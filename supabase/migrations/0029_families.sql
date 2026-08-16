-- =============================================================================
-- Family billing — the student keeps the ledger, the family holds the wallet.
--
-- Design and rationale: docs/10-MONEY-ENGINE-V2.md
--
-- A father with three children in the school hands over one bundle of cash.
-- Until now that was three transactions, three receipt numbers and three
-- pieces of paper, because fn_record_payment took a single student_id.
--
-- What changes:
--   * `families` is the payer. Every student belongs to exactly one.
--   * A payment belongs to a FAMILY and is allocated across whichever
--     children's invoices it clears — oldest month first, across siblings.
--   * Money that clears no invoice is FAMILY CREDIT: explicit, queryable and
--     reportable, instead of an unexplained negative student balance.
--
-- What deliberately does NOT change:
--   * Invoices stay per student. Charges, discounts, fines, adjustments and
--     arrears are untouched, so every existing report keeps working.
--   * `guardians` stays as-is. It holds the contact people (father, mother,
--     the uncle who does pickup). `families` is the BILLING entity. Conflating
--     the two would be a mistake — the person who pays and the people you ring
--     are different sets.
--
-- THE ONE BEHAVIOUR CHANGE, stated loudly because it is deliberate:
--
--   student_balance() used to subtract `sum(payments where student_id = X)`.
--   Once a payment can span three children that is simply wrong — the money
--   belongs to the invoices it cleared, not to any one child. It now subtracts
--   the ALLOCATIONS against that student's invoices.
--
--   For a fully-allocated single-student payment the two are identical, and
--   the test suite proves it. They differ for an OVERPAYMENT: the old rule
--   drove the student's balance negative, the new rule takes the student to
--   zero and parks the remainder as family credit. That is the fix, not a
--   regression — "how much advance is this parent holding?" was previously
--   unanswerable.
--
--   Conservation still holds:
--     family_outstanding = sum(student_balance of members) - family_credit
-- =============================================================================

-- ===========================================================================
-- 1. The payer
-- ===========================================================================

create table public.families (
  id            uuid primary key default gen_random_uuid(),
  school_id     uuid not null references public.schools(id) on delete cascade,
  head_name     text not null,                 -- "Muhammad Aslam"
  head_cnic     text,                          -- the natural key at the counter
  phone         text,
  whatsapp      text,
  address       text,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);

create trigger trg_families_updated before update on public.families
  for each row execute function public.set_updated_at();

-- CNIC is unique per school when present. Nullable because plenty of schools
-- never collect it, and a NOT NULL here would block admission.
create unique index uq_families_school_cnic
  on public.families (school_id, head_cnic) where head_cnic is not null;
create index idx_families_school on public.families (school_id);
create index idx_families_phone  on public.families (school_id, phone);

alter table public.students add column family_id uuid references public.families(id);
create index idx_students_family on public.students (family_id);

-- ===========================================================================
-- 2. Backfill: one family per existing student, from the primary guardian
--
-- Deliberately NOT merged on a name match. Merging two families is
-- destructive — it moves money between ledgers — so existing schools get
-- one family per student and fn_link_students (which already detects
-- siblings) proposes merges a human confirms.
-- ===========================================================================

do $$
declare v_s record; v_f uuid;
begin
  for v_s in
    select s.id, s.school_id, s.full_name,
           (select g.name from public.guardians g
            where g.student_id = s.id order by g.is_primary desc, g.created_at limit 1) as g_name,
           (select g.phone from public.guardians g
            where g.student_id = s.id order by g.is_primary desc, g.created_at limit 1) as g_phone,
           (select g.whatsapp from public.guardians g
            where g.student_id = s.id order by g.is_primary desc, g.created_at limit 1) as g_wa
    from public.students s
    where s.family_id is null
  loop
    insert into public.families (school_id, head_name, phone, whatsapp)
    values (v_s.school_id,
            coalesce(nullif(btrim(coalesce(v_s.g_name, '')), ''), v_s.full_name || ' (family)'),
            v_s.g_phone, v_s.g_wa)
    returning id into v_f;

    update public.students set family_id = v_f where id = v_s.id;
  end loop;
end $$;

-- ===========================================================================
-- 3. Payments belong to a family
-- ===========================================================================

alter table public.payments add column family_id uuid references public.families(id);

update public.payments p
   set family_id = s.family_id
  from public.students s
 where s.id = p.student_id and p.family_id is null;

-- student_id stays, now nullable: it is set for a single-student payment (so a
-- receipt can still say "this was for Ahmed") and null for a family payment,
-- where the children are derived from the allocations.
alter table public.payments alter column student_id drop not null;
alter table public.payments
  add constraint payments_has_payer check (family_id is not null or student_id is not null);
create index idx_payments_family on public.payments (family_id);

-- ===========================================================================
-- 4. Tenant plumbing for the new table
-- ===========================================================================

create trigger trg_families_school before insert or update on public.families
  for each row execute function public.enforce_school_id();

create trigger trg_audit_families after insert or update or delete on public.families
  for each row execute function public.audit_trigger();

alter table public.families enable row level security;

-- Readable by any signed-in member of the school (the family shows on a
-- student profile). Writable by the roles that admit students and take money.
create policy families_select on public.families for select to authenticated
  using (school_id = public.current_school_id());
create policy families_insert on public.families for insert to authenticated
  with check (school_id = public.current_school_id()
              and public.has_role('owner', 'principal', 'admin_clerk', 'accountant'));
create policy families_update on public.families for update to authenticated
  using (school_id = public.current_school_id()
         and public.has_role('owner', 'principal', 'admin_clerk', 'accountant'))
  with check (school_id = public.current_school_id());

-- ===========================================================================
-- 5. The shared allocator
--
-- One implementation, used by every path that puts money against invoices:
-- single-student payment, family payment, verifying a pending payment, and
-- applying credit. Having three copies of a FIFO loop was how the old code
-- drifted; there is now exactly one.
--
-- Order is oldest period first, then student, then invoice — deterministic, so
-- the same payment always lands the same way and a test can assert it.
-- ===========================================================================

create or replace function public.fn__allocate_payment(
  p_payment_id uuid, p_student_ids uuid[], p_amount numeric
) returns numeric language plpgsql security definer set search_path = public as $$
declare
  v_remaining numeric := p_amount;
  v_alloc     numeric;
  v_rec       record;
begin
  for v_rec in
    select b.invoice_id, (b.charge - b.allocated) as outstanding
    from public.invoice_balances b
    join public.invoices i on i.id = b.invoice_id
    where b.student_id = any(p_student_ids)
      and b.status in ('issued', 'partial')
      and (b.charge - b.allocated) > 0
    order by i.period_month nulls first, b.student_id, b.invoice_id
  loop
    exit when v_remaining <= 0;
    v_alloc := least(v_remaining, v_rec.outstanding);

    insert into public.payment_allocations(payment_id, invoice_id, amount)
    values (p_payment_id, v_rec.invoice_id, v_alloc);
    v_remaining := v_remaining - v_alloc;

    update public.invoices i set status = (case
      when (select allocated from public.invoice_balances b2 where b2.invoice_id = i.id)
           >= (select charge from public.invoice_balances b2 where b2.invoice_id = i.id)
      then 'paid' else 'partial' end)::public.invoice_status
    where i.id = v_rec.invoice_id;
  end loop;

  return v_remaining;   -- what stayed unallocated; the family keeps it as credit
end;
$$;

-- ===========================================================================
-- 6. Balances
-- ===========================================================================

-- Payments now come from ALLOCATIONS. See the header for why, and for the one
-- behaviour change (overpayment no longer drives a student negative).
create or replace function public.student_balance(p_student_id uuid)
returns numeric language sql stable security invoker set search_path = public as $$
  select
    coalesce((
      select sum(case when l.is_discount then -l.amount else l.amount end)
      from public.invoice_lines l
      join public.invoices i on i.id = l.invoice_id
      where i.student_id = p_student_id and i.status <> 'void'
    ), 0)
    + coalesce((
      select sum(i.fine) from public.invoices i
      where i.student_id = p_student_id and i.status <> 'void'
    ), 0)
    + coalesce((
      select sum(a.amount) from public.adjustments a
      where a.student_id = p_student_id
    ), 0)
    - coalesce((
      select sum(al.amount)
      from public.payment_allocations al
      join public.invoices i2 on i2.id = al.invoice_id
      join public.payments p on p.id = al.payment_id
      where i2.student_id = p_student_id and p.status = 'verified'
    ), 0);
$$;

-- Money received from this family that has not been applied to any invoice.
-- Reversals carry negative amounts and negative allocations, so they net out.
create or replace function public.family_credit(p_family_id uuid)
returns numeric language sql stable security invoker set search_path = public as $$
  select greatest(coalesce((
    select sum(p.amount - coalesce(a.alloc, 0))
    from public.payments p
    left join lateral (
      select sum(al.amount) as alloc
      from public.payment_allocations al
      where al.payment_id = p.id
    ) a on true
    where p.family_id = p_family_id and p.status = 'verified'
  ), 0), 0);
$$;

-- What the family actually owes, net of anything they are holding on account.
create or replace function public.family_outstanding(p_family_id uuid)
returns numeric language sql stable security invoker set search_path = public as $$
  select coalesce((
    select sum(public.student_balance(s.id))
    from public.students s where s.family_id = p_family_id
  ), 0) - public.family_credit(p_family_id);
$$;

-- ===========================================================================
-- 7. Finding the payer at the counter
--
-- One search box resolving CNIC / phone / head name / student name / GR to a
-- family. Fifteen seconds is the target for the whole interaction; making the
-- clerk pick the right search mode first is how you lose ten of them.
-- ===========================================================================

create or replace function public.fn_find_family(p_query text)
returns table (
  family_id uuid, head_name text, head_cnic text, phone text,
  children integer, outstanding numeric, credit numeric
) language sql stable security invoker set search_path = public as $$
  with q as (select trim(coalesce(p_query, '')) as t)
  select f.id, f.head_name, f.head_cnic, f.phone,
         (select count(*)::integer from public.students s where s.family_id = f.id),
         public.family_outstanding(f.id),
         public.family_credit(f.id)
  from public.families f, q
  where q.t <> ''
    -- Explicit tenant filter, NOT just RLS. This function is SECURITY INVOKER
    -- so RLS does cover it today, but a search that leaks every school's
    -- parents is too dangerous to leave resting on one mechanism — and if
    -- anyone ever marks it SECURITY DEFINER, RLS stops applying silently.
    and f.school_id = public.current_school_id()
    and (
      f.head_cnic = q.t
      or replace(coalesce(f.head_cnic, ''), '-', '') = replace(q.t, '-', '')
      or f.phone like '%' || q.t || '%'
      or f.head_name ilike '%' || q.t || '%'
      or exists (
        select 1 from public.students s
        where s.family_id = f.id
          and (s.full_name ilike '%' || q.t || '%' or s.gr_no = q.t)
      )
    )
  order by f.head_name
  limit 25;
$$;

-- The family sheet: every child, what each owes, and what the family holds.
create or replace function public.fn_family_sheet(p_family_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_out jsonb;
begin
  if not public.has_role('owner','principal','admin_clerk','accountant','readonly') then
    raise exception 'Not permitted to view fee records';
  end if;
  perform public.assert_own('families', p_family_id);

  select jsonb_build_object(
    'family', to_jsonb(f) - 'school_id',
    'credit', public.family_credit(f.id),
    'outstanding', public.family_outstanding(f.id),
    'children', coalesce((
      select jsonb_agg(jsonb_build_object(
        'student_id', s.id,
        'full_name',  s.full_name,
        'gr_no',      s.gr_no,
        'status',     s.status,
        'balance',    public.student_balance(s.id),
        'invoices',   coalesce((
          select jsonb_agg(jsonb_build_object(
            'invoice_id',   b.invoice_id,
            'period_month', i.period_month,
            'due_date',     i.due_date,
            'charge',       b.charge,
            'allocated',    b.allocated,
            'outstanding',  b.charge - b.allocated,
            'status',       b.status
          ) order by i.period_month nulls first)
          from public.invoice_balances b
          join public.invoices i on i.id = b.invoice_id
          where b.student_id = s.id and b.status in ('issued', 'partial')
            and b.charge - b.allocated > 0
        ), '[]'::jsonb)
      ) order by s.full_name)
      from public.students s where s.family_id = f.id
    ), '[]'::jsonb)
  ) into v_out
  from public.families f where f.id = p_family_id;

  if v_out is null then raise exception 'Family not found'; end if;
  return v_out;
end;
$$;

-- ===========================================================================
-- 8. Taking the money
-- ===========================================================================

-- One payment, one gapless receipt, allocated across every child in the family.
create or replace function public.fn_record_family_payment(
  p_family_id uuid, p_amount numeric, p_method public.payment_method,
  p_note text default null, p_pending boolean default false
) returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_actor    uuid := auth.uid();
  v_receipt  bigint;
  v_pay      uuid;
  v_students uuid[];
  v_left     numeric;
begin
  if not public.has_role('owner','principal','admin_clerk','accountant') then
    raise exception 'Not permitted to record payments';
  end if;
  if p_amount is null or p_amount <= 0 then raise exception 'Amount must be positive'; end if;
  perform public.assert_own('families', p_family_id);

  select array_agg(id) into v_students from public.students where family_id = p_family_id;
  if v_students is null then raise exception 'This family has no students'; end if;

  v_receipt := public.next_counter('receipt');
  insert into public.payments(family_id, student_id, amount, method, receipt_no,
                              status, received_by, note)
  values (p_family_id, null, p_amount, p_method, v_receipt,
          case when p_pending then 'pending' else 'verified' end, v_actor, p_note)
  returning id into v_pay;

  -- A pending payment (a bank challan not yet cleared) holds a receipt number
  -- but is not counted and not allocated until it is verified.
  if p_pending then
    return jsonb_build_object('payment_id', v_pay, 'receipt_no', v_receipt,
      'allocated', 0, 'credit', 0, 'pending', true);
  end if;

  v_left := public.fn__allocate_payment(v_pay, v_students, p_amount);

  return jsonb_build_object(
    'payment_id', v_pay, 'receipt_no', v_receipt,
    'allocated', p_amount - v_left,
    'credit', v_left,                       -- stays with the family, on account
    'family_outstanding', public.family_outstanding(p_family_id),
    'pending', false);
end;
$$;

-- The single-student path, rewritten onto the shared allocator. Semantics are
-- unchanged: it allocates only to THAT student's invoices, never a sibling's.
create or replace function public.fn_record_payment(
  p_student_id uuid, p_amount numeric, p_method public.payment_method,
  p_note text default null, p_pending boolean default false
) returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_actor   uuid := auth.uid();
  v_receipt bigint;
  v_pay     uuid;
  v_family  uuid;
  v_left    numeric;
begin
  if not public.has_role('owner','principal','admin_clerk','accountant') then
    raise exception 'Not permitted to record payments';
  end if;
  if p_amount is null or p_amount <= 0 then raise exception 'Amount must be positive'; end if;
  perform public.assert_own('students', p_student_id);

  select family_id into v_family from public.students where id = p_student_id;

  v_receipt := public.next_counter('receipt');
  insert into public.payments(student_id, family_id, amount, method, receipt_no,
                              status, received_by, note)
  values (p_student_id, v_family, p_amount, p_method, v_receipt,
          case when p_pending then 'pending' else 'verified' end, v_actor, p_note)
  returning id into v_pay;

  if p_pending then
    return jsonb_build_object('payment_id', v_pay, 'receipt_no', v_receipt,
      'allocated', 0, 'unallocated', p_amount, 'pending', true);
  end if;

  v_left := public.fn__allocate_payment(v_pay, array[p_student_id], p_amount);

  return jsonb_build_object(
    'payment_id', v_pay, 'receipt_no', v_receipt,
    'allocated', p_amount - v_left, 'unallocated', v_left, 'pending', false);
end;
$$;

-- Verifying a cleared challan allocates the same way the original would have,
-- across the family when it was a family payment.
create or replace function public.fn_verify_payment(p_payment_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_pay      record;
  v_students uuid[];
  v_left     numeric;
begin
  if not public.has_role('owner','principal','admin_clerk','accountant') then
    raise exception 'Not permitted to verify payments';
  end if;
  perform public.assert_own('payments', p_payment_id);
  select * into v_pay from public.payments where id = p_payment_id for update;
  if not found then raise exception 'Payment not found'; end if;
  if v_pay.status <> 'pending' then raise exception 'Only a pending payment can be verified'; end if;

  update public.payments set status = 'verified' where id = p_payment_id;

  if v_pay.student_id is not null then
    v_students := array[v_pay.student_id];
  else
    select array_agg(id) into v_students from public.students where family_id = v_pay.family_id;
  end if;

  v_left := public.fn__allocate_payment(p_payment_id, coalesce(v_students, '{}'::uuid[]), v_pay.amount);

  return jsonb_build_object('payment_id', p_payment_id,
    'allocated', v_pay.amount - v_left, 'unallocated', v_left);
end;
$$;

-- Reversal must carry the family across, or the reversing entry would not
-- cancel out of family_credit and the wallet would drift.
create or replace function public.fn_reverse_payment(p_payment_id uuid, p_reason text)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  v_actor   uuid := auth.uid();
  v_orig    record;
  v_a       record;
  v_rev     uuid;
  v_receipt bigint;
begin
  if not public.has_role('owner', 'principal') then
    raise exception 'Only owner/principal may reverse a payment';
  end if;
  perform public.assert_own('payments', p_payment_id);
  select * into v_orig from public.payments where id = p_payment_id;
  if not found then raise exception 'Payment not found'; end if;
  if v_orig.status <> 'verified' then
    raise exception 'Only a verified payment can be reversed (pending/cancelled payments are handled in the Pending tab)';
  end if;
  if v_orig.reversal_of is not null then raise exception 'Cannot reverse a reversal'; end if;
  if exists (select 1 from public.payments where reversal_of = p_payment_id) then
    raise exception 'Payment already reversed';
  end if;

  v_receipt := public.next_counter('receipt');
  insert into public.payments(student_id, family_id, amount, method, receipt_no,
                              status, received_by, reversal_of, note)
  values (v_orig.student_id, v_orig.family_id, -v_orig.amount, v_orig.method, v_receipt,
          'verified', v_actor, p_payment_id, coalesce(p_reason, 'reversal'))
  returning id into v_rev;

  for v_a in select * from public.payment_allocations where payment_id = p_payment_id loop
    insert into public.payment_allocations(payment_id, invoice_id, amount)
    values (v_rev, v_a.invoice_id, -v_a.amount);
    update public.invoices i set status = (case
      when (select allocated from public.invoice_balances b where b.invoice_id = i.id) <= 0 then 'issued'
      when (select allocated from public.invoice_balances b where b.invoice_id = i.id)
           >= (select charge from public.invoice_balances b where b.invoice_id = i.id) then 'paid'
      else 'partial' end)::public.invoice_status
    where i.id = v_a.invoice_id;
  end loop;

  return v_rev;
end;
$$;

-- ===========================================================================
-- 9. Credit meets the next challan
--
-- A family holding credit must not appear on the defaulter list. Left
-- unapplied, the list shows families who have already paid, and a list nobody
-- trusts is a list nobody reads. So generation applies credit immediately.
-- ===========================================================================

create or replace function public.fn_apply_family_credit(p_family_id uuid)
returns numeric language plpgsql security definer set search_path = public as $$
declare
  v_students uuid[];
  v_pay      record;
  v_left     numeric;
  v_applied  numeric := 0;
begin
  select array_agg(id) into v_students from public.students where family_id = p_family_id;
  if v_students is null then return 0; end if;

  -- Walk the family's payments oldest first, topping up each one's allocations
  -- until its own unallocated remainder is spent. Allocation rows stay tied to
  -- the payment that actually brought the money in, so a receipt reprint and a
  -- reversal both still reconcile.
  for v_pay in
    select p.id, p.amount - coalesce((
             select sum(al.amount) from public.payment_allocations al
             where al.payment_id = p.id), 0) as unallocated
    from public.payments p
    where p.family_id = p_family_id and p.status = 'verified'
    order by p.created_at, p.id
  loop
    if v_pay.unallocated > 0 then
      v_left := public.fn__allocate_payment(v_pay.id, v_students, v_pay.unallocated);
      v_applied := v_applied + (v_pay.unallocated - v_left);
    end if;
  end loop;

  return v_applied;
end;
$$;

-- Generation now settles credit for every family it billed.
create or replace function public.fn_generate_class_invoices(
  p_session_id uuid, p_class_id uuid, p_period_month date, p_due_date date
) returns integer language plpgsql security definer set search_path = public as $$
declare
  v_actor    uuid := auth.uid();
  v_enr      record;
  v_inv      uuid;
  v_count    integer := 0;
  v_arrears  numeric;
  v_tuition  numeric;
  v_families uuid[] := '{}';
  v_fam      uuid;
begin
  if not public.has_role('owner', 'principal', 'admin_clerk', 'accountant') then
    raise exception 'Not permitted to generate invoices';
  end if;
  perform public.assert_own('academic_sessions', p_session_id);
  perform public.assert_own('classes', p_class_id);

  for v_enr in
    select e.id as enrollment_id, e.student_id
    from public.enrollments e
    where e.session_id = p_session_id and e.class_id = p_class_id and e.status = 'active'
      and not exists (
        select 1 from public.invoices i
        where i.enrollment_id = e.id and i.period_month = p_period_month and i.status <> 'void'
      )
  loop
    v_arrears := public.student_balance(v_enr.student_id);
    begin
      insert into public.invoices(
        student_id, enrollment_id, session_id, period_month, status,
        arrears_brought_forward, due_date, issued_at, created_by)
      values (
        v_enr.student_id, v_enr.enrollment_id, p_session_id, p_period_month, 'issued',
        v_arrears, p_due_date, now(), v_actor)
      returning id into v_inv;
    exception when unique_violation then
      continue;
    end;

    insert into public.invoice_lines(invoice_id, fee_head_id, description, amount, is_discount)
    select v_inv, fh.id, fh.name, coalesce(sfi.amount, fs.amount), false
    from public.fee_structures fs
    join public.fee_heads fh on fh.id = fs.fee_head_id
    left join public.student_fee_items sfi
      on sfi.enrollment_id = v_enr.enrollment_id and sfi.fee_head_id = fh.id and sfi.active
    where fs.session_id = p_session_id and fs.class_id = p_class_id
      and fh.is_recurring and fh.active;

    select coalesce(sum(amount), 0) into v_tuition
    from public.invoice_lines where invoice_id = v_inv and not is_discount;

    perform public.fn__apply_discount_lines(v_inv, v_enr.enrollment_id, v_tuition);
    v_count := v_count + 1;

    select family_id into v_fam from public.students where id = v_enr.student_id;
    if v_fam is not null and not (v_fam = any(v_families)) then
      v_families := v_families || v_fam;
    end if;
  end loop;

  foreach v_fam in array v_families loop
    perform public.fn_apply_family_credit(v_fam);
  end loop;

  return v_count;
end;
$$;

-- ===========================================================================
-- 10. Admission attaches the family
-- ===========================================================================

-- Match on the father's CNIC when given, otherwise start a new family. Never
-- match on name alone: two unrelated Muhammad Aslams in one school is not a
-- corner case in Pakistan, and a wrong match merges two families' money.
create or replace function public.fn_family_for(
  p_head_name text, p_head_cnic text default null,
  p_phone text default null, p_whatsapp text default null
) returns uuid language plpgsql security definer set search_path = public as $$
declare v_id uuid; v_school uuid := public.current_school_id();
begin
  if p_head_cnic is not null and btrim(p_head_cnic) <> '' then
    select id into v_id from public.families
    where school_id = v_school and head_cnic = btrim(p_head_cnic);
    if found then
      update public.families set
        phone    = coalesce(nullif(btrim(coalesce(p_phone, '')), ''), phone),
        whatsapp = coalesce(nullif(btrim(coalesce(p_whatsapp, '')), ''), whatsapp)
      where id = v_id;
      return v_id;
    end if;
  end if;

  insert into public.families (head_name, head_cnic, phone, whatsapp)
  values (coalesce(nullif(btrim(coalesce(p_head_name, '')), ''), 'Family'),
          nullif(btrim(coalesce(p_head_cnic, '')), ''),
          nullif(btrim(coalesce(p_phone, '')), ''),
          nullif(btrim(coalesce(p_whatsapp, '')), ''))
  returning id into v_id;
  return v_id;
end;
$$;

-- Any student created without a family gets a single-child one, so no code
-- path can produce a student who cannot be billed.
create or replace function public.fn_student_default_family() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.family_id is null then
    -- school_id is left to the families stamping trigger rather than copied
    -- from new.school_id, so this is correct even if trigger order ever moves.
    insert into public.families (school_id, head_name)
    values (coalesce(new.school_id, public.current_school_id()),
            new.full_name || ' (family)')
    returning id into new.family_id;
  end if;
  return new;
end;
$$;

-- THE NAME MATTERS. Postgres fires BEFORE ROW triggers in alphabetical order,
-- and 0025 created `trg_students_school` to stamp school_id. This trigger must
-- run AFTER that one, or new.school_id is still null when it reads it — so the
-- name is chosen to sort later. Do not rename it earlier in the alphabet.
create trigger trg_students_zz_family before insert on public.students
  for each row execute function public.fn_student_default_family();

alter table public.students alter column family_id set not null;

-- ===========================================================================
-- 11. Grants
-- ===========================================================================

grant execute on function public.family_credit(uuid)              to authenticated;
grant execute on function public.family_outstanding(uuid)         to authenticated;
grant execute on function public.fn_find_family(text)             to authenticated;
grant execute on function public.fn_family_sheet(uuid)            to authenticated;
grant execute on function public.fn_family_for(text, text, text, text) to authenticated;
grant execute on function public.fn_record_family_payment(uuid, numeric, public.payment_method, text, boolean)
  to authenticated;
grant execute on function public.fn_apply_family_credit(uuid)     to authenticated;

-- fn__allocate_payment is INTERNAL. It writes allocation rows against any
-- invoice id handed to it, so exposing it would let a signed-in user mark
-- invoices paid without a payment. Callers reach it only through the guarded
-- functions above.
revoke all on function public.fn__allocate_payment(uuid, uuid[], numeric) from public, anon, authenticated;

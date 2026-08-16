-- =============================================================================
-- Fee operations: the annual raise, and a scannable challan.
--
-- 1. EFFECTIVE-DATED FEE STRUCTURES
--
-- fee_structures was unique on (session, class, head) — one amount, forever.
-- Every Pakistani school raises fees at least once a year, and doing that here
-- meant editing every class and every head by hand. That afternoon is exactly
-- when a school decides the software is a burden.
--
-- Amounts now carry effective_from, and billing picks the row in force for the
-- month being billed. Nothing is ever updated in place, so a raise leaves the
-- old amount visible beside the new one and last year's invoices still explain
-- themselves. (Past invoices were already safe — invoice_lines snapshots the
-- amount — but the STRUCTURE had no memory, so "what did Class 5 pay in
-- March?" was unanswerable.)
--
-- 2. SCANNABLE CHALLANS
--
-- A short code on the printed challan that the clerk scans at the counter.
-- Beyond speed, it removes the wrong-student posting error, which is the
-- mistake that is indistinguishable from theft when it surfaces months later.
-- =============================================================================

-- ===========================================================================
-- 1. Effective dating
-- ===========================================================================

alter table public.fee_structures
  add column effective_from date not null default date '1900-01-01';

alter table public.fee_structures
  drop constraint fee_structures_session_id_class_id_fee_head_id_key;

alter table public.fee_structures
  add constraint fee_structures_effective_key
  unique (session_id, class_id, fee_head_id, effective_from);

create index idx_fee_structures_lookup
  on public.fee_structures (session_id, class_id, fee_head_id, effective_from desc);

-- The amount in force for a given month. One definition, used by billing and
-- by the preview, so a preview can never disagree with what generation does.
create or replace function public.fn_fee_amount(
  p_session_id uuid, p_class_id uuid, p_fee_head_id uuid, p_on date
) returns numeric language sql stable security definer set search_path = public as $$
  select fs.amount
  from public.fee_structures fs
  where fs.session_id = p_session_id
    and fs.class_id = p_class_id
    and fs.fee_head_id = p_fee_head_id
    and fs.effective_from <= coalesce(p_on, current_date)
  order by fs.effective_from desc
  limit 1;
$$;

-- Billing now reads the effective amount instead of the single row.
-- Everything else about this function is unchanged from 0029.
create or replace function public.fn_generate_class_invoices(
  p_session_id uuid, p_class_id uuid, p_period_month date, p_due_date date
) returns integer language plpgsql security definer set search_path = public as $$
declare
  v_actor    uuid := auth.uid();
  v_school   uuid := public.current_school_id();
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

    -- A per-student override (student_fee_items) still wins over the class
    -- amount; the class amount is now the one in force for the billed month.
    insert into public.invoice_lines(invoice_id, fee_head_id, description, amount, is_discount)
    select v_inv, fh.id, fh.name, coalesce(sfi.amount, amt.amount), false
    from public.fee_heads fh
    join lateral (
      select fs.amount
      from public.fee_structures fs
      where fs.session_id = p_session_id
        and fs.class_id = p_class_id
        and fs.fee_head_id = fh.id
        and fs.effective_from <= coalesce(p_period_month, current_date)
      order by fs.effective_from desc
      limit 1
    ) amt on true
    left join public.student_fee_items sfi
      on sfi.enrollment_id = v_enr.enrollment_id and sfi.fee_head_id = fh.id and sfi.active
    where fh.school_id = v_school and fh.is_recurring and fh.active;

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
-- 2. The annual raise
--
-- Preview → commit, the same shape as fn_rollover, because a fee raise applied
-- to the wrong classes is discovered by four hundred angry parents.
-- ===========================================================================

create or replace function public.fn_fee_increment(
  p_session_id     uuid,
  p_class_ids      uuid[],          -- null = every class in the session
  p_fee_head_ids   uuid[],          -- null = every recurring head
  p_percent        numeric,         -- either a percent...
  p_amount         numeric,         -- ...or a flat rupee amount. Not both.
  p_effective_from date,
  p_commit         boolean default false
) returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_school uuid := public.current_school_id();
  r        record;
  v_new    numeric;
  v_rows   jsonb := '[]'::jsonb;
  v_n      integer := 0;
begin
  if not public.has_role('owner', 'principal') then
    raise exception 'Only owner/principal may change fees';
  end if;
  perform public.assert_own('academic_sessions', p_session_id);

  if (p_percent is null) = (p_amount is null) then
    raise exception 'Give either a percentage or a flat amount, not both and not neither';
  end if;
  if coalesce(p_percent, 0) < 0 or coalesce(p_amount, 0) < 0 then
    raise exception 'Use a positive figure. To reduce a fee, set the new amount directly.';
  end if;
  if p_effective_from is null then
    raise exception 'A fee change needs a date it takes effect from';
  end if;

  for r in
    select fs.class_id, c.name as class_name,
           fs.fee_head_id, fh.name as head_name,
           public.fn_fee_amount(p_session_id, fs.class_id, fs.fee_head_id,
                                p_effective_from) as current_amount
    from public.fee_structures fs
    join public.classes c on c.id = fs.class_id
    join public.fee_heads fh on fh.id = fs.fee_head_id
    where fs.session_id = p_session_id
      and fs.school_id = v_school
      and (p_class_ids is null or fs.class_id = any(p_class_ids))
      and (p_fee_head_ids is null or fs.fee_head_id = any(p_fee_head_ids))
    group by fs.class_id, c.name, fs.fee_head_id, fh.name
    order by c.name, fh.name
  loop
    v_new := round(
      case when p_percent is not null
           then coalesce(r.current_amount, 0) * (1 + p_percent / 100.0)
           else coalesce(r.current_amount, 0) + p_amount
      end, 0);

    v_rows := v_rows || jsonb_build_object(
      'class', r.class_name, 'fee_head', r.head_name,
      'from', r.current_amount, 'to', v_new);
    v_n := v_n + 1;

    if p_commit then
      insert into public.fee_structures
        (session_id, class_id, fee_head_id, amount, effective_from, school_id)
      values (p_session_id, r.class_id, r.fee_head_id, v_new, p_effective_from, v_school)
      on conflict (session_id, class_id, fee_head_id, effective_from)
      do update set amount = excluded.amount;
    end if;
  end loop;

  return jsonb_build_object(
    'committed', p_commit,
    'effective_from', p_effective_from,
    'changes', v_n,
    'rows', v_rows);
end;
$$;

-- ===========================================================================
-- 3. Scannable challans
-- ===========================================================================

alter table public.invoices add column voucher_code text;

-- Short, unambiguous, printable as Code128 and typeable when the scanner dies.
-- Characters that look alike (0/O, 1/I) are excluded from the alphabet.
create or replace function public.fn__voucher_code() returns text
language plpgsql volatile set search_path = public as $$
declare
  v_alpha text := '23456789ABCDEFGHJKLMNPQRSTUVWXYZ';
  v_out   text := '';
  i integer;
begin
  for i in 1..8 loop
    v_out := v_out || substr(v_alpha, 1 + floor(random() * length(v_alpha))::int, 1);
  end loop;
  return v_out;
end;
$$;

create or replace function public.fn__stamp_voucher_code() returns trigger
language plpgsql security definer set search_path = public as $$
declare i integer := 0;
begin
  if new.voucher_code is not null then return new; end if;
  loop
    new.voucher_code := public.fn__voucher_code();
    exit when not exists (
      select 1 from public.invoices
      where school_id = new.school_id and voucher_code = new.voucher_code);
    i := i + 1;
    if i > 20 then
      -- Never block a challan over a code collision.
      new.voucher_code := null;
      exit;
    end if;
  end loop;
  return new;
end;
$$;

-- Sorts after trg_invoices_school so school_id is already stamped.
create trigger trg_invoices_zz_voucher before insert on public.invoices
  for each row execute function public.fn__stamp_voucher_code();

create unique index uq_invoices_voucher
  on public.invoices (school_id, voucher_code) where voucher_code is not null;

-- Backfill existing invoices so every challan in the system can be scanned.
do $$
declare r record; v_code text; i integer;
begin
  for r in select id, school_id from public.invoices where voucher_code is null loop
    i := 0;
    loop
      v_code := public.fn__voucher_code();
      exit when not exists (
        select 1 from public.invoices
        where school_id = r.school_id and voucher_code = v_code);
      i := i + 1;
      exit when i > 20;
    end loop;
    update public.invoices set voucher_code = v_code where id = r.id;
  end loop;
end $$;

-- Scan at the counter: resolve a code to the FAMILY, because that is what the
-- collection screen works in. Scanning one child's challan brings up the whole
-- family, which is what the parent is standing there to pay.
create or replace function public.fn_find_by_voucher(p_code text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_inv record;
begin
  if not public.has_role('owner','principal','admin_clerk','accountant') then
    raise exception 'Not permitted';
  end if;

  select i.id, i.student_id, i.period_month, s.full_name, s.family_id
    into v_inv
  from public.invoices i
  join public.students s on s.id = i.student_id
  where i.school_id = public.current_school_id()
    and i.voucher_code = upper(btrim(coalesce(p_code, '')))
    and i.status <> 'void';

  if not found then return null; end if;

  return jsonb_build_object(
    'invoice_id', v_inv.id,
    'student_id', v_inv.student_id,
    'student_name', v_inv.full_name,
    'family_id', v_inv.family_id,
    'period_month', v_inv.period_month);
end;
$$;

-- ===========================================================================
-- 4. Head-wise dues
--
-- Which fee head is unpaid across the school. Allocations are invoice-level,
-- not line-level, so collections are apportioned across heads IN PROPORTION to
-- their share of each invoice. That rule is stated on the report itself: a
-- number whose derivation is hidden is one an owner cannot defend.
-- ===========================================================================

create or replace function public.fn_head_wise_dues(p_session_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_rows jsonb;
begin
  if not public.has_role('owner', 'principal', 'accountant') then
    raise exception 'Not permitted to view fee reports';
  end if;
  perform public.assert_own('academic_sessions', p_session_id);

  select coalesce(jsonb_agg(x order by x.charged desc), '[]'::jsonb) into v_rows
  from (
    select coalesce(l.description, 'Other') as fee_head,
           sum(case when l.is_discount then -l.amount else l.amount end) as charged,
           sum(
             case when b.charge > 0
                  then (case when l.is_discount then -l.amount else l.amount end)
                       * (b.allocated / b.charge)
                  else 0 end
           ) as collected
    from public.invoice_lines l
    join public.invoices i on i.id = l.invoice_id
    join public.invoice_balances b on b.invoice_id = i.id
    where i.session_id = p_session_id
      and i.school_id = public.current_school_id()
      and i.status <> 'void'
    group by 1
  ) x;

  return jsonb_build_object(
    'session_id', p_session_id,
    'basis', 'Collections are apportioned across fee heads in proportion to '
             || 'their share of each invoice.',
    'heads', v_rows);
end;
$$;

grant execute on function public.fn_fee_amount(uuid, uuid, uuid, date) to authenticated;
grant execute on function public.fn_fee_increment(uuid, uuid[], uuid[], numeric, numeric, date, boolean) to authenticated;
grant execute on function public.fn_find_by_voucher(text)              to authenticated;
grant execute on function public.fn_head_wise_dues(uuid)               to authenticated;

revoke all on function public.fn__stamp_voucher_code() from public, anon, authenticated;

-- =============================================================================
-- Fixes from the adversarial review of the fee/attendance redesign:
--   1. fn_reverse_payment must reject non-verified payments — reversing a pending
--      or cancelled challan would mint a verified negative entry (phantom credit,
--      fake day-book row) since the original never counted.
--   2. Billing must cap cumulative discount at tuition, exactly like the display
--      (fn_student_monthly_fee). An over-discount / stacked "Make free" otherwise
--      bills a NEGATIVE invoice = a hidden credit.
--   3. fn_verify_payment: lock the row (FOR UPDATE) so concurrent verifies can't
--      double-allocate.
--   4. Enforce one invoice per (enrollment, month) at the DB level; make the
--      on-demand and batch billing tolerate the race.
--   5. fn_student_month_tests → SECURITY INVOKER (reads only RLS-public tables).
-- =============================================================================

-- 1. Reversal is for VERIFIED payments only. --------------------------------
create or replace function public.fn_reverse_payment(p_payment_id uuid, p_reason text)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  v_actor uuid := auth.uid();
  v_orig  record;
  v_a     record;
  v_rev   uuid;
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
  insert into public.payments(student_id, amount, method, receipt_no, status, received_by, reversal_of, note)
  values (v_orig.student_id, -v_orig.amount, v_orig.method, v_receipt, 'verified', v_actor, p_payment_id,
          coalesce(p_reason, 'reversal'))
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

-- 2 + 4. One invoice per (enrollment, month); billing caps discount at tuition.
create unique index if not exists uq_invoice_enroll_month
  on public.invoices (enrollment_id, period_month)
  where status <> 'void' and period_month is not null;

-- Shared helper: insert approved-discount lines for an invoice, capping the
-- cumulative discount at the tuition so an invoice can never go negative.
create or replace function public.fn__apply_discount_lines(
  p_invoice_id uuid, p_enrollment_id uuid, p_tuition numeric
) returns void language plpgsql security definer set search_path = public as $$
declare
  v_drec record;
  v_room numeric := p_tuition;
  v_amt  numeric;
begin
  for v_drec in
    select * from public.discounts d
    where d.enrollment_id = p_enrollment_id and d.status = 'approved'
    order by d.created_at
  loop
    exit when v_room <= 0;
    v_amt := case when v_drec.is_percent then round(p_tuition * v_drec.amount / 100.0, 2) else v_drec.amount end;
    v_amt := least(v_amt, v_room);
    if v_amt > 0 then
      insert into public.invoice_lines(invoice_id, fee_head_id, description, amount, is_discount)
      values (p_invoice_id, null, 'Discount: ' || v_drec.type, v_amt, true);
      v_room := v_room - v_amt;
    end if;
  end loop;
end;
$$;

create or replace function public.fn_bill_student_month(
  p_enrollment_id uuid, p_period_month date, p_due_date date
) returns uuid language plpgsql security definer set search_path = public as $$
declare
  v_actor   uuid := auth.uid();
  v_enr     record;
  v_inv     uuid;
  v_arrears numeric;
  v_tuition numeric;
begin
  if not public.has_role('owner','principal','admin_clerk','accountant') then
    raise exception 'Not permitted to generate invoices';
  end if;
  perform public.assert_own('enrollments', p_enrollment_id);
  select e.id, e.student_id, e.session_id, e.class_id into v_enr
  from public.enrollments e where e.id = p_enrollment_id;
  if not found then raise exception 'Enrolment not found'; end if;

  select id into v_inv from public.invoices
   where enrollment_id = p_enrollment_id and period_month = p_period_month and status <> 'void'
   limit 1;
  if found then return v_inv; end if;

  v_arrears := public.student_balance(v_enr.student_id);
  begin
    insert into public.invoices(student_id, enrollment_id, session_id, period_month, status,
        arrears_brought_forward, due_date, issued_at, created_by)
    values (v_enr.student_id, v_enr.id, v_enr.session_id, p_period_month, 'issued',
        v_arrears, p_due_date, now(), v_actor)
    returning id into v_inv;
  exception when unique_violation then
    -- lost a race with a concurrent bill for the same (enrolment, month)
    select id into v_inv from public.invoices
     where enrollment_id = p_enrollment_id and period_month = p_period_month and status <> 'void' limit 1;
    return v_inv;
  end;

  insert into public.invoice_lines(invoice_id, fee_head_id, description, amount, is_discount)
  select v_inv, fh.id, fh.name, coalesce(sfi.amount, fs.amount), false
  from public.fee_structures fs
  join public.fee_heads fh on fh.id = fs.fee_head_id
  left join public.student_fee_items sfi
    on sfi.enrollment_id = v_enr.id and sfi.fee_head_id = fh.id and sfi.active
  where fs.session_id = v_enr.session_id and fs.class_id = v_enr.class_id
    and fh.is_recurring and fh.active;

  select coalesce(sum(amount), 0) into v_tuition
  from public.invoice_lines where invoice_id = v_inv and not is_discount;

  perform public.fn__apply_discount_lines(v_inv, v_enr.id, v_tuition);
  return v_inv;
end;
$$;

create or replace function public.fn_generate_class_invoices(
  p_session_id uuid, p_class_id uuid, p_period_month date, p_due_date date
) returns integer language plpgsql security definer set search_path = public as $$
declare
  v_actor uuid := auth.uid();
  v_enr   record;
  v_inv   uuid;
  v_count integer := 0;
  v_arrears numeric;
  v_tuition numeric;
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
      -- another run billed this (enrolment, month) concurrently — skip it
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
  end loop;

  return v_count;
end;
$$;

-- 3. Lock the pending row before verifying to serialize concurrent verifies.
create or replace function public.fn_verify_payment(p_payment_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_pay       record;
  v_remaining numeric;
  v_alloc     numeric;
  v_rec       record;
begin
  if not public.has_role('owner','principal','admin_clerk','accountant') then
    raise exception 'Not permitted to verify payments';
  end if;
  perform public.assert_own('payments', p_payment_id);
  select * into v_pay from public.payments where id = p_payment_id for update;
  if not found then raise exception 'Payment not found'; end if;
  if v_pay.status <> 'pending' then raise exception 'Only a pending payment can be verified'; end if;

  update public.payments set status = 'verified' where id = p_payment_id;

  v_remaining := v_pay.amount;
  for v_rec in
    select invoice_id, (charge - allocated) as outstanding
    from public.invoice_balances
    where student_id = v_pay.student_id and status in ('issued', 'partial') and (charge - allocated) > 0
    order by period_month nulls first, invoice_id
  loop
    exit when v_remaining <= 0;
    v_alloc := least(v_remaining, v_rec.outstanding);
    insert into public.payment_allocations(payment_id, invoice_id, amount)
    values (p_payment_id, v_rec.invoice_id, v_alloc);
    v_remaining := v_remaining - v_alloc;
    update public.invoices i set status = (case
      when (select allocated from public.invoice_balances b where b.invoice_id = i.id)
           >= (select charge from public.invoice_balances b where b.invoice_id = i.id)
      then 'paid' else 'partial' end)::public.invoice_status
    where i.id = v_rec.invoice_id;
  end loop;

  return jsonb_build_object('payment_id', p_payment_id,
    'allocated', v_pay.amount - v_remaining, 'unallocated', v_remaining);
end;
$$;

-- 5. Month-tests reads only RLS-public academic tables → SECURITY INVOKER.
create or replace function public.fn_student_month_tests(p_enrollment_id uuid, p_month date)
returns table(
  assessment_id uuid, title text, subject_name text, assessment_date date,
  max_marks numeric, marks numeric, is_absent boolean,
  class_avg numeric, class_count integer, pass_mark numeric, passed boolean
) language plpgsql stable security invoker set search_path = public as $$
declare
  v_first date := date_trunc('month', p_month)::date;
  v_last  date := (date_trunc('month', p_month) + interval '1 month - 1 day')::date;
  v_pass  numeric;
begin
  select pass_percent into v_pass from public.school_settings where school_id = public.current_school_id();
  v_pass := coalesce(v_pass, 33);

  return query
  select a.id, a.title, subj.name, a.assessment_date, a.max_marks,
         me.marks, coalesce(me.is_absent, false),
         (select round(avg(m2.marks), 1) from public.mark_entries m2
            where m2.assessment_id = a.id and not m2.is_absent and m2.marks is not null),
         (select count(*)::int from public.mark_entries m3
            where m3.assessment_id = a.id and not m3.is_absent and m3.marks is not null),
         round(a.max_marks * v_pass / 100.0, 2),
         case when coalesce(me.is_absent, false) or me.marks is null then false
              else me.marks >= a.max_marks * v_pass / 100.0 end
  from public.assessments a
  left join public.subjects subj on subj.id = a.subject_id
  join public.enrollments e on e.id = p_enrollment_id
  left join public.mark_entries me on me.assessment_id = a.id and me.enrollment_id = p_enrollment_id
  where a.session_id = e.session_id and a.class_id = e.class_id
    and a.assessment_date between v_first and v_last
    and (a.section_id is null or a.section_id = e.section_id)
  order by a.assessment_date nulls last, a.title;
end;
$$;

grant execute on function public.fn__apply_discount_lines(uuid, uuid, numeric) to authenticated;

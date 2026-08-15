-- =============================================================================
-- Fee month-ops (testing round 1) — everything the student-profile "Fees" tab
-- needs to behave like a simple month-by-month list while staying on the same
-- append-only, reconcilable ledger:
--   * fn_bill_student_month  — bill ONE student for ONE month on demand, so
--     "Mark paid" on an un-billed month never hits a dead end (safe: arrears is
--     a display snapshot, balance is derived — no double counting).
--   * Deferral ("Delay") as invoice metadata (deferred_until + reason). The
--     family STILL owes it; the reminder is paused, the reason is logged.
--   * Pending vs verified payments (bank challan "not yet cleared"): record as
--     pending (receipt logged, NOT counted, NOT allocated) → verify to count.
--   * fn_student_monthly_fee — the class default fee net of approved discount.
--   * fn_student_month_tests — this student's class tests in a month, with the
--     class average and pass/fail (pass = school pass_percent of the max).
-- =============================================================================

-- --- Deferral metadata + view refresh --------------------------------------
alter table public.invoices add column if not exists deferred_until date;
alter table public.invoices add column if not exists defer_reason text;

-- Re-create the balance view with the deferral columns appended (existing
-- columns unchanged/in order, so create-or-replace is allowed).
create or replace view public.invoice_balances with (security_invoker = true) as
select
  i.id            as invoice_id,
  i.student_id,
  i.enrollment_id,
  i.session_id,
  i.period_month,
  i.status,
  i.due_date,
  i.arrears_brought_forward,
  i.fine,
  coalesce((
    select sum(case when l.is_discount then -l.amount else l.amount end)
    from public.invoice_lines l where l.invoice_id = i.id
  ), 0) + i.fine as charge,
  coalesce((
    select sum(a.amount) from public.payment_allocations a where a.invoice_id = i.id
  ), 0) as allocated,
  i.deferred_until,
  i.defer_reason
from public.invoices i
where i.status <> 'void';

grant select on public.invoice_balances to authenticated;

-- --- Bill one student for one month ----------------------------------------
create or replace function public.fn_bill_student_month(
  p_enrollment_id uuid, p_period_month date, p_due_date date
) returns uuid language plpgsql security definer set search_path = public as $$
declare
  v_actor   uuid := auth.uid();
  v_enr     record;
  v_inv     uuid;
  v_arrears numeric;
  v_tuition numeric;
  v_drec    record;
begin
  if not public.has_role('owner','principal','admin_clerk','accountant') then
    raise exception 'Not permitted to generate invoices';
  end if;
  select e.id, e.student_id, e.session_id, e.class_id into v_enr
  from public.enrollments e where e.id = p_enrollment_id;
  if not found then raise exception 'Enrolment not found'; end if;

  select id into v_inv from public.invoices
   where enrollment_id = p_enrollment_id and period_month = p_period_month and status <> 'void'
   limit 1;
  if found then return v_inv; end if;

  v_arrears := public.student_balance(v_enr.student_id);
  insert into public.invoices(student_id, enrollment_id, session_id, period_month, status,
      arrears_brought_forward, due_date, issued_at, created_by)
  values (v_enr.student_id, v_enr.id, v_enr.session_id, p_period_month, 'issued',
      v_arrears, p_due_date, now(), v_actor)
  returning id into v_inv;

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

  for v_drec in
    select * from public.discounts d
    where d.enrollment_id = v_enr.id and d.status = 'approved'
  loop
    insert into public.invoice_lines(invoice_id, fee_head_id, description, amount, is_discount)
    values (
      v_inv, null, 'Discount: ' || v_drec.type,
      case when v_drec.is_percent then round(v_tuition * v_drec.amount / 100.0, 2) else v_drec.amount end,
      true);
  end loop;

  return v_inv;
end;
$$;

-- --- Payments: pending support (re-create with p_pending) ------------------
drop function if exists public.fn_record_payment(uuid, numeric, public.payment_method, text);
create or replace function public.fn_record_payment(
  p_student_id uuid, p_amount numeric, p_method public.payment_method,
  p_note text default null, p_pending boolean default false
) returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_actor     uuid := auth.uid();
  v_receipt   bigint;
  v_pay       uuid;
  v_remaining numeric := p_amount;
  v_alloc     numeric;
  v_rec       record;
begin
  if not public.has_role('owner','principal','admin_clerk','accountant') then
    raise exception 'Not permitted to record payments';
  end if;
  if p_amount is null or p_amount <= 0 then raise exception 'Amount must be positive'; end if;
  perform public.assert_own('students', p_student_id);

  v_receipt := public.next_counter('receipt');
  insert into public.payments(student_id, amount, method, receipt_no, status, received_by, note)
  values (p_student_id, p_amount, p_method, v_receipt,
          case when p_pending then 'pending' else 'verified' end, v_actor, p_note)
  returning id into v_pay;

  -- A pending payment (e.g. a bank challan not yet cleared) is logged with a
  -- receipt number but is NOT counted or allocated until it is verified.
  if p_pending then
    return jsonb_build_object('payment_id', v_pay, 'receipt_no', v_receipt,
      'allocated', 0, 'unallocated', p_amount, 'pending', true);
  end if;

  for v_rec in
    select invoice_id, (charge - allocated) as outstanding
    from public.invoice_balances
    where student_id = p_student_id and status in ('issued', 'partial') and (charge - allocated) > 0
    order by period_month nulls first, invoice_id
  loop
    exit when v_remaining <= 0;
    v_alloc := least(v_remaining, v_rec.outstanding);
    insert into public.payment_allocations(payment_id, invoice_id, amount)
    values (v_pay, v_rec.invoice_id, v_alloc);
    v_remaining := v_remaining - v_alloc;

    update public.invoices i set status = (case
      when (select allocated from public.invoice_balances b where b.invoice_id = i.id)
           >= (select charge from public.invoice_balances b where b.invoice_id = i.id)
      then 'paid' else 'partial' end)::public.invoice_status
    where i.id = v_rec.invoice_id;
  end loop;

  return jsonb_build_object(
    'payment_id', v_pay, 'receipt_no', v_receipt,
    'allocated', p_amount - v_remaining, 'unallocated', v_remaining, 'pending', false);
end;
$$;

-- Verify a pending payment → it now counts, and allocates FIFO to open months.
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
  select * into v_pay from public.payments where id = p_payment_id;
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

-- Cancel a pending payment that never cleared (bounced challan). It never
-- counted, so no reversing entry is needed — just mark it cancelled.
create or replace function public.fn_cancel_pending_payment(p_payment_id uuid, p_reason text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.has_role('owner','principal','admin_clerk','accountant') then
    raise exception 'Not permitted';
  end if;
  perform public.assert_own('payments', p_payment_id);
  update public.payments
     set status = 'cancelled',
         note = coalesce(note || ' · ', '') || 'Cancelled: '
                || coalesce(nullif(btrim(p_reason),''), 'no reason')
   where id = p_payment_id and status = 'pending';
  if not found then raise exception 'No pending payment to cancel'; end if;
end;
$$;

-- --- Deferral ("Delay") ----------------------------------------------------
create or replace function public.fn_defer_invoice(p_invoice_id uuid, p_until date, p_reason text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.has_role('owner','principal','admin_clerk','accountant') then
    raise exception 'Not permitted';
  end if;
  perform public.assert_own('invoices', p_invoice_id);
  update public.invoices
     set deferred_until = p_until,
         defer_reason = nullif(btrim(p_reason),''),
         notes = coalesce(notes || E'\n','') || 'Deferred'
                 || coalesce(' until ' || p_until::text, '')
                 || coalesce(': ' || nullif(btrim(p_reason),''), '')
   where id = p_invoice_id and status in ('issued','partial');
  if not found then raise exception 'Invoice not found, already settled, or void'; end if;
end;
$$;

create or replace function public.fn_undo_defer(p_invoice_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.has_role('owner','principal','admin_clerk','accountant') then
    raise exception 'Not permitted';
  end if;
  perform public.assert_own('invoices', p_invoice_id);
  update public.invoices set deferred_until = null, defer_reason = null where id = p_invoice_id;
  if not found then raise exception 'Invoice not found'; end if;
end;
$$;

-- --- Monthly fee for a student (class default net of approved discount) -----
create or replace function public.fn_student_monthly_fee(p_enrollment_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_enr   record;
  v_gross numeric := 0;
  v_disc  numeric := 0;
  v_drec  record;
begin
  if not public.has_role('owner','principal','admin_clerk','accountant') then
    raise exception 'Not permitted';
  end if;
  perform public.assert_own('enrollments', p_enrollment_id);
  select e.id, e.session_id, e.class_id into v_enr from public.enrollments e where e.id = p_enrollment_id;
  if not found then return jsonb_build_object('gross',0,'discount',0,'net',0); end if;

  select coalesce(sum(coalesce(sfi.amount, fs.amount)), 0) into v_gross
  from public.fee_structures fs
  join public.fee_heads fh on fh.id = fs.fee_head_id
  left join public.student_fee_items sfi
    on sfi.enrollment_id = v_enr.id and sfi.fee_head_id = fh.id and sfi.active
  where fs.session_id = v_enr.session_id and fs.class_id = v_enr.class_id
    and fh.is_recurring and fh.active;

  for v_drec in select * from public.discounts d
    where d.enrollment_id = v_enr.id and d.status = 'approved'
  loop
    v_disc := v_disc + case when v_drec.is_percent then round(v_gross * v_drec.amount / 100.0, 2) else v_drec.amount end;
  end loop;
  if v_disc > v_gross then v_disc := v_gross; end if;

  return jsonb_build_object('gross', v_gross, 'discount', v_disc, 'net', v_gross - v_disc);
end;
$$;

-- --- This student's class tests in a month ---------------------------------
create or replace function public.fn_student_month_tests(p_enrollment_id uuid, p_month date)
returns table(
  assessment_id uuid, title text, subject_name text, assessment_date date,
  max_marks numeric, marks numeric, is_absent boolean,
  class_avg numeric, class_count integer, pass_mark numeric, passed boolean
) language plpgsql stable security definer set search_path = public as $$
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

grant execute on function public.fn_bill_student_month(uuid, date, date) to authenticated;
grant execute on function public.fn_record_payment(uuid, numeric, public.payment_method, text, boolean) to authenticated;
grant execute on function public.fn_verify_payment(uuid) to authenticated;
grant execute on function public.fn_cancel_pending_payment(uuid, text) to authenticated;
grant execute on function public.fn_defer_invoice(uuid, date, text) to authenticated;
grant execute on function public.fn_undo_defer(uuid) to authenticated;
grant execute on function public.fn_student_monthly_fee(uuid) to authenticated;
grant execute on function public.fn_student_month_tests(uuid, date) to authenticated;

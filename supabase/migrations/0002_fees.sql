-- =============================================================================
-- Fees module — money logic as Postgres functions (transactional, server-side).
--
-- Balance model = running ledger (see docs/02-DATA-MODEL.md):
--   * An invoice holds a billing period's NEW charges (lines + fine).
--   * A student's balance is DERIVED, never stored:
--       balance = SUM(non-void invoice charges) − SUM(verified payments)
--     where a reversal is a negative-amount payment, so the cash ledger foots.
--   * `arrears_brought_forward` on an invoice is a DISPLAY snapshot of the
--     balance just before that invoice — it is NOT summed into the balance
--     (that would double-count).
-- All mutating functions are SECURITY DEFINER with an explicit role guard.
-- =============================================================================

-- Per-invoice charge/allocated view (security_invoker → caller's RLS applies).
create view public.invoice_balances with (security_invoker = true) as
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
  ), 0) as allocated
from public.invoices i
where i.status <> 'void';

-- Derived student balance (SECURITY INVOKER → RLS on underlying tables applies).
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
    - coalesce((
      select sum(p.amount) from public.payments p
      where p.student_id = p_student_id and p.status = 'verified'
    ), 0);
$$;

-- Generate monthly challans for a class: recurring heads + approved discounts,
-- with the current balance snapshotted as arrears_brought_forward. Idempotent
-- per (enrollment, period_month) — re-running does not duplicate.
create or replace function public.fn_generate_class_invoices(
  p_session_id uuid, p_class_id uuid, p_period_month date, p_due_date date
) returns integer language plpgsql security definer set search_path = public as $$
declare
  v_actor uuid := auth.uid();
  v_enr   record;
  v_drec  record;
  v_inv   uuid;
  v_count integer := 0;
  v_arrears numeric;
  v_tuition numeric;
begin
  if not public.has_role('owner', 'principal', 'admin_clerk', 'accountant') then
    raise exception 'Not permitted to generate invoices';
  end if;

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

    insert into public.invoices(
      student_id, enrollment_id, session_id, period_month, status,
      arrears_brought_forward, due_date, issued_at, created_by)
    values (
      v_enr.student_id, v_enr.enrollment_id, p_session_id, p_period_month, 'issued',
      v_arrears, p_due_date, now(), v_actor)
    returning id into v_inv;

    -- recurring fee-head lines (per-student override wins over class structure)
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

    -- approved discounts as negative lines
    for v_drec in
      select * from public.discounts d
      where d.enrollment_id = v_enr.enrollment_id and d.status = 'approved'
    loop
      insert into public.invoice_lines(invoice_id, fee_head_id, description, amount, is_discount)
      values (
        v_inv, null, 'Discount: ' || v_drec.type,
        case when v_drec.is_percent then round(v_tuition * v_drec.amount / 100.0, 2) else v_drec.amount end,
        true);
    end loop;

    v_count := v_count + 1;
  end loop;

  return v_count;
end;
$$;

-- Record a payment: gapless receipt number, then FIFO-allocate to oldest
-- unpaid invoices and update their status. Leftover is left as credit.
create or replace function public.fn_record_payment(
  p_student_id uuid, p_amount numeric, p_method public.payment_method, p_note text default null
) returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_actor    uuid := auth.uid();
  v_receipt  bigint;
  v_pay      uuid;
  v_remaining numeric := p_amount;
  v_alloc    numeric;
  v_rec      record;
begin
  if not public.has_role('owner', 'principal', 'admin_clerk', 'accountant') then
    raise exception 'Not permitted to record payments';
  end if;
  if p_amount is null or p_amount <= 0 then
    raise exception 'Amount must be positive';
  end if;

  v_receipt := public.next_counter('receipt');
  insert into public.payments(student_id, amount, method, receipt_no, status, received_by, note)
  values (p_student_id, p_amount, p_method, v_receipt, 'verified', v_actor, p_note)
  returning id into v_pay;

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
    'allocated', p_amount - v_remaining, 'unallocated', v_remaining);
end;
$$;

-- Reverse a payment by a linked negative entry (never edit/delete the original).
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
  select * into v_orig from public.payments where id = p_payment_id;
  if not found then raise exception 'Payment not found'; end if;
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

-- Defaulters for a session: active students with a positive balance, biggest first.
create or replace function public.fn_defaulters(p_session_id uuid)
returns table(
  student_id uuid, gr_no text, full_name text,
  class_name text, section_name text, roll_no text, balance numeric)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.has_role('owner', 'principal', 'admin_clerk', 'accountant') then
    raise exception 'Not permitted';
  end if;
  return query
    select s.id, s.gr_no, s.full_name, c.name, sec.name, e.roll_no, public.student_balance(s.id)
    from public.enrollments e
    join public.students s on s.id = e.student_id
    join public.classes c on c.id = e.class_id
    left join public.sections sec on sec.id = e.section_id
    where e.session_id = p_session_id and e.status = 'active' and public.student_balance(s.id) > 0
    order by public.student_balance(s.id) desc;
end;
$$;

grant select on public.invoice_balances to authenticated;
grant execute on function public.student_balance(uuid) to authenticated;
grant execute on function public.fn_generate_class_invoices(uuid, uuid, date, date) to authenticated;
grant execute on function public.fn_record_payment(uuid, numeric, public.payment_method, text) to authenticated;
grant execute on function public.fn_reverse_payment(uuid, text) to authenticated;
grant execute on function public.fn_defaulters(uuid) to authenticated;

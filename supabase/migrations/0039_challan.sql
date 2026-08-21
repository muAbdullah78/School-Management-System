-- =============================================================================
-- 0039 — The printed fee challan.
--
-- WHY THIS DID NOT EXIST, AND WHY THAT WAS THE WORST GAP IN THE PRODUCT
--
-- In a Pakistani school the challan IS the product. The parent is handed a
-- slip, takes it to the bank, the bank stamps it, one copy comes back to the
-- school. Everything else the software does hangs off that piece of paper.
--
-- We shipped none of it:
--
--   * fn_generate_class_invoices bulk-bills a class and returns a COUNT. It
--     returns no invoice ids and links to no print view.
--   * No function anywhere lists a class's invoices for a month, so there was
--     nothing to print even if a screen had existed.
--   * invoices.voucher_code is stamped by a trigger on every insert and is
--     never selected or rendered anywhere — so the scannable code existed in
--     the database and on no piece of paper.
--   * docs/03-FEATURES.md line 25 promises "monthly challan generation in
--     bank-payable 3-part format". Grep for 3-part, counterfoil, bank copy:
--     nothing. And docs/STATUS.md's "Known gaps, stated plainly" did not
--     mention it, so the documentation claimed a feature AND hid its absence.
--
-- The only fee printable in the whole product was a single-student receipt,
-- issued after payment — the opposite end of the transaction.
--
-- WHAT THE NUMBERS ON THE SLIP MEAN
--
-- invoices.arrears_brought_forward is a DISPLAY SNAPSHOT of the student's
-- balance at the moment the challan was generated (0002 says so explicitly). It
-- is deliberately NOT part of the ledger — student_balance() ignores it,
-- because the earlier unpaid invoices already carry that money.
--
-- Printing that snapshot would be wrong: a parent who paid last month's dues
-- on the 3rd would still be handed a slip demanding them on the 5th. So this
-- computes previous dues LIVE:
--
--      this_month     = this invoice's lines + its fine
--      already_paid   = verified allocations against this invoice
--      this_month_due = this_month - already_paid
--      total_payable  = student_balance(student)        -- live, everything
--      previous_dues  = total_payable - this_month_due
--
-- which makes total_payable exactly what the parent owes today, and makes the
-- two halves add up to it. The snapshot is returned as well, under a name that
-- says what it is, so a reprint can be compared against the original.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. One challan.
--
-- Returns everything the paper needs in a single object so the print view does
-- no arithmetic. Print views that compute totals are how a slip ends up
-- disagreeing with the ledger.
-- ---------------------------------------------------------------------------
create or replace function public.fn_challan(p_invoice_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_inv     record;
  v_lines   jsonb;
  v_charge  numeric;
  v_paid    numeric;
  v_this    numeric;
  v_total   numeric;
begin
  if not public.is_staff() then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  perform public.assert_own('invoices', p_invoice_id);

  select i.id, i.student_id, i.period_month, i.due_date, i.fine, i.voucher_code,
         i.arrears_brought_forward, i.status, i.notes,
         s.full_name, s.gr_no, s.father_name, s.phone, s.whatsapp,
         f.head_name as family_head, f.head_cnic as family_cnic,
         c.name as class_name, sec.name as section_name, e.roll_no
    into v_inv
  from public.invoices i
  join public.students s   on s.id = i.student_id
  left join public.families f on f.id = s.family_id
  left join public.enrollments e on e.id = i.enrollment_id
  left join public.classes c   on c.id = e.class_id
  left join public.sections sec on sec.id = e.section_id
  where i.id = p_invoice_id;

  if not found then
    raise exception 'No such challan' using errcode = '42704';
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'description', l.description,
           'amount',      l.amount,
           'is_discount', l.is_discount) order by l.is_discount, l.description), '[]'::jsonb)
    into v_lines
  from public.invoice_lines l where l.invoice_id = p_invoice_id;

  select coalesce(sum(case when l.is_discount then -l.amount else l.amount end), 0)
    into v_charge
  from public.invoice_lines l where l.invoice_id = p_invoice_id;
  v_charge := v_charge + coalesce(v_inv.fine, 0);

  select coalesce(sum(al.amount), 0) into v_paid
  from public.payment_allocations al
  join public.payments p on p.id = al.payment_id
  where al.invoice_id = p_invoice_id and p.status = 'verified';

  v_this  := v_charge - v_paid;
  v_total := public.student_balance(v_inv.student_id);

  return jsonb_build_object(
    'invoice_id',     v_inv.id,
    'voucher_code',   v_inv.voucher_code,
    'status',         v_inv.status,
    'period_month',   v_inv.period_month,
    'period_label',   coalesce(to_char(v_inv.period_month, 'FMMonth YYYY'),
                               coalesce(v_inv.notes, 'One-off charge')),
    'due_date',       v_inv.due_date,
    'student_id',     v_inv.student_id,
    'student_name',   v_inv.full_name,
    'gr_no',          v_inv.gr_no,
    'roll_no',        v_inv.roll_no,
    'father_name',    v_inv.father_name,
    'family_head',    v_inv.family_head,
    'family_cnic',    v_inv.family_cnic,
    'phone',          coalesce(v_inv.whatsapp, v_inv.phone),
    'class_name',     v_inv.class_name,
    'section_name',   v_inv.section_name,
    'lines',          v_lines,
    'fine',           coalesce(v_inv.fine, 0),
    'this_month',     v_charge,
    'already_paid',   v_paid,
    'this_month_due', v_this,
    -- Live, so a parent who has paid since generation is not asked twice.
    'previous_dues',  v_total - v_this,
    'total_payable',  v_total,
    -- The stale figure, named as such, for comparing a reprint with the original.
    'arrears_snapshot_at_generation', v_inv.arrears_brought_forward);
end;
$$;

-- ---------------------------------------------------------------------------
-- 2. A whole class's challans, for the batch print.
--
-- p_section_id null means every section of the class — the common case, since a
-- clerk prints "Class 5" and hands the stack to the class teacher to give out.
--
-- Voided invoices are excluded: a challan that was cancelled must not come out
-- of the printer, and a clerk who is handed one will collect against it.
--
-- Ordered by roll number the way a class register is, so the printed stack can
-- be handed out down the row without sorting. Roll numbers are text in this
-- schema and "10" sorts before "2" as text, so it is cast for the sort only.
-- ---------------------------------------------------------------------------
create or replace function public.fn_challans_for_class(
  p_session_id uuid,
  p_class_id   uuid,
  p_section_id uuid,
  p_period_month date
) returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_out jsonb;
begin
  if not public.is_staff() then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  perform public.assert_own('academic_sessions', p_session_id);
  perform public.assert_own('classes', p_class_id);
  perform public.assert_own('sections', p_section_id);

  select coalesce(jsonb_agg(public.fn_challan(x.id) order by x.sort_roll, x.full_name), '[]'::jsonb)
    into v_out
  from (
    select i.id,
           s.full_name,
           coalesce(nullif(regexp_replace(coalesce(e.roll_no, ''), '[^0-9]', '', 'g'), '')::int, 999999)
             as sort_roll
    from public.invoices i
    join public.enrollments e on e.id = i.enrollment_id
    join public.students s    on s.id = i.student_id
    where i.school_id = public.current_school_id()
      and i.session_id = p_session_id
      and e.class_id = p_class_id
      and (p_section_id is null or e.section_id = p_section_id)
      and i.period_month = p_period_month
      and i.status <> 'void'
      and s.deleted_at is null
  ) x;

  return v_out;
end;
$$;

-- ---------------------------------------------------------------------------
-- 3. Which months have challans, so the print screen can offer real choices.
--
-- Without this the clerk picks a month from a date input and finds out whether
-- anything was generated for it only after pressing Print. Offering the months
-- that exist, with a count, is the difference between a screen that works and
-- one that guesses.
-- ---------------------------------------------------------------------------
create or replace function public.fn_challan_months(p_session_id uuid, p_class_id uuid)
returns table (period_month date, challans integer, unpaid integer)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_staff() then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  perform public.assert_own('academic_sessions', p_session_id);
  perform public.assert_own('classes', p_class_id);

  return query
  select i.period_month,
         count(*)::int,
         count(*) filter (where (
           coalesce((select sum(case when l.is_discount then -l.amount else l.amount end)
                       from public.invoice_lines l where l.invoice_id = i.id), 0)
           + coalesce(i.fine, 0)
           - coalesce((select sum(al.amount)
                         from public.payment_allocations al
                         join public.payments p on p.id = al.payment_id
                        where al.invoice_id = i.id and p.status = 'verified'), 0)
         ) > 0)::int
  from public.invoices i
  join public.enrollments e on e.id = i.enrollment_id
  where i.school_id = public.current_school_id()
    and i.session_id = p_session_id
    and e.class_id = p_class_id
    and i.period_month is not null
    and i.status <> 'void'
  group by i.period_month
  order by i.period_month desc;
end;
$$;

-- ---------------------------------------------------------------------------
-- 4. Grants. All three are staff-gated in the body, so a parent calling them
-- directly gets 42501 rather than a class's fee data.
-- ---------------------------------------------------------------------------
grant execute on function public.fn_challan(uuid)                             to authenticated;
grant execute on function public.fn_challans_for_class(uuid, uuid, uuid, date) to authenticated;
grant execute on function public.fn_challan_months(uuid, uuid)                to authenticated;

revoke all on function public.fn_challan(uuid)                             from anon;
revoke all on function public.fn_challans_for_class(uuid, uuid, uuid, date) from anon;
revoke all on function public.fn_challan_months(uuid, uuid)                from anon;

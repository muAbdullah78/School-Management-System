-- =============================================================================
-- REPAIR: migration 0045_balance_sheet, on its own.
--
-- Run supabase/repair/detect.sql FIRST. Run only the files it marks MISSING,
-- in ascending order. Then re-run 5_search.sql, then verify.sql.
--
-- WHY 5_search AFTERWARDS IS NOT OPTIONAL: migrations 0050-0056 replace some of
-- the functions these files define with newer versions. Applying an older file
-- now puts the OLD version back until bundle 5 restores it. Concretely: 0038
-- defines fn_recent_payments and 0052 fixes its ordering, so applying 0038
-- without re-running bundle 5 reintroduces a payment list that reshuffles
-- itself between page loads.
--
-- One file per migration, because a single concatenated repair CANNOT work:
-- different schools stopped at different points inside bundle 3, so any fixed
-- starting migration is already applied for somebody and fails on its first
-- statement. That is exactly what happened with the first version of this.
-- =============================================================================

-- =============================================================================
-- 0045 — The balance sheet, as at a date.
--
-- The last of their eight missing money reports, and the only one that could
-- not be served by filtering the ledger — because it is not a RANGE, it is a
-- position AS AT one day. "What did the school stand at on 30 June?" is a
-- different question from "what happened in June?", and answering it with a
-- range is how a year-end figure ends up wrong.
--
-- WHY THIS IS HARDER THAN IT LOOKS
--
-- student_balance() gives the CURRENT balance. It cannot answer "what was owed
-- on 30 June?", because it counts every charge and every payment regardless of
-- date. So this reconstructs the position from the dated rows:
--
--   receivable  = charges on invoices ISSUED on or before the date
--                 + fines on those
--                 + adjustments made on or before the date
--                 − allocations from payments TAKEN on or before the date
--
--   advance     = verified payments taken on or before the date
--                 − everything those payments have been allocated to,
--                 counting only allocations against invoices issued by then
--
--   cash moved  = verified receipts + other income − expenses, all up to the
--                 date, from the beginning
--
-- The awkward term is `advance`. A payment can be allocated to an invoice
-- issued AFTER the as-at date — a parent paying August's fee in July. On 31
-- July that money is an advance the school is holding, not income against a
-- charge that does not exist yet, so the allocation is excluded by the
-- invoice's issue date rather than the payment's. Getting that wrong makes a
-- school with advance fees look like it has no liability.
--
-- WHAT THIS IS NOT
--
-- Not double-entry bookkeeping. There is no chart of accounts, no bank
-- reconciliation and no fixed assets, because none of that exists in this
-- schema and inventing it would be worse than omitting it. It is the four
-- figures a Pakistani school principal actually asks for: what we are owed,
-- what we are holding for parents, what has come in, what has gone out.
-- =============================================================================

create or replace function public.fn_report_balance_sheet(p_as_at date)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_school     uuid := public.current_school_id();
  v_as_at      date := coalesce(p_as_at, current_date);
  v_charges    numeric;
  v_fines      numeric;
  v_adjust     numeric;
  v_allocated  numeric;
  v_receivable numeric;
  v_from_off   numeric;
  v_receipts   numeric;
  v_other_in   numeric;
  v_expenses   numeric;
  v_advance    numeric;
  v_students   int;
  v_owing      int;
begin
  if not public.has_role('owner', 'principal', 'accountant') then
    raise exception 'Not permitted to read the accounts' using errcode = '42501';
  end if;

  -- ---- the position, reconstructed one student at a time ----
  --
  -- Done PER STUDENT rather than as four school-wide sums, for one reason: the
  -- headcount of who owes money and the total owed must come out of the same
  -- arithmetic. The first cut of this function summed the money as-at but took
  -- the headcount from student_balance(), which is a CURRENT figure — so a
  -- balance sheet as at a date before the school billed anything reported
  -- "receivable 0, students owing 1". A statement that contradicts itself in
  -- two adjacent numbers is worse than no statement.
  --
  -- Grouping allocations by the INVOICE's student, not the payment's, is also
  -- what makes family payments land on the right child: a payment row for a
  -- family has no student_id at all.
  with inv as (
    -- issued_at, not created_at: a challan prepared on the 28th and issued on
    -- the 1st is not a receivable on the 30th.
    select i.id, i.student_id, i.status, coalesce(i.fine, 0) as fine
    from public.invoices i
    where i.school_id = v_school
      and coalesce(i.issued_at::date, i.created_at::date) <= v_as_at
  ),
  charge as (
    select v.student_id,
           sum(case when l.is_discount then -l.amount else l.amount end) as amt
    from inv v
    join public.invoice_lines l on l.invoice_id = v.id
    where v.status <> 'void'
    group by 1
  ),
  fine as (
    select v.student_id, sum(v.fine) as amt
    from inv v where v.status <> 'void' group by 1
  ),
  adj as (
    select a.student_id, sum(a.amount) as amt
    from public.adjustments a
    where a.school_id = v_school and a.created_at::date <= v_as_at
    group by 1
  ),
  alloc as (
    -- `inv` is already filtered to invoices ISSUED by the as-at date, and that
    -- is the subtle part of the whole report: an allocation against an invoice
    -- issued AFTER the date is a parent paying next month early. On this date
    -- that money is an advance the school is holding, not a settled charge.
    --
    -- Note there is deliberately no `status <> 'void'` here, even though the
    -- charge sums have it. student_balance() omits it too, and the two must
    -- agree — a clerk checking this against a student ledger has to see the
    -- same money. Nothing in this schema ever sets an invoice to 'void' today
    -- (there is no void function), so the case is unreachable; aligning now is
    -- what stops the two screens diverging if one is ever added.
    select v.student_id, sum(al.amount) as amt
    from public.payment_allocations al
    join inv v on v.id = al.invoice_id
    join public.payments p on p.id = al.payment_id
    where p.school_id = v_school
      and p.status = 'verified'
      and p.created_at::date <= v_as_at
    group by 1
  ),
  per_student as (
    -- Every student the school has ever had, not just those on the roll: a
    -- withdrawn child's unpaid arrears are still money owed to the school, and
    -- dropping them would quietly shrink the receivable.
    select s.id,
           coalesce(c.amt, 0)  as charges,
           coalesce(f.amt, 0)  as fines,
           coalesce(j.amt, 0)  as adjust,
           coalesce(al.amt, 0) as allocated,
           coalesce(c.amt, 0) + coalesce(f.amt, 0) + coalesce(j.amt, 0)
             - coalesce(al.amt, 0) as bal,
           -- On the roll AS AT the date. admission_date is a real date, so
           -- "had they joined yet" is answerable; `status` however has no
           -- history, so a child who has since left is counted as off-roll
           -- even for a date when they were present. Stated in `basis`.
           (coalesce(s.admission_date, s.created_at::date) <= v_as_at
            and (s.deleted_at is null or s.deleted_at::date > v_as_at)
            and s.status = 'active') as on_roll
    from public.students s
    left join charge c  on c.student_id  = s.id
    left join fine   f  on f.student_id  = s.id
    left join adj    j  on j.student_id  = s.id
    left join alloc  al on al.student_id = s.id
    where s.school_id = v_school
  )
  select coalesce(sum(charges), 0),
         coalesce(sum(fines), 0),
         coalesce(sum(adjust), 0),
         coalesce(sum(allocated), 0),
         coalesce(sum(bal), 0),
         coalesce(sum(bal) filter (where bal > 0 and not on_roll), 0),
         count(*) filter (where on_roll),
         count(*) filter (where bal > 0 and on_roll)
    into v_charges, v_fines, v_adjust, v_allocated,
         v_receivable, v_from_off, v_students, v_owing
  from per_student;

  -- ---- cash movement from the beginning up to the date ----
  select coalesce(sum(p.amount), 0) into v_receipts
  from public.payments p
  where p.school_id = v_school
    and p.status = 'verified'
    and p.created_at::date <= v_as_at;

  select coalesce(sum(oi.amount), 0) into v_other_in
  from public.other_income oi
  where oi.school_id = v_school and oi.received_on <= v_as_at;

  select coalesce(sum(e.amount), 0) into v_expenses
  from public.expenses e
  where e.school_id = v_school and e.spent_on <= v_as_at;

  -- ---- money held that is not against a charge yet ----
  v_advance := v_receipts - v_allocated;
  -- Cannot be negative: if allocations somehow exceed receipts the honest thing
  -- is to show zero advance and let the receivable carry the difference, rather
  -- than print a negative liability nobody can interpret.
  if v_advance < 0 then v_advance := 0; end if;

  return jsonb_build_object(
    'as_at',              v_as_at,
    -- Assets side
    'receivable',         v_receivable,
    'cash_in',            v_receipts + v_other_in,
    'cash_out',           v_expenses,
    'cash_position',      v_receipts + v_other_in - v_expenses,
    -- Liability side
    'advance_held',       v_advance,
    -- Context, so the figures can be sanity-checked at a glance
    'fee_receipts',       v_receipts,
    'other_income',       v_other_in,
    'charges_raised',     v_charges + v_fines + v_adjust,
    'allocated',          v_allocated,
    -- Named separately rather than hidden inside `receivable`, because the
    -- headcount below excludes these children and a principal comparing the
    -- two would otherwise be looking at an unexplained gap. Schools here do
    -- chase leavers' arrears, so it is a figure they want, not a footnote.
    'receivable_off_roll', v_from_off,
    'students_on_roll',   v_students,
    'students_owing',     v_owing,
    -- Stated in the payload rather than only in a comment, because a reader of
    -- the raw JSON deserves to know what it does not include.
    'basis',             'Cumulative from the first record up to the as-at date. '
                      || 'Receivable counts charges on invoices ISSUED by that date, less '
                      || 'payments taken by that date against those invoices, for every '
                      || 'student the school has ever had. Money paid early for a later '
                      || 'month is shown as advance held, not as income. Roll counts use '
                      || 'the student''s CURRENT status, which is not kept historically, '
                      || 'so a child who has since left is counted off-roll even for a '
                      || 'date when they were present; their arrears still appear in '
                      || 'receivable. Not double-entry: no chart of accounts, no bank '
                      || 'reconciliation, no fixed assets.');
end;
$$;

grant execute on function public.fn_report_balance_sheet(date) to authenticated;
revoke all on function public.fn_report_balance_sheet(date) from anon;

-- =============================================================================
-- GENERATED FILE — DO NOT EDIT.
-- Built from supabase/migrations/ by supabase/build-bundles.sh
--
-- Paste this whole file into the Supabase SQL Editor and press Run.
-- Run the bundles in order, one at a time, waiting for each to finish.
-- =============================================================================


-- ─────────────────────────────────────────────────────────────────────────
-- 0098_one_number.sql
-- ─────────────────────────────────────────────────────────────────────────
-- =============================================================================
-- 0098 — One number for what a family owes, and the workings behind it
--
-- HOW THIS WAS FOUND
--
-- Not by reading. By seeding one school with a deliberately awkward child --
-- a Rs 500 sibling discount, a Rs 100 late fine, a Rs 250 manual charge for the
-- van, a part payment, a cancelled challan and a deferred one -- and then
-- asking every screen in the application the same question on the same second.
--
--   Dashboard, "Outstanding"                   Rs 8,350
--   Balance sheet, "Receivable"                Rs 8,350
--   Defaulters list, summed                    Rs 8,350
--   Fees > Reconciliation, "Outstanding"       Rs 8,100
--   Reports > Unpaid challans, summed          Rs 8,100
--   Reports > Dues by fee head, charged-paid   Rs 8,062.50
--
-- Three answers to one question, on six screens, none of them labelled as
-- answering a different question. An owner who opens two of these in one
-- morning has no way to tell which is wrong, and the honest conclusion for them
-- to draw is that all of it is.
--
-- THE THREE CAUSES, EACH DIFFERENT
--
-- 1. ADJUSTMENTS ARE WRITE-ONLY. `fn_add_adjustment` records a manual charge or
--    a waiver against a student, with a reason and an approver. It is counted by
--    `student_balance` and therefore by the dashboard, the defaulters list, the
--    balance sheet and the certificate dues gate -- and it is displayed by
--    NOTHING. Not the student's fee tab, not the parent portal, not one report.
--
--    That is worse than an inconsistency, it is the oldest fee-office fraud with
--    the evidence switched off. "Waive outstanding" on the student profile
--    writes a negative adjustment for the whole balance; the family's dues go to
--    zero and the only trace is a row no screen in the product can read. The
--    fix is not to remove the waiver -- schools genuinely waive fees -- it is to
--    make every entry that moves a balance visible on the child's own page.
--
--    It is also why the parent portal showed a child owing Rs 2,350 above two
--    challans totalling Rs 2,100. A parent cannot reconcile that, and will
--    reasonably conclude the school is adding money on quietly.
--
-- 2. DUES BY FEE HEAD DROPPED THE FINE AND THEN MISCOUNTED THE PAYMENT. It sums
--    invoice LINES per head, but a fine lives on `invoices.fine`, not on a line.
--    So the fine vanished from "charged" -- while remaining in the denominator
--    of the apportionment that splits a payment across heads. The result was
--    both a missing charge and a systematically understated collection for every
--    invoice carrying a fine: Rs 1,000 taken at the counter appeared in the
--    report as Rs 937.50, and the missing Rs 62.50 was in no row of it.
--
-- 3. RECONCILIATION AND UNPAID CHALLANS ARE INVOICE-BASIS, AND THAT IS CORRECT.
--    "Did we bill Class 5 properly, and how much of it came in?" is a question
--    about challans, and adjustments are not challans. The defect was never the
--    basis, it was presenting an invoice-basis total on a screen headed
--    "Outstanding" beside a dashboard that means something else by the same
--    word. So this does not force them to agree -- it makes each say what it
--    counts and prints the bridge between them.
--
-- WHAT THIS MIGRATION DOES
--
--   1. `invoice_balances.allocated` counts VERIFIED payments only, matching
--      `student_balance`.
--   2. `fn_student_ledger` -- every entry that moved a child's balance, in date
--      order, with a running total that closes on `student_balance` exactly.
--   3. `fn_portal_child_ledger` -- the same statement for the parent, off the
--      same implementation, so the two can never drift apart.
--   4. `fn_portal_child_fees` gains the adjustments, so the parent's balance
--      adds up on the page they are already looking at.
--   5. `fn_head_wise_dues` -- the fine becomes a head of its own, and the totals
--      are computed once rather than summed from the apportioned rows.
--   6. `fn_fee_reconciliation` -- an explicit bridge from the invoice basis to
--      the figure on the dashboard.
--
-- supabase/tests/one_number.sql asks every one of those screens the same
-- question and fails if any two of them answer differently.
--
-- Re-runnable.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. A payment counts when it is verified, on both sides of the wall
--
-- `student_balance` subtracts allocations whose payment is verified.
-- `invoice_balances.allocated` subtracted every allocation, verified or not.
--
-- Today nothing can tell the difference: `fn_record_payment` returns before
-- allocating when the payment is pending, and only `fn_verify_payment`
-- allocates afterwards, so an allocation belonging to an unverified payment
-- cannot exist. This is therefore not a bug fix, it is closing the gap that
-- would turn the next change to the payment flow into one. Two definitions of
-- "paid", one of which is right by accident, is how the six numbers above
-- happened in the first place.
--
-- Column names, types and order are unchanged, which is what create-or-replace
-- on a view requires.
-- ---------------------------------------------------------------------------
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
    select sum(a.amount)
    from public.payment_allocations a
    join public.payments p on p.id = a.payment_id
    where a.invoice_id = i.id and p.status = 'verified'
  ), 0) as allocated,
  i.deferred_until,
  i.defer_reason
from public.invoices i
where i.status <> 'void';

grant select on public.invoice_balances to authenticated;

-- ---------------------------------------------------------------------------
-- 2. The statement: every entry that moved this child's balance
--
-- `student_balance` is four sums added together. This returns the individual
-- rows behind those four sums, in the order they happened, with a running
-- total. The last row's running total IS `student_balance`, by construction
-- rather than by coincidence, and supabase/tests/one_number.sql asserts it for
-- every student in a fixture built to be awkward.
--
-- SECURITY DEFINER with NO permission check, prefixed `fn__`, and revoked from
-- every client role. It is the shared implementation; the two callers below
-- carry the gates. Splitting it this way is the same decision as 0097's
-- attendance rule: a school and a parent looking at the same child must be
-- looking at the same arithmetic, and the only way to guarantee that is for
-- there to be one copy of it.
--
-- WHY `entry_on` IS A DATE AND NOT A TIMESTAMP
--
-- The rows come from four tables with four different notions of when. An
-- invoice line has no time of its own, so it inherits the challan's issue date;
-- an adjustment has `created_at`; an allocation takes the payment's. Mixing
-- second-accurate and date-only entries on one page invites a reader to trust
-- an order that is not real, so everything is a date and the tie-break is by
-- KIND: on any given day a charge is listed before the payment that settles it,
-- because that is the order they happened in even when the clock says otherwise.
--
-- `seq` is the row's position in statement order, so "the closing balance" is
-- the row with the highest seq rather than whatever a re-sort happens to leave
-- last. A caller that re-orders the rows can still find the bottom line, and the
-- browser has a stable key that does not depend on the contents of the row.
--
-- A VOID CHALLAN IS EXCLUDED, ITS FINE AND LINES WITH IT. 0087 refuses to
-- cancel a challan carrying money, so there is never a stranded allocation to
-- account for.
--
-- EVERY BRANCH CARRIES ITS OWN `school_id` FILTER, even though both callers
-- have already established that the child belongs to the caller. dashboard.sql
-- assertion 20 objected to the first version of this function for exactly that
-- reason and it was right to: 0042's leak was three unscoped queries sheltering
-- behind a function that scoped everywhere else, and "the gate is upstream" is
-- a property of today's callers rather than of this function.
-- ---------------------------------------------------------------------------
create or replace function public.fn__student_ledger(p_student_id uuid)
returns table (
  seq           bigint,
  entry_on      date,
  kind          text,
  particulars   text,
  reference     text,
  debit         numeric,
  credit        numeric,
  balance_after numeric,
  recorded_by   text
) language sql stable security definer set search_path = public as $$
  with entries as (
    -- The charge lines of every live challan
    select coalesce(i.issued_at::date, i.created_at::date) as entry_on,
           'charge'::text as kind,
           coalesce(l.description, 'Fee')
             || coalesce(' for ' || to_char(i.period_month, 'Mon YYYY'), '') as particulars,
           coalesce(i.voucher_code, '') as reference,
           l.amount as debit, 0::numeric as credit,
           1 as rank,
           i.created_by as actor
    from public.invoices i
    join public.invoice_lines l on l.invoice_id = i.id
    where i.student_id = p_student_id and i.school_id = public.current_school_id()
      and i.status <> 'void' and not l.is_discount

    union all

    -- and the discount lines of the same challans, shown as the reduction they
    -- are rather than folded into the charge above. A parent who was granted a
    -- sibling discount should be able to see it every month.
    select coalesce(i.issued_at::date, i.created_at::date),
           'discount',
           coalesce(l.description, 'Discount')
             || coalesce(' for ' || to_char(i.period_month, 'Mon YYYY'), ''),
           coalesce(i.voucher_code, ''),
           0, l.amount,
           2,
           i.created_by
    from public.invoices i
    join public.invoice_lines l on l.invoice_id = i.id
    where i.student_id = p_student_id and i.school_id = public.current_school_id()
      and i.status <> 'void' and l.is_discount

    union all

    -- The fine, which is on the challan rather than on a line of it. This is
    -- the row Dues by Fee Head was missing.
    select coalesce(i.issued_at::date, i.created_at::date),
           'fine',
           'Late fee' || coalesce(' for ' || to_char(i.period_month, 'Mon YYYY'), ''),
           coalesce(i.voucher_code, ''),
           i.fine, 0,
           3,
           i.created_by
    from public.invoices i
    where i.student_id = p_student_id and i.school_id = public.current_school_id()
      and i.status <> 'void' and coalesce(i.fine, 0) <> 0

    union all

    -- Manual charges and waivers. Until this migration these existed only
    -- inside the balance.
    select a.created_at::date,
           'adjustment',
           coalesce(nullif(btrim(a.reason), ''), 'Adjustment'),
           '',
           case when a.amount > 0 then a.amount else 0 end,
           case when a.amount < 0 then -a.amount else 0 end,
           4,
           a.created_by
    from public.adjustments a
    where a.student_id = p_student_id and a.school_id = public.current_school_id()

    union all

    -- Money received, attributed to the child whose challan it settled. A
    -- family payment has no student_id of its own, so the invoice is what says
    -- which child it belongs to.
    select p.created_at::date,
           'payment',
           case when p.amount < 0 then 'Payment reversed' else 'Payment received' end
             || coalesce(' for ' || to_char(i.period_month, 'Mon YYYY'), ''),
           coalesce('#' || p.receipt_no::text, ''),
           0, al.amount,
           5,
           p.received_by
    from public.payment_allocations al
    join public.invoices i on i.id = al.invoice_id
    join public.payments p on p.id = al.payment_id
    where i.student_id = p_student_id
      and i.school_id = public.current_school_id()
      and p.school_id = public.current_school_id()
      and p.status = 'verified'
  )
  select row_number() over w as seq,
         e.entry_on, e.kind, e.particulars, e.reference, e.debit, e.credit,
         sum(e.debit - e.credit) over (
           w rows between unbounded preceding and current row
         ) as balance_after,
         coalesce(pr.full_name, '') as recorded_by
  from entries e
  left join public.profiles pr on pr.id = e.actor
  window w as (order by e.entry_on, e.rank, e.particulars, e.reference)
  order by seq;
$$;

revoke all on function public.fn__student_ledger(uuid) from public, anon, authenticated;

-- The office copy. Same read boundary as fn_family_sheet, so a school that can
-- see the family's dues can see how they were arrived at.
create or replace function public.fn_student_ledger(p_student_id uuid)
returns table (
  seq           bigint,
  entry_on      date,
  kind          text,
  particulars   text,
  reference     text,
  debit         numeric,
  credit        numeric,
  balance_after numeric,
  recorded_by   text
) language plpgsql stable security definer set search_path = public as $$
begin
  -- may_view, and NOT the plain role check: 0059's rule is that every READ gate
  -- admits the observer role through one helper rather than by each function
  -- remembering to name it. supabase/verify.sql fails the build otherwise, and
  -- it did.
  if not public.may_view('owner','principal','admin_clerk','accountant') then
    raise exception 'Not permitted to view fee records' using errcode = '42501';
  end if;
  perform public.assert_own('students', p_student_id);
  return query select * from public.fn__student_ledger(p_student_id);
end;
$$;

revoke all on function public.fn_student_ledger(uuid) from public, anon;
grant execute on function public.fn_student_ledger(uuid) to authenticated;

-- The parent's copy. fn__assert_my_child is the same gate every other portal
-- function uses, so a parent reaches their own children and nobody else's.
create or replace function public.fn_portal_child_ledger(p_student_id uuid)
returns table (
  seq           bigint,
  entry_on      date,
  kind          text,
  particulars   text,
  reference     text,
  debit         numeric,
  credit        numeric,
  balance_after numeric,
  recorded_by   text
) language plpgsql stable security definer set search_path = public as $$
begin
  perform public.fn__assert_my_child(p_student_id);
  -- The office statement names the clerk who took the money. A parent has no
  -- business knowing which member of staff keyed an entry, so that column comes
  -- back empty here rather than being selected and hidden in the browser.
  return query
    select l.seq, l.entry_on, l.kind, l.particulars, l.reference,
           l.debit, l.credit, l.balance_after, ''::text
    from public.fn__student_ledger(p_student_id) l;
end;
$$;

revoke all on function public.fn_portal_child_ledger(uuid) from public, anon;
grant execute on function public.fn_portal_child_ledger(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 3. The parent's fee page adds up
--
-- It showed the challans and the balance. When an adjustment existed, the two
-- disagreed and the page offered no third figure to explain the gap. Now the
-- adjustments are listed, and `charges_not_on_a_challan` is the single number
-- that closes it:
--
--     sum(invoice outstanding) + charges_not_on_a_challan = balance
--
-- asserted in supabase/tests/one_number.sql rather than left as a comment.
-- ---------------------------------------------------------------------------
create or replace function public.fn_portal_child_fees(p_student_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_fam uuid; v_out jsonb;
begin
  perform public.fn__assert_my_child(p_student_id);
  v_fam := public.my_family_id();

  select jsonb_build_object(
    'student_id', p_student_id,
    'balance', public.student_balance(p_student_id),
    'family_outstanding', public.family_outstanding(v_fam),
    'family_credit', public.family_credit(v_fam),
    'invoices', coalesce((
      select jsonb_agg(jsonb_build_object(
        'period_month', i.period_month, 'due_date', i.due_date,
        'charge', b.charge, 'paid', b.allocated,
        'outstanding', b.charge - b.allocated, 'status', b.status
      ) order by i.period_month desc nulls last)
      from public.invoice_balances b
      join public.invoices i on i.id = b.invoice_id
      where b.student_id = p_student_id
    ), '[]'::jsonb),
    -- New. Every charge or credit that is not on a challan, with the reason the
    -- school recorded at the time.
    'adjustments', coalesce((
      select jsonb_agg(jsonb_build_object(
        'on', a.created_at::date,
        'amount', a.amount,
        'reason', coalesce(nullif(btrim(a.reason), ''), 'Adjustment')
      ) order by a.created_at desc)
      from public.adjustments a
      where a.student_id = p_student_id
    ), '[]'::jsonb),
    'charges_not_on_a_challan', coalesce((
      select sum(a.amount) from public.adjustments a where a.student_id = p_student_id
    ), 0),
    'receipts', coalesce((
      select jsonb_agg(jsonb_build_object(
        'receipt_no', p.receipt_no, 'amount', p.amount,
        'method', p.method, 'paid_on', p.created_at,
        'received_by', pr.full_name
      ) order by p.created_at desc)
      from public.payments p
      left join public.profiles pr on pr.id = p.received_by
      where p.family_id = v_fam and p.status = 'verified'
    ), '[]'::jsonb)
  ) into v_out;

  return v_out;
end;
$$;

-- ---------------------------------------------------------------------------
-- 4. Dues by fee head: the fine is a head, and the totals are counted once
--
-- TWO CHANGES, AND THE SECOND MATTERS MORE THAN IT LOOKS.
--
-- The fine now appears as its own head, so `charged` covers everything the
-- school billed and the apportionment numerator matches its own denominator.
--
-- And the report's TOTALS no longer come from summing the rows. Apportioning a
-- payment across heads is a division, and a division of Rs 1,000 across three
-- heads does not come back as Rs 1,000 no matter how the rounding is arranged.
-- Summing the rows to get the total therefore produced a figure that missed the
-- reconciliation screen by a few paisa for no reason a school could ever
-- discover. The totals are now taken straight from the challans -- one sum, no
-- division -- and the per-head split is what it has always been: an
-- apportionment, and now labelled as one on its own row.
-- ---------------------------------------------------------------------------
create or replace function public.fn_head_wise_dues(p_session_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_rows      jsonb;
  v_charged   numeric;
  v_collected numeric;
begin
  if not public.may_view('owner', 'principal', 'accountant') then
    raise exception 'Not permitted to view fee reports';
  end if;
  perform public.assert_own('academic_sessions', p_session_id);

  -- The exact totals, from the challans themselves.
  select coalesce(sum(b.charge), 0), coalesce(sum(b.allocated), 0)
    into v_charged, v_collected
  from public.invoice_balances b
  join public.invoices i on i.id = b.invoice_id
  where i.session_id = p_session_id
    and i.school_id = public.current_school_id();

  select coalesce(jsonb_agg(x order by x.charged desc), '[]'::jsonb) into v_rows
  from (
    select p.fee_head,
           sum(p.amt) as charged,
           -- Multiply before dividing: `amt * (allocated / charge)` rounds the
           -- ratio to numeric's default scale first and then multiplies the
           -- error up, which is how a whole-rupee payment came out in paisa.
           sum(case when p.charge > 0 then p.amt * p.allocated / p.charge else 0 end) as collected
    from (
      select coalesce(l.description, 'Other') as fee_head,
             (case when l.is_discount then -l.amount else l.amount end) as amt,
             b.charge, b.allocated
      from public.invoice_balances b
      join public.invoices i on i.id = b.invoice_id
      join public.invoice_lines l on l.invoice_id = i.id
      where i.session_id = p_session_id
        and i.school_id = public.current_school_id()

      union all

      select 'Late fee', i.fine, b.charge, b.allocated
      from public.invoice_balances b
      join public.invoices i on i.id = b.invoice_id
      where i.session_id = p_session_id
        and i.school_id = public.current_school_id()
        and coalesce(i.fine, 0) <> 0
    ) p
    group by p.fee_head
  ) x;

  return jsonb_build_object(
    'session_id', p_session_id,
    'basis', 'Collections are apportioned across fee heads in proportion to '
             || 'their share of each challan, so a head-by-head figure is an '
             || 'estimate. The totals are taken from the challans directly and '
             || 'are exact.',
    'heads', v_rows,
    'total_charged', v_charged,
    'total_collected', v_collected,
    'total_outstanding', v_charged - v_collected);
end;
$$;

-- ---------------------------------------------------------------------------
-- 5. Reconciliation says what it counts, and bridges to the dashboard
--
-- `expected - collected` is a question about CHALLANS and stays exactly that:
-- it is the only figure that can tell a school it billed Class 5 short. What it
-- cannot be is the answer to "what are we owed", because a school is also owed
-- the van fare somebody charged by hand, and is owed money by the child who
-- left in March still carrying arrears.
--
-- So the bridge is now part of the answer. Every term is a real query rather
-- than a residual, because a residual line labelled "difference" is how a
-- reconciliation hides the thing it was built to find.
-- ---------------------------------------------------------------------------
create or replace function public.fn_fee_reconciliation(p_session_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_school    uuid := public.current_school_id();
  v_expected  numeric;
  v_collected numeric;
  v_by_class  jsonb;
  v_uninv     jsonb;
  v_ghost     jsonb;
  v_on_chal   numeric;
  v_manual    numeric;
  v_earlier   numeric;
  v_left      numeric;
  v_student   numeric;
begin
  if not public.may_view('owner','principal','admin_clerk','accountant') then
    raise exception 'Not permitted to view fee reconciliation';
  end if;
  perform public.assert_own('academic_sessions', p_session_id);

  select coalesce(sum(charge), 0), coalesce(sum(allocated), 0)
    into v_expected, v_collected
  from public.invoice_balances where session_id = p_session_id;

  select coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb) into v_by_class
  from (
    select c.name as class_name,
           coalesce(sum(b.charge), 0) as expected,
           coalesce(sum(b.allocated), 0) as collected,
           coalesce(sum(b.charge - b.allocated), 0) as outstanding
    from public.invoice_balances b
    join public.enrollments e on e.id = b.enrollment_id
    join public.classes c on c.id = e.class_id
    where b.session_id = p_session_id
    group by c.name, c.level_order
    order by c.level_order
  ) t;

  select coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb) into v_uninv
  from (
    select s.gr_no, s.full_name, c.name as class_name
    from public.enrollments e
    join public.students s on s.id = e.student_id
    join public.classes c on c.id = e.class_id
    where e.session_id = p_session_id and e.status = 'active'
      and not exists (select 1 from public.invoices i
                      where i.enrollment_id = e.id and i.status <> 'void')
    order by c.level_order, s.full_name
  ) t;

  select coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb) into v_ghost
  from (
    select s.gr_no, s.full_name, c.name as class_name
    from public.enrollments e
    join public.students s on s.id = e.student_id
    join public.classes c on c.id = e.class_id
    where e.session_id = p_session_id and e.status = 'active'
      and not exists (select 1 from public.invoices i
                      where i.enrollment_id = e.id and i.status <> 'void')
      and not exists (select 1 from public.attendance_daily ad where ad.enrollment_id = e.id)
    order by c.level_order, s.full_name
  ) t;

  -- ---- the bridge to the dashboard ----------------------------------------
  -- Everything below is restricted to the children the dashboard counts:
  -- ACTIVE enrolments of this session. That restriction is the whole point --
  -- it is what makes the terms add up to the dashboard's own figure.

  -- What those children still owe on THIS session's challans.
  select coalesce(sum(b.charge - b.allocated), 0) into v_on_chal
  from public.invoice_balances b
  join public.enrollments e on e.id = b.enrollment_id
  where b.session_id = p_session_id
    and e.school_id = v_school
    and e.status = 'active';

  -- Charges and waivers keyed by hand, which never appear on a challan.
  select coalesce(sum(a.amount), 0) into v_manual
  from public.adjustments a
  where a.school_id = v_school
    and exists (select 1 from public.enrollments e
                where e.student_id = a.student_id
                  and e.session_id = p_session_id
                  and e.status = 'active'
                  and e.school_id = v_school);

  -- Arrears the same children carry from an earlier session.
  select coalesce(sum(b.charge - b.allocated), 0) into v_earlier
  from public.invoice_balances b
  join public.enrollments cur on cur.student_id = b.student_id
  where b.session_id is distinct from p_session_id
    and cur.session_id = p_session_id
    and cur.status = 'active'
    and cur.school_id = v_school;

  -- And what is owed by children who are NOT on the current roll: struck off,
  -- left, or moved on. Real money, on nobody's dashboard, which is exactly why
  -- it is worth a line of its own.
  select coalesce(sum(b.charge - b.allocated), 0) into v_left
  from public.invoice_balances b
  join public.enrollments e on e.id = b.enrollment_id
  where b.session_id = p_session_id
    and e.school_id = v_school
    and e.status <> 'active';

  -- The dashboard's own figure, computed the dashboard's own way.
  select coalesce(sum(public.student_balance(e.student_id)), 0) into v_student
  from public.enrollments e
  where e.school_id = v_school
    and e.session_id = p_session_id
    and e.status = 'active';

  return jsonb_build_object(
    'expected', v_expected,
    'collected', v_collected,
    'outstanding', v_expected - v_collected,
    'by_class', v_by_class,
    'uninvoiced', v_uninv,
    'ghost_suspects', v_ghost,
    'basis', 'Expected and collected count CHALLANS raised in this session, for '
             || 'every child billed in it. The dashboard counts what the '
             || 'children on the roll today owe in total, which also includes '
             || 'charges keyed by hand and arrears from an earlier session. '
             || 'The bridge below is how one becomes the other.',
    'bridge', jsonb_build_object(
      'on_challans_this_session', v_on_chal,
      'charges_keyed_by_hand', v_manual,
      'arrears_from_earlier_sessions', v_earlier,
      'student_outstanding', v_student,
      'owed_by_children_no_longer_on_the_roll', v_left));
end;
$$;

grant execute on function public.fn_fee_reconciliation(uuid) to authenticated;
grant execute on function public.fn_head_wise_dues(uuid) to authenticated;
grant execute on function public.fn_portal_child_fees(uuid) to authenticated;

-- ─────────────────────────────────────────────────────────────────────────
-- 0099_one_headcount.sql
-- ─────────────────────────────────────────────────────────────────────────
-- =============================================================================
-- 0099 — "How many children are here" had three answers
--
-- HOW THIS WAS FOUND
--
-- The same way as 0098: one school, seeded to be awkward, and every screen
-- asked the same question in the same transaction.
--
--   Three children enrolled normally
--   One admitted this morning, class not chosen yet
--   One whose record was removed in error, enrolment untouched
--
--   Dashboard tile, "Students"          4
--   Students screen, rows listed        4
--   Plan limit counter                  3
--
-- The two 4s are not agreement. They are two different wrong answers that
-- happen to collide on this fixture: the dashboard counts the removed child and
-- misses the unenrolled one, the Students screen does the exact opposite. On a
-- school with only one of the two situations they differ on screen, and there is
-- nothing anywhere to explain which is right.
--
-- THE THREE DEFINITIONS
--
--   fn_count_students        active enrolment in the current session, student
--   (the plan limit)         active, not removed. Documented in 0026 as "the
--                            same number a principal would say out loud", and
--                            it is the one that decides whether a school can
--                            admit another child, so it is the one that has to
--                            be right.
--
--   fn_dashboard_summary     active enrolment in the current session. Does not
--   (the tile)               look at the student row at all. 0042 fixed exactly
--                            this omission on "New this month" -- it added
--                            `deleted_at is null` there -- and left the tile
--                            beside it counting removed children.
--
--   fn_student_list          active student, not removed, WITH OR WITHOUT an
--   (the Students screen)    enrolment. Correct for a roster: a child admitted
--                            an hour ago has to appear somewhere.
--
-- WHY THE UNENROLLED CHILD IS THE ONE THAT MATTERS
--
-- `fn_admit_student` always creates an enrolment, so this is not a state the
-- admission form can produce. Rollover is. A child not carried into the new
-- session keeps `students.status = 'active'` and has no enrolment in the
-- current one, and from that moment they are invisible to nearly everything:
--
--   * no challan, because billing walks enrolments
--   * no attendance, because the register walks enrolments
--   * no result card, for the same reason
--   * not in the dashboard count, and not in the plan count
--   * NOT in the reconciliation screen's "uninvoiced" list either, because that
--     list also walks active enrolments -- so the one report built to catch a
--     child who is not being billed cannot see this child at all
--
-- They appear on the Students screen with an empty class, which reads as a
-- formatting gap rather than as a child who is about to be forgotten for a
-- term. A school finds out in March when a parent asks why no fee slip ever
-- came.
--
-- WHAT THIS MIGRATION DOES
--
--   1. The dashboard tile IS the plan counter: `fn_dashboard_summary` calls
--      `fn_count_students` rather than carrying a second copy of the rule.
--   2. The dashboard returns `students_without_a_class`, so the difference
--      between the tile and the Students screen is a number the school is shown
--      rather than one they have to notice.
--   3. Today's attendance excludes removed students, so `marked` can never
--      exceed a headcount that now excludes them.
--
-- supabase/tests/one_number.sql asserts all three counts agree, and that a
-- child left out of a rollover is reported rather than lost.
--
-- Re-runnable.
-- =============================================================================

create or replace function public.fn_dashboard_summary()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_school  uuid := public.current_school_id();
  v_session uuid := (select current_session_id from public.school_settings
                      where school_id = v_school);
  -- may_view, and NOT the plain role check. 0059 rewrote every READ gate in the
  -- schema to go through one helper, programmatically, and warned in its own
  -- header that retyping a function body by hand is how that gets silently
  -- reverted. The first draft of this migration did exactly that on all three
  -- functions it touches; supabase/repair/detect.sql caught it. Uncaught, it
  -- would have shut the observer role out of the money tiles all over again.
  v_finance boolean := public.may_view('owner','principal','admin_clerk','accountant','readonly');
  v_active  int;
  v_no_class int;
  v_present int; v_absent int; v_leave int; v_late int; v_half int; v_marked int;
  v_today numeric; v_month numeric; v_outstanding numeric; v_defaulters int;
  v_new_admissions int;
  v_billed_month int;
  v_classes_no_fee int;
  v_month_start date := date_trunc('month', current_date)::date;
begin
  if not public.may_view('owner','principal','admin_clerk','accountant',
                         'class_teacher','subject_teacher','readonly') then
    raise exception 'Not permitted';
  end if;

  -- ONE definition, shared with the plan limit. Previously this counted
  -- enrolments without looking at the student row, so a record removed in error
  -- stayed in the tile while dropping out of the licence count and off the
  -- Students screen.
  v_active := public.fn_count_students(v_school);

  -- The children the tile cannot see. An active student with no active
  -- enrolment in the current session gets no challan, no register entry and no
  -- result card, and no other screen in the product reports them.
  select count(*) into v_no_class
  from public.students s
  where s.school_id = v_school
    and s.status = 'active'
    and s.deleted_at is null
    and not exists (
      select 1 from public.enrollments e
      where e.student_id = s.id
        and e.session_id = v_session
        and e.status = 'active');

  -- Joined to students so a removed child cannot be marked present against a
  -- headcount that no longer includes them. "42 present of 40 on the roll" is
  -- the kind of arithmetic that makes a school stop trusting the whole page.
  select
    count(*) filter (where ad.status = 'present'),
    count(*) filter (where ad.status = 'absent'),
    count(*) filter (where ad.status = 'leave'),
    count(*) filter (where ad.status = 'late'),
    count(*) filter (where ad.status = 'half_day'),
    count(*)
  into v_present, v_absent, v_leave, v_late, v_half, v_marked
  from public.attendance_daily ad
  join public.enrollments e on e.id = ad.enrollment_id
  join public.students s on s.id = e.student_id
  where ad.school_id = v_school
    and ad.attendance_date = current_date
    and e.session_id = v_session
    and s.deleted_at is null;

  select count(*) into v_new_admissions
  from public.students s
  where s.school_id = v_school
    and s.deleted_at is null
    and s.created_at >= v_month_start
    and s.created_at < (v_month_start + interval '1 month');

  if v_finance then
    select coalesce(sum(p.amount), 0) into v_today
    from public.payments p
    where p.school_id = v_school
      and p.status = 'verified'
      and p.created_at >= date_trunc('day', now())
      and p.created_at <  date_trunc('day', now()) + interval '1 day';

    select coalesce(sum(p.amount), 0) into v_month
    from public.payments p
    where p.school_id = v_school
      and p.status = 'verified'
      and p.created_at >= v_month_start
      and p.created_at <  (v_month_start + interval '1 month');

    select coalesce(sum(b.bal), 0), count(*) into v_outstanding, v_defaulters
    from public.enrollments e
    join lateral (select public.student_balance(e.student_id) as bal) b on true
    where e.school_id = v_school
      and e.session_id = v_session
      and e.status = 'active'
      and b.bal > 0;

    select count(distinct i.student_id) into v_billed_month
    from public.invoices i
    where i.school_id = v_school
      and i.period_month = v_month_start
      and i.status <> 'void'
      and coalesce((select sum(case when l.is_discount then -l.amount else l.amount end)
                      from public.invoice_lines l where l.invoice_id = i.id), 0) > 0;

    select count(*) into v_classes_no_fee
    from public.classes c
    where c.school_id = v_school
      and exists (select 1 from public.enrollments e
                   where e.class_id = c.id and e.session_id = v_session and e.status = 'active')
      and not exists (select 1 from public.fee_structures fs
                       where fs.class_id = c.id and fs.session_id = v_session and fs.amount > 0);
  end if;

  return jsonb_build_object(
    'active_students', coalesce(v_active, 0),
    'students_without_a_class', coalesce(v_no_class, 0),
    'new_admissions_month', coalesce(v_new_admissions, 0),
    'attendance', jsonb_build_object(
      'marked', coalesce(v_marked, 0), 'present', coalesce(v_present, 0),
      'absent', coalesce(v_absent, 0), 'leave', coalesce(v_leave, 0),
      'late', coalesce(v_late, 0), 'half_day', coalesce(v_half, 0)),
    'finance_visible', v_finance,
    'collected_today', coalesce(v_today, 0),
    'collected_month', coalesce(v_month, 0),
    'outstanding', coalesce(v_outstanding, 0),
    'defaulters', coalesce(v_defaulters, 0),
    'billed_students_month', coalesce(v_billed_month, 0),
    'classes_without_fee', coalesce(v_classes_no_fee, 0),
    'session_set', v_session is not null);
end;
$$;

-- ---------------------------------------------------------------------------
-- Who they are, not just how many
--
-- A count on a tile is a prompt, not an answer. This is the list behind it, so
-- the office can put each child into a class instead of hunting the Students
-- screen for blank class names.
--
-- `is_staff` rather than the finance roles: a class teacher noticing that a
-- child in their room is on no register is exactly who should be able to see
-- this, and it carries no money.
-- ---------------------------------------------------------------------------
create or replace function public.fn_students_without_a_class()
returns table (
  student_id     uuid,
  full_name      text,
  gr_no          text,
  father_name    text,
  admission_date date,
  last_class     text,
  last_session   text
) language plpgsql stable security definer set search_path = public as $$
declare
  v_school  uuid := public.current_school_id();
  v_session uuid := (select current_session_id from public.school_settings
                      where school_id = v_school);
begin
  if not public.is_staff() then
    raise exception 'Not permitted' using errcode = '42501';
  end if;

  return query
  select s.id, s.full_name, s.gr_no, s.father_name, s.admission_date,
         -- Where they were last seen, which is what tells the office whether
         -- this is a new admission or a child a rollover left behind.
         (select c.name from public.enrollments e
            join public.classes c on c.id = e.class_id
            join public.academic_sessions ses on ses.id = e.session_id
           where e.student_id = s.id and e.school_id = v_school
           order by ses.created_at desc, e.created_at desc limit 1),
         (select ses.name from public.enrollments e
            join public.academic_sessions ses on ses.id = e.session_id
           where e.student_id = s.id and e.school_id = v_school
           order by ses.created_at desc, e.created_at desc limit 1)
  from public.students s
  where s.school_id = v_school
    and s.status = 'active'
    and s.deleted_at is null
    and not exists (
      select 1 from public.enrollments e
      where e.student_id = s.id
        and e.session_id = v_session
        and e.status = 'active')
  order by s.admission_date desc nulls last, s.full_name;
end;
$$;

-- Postgres grants EXECUTE on a new function to PUBLIC, and `anon` is a member
-- of PUBLIC, so a new function is reachable without a login until this line.
revoke all on function public.fn_students_without_a_class() from public, anon;
grant execute on function public.fn_students_without_a_class() to authenticated;

-- ─────────────────────────────────────────────────────────────────────────
-- 0100_the_attendance_rule_is_one_place.sql
-- ─────────────────────────────────────────────────────────────────────────
-- =============================================================================
-- 0100 — Finishing 0097: the attendance rule now exists in one place
--
-- 0097 was written because the same register produced three different
-- percentages: the parent portal read 92% where the result card in the child's
-- hand printed 83.3%, because the portal counted a late arrival and a half day
-- as whole days present, and the dashboard did not count a late arrival at all.
-- It created `fn__attendance_pct` as the single rule and pointed the two broken
-- callers at it.
--
-- It left the three CORRECT copies alone, and that was the wrong call.
--
--   fn_attendance_summary          the student profile
--   fn_staff_attendance_summary    the staff record
--   fn_generate_result_cards       the printed card
--
-- All three carry the arithmetic inline, all three are byte-identical in effect
-- today, and being correct today is exactly what the two broken ones were until
-- somebody edited one of them. Four copies of a rule is not four checks on it,
-- it is four chances to diverge, and this rule has already diverged twice on
-- the two surfaces a school and a parent look at most.
--
-- The check at the bottom is the part that lasts: after this migration, the
-- formula appears in exactly ONE function body, and a future migration that
-- writes it out again fails here rather than in front of a family.
--
-- WHY fn_generate_result_cards IS REWRITTEN PROGRAMMATICALLY
--
-- It is 287 lines. Retyping it into this file to change two of them is how a
-- stack of earlier fixes gets silently reverted, which 0059's header records
-- happening in this repository once already, and which the first draft of 0098
-- did again to three read gates. So its own definition is read back from the
-- catalogue, the formula is substituted, and the result is executed. Nothing
-- else in it can change, because nothing else in it is touched.
--
-- Re-runnable: the substitution matches nothing on a second run, and the do
-- block skips out.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. The student profile
-- ---------------------------------------------------------------------------
create or replace function public.fn_attendance_summary(
  p_enrollment_id uuid, p_from date, p_to date
) returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v jsonb;
begin
  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;
  perform public.assert_own('enrollments', p_enrollment_id);
  select jsonb_build_object(
    'present',     count(*) filter (where status = 'present'),
    'absent',      count(*) filter (where status = 'absent'),
    'leave',       count(*) filter (where status = 'leave'),
    'late',        count(*) filter (where status = 'late'),
    'half_day',    count(*) filter (where status = 'half_day'),
    'marked_days', count(*),
    -- The shared rule. It returns null on an unmarked register itself, so the
    -- `case when count(*) = 0` that used to wrap this is gone rather than
    -- duplicated: two places deciding what an empty register means is the same
    -- mistake one size smaller.
    'present_pct', public.fn__attendance_pct(
      (count(*) filter (where status = 'present'))::int,
      (count(*) filter (where status = 'late'))::int,
      (count(*) filter (where status = 'half_day'))::int,
      count(*)::int)
  ) into v
  from public.attendance_daily
  where enrollment_id = p_enrollment_id
    and attendance_date between p_from and p_to;
  return v;
end;
$$;

-- ---------------------------------------------------------------------------
-- 2. The staff record
--
-- A different table, the same rule. A school that docks pay on attendance will
-- compare a teacher's percentage against a pupil's and expect them to be
-- computed the same way, and there is no argument for them not to be.
-- ---------------------------------------------------------------------------
create or replace function public.fn_staff_attendance_summary(
  p_staff_id uuid, p_from date, p_to date
) returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v jsonb;
begin
  if not (public.may_view('owner','principal','admin_clerk') or p_staff_id = public.my_staff_id()) then
    raise exception 'Not permitted';
  end if;
  perform public.assert_own('staff', p_staff_id);
  select jsonb_build_object(
    'present',     count(*) filter (where status = 'present'),
    'absent',      count(*) filter (where status = 'absent'),
    'leave',       count(*) filter (where status = 'leave'),
    'late',        count(*) filter (where status = 'late'),
    'half_day',    count(*) filter (where status = 'half_day'),
    'marked_days', count(*),
    'present_pct', public.fn__attendance_pct(
      (count(*) filter (where status = 'present'))::int,
      (count(*) filter (where status = 'late'))::int,
      (count(*) filter (where status = 'half_day'))::int,
      count(*)::int)
  ) into v
  from public.staff_attendance
  where staff_id = p_staff_id and attendance_date between p_from and p_to;
  return v;
end;
$$;

-- ---------------------------------------------------------------------------
-- 3. The printed card, rewritten from its own definition
-- ---------------------------------------------------------------------------
do $rewrite$
declare
  v_src text;
  v_new text;
begin
  select pg_get_functiondef(p.oid) into v_src
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname = 'fn_generate_result_cards';

  if v_src is null then
    raise notice '0100: fn_generate_result_cards is not present, nothing to rewrite';
    return;
  end if;

  -- Whitespace-tolerant, because the same expression is laid out differently in
  -- 0005 and 0058 and a school may be on either.
  v_new := regexp_replace(
    v_src,
    'round\(100\.0 \* \(count\(\*\) filter \(where status in \(''present'',''late''\)\)\s*'
      || '\+ 0\.5 \* count\(\*\) filter \(where status = ''half_day''\)\) / count\(\*\), 1\)',
    'public.fn__attendance_pct('
      || '(count(*) filter (where status = ''present''))::int, '
      || '(count(*) filter (where status = ''late''))::int, '
      || '(count(*) filter (where status = ''half_day''))::int, '
      || 'count(*)::int)',
    'g');

  if v_new = v_src then
    -- Either already done, or the expression has been reworded. Those are very
    -- different situations, so they are told apart rather than both passing
    -- quietly: a rewording means this migration silently stopped working.
    if v_src like '%fn__attendance_pct%' then
      raise notice '0100: fn_generate_result_cards already uses the shared rule';
      return;
    end if;
    -- Adjacent string literals, not `||`. RAISE takes a literal format string
    -- and a concatenation expression is a syntax error there, which is how the
    -- first version of this file failed to apply at all.
    raise exception '0100: could not find the attendance formula in '
      'fn_generate_result_cards. It has been reworded, so this substitution '
      'no longer matches and the card would keep its own copy of the rule. '
      'Update the pattern in this migration.';
  end if;

  execute v_new;
end $rewrite$;

-- ---------------------------------------------------------------------------
-- 4. Did this migration actually do its job?
--
-- Narrower than it looks, and worth being exact about rather than claiming to
-- be the permanent guard. It runs AFTER the three rewrites above, so what it
-- catches is THIS FILE failing: a school on a variant wording the substitution
-- in section 3 did not match, or a fourth copy nobody knew about. It cannot
-- catch a migration written next year that spells the formula out again,
-- because that one runs after this file on every install.
--
-- The permanent guard is in supabase/tests/attendance_rule.sql, which asks the
-- same catalogue question on the finished database and fails CI. Both exist
-- because they answer different questions: this one protects the deployment,
-- that one protects the next change.
-- ---------------------------------------------------------------------------
do $assert$
declare v_bad text;
begin
  select string_agg(p.proname, ', ' order by p.proname) into v_bad
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public'
    and p.proname <> 'fn__attendance_pct'
    and p.prosrc like '%0.5 * count(*) filter (where status = ''half_day'')%';

  if v_bad is not null then
    raise exception '0100: the attendance rule is written out inside: %. '
      'It must exist only in fn__attendance_pct, because the last time it '
      'existed in four places two of them were wrong and a parent read 92%% '
      'where the result card printed 83.3%%.', v_bad;
  end if;
end $assert$;

-- ─────────────────────────────────────────────────────────────────────────
-- 0101_a_dropped_key_is_lost_data.sql
-- ─────────────────────────────────────────────────────────────────────────
-- =============================================================================
-- 0101 — A key the database does not recognise was silently thrown away
--
-- HOW THIS WAS FOUND
--
-- Not by a school. By making the mistake while writing a test: a seed script
-- sent `practical` where fn_enter_marks reads `practical_marks`. The function
-- accepted the call, reported success, and wrote NULL into the practical column
-- for every pupil in the class. Nothing raised, nothing logged, and the office
-- marksheet simply showed an empty practical column, which reads as "nobody has
-- entered the practicals yet".
--
-- Four functions take a list of rows as jsonb and read the keys they know by
-- name, ignoring anything else:
--
--   fn_enter_marks              enrollment_id, marks, practical_marks, is_absent
--   fn_enter_assessment_marks   enrollment_id, marks, is_absent
--   fn_mark_attendance          enrollment_id, status
--   fn_record_bulk_payments     student_id, amount, receipt_no
--
-- WHAT EACH ONE ACTUALLY DOES TODAY, measured rather than assumed. The first
-- draft of this migration asserted that a misspelt attendance status marks a
-- whole class present and a misspelt amount posts a receipt for nothing. Both
-- were wrong, and running it was what showed that:
--
--   fn_mark_attendance       ALREADY REFUSES. A row with no `status` the
--                            function recognises fails the NOT NULL constraint
--                            on attendance_daily.status. Nothing is written.
--   fn_record_bulk_payments  ALREADY REFUSES, with "Amount for <name> must be
--                            more than zero". Nothing is written.
--   fn_enter_marks           SILENT. `practical` for `practical_marks` stores
--                            NULL; `absent` for `is_absent` stores false, so a
--                            child who sat no paper is recorded as having
--                            scored nothing, which prints as a FAIL on a card
--                            that goes home.
--   fn_enter_assessment_marks  the same, on a class test.
--
-- So the honest summary is: two of the four lose data silently, and two are
-- saved by a constraint that happens to be there.
--
-- IT IS STILL WORTH DOING FOR ALL FOUR, for two reasons.
--
-- The first is that the two which refuse do so for reasons unrelated to the
-- mistake, and say the wrong thing about it. "Amount for Ahmed must be more
-- than zero" sent to a clerk who typed an amount is a diagnosis pointing at the
-- wrong thing, and somebody will spend a morning on it. The refusal now names
-- the key.
--
-- The second is that being saved by a constraint is not a rule, it is luck.
-- attendance_daily.status is NOT NULL today; a future column added nullable, or
-- a fifth function of the same shape, has no such accident to fall back on.
--
-- The app is correct today: its TypeScript payload types match all four
-- functions exactly. That is a property of today's caller. The failure arrives
-- the day somebody renames a field on one side of the wall, imports a
-- spreadsheet through a script, or writes a second client.
--
-- WHY THE FOUR ARE PATCHED PROGRAMMATICALLY
--
-- Same reason as 0100. fn_enter_marks alone is 114 lines, and retyping a
-- function body to add one statement to it is how a stack of earlier fixes gets
-- silently reverted, which this repository has recorded happening twice.
-- Each definition is read from the catalogue, one `perform` is inserted directly
-- after the function's own permission gate, and the result is executed. The
-- insertion point is located rather than assumed, and the block refuses loudly
-- rather than guessing if it cannot find the gate.
--
-- WHAT IS DELIBERATELY LEFT ALONE
--
-- fn_admit_student, fn_import_students, fn_import_staff, fn_import_opening_balances
-- and fn_rollover also take jsonb. They are NOT given this treatment:
--
--   * the three importers already report per row, in words, what they did and
--     did not understand, and they are fed by a CSV mapper whose whole job is
--     that a school's column headings do not match ours. Refusing an unknown
--     column there would break the feature.
--   * fn_admit_student takes a nested DOCUMENT with sub-objects (guardian,
--     links), not a list of flat rows, so one flat key list does not describe
--     it and pretending otherwise would be a guard that is wrong about what it
--     is guarding.
--
-- Re-runnable.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. The rule
--
-- Collects EVERY unrecognised key across the whole payload before raising, so a
-- caller with three fields wrong is told about three fields, not told about one,
-- corrected, and told about the next. A clerk pasting a spreadsheet does not get
-- three round trips.
-- ---------------------------------------------------------------------------
create or replace function public.fn__only_these_keys(
  p_rows jsonb, p_allowed text[], p_what text
) returns void language plpgsql immutable as $$
declare
  v_row jsonb;
  v_key text;
  v_bad text[] := '{}';
begin
  if p_rows is null then
    return;
  end if;
  if jsonb_typeof(p_rows) <> 'array' then
    raise exception '% expects a list of rows and was given a %.',
      p_what, jsonb_typeof(p_rows);
  end if;

  for v_row in select value from jsonb_array_elements(p_rows) loop
    if jsonb_typeof(v_row) <> 'object' then
      raise exception '% expects each row to be an object and found a %.',
        p_what, jsonb_typeof(v_row);
    end if;
    for v_key in select jsonb_object_keys(v_row) loop
      if not (v_key = any(p_allowed)) and not (v_key = any(v_bad)) then
        v_bad := v_bad || v_key;
      end if;
    end loop;
  end loop;

  if array_length(v_bad, 1) is not null then
    raise exception '% does not understand %. It reads only: %. '
      'A field it does not recognise is not ignored here, because ignoring one '
      'silently loses whatever was in it.',
      p_what,
      array_to_string(v_bad, ', '),
      array_to_string(p_allowed, ', ')
      using errcode = '22023';
  end if;
end;
$$;

revoke all on function public.fn__only_these_keys(jsonb, text[], text)
  from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2. The four callers, patched from their own definitions
-- ---------------------------------------------------------------------------
do $patch$
declare
  v_targets text[][] := array[
    -- function, payload argument, what to call it, allowed keys (comma separated)
    array['fn_enter_marks', 'p_marks', 'Mark entry',
          'enrollment_id,marks,practical_marks,is_absent'],
    array['fn_enter_assessment_marks', 'p_marks', 'Class test mark entry',
          'enrollment_id,marks,is_absent'],
    array['fn_mark_attendance', 'p_marks', 'Attendance marking',
          'enrollment_id,status'],
    array['fn_record_bulk_payments', 'p_items', 'Bulk payment entry',
          'student_id,amount,receipt_no']
  ];
  v_i int;
  v_name text; v_arg text; v_what text; v_keys text;
  v_src text; v_new text;
  v_at int; v_end int;
  v_call text;
begin
  for v_i in 1 .. array_length(v_targets, 1) loop
    v_name := v_targets[v_i][1];
    v_arg  := v_targets[v_i][2];
    v_what := v_targets[v_i][3];
    v_keys := v_targets[v_i][4];

    select pg_get_functiondef(p.oid) into v_src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = v_name;

    if v_src is null then
      raise exception '0101: % is not present. This migration expects the four '
        'payload functions to exist; apply the earlier bundles first.', v_name;
    end if;

    if v_src like '%fn__only_these_keys%' then
      raise notice '0101: % already refuses unknown keys', v_name;
      continue;
    end if;

    -- AFTER THE PERMISSION CHECK, not at the top of the body.
    --
    -- The first draft inserted after `begin`, which put payload validation
    -- ahead of "Not permitted". That is the wrong order on principle: a caller
    -- who may not do the thing should be told that and nothing else, and every
    -- other function in this schema authorises first. So the anchor is the
    -- closing `end if;` of the function's own permission gate, found by taking
    -- the first `end if;` that follows the first 'Not permitted' it raises.
    v_at := position('Not permitted' in v_src);
    if v_at = 0 then
      raise exception '0101: % has no "Not permitted" gate, so this migration '
        'cannot tell where the permission check ends. Nothing was changed.', v_name;
    end if;
    v_end := position(E'\n  end if;\n' in substr(v_src, v_at));
    if v_end = 0 then
      raise exception '0101: could not find the end of %''s permission gate. '
        'Nothing was changed.', v_name;
    end if;
    v_at := v_at + v_end + length(E'\n  end if;\n') - 1;

    v_call := format(
      E'  perform public.fn__only_these_keys(%I, %L::text[], %L);\n',
      v_arg, '{' || v_keys || '}', v_what);

    v_new := substr(v_src, 1, v_at - 1) || v_call || substr(v_src, v_at);
    if v_new = v_src then
      raise exception '0101: the insertion into % changed nothing', v_name;
    end if;
    execute v_new;
  end loop;
end $patch$;

-- ---------------------------------------------------------------------------
-- 3. Did it take?
--
-- Narrow, like 0100's: this runs straight after the patch, so what it catches
-- is THIS FILE failing on a school whose function shapes differ. The lasting
-- check is supabase/tests/payload_keys.sql, which proves the refusal actually
-- happens rather than that the text is present.
-- ---------------------------------------------------------------------------
do $assert$
declare v_missing text;
begin
  select string_agg(x.name, ', ' order by x.name) into v_missing
  from (values ('fn_enter_marks'), ('fn_enter_assessment_marks'),
               ('fn_mark_attendance'), ('fn_record_bulk_payments')) as x(name)
  where not exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = x.name
      and p.prosrc like '%fn__only_these_keys%');

  if v_missing is not null then
    raise exception '0101: these still accept a key they do not read: %', v_missing;
  end if;
end $assert$;

-- ─────────────────────────────────────────────────────────────────────────
-- 0102_the_drawer_and_the_clerk.sql
-- ─────────────────────────────────────────────────────────────────────────
-- =============================================================================
-- 0102 — The cash drawer accused the clerk of a shortfall the software created
--
-- WHAT WAS MEASURED
--
-- One ordinary morning at the counter, seeded and run:
--
--   open the drawer with a Rs 1,000 float
--   take Rs 3,000 in cash for September            drawer holds 4,000
--   the cheque bounced: reverse it, hand the money back   drawer holds 1,000
--   admit a child, Rs 2,000 admission fee in cash  drawer holds 3,000
--
--   THE TILL EXPECTS Rs 4,000. THE DRAWER HOLDS Rs 3,000.
--   "The drawer is off by -1000.00. A reason is required to close it."
--
-- The clerk did everything correctly and cannot close their till without
-- writing an explanation for money they never touched. The variance is then
-- recorded against them and an owner signs it off. In a Pakistani school office
-- that is not a rounding complaint, it is an accusation, and it lands on the
-- lowest-paid person in the building.
--
-- WHY, EXACTLY
--
-- 0031 attached cash to the collector's drawer by adding one line to the two
-- payment entry points, fn_record_payment and fn_record_family_payment. Two
-- other functions write to `payments` and neither was given that line:
--
--   fn_reverse_payment    the contra receipt. Money leaves the drawer and the
--                         till never learns, so the till still expects the
--                         original receipt. The drawer is SHORT by that amount.
--   fn_admit_student      the admission fee, which is hardcoded 'cash'. Money
--                         enters the drawer and the till never learns, so the
--                         drawer is OVER by that amount -- which fn_close_till's
--                         own comment calls "as much a red flag as missing cash".
--
-- In the run above the two partly cancelled, which is worse than either alone:
-- a Rs 3,000 shortfall and a Rs 2,000 surplus presented as a Rs 1,000 mystery.
--
-- WHICH DRAWER A REVERSAL COMES OUT OF
--
-- Not the same question as "who is doing it". fn_reverse_payment is
-- owner/principal only, and a principal usually has no drawer of their own; the
-- cash is handed back from the drawer it went into. So:
--
--   1. the original payment's till, IF that session is still open. The money is
--      physically in that drawer and taking it out is what the contra records.
--   2. otherwise the person's own open till, if they have one. The original
--      drawer is closed and counted; the cash is coming out of whatever is open
--      in front of them now.
--   3. otherwise nothing, exactly as today. A reversal of last month's receipt
--      belongs to no drawer, and inventing one would open a till in somebody's
--      name that they never opened and will be asked to count.
--
-- It never CREATES a till, which is the difference from the money-in path.
-- fn__ensure_till opens one because cash that has arrived must be in somebody's
-- drawer; cash going out has no such guarantee, and a till opened with a
-- negative balance is a worse lie than an unattributed reversal.
--
-- The admission fee is money IN and uses fn__ensure_till, exactly like the two
-- entry points 0031 fixed.
--
-- Both functions are patched from their own definitions rather than retyped:
-- fn_admit_student is 200 lines and this changes one of them. Same reasoning as
-- 0100 and 0101, and the same refusal to guess if the anchor is not found.
--
-- Re-runnable.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. Which drawer a reversal comes out of
-- ---------------------------------------------------------------------------
create or replace function public.fn__reversal_till(
  p_original_till uuid, p_method public.payment_method
) returns uuid language plpgsql stable security definer set search_path = public as $$
declare v_id uuid;
begin
  -- Only cash sits in a drawer. Reversing a bank transfer moves nothing on the
  -- counter, and attributing it to a till would make that till wrong.
  if p_method <> 'cash' then
    return null;
  end if;

  if p_original_till is not null then
    select id into v_id from public.till_sessions
     where id = p_original_till and status = 'open';
    if found then return v_id; end if;
  end if;

  if auth.uid() is not null then
    select id into v_id from public.till_sessions
     where opened_by = auth.uid() and status = 'open';
    if found then return v_id; end if;
  end if;

  return null;
exception when others then
  -- Never let till bookkeeping stop a reversal being recorded. The same
  -- decision fn__ensure_till made, for the same reason: the money movement is
  -- the fact, and the drawer is the annotation.
  return null;
end;
$$;

revoke all on function public.fn__reversal_till(uuid, public.payment_method)
  from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2. The two writers that never learned about the drawer
-- ---------------------------------------------------------------------------
do $patch$
declare
  v_src text; v_new text;
begin
  -- ---- the contra receipt --------------------------------------------------
  select pg_get_functiondef(p.oid) into v_src
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname = 'fn_reverse_payment';
  if v_src is null then
    raise exception '0102: fn_reverse_payment is not present; apply the earlier bundles first';
  end if;

  if v_src like '%fn__reversal_till%' then
    raise notice '0102: fn_reverse_payment already attributes the drawer';
  else
    v_new := regexp_replace(
      v_src,
      '(insert into public\.payments\(student_id, family_id, amount, method, receipt_no,\s*'
        || 'status, received_by, reversal_of, note\)\s*'
        || 'values \(v_orig\.student_id, v_orig\.family_id, -v_orig\.amount, v_orig\.method, v_receipt,\s*'
        || '''verified'', v_actor, p_payment_id, coalesce\(p_reason, ''reversal''\))\)',
      '\1, public.fn__reversal_till(v_orig.till_session_id, v_orig.method))');
    -- The column list needs the new name at the END, where the value was
    -- appended. The first version of this put the column after `receipt_no` and
    -- the value last, so the columns and the values no longer lined up and
    -- Postgres tried to write 'verified' into a uuid. Caught by re-running the
    -- morning above, which is why that fixture exists.
    v_new := replace(v_new,
      'status, received_by, reversal_of, note)',
      'status, received_by, reversal_of, note, till_session_id)');
    if v_new = v_src or v_new not like '%fn__reversal_till%' then
      raise exception '0102: could not find the contra-receipt insert in '
        'fn_reverse_payment. It has been reworded, so nothing was changed and '
        'the drawer would keep being wrong. Update the pattern in this migration.';
    end if;
    execute v_new;
  end if;

  -- ---- the admission fee ---------------------------------------------------
  select pg_get_functiondef(p.oid) into v_src
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname = 'fn_admit_student';
  if v_src is null then
    raise exception '0102: fn_admit_student is not present; apply the earlier bundles first';
  end if;

  if v_src like '%fn__ensure_till%' then
    raise notice '0102: fn_admit_student already attributes the drawer';
  else
    v_new := replace(v_src,
      'insert into public.payments(student_id, family_id, amount, method, receipt_no, status, received_by, note)'
        || E'\n      values (v_student, v_family, v_af_amt, ''cash'', v_af_receipt, ''verified'', v_actor, ''Admission fee'')',
      'insert into public.payments(student_id, family_id, amount, method, receipt_no, status, received_by, note, till_session_id)'
        || E'\n      values (v_student, v_family, v_af_amt, ''cash'', v_af_receipt, ''verified'', v_actor, ''Admission fee'', public.fn__ensure_till())');
    if v_new = v_src then
      raise exception '0102: could not find the admission-fee insert in '
        'fn_admit_student. It has been reworded, so nothing was changed and the '
        'drawer would keep being over. Update the pattern in this migration.';
    end if;
    execute v_new;
  end if;
end $patch$;

-- ---------------------------------------------------------------------------
-- 3. Did it take?
--
-- Narrow, like 0100's and 0101's: this runs straight after the patch, so it
-- catches THIS FILE failing rather than a later regression. The lasting check
-- is supabase/tests/till_and_the_clerk.sql, which runs the morning above and
-- asserts the drawer balances.
-- ---------------------------------------------------------------------------
do $assert$
declare v_bad text;
begin
  select string_agg(x.name, ', ' order by x.name) into v_bad
  from (values ('fn_reverse_payment'), ('fn_admit_student')) as x(name)
  where not exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = x.name
      and p.prosrc like '%till_session_id%');

  if v_bad is not null then
    raise exception '0102: these still write cash without saying which drawer '
      'it came from or went into: %', v_bad;
  end if;
end $assert$;

-- ─────────────────────────────────────────────────────────────────────────
-- 0103_the_familys_money.sql
-- ─────────────────────────────────────────────────────────────────────────
-- =============================================================================
-- 0103 — The school holds the family's deposit and told the family nothing
--
-- A security deposit is the one sum on this system that is NOT the school's
-- money. The balance sheet knows that and shows it as a liability, removed from
-- retained earnings, with a comment saying so in as many words.
--
-- The family it belongs to is never told.
--
-- Asked of the running code: where does a deposit appear?
--
--   Fees > Deposits              the office screen, opened when somebody leaves
--   Settings > Fee heads         the setup
--   the balance sheet            as a liability
--
--   the child's own profile      NOWHERE
--   the parent portal            NOWHERE
--   the printed statement        NOWHERE
--
-- fn_deposit_held exists, is granted, and has a wrapper in the app that no
-- screen calls. So the school holds Rs 5,000 of a family's money, and the only
-- place that says so is a screen the family cannot open and the office opens
-- once a year.
--
-- This is the same shape as the hand-keyed adjustment 0098 fixed, and worse in
-- one respect. An adjustment is the school's claim ON the family, and the school
-- has every reason to remember it. A deposit is the family's claim on the
-- SCHOOL, and the only party with a reason to remember it is the one who cannot
-- see it. A parent whose child leaves and who was never shown the deposit is
-- relying on the office to volunteer money back.
--
-- It is also why the parent's own page did not add up in a second way. 0098
-- made the challans plus the hand-keyed charges equal the balance. A deposit is
-- neither: it is paid, it is not owed, and it is held. Without a line for it a
-- parent who paid Rs 5,000 into a deposit sees it leave their pocket and appear
-- in no total anywhere.
--
-- WHAT THIS ADDS
--
-- `deposit_held` on fn_portal_child_fees, which the portal and the printed
-- statement now show, and which the office profile reads through the wrapper
-- that already existed. One figure, one function, three screens: the same
-- arrangement as the fee statement.
--
-- Re-runnable.
-- =============================================================================

create or replace function public.fn_portal_child_fees(p_student_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_fam uuid; v_out jsonb;
begin
  perform public.fn__assert_my_child(p_student_id);
  v_fam := public.my_family_id();

  select jsonb_build_object(
    'student_id', p_student_id,
    'balance', public.student_balance(p_student_id),
    'family_outstanding', public.family_outstanding(v_fam),
    'family_credit', public.family_credit(v_fam),
    -- Refundable money the school is HOLDING for this child. Not part of the
    -- balance, which is what is owed: this is the other direction, and a parent
    -- who is never shown it has no way to ask for it back.
    'deposit_held', public.fn__deposit_held(p_student_id),
    'invoices', coalesce((
      select jsonb_agg(jsonb_build_object(
        'period_month', i.period_month, 'due_date', i.due_date,
        'charge', b.charge, 'paid', b.allocated,
        'outstanding', b.charge - b.allocated, 'status', b.status
      ) order by i.period_month desc nulls last)
      from public.invoice_balances b
      join public.invoices i on i.id = b.invoice_id
      where b.student_id = p_student_id
    ), '[]'::jsonb),
    'adjustments', coalesce((
      select jsonb_agg(jsonb_build_object(
        'on', a.created_at::date,
        'amount', a.amount,
        'reason', coalesce(nullif(btrim(a.reason), ''), 'Adjustment')
      ) order by a.created_at desc)
      from public.adjustments a
      where a.student_id = p_student_id
    ), '[]'::jsonb),
    'charges_not_on_a_challan', coalesce((
      select sum(a.amount) from public.adjustments a where a.student_id = p_student_id
    ), 0),
    'receipts', coalesce((
      select jsonb_agg(jsonb_build_object(
        'receipt_no', p.receipt_no, 'amount', p.amount,
        'method', p.method, 'paid_on', p.created_at,
        'received_by', pr.full_name
      ) order by p.created_at desc)
      from public.payments p
      left join public.profiles pr on pr.id = p.received_by
      where p.family_id = v_fam and p.status = 'verified'
    ), '[]'::jsonb)
  ) into v_out;

  return v_out;
end;
$$;

revoke all on function public.fn_portal_child_fees(uuid) from public, anon;
grant execute on function public.fn_portal_child_fees(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- fn_deposit_held is now staff only
--
-- Found while wiring the line above, by asking who could already call it: it is
-- SECURITY DEFINER, granted to `authenticated`, and gated by NOTHING but
-- current_school_id(). Every signed-in account in a school could ask it for any
-- student id in that school, including a parent account, which is supposed to
-- have no reach beyond its own children.
--
-- Not enumerable in practice, because a student id is a uuid and a parent is
-- only ever handed their own. That is a reason it has not been exploited, not a
-- reason to leave it: 0033's whole design is that a parent's reach is decided by
-- fn__assert_my_child and not by which ids they happen to know.
--
-- The gate is is_staff() rather than the finance roles, matching fn_deposits_held
-- next to it: a class teacher asked whether a leaving pupil has money to collect
-- is answering a normal question, and the figure carries no other family's data.
--
-- The portal is unaffected. fn_portal_child_fees is SECURITY DEFINER and reaches
-- this as the owner after asserting the child, which is the same arrangement
-- fn__student_ledger uses.
-- ---------------------------------------------------------------------------
create or replace function public.fn_deposit_held(p_student_id uuid)
returns numeric language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_staff() then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  perform public.assert_own('students', p_student_id);
  return public.fn__deposit_held(p_student_id);
end;
$$;

-- The arithmetic, unchanged, with no gate: the portal reaches it as the owner
-- after asserting the child, and the staff wrapper above carries the gate.
create or replace function public.fn__deposit_held(p_student_id uuid)
returns numeric language sql stable security definer set search_path = public as $$
  select greatest(
    coalesce((
      select sum(al.amount)
        from public.payment_allocations al
        join public.payments p on p.id = al.payment_id
        join public.invoices i on i.id = al.invoice_id
       where i.school_id = public.current_school_id()
         and i.student_id = p_student_id
         and i.status <> 'void'
         and p.status = 'verified'
         and exists (
           select 1 from public.invoice_lines l
           join public.fee_heads h on h.id = l.fee_head_id
           where l.invoice_id = i.id and h.is_refundable)
    ), 0)
    - coalesce((
      select sum(r.amount) from public.deposit_refunds r
       where r.school_id = public.current_school_id()
         and r.student_id = p_student_id
    ), 0),
    0);
$$;

revoke all on function public.fn__deposit_held(uuid) from public, anon, authenticated;
revoke all on function public.fn_deposit_held(uuid) from public, anon;
grant execute on function public.fn_deposit_held(uuid) to authenticated;

do $assert$
begin
  if not exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'fn_portal_child_fees'
      and p.prosrc like '%deposit_held%')
  then
    raise exception '0103: fn_portal_child_fees does not report the deposit';
  end if;
  if has_function_privilege('anon', 'public.fn__deposit_held(uuid)', 'execute')
     or has_function_privilege('authenticated', 'public.fn__deposit_held(uuid)', 'execute') then
    raise exception '0103: the ungated deposit arithmetic is reachable by a client role';
  end if;
end $assert$;

-- ─────────────────────────────────────────────────────────────────────────
-- 0104_the_parent_nobody_can_see.sql
-- ─────────────────────────────────────────────────────────────────────────
-- =============================================================================
-- 0104 — A parent login attached to no family appeared on no screen
--
-- 0095 fixed this exact shape for STAFF: a login that was never attached to a
-- staff record was invisible, because the roster reads the staff table, so
-- creating a teacher login left the screen still saying "No staff yet". The fix
-- was fn_school_logins, which lists every login including the unattached ones.
--
-- It excluded parents, and said why:
--
--     -- screen. Mixing four hundred parents into a staff roster would bury the
--     and p.role <> 'parent'
--
-- That reason is right for a LINKED parent, and it hid the broken ones with
-- them. Measured on the running code, with a parent login whose family link was
-- never written:
--
--     Who can sign in            0 rows
--     the family page            0 rows
--     public.profiles            1 row
--     the parent's own portal    {"children": [], "full_name": "Unlinked Parent"}
--
-- So the parent sits at home looking at an empty portal with their own name at
-- the top of it, the office has no screen anywhere that shows the login exists,
-- and the only remedy anybody can find is to create a SECOND login for the same
-- address, which fails because the address is taken. There is no way out of that
-- state from inside the product.
--
-- IT IS REACHABLE BY AN ORDINARY FAILURE. createParentLogin does two things in
-- sequence: the edge function creates the auth user and the profile, and then
-- fn_link_parent writes the family. A dropped connection, an edge function that
-- is a version behind, or any error between those two awaits leaves the orphan.
-- That is not a hypothetical: the app already carries a warning banner about
-- exactly one of those failure modes.
--
-- THE CHANGE IS ONE CLAUSE, and it keeps 0095's reason intact:
--
--     and (p.role <> 'parent' or p.family_id is null)
--
-- A parent attached to a family is still kept out of the staff roster, which is
-- what stops four hundred of them burying it. A parent attached to NOTHING is
-- shown, because there are never many of them and each one is a person who
-- cannot use the thing they were given.
--
-- Re-runnable.
-- =============================================================================

create or replace function public.fn_school_logins()
returns table (
  profile_id uuid, full_name text, email text, role public.user_role,
  active boolean, staff_id uuid, staff_name text, last_sign_in_at timestamptz
) language plpgsql stable security definer set search_path = public as $$
begin
  if not public.has_role('owner', 'principal') then
    raise exception 'Only the owner or principal may see who can sign in'
      using errcode = '42501';
  end if;

  return query
  select p.id,
         p.full_name,
         u.email::text,
         p.role,
         p.active,
         s.id,
         s.full_name,
         u.last_sign_in_at
  from public.profiles p
  left join auth.users u on u.id = p.id
  left join public.staff s on s.profile_id = p.id
  where p.school_id = public.current_school_id()
    -- 0095's rule, with the hole closed. A parent WITH a family stays out of the
    -- staff roster: four hundred of them would bury it, and they are already
    -- listed on their own family's page. A parent with NO family is on no other
    -- screen in the product, so they belong here.
    and (p.role <> 'parent' or p.family_id is null)
  -- Unattached first: the whole point of this list is the login nobody has
  -- connected to anybody, and it is the one a school has to act on.
  order by (s.id is null) desc, p.full_name;
end;
$$;

revoke all on function public.fn_school_logins() from public, anon;
grant execute on function public.fn_school_logins() to authenticated;

do $assert$
begin
  if not exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'fn_school_logins'
      and p.prosrc like '%p.family_id is null%')
  then
    raise exception '0104: fn_school_logins still hides a parent login that '
      'belongs to no family, and that login is on no other screen';
  end if;
end $assert$;

-- ─────────────────────────────────────────────────────────────────────────
-- Record what this bundle applied (no-op before 0069 creates the ledger)
-- ─────────────────────────────────────────────────────────────────────────
do $ledger$
begin
  if to_regprocedure('public.fn_record_migration(text,text,text)') is null then
    raise notice 'migration ledger not present yet — nothing recorded';
    return;
  end if;
  perform public.fn_record_migration('0098_one_number.sql', '12_one_number.sql');
  perform public.fn_record_migration('0099_one_headcount.sql', '12_one_number.sql');
  perform public.fn_record_migration('0100_the_attendance_rule_is_one_place.sql', '12_one_number.sql');
  perform public.fn_record_migration('0101_a_dropped_key_is_lost_data.sql', '12_one_number.sql');
  perform public.fn_record_migration('0102_the_drawer_and_the_clerk.sql', '12_one_number.sql');
  perform public.fn_record_migration('0103_the_familys_money.sql', '12_one_number.sql');
  perform public.fn_record_migration('0104_the_parent_nobody_can_see.sql', '12_one_number.sql');
end $ledger$;

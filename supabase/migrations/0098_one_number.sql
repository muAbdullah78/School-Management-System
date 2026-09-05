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

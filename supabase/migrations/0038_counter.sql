-- =============================================================================
-- 0038 — The fee counter: open on today's work, not on an empty box.
--
-- WHY
--
-- OurSchoolSoftware's Fee Payment screen — their busiest, the one a clerk sits
-- on all morning during the first ten days of a month — opens showing:
--
--   * four figures: unpaid invoices, income today, expense today, balance today
--   * TWO search boxes side by side: by student name/code (or by scanning the
--     fee slip), and by the father's CNIC to pull up every connected child
--   * the day's payments, already listed, without searching for anything
--
-- Ours opens as a single empty text input. Nothing is on screen until the clerk
-- types, and there is no way to see what has been collected today without
-- leaving for a report. That is the difference between a counter and a lookup
-- form, and it is the single most-used screen in the product.
--
-- This migration adds the two reads that screen needs. No new tables: every
-- figure is derived, so none of it can drift from the ledger.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. The four tiles.
--
-- Deliberately one round trip rather than four. The clerk reloads this screen
-- constantly and each figure is a cheap aggregate; four separate calls would
-- mean four sets of latency to Mumbai for numbers that must agree with each
-- other anyway.
--
-- "Unpaid invoices" counts CHALLANS still owing, not students — that is the
-- figure their screen shows and it is the one a clerk is asked for ("how many
-- challans are still out?"). It is not the same as the defaulter count, and
-- conflating them is how a dashboard ends up lying.
-- ---------------------------------------------------------------------------
create or replace function public.fn_counter_summary()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_school   uuid := public.current_school_id();
  v_unpaid   integer;
  v_income   numeric;
  v_expense  numeric;
  v_pending  integer;
  v_pending_amt numeric;
begin
  if not public.is_staff() then
    raise exception 'Not permitted' using errcode = '42501';
  end if;

  -- An invoice is "unpaid" when what it charges exceeds what has been allocated
  -- to it from VERIFIED payments. Derived rather than read off invoices.status,
  -- because status is a label and this is the money.
  select count(*) into v_unpaid
  from public.invoices i
  where i.school_id = v_school
    and i.status <> 'void'
    and (
      coalesce((select sum(case when l.is_discount then -l.amount else l.amount end)
                  from public.invoice_lines l where l.invoice_id = i.id), 0)
      + coalesce(i.fine, 0)
      - coalesce((select sum(al.amount)
                    from public.payment_allocations al
                    join public.payments p on p.id = al.payment_id
                   where al.invoice_id = i.id and p.status = 'verified'), 0)
    ) > 0;

  select coalesce(sum(p.amount), 0) into v_income
  from public.payments p
  where p.school_id = v_school
    and p.status = 'verified'
    and p.created_at >= date_trunc('day', now())
    and p.created_at <  date_trunc('day', now()) + interval '1 day';

  select coalesce(sum(e.amount), 0) into v_expense
  from public.expenses e
  where e.school_id = v_school
    and e.spent_on = current_date
    and e.reversal_of is null;

  -- Money taken but not yet cleared. Shown next to the day's income because a
  -- clerk who has accepted three bank transfers needs to know they are not in
  -- that income figure — otherwise the drawer looks short at closing.
  select count(*), coalesce(sum(p.amount), 0) into v_pending, v_pending_amt
  from public.payments p
  where p.school_id = v_school and p.status = 'pending';

  return jsonb_build_object(
    'unpaid_invoices', v_unpaid,
    'income_today',    v_income,
    'expense_today',   v_expense,
    'balance_today',   v_income - v_expense,
    'pending_count',   v_pending,
    'pending_amount',  v_pending_amt);
end;
$$;

-- ---------------------------------------------------------------------------
-- 2. Latest payments — the list that makes the screen useful on open.
--
-- Columns chosen to match theirs: student, parent, class, what it paid for,
-- amount, late fee, discount, note, and WHO took the money. That last one is
-- what makes the list a control rather than a convenience — a clerk can see
-- their own receipts, and an owner can see whose counter the cash came over.
--
-- A caveat that belongs in the schema rather than only in the UI: late_fee and
-- discount are the totals on the CHALLANS this receipt was allocated to, not a
-- share apportioned to this payment. Two part-payments against one challan will
-- each report that challan's full fine. The alternative — apportioning — would
-- invent a number that appears nowhere in the ledger, which is worse. The
-- column names and the UI heading both say "on the challans this paid".
-- ---------------------------------------------------------------------------
create or replace function public.fn_recent_payments(p_limit integer default 25)
returns table (
  payment_id     uuid,
  receipt_no     bigint,
  paid_at        timestamptz,
  student_id     uuid,
  student_name   text,
  gr_no          text,
  family_id      uuid,
  parent_name    text,
  class_name     text,
  section_name   text,
  paid_for       text,
  amount         numeric,
  method         public.payment_method,
  late_fee       numeric,
  discount       numeric,
  note           text,
  status         text,
  received_by    text,
  is_reversal    boolean
) language plpgsql stable security definer set search_path = public as $$
declare v_school uuid := public.current_school_id();
begin
  if not public.is_staff() then
    raise exception 'Not permitted' using errcode = '42501';
  end if;

  return query
  select
    p.id,
    p.receipt_no,
    p.created_at,
    eff.sid,
    -- A family payment has NO payments.student_id: the money came from the
    -- father, not from a child. Falling back to the allocations is what makes
    -- this column non-empty for exactly the payments the family feature
    -- creates, and it names every child the receipt actually covered — which is
    -- what the clerk needs to say out loud at the window.
    coalesce(s.full_name, alloc.names, '—'),
    s.gr_no,
    p.family_id,
    f.head_name,
    c.name,
    sec.name,
    (select string_agg(distinct
              coalesce(to_char(i.period_month, 'Mon YYYY'), coalesce(i.notes, 'Other')),
              ', ' order by coalesce(to_char(i.period_month, 'Mon YYYY'), coalesce(i.notes, 'Other')))
       from public.payment_allocations al
       join public.invoices i on i.id = al.invoice_id
      where al.payment_id = p.id),
    p.amount,
    p.method,
    coalesce((select sum(d.fine)
                from (select distinct i2.id, i2.fine
                        from public.payment_allocations al2
                        join public.invoices i2 on i2.id = al2.invoice_id
                       where al2.payment_id = p.id) d), 0),
    coalesce((select sum(l.amount)
                from public.payment_allocations al3
                join public.invoice_lines l on l.invoice_id = al3.invoice_id
               where al3.payment_id = p.id and l.is_discount), 0),
    p.note,
    p.status::text,
    coalesce(pr.full_name, '—'),
    p.reversal_of is not null
  from public.payments p
  -- Which children this receipt settled anything for.
  left join lateral (
    select string_agg(distinct s2.full_name, ', ' order by s2.full_name) as names,
           count(distinct s2.id)                                        as n,
           (array_agg(distinct s2.id))[1]                               as only_id
      from public.payment_allocations al4
      join public.invoices i4  on i4.id = al4.invoice_id
      join public.students s2  on s2.id = i4.student_id
     where al4.payment_id = p.id
  ) alloc on true
  -- The one student this payment is ABOUT, if there is exactly one. A family
  -- payment spread across three siblings has no single class, and showing one
  -- of the three would be worse than showing none.
  left join lateral (
    select coalesce(p.student_id,
                    case when alloc.n = 1 then alloc.only_id end) as sid
  ) eff on true
  left join public.students   s   on s.id = eff.sid
  left join public.families    f  on f.id = p.family_id
  left join public.enrollments e  on e.student_id = eff.sid and e.status = 'active'
  left join public.classes     c  on c.id = e.class_id
  left join public.sections    sec on sec.id = e.section_id
  left join public.profiles    pr on pr.id = p.received_by
  where p.school_id = v_school
  order by p.created_at desc
  limit greatest(1, least(coalesce(p_limit, 25), 200));
end;
$$;

-- ---------------------------------------------------------------------------
-- 3. Grants.
--
-- Both are staff-gated inside the function bodies, so a signed-in parent
-- calling either directly gets 42501 rather than a school's cash position.
-- ---------------------------------------------------------------------------
grant execute on function public.fn_counter_summary()          to authenticated;
grant execute on function public.fn_recent_payments(integer)   to authenticated;

revoke all on function public.fn_counter_summary()        from anon;
revoke all on function public.fn_recent_payments(integer) from anon;

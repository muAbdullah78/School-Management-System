-- =============================================================================
-- 0060 — A security deposit was counted as profit.
--
-- Demonstrated on a real database before anything here was written. One pupil,
-- one invoice: Rs 2,000 tuition + Rs 5,000 REFUNDABLE security deposit, family
-- pays all 7,000.
--
--   fee_income ................................. 7,000   (should be 2,000)
--   profit ..................................... 7,000   (should be 2,000)
--   balance-sheet liability for the deposit .... 0       (should be 5,000)
--   ways to record a refund .................... none
--   functions reading fee_heads.is_refundable .. none
--
-- fn_finance_summary computes fee_income as the sum of every verified payment,
-- and profit = fee_income + other_income - expenses. A deposit is a payment, so
-- it went straight into profit. A school of 200 pupils on a Rs 5,000 deposit
-- shows ONE MILLION RUPEES of profit that is a liability — and a proprietor pays
-- a salary or a building instalment out of it.
--
-- fee_heads.is_refundable and the 'security_deposit' value of fee_head_type had
-- both existed since the first migration and nothing read either. The concept
-- was modelled and never wired — the same pattern as students.photo_url and
-- enrollments.stream.
--
-- The design, with the argument against each decision, is in
-- docs/DEPOSITS-DESIGN.md. The two that shape this file:
--
--  * A REFUNDABLE CHARGE GETS ITS OWN INVOICE. payment_allocations allocates to
--    an INVOICE, not a line, so on a mixed invoice a part-payment cannot be
--    split — and every splitting rule I could invent is a rule a parent can
--    argue with at the counter and the school cannot defend, because it exists
--    only inside the software. With refundable charges on their own invoice,
--    "how much deposit has this family paid" is exactly "allocations against
--    their deposit invoices", with no allocation-order rule anywhere.
--
--  * NETTING ON LEAVING IS AN ADJUSTMENT, NEVER A PAYMENT. The tempting
--    implementation of "the deposit clears the arrears" is a payments row. That
--    would be a lie in the cash reports: fn_finance_summary, the day book and
--    the till all read payments, so money nobody handed over would appear as
--    taken that day and the till would not balance.
--
-- SAFE BY DEFAULT: a school with no refundable fee head sees NO change to any
-- figure, because every sum below is zero. Nothing moves until somebody
-- deliberately marks a head refundable.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. An invoice may not mix refundable and non-refundable lines
--
-- This is the invariant the whole feature rests on. Enforced with a trigger so
-- it holds no matter which path inserts the line — the importer, the monthly
-- generator, a manual charge or a future screen.
--
-- HONEST ABOUT ITS LIMITS: the trigger reads sibling rows, so two genuinely
-- concurrent inserts of different kinds could both pass. That is a data-entry
-- invariant, not a concurrency defence — a school enters invoice lines from one
-- screen at a time — and the derived figures stay correct regardless, because a
-- mixed invoice is refused at the next line rather than silently miscounted.
-- ---------------------------------------------------------------------------
create or replace function public.fn_invoice_no_mixed_refundable()
returns trigger language plpgsql as $$
declare v_refundable int; v_ordinary int;
begin
  select count(*) filter (where h.is_refundable),
         count(*) filter (where not h.is_refundable)
    into v_refundable, v_ordinary
  from public.invoice_lines l
  join public.fee_heads h on h.id = l.fee_head_id
  where l.invoice_id = new.invoice_id;

  if v_refundable > 0 and v_ordinary > 0 then
    raise exception 'A refundable charge must be billed on its own challan, not '
                    'mixed with ordinary fees. Issue the deposit separately.'
      using errcode = '23514';
  end if;
  return null;
end;
$$;

-- IMMEDIATE, not deferrable. The first version of this was a
-- `deferrable initially deferred` constraint trigger, which fires at COMMIT —
-- so the error arrived detached from the statement that caused it, the whole
-- transaction died at the end instead of the one bad insert, and a caller could
-- not catch it at all. Caught by assertion 1 of supabase/tests/deposits.sql
-- failing: the raise never happened inside the block under test.
--
-- A plain AFTER ROW trigger fires within the statement, so the bad insert is the
-- thing that fails and the message points at it. A multi-row INSERT still works:
-- AFTER ROW triggers run for every affected row, so a statement adding both a
-- refundable and an ordinary line is refused on the second one.
drop trigger if exists trg_invoice_no_mixed_refundable on public.invoice_lines;
create trigger trg_invoice_no_mixed_refundable
  after insert or update on public.invoice_lines
  for each row execute function public.fn_invoice_no_mixed_refundable();

comment on function public.fn_invoice_no_mixed_refundable() is
  'Keeps refundable charges on their own invoice, so allocations against that '
  'invoice are unambiguously deposit money. See docs/DEPOSITS-DESIGN.md D1.';

-- ---------------------------------------------------------------------------
-- 2. The refund ledger
--
-- The ONLY new table. Everything else — what was charged, what was paid — is
-- derived from the invoice and payment machinery that already exists and is
-- already tested. A second place recording "how much has this family paid" would
-- be a second thing to disagree with the first.
-- ---------------------------------------------------------------------------
create table if not exists public.deposit_refunds (
  id            uuid primary key default gen_random_uuid(),
  school_id     uuid not null references public.schools(id) on delete cascade,
  student_id    uuid not null references public.students(id) on delete cascade,
  -- The total liability discharged. Split into the two ways it can be
  -- discharged, which must sum to `amount`.
  amount        numeric not null check (amount > 0),
  -- Applied against what the family owed. Recorded as an `adjustments` row, so
  -- no cash report gains money that never moved.
  applied_to_dues numeric not null default 0 check (applied_to_dues >= 0),
  -- Actually handed back.
  paid_out      numeric not null default 0 check (paid_out >= 0),
  method        text,
  reason        text,
  -- Whether the pupil was STILL ENROLLED when this was refunded. A deposit is
  -- normally held until leaving; an early refund is allowed (see D6) and is
  -- flagged here so the report can show those separately rather than having
  -- them look identical to ordinary leaving refunds.
  was_enrolled  boolean not null default false,
  adjustment_id uuid references public.adjustments(id),
  refunded_by   uuid,
  refunded_on   date not null default current_date,
  created_at    timestamptz not null default now(),
  constraint deposit_refunds_split_chk
    check (applied_to_dues + paid_out = amount)
);

create index if not exists ix_deposit_refunds_student
  on public.deposit_refunds(school_id, student_id);

alter table public.deposit_refunds enable row level security;

-- Append-only, like payments: a refund that can be edited is a refund that can
-- be made to disappear. A mistake is corrected by a second row, not by rewriting
-- the first.
drop policy if exists deposit_refunds_select on public.deposit_refunds;
create policy deposit_refunds_select on public.deposit_refunds
  for select using (
    school_id = public.current_school_id()
    and public.may_view('owner', 'principal', 'admin_clerk', 'accountant'));

drop policy if exists deposit_refunds_insert on public.deposit_refunds;
create policy deposit_refunds_insert on public.deposit_refunds
  for insert with check (
    school_id = public.current_school_id()
    and public.has_role('owner', 'principal'));

grant select on public.deposit_refunds to authenticated;
grant insert on public.deposit_refunds to authenticated;

-- ---------------------------------------------------------------------------
-- 3. How much refundable money is this school holding for this pupil?
--
-- Derived, never stored. Allocations against invoices whose lines are refundable,
-- minus refunds already made.
--
-- Note what is NOT here: any filter on the pupil's status. The report of what is
-- held MUST include children who have left and not been refunded, because that
-- is exactly the money the school still owes. Excluding off-roll pupils would
-- make the liability shrink the moment a child left — the same mistake
-- fn_report_balance_sheet already documents avoiding for arrears.
-- ---------------------------------------------------------------------------
create or replace function public.fn_deposit_held(p_student_id uuid)
returns numeric language sql stable security definer set search_path = public as $$
  select greatest(
    coalesce((
      -- Paid in, against deposit invoices only.
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

comment on function public.fn_deposit_held(uuid) is
  'Refundable money the school is holding for this pupil: allocations against '
  'deposit invoices, less refunds. Derived — never stored, so it cannot drift.';

-- ---------------------------------------------------------------------------
-- 4. Charging a deposit — on its own invoice, by construction
-- ---------------------------------------------------------------------------
create or replace function public.fn_charge_deposit(
  p_student_id uuid, p_fee_head_id uuid, p_amount numeric,
  p_due_date date default null, p_note text default null
) returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_school uuid := public.current_school_id();
  v_enr uuid; v_sess uuid; v_inv uuid; v_name text; v_refundable boolean;
begin
  if not public.has_role('owner', 'principal', 'admin_clerk', 'accountant') then
    raise exception 'Not permitted to charge a deposit' using errcode = '42501';
  end if;
  perform public.assert_own('students', p_student_id);
  perform public.assert_own('fee_heads', p_fee_head_id);

  if coalesce(p_amount, 0) <= 0 then
    raise exception 'A deposit must be more than zero';
  end if;

  select is_refundable, name into v_refundable, v_name
    from public.fee_heads where id = p_fee_head_id and school_id = v_school;
  if not coalesce(v_refundable, false) then
    raise exception '% is not marked refundable. Use the ordinary fee screens '
                    'for it, or mark the head refundable first.', coalesce(v_name, 'That fee head');
  end if;

  select current_session_id into v_sess from public.school_settings where school_id = v_school;
  if v_sess is null then raise exception 'No current session'; end if;

  select id into v_enr from public.enrollments
   where school_id = v_school and student_id = p_student_id
     and session_id = v_sess and status = 'active'
   order by created_at desc limit 1;
  if v_enr is null then
    raise exception 'This pupil has no active enrolment in the current session';
  end if;

  -- Its OWN invoice. period_month is null: a deposit is a once-ever charge and
  -- not part of any month's billing, so it must never be picked up by a monthly
  -- run or counted as a month a family owes.
  insert into public.invoices (school_id, student_id, enrollment_id, session_id,
                               period_month, status, due_date, notes, issued_at)
  values (v_school, p_student_id, v_enr, v_sess, null, 'issued',
          coalesce(p_due_date, current_date),
          coalesce(nullif(btrim(p_note), ''), v_name || ' (refundable)'), now())
  returning id into v_inv;

  insert into public.invoice_lines (school_id, invoice_id, fee_head_id, description, amount)
  values (v_school, v_inv, p_fee_head_id, v_name || ' (refundable)', p_amount);

  return jsonb_build_object(
    'invoice_id', v_inv, 'amount', p_amount, 'fee_head', v_name);
end;
$$;

-- ---------------------------------------------------------------------------
-- 5. Refunding it
--
-- The arrears are netted FIRST, because that is how a school does it at the
-- counter: "you owe 3,000, your deposit is 5,000, here is 2,000 back."
--
-- The netting is an ADJUSTMENT and not a payment. A payments row would put money
-- nobody handed over into fn_finance_summary, the day book and the till.
-- ---------------------------------------------------------------------------
create or replace function public.fn_refund_deposit(
  p_student_id uuid,
  p_amount numeric default null,       -- null = everything held
  p_net_against_dues boolean default true,
  p_method text default 'cash',
  p_reason text default null
) returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_school uuid := public.current_school_id();
  v_actor  uuid := auth.uid();
  v_held   numeric;
  v_amount numeric;
  v_bal    numeric;
  v_applied numeric := 0;
  v_paid   numeric;
  v_adj    uuid;
  v_name   text;
  v_enrolled boolean;
  v_id     uuid;
begin
  -- Money leaving the school is an approval, not a clerical act.
  if not public.has_role('owner', 'principal') then
    raise exception 'Only an owner or principal may refund a deposit'
      using errcode = '42501';
  end if;
  perform public.assert_own('students', p_student_id);

  select full_name into v_name from public.students
   where id = p_student_id and school_id = v_school;

  v_held := public.fn_deposit_held(p_student_id);
  if v_held <= 0 then
    raise exception 'No refundable deposit is held for %', coalesce(v_name, 'this pupil');
  end if;

  v_amount := coalesce(p_amount, v_held);
  if v_amount <= 0 then
    raise exception 'A refund must be more than zero';
  end if;
  if v_amount > v_held then
    raise exception 'Only % is held for %. A refund cannot exceed it.',
      to_char(v_held, 'FM999999999.00'), coalesce(v_name, 'this pupil');
  end if;

  -- Still on the roll? Recorded rather than refused: a school will occasionally
  -- refund early, and refusing outright pushes them into booking it as an
  -- expense, where it vanishes from the deposit ledger entirely.
  select exists (
    select 1 from public.enrollments e
     where e.school_id = v_school and e.student_id = p_student_id
       and e.status = 'active'
  ) into v_enrolled;

  if coalesce(p_net_against_dues, true) then
    v_bal := public.student_balance(p_student_id);
    -- The deposit invoice itself is part of that balance if it was never paid;
    -- but fn_deposit_held only counts ALLOCATED money, so anything held here has
    -- already been paid and is not sitting in the balance as a charge.
    if v_bal > 0 then
      v_applied := least(v_bal, v_amount);
      v_adj := public.fn_add_adjustment(
        p_student_id, -v_applied,
        coalesce(nullif(btrim(p_reason), ''), 'Security deposit applied on leaving'));
    end if;
  end if;

  v_paid := v_amount - v_applied;

  insert into public.deposit_refunds
    (school_id, student_id, amount, applied_to_dues, paid_out, method, reason,
     was_enrolled, adjustment_id, refunded_by)
  values (v_school, p_student_id, v_amount, v_applied, v_paid,
          nullif(btrim(p_method), ''), nullif(btrim(p_reason), ''),
          v_enrolled, v_adj, v_actor)
  returning id into v_id;

  return jsonb_build_object(
    'refund_id', v_id,
    'student_name', coalesce(v_name, ''),
    'amount', v_amount,
    'applied_to_dues', v_applied,
    'paid_out', v_paid,
    'still_held', public.fn_deposit_held(p_student_id),
    'was_enrolled', v_enrolled);
end;
$$;

-- ---------------------------------------------------------------------------
-- 6. The report: what is the school holding, and for whom?
--
-- Includes pupils who have LEFT and not been refunded. That is the point — it is
-- the money still owed.
-- ---------------------------------------------------------------------------
create or replace function public.fn_deposits_held()
returns table (
  student_id uuid, full_name text, gr_no text, father_name text,
  class_name text, status text, left_on date,
  collected numeric, refunded numeric, held numeric
)
language plpgsql stable security definer set search_path = public as $$
declare v_school uuid := public.current_school_id(); v_sess uuid;
begin
  if not public.may_view('owner', 'principal', 'admin_clerk', 'accountant') then
    raise exception 'Not permitted to read the accounts' using errcode = '42501';
  end if;
  select current_session_id into v_sess from public.school_settings where school_id = v_school;

  return query
  with paid as (
    select i.student_id, sum(al.amount) as amt
      from public.payment_allocations al
      join public.payments p on p.id = al.payment_id
      join public.invoices i on i.id = al.invoice_id
     where i.school_id = v_school and i.status <> 'void' and p.status = 'verified'
       and exists (
         select 1 from public.invoice_lines l
         join public.fee_heads h on h.id = l.fee_head_id
         where l.invoice_id = i.id and h.is_refundable)
     group by i.student_id
  ),
  back as (
    select r.student_id, sum(r.amount) as amt
      from public.deposit_refunds r
     where r.school_id = v_school
     group by r.student_id
  )
  select s.id, s.full_name, s.gr_no, s.father_name,
         c.name, s.status::text, s.left_on,
         coalesce(pd.amt, 0), coalesce(b.amt, 0),
         coalesce(pd.amt, 0) - coalesce(b.amt, 0)
    from paid pd
    join public.students s on s.id = pd.student_id and s.school_id = v_school
    left join back b on b.student_id = s.id
    left join public.enrollments e
      on e.school_id = v_school and e.student_id = s.id and e.session_id = v_sess
    left join public.classes c on c.id = e.class_id and c.school_id = v_school
   where coalesce(pd.amt, 0) - coalesce(b.amt, 0) > 0
   order by s.full_name;
end;
$$;

-- ---------------------------------------------------------------------------
-- 7. Take deposits out of income, and put them on the liability side
--
-- Rewritten programmatically? No — these two functions are small enough to
-- restate, and the change is not a mechanical substitution. But BOTH are
-- rewritten in full here rather than patched by string replacement, because a
-- partial edit of a money function is how a report starts disagreeing with
-- itself.
-- ---------------------------------------------------------------------------
create or replace function public.fn_finance_summary(p_from date, p_to date)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_fee     numeric;
  v_dep     numeric;
  v_other   numeric;
  v_exp     numeric;
  v_by_cat  jsonb;
  v_school  uuid := public.current_school_id();
begin
  if not public.may_view('owner', 'principal', 'accountant') then
    raise exception 'Not permitted to view finances';
  end if;

  -- Gross receipts: verified payments in the window. Reversals carry a negative
  -- amount, so a reversed payment removes itself automatically.
  select coalesce(sum(p.amount), 0) into v_fee
  from public.payments p
  where p.school_id = v_school and p.status = 'verified'
    and p.created_at::date between p_from and p_to;

  -- Of which REFUNDABLE — money the school holds and must give back. Counting
  -- it as income is what made a Rs 5,000 deposit into Rs 5,000 of profit; at
  -- 200 pupils that is a million rupees a proprietor would take decisions on.
  --
  -- Matched by ALLOCATION against a deposit invoice, not by payment: a payment
  -- is not intrinsically a deposit, the invoice it settles is.
  select coalesce(sum(al.amount), 0) into v_dep
  from public.payment_allocations al
  join public.payments p on p.id = al.payment_id
  join public.invoices i on i.id = al.invoice_id
  where p.school_id = v_school and p.status = 'verified'
    and p.created_at::date between p_from and p_to
    and i.school_id = v_school and i.status <> 'void'
    and exists (
      select 1 from public.invoice_lines l
      join public.fee_heads h on h.id = l.fee_head_id
      where l.invoice_id = i.id and h.is_refundable);

  select coalesce(sum(o.amount), 0) into v_other
  from public.other_income o
  where o.school_id = v_school and o.received_on between p_from and p_to;

  select coalesce(sum(e.amount), 0) into v_exp
  from public.expenses e
  where e.school_id = v_school and e.spent_on between p_from and p_to;

  select coalesce(jsonb_agg(x order by x.total desc), '[]'::jsonb) into v_by_cat
  from (
    select coalesce(c.name, 'Uncategorised') as category,
           sum(e.amount) as total
    from public.expenses e
    left join public.expense_categories c on c.id = e.category_id
    where e.school_id = v_school and e.spent_on between p_from and p_to
    group by 1
    having sum(e.amount) <> 0
  ) x;

  return jsonb_build_object(
    'from', p_from, 'to', p_to,
    -- NET of deposits. A school with no refundable head sees exactly the old
    -- number, because v_dep is zero.
    'fee_income', v_fee - v_dep,
    -- Both halves are reported too, so a clerk reconciling against the till sees
    -- the CASH they counted as well as the INCOME that excludes the deposit.
    -- Replacing one number with another and saying nothing is how a school
    -- stops trusting a report.
    'fee_receipts_gross', v_fee,
    'deposits_collected', v_dep,
    'other_income', v_other,
    'total_income', v_fee - v_dep + v_other,
    'expenses', v_exp,
    'profit', v_fee - v_dep + v_other - v_exp,
    'expenses_by_category', v_by_cat);
end;
$$;

-- The balance sheet gains the liability. Patched by replacement rather than
-- retyped: it is one of the largest functions in the schema and hand-retyping it
-- would be the fourth time this project nearly reverted a stack of fixes that
-- way.
do $bs$
declare v_def text; v_new text;
begin
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'fn_report_balance_sheet';
  if v_def is null then
    raise exception '0060: fn_report_balance_sheet not found';
  end if;

  -- ALREADY PATCHED: nothing to do. This guard is load-bearing, not tidiness.
  -- Without it, re-running this migration inserts `v_deposits numeric;` a second
  -- time and the whole file dies with `duplicate declaration at or near
  -- "v_deposits"`. Found by re-running it, which is exactly what a school does
  -- when a bundle is pasted twice.
  --
  -- Keyed on the OUTPUT it produces, not on a flag: if a bundle ever restores
  -- the pre-0060 definition, deposits_held disappears and the patch correctly
  -- runs again.
  if v_def like '%deposits_held%' then
    return;
  end if;

  -- Declare the new variable.
  v_new := replace(v_def,
    '  v_students   int;',
    '  v_students   int;' || E'\n' || '  v_deposits   numeric;');

  -- Compute it, right after the expenses figure.
  v_new := replace(v_new,
    '  -- ---- money held that is not against a charge yet ----',
    '  -- ---- refundable money held, which is a LIABILITY and not income ----'
    || E'\n' ||
    '  -- Every deposit ever collected and not yet refunded, as at the date.' || E'\n' ||
    '  -- Not restricted to pupils on the roll: a child who has left and not been' || E'\n' ||
    '  -- refunded is exactly the money the school still owes.' || E'\n' ||
    '  select coalesce(sum(al.amount), 0) - coalesce((' || E'\n' ||
    '           select sum(r.amount) from public.deposit_refunds r' || E'\n' ||
    '            where r.school_id = v_school and r.refunded_on <= v_as_at), 0)' || E'\n' ||
    '    into v_deposits' || E'\n' ||
    '  from public.payment_allocations al' || E'\n' ||
    '  join public.payments p on p.id = al.payment_id' || E'\n' ||
    '  join public.invoices i on i.id = al.invoice_id' || E'\n' ||
    '  where p.school_id = v_school and p.status = ''verified''' || E'\n' ||
    '    and p.created_at::date <= v_as_at' || E'\n' ||
    '    and i.school_id = v_school and i.status <> ''void''' || E'\n' ||
    '    and exists (select 1 from public.invoice_lines l' || E'\n' ||
    '                join public.fee_heads h on h.id = l.fee_head_id' || E'\n' ||
    '                where l.invoice_id = i.id and h.is_refundable);' || E'\n' ||
    '  if v_deposits < 0 then v_deposits := 0; end if;' || E'\n\n' ||
    '  -- ---- money held that is not against a charge yet ----');

  -- Report it on the liability side, and take it out of what the school kept.
  v_new := replace(v_new,
    '    ''advance_held'',       v_advance,',
    '    ''advance_held'',       v_advance,' || E'\n' ||
    '    -- A refundable deposit is the one kind of money here that is NOT the' || E'\n' ||
    '    -- school''''s. Shown on the liability side, and removed from the' || E'\n' ||
    '    -- retained figure below.' || E'\n' ||
    '    ''deposits_held'',      v_deposits,' || E'\n' ||
    '    ''retained'',           v_receipts + v_other_in - v_expenses - v_deposits,');

  if v_new = v_def then
    raise exception '0060: no replacement matched in fn_report_balance_sheet — '
                    'the function has changed shape; re-check this block';
  end if;
  execute v_new;
end;
$bs$;

-- The end state, asserted.
do $check$
begin
  if not exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = 'fn_report_balance_sheet'
       and p.prosrc like '%deposits_held%'
  ) then
    raise exception '0060: fn_report_balance_sheet does not report deposits_held';
  end if;
  if not exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = 'fn_finance_summary'
       and p.prosrc like '%deposits_collected%'
  ) then
    raise exception '0060: fn_finance_summary does not report deposits_collected';
  end if;
end;
$check$;

-- ---------------------------------------------------------------------------
-- 8. A gap in 0059, found by wiring this feature
--
-- fn_profit_snapshot is the Accounts overview. It calls fn_finance_summary three
-- times and builds a jsonb; it writes nothing. But it is declared VOLATILE, and
-- 0059 rewrote read gates only in STABLE functions — on the reasoning that a
-- VOLATILE function can write and has_role inside one is not a read gate.
--
-- So it kept its has_role gate and refuses `readonly`, while 0059's companion
-- change put Accounts into the observer's navigation. An observer opening
-- Accounts got 'Not permitted to view finances' on the one screen the module
-- exists for.
--
-- check-readonly-writes.py could not see it either: it looks for STABLE
-- SECURITY DEFINER functions left on has_role, and this is VOLATILE. A blind
-- spot in the guard AND in the migration, in the same place.
--
-- Fixed both ways round: the gate becomes may_view, and the function is declared
-- STABLE — which it truthfully is — so it falls inside the guard's view from now
-- on rather than needing a special case. supabase/tests/readonly_role.sql also
-- gains a positive assertion that walks the observer's navigation and requires
-- every screen behind it to ANSWER, because a nav entry whose screen errors is
-- exactly this defect and only walking it catches the next one.
-- ---------------------------------------------------------------------------
do $snapshot$
declare v_def text; v_new text;
begin
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'fn_profit_snapshot';
  if v_def is null then return; end if;

  v_new := replace(v_def, 'public.has_role(', 'public.may_view(');
  v_new := replace(v_new, ' has_role(', ' may_view(');
  -- Declared VOLATILE by omission, so pg_get_functiondef prints no volatility
  -- keyword at all — there is nothing to replace, only somewhere to insert.
  -- The header it emits is:
  --     LANGUAGE plpgsql
  --      SECURITY DEFINER
  -- with a leading space on the second line.
  --
  -- Matched with `\s+` rather than chr(10) and a counted space. This header is
  -- generated by Postgres itself rather than copied out of prosrc, so its line
  -- ending really is always a line feed -- but the exact spacing has changed
  -- between server versions before, and a pattern that is right for one reason
  -- and wrong for another is not worth keeping when `\s+` is right for both.
  -- supabase/check-patch-anchors.py fails the build on the old form.
  if v_new not like '%STABLE%' then
    v_new := regexp_replace(v_new, 'LANGUAGE plpgsql\s+SECURITY DEFINER',
                            'LANGUAGE plpgsql' || chr(10) || ' STABLE SECURITY DEFINER');
  end if;
  execute v_new;
end;
$snapshot$;

do $check$
begin
  if not exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = 'fn_profit_snapshot'
       and p.prosrc like '%may_view(%'
  ) then
    raise exception '0060: fn_profit_snapshot still refuses an observer';
  end if;
  if not exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = 'fn_profit_snapshot'
       and p.provolatile in ('s','i')
  ) then
    raise exception '0060: fn_profit_snapshot is still VOLATILE, so '
                    'check-readonly-writes.py cannot see it';
  end if;
end;
$check$;

-- ---------------------------------------------------------------------------
-- 9. Grants
-- ---------------------------------------------------------------------------
revoke all on function public.fn_deposit_held(uuid) from public;
revoke all on function public.fn_charge_deposit(uuid, uuid, numeric, date, text) from public;
revoke all on function public.fn_refund_deposit(uuid, numeric, boolean, text, text) from public;
revoke all on function public.fn_deposits_held() from public;

grant execute on function public.fn_deposit_held(uuid) to authenticated;
grant execute on function public.fn_charge_deposit(uuid, uuid, numeric, date, text) to authenticated;
grant execute on function public.fn_refund_deposit(uuid, numeric, boolean, text, text) to authenticated;
grant execute on function public.fn_deposits_held() to authenticated;

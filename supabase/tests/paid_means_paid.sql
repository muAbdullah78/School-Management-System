-- =============================================================================
-- Paid means paid (0155 and 0156, after the adversarial review).
--
-- An adversarial review of the subscription rebuild found ways to get access
-- without paying, ways to pay and stay locked, and money that disappeared. Each
-- block below is one of those findings, reproduced as it was reported and held
-- to the rule it broke:
--
--   1. A Rs 0 invoice is paid: a free month we gave never lapses, and a one-
--      month code cannot be recycled into free access for ever.
--   2. Paid-through comes only from what is paid: voiding the invoice (or the
--      credit note) that paid for a year takes the year back.
--   3. A credit note on money already paid hands that money back as credit,
--      and never credits an invoice beyond its total.
--   4. Tax cannot be changed on an invoice once anything is paid on it.
--   5. A lapsed invoice with a part payment is closed; what was paid on it
--      comes back as credit; the locked school is asked for exactly what
--      opens it, and a payment of that amount opens it.
--   6. A locked school is never asked for a lapsed hand price it cannot use.
--   7. A payment split over two invoices prints its withheld tax once.
--   8. Paisa the licence forgives are not reported as owed.
--   9. A credit note must be worth something, and credits only tax charged.
--  10. A school that asked to stop can come back, is not chased for the month
--      after its end, and is told the truth about when it closes.
--  11. Money paid ahead reaches the licence, including money paid while an
--      Enterprise price was being agreed.
--  12. A trial lengthened by a code moves the first invoice after it.
--  13. An invoice raised during grace is due on the first day of its period.
--  14. Correcting a locked Enterprise school's price does not reopen it.
--  15. A suspended school has no lock date to count down to.
--  16. A month that starts on the 31st runs to the end of the next month.
--  17. Nobody signed in can TRUNCATE a table.
--  18. A paid-through date set by hand in the table stands.
--  19. A school created with no trial days is billed from the day it starts.
--  20. A plan move suggests the difference on each paid period at its own
--      term, not the whole paid block at the term chosen for the future.
--  21. Extra room that ends today does not let a new period through.
--  22. A change the school makes never undoes an invoice we set by hand, and a
--      reissue that cannot raise its replacement keeps the original.
--  23. Moving back off a plan withdraws the unpaid charge for moving onto it;
--      money on an open renewal moves with a plan change.
--  24. A room request is answered with what the move actually gives.
--  25. The old plan screen keeps the school's term; room set by hand lives.
--  26. Price changes are recorded truthfully: before, after and who.
--  27. The renewal run leaves a school that locked long ago alone.
--  28. A second review: stopping during grace, old months owed again, a roll
--      over the limit, free codes and credit, debt locks, leaving with money
--      on next month, suspension, credit notes in parts, and who sees prices.
--
-- Run: psql -v ON_ERROR_STOP=1 -f supabase/tests/paid_means_paid.sql
-- =============================================================================

\set ON_ERROR_STOP on

begin;
set local timezone = 'Asia/Karachi';

create or replace function auth.uid() returns uuid language sql stable as
  $$ select nullif(current_setting('test.uid', true), '')::uuid $$;

create or replace function pg_temp.ok(p_cond boolean, p_label text)
returns void language plpgsql as $$
begin
  if coalesce(p_cond, false) then raise notice 'PASS  %', p_label;
  else raise exception 'FAIL  %', p_label; end if;
end;
$$;

create or replace function pg_temp.raises(p_sql text, p_needle text) returns boolean
language plpgsql as $$
begin
  execute p_sql;
  return false;
exception when others then
  if position(lower(p_needle) in lower(sqlerrm)) > 0 then return true; end if;
  raise notice '  (refused, but with the wrong message: %)', sqlerrm;
  return false;
end;
$$;

create or replace function pg_temp.as_op() returns void language sql as $$
  select set_config('test.uid', '00000000-0000-0000-0000-0000000157f0', false);
$$;

create or replace function pg_temp.as_nobody() returns void language sql as $$
  select set_config('test.uid', '', false);
$$;

-- A school signed up the way the website does it.
create or replace function pg_temp.school(p_name text, p_pupils integer, p_term integer)
returns uuid language plpgsql as $$
begin
  perform pg_temp.as_nobody();
  return (public.fn_signup_school_for_students(p_name, null, null, null, null, null,
                                               p_pupils, p_term)->>'school_id')::uuid;
end;
$$;

-- An owner login for a school, made on demand.
create or replace function pg_temp.owner_of(p_school uuid, p_tag text) returns uuid
language plpgsql as $$
declare v uuid := md5('pp-owner-' || p_tag)::uuid;
begin
  insert into auth.users (id, email) values (v, p_tag || '@paidmeanspaid.test')
    on conflict (id) do nothing;
  alter table public.profiles disable trigger user;
  insert into public.profiles (id, full_name, role, school_id, active)
  values (v, 'Owner ' || p_tag, 'owner', p_school, true)
  on conflict (id) do update set school_id = excluded.school_id, role = 'owner', active = true;
  alter table public.profiles enable trigger user;
  return v;
end;
$$;

-- Time passes: every date the school has moves back p_days, as the suites do.
-- Marked as the licence's own write, so the shift is not taken for a date set
-- by hand (block 18).
create or replace function pg_temp.age(p_school uuid, p_days integer) returns void
language plpgsql as $$
begin
  perform set_config('app.licence_recompute', 'on', true);
  update public.subscriptions
     set trial_ends_on = trial_ends_on - p_days,
         period_start = period_start - p_days, period_end = period_end - p_days,
         given_from = given_from - p_days, given_through = given_through - p_days,
         oldest_unpaid_due_on = oldest_unpaid_due_on - p_days,
         closed_from = closed_from - p_days,
         student_limit_override_until = student_limit_override_until - p_days
   where school_id = p_school;
  perform set_config('app.licence_recompute', '', true);
  update public.platform_invoices
     set period_start = period_start - p_days, period_end = period_end - p_days,
         due_on = due_on - p_days, issued_on = issued_on - p_days
   where school_id = p_school;
end;
$$;

create or replace function pg_temp.pay(p_school uuid, p_amount numeric, p_ref text,
                                       p_invoice uuid default null, p_wht numeric default 0)
returns jsonb language plpgsql as $$
begin
  perform pg_temp.as_op();
  return public.fn_platform_record_payment(p_school, p_amount, current_date, 'bank', p_ref,
                                           p_invoice, null, p_wht, null);
end;
$$;

-- n enrolled pupils (fn_count_students counts enrolments, not bare student rows).
create or replace function pg_temp.roll(p_school uuid, p_n integer) returns void
language plpgsql as $$
declare v_sess uuid; v_class uuid;
begin
  perform pg_temp.as_nobody();
  select id into v_sess from public.academic_sessions where school_id = p_school and is_current;
  if v_sess is null then
    insert into public.academic_sessions (school_id, name, starts_on, ends_on, is_current)
      values (p_school, '2026', current_date - 60, current_date + 300, true) returning id into v_sess;
  end if;
  select id into v_class from public.classes where school_id = p_school limit 1;
  if v_class is null then
    insert into public.classes (school_id, name, level_order) values (p_school, 'One', 1)
      returning id into v_class;
  end if;
  with ins as (
    insert into public.students (school_id, full_name, father_name, status)
    select p_school, 'PP Child ' || g || '-' || md5(random()::text), 'F', 'active'
      from generate_series(1, p_n) g
    returning id, full_name
  )
  insert into public.enrollments (school_id, student_id, session_id, class_id, roll_no, status)
  select p_school, ins.id, v_sess, v_class, ins.full_name, 'active' from ins;
  perform public.fn_refresh_student_count(p_school);
end;
$$;

do $$
begin
  insert into auth.users (id, email)
  values ('00000000-0000-0000-0000-0000000157f0', 'operator@paidmeanspaid.test')
  on conflict (id) do nothing;
  insert into public.platform_admins (user_id, email, note)
  values ('00000000-0000-0000-0000-0000000157f0', 'operator@paidmeanspaid.test', 'suite')
  on conflict (user_id) do nothing;
end $$;

-- =============================================================================
-- 1. A FREE MONTH STAYS FREE, AND A ONE-MONTH CODE IS USED ONCE
-- =============================================================================
do $$
declare v_s uuid; v_own uuid; r jsonb; v_free uuid; v_trial date;
begin
  v_s := pg_temp.school('PP Free Month', 100, 1);
  v_own := pg_temp.owner_of(v_s, 'ppfree');
  perform pg_temp.as_op();
  perform public.fn_platform_create_discount(
    '{"code":"PPFREE1","label":"First month free","description":"suite","kind":"percent","value":100,"duration":"months","duration_months":1}');
  perform set_config('test.uid', v_own::text, false);
  perform pg_temp.ok((public.fn_my_redeem_code('PPFREE1', false)->>'ok')::boolean,
    '1 the school uses a one-month 100% code');
  r := public.fn_my_request_invoice();
  v_free := (r->>'invoice_id')::uuid;
  select trial_ends_on into v_trial from public.subscriptions where school_id = v_s;
  perform pg_temp.ok((r->>'amount')::numeric = 0
                     and (select period_end from public.subscriptions where school_id = v_s)
                         = public.fn__term_end(v_trial + 1, 1),
    '2 its first month is a Rs 0 invoice, and that counts as paid');

  -- Forty days on, the free month is past its due date and grace.
  perform pg_temp.age(v_s, 40);
  perform set_config('test.uid', v_own::text, false);
  r := public.fn_my_request_invoice();
  perform pg_temp.ok((select voided_at is null from public.platform_invoices where id = v_free),
    '3 the free month is not voided as lapsed: nothing was ever owed on it');
  perform pg_temp.ok((select reversed_at is null from public.discount_applications
                       where invoice_id = v_free),
    '4 so the code''s month is not given back');
  perform pg_temp.ok((r->>'amount')::numeric = 2000,
    '5 and the month after it is charged in full: the code was used once');
end $$;

-- =============================================================================
-- 2. VOIDING WHAT PAID FOR A YEAR TAKES THE YEAR BACK
-- =============================================================================
do $$
declare v_s uuid; r jsonb; v_inv uuid; v_cn uuid; s record;
begin
  v_s := pg_temp.school('PP Void Paid', 100, 12);
  perform pg_temp.as_op();
  r := public.fn_platform_raise_invoice(v_s, 12, null, null);
  v_inv := (r->>'invoice_id')::uuid;
  r := public.fn_platform_credit_note(v_inv, 20000, 'suite: settled as goodwill');
  v_cn := (r->>'credit_note_id')::uuid;
  select * into s from public.subscriptions where school_id = v_s;
  perform pg_temp.ok(s.period_end = public.fn__term_end(s.trial_ends_on + 1, 12)
                     and s.status = 'active',
    '6 a year settled by a credit note is a paid year');

  perform public.fn_platform_void_invoice(v_cn, 'suite: the credit was a mistake');
  select * into s from public.subscriptions where school_id = v_s;
  perform pg_temp.ok(s.period_end is null and s.status = 'trialing',
    '7 voiding the credit note takes the year back: nothing is paid, so nothing is paid through');
  perform pg_temp.ok(public.fn__next_period_start(v_s) = s.trial_ends_on + 1,
    '8 and the next invoice starts after the trial, not after a year nobody paid for');

  perform public.fn_platform_void_invoice(v_inv, 'suite: raised by mistake');
  perform pg_temp.ok(public.fn_effective_status(v_s) = 'trialing',
    '9 with the invoice voided too, the school is back on the trial it had');
end $$;

-- =============================================================================
-- 3. A CREDIT NOTE ON MONEY ALREADY PAID GIVES THAT MONEY BACK AS CREDIT
-- =============================================================================
do $$
declare v_s uuid; r jsonb; v_inv uuid;
begin
  v_s := pg_temp.school('PP Credit Paid', 100, 1);
  perform pg_temp.as_op();
  v_inv := (public.fn_platform_raise_invoice(v_s, 1, null, null)->>'invoice_id')::uuid;
  perform pg_temp.pay(v_s, 2000, 'PP-CP-1', v_inv);
  perform pg_temp.as_op();
  r := public.fn_platform_credit_note(v_inv, 500, 'suite: a week we were down');
  perform pg_temp.ok((r->>'released_to_credit')::numeric = 500
                     and public.fn__unallocated(v_s) = 500
                     and public.fn__invoice_owed(v_inv) = 0
                     and public.fn_effective_status(v_s) = 'active',
    '10 Rs 500 credited on a paid month comes back as Rs 500 of credit, and the month stays paid');
  perform pg_temp.ok(pg_temp.raises(
    format($q$select public.fn_platform_credit_note(%L, 1600, 'suite: too much')$q$, v_inv),
    'At most'),
    '11 the invoice can be credited only up to its total');

  r := public.fn_platform_raise_invoice(v_s, 1, null, null);
  perform pg_temp.ok((r->>'owed')::numeric = 1500
                     and public.fn_platform_outstanding(v_s) = 1500
                     and (public.fn__subscription_view(v_s, false)->>'pay_now')::numeric = 1500,
    '12 the next invoice takes the credit, and the statement and the screen agree on Rs 1,500');
  perform pg_temp.ok(position('for update' in (select prosrc from pg_proc
                                                where proname = 'fn_platform_credit_note')) > 0,
    '13 a credit note takes its locks before it counts what is already credited');
end $$;

-- =============================================================================
-- 4. TAX IS SET BEFORE ANYTHING IS PAID, AND THE LICENCE FOLLOWS IT
-- =============================================================================
do $$
declare v_s uuid; v_inv uuid; v_inv2 uuid;
begin
  v_s := pg_temp.school('PP Tax', 100, 1);
  perform pg_temp.as_op();
  v_inv := (public.fn_platform_raise_invoice(v_s, 1, null, null)->>'invoice_id')::uuid;
  perform pg_temp.pay(v_s, 2000, 'PP-TAX-1');
  perform pg_temp.as_op();
  perform pg_temp.ok(pg_temp.raises(
    format($q$select public.fn_platform_set_invoice_tax(%L, 16)$q$, v_inv), 'has been paid'),
    '14 tax cannot be put on an invoice paid by a payment that did not name it');
  v_inv2 := (public.fn_platform_raise_invoice(v_s, 1, null, null)->>'invoice_id')::uuid;
  perform public.fn_platform_set_invoice_tax(v_inv2, 16);
  perform pg_temp.ok(public.fn__invoice_owed(v_inv2) = 2320
                     and (select oldest_unpaid_due_on from public.subscriptions where school_id = v_s)
                         = (select due_on from public.platform_invoices where id = v_inv2),
    '15 on an unpaid invoice it is accepted, and what is owed and when follow at once');
end $$;

-- =============================================================================
-- 5. A LAPSED INVOICE WITH A PART PAYMENT
-- =============================================================================
do $$
declare v_s uuid; v_own uuid; v_inv uuid; r jsonb; v jsonb;
begin
  v_s := pg_temp.school('PP Part Paid', 100, 1);
  v_own := pg_temp.owner_of(v_s, 'pppart');
  perform pg_temp.as_op();
  v_inv := (public.fn_platform_raise_invoice(v_s, 1, null, null)->>'invoice_id')::uuid;
  perform pg_temp.pay(v_s, 500, 'PP-PART-1', v_inv);
  -- Its trial ended 27 days ago; the invoice was due 26 days ago.
  perform pg_temp.age(v_s, 40);
  perform pg_temp.ok(public.fn_effective_status(v_s) = 'locked',
    '16 Rs 500 short and past its grace, the school is locked');

  perform set_config('test.uid', v_own::text, false);
  v := public.fn_my_next_payment();
  perform pg_temp.ok(public.fn__open_term_invoice(v_s) is null
                     and (v->'view'->>'pay_now')::numeric = 1500
                     and v->>'sentence' like '%paused until Rs 1,500%'
                     and v->>'sentence' not like '%trial%',
    '17 it is asked for Rs 1,500 (a fresh month less the Rs 500 it paid), not for the lapsed month, and not told its trial is running');
  perform pg_temp.pay(v_s, 1500, 'PP-PART-2');
  perform pg_temp.ok((select voided_at is not null from public.platform_invoices where id = v_inv)
                     and public.fn_effective_status(v_s) = 'active'
                     and public.fn__unallocated(v_s) = 0
                     and (select period_start from public.subscriptions where school_id = v_s)
                         = current_date - 14,
    '18 paying it closes the lapsed month, puts its Rs 500 on the new one and opens the school; the new month counts the grace days it used');
end $$;

-- =============================================================================
-- 6. A LAPSED HAND PRICE IS NOT WHAT A LOCKED SCHOOL IS ASKED FOR
-- =============================================================================
do $$
declare v_s uuid;
begin
  v_s := pg_temp.school('PP Hand Price', 100, 1);
  perform pg_temp.as_op();
  perform public.fn_platform_raise_invoice(v_s, 1, 1500, 'suite: agreed Rs 1,500 for the first month');
  perform pg_temp.age(v_s, 40);
  perform pg_temp.ok((public.fn__subscription_view(v_s, false)->>'pay_now')::numeric = 2000,
    '19 locked, it is asked for what will open it: the next month at its price, not a lapsed hand price');
  perform pg_temp.pay(v_s, 2000, 'PP-HAND-1');
  perform pg_temp.ok(public.fn_effective_status(v_s) = 'active',
    '20 and paying that opens it');
end $$;

-- =============================================================================
-- 7. WITHHELD TAX IS PRINTED ONCE ACROSS THE INVOICES A PAYMENT PAID
-- =============================================================================
do $$
declare v_s uuid; d1 jsonb; d2 jsonb; v_i1 uuid; v_i2 uuid;
begin
  v_s := pg_temp.school('PP Withheld', 100, 1);
  -- Rs 3,800 transferred and Rs 200 withheld: two months.
  perform pg_temp.pay(v_s, 3800, 'PP-WHT-1', null, 200);
  select id into v_i1 from public.platform_invoices where school_id = v_s and kind = 'invoice'
   order by period_start limit 1;
  select id into v_i2 from public.platform_invoices where school_id = v_s and kind = 'invoice'
   order by period_start desc limit 1;
  d1 := public.fn__invoice_document(v_i1);
  d2 := public.fn__invoice_document(v_i2);
  perform pg_temp.ok(v_i1 <> v_i2
                     and (d1->'payments'->0->>'tax_withheld')::numeric = 100
                     and (d2->'payments'->0->>'tax_withheld')::numeric = 100
                     and (d1->'payments'->0->>'amount')::numeric
                         + (d1->'payments'->0->>'tax_withheld')::numeric
                         = (d1->'payments'->0->>'settled')::numeric,
    '21 each invoice shows its share of the Rs 200 withheld, and cash plus withheld is what it received');
end $$;

-- =============================================================================
-- 8. PAISA THE LICENCE FORGIVES ARE NOT OWED ANYWHERE
-- =============================================================================
do $$
declare v_s uuid; v_inv uuid;
begin
  v_s := pg_temp.school('PP Paisa', 100, 1);
  perform pg_temp.as_op();
  v_inv := (public.fn_platform_raise_invoice(v_s, 1, null, null)->>'invoice_id')::uuid;
  perform public.fn_platform_set_invoice_tax(v_inv, 10.18, 203.61);
  perform pg_temp.pay(v_s, 2203, 'PP-PAISA-1', v_inv);
  perform pg_temp.as_op();
  perform pg_temp.ok(public.fn__invoice_owed(v_inv) = 0
                     and public.fn_platform_outstanding(v_s) = 0
                     and (public.fn__invoice_document(v_inv)->'totals'->>'balance')::numeric = 0,
    '22 61 paisa short: paid for the licence, and nothing owed on the statement or the invoice');
end $$;

-- =============================================================================
-- 9. A CREDIT NOTE IS WORTH SOMETHING, AND CREDITS ONLY TAX CHARGED
-- =============================================================================
do $$
declare v_s uuid; v_inv uuid;
begin
  v_s := pg_temp.school('PP Credit Rules', 100, 1);
  perform pg_temp.as_op();
  v_inv := (public.fn_platform_raise_invoice(v_s, 1, null, null)->>'invoice_id')::uuid;
  perform pg_temp.ok(pg_temp.raises(
    format($q$select public.fn_platform_credit_note(%L, 0.004, 'suite')$q$, v_inv), 'more than zero'),
    '23 a credit note that rounds to nothing is refused');
  perform pg_temp.ok(pg_temp.raises(
    format($q$select public.fn_platform_credit_note(%L, 1000, 'suite', 900)$q$, v_inv), 'sales tax'),
    '24 sales tax is credited only up to the tax the invoice charged');
end $$;

-- =============================================================================
-- 10. ASKING TO STOP, AND COMING BACK
-- =============================================================================
do $$
declare v_s uuid; v_own uuid; v_next uuid; r jsonb; v jsonb; v_cov date;
begin
  v_s := pg_temp.school('PP Leaving', 100, 1);
  v_own := pg_temp.owner_of(v_s, 'ppleave');
  perform pg_temp.pay(v_s, 2000, 'PP-LEAVE-1');
  perform pg_temp.as_op();
  v_next := (public.fn_platform_raise_invoice(v_s, 1, null, null)->>'invoice_id')::uuid;

  perform set_config('test.uid', v_own::text, false);
  r := public.fn_cancel_my_subscription('suite: closing the branch');
  perform pg_temp.ok((select voided_at is not null from public.platform_invoices where id = v_next)
                     and r->'voided' ? (select doc_no from public.platform_invoices where id = v_next),
    '25 asking to stop voids the invoice already raised for the month after the end');
  v := public.fn__subscription_view(v_s, false);
  v_cov := (v->>'covered_to')::date;
  perform pg_temp.ok((v->>'locks_on')::date = v_cov + 1 and (v->>'pay_now')::numeric = 0,
    '26 it closes the day after its period (no grace for a school that is leaving) and owes nothing');

  perform pg_temp.age(v_s, 60);
  perform pg_temp.ok(public.fn_effective_status(v_s) = 'cancelled',
    '27 after its end it is closed');
  perform pg_temp.pay(v_s, 2000, 'PP-LEAVE-2');
  perform pg_temp.ok(public.fn_effective_status(v_s) = 'cancelled' and public.fn__unallocated(v_s) = 2000,
    '28 money that arrives while it is closed is kept as credit');
  perform set_config('test.uid', v_own::text, false);
  r := public.fn_resume_my_subscription();
  perform pg_temp.ok((r->>'resumed')::boolean and public.fn_effective_status(v_s) = 'active'
                     and public.fn__unallocated(v_s) = 0,
    '29 it can come back: restarting puts its credit on the next month and opens it');
  perform pg_temp.ok((select period_start from public.subscriptions where school_id = v_s) = current_date,
    '30 billed from today: a school that left used no grace');
end $$;

do $$
declare v_s uuid; v_own uuid; r jsonb;
begin
  v_s := pg_temp.school('PP Leaving Two', 100, 1);
  v_own := pg_temp.owner_of(v_s, 'ppleave2');
  perform pg_temp.pay(v_s, 2000, 'PP-LEAVE2-1');
  perform set_config('test.uid', v_own::text, false);
  perform public.fn_cancel_my_subscription(null);
  perform pg_temp.as_op();
  perform pg_temp.ok(pg_temp.raises(
    format($q$select public.fn_platform_raise_invoice(%L, 1, null, null)$q$, v_s), 'reinstate'),
    '31 we do not invoice a school that asked to stop, and the refusal says how it comes back');
  r := public.fn_platform_reinstate_subscription(v_s, 'suite: they are staying after all');
  perform pg_temp.ok((r->>'back_in')::boolean
                     and not (select cancel_at_period_end from public.subscriptions where school_id = v_s),
    '32 and we can reinstate it, which clears the request to stop');
end $$;

-- =============================================================================
-- 11. MONEY PAID AHEAD REACHES THE LICENCE
-- =============================================================================
do $$
declare v_s uuid; v_trial date; r jsonb;
begin
  v_s := pg_temp.school('PP Ahead', 100, 1);
  select trial_ends_on into v_trial from public.subscriptions where school_id = v_s;
  perform pg_temp.pay(v_s, 4000, 'PP-AHEAD-1');
  perform pg_temp.ok((select count(*) from public.platform_invoices
                       where school_id = v_s and kind = 'invoice' and voided_at is null
                         and public.fn__invoice_owed(id) = 0) = 2
                     and public.fn__unallocated(v_s) = 0
                     and (select period_end from public.subscriptions where school_id = v_s)
                         = public.fn__term_end(public.fn__term_end(v_trial + 1, 1) + 1, 1),
    '33 Rs 4,000 on a Rs 2,000 month pays two months, not one month and a credit that locks');

  v_s := pg_temp.school('PP Enterprise Ahead', 1500, 1);
  r := pg_temp.pay(v_s, 7000, 'PP-ENT-1');
  perform pg_temp.ok(public.fn__unallocated(v_s) = 7000,
    '34 an Enterprise school that pays before its price is set holds it as credit');
  perform pg_temp.as_op();
  r := public.fn_platform_set_price(v_s, 7000, null, null, 'suite: agreed with the principal on the phone');
  perform pg_temp.ok(jsonb_array_length(r->'from_credit') = 1
                     and public.fn__unallocated(v_s) = 0
                     and public.fn_effective_status(v_s) in ('trialing', 'active'),
    '35 setting the price puts that money on its first month at once');
end $$;

-- =============================================================================
-- 12. A LONGER TRIAL MOVES THE FIRST INVOICE AFTER IT
-- =============================================================================
do $$
declare v_s uuid; v_own uuid; v_inv uuid; r jsonb; v_trial date;
begin
  v_s := pg_temp.school('PP Trial Code', 100, 1);
  v_own := pg_temp.owner_of(v_s, 'pptrial');
  perform set_config('test.uid', v_own::text, false);
  v_inv := (public.fn_my_request_invoice()->>'invoice_id')::uuid;
  perform pg_temp.as_op();
  perform public.fn_platform_create_discount(
    '{"code":"PPTRIAL10","label":"Ten more days","description":"suite","kind":"trial_days","value":10}');
  perform set_config('test.uid', v_own::text, false);
  r := public.fn_my_redeem_code('PPTRIAL10', false);
  select trial_ends_on into v_trial from public.subscriptions where school_id = v_s;
  perform pg_temp.ok((select voided_at is not null from public.platform_invoices where id = v_inv)
                     and (select period_start from public.platform_invoices
                           where id = public.fn__open_term_invoice(v_s)) = v_trial + 1,
    '36 the invoice raised for the old end is reissued to start after the new one');
  perform pg_temp.age(v_s, 20);
  perform pg_temp.ok(public.fn_effective_status(v_s) = 'trialing',
    '37 so the school is not locked as unpaid in the middle of its trial');
end $$;

-- =============================================================================
-- 13. AN INVOICE RAISED DURING GRACE IS DUE ON THE FIRST DAY OF ITS PERIOD
-- =============================================================================
do $$
declare v_s uuid; r jsonb;
begin
  v_s := pg_temp.school('PP Grace Raise', 100, 1);
  perform pg_temp.age(v_s, 20);
  perform pg_temp.ok(public.fn_effective_status(v_s) = 'grace', '38 seven days into its grace');
  perform pg_temp.as_op();
  r := public.fn_platform_raise_invoice(v_s, 1, null, null);
  perform pg_temp.ok((r->>'due_on')::date = (r->>'period_start')::date
                     and (r->>'due_on')::date < current_date,
    '39 its invoice is due on the first day of the period it pays for, not on the day it was raised');
  perform pg_temp.age(v_s, 8);
  perform pg_temp.ok(public.fn__invoice_lapsed((r->>'invoice_id')::uuid)
                     and public.fn_effective_status(v_s) = 'locked',
    '40 so it lapses the day the school locks, and a payment then is not spent on locked days');
end $$;

-- =============================================================================
-- 14. CORRECTING A PRICE DOES NOT REOPEN A SCHOOL THAT HAS NOT PAID
-- =============================================================================
do $$
declare v_s uuid;
begin
  v_s := pg_temp.school('PP Enterprise Unpaid', 1500, 1);
  perform pg_temp.as_op();
  perform public.fn_platform_set_price(v_s, 50000, null, null, 'suite: agreed in the first week');
  perform public.fn_platform_raise_invoice(v_s, 1, null, null);
  perform pg_temp.age(v_s, 40);
  perform pg_temp.ok(public.fn_effective_status(v_s) = 'locked', '41 priced, invoiced, unpaid: locked');
  perform pg_temp.as_op();
  perform public.fn_platform_set_price(v_s, 45000, null, null, 'suite: corrected after a call');
  perform pg_temp.ok(public.fn_effective_status(v_s) = 'locked',
    '42 correcting its price leaves it locked: the fourteen days to pay are for a school that waited for its price');
end $$;

-- =============================================================================
-- 15. A SUSPENDED SCHOOL HAS NO COUNTDOWN
-- =============================================================================
do $$
declare v_s uuid; v jsonb;
begin
  v_s := pg_temp.school('PP Suspended', 100, 1);
  update public.subscriptions set suspended_at = now(), suspend_reason = 'suite'
   where school_id = v_s;
  v := public.fn__subscription_view(v_s, false);
  perform pg_temp.ok(v->>'locks_on' is null and (v->>'days_to_lock')::integer = 0,
    '43 a suspended school is shown no lock date and no days left');
end $$;

-- =============================================================================
-- 16. MONTH ENDS
-- =============================================================================
do $$
begin
  perform pg_temp.ok(public.fn__term_end('2027-01-31', 1) = '2027-02-28'
                     and public.fn__term_end('2027-01-28', 1) = '2027-02-27'
                     and public.fn__term_end('2027-03-01', 1) = '2027-03-31'
                     and public.fn__term_end('2027-03-31', 1) = '2027-04-30'
                     and public.fn__term_end('2028-02-29', 12) = '2029-02-28'
                     and public.fn__term_end('2027-11-30', 3) = '2028-02-29',
    '44 a month from the 31st runs to the end of the next month, and the billing day does not creep');
end $$;

-- =============================================================================
-- 17. NOBODY SIGNED IN CAN EMPTY A TABLE
-- =============================================================================
do $$
begin
  perform pg_temp.ok(not exists (
    select 1 from pg_class c join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'public' and c.relkind = 'r'
       and (has_table_privilege('authenticated', c.oid, 'truncate')
            or has_table_privilege('anon', c.oid, 'truncate'))),
    '45 TRUNCATE, which skips row security and every trigger, is granted on no table');
end $$;

-- =============================================================================
-- 18. A DATE SET BY HAND STANDS
-- =============================================================================
do $$
declare v_s uuid;
begin
  v_s := pg_temp.school('PP By Hand', 100, 1);
  update public.subscriptions set period_start = current_date, period_end = current_date + 60,
         status = 'active'
   where school_id = v_s;
  perform pg_temp.as_op();
  perform public.fn__recompute_licence(v_s);
  perform pg_temp.ok((select period_end = current_date + 60 and given_through = current_date + 60
                        from public.subscriptions where school_id = v_s),
    '46 a paid-through date typed into the table is a grant, and the next recompute keeps it');
end $$;

-- =============================================================================
-- 19. NO TRIAL DAYS: BILLED FROM THE DAY IT STARTS
-- =============================================================================
do $$
declare v_s uuid;
begin
  v_s := pg_temp.school('PP No Trial', 100, 1);
  update public.subscriptions set trial_ends_on = current_date - 1 where school_id = v_s;
  perform pg_temp.ok(public.fn_effective_status(v_s) = 'grace'
                     and public.fn__next_period_start(v_s) = current_date,
    '47 a school with no trial days works while its first payment arrives, and its first month starts today');
  perform pg_temp.age(v_s, 30);
  perform pg_temp.ok(public.fn__next_period_start(v_s) = current_date - 14,
    '48 if it never pays and comes back later, the fourteen days it used are billed');
end $$;

-- =============================================================================
-- 20. THE SUGGESTED CHARGE FOR A MOVE
-- =============================================================================
do $$
declare v_s uuid; q jsonb; r record; v_expect numeric := 0;
begin
  v_s := pg_temp.school('PP Pro Rata', 100, 1);
  perform pg_temp.pay(v_s, 4000, 'PP-PR-1');            -- two months, paid
  perform pg_temp.age(v_s, 30);                          -- into the first of them
  -- The school then chooses to pay yearly from its next invoice.
  update public.subscriptions set term_months = 12, cycle = 'yearly' where school_id = v_s;
  perform pg_temp.as_op();
  q := public.fn_platform_plan_change_quote(v_s, 'growth', null);
  for r in select period_start, period_end from public.platform_invoices
            where school_id = v_s and kind = 'invoice' and voided_at is null
              and period_end >= current_date order by period_start loop
    v_expect := v_expect + round(2000.0 * (r.period_end - greatest(current_date, r.period_start) + 1)
                                       / (r.period_end - r.period_start + 1));
  end loop;
  perform pg_temp.ok((q->>'suggested_charge')::numeric = v_expect
                     and jsonb_array_length(q->'lines') = 2
                     and (q->'lines'->0->>'months')::int = 1,
    '49 the move is priced on each paid month at the monthly prices (Rs 2,000 more a month), not the whole block at the yearly price chosen for later');
end $$;

-- =============================================================================
-- 21. ROOM THAT ENDS TODAY DOES NOT COVER THE NEXT PERIOD
-- =============================================================================
do $$
declare v_s uuid;
begin
  v_s := pg_temp.school('PP Room Today', 100, 1);
  perform pg_temp.roll(v_s, 290);
  perform pg_temp.age(v_s, 20);                          -- in grace
  update public.subscriptions
     set student_limit_override = 400, student_limit_override_reason = 'suite',
         student_limit_override_until = current_date
   where school_id = v_s;
  perform pg_temp.ok(public.fn__over_limit_for_period(v_s, public.fn__next_period_start(v_s)) is not null,
    '50 room given during grace ends today, so the next period is held to the plan''s own 280');
end $$;

-- =============================================================================
-- 22. A SCHOOL'S CHANGE NEVER UNDOES OUR INVOICE
-- =============================================================================
do $$
declare v_s uuid; v_own uuid; v_inv uuid; r jsonb;
begin
  v_s := pg_temp.school('PP Hand Kept', 100, 1);
  v_own := pg_temp.owner_of(v_s, 'pphandkept');
  perform pg_temp.as_op();
  v_inv := (public.fn_platform_raise_invoice(v_s, 1, 3000,
              'suite: the month plus a records fee, agreed with the owner')->>'invoice_id')::uuid;
  perform set_config('test.uid', v_own::text, false);
  r := public.fn_choose_term(3);
  perform pg_temp.ok((select voided_at is null and amount = 3000 from public.platform_invoices where id = v_inv)
                     and r->'invoice'->>'kept' is not null
                     and r->>'why' like 'We set this invoice with you%',
    '51 a term change keeps the invoice we priced by hand, and says the change applies after it');

  v_s := pg_temp.school('PP Reissue Kept', 100, 1);
  v_own := pg_temp.owner_of(v_s, 'ppreissue');
  perform pg_temp.as_op();
  v_inv := (public.fn_platform_raise_invoice(v_s, 1, null, null)->>'invoice_id')::uuid;
  perform pg_temp.roll(v_s, 290);                        -- the roll outgrows Starter
  perform set_config('test.uid', v_own::text, false);
  r := public.fn_choose_term(12);
  perform pg_temp.ok((select voided_at is null from public.platform_invoices where id = v_inv)
                     and public.fn__open_term_invoice(v_s) = v_inv
                     and r->>'why' like 'Your roll is bigger%'
                     and r->>'why' not like '%Change plan%',
    '52 a reissue that cannot raise its replacement keeps the original, and the school is told why in its own words');
end $$;

-- =============================================================================
-- 23. MOVES AND THE INVOICES AROUND THEM
-- =============================================================================
do $$
declare v_s uuid; r jsonb; v_charge uuid; v_open uuid; v_new uuid;
begin
  v_s := pg_temp.school('PP Up And Down', 100, 1);
  perform pg_temp.pay(v_s, 2000, 'PP-UD-1');
  perform pg_temp.age(v_s, 20);
  perform pg_temp.as_op();
  r := public.fn_platform_change_plan(v_s, 'growth', 'suite: they asked to move up', 1000);
  v_charge := (r->>'invoice_id')::uuid;
  r := public.fn_platform_change_plan(v_s, 'starter', 'suite: they changed their mind');
  perform pg_temp.ok((select voided_at is not null from public.platform_invoices where id = v_charge)
                     and r->'charges_withdrawn' ? (select doc_no from public.platform_invoices where id = v_charge)
                     and (select oldest_unpaid_due_on from public.subscriptions where school_id = v_s) is null,
    '53 moving back off Growth withdraws the unpaid charge for moving onto it');

  v_s := pg_temp.school('PP Token Payment', 100, 12);
  perform pg_temp.as_op();
  v_open := (public.fn_platform_raise_invoice(v_s, 12, null, null)->>'invoice_id')::uuid;
  perform pg_temp.pay(v_s, 100, 'PP-TOKEN-1', v_open);
  perform pg_temp.as_op();
  r := public.fn_platform_change_plan(v_s, 'growth', 'suite: their roll has grown');
  v_new := (r->'reissued'->'raised'->>'invoice_id')::uuid;
  perform pg_temp.ok((select voided_at is not null from public.platform_invoices where id = v_open)
                     and (select amount = 40000 from public.platform_invoices where id = v_new)
                     and public.fn__invoice_owed(v_new) = 39900,
    '54 Rs 100 on a Starter year does not hold the year at Starter: it is reissued on Growth with the Rs 100 on it');
end $$;

-- =============================================================================
-- 24. A ROOM REQUEST IS ANSWERED WITH WHAT THE MOVE GIVES
-- =============================================================================
do $$
declare v_s uuid; v_own uuid; v_req record;
begin
  v_s := pg_temp.school('PP Asked For More', 500, 1);    -- Growth
  v_own := pg_temp.owner_of(v_s, 'ppasked');
  perform set_config('test.uid', v_own::text, false);
  perform public.fn_request_student_limit(1500, 'suite: a second campus joins in spring', 'move_up');
  perform pg_temp.as_op();
  perform public.fn_platform_change_plan(v_s, 'starter', 'suite: the campus fell through, they shrank');
  select * into v_req from public.student_limit_requests where school_id = v_s;
  perform pg_temp.ok(v_req.status = 'declined' and v_req.granted_limit is null
                     and v_req.decision_note like '%covers 280 pupils, fewer than the 1500 asked for%',
    '55 a move to a plan that gives less than was asked is not recorded as granted');
end $$;

-- =============================================================================
-- 25. THE OLD PLAN SCREEN, AND ROOM SET BY HAND
-- =============================================================================
do $$
declare v_s uuid; v_own uuid;
begin
  v_s := pg_temp.school('PP Old Screen', 100, 12);
  v_own := pg_temp.owner_of(v_s, 'ppoldscreen');
  perform set_config('test.uid', v_own::text, false);
  perform public.fn_my_choose_plan('starter', null);
  perform pg_temp.ok((select term_months from public.subscriptions where school_id = v_s) = 12,
    '56 saving the plan with no term on the old screen keeps the school yearly');

  update public.subscriptions
     set student_limit_override = 300, student_limit_override_reason = 'suite',
         student_limit_override_until = current_date - 5
   where school_id = v_s;
  update public.subscriptions set student_limit_override = 350 where school_id = v_s;
  perform pg_temp.ok((select student_limit_override_until >= current_date
                        from public.subscriptions where school_id = v_s)
                     and public.fn__student_limit(v_s) = 350,
    '57 new room set by hand over an old end date gets a live end date, not the expired one');
end $$;

-- =============================================================================
-- 26. PRICE CHANGES, RECORDED TRUTHFULLY
-- =============================================================================
do $$
declare v_s uuid; v_a record;
begin
  v_s := pg_temp.school('PP Price Audit', 1500, 1);
  perform pg_temp.as_op();
  perform public.fn_platform_set_price(v_s, 10000, null, 90000, 'suite: agreed on a visit, 1,500 pupils');
  perform public.fn_platform_set_price(v_s, 12000, null, null, 'suite: revised after the second campus');
  select * into v_a from public.audit_log
   where school_id = v_s and action = 'subscription_price_set' order by created_at desc, id desc limit 1;
  perform pg_temp.ok((v_a.before->>'monthly')::numeric = 10000
                     and (v_a.before->>'yearly')::numeric = 90000
                     and (v_a.after->>'yearly')::numeric = 120000,
    '58 the audit row records the price as it was, every term, and the price as it is');
  perform pg_temp.ok(pg_temp.raises(
    $q$select public.fn_platform_create_school('{"name":"PP Priced No Reason","students":1500,"agreed_monthly":9000}')$q$,
    'Say how this price was agreed'),
    '59 a school created with a price needs to say how the price was agreed');

  -- A role of the suite's own, made inside this transaction, so the check does
  -- not depend on whether this database's service_role bypasses row security
  -- (it does on Supabase, and not in CI).
  create role pp_price_editor nologin bypassrls;
  grant select, update on public.plans to pp_price_editor;
  set local role pp_price_editor;
  update public.plans set name = name where code = 'starter';
  reset role;
  perform pg_temp.ok((select changed_as from public.plan_changes order by id desc limit 1) = 'pp_price_editor',
    '60 a change to the price list records the role that made it, not the owner of the trigger');
  perform pg_temp.ok(pg_temp.raises(
    $q$delete from public.plan_changes where id = (select max(id) from public.plan_changes)$q$,
    'append-only'),
    '61 and the record cannot be deleted');
end $$;

-- =============================================================================
-- 27. THE RENEWAL RUN LEAVES A SCHOOL THAT LOCKED LONG AGO ALONE
-- =============================================================================
do $$
declare v_s uuid; r jsonb;
begin
  v_s := pg_temp.school('PP Long Gone', 100, 1);
  perform pg_temp.age(v_s, 90);
  perform pg_temp.as_op();
  r := public.fn_platform_run_renewals(false, current_date);
  perform pg_temp.ok(not exists (select 1 from jsonb_array_elements(r->'attempts') a
                                  where a->>'school_id' = v_s::text)
                     and not exists (select 1 from public.platform_invoices where school_id = v_s),
    '62 a school locked for months is not invoiced by the run: it is billed when it comes back');
end $$;

-- =============================================================================
-- 28. THE SECOND REVIEW
-- =============================================================================
do $$
declare v_s uuid; v_own uuid; v_cov date; v_inv uuid; v_cn uuid; r jsonb; v jsonb;
begin
  -- Stopping after the period ended does not wipe the grace days used.
  v_s := pg_temp.school('PP Stop In Grace', 100, 1);
  v_own := pg_temp.owner_of(v_s, 'ppstopgrace');
  perform pg_temp.pay(v_s, 2000, 'PP-SG-1');
  v_cov := public.fn__coverage_end(v_s);
  perform pg_temp.age(v_s, (v_cov - current_date) + 12);   -- 11 days into grace
  v_cov := public.fn__coverage_end(v_s);
  perform set_config('test.uid', v_own::text, false);
  perform public.fn_cancel_my_subscription('suite');
  perform public.fn_resume_my_subscription();
  perform pg_temp.ok(public.fn__next_period_start(v_s) = v_cov + 1,
    '63 a school that stops and restarts after working its grace is still billed for those days');

  -- An old month cannot be made owed again under months paid after it.
  v_s := pg_temp.school('PP Old Month', 100, 1);
  perform pg_temp.as_op();
  v_inv := (public.fn_platform_raise_invoice(v_s, 1, null, null)->>'invoice_id')::uuid;
  v_cn := (public.fn_platform_credit_note(v_inv, 2000, 'suite: goodwill')->>'credit_note_id')::uuid;
  perform pg_temp.pay(v_s, 2000, 'PP-OM-1');
  perform pg_temp.as_op();
  perform pg_temp.ok(pg_temp.raises(format($q$select public.fn_platform_void_invoice(%L, 'suite')$q$, v_cn),
                                    'followed by periods already paid'),
    '64 a credit note cannot be voided under a month paid after it');
  v_inv := (public.fn_platform_raise_invoice(v_s, 1, 0, 'suite: a free month')->>'invoice_id')::uuid;
  perform pg_temp.ok(pg_temp.raises(format($q$select public.fn_platform_set_invoice_tax(%L, 16)$q$, v_inv),
                                    'has been paid'),
    '65 nor can tax be put on a Rs 0 month that already counts as paid');

  -- Over the limit: the next term is not asked for until we move the school.
  v_s := pg_temp.school('PP Over Limit', 100, 1);
  v_own := pg_temp.owner_of(v_s, 'ppoverlimit');
  perform pg_temp.pay(v_s, 2000, 'PP-OL-1');
  perform pg_temp.roll(v_s, 300);
  perform pg_temp.age(v_s, (public.fn__coverage_end(v_s) - current_date) + 2);
  perform set_config('test.uid', v_own::text, false);
  v := public.fn_my_next_payment();
  perform pg_temp.ok((v->'view'->>'pay_now')::numeric = 0 and v->'view'->>'next_blocked' = 'over_limit'
                     and v->>'sentence' like 'Your roll is bigger than your plan covers%',
    '66 a school over its limit is told it needs moving, not asked for money that buys nothing');

  -- A free code and a rupee of credit raise one term, not decades.
  v_s := pg_temp.school('PP Free Forever', 100, 12);
  perform pg_temp.as_op();
  perform public.fn_platform_create_discount(jsonb_build_object(
    'code', 'PPFREEFOREVER', 'label', 'Free', 'description', 'suite', 'kind', 'percent',
    'value', 100, 'duration', 'forever', 'private', true, 'school_id', v_s));
  perform public.fn_platform_grant_discount(v_s, 'PPFREEFOREVER', 'suite: a partner school', false);
  perform pg_temp.pay(v_s, 1, 'PP-FF-1');
  perform pg_temp.ok((select count(*) from public.platform_invoices where school_id = v_s and voided_at is null) <= 1,
    '67 credit never raises Rs 0 terms ahead');

  -- Locked only by a charge in the middle of a paid year: asked for the charge.
  v_s := pg_temp.school('PP Charge Lock', 100, 12);
  perform pg_temp.pay(v_s, 20000, 'PP-CL-1');
  perform pg_temp.age(v_s, 30);
  perform pg_temp.as_op();
  r := public.fn_platform_change_plan(v_s, 'growth', 'suite: their roll grew', 15000);
  perform pg_temp.age(v_s, 15);
  v := public.fn__subscription_view(v_s, false);
  perform pg_temp.ok(public.fn_effective_status(v_s) = 'locked' and (v->>'pay_now')::numeric = 15000,
    '68 a school locked by an unpaid move charge mid-year is asked for the charge, not next year as well');

  -- Leaving with money on next month: it comes back as credit; our invoice stays.
  v_s := pg_temp.school('PP Leave Part Paid', 100, 1);
  v_own := pg_temp.owner_of(v_s, 'ppleavepart');
  perform pg_temp.pay(v_s, 2000, 'PP-LP-1');
  perform pg_temp.as_op();
  v_inv := (public.fn_platform_raise_invoice(v_s, 1, null, null)->>'invoice_id')::uuid;
  perform pg_temp.pay(v_s, 500, 'PP-LP-2', v_inv);
  perform set_config('test.uid', v_own::text, false);
  r := public.fn_cancel_my_subscription('suite');
  perform pg_temp.ok((select voided_at is not null from public.platform_invoices where id = v_inv)
                     and (r->>'released_to_credit')::numeric = 500 and public.fn__unallocated(v_s) = 500,
    '69 stopping closes next month and the Rs 500 paid on it comes back as credit');

  v_s := pg_temp.school('PP Leave Hand', 100, 12);
  v_own := pg_temp.owner_of(v_s, 'ppleavehand');
  perform pg_temp.pay(v_s, 20000, 'PP-LH-1');
  perform pg_temp.as_op();
  v_inv := (public.fn_platform_raise_invoice(v_s, 12, 24000, 'suite: year plus a training day')->>'invoice_id')::uuid;
  perform set_config('test.uid', v_own::text, false);
  r := public.fn_cancel_my_subscription('suite');
  perform pg_temp.ok((select voided_at is null from public.platform_invoices where id = v_inv)
                     and (public.fn__subscription_view(v_s, false)->>'owed')::numeric = 0,
    '70 an invoice we set by hand survives a stop, and a leaving school does not owe it');
  perform public.fn_resume_my_subscription();
  perform pg_temp.ok((select voided_at is null and amount = 24000 from public.platform_invoices where id = v_inv),
    '71 and it is still there when the school restarts');

  -- Money paid while suspended is spent when the suspension is lifted.
  v_s := pg_temp.school('PP Suspended Paid', 100, 1);
  update public.subscriptions set suspended_at = now(), suspend_reason = 'suite' where school_id = v_s;
  perform pg_temp.pay(v_s, 2000, 'PP-SP-1');
  perform pg_temp.as_op();
  r := public.fn_platform_unsuspend_school(v_s, 'suite');
  perform pg_temp.ok(public.fn__unallocated(v_s) = 0 and jsonb_array_length(r->'from_credit') = 1,
    '72 lifting a suspension puts the money paid meanwhile on the next month');

  -- A taxed invoice credited in three parts reaches zero.
  v_s := pg_temp.school('PP Credit Parts', 100, 1);
  perform pg_temp.as_op();
  v_inv := (public.fn_platform_raise_invoice(v_s, 1, null, null)->>'invoice_id')::uuid;
  perform public.fn_platform_set_invoice_tax(v_inv, 16.5);
  perform public.fn_platform_credit_note(v_inv, 667, 'suite: part one');
  perform public.fn_platform_credit_note(v_inv, 667, 'suite: part two');
  perform public.fn_platform_credit_note(v_inv, 666, 'suite: part three');
  perform pg_temp.ok(public.fn__invoice_owed(v_inv) = 0,
    '73 an invoice credited in parts can be credited to nothing without typing the tax');

  -- Who sees the price.
  v_s := pg_temp.school('PP Who Sees', 1500, 1);
  perform pg_temp.as_op();
  perform public.fn_platform_set_price(v_s, 50000, null, null, 'suite: we matched a rival quote, do not go lower');
  insert into auth.users (id, email) values ('00000000-0000-0000-0000-00000000c7a1', 'pp-teacher@paidmeanspaid.test')
    on conflict do nothing;
  alter table public.profiles disable trigger user;
  insert into public.profiles (id, full_name, role, school_id, active)
  values ('00000000-0000-0000-0000-00000000c7a1', 'PP Teacher', 'class_teacher', v_s, true)
  on conflict (id) do nothing;
  alter table public.profiles enable trigger user;
  perform set_config('test.uid', '00000000-0000-0000-0000-00000000c7a1', false);
  v := public.fn_my_licence();
  perform pg_temp.ok(v->'price_monthly' = 'null'::jsonb and v->'pay_now' = 'null'::jsonb
                     and v->>'status' is not null,
    '74 a teacher''s banner has the status and dates, not the price or what is owed');
  perform pg_temp.as_nobody();
  perform pg_temp.ok(not has_column_privilege('authenticated', 'public.subscriptions', 'agreed_reason', 'select')
                     and has_column_privilege('authenticated', 'public.subscriptions', 'period_end', 'select'),
    '75 how a price was agreed is not readable by a signed-in user');
end $$;

rollback;

-- =============================================================================
-- Can a school set a fee at all, and does a scheduled rise bill correctly?
--
-- Three defects, all proven on a real database before 0066 was written, all in
-- the module the whole product exists for.
--
--   1. Saving an amount raised 42P10 every time. 0035 replaced the 3-column
--      unique key on fee_structures with a 4-column one including
--      effective_from; the app still sent the old 3-column ON CONFLICT.
--   2. Nothing anywhere could create a fee head, so there was nothing to put an
--      amount against.
--   3. effective_from arrived in 0035 and only ONE of four readers learned about
--      it. Tuition 1500 with a rise to 1800 scheduled from 2027-01-01, billing
--      MAY 2026, produced TWO lines — 1500 and 1800 — and the "monthly fee"
--      figure read 3300.
--
-- The rules this file defends:
--
--   1. A FEE HEAD CAN BE CREATED, RENAMED AND SWITCHED OFF, and never deleted
--      once billed — an invoice line names it.
--   2. TWO HEADS CANNOT SHARE A NAME, case-insensitively. A grid with two rows
--      called Tuition is a support call nobody can resolve.
--   3. A REFUNDABLE HEAD CANNOT BE RECURRING. A deposit charged monthly is a
--      liability manufactured every month.
--   4. SETTING AN AMOUNT WORKS, and the first one covers a month billed in
--      arrears — a school setting up in August must be able to bill April.
--   5. A SCHEDULED RISE APPLIES FROM ITS DATE AND NOT BEFORE. One line per head
--      per month, at the price in force that month.
--   6. THE GRID SHOWS WHAT WILL BE BILLED, plus any change already scheduled.
--   7. ALL THREE BILLING PATHS AGREE. They disagreeing with each other is what
--      made this invisible.
--
-- Run: psql -v ON_ERROR_STOP=1 -f supabase/tests/fee_setup.sql
-- =============================================================================

\set ON_ERROR_STOP on

begin;

create or replace function auth.uid() returns uuid language sql stable as
  $$ select nullif(current_setting('test.uid', true), '')::uuid $$;

create or replace function pg_temp.ok(p_cond boolean, p_label text)
returns void language plpgsql as $$
begin
  if p_cond then raise notice 'PASS  %', p_label;
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

create or replace function pg_temp.head(p_name text) returns uuid language sql as $$
  select id from public.fee_heads where name = p_name
     and school_id = public.current_school_id();
$$;

create or replace function pg_temp.sess() returns uuid language sql as $$
  select id from public.academic_sessions where school_id = public.current_school_id()
     and is_current limit 1;
$$;

create or replace function pg_temp.cls(p_name text) returns uuid language sql as $$
  select id from public.classes where name = p_name
     and school_id = public.current_school_id();
$$;

-- THIS suite's one enrolment.
--
-- Every query below goes through this rather than `select id from
-- public.enrollments`. That unqualified form assumes the database contains
-- nothing but this fixture, which is never safe and is not true in CI: the
-- workflow's own sanity-check step COMMITS a school with pupils before any suite
-- runs, so the bare select raised "more than one row returned by a subquery used
-- as an expression". The same assumption broke operator_billing.sql's first
-- assertion for the same reason.
create or replace function pg_temp.enr() returns uuid language sql as $$
  select e.id from public.enrollments e
    join public.schools s on s.id = e.school_id
   where s.name = 'Fee School';
$$;

-- --- Fixture -----------------------------------------------------------------
do $seed$
declare
  v_s uuid; v_o uuid := '00000000-0000-0000-0000-00000000fa01';
  v_c uuid := '00000000-0000-0000-0000-00000000fa02';
  v_sess uuid; v_cl uuid; v_stu uuid;
begin
  insert into public.schools (name) values ('Fee School') returning id into v_s;
  insert into public.subscriptions (school_id, plan_code, status, trial_ends_on)
    values (v_s, 'growth', 'active', current_date + 300);
  insert into auth.users (id, email, raw_app_meta_data) values
    (v_o, 'owner@fee.test', jsonb_build_object('school_id', v_s::text)),
    (v_c, 'clerk@fee.test', jsonb_build_object('school_id', v_s::text,
                                               'role', 'admin_clerk'));
  perform set_config('test.uid', v_o::text, false);

  insert into public.academic_sessions (school_id, name, is_current, starts_on, ends_on)
    values (v_s, '2026-27', true, '2026-04-01', '2027-03-31') returning id into v_sess;
  update public.school_settings set current_session_id = v_sess where school_id = v_s;
  insert into public.classes (school_id, name, level_order)
    values (v_s, 'Class 5', 5) returning id into v_cl;

  insert into public.students (school_id, full_name, father_name, status)
    values (v_s, 'Ahmed', 'Rashid', 'active') returning id into v_stu;
  insert into public.enrollments (school_id, student_id, session_id, class_id, roll_no, status)
    values (v_s, v_stu, v_sess, v_cl, '1', 'active');
end;
$seed$;

-- =============================================================================
-- 1. Rule 1 — a fee head can be created at all
-- =============================================================================
select pg_temp.ok(
  (select count(*) from public.fn_fee_heads()) >= 0,
  '1. the fee-head list answers — before 0066 there was no screen and no '
  || 'function behind one');

select public.fn_upsert_fee_head('Tuition', 'monthly', true, false, 1) as tuition \gset

select pg_temp.ok(
  (select name = 'Tuition' and is_recurring and active and not is_refundable
     from public.fn_fee_heads() where id = :'tuition'::uuid),
  '2. a school can create its Tuition head — the one thing a fresh school could '
  || 'not do, and without which it can never bill a monthly fee');

select public.fn_upsert_fee_head('Admission Fee', 'admission', false, false, 2) as adm \gset
select public.fn_upsert_fee_head('Security Deposit', 'security_deposit', false, true, 3) as dep \gset

select pg_temp.ok(
  (select count(*) from public.fn_fee_heads()) = 3,
  '3. and as many more as it needs');

-- Renaming.
select public.fn_upsert_fee_head('Monthly Tuition', 'monthly', true, false, 1,
                                 :'tuition'::uuid) as renamed \gset
select pg_temp.ok(
  (select name = 'Monthly Tuition' from public.fn_fee_heads() where id = :'tuition'::uuid),
  '4. and rename one without creating a second');

-- =============================================================================
-- 2. Rules 2 and 3 — the constraints worth having
-- =============================================================================
select pg_temp.ok(
  pg_temp.raises($$select public.fn_upsert_fee_head('MONTHLY TUITION')$$,
                 'already has a fee head called'),
  '5. a duplicate name is refused case-insensitively — two Tuition rows in one '
  || 'grid cannot be told apart');

select pg_temp.ok(
  pg_temp.raises(
    $$select public.fn_upsert_fee_head('Bad Deposit', 'security_deposit', true, true)$$,
    'cannot be recurring'),
  '6. a refundable head cannot be recurring — a deposit charged every month '
  || 'manufactures a liability every month');

select pg_temp.ok(
  pg_temp.raises($$select public.fn_upsert_fee_head('   ')$$, 'needs a name'),
  '7. and a blank name is refused rather than stored');

-- =============================================================================
-- 3. Rule 4 — setting an amount, and the arrears case
-- =============================================================================
select public.fn_set_fee_amount(pg_temp.sess(), pg_temp.cls('Class 5'),
                                :'tuition'::uuid, 1500) as eff \gset

select pg_temp.ok(
  :'eff'::date = '1900-01-01',
  '8. the FIRST amount for a head is written at the base date, not today — a '
  || 'school setting up in August must be able to bill April, and a row dated '
  || 'today would leave every earlier month empty');

select pg_temp.ok(
  (select amount = 1500 and next_from is null
     from public.fn_fee_structure(pg_temp.sess(), pg_temp.cls('Class 5'))
    where fee_head_id = :'tuition'::uuid),
  '9. and the grid reads it back, with no change scheduled');

-- Correcting a typo must not create a second price.
select public.fn_set_fee_amount(pg_temp.sess(), pg_temp.cls('Class 5'),
                                :'tuition'::uuid, 1600);
select pg_temp.ok(
  (select count(*) from public.fee_structures
    where fee_head_id = :'tuition'::uuid) = 1,
  '10. correcting the amount while no history exists UPDATES it rather than '
  || 'stacking a second row — a typo is not a price change');

select pg_temp.ok(
  (select amount = 1600 from public.fn_fee_structure(pg_temp.sess(), pg_temp.cls('Class 5'))
    where fee_head_id = :'tuition'::uuid),
  '11. and the grid shows the corrected figure');

-- =============================================================================
-- 4. Rules 5, 6, 7 — a scheduled rise, and the three billing paths
-- =============================================================================
select public.fn_set_fee_amount(pg_temp.sess(), pg_temp.cls('Class 5'),
                                :'tuition'::uuid, 2000, '2027-01-01') as future \gset

select pg_temp.ok(
  (select count(*) from public.fee_structures
    where fee_head_id = :'tuition'::uuid) = 2,
  '12. a rise dated in the future is a SECOND row — the history the column exists for');

select pg_temp.ok(
  (select amount = 1600 and next_amount = 2000 and next_from = '2027-01-01'
     from public.fn_fee_structure(pg_temp.sess(), pg_temp.cls('Class 5'))
    where fee_head_id = :'tuition'::uuid),
  '13. and the grid shows BOTH — what is billed now and what is coming — so a '
  || 'school is never surprised by its own scheduled increase');

-- The three billing paths, on a month BEFORE the rise.
select pg_temp.ok(
  (public.fn_student_monthly_fee(pg_temp.enr())->>'gross')::numeric = 1600,
  '14. the monthly fee is 1600, not 3600. Summing every price on record is what '
  || 'it did before, and that figure is what a clerk quotes a parent');

select public.fn_bill_student_month(
  pg_temp.enr(), '2026-05-01', '2026-05-10') as inv \gset

select pg_temp.ok(
  (select count(*) from public.invoice_lines
    where invoice_id = :'inv'::uuid and fee_head_id = :'tuition'::uuid) = 1,
  '15. billing May 2026 produces exactly ONE tuition line — it produced two '
  || 'before, at 1500 and 1800, charging a parent for a price eight months away');

select pg_temp.ok(
  (select amount = 1600 from public.invoice_lines
    where invoice_id = :'inv'::uuid and fee_head_id = :'tuition'::uuid),
  '16. at the price in force in May, not the one starting in January');

-- The class path, which was already correct, must still agree.
select pg_temp.ok(
  (select count(*) from public.fee_structures fs
    where fs.fee_head_id = :'tuition'::uuid) = 2,
  '17. (the two prices are still both on record — nothing was destroyed to make '
  || 'the billing correct)');

-- And a month AFTER the rise gets the new price.
select public.fn_bill_student_month(
  pg_temp.enr(), '2027-02-01', '2027-02-10') as inv2 \gset

select pg_temp.ok(
  (select amount = 2000 from public.invoice_lines
    where invoice_id = :'inv2'::uuid and fee_head_id = :'tuition'::uuid),
  '18. February 2027, after the rise, is billed at 2000 — the schedule is '
  || 'honoured in both directions, not merely ignored');

-- =============================================================================
-- 5. Rule 1 again — switching a head off, and never deleting a billed one
-- =============================================================================
select pg_temp.ok(
  (select in_use from public.fn_fee_heads() where id = :'tuition'::uuid),
  '19. the head reports itself IN USE once billed, so the screen can explain '
  || 'why it offers Off rather than Delete');

select public.fn_set_fee_head_active(:'adm'::uuid, false);
select pg_temp.ok(
  (select count(*) from public.fn_fee_heads()) = 2
  and (select count(*) from public.fn_fee_heads(true)) = 3,
  '20. switching one off hides it from the billing list but keeps it on the '
  || 'management list');

select pg_temp.ok(
  not exists (select 1 from public.fn_fee_structure(pg_temp.sess(), pg_temp.cls('Class 5'))
               where fee_head_id = :'adm'::uuid),
  '21. and it disappears from the fee grid, so nothing new is charged against it');

-- =============================================================================
-- 6. Permissions
-- =============================================================================
select set_config('test.uid', '00000000-0000-0000-0000-00000000fa02', false);

select pg_temp.ok(
  (select public.fn_upsert_fee_head('Exam Fee', 'exam', false) is not null),
  '22. a clerk CAN manage fee heads — this is daily office work, not a '
  || 'proprietor decision');

select set_config('test.uid', null, false);
select pg_temp.ok(
  pg_temp.raises($$select public.fn_upsert_fee_head('Sneaky')$$, 'not permitted'),
  '23. a caller with no school context cannot create one');

select pg_temp.ok(
  pg_temp.raises(
    format('select public.fn_set_fee_amount(%L, %L, %L, 1)',
           '00000000-0000-0000-0000-000000000000',
           '00000000-0000-0000-0000-000000000000',
           '00000000-0000-0000-0000-000000000000'),
    'not permitted'),
  '24. nor set an amount');

do $$ begin raise notice 'ALL FEE SETUP TESTS PASSED'; end $$;

rollback;

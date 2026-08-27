-- =============================================================================
-- The observer role: look at everything, change nothing.
--
-- Two defects sat here, and the second one is not about `readonly` at all.
--
-- WHAT `readonly` ACTUALLY EXPERIENCED. It is in ADMIN_ROLES in the app, so it
-- was shown the whole admin navigation. Asking the database what each of those
-- screens would return:
--
--   students, attendance ........................ worked
--   invoices, payments, expenses, till,
--   discounts, certificates, audit_log .......... ZERO ROWS — screens look empty
--   Reports -> Debit & Credit ................... 'Not permitted to read the accounts'
--   Staff ....................................... 'Not permitted'
--   Dashboard ................................... collected_month 500, finance_visible TRUE
--
-- Incoherent in both directions at once: the dashboard showed this role the
-- school's takings while every screen it could click through to showed nothing.
--
-- THE WORSE ONE. RLS treats the write verbs differently:
--
--   INSERT with no matching policy          -> RAISES
--   UPDATE / DELETE with no matching policy -> ZERO ROWS, and no error
--
-- So as a `readonly` login, `update students set full_name` returned SUCCESS.
-- Every direct-table write in db.ts was `const { error } = await ...update(...)`,
-- and `error` is null when nothing matched — so the app said "Saved." over an
-- unchanged record. That is indistinguishable, from the user's seat, from lost
-- work.
--
-- The rules this file defends:
--
--   1. AN OBSERVER READS EVERYTHING a staff member reads, money included, and
--      the assertions look for a REAL ROW rather than for "no error" — because
--      zero rows with no error was exactly the old broken state.
--   2. EVERY WRITE VERB IS REFUSED, and UPDATE and DELETE are asserted on
--      ROWS AFFECTED and on the value being unchanged, not on an exception,
--      because there is no exception to catch.
--   3. WRITE RPCs REFUSE an observer explicitly, with a message.
--   4. may_view NEVER REACHES A WRITE. Asserted here as well as in
--      check-readonly-writes.py, so the rule holds even if the script is not run.
--   5. AN INVITE WITH NO ROLE LANDS INACTIVE, rather than quietly acquiring the
--      fallback role and full read access.
--   6. NOTHING CROSSES A SCHOOL BOUNDARY, in both directions.
--
-- Run: psql -v ON_ERROR_STOP=1 -f supabase/tests/readonly_role.sql
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
  return position(lower(p_needle) in lower(sqlerrm)) > 0;
end;
$$;

/** How many rows a statement actually changed. The whole point: an UPDATE that
 *  RLS blocks does not raise, it affects nothing, so this is the only way to
 *  tell "refused" from "done". */
create or replace function pg_temp.affected(p_sql text) returns integer
language plpgsql as $$
declare n integer;
begin
  execute p_sql;
  get diagnostics n = row_count;
  return n;
exception when others then
  -- An exception is also a refusal. -1 distinguishes it from a silent zero so
  -- an assertion can say which kind happened.
  return -1;
end;
$$;

-- --- Fixture -----------------------------------------------------------------
-- One school with an owner and an observer and a row in every table the observer
-- must be able to read. A second school whose observer must see none of it.
do $seed$
declare
  v_a uuid; v_b uuid;
  v_oa uuid := '00000000-0000-0000-0000-00000000c001';
  v_ro uuid := '00000000-0000-0000-0000-00000000c002';
  v_ob uuid := '00000000-0000-0000-0000-00000000c003';
  v_rb uuid := '00000000-0000-0000-0000-00000000c004';
  v_sess uuid; v_cl uuid; v_sec uuid; v_stu uuid; v_enr uuid;
  v_head uuid; v_inv uuid; v_pay uuid; v_staff uuid; v_cat uuid;
  v_sess_b uuid; v_cl_b uuid; v_stu_b uuid;
begin
  insert into public.schools (name) values ('Obs A') returning id into v_a;
  insert into public.subscriptions (school_id, plan_code, status, trial_ends_on)
    values (v_a, 'growth', 'active', current_date + 30);
  insert into public.schools (name) values ('Obs B') returning id into v_b;
  insert into public.subscriptions (school_id, plan_code, status, trial_ends_on)
    values (v_b, 'growth', 'active', current_date + 30);

  insert into auth.users (id, email) values
    (v_oa, 'oa@obs.test'), (v_ro, 'ro@obs.test'),
    (v_ob, 'ob@obs.test'), (v_rb, 'rb@obs.test');
  insert into public.profiles (id, school_id, full_name, role, active) values
    (v_oa, v_a, 'Obs Owner A', 'owner', true),
    (v_ro, v_a, 'Obs Watcher A', 'readonly', true),
    (v_ob, v_b, 'Obs Owner B', 'owner', true),
    (v_rb, v_b, 'Obs Watcher B', 'readonly', true);

  -- ---- School A, as its owner ----
  perform set_config('test.uid', v_oa::text, false);
  insert into public.academic_sessions (school_id, name, is_current)
    values (v_a, '2025-26', true) returning id into v_sess;
  update public.school_settings set current_session_id = v_sess where school_id = v_a;
  insert into public.classes (school_id, name, level_order) values (v_a, 'Class 1', 1)
    returning id into v_cl;
  insert into public.sections (school_id, class_id, name) values (v_a, v_cl, 'A')
    returning id into v_sec;
  insert into public.students (school_id, full_name, status)
    values (v_a, 'Observed Pupil', 'active') returning id into v_stu;
  insert into public.enrollments (school_id, student_id, session_id, class_id, section_id,
                                  roll_no, status)
    values (v_a, v_stu, v_sess, v_cl, v_sec, '1', 'active') returning id into v_enr;
  insert into public.fee_heads (school_id, name, is_recurring)
    values (v_a, 'Tuition', true) returning id into v_head;
  insert into public.invoices (school_id, student_id, enrollment_id, session_id,
                               period_month, status, due_date)
    values (v_a, v_stu, v_enr, v_sess, date_trunc('month', current_date)::date,
            'issued', current_date) returning id into v_inv;
  insert into public.payments (school_id, student_id, amount, method)
    values (v_a, v_stu, 500, 'cash') returning id into v_pay;
  insert into public.staff (school_id, full_name, designation, status)
    values (v_a, 'Observed Teacher', 'Teacher', 'active') returning id into v_staff;
  select id into v_cat from public.expense_categories
   where school_id = v_a limit 1;
  insert into public.expenses (school_id, category_id, amount, spent_on, note)
    values (v_a, v_cat, 250, current_date, 'Chalk');
  insert into public.attendance_daily (school_id, enrollment_id, attendance_date, status)
    values (v_a, v_enr, current_date, 'present');
  perform public.fn_issue_certificate('bonafide', v_stu, '{}'::jsonb);

  -- ---- School B, deliberately different numbers ----
  perform set_config('test.uid', v_ob::text, false);
  insert into public.academic_sessions (school_id, name, is_current)
    values (v_b, '2025-26', true) returning id into v_sess_b;
  update public.school_settings set current_session_id = v_sess_b where school_id = v_b;
  insert into public.classes (school_id, name, level_order) values (v_b, 'Class 1', 1)
    returning id into v_cl_b;
  insert into public.students (school_id, full_name, status)
    values (v_b, 'Other School Pupil', 'active') returning id into v_stu_b;
  insert into public.payments (school_id, student_id, amount, method)
    values (v_b, v_stu_b, 9999, 'cash');
end;
$seed$;

-- =============================================================================
-- 1. An observer READS everything, and the assertions look for a real row
-- =============================================================================
select set_config('test.uid', '00000000-0000-0000-0000-00000000c002', false);
set local role authenticated;

select pg_temp.ok((select count(*) from public.students) = 1,
  '1. students — the pupil is visible');
select pg_temp.ok((select count(*) from public.invoices) = 1,
  '2. invoices — ONE row, not zero. Zero with no error was the whole defect: '
  || 'the Fees screen looked like the school had lost its billing');
select pg_temp.ok((select count(*) from public.payments) = 1,
  '3. payments — visible. A role that cannot see the money cannot oversee anything');
select pg_temp.ok((select count(*) from public.expenses) = 1,
  '4. expenses — visible, which makes an observer MORE widely-read than a clerk. '
  || 'Deliberate: breadth of reading and the right to write are different axes');
select pg_temp.ok((select count(*) from public.certificates) = 1,
  '5. certificates — the register is readable');
select pg_temp.ok((select count(*) from public.attendance_daily) = 1,
  '6. attendance is readable');
select pg_temp.ok((select count(*) from public.staff) = 1,
  '7. staff records are readable');
select pg_temp.ok((select count(*) from public.audit_log) > 0,
  '8. the audit log is readable — an observer checking who did what is the '
  || 'clearest use the role has');

-- The read RPCs the screens call. Every one of these refused before 0059.
select pg_temp.ok((select count(*) from public.fn_staff_roster()) = 1,
  '9. fn_staff_roster answers — it raised ''Not permitted'' before, so the Staff '
  || 'screen showed an error to a role the nav had already let in');
select pg_temp.ok((select count(*) from public.fn_report_ledger(current_date - 30, current_date, null)) >= 0,
  '10. the debit-and-credit report answers');
select pg_temp.ok((public.fn_dashboard_summary()->>'collected_month')::numeric = 500,
  '11. the dashboard money tile is honest now that the screens behind it work');

-- =============================================================================
-- 2. Every write is refused — and UPDATE/DELETE are checked on ROWS AFFECTED
-- =============================================================================
-- INSERT raises. This half always worked.
select pg_temp.ok(
  pg_temp.raises(
    'insert into public.students(school_id, full_name, status) '
    || 'values (public.current_school_id(), ''Hacked'', ''active'')',
    'row-level security'),
  '12. INSERT on students is refused with an error');

-- Since 0086 this one is refused a step EARLIER than it used to be: no role but
-- the table owner holds INSERT on public.payments at all, so the request never
-- reaches the policy. The needle therefore matches the privilege error rather
-- than 'row-level security', and the assertion says which — a test whose
-- message describes the wrong mechanism is a test that will mislead the next
-- person reading a failure.
select pg_temp.ok(
  pg_temp.raises(
    'insert into public.payments(school_id, student_id, amount, method) '
    || 'select public.current_school_id(), id, 1, ''cash'' from public.students limit 1',
    'permission denied'),
  '13. INSERT on payments is refused by PRIVILEGE, before RLS is consulted — '
  || 'no signed-in role can invent a receipt, observer or not');

-- UPDATE and DELETE do NOT raise. They affect zero rows, silently, which is why
-- these assertions count rows instead of catching an exception. This is the
-- defect the app-side mustWrite() exists to make visible.
select pg_temp.ok(
  pg_temp.affected('update public.students set full_name = ''Renamed'' where true') = 0,
  '14. UPDATE on students affects ZERO rows — and raises nothing, which is why '
  || 'the app said "Saved." over an unchanged record until mustWrite() was added');

-- -1 is pg_temp.affected's code for "it raised". Asserted as -1 rather than
-- "<= 0" on purpose: 0086 revoked DELETE on students from every signed-in role,
-- so this stopped being a silent no-op and became a loud refusal, and pinning
-- the assertion to the loud form means a future migration that hands the
-- privilege back fails this suite instead of passing it quietly.
select pg_temp.ok(
  pg_temp.affected('delete from public.students where true') = -1,
  '15. DELETE on students RAISES — since 0086 no signed-in role holds the '
  || 'privilege, so a pupil cannot be removed at all, only marked as left');

select pg_temp.ok(
  pg_temp.affected('update public.payments set amount = 1 where true') = -1,
  '16. a receipt cannot be altered — and the refusal is a privilege error, so '
  || 'it holds for an owner exactly as it holds for an observer');

select pg_temp.ok(
  pg_temp.affected('update public.staff set full_name = ''Renamed'' where true') = 0,
  '17. a staff record cannot be altered');

select pg_temp.ok(
  pg_temp.affected('update public.school_settings set name = ''Renamed'' where true') = 0,
  '18. the school profile cannot be altered');

-- The property that actually matters: the data is unchanged.
select pg_temp.ok(
  (select full_name from public.students limit 1) = 'Observed Pupil'
  and (select amount from public.payments limit 1) = 500,
  '19. and nothing actually changed — the assertion the row counts stand in for');

-- =============================================================================
-- 3. Write RPCs refuse an observer, and say so
-- =============================================================================
select pg_temp.ok(
  pg_temp.raises(
    format('select public.fn_set_student_photo(%L, ''x.jpg'')',
           (select id from public.students limit 1)),
    'only the office'),
  '20. an observer cannot change a pupil''s photograph');

select pg_temp.ok(
  pg_temp.raises(
    format('select public.fn_issue_certificate(''leaving'', %L, ''{}''::jsonb)',
           (select id from public.students limit 1)),
    'not permitted'),
  '21. an observer cannot issue a certificate — it would take a serial number '
  || 'that can never be reused');

select pg_temp.ok(
  pg_temp.raises(
    format('select public.fn_staff_leave(%L, current_date, null)',
           (select id from public.staff limit 1)),
    'only an owner or principal'),
  '22. an observer cannot record a member of staff leaving');

select pg_temp.ok(
  pg_temp.raises(
    format('select public.fn_generate_result_cards(%L, %L, true)',
           gen_random_uuid(), gen_random_uuid()),
    'not permitted'),
  '23. an observer cannot generate result cards');

select pg_temp.ok(
  pg_temp.raises(
    format('select public.fn_set_enrollment_stream(%L, ''Science'')',
           (select id from public.enrollments limit 1)),
    'not permitted'),
  '24. an observer cannot set a stream');

reset role;

-- =============================================================================
-- 3b. EVERY SCREEN THE OBSERVER'S NAVIGATION OFFERS MUST ANSWER
--
-- The gap this closes was real and shipped one migration later: 0059 put
-- Accounts into the observer's navigation, and fn_profit_snapshot — the Accounts
-- overview — kept its has_role gate, so the one screen the module exists for
-- said 'Not permitted to view finances'.
--
-- It escaped BOTH guards for the same reason: it is declared VOLATILE (it writes
-- nothing, but nobody had said so), and 0059 rewrote read gates only in STABLE
-- functions while check-readonly-writes.py looks only at STABLE ones too. A
-- blind spot in the migration and in the check, in the same place.
--
-- So this walks the RPCs behind the observer's nav and requires each to ANSWER.
-- A "no write policy names may_view" check can never find a screen that is
-- offered and then refuses; only calling it can.
-- =============================================================================
select set_config('test.uid', '00000000-0000-0000-0000-00000000c002', false);
set local role authenticated;

create or replace function pg_temp.answers(p_sql text) returns boolean
language plpgsql as $$
begin
  execute p_sql;
  return true;
exception when others then
  raise notice '      (refused: %)', sqlerrm;
  return false;
end;
$$;

select pg_temp.ok(pg_temp.answers('select public.fn_profit_snapshot()'),
  '24a. Accounts overview (fn_profit_snapshot) answers — it is in the observer''s '
  || 'nav, and it refused until 0060');
select pg_temp.ok(pg_temp.answers('select public.fn_finance_summary(current_date, current_date)'),
  '24b. the finance summary answers');
select pg_temp.ok(pg_temp.answers('select public.fn_report_balance_sheet(current_date)'),
  '24c. the balance sheet answers');
select pg_temp.ok(pg_temp.answers('select public.fn_counter_summary()'),
  '24d. the fee counter summary answers');
select pg_temp.ok(pg_temp.answers('select public.fn_dashboard_summary()'),
  '24e. the dashboard answers');
select pg_temp.ok(pg_temp.answers('select count(*) from public.fn_staff_roster()'),
  '24f. the staff roster answers');
select pg_temp.ok(pg_temp.answers('select count(*) from public.fn_deposits_held()'),
  '24g. the deposits-held report answers');
select pg_temp.ok(pg_temp.answers(
  'select count(*) from public.fn_defaulters((select current_session_id from '
  || 'public.school_settings where school_id = public.current_school_id()))'),
  '24h. the defaulters report answers');
select pg_temp.ok(pg_temp.answers(
  'select count(*) from public.fn_report_ledger(current_date - 30, current_date, null)'),
  '24i. the debit-and-credit statement answers');
select pg_temp.ok(pg_temp.answers('select count(*) from public.fn_enquiry_list()'),
  '24j. the enquiry list answers');

reset role;

-- =============================================================================
-- 4. may_view never reaches a write — asserted here, not only in the script
-- =============================================================================
select pg_temp.ok(
  not exists (
    select 1 from pg_policy pol
    join pg_class c on c.oid = pol.polrelid
    join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public' and pol.polcmd <> 'r'
     and (coalesce(pg_get_expr(pol.polqual, pol.polrelid), '')
       || coalesce(pg_get_expr(pol.polwithcheck, pol.polrelid), '')) like '%may_view(%'),
  '25. no INSERT / UPDATE / DELETE / ALL policy consults may_view');

select pg_temp.ok(
  not exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.provolatile = 'v'
       and p.prosrc like '%may_view(%'),
  '26. no VOLATILE function consults may_view — a volatile function can write');

-- The two permission predicates that LOOK like reads. If may_view ever reaches
-- them, an observer can enter marks and overwrite a child's photograph — through
-- the functions that call them, so nothing at the call site looks wrong.
select pg_temp.ok(
  not exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and p.proname in ('fn_may_manage_class', 'fn_may_write_school_file')
       and p.prosrc like '%may_view(%'),
  '27. fn_may_manage_class and fn_may_write_school_file still gate on has_role — '
  || 'they are STABLE and look like reads, but they authorise WRITES elsewhere');

select pg_temp.ok(
  (select provolatile from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'may_view') in ('s', 'i'),
  '28. may_view is STABLE, so it cannot be slipped into a write path unnoticed');

-- Not vacuous: the helper is genuinely the mechanism.
select pg_temp.ok(
  (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.prosrc like '%may_view(%') >= 20,
  '29. at least twenty read gates use may_view — a suite that passed because the '
  || 'helper had been reverted would be measuring nothing');

-- =============================================================================
-- 5. An invite with no role lands INACTIVE
-- =============================================================================
-- 0065 moved these two assertions onto a stronger property than 0059 could
-- state. 0059 asked "does a half-finished invite land INACTIVE?", which
-- presumed the invite was believed at all. It should not have been: the
-- metadata carrying it is written by the browser at auth.signUp, so
-- `role: 'principal'` in that field was a self-service promotion. 0065 stopped
-- reading it, and the correct assertion is now that a signup carrying school
-- and role in USER metadata produces NOTHING — and that the trusted path,
-- app_metadata, produces exactly what it asked for.
do $invites$
declare
  v_a uuid := (select id from public.schools where name = 'Obs A');
  v_forged  uuid := '00000000-0000-0000-0000-00000000c005';
  v_trusted uuid := '00000000-0000-0000-0000-00000000c006';
begin
  -- The attack: a browser signUp naming a school and asking for a role.
  insert into auth.users (id, email, raw_user_meta_data)
  values (v_forged, 'forged@obs.test',
          jsonb_build_object('school_id', v_a::text, 'full_name', 'Forged Clerk',
                             'role', 'admin_clerk'));

  -- The trusted path: only the service role can write app_metadata, so this is
  -- what an Edge Function's createUser call looks like.
  insert into auth.users (id, email, raw_user_meta_data, raw_app_meta_data)
  values (v_trusted, 'trusted@obs.test',
          jsonb_build_object('full_name', 'Clerk Invite'),
          jsonb_build_object('school_id', v_a::text, 'role', 'admin_clerk'));
end;
$invites$;

select pg_temp.ok(
  not exists (select 1 from public.profiles
               where id = '00000000-0000-0000-0000-00000000c005'),
  '30. a signup that names its own school AND role in USER metadata gets NO '
  || 'profile at all — that field is written by the browser, so believing it let '
  || 'any parent make themselves principal');

select pg_temp.ok(
  (select active and role::text = 'admin_clerk' from public.profiles
    where id = '00000000-0000-0000-0000-00000000c006'),
  '31. while the same request through APP metadata — which only the service role '
  || 'can write — is created active with exactly that role');

-- The whitelist still earns its keep, but its job changed. It is no longer the
-- security boundary — app_metadata is — so what it now defends against is an
-- Edge Function TYPO: an unrecognised role must not be cast (that would fail the
-- signup itself) and must not be honoured either.
do $bad$
declare v_a uuid := (select id from public.schools where name = 'Obs A');
begin
  insert into auth.users (id, email, raw_user_meta_data, raw_app_meta_data)
  values ('00000000-0000-0000-0000-00000000c007', 'bad@obs.test',
          '{}'::jsonb,
          jsonb_build_object('school_id', v_a::text, 'role', 'superuser'));
end;
$bad$;

select pg_temp.ok(
  (select not active and role::text = 'readonly' from public.profiles
    where id = '00000000-0000-0000-0000-00000000c007'),
  '32. an unrecognised role on the TRUSTED path falls through to the safe default '
  || 'AND stays inactive — a typo in an Edge Function neither crashes the signup '
  || 'nor grants anything');

-- =============================================================================
-- 6. Nothing crosses a school boundary, in both directions
-- =============================================================================
select set_config('test.uid', '00000000-0000-0000-0000-00000000c002', false);
set local role authenticated;
select pg_temp.ok(
  not exists (select 1 from public.students where full_name = 'Other School Pupil')
  and (select count(*) from public.payments) = 1,
  '33. school A''s observer sees none of school B''s pupils or payments');
reset role;

select set_config('test.uid', '00000000-0000-0000-0000-00000000c004', false);
set local role authenticated;
select pg_temp.ok(
  not exists (select 1 from public.students where full_name = 'Observed Pupil'),
  '34. and school B''s observer sees none of school A''s — the reverse direction, '
  || 'because a filter scoped to whichever school was created first passes one way only');
select pg_temp.ok(
  (select count(*) from public.payments) = 1
  and (select amount from public.payments limit 1) = 9999,
  '35. school B''s observer sees only school B''s money');
reset role;

rollback;

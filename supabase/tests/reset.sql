-- =============================================================================
-- Starting again: prove it clears everything, keeps what is not the school's to
-- clear, and cannot be reached by anyone who should not have it.
--
-- The dangerous half of this feature is not the deleting. It is the possibility
-- of a HALF-cleared school: the owner is told it is empty, starts entering real
-- admissions, and last week's practice data is still sitting underneath in one
-- table nobody thought about. So the strongest assertion here is the sweep: no
-- table carrying a school_id may have a single row left, computed from the
-- catalogue rather than from a list somebody has to remember to update.
--
-- Run: psql -v ON_ERROR_STOP=1 -f supabase/tests/reset.sql
-- =============================================================================
\set ON_ERROR_STOP on
begin;

create or replace function auth.uid() returns uuid language sql stable as
  $$ select nullif(current_setting('test.uid', true), '')::uuid $$;

create temp table ids (k text primary key, v uuid);

do $seed$
declare
  s1 uuid := gen_random_uuid(); s2 uuid := gen_random_uuid();
  own uuid := '00000000-0000-0000-0000-00000000a001';
  clk uuid := '00000000-0000-0000-0000-00000000a002';
  own2 uuid := '00000000-0000-0000-0000-00000000a003';
  ses uuid; cls uuid; sec uuid; fam uuid; stu uuid; enr uuid; st uuid;
begin
  insert into public.schools (id, name, city) values
    (s1, 'Al Qalam Public School', 'Islamabad'),
    (s2, 'Untouched School', 'Lahore');
  -- One on trial, one paying.
  insert into public.subscriptions (school_id, plan_code, status, trial_ends_on) values
    (s1, 'starter', 'trialing', current_date + 10),
    (s2, 'starter', 'active',   current_date + 300);

  insert into auth.users (id, email) values
    (own, 'owner@alqalam.test'), (clk, 'clerk@alqalam.test'), (own2, 'owner@untouched.test')
    on conflict (id) do nothing;
  alter table public.profiles disable trigger user;
  insert into public.profiles (id, school_id, full_name, role) values
    (own, s1, 'The Owner', 'owner'), (clk, s1, 'The Clerk', 'admin_clerk'),
    (own2, s2, 'Other Owner', 'owner');
  alter table public.profiles enable trigger user;

  -- A week of practice in the trial school.
  insert into public.academic_sessions (school_id, name, starts_on, ends_on, is_current)
    values (s1, '2026-2027', current_date - 20, current_date + 300, true) returning id into ses;
  insert into public.classes (school_id, name, level_order) values (s1, 'Class 5', 5) returning id into cls;
  insert into public.sections (school_id, class_id, name) values (s1, cls, 'A') returning id into sec;
  insert into public.families (school_id, head_name) values (s1, 'Practice Family') returning id into fam;
  insert into public.students (school_id, gr_no, full_name, family_id, admission_date, status)
    values (s1, 'GR-1', 'Practice Child', fam, current_date, 'active') returning id into stu;
  insert into public.enrollments (school_id, student_id, session_id, class_id, section_id, roll_no)
    values (s1, stu, ses, cls, sec, '1') returning id into enr;
  insert into public.payments (school_id, student_id, family_id, amount, method, receipt_no, status)
    values (s1, stu, fam, 1500, 'cash', 1, 'confirmed');
  insert into public.attendance_daily (school_id, enrollment_id, attendance_date, status, marked_by)
    values (s1, enr, current_date, 'present', own);
  insert into public.staff (school_id, full_name, designation) values (s1, 'A Teacher', 'Teacher')
    returning id into st;
  insert into public.expense_categories (school_id, name) values (s1, 'Practice Category');

  -- And real data in the OTHER school, which must not be touched.
  insert into public.families (school_id, head_name) values (s2, 'Real Family');
  insert into public.classes (school_id, name, level_order) values (s2, 'Class 1', 1);

  insert into ids values ('s1', s1), ('s2', s2), ('own', own), ('clk', clk), ('own2', own2);
end $seed$;

-- =============================================================================
-- 1. Who may not
-- =============================================================================
do $who$
declare ok boolean;
begin
  -- A clerk may not, however sure they are.
  perform set_config('test.uid', (select v::text from ids where k='clk'), false);
  ok := false;
  begin perform public.fn_reset_school_data('Al Qalam Public School');
  exception when others then ok := true; end;
  if not ok then raise exception 'FAIL: a clerk emptied the school'; end if;

  -- The owner, with the wrong name typed. One click is not a confirmation.
  perform set_config('test.uid', (select v::text from ids where k='own'), false);
  ok := false;
  begin perform public.fn_reset_school_data('al qalam');
  exception when others then ok := true; end;
  if not ok then raise exception 'FAIL: a partial name was accepted as confirmation'; end if;

  if not exists (select 1 from public.students where school_id = (select v from ids where k='s1')) then
    raise exception 'FAIL: a refused reset deleted rows anyway';
  end if;
  raise notice 'ok: a clerk cannot, and the name must be typed exactly';
end $who$;

-- =============================================================================
-- 2. A PAYING school cannot, which is the point of the restriction
-- =============================================================================
do $paying$
declare ok boolean;
begin
  perform set_config('test.uid', (select v::text from ids where k='own2'), false);
  ok := false;
  begin perform public.fn_reset_school_data('Untouched School');
  exception when others then ok := true; end;
  if not ok then
    raise exception 'FAIL: a paying school with real history was allowed to wipe itself';
  end if;
  raise notice 'ok: only a school on trial can start again';
end $paying$;

-- =============================================================================
-- 3. It clears EVERYTHING, checked against the catalogue
-- =============================================================================
do $sweep$
declare
  r jsonb; v_t text; v_n bigint; v_left text[] := array[]::text[];
  v_keep text[] := array['subscriptions','school_settings','profiles','audit_log','reviews',
                         'operator_actions','operator_sessions','platform_invoices',
                         'platform_payments','platform_payment_claims','platform_exports'];
begin
  perform set_config('test.uid', (select v::text from ids where k='own'), false);
  r := public.fn_reset_school_data('  Al Qalam Public School  ');
  if not (r->>'cleared')::boolean then raise exception 'FAIL: reset reported failure: %', r; end if;
  if (r->>'rows_removed')::bigint < 8 then
    raise exception 'FAIL: only % rows removed, the seed put in more than that', r->>'rows_removed';
  end if;

  -- The assertion that matters. Every table with a school_id, from the
  -- catalogue, not from a list. A table added next year is covered here the day
  -- it is created.
  for v_t in
    select c.relname from pg_class c
      join pg_namespace n on n.oid = c.relnamespace
      join pg_attribute a on a.attrelid = c.oid and a.attname = 'school_id' and a.attnum > 0
     where n.nspname = 'public' and c.relkind = 'r' and not (c.relname = any(v_keep))
  loop
    execute format('select count(*) from public.%I where school_id = $1', v_t)
      into v_n using (select v from ids where k='s1');
    if v_n > 0 then v_left := v_left || (v_t || '=' || v_n::text); end if;
  end loop;
  if array_length(v_left, 1) > 0 then
    raise exception 'FAIL: the school was only HALF cleared, which is worse than not '
                    'clearing it: the owner is told it is empty and starts entering real '
                    'admissions on top. Left behind: %', array_to_string(v_left, ', ');
  end if;
  raise notice 'ok: every school-scoped table is empty, checked from the catalogue';
end $sweep$;

-- =============================================================================
-- 4. What it must NOT have taken
-- =============================================================================
do $kept$
declare n int;
begin
  -- The school, its subscription, and every login.
  if not exists (select 1 from public.schools where id = (select v from ids where k='s1')) then
    raise exception 'FAIL: the school itself was deleted';
  end if;
  if not exists (select 1 from public.subscriptions where school_id = (select v from ids where k='s1')) then
    raise exception 'FAIL: the subscription was deleted, so the school is now unlicensed';
  end if;
  select count(*) into n from public.profiles where school_id = (select v from ids where k='s1');
  if n <> 2 then
    raise exception 'FAIL: % login(s) left, expected 2. An owner who resets themselves out '
                    'of their own account cannot get back in, and a deleted profile cannot '
                    'free the email address for reuse.', n;
  end if;

  -- And the other school is untouched.
  select count(*) into n from public.families where school_id = (select v from ids where k='s2');
  if n <> 1 then raise exception 'FAIL: another school lost data: % families left', n; end if;
  select count(*) into n from public.classes where school_id = (select v from ids where k='s2');
  if n <> 1 then raise exception 'FAIL: another school lost its classes'; end if;

  raise notice 'ok: the school, its subscription, its logins and every other school survive';
end $kept$;

-- =============================================================================
-- 5. It is written down that it happened
-- =============================================================================
do $logged$
declare n int;
begin
  select count(*) into n from public.operator_actions
   where action = 'school.data_reset' and school_id = (select v from ids where k='s1');
  if n <> 1 then
    raise exception 'FAIL: clearing a school wrote % audit row(s), expected 1', n;
  end if;
  raise notice 'ok: the reset is recorded';
end $logged$;

rollback;
\echo 'RESET: ALL TESTS PASSED'

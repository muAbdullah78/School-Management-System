-- =============================================================================
-- Staff QR check-in. No biometric — so this file is about the gap between
-- "a body was at the gate" and "a valid, currently-displayed code was presented
-- by a signed-in account", and about which parts of that gap are closed.
--
-- Demonstrated on a real database before 0062 was written. One teacher, login
-- linked to her staff record, sitting at home:
--
--   inserted her own attendance row .......... yes. No QR code involved at all.
--     with source = 'qr', code_id null ....... and nothing anywhere read code_id
--   back-dated seven days she never worked ... yes
--   the code .................................. 32 static hex chars, no expiry
--   check-out / lateness / school day ......... none of the three existed
--
-- The rules this file defends:
--
--   1. A TEACHER CANNOT WRITE HER OWN ATTENDANCE ROW. The only ways in are a
--      scan and an office mark, both SECURITY DEFINER. This is worth more than
--      everything else here: the rotating code is a lock, and this is the wall.
--   2. NOBODY CAN RECORD ATTENDANCE FOR A DAY THAT HAS NOT HAPPENED.
--   3. A ROTATING CODE REFUSES A PLAIN CODE. Otherwise the rotation is
--      decorative in exactly the way the direct insert was.
--   4. A STALE OR FUTURE TOKEN IS REFUSED, and the PREVIOUS WINDOW IS NOT — a
--      scan has to survive the second between the screen and the phone.
--   5. THE SECRET NEVER LEAVES THE DATABASE, and an observer is not handed a
--      live token.
--   6. AN OFFICE MARK OUTRANKS A SCAN, and overriding a scan needs a reason.
--   7. THE SECOND SCAN IS THE CHECK-OUT, and a double scan on arrival is not.
--   8. NOTHING IS LATE UNTIL A START TIME IS SET.
--   9. EVERY REFUSAL IS LOGGED — durably, which is why a refusal RETURNS and
--      does not raise: the first draft logged and then raised, and a raise rolls
--      the log row back with it, so the refusal register would have been empty
--      for ever and the brute-force counter that reads it would never have
--      counted past zero.
--  10. NOTHING CROSSES A SCHOOL BOUNDARY, in both directions.
--
-- Everything after the fixture runs with `set local role authenticated`. RLS does
-- not apply to a table's owner, so a negative assertion made as postgres proves
-- nothing at all — it would pass with no policies in place.
--
-- Run: psql -v ON_ERROR_STOP=1 -f supabase/tests/staff_checkin.sql
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

-- SECURITY DEFINER because the suite runs as `authenticated`, where RLS on
-- profiles hides the other school's rows — so an ordinary lookup could not
-- switch to school B's owner to test the boundary from the other side.
create or replace function pg_temp.be(p_name text) returns void
language sql security definer as $$
  select set_config('test.uid',
    (select id::text from public.profiles where full_name = p_name), false);
$$;

create or replace function pg_temp.raises(p_sql text, p_needle text) returns boolean
language plpgsql as $$
begin
  execute p_sql;
  return false;
exception when others then
  if position(lower(p_needle) in lower(sqlerrm)) > 0 then return true; end if;
  raise notice '   (raised the wrong thing: %)', sqlerrm;
  return false;
end;
$$;

-- Counts ROWS AFFECTED, and returns -1 if the statement raised. A blocked INSERT
-- raises, but a blocked UPDATE or DELETE affects zero rows and raises nothing, so
-- "did it error?" is the wrong question for half of these.
create or replace function pg_temp.affected(p_sql text) returns integer
language plpgsql as $$
declare n integer;
begin
  execute p_sql;
  get diagnostics n = row_count;
  return n;
exception when others then
  return -1;
end;
$$;

create or replace function pg_temp.staff(p_name text) returns uuid
language sql security definer as $$
  select id from public.staff where full_name = p_name
   and school_id = public.current_school_id();
$$;

-- Minting a token for an arbitrary window. SECURITY DEFINER on purpose: the
-- digest function is revoked from `authenticated`, which is the point of
-- assertion 18, so a test that needs to FORGE a token has to stand outside the
-- application to do it — exactly as an attacker would have to.
create or replace function pg_temp.mint(p_offset bigint, p_digest text default null)
returns text language plpgsql security definer as $$
declare v_code text; v_secret text; v_win bigint;
begin
  select code, secret into v_code, v_secret from public.staff_checkin_codes
   where rotating and active
     and school_id = (select id from public.schools where name = 'Checkin School A');
  v_win := floor(extract(epoch from now()) / 30)::bigint + p_offset;
  return v_code || '.' || v_win::text || '.'
         || coalesce(p_digest, public.fn__checkin_digest(v_secret, v_win));
end;
$$;

create or replace function pg_temp.plain_code() returns text
language sql security definer as $$
  select code from public.staff_checkin_codes
   where rotating and active
     and school_id = (select id from public.schools where name = 'Checkin School A');
$$;

-- Moving an arrival time back, so that the next scan is past the grace window
-- and counts as a departure. Nothing in the app can do this; it is standing in
-- for five hours passing.
create or replace function pg_temp.backdate_arrival(p_staff_name text, p_hours integer)
returns void language sql security definer as $$
  update public.staff_attendance a set checked_at = now() - (p_hours || ' hours')::interval
   where a.attendance_date = current_date
     and a.staff_id = (select id from public.staff where full_name = p_staff_name
                        and school_id = (select id from public.schools
                                          where name = 'Checkin School A'));
$$;

-- --- Fixture -----------------------------------------------------------------
-- Two schools, created BEFORE any login is adopted: provisioning a second school
-- while signed in as the first one's owner trips the cross-tenant guard.
--
-- Three teachers in school A with logins, because the suite needs a first scan
-- of the day three separate times: an ordinary arrival, a departure, and a late
-- arrival once a start time is set.
do $seed$
declare
  v_a uuid; v_b uuid;
  v_oa uuid := '00000000-0000-0000-0000-00000000c101';
  v_ta uuid := '00000000-0000-0000-0000-00000000c102';
  v_ka uuid := '00000000-0000-0000-0000-00000000c103';
  v_ra uuid := '00000000-0000-0000-0000-00000000c104';
  v_la uuid := '00000000-0000-0000-0000-00000000c105';
  v_ob uuid := '00000000-0000-0000-0000-00000000c106';
  v_tb uuid := '00000000-0000-0000-0000-00000000c107';
  v_s1 uuid; v_s2 uuid; v_s3 uuid; v_s4 uuid;
begin
  insert into public.schools (name) values ('Checkin School A') returning id into v_a;
  insert into public.schools (name) values ('Checkin School B') returning id into v_b;
  insert into public.subscriptions (school_id, plan_code, status, trial_ends_on) values
    (v_a, 'growth', 'active', current_date + 60),
    (v_b, 'growth', 'active', current_date + 60);

  insert into auth.users (id, email) values
    (v_oa, 'oa@ci.test'), (v_ta, 'ta@ci.test'), (v_ka, 'ka@ci.test'),
    (v_ra, 'ra@ci.test'), (v_la, 'la@ci.test'), (v_ob, 'ob@ci.test'), (v_tb, 'tb@ci.test');

  alter table public.profiles disable trigger user;
  insert into public.profiles (id, school_id, full_name, role, active) values
    (v_oa, v_a, 'CI Owner A',    'owner', true),
    (v_ta, v_a, 'Miss Ayesha',   'class_teacher', true),
    (v_ka, v_a, 'Mr Kamran',     'subject_teacher', true),
    (v_ra, v_a, 'CI Observer A', 'readonly', true),
    (v_la, v_a, 'Mrs Late',      'class_teacher', true),
    (v_ob, v_b, 'CI Owner B',    'owner', true),
    (v_tb, v_b, 'Mr Bilal',      'class_teacher', true);
  alter table public.profiles enable trigger user;

  perform set_config('test.uid', v_oa::text, false);
  insert into public.staff (school_id, full_name, designation, status)
    values (v_a, 'Miss Ayesha', 'Teacher', 'active') returning id into v_s1;
  insert into public.staff (school_id, full_name, designation, status)
    values (v_a, 'Mr Kamran', 'Teacher', 'active') returning id into v_s2;
  insert into public.staff (school_id, full_name, designation, status)
    values (v_a, 'Mrs Late', 'Teacher', 'active') returning id into v_s3;
  -- No login at all. A school still has to be able to mark the ayah and the
  -- watchman, who will never scan anything.
  insert into public.staff (school_id, full_name, designation, status)
    values (v_a, 'Mr Watchman', 'Watchman', 'active');
  perform public.fn_link_staff_profile(v_s1, v_ta);
  perform public.fn_link_staff_profile(v_s2, v_ka);
  perform public.fn_link_staff_profile(v_s3, v_la);

  perform set_config('test.uid', v_ob::text, false);
  insert into public.staff (school_id, full_name, designation, status)
    values (v_b, 'Mr Bilal', 'Teacher', 'active') returning id into v_s4;
  perform public.fn_link_staff_profile(v_s4, v_tb);
end;
$seed$;

-- From here on, everything is a real client. RLS does not apply to the owner.
set local role authenticated;

-- =============================================================================
-- 1. The loophole that made the whole feature decorative
-- =============================================================================
select pg_temp.be('Miss Ayesha');

select pg_temp.ok(
  pg_temp.affected(format(
    'insert into public.staff_attendance (school_id, staff_id, attendance_date, status, checked_at, source) '
    'values (%L, %L, current_date, ''present'', now(), ''qr'')',
    public.current_school_id(), public.my_staff_id())) = -1,
  '1. a teacher cannot insert her own attendance row. This is the whole feature: '
  || 'before 0062 she could, with source = ''qr'' and no code, from home');

select pg_temp.ok(
  (select count(*) from public.staff_attendance) = 0,
  '2. and nothing landed — the register is still empty');

select pg_temp.ok(
  pg_temp.affected(format(
    'insert into public.staff_attendance (school_id, staff_id, attendance_date, status, checked_at, source) '
    'values (%L, %L, current_date - 3, ''present'', now(), ''qr'')',
    public.current_school_id(), public.my_staff_id())) = -1,
  '3. nor back-date a day she never worked — on a school that pays by attendance '
  || 'that was payroll fraud in one call');

-- =============================================================================
-- 2. Nobody records a day that has not happened — not even the office
-- =============================================================================
select pg_temp.be('CI Owner A');

select pg_temp.ok(
  pg_temp.raises(format(
    'select public.fn_set_staff_attendance(%L, current_date + 1, ''present''::public.attendance_status, ''early'')',
    pg_temp.staff('Miss Ayesha')),
    'has not happened yet'),
  '4. the office cannot mark attendance for tomorrow either — a month of '
  || 'attendance recorded in advance is not a thing a register may hold');

select pg_temp.ok(
  pg_temp.raises(format(
    'insert into public.staff_attendance (school_id, staff_id, attendance_date, status, source) '
    'values (%L, %L, current_date + 5, ''present'', ''manual'')',
    public.current_school_id(), pg_temp.staff('Miss Ayesha')),
    'staff_attendance_not_future'),
  '5. and the CHECK constraint stops it on every other path too, including ones '
  || 'nobody has written yet');

-- =============================================================================
-- 3. A rotating code refuses a plain code
-- =============================================================================
select public.fn_generate_checkin_code('Gate screen', null, null, true, true) as rc \gset

select pg_temp.ok(
  (:'rc'::jsonb->>'rotating')::boolean and (:'rc'::jsonb->>'code') is not null,
  '6. a rotating code is created');

select pg_temp.ok(
  (:'rc'::jsonb ? 'secret') = false,
  '7. and its secret is NOT returned to the caller — a rotating code whose seed '
  || 'reaches a browser is not a rotating code');

select pg_temp.be('Miss Ayesha');
select public.fn_staff_check_in(:'rc'::jsonb->>'code') as bare \gset

select pg_temp.ok(
  (:'bare'::jsonb->>'status') = 'refused'
  and (:'bare'::jsonb->>'reason') = 'plain code presented against a rotating code',
  '8. presenting the bare code against a rotating one is refused. THE POINT: '
  || 'accepting it would make the rotation decorative, which is the shape of the '
  || 'defect this migration exists to fix');

select pg_temp.ok(
  (select count(*) from public.staff_attendance) = 0,
  '9. and no attendance row was written');

-- =============================================================================
-- 4. Tokens: the current window works, so does the one before it, nothing else
-- =============================================================================
select pg_temp.be('CI Owner A');
select public.fn_checkin_display() as disp \gset

select pg_temp.ok(
  (:'disp'::jsonb->>'status') = 'rotating'
  and (:'disp'::jsonb->>'token') like ((:'rc'::jsonb->>'code') || '.%')
  and (:'disp'::jsonb->>'period_seconds')::integer = 30
  and (:'disp'::jsonb->>'expires_in')::integer between 1 and 30,
  '10. the display hands out a token for the current window, with the seconds it '
  || 'has left, so a screen never shows a token that has stopped working');

select pg_temp.ok(
  (:'disp'::jsonb ? 'secret') = false,
  '11. and never the secret');

select pg_temp.be('Miss Ayesha');
select public.fn_staff_check_in(:'disp'::jsonb->>'token', null, null, 'iPhone') as inn \gset

select pg_temp.ok(
  (:'inn'::jsonb->>'status') = 'ok',
  '12. a live token checks her in');

select pg_temp.ok(
  (select code_id is not null and code_window is not null and source = 'qr'
     from public.staff_attendance where attendance_date = current_date),
  '13. and the row records WHICH code and WHICH window — the forged row had a '
  || 'null code_id and nothing anywhere looked at it');

select pg_temp.be('Mr Kamran');
select public.fn_staff_check_in(pg_temp.mint(-1), null, null, 'Android') as prev \gset

select pg_temp.ok(
  (:'prev'::jsonb->>'status') = 'ok',
  '14. the PREVIOUS 30-second window is still accepted — a token has to survive '
  || 'the second between the screen rendering it and the phone posting it');

select pg_temp.be('Miss Ayesha');
select public.fn_staff_check_in(pg_temp.mint(-4)) as stale \gset

select pg_temp.ok(
  (:'stale'::jsonb->>'reason') = 'stale or future token',
  '15. a token two minutes old is refused. THAT is the difference between a '
  || 'photograph being worth a minute and being worth a whole term');

select public.fn_staff_check_in(pg_temp.mint(0, 'deadbeef')) as forged \gset

select pg_temp.ok(
  (:'forged'::jsonb->>'reason') = 'bad token digest',
  '16. a guessed digest on a live window is refused');

select public.fn_staff_check_in(pg_temp.mint(100)) as future \gset

select pg_temp.ok(
  (:'future'::jsonb->>'reason') = 'stale or future token',
  '17. and a token for a FUTURE window is refused too, so a leaked secret could '
  || 'not be spent in advance');

-- =============================================================================
-- 5. The secret is not readable, and an observer is not handed a live token
-- =============================================================================
select pg_temp.ok(
  (select count(*) from public.staff_checkin_codes) = 0,
  '18. a teacher cannot read the check-in codes table at all, so she cannot read '
  || 'the secret and mint her own tokens for ever');

select pg_temp.ok(
  pg_temp.raises(format('select public.fn__checkin_digest(%L, 1::bigint)', 'anything'),
                 'permission denied'),
  '19. and cannot call the digest function either — a secret nobody can read is '
  || 'no use if anybody can ask the database to hash one');

select pg_temp.be('CI Observer A');
select pg_temp.ok(
  pg_temp.raises('select public.fn_checkin_display()', 'not permitted'),
  '20. an observer is refused a live token. It is not a read of the school''s '
  || 'records, it is a key to the gate — so has_role, not may_view');

select pg_temp.ok(
  (select count(*) from public.fn_staff_attendance_day(current_date)) > 0,
  '21. while the observer CAN read the daily register, which is a read');

-- =============================================================================
-- 6. An office mark outranks a scan, and overriding a scan needs a reason
-- =============================================================================
select pg_temp.be('CI Owner A');

select pg_temp.ok(
  pg_temp.raises(format(
    'select public.fn_set_staff_attendance(%L, current_date, ''absent''::public.attendance_status)',
    pg_temp.staff('Miss Ayesha')),
    'needs a reason'),
  '22. overwriting a recorded check-in with a judgement needs a reason — it is '
  || 'exactly the thing somebody has to be able to explain a month later');

select public.fn_set_staff_attendance(
  pg_temp.staff('Miss Ayesha'), current_date, 'leave', 'Called away, confirmed by phone');

select pg_temp.ok(
  (select status::text = 'leave' and source = 'manual'
      and reason = 'Called away, confirmed by phone' and checked_at is not null
     from public.staff_attendance
    where staff_id = pg_temp.staff('Miss Ayesha') and attendance_date = current_date),
  '23. the office mark lands, and the ORIGINAL arrival time is kept — what time '
  || 'somebody actually arrived is a fact worth keeping even when the status changes');

select pg_temp.be('Miss Ayesha');
select public.fn_staff_check_in(pg_temp.mint(0)) as afteroffice \gset

select pg_temp.ok(
  (:'afteroffice'::jsonb->>'status') = 'office_marked',
  '24. a scan does not overwrite an office mark — otherwise a teacher marked '
  || 'absent could scan the absence away');

select pg_temp.be('CI Owner A');
select pg_temp.ok(
  (select status::text = 'leave' from public.staff_attendance
    where staff_id = pg_temp.staff('Miss Ayesha') and attendance_date = current_date),
  '25. and the office''s status is still what stands');

-- =============================================================================
-- 7. The second scan is the check-out; a double scan on arrival is not
-- =============================================================================
select pg_temp.be('Mr Kamran');
select public.fn_staff_check_in(pg_temp.mint(0)) as dbl \gset

select pg_temp.ok(
  (:'dbl'::jsonb->>'status') = 'already',
  '26. a double scan seconds after arrival is a repeat, not a departure — '
  || 'otherwise a nervous teacher checks herself out at 08:01');

select pg_temp.backdate_arrival('Mr Kamran', 5);
select public.fn_staff_check_in(pg_temp.mint(0)) as out \gset

select pg_temp.ok(
  (:'out'::jsonb->>'status') = 'out',
  '27. the second scan of the day, once the grace window has passed, is the check-out');

select pg_temp.ok(
  (:'out'::jsonb->>'worked_minutes')::integer between 295 and 302,
  '28. and worked_minutes is derived from the two timestamps, not stored twice');

-- =============================================================================
-- 8. Nothing is late until a start time is set
-- =============================================================================
select pg_temp.be('CI Owner A');
select pg_temp.ok(
  (select late_minutes is null and status::text = 'present'
     from public.staff_attendance
    where staff_id = pg_temp.staff('Mr Kamran') and attendance_date = current_date),
  '29. with no school start time set, nothing is late and late_minutes is null. '
  || 'A default start time would have marked a whole staff room late on the day '
  || 'the school upgraded');

update public.school_settings
   set day_starts_at = ((now() at time zone 'Asia/Karachi')::time - interval '95 minutes')::time,
       late_grace_minutes = 10
 where school_id = public.current_school_id();

select pg_temp.be('Mrs Late');
select public.fn_staff_check_in(pg_temp.mint(0)) as late \gset

select pg_temp.ok(
  (:'late'::jsonb->>'attendance_status') = 'late',
  '30. once a start time is set, a late arrival is marked late. The ''late'' '
  || 'status has existed since the first migration and nothing could ever '
  || 'produce it, because there was no start time to be late against');

select pg_temp.ok(
  (:'late'::jsonb->>'late_minutes')::integer between 83 and 87,
  '31. and late_minutes is measured NET of the grace period (95 late, 10 grace), '
  || 'not gross');

-- =============================================================================
-- 9. Every refusal is logged, durably, and brute force stops
-- =============================================================================
select pg_temp.be('CI Owner A');
select pg_temp.ok(
  (select count(*) from public.fn_checkin_attempts(100)) >= 4,
  '32. the refusals from sections 3 and 4 are ON RECORD. Had a refusal raised, '
  || 'this table would be empty for ever and nothing could ever count a brute force');

select pg_temp.ok(
  (select count(*) from public.fn_checkin_attempts(100)
    where reason = 'plain code presented against a rotating code') = 1,
  '33. and each carries the reason it was refused, not just a count');

do $$
declare v_res jsonb; i integer;
begin
  perform pg_temp.be('Mrs Late');
  for i in 1..12 loop
    v_res := public.fn_staff_check_in(pg_temp.plain_code() || '.1.deadbeef');
  end loop;
  if v_res->>'reason' <> 'rate limited' then
    raise exception 'FAIL  34. the eleventh failure in ten minutes must be refused outright, got %', v_res;
  end if;
  raise notice 'PASS  34. more than ten failures in ten minutes stops the account. The token space is comfortable, but comfortable is not a control';
end $$;

select pg_temp.be('Miss Ayesha');
select public.fn_staff_check_in('nonsense') as other \gset

select pg_temp.ok(
  (:'other'::jsonb->>'reason') <> 'rate limited',
  '35. and the lockout is PER ACCOUNT, so one jammed phone does not shut the '
  || 'gate for the whole staff room');

select pg_temp.be('CI Owner A');
select pg_temp.ok(
  pg_temp.affected('delete from public.staff_checkin_attempts') = 0
  and (select count(*) from public.staff_checkin_attempts) > 0,
  '36. the refusal log cannot be emptied from the app — there is no write policy '
  || 'on it at all, so the delete affects zero rows and raises nothing');

-- =============================================================================
-- 10. The register shows what was scanned and what was typed
-- =============================================================================
select pg_temp.ok(
  (select scanned from public.fn_staff_attendance_day(current_date)
    where full_name = 'Mrs Late'),
  '37. a scanned row is shown as scanned');

select public.fn_set_staff_attendance(
  pg_temp.staff('Mr Watchman'), current_date, 'absent', 'Did not come in');

select pg_temp.ok(
  (select not scanned and source = 'manual'
     from public.fn_staff_attendance_day(current_date) where full_name = 'Mr Watchman'),
  '38. and a row the office typed, for somebody who has no login and will never '
  || 'scan anything, is shown as NOT scanned. The direct-insert loophole survived '
  || 'because nothing anywhere displayed code_id');

select pg_temp.ok(
  (select scanned and source = 'manual'
     from public.fn_staff_attendance_day(current_date) where full_name = 'Miss Ayesha'),
  '39. while a scan the office later overrode keeps BOTH facts — she did arrive '
  || 'and a code was presented, and the office then changed the status. Collapsing '
  || 'those into one column would lose the arrival');

select pg_temp.ok(
  (select count(*) from public.fn_staff_attendance_day(current_date))
    = (select count(*) from public.staff where status = 'active'
        and school_id = public.current_school_id()),
  '40. and every active staff member appears, marked or not — a register that '
  || 'lists only the people who turned up cannot tell you who did not');

-- =============================================================================
-- 11. Nothing crosses a school boundary, in both directions
-- =============================================================================
select pg_temp.be('Mr Bilal');
select public.fn_staff_check_in(pg_temp.mint(0)) as cross \gset

select pg_temp.ok(
  (:'cross'::jsonb->>'reason') = 'unknown or inactive code',
  '41. school B''s teacher cannot check in against school A''s LIVE token — codes '
  || 'are unique per school, so an unscoped lookup would have matched it');

select pg_temp.be('CI Owner B');
select pg_temp.ok(
  (select count(*) from public.fn_staff_attendance_day(current_date)) = 1
  and (select full_name from public.fn_staff_attendance_day(current_date)) = 'Mr Bilal',
  '42. and school B''s daily register shows only school B''s staff');

select pg_temp.ok(
  (select count(*) from public.fn_checkin_attempts(200)
    where staff_name in ('Miss Ayesha', 'Mrs Late')) = 0,
  '43. nor school A''s refused attempts');

select pg_temp.be('CI Owner A');
select pg_temp.ok(
  not exists (select 1 from public.fn_staff_attendance_day(current_date)
               where full_name = 'Mr Bilal'),
  '44. and the reverse: school A cannot see school B''s staff either — a filter '
  || 'scoped to whichever school was created first passes one way only');

reset role;
rollback;

-- =============================================================================
-- The gate, the phone and the bill (0149).
--
-- Staff check-in walked end to end as the people who use it: the office makes a
-- code and opens the gate screen, a teacher checks in from a phone with the six
-- digit PIN or the QR, checks out in the afternoon, and reads their own days.
-- Then the office corrects a day, a teacher who has left tries to check in, and
-- the office switches check-in off.
--
-- Then the bill: a school over its plan cannot ask for less room than it has,
-- and a login cannot write a pupil onto the roll past the functions that count.
--
-- Everything after the fixture runs as the AUTHENTICATED role, because RLS and
-- the invoker guards do not apply to a superuser.
--
-- Run: psql -v ON_ERROR_STOP=1 -f supabase/tests/the_gate_the_phone_and_the_bill.sql
-- =============================================================================

\set ON_ERROR_STOP on

begin;

create or replace function auth.uid() returns uuid language sql stable as
  $$ select nullif(current_setting('test.uid', true), '')::uuid $$;
grant usage on schema auth to authenticated;
grant execute on function auth.uid() to authenticated;

create or replace function pg_temp.ok(p_cond boolean, p_label text)
returns void language plpgsql as $$
begin
  if coalesce(p_cond, false) then raise notice 'PASS  %', p_label;
  else raise exception 'FAIL  %', p_label; end if;
end;
$$;

create or replace function pg_temp.be(p_name text) returns void
language sql security definer as $$
  select set_config('test.uid',
    (select id::text from public.profiles where full_name = p_name), false);
$$;

create or replace function pg_temp.raises(p_sql text, p_like text) returns boolean
language plpgsql as $$
begin
  execute p_sql;
  return false;
exception when others then
  if sqlerrm ilike p_like then return true; end if;
  raise notice '   (raised the wrong thing: %)', sqlerrm;
  return false;
end;
$$;

-- Standing outside the application, as an attacker would have to: the PIN
-- function is revoked from logins.
create or replace function pg_temp.pin_for(p_school text, p_offset bigint)
returns text language sql security definer as $$
  select public.fn__checkin_pin(c.secret, floor(extract(epoch from now()) / 30)::bigint + p_offset)
    from public.staff_checkin_codes c
   where c.rotating and c.active
     and c.school_id = (select id from public.schools where name = p_school);
$$;

create or replace function pg_temp.row_for(p_staff text)
returns public.staff_attendance language sql security definer as $$
  select a.* from public.staff_attendance a
    join public.staff s on s.id = a.staff_id
   where s.full_name = p_staff
     and a.attendance_date = (now() at time zone 'Asia/Karachi')::date;
$$;

create or replace function pg_temp.backdate_arrival(p_staff text, p_hours integer)
returns void language sql security definer as $$
  update public.staff_attendance a set checked_at = now() - (p_hours || ' hours')::interval
   where a.attendance_date = (now() at time zone 'Asia/Karachi')::date
     and a.staff_id = (select id from public.staff where full_name = p_staff);
$$;

create or replace function pg_temp.staff(p_name text) returns uuid
language sql security definer as $$ select id from public.staff where full_name = p_name $$;

create or replace function pg_temp.attempts(p_reason text) returns bigint
language sql security definer as $$
  select count(*) from public.staff_checkin_attempts where reason = p_reason
$$;

-- --- Fixture -----------------------------------------------------------------
do $seed$
declare
  v_a uuid; v_b uuid; v_c uuid;
  v_own  uuid := '00000000-0000-0000-0000-0000000fc001';
  v_t1   uuid := '00000000-0000-0000-0000-0000000fc002';
  v_t2   uuid := '00000000-0000-0000-0000-0000000fc003';
  v_t3   uuid := '00000000-0000-0000-0000-0000000fc004';
  v_t4   uuid := '00000000-0000-0000-0000-0000000fc005';
  v_t5   uuid := '00000000-0000-0000-0000-0000000fc006';
  v_ro   uuid := '00000000-0000-0000-0000-0000000fc007';
  v_nol  uuid := '00000000-0000-0000-0000-0000000fc008';
  v_ownb uuid := '00000000-0000-0000-0000-0000000fc009';
  v_tb   uuid := '00000000-0000-0000-0000-0000000fc00a';
  v_ownc uuid := '00000000-0000-0000-0000-0000000fc00b';
  v_s uuid; v_sess uuid; v_old uuid; v_class uuid; v_kid uuid;
begin
  insert into public.schools (name) values ('Gate School A') returning id into v_a;
  insert into public.schools (name) values ('Gate School B') returning id into v_b;
  insert into public.schools (name) values ('Full School C') returning id into v_c;
  insert into public.subscriptions (school_id, plan_code, status, trial_ends_on) values
    (v_a, 'growth', 'active', current_date + 60),
    (v_b, 'growth', 'active', current_date + 60),
    (v_c, 'starter', 'active', current_date + 60);
  -- School C is over its plan: two places, three pupils (the screenshot's
  -- 238 of 150, in miniature).
  update public.subscriptions set student_limit_override = 2,
         student_limit_override_reason = 'Suite: a school over its plan' where school_id = v_c;

  insert into auth.users (id, email) values
    (v_own, 'own@gate.test'), (v_t1, 't1@gate.test'), (v_t2, 't2@gate.test'),
    (v_t3, 't3@gate.test'), (v_t4, 't4@gate.test'), (v_t5, 't5@gate.test'),
    (v_ro, 'ro@gate.test'), (v_nol, 'nol@gate.test'), (v_ownb, 'ownb@gate.test'),
    (v_tb, 'tb@gate.test'), (v_ownc, 'ownc@gate.test')
    on conflict (id) do nothing;

  alter table public.profiles disable trigger user;
  insert into public.profiles (id, school_id, full_name, role, active) values
    (v_own, v_a, 'Gate Owner', 'owner', true),
    (v_t1, v_a, 'Miss Sidra', 'class_teacher', true),
    (v_t2, v_a, 'Mr Hamza', 'subject_teacher', true),
    (v_t3, v_a, 'Mrs Nadia', 'class_teacher', true),
    (v_t4, v_a, 'Mr Usman', 'class_teacher', true),
    (v_t5, v_a, 'Miss Gone', 'class_teacher', true),
    (v_ro, v_a, 'Gate Observer', 'readonly', true),
    (v_nol, v_a, 'Mr Unlinked', 'class_teacher', true),
    (v_ownb, v_b, 'Gate Owner B', 'owner', true),
    (v_tb, v_b, 'Mr Bilal B', 'class_teacher', true),
    (v_ownc, v_c, 'Full Owner C', 'owner', true);
  alter table public.profiles enable trigger user;

  perform set_config('test.uid', v_own::text, false);
  insert into public.staff (school_id, full_name, designation, status)
    values (v_a, 'Miss Sidra', 'Teacher', 'active') returning id into v_s;
  perform public.fn_link_staff_profile(v_s, v_t1);
  insert into public.staff (school_id, full_name, designation, status)
    values (v_a, 'Mr Hamza', 'Teacher', 'active') returning id into v_s;
  perform public.fn_link_staff_profile(v_s, v_t2);
  insert into public.staff (school_id, full_name, designation, status)
    values (v_a, 'Mrs Nadia', 'Teacher', 'active') returning id into v_s;
  perform public.fn_link_staff_profile(v_s, v_t3);
  insert into public.staff (school_id, full_name, designation, status)
    values (v_a, 'Mr Usman', 'Teacher', 'active') returning id into v_s;
  perform public.fn_link_staff_profile(v_s, v_t4);
  insert into public.staff (school_id, full_name, designation, status)
    values (v_a, 'Miss Gone', 'Teacher', 'active') returning id into v_s;
  perform public.fn_link_staff_profile(v_s, v_t5);

  perform set_config('test.uid', v_ownb::text, false);
  insert into public.staff (school_id, full_name, designation, status)
    values (v_b, 'Mr Bilal B', 'Teacher', 'active') returning id into v_s;
  perform public.fn_link_staff_profile(v_s, v_tb);

  -- School C's roll, written as the superuser, standing for a roll that got
  -- over its plan before 0149.
  perform set_config('test.uid', '', false);
  insert into public.academic_sessions (school_id, name, starts_on, ends_on, is_current)
    values (v_c, '2025-2026', date '2025-04-01', date '2026-03-31', false) returning id into v_old;
  insert into public.academic_sessions (school_id, name, starts_on, ends_on, is_current)
    values (v_c, '2026-2027', date '2026-04-01', date '2027-03-31', true) returning id into v_sess;
  insert into public.classes (school_id, name) values (v_c, 'Class 1') returning id into v_class;
  for i in 1..3 loop
    insert into public.students (school_id, gr_no, full_name, status)
      values (v_c, 'C-' || i, 'Full Kid ' || i, 'active') returning id into v_kid;
    insert into public.enrollments (school_id, student_id, session_id, class_id, status)
      values (v_c, v_kid, v_sess, v_class, 'active');
  end loop;
  insert into public.students (school_id, gr_no, full_name, status, left_on)
    values (v_c, 'C-9', 'Full Kid Left', 'withdrawn', current_date - 10) returning id into v_kid;
  insert into public.enrollments (school_id, student_id, session_id, class_id, status)
    values (v_c, v_kid, v_sess, v_class, 'left');
end;
$seed$;

set local role authenticated;

-- =============================================================================
-- 1. The office makes a rotating code, and the gate screen shows a PIN
-- =============================================================================
select pg_temp.be('Gate Owner');
select public.fn_generate_checkin_code('Main gate', null, null, true, true) as rc \gset
select pg_temp.ok((:'rc'::jsonb->>'pin') is null and (:'rc'::jsonb->>'rotating')::boolean,
  '1. a rotating code has no stored PIN: its PIN is worked out for each 30 seconds');

select public.fn_checkin_display() as disp \gset
select pg_temp.ok((:'disp'::jsonb->>'pin') ~ '^[0-9]{6}$',
  '2. the gate screen is given a six digit PIN beside the QR token');
select pg_temp.ok((:'disp'::jsonb->>'pin') = pg_temp.pin_for('Gate School A', 0),
  '3. and it is the PIN for the window showing now');
select pg_temp.ok(not (:'disp'::jsonb ? 'secret'),
  '4. the secret the PIN is made from never leaves the database');

select pg_temp.ok(pg_temp.raises(
  'select public.fn__checkin_pin(''x'', 1)', '%permission denied%'),
  '5. a login cannot work PINs out for itself: fn__checkin_pin is not theirs to call');

select pg_temp.be('Gate Observer');
select pg_temp.ok(pg_temp.raises('select public.fn_checkin_display()', '%Not permitted%'),
  '6. a Read only login is not handed the live PIN');

-- =============================================================================
-- 2. A teacher checks in from their phone with the PIN
-- =============================================================================
select pg_temp.be('Miss Sidra');
select public.fn_my_checkin() as me \gset
select pg_temp.ok((:'me'::jsonb->>'linked')::boolean and (:'me'::jsonb->>'mode') = 'rotating'
                  and (:'me'::jsonb->'record') = 'null'::jsonb,
  '7. before checking in, the phone knows the school uses the rotating code and nothing is recorded');

select public.fn_staff_check_in(pg_temp.pin_for('Gate School A', 0), 33.6, 73.1, 'Phone') as r \gset
select pg_temp.ok((:'r'::jsonb->>'status') = 'ok' and (:'r'::jsonb->>'method') = 'pin',
  '8. the six digit PIN checks the teacher in');
select pg_temp.ok((pg_temp.row_for('Miss Sidra')).method = 'pin'
                  and (pg_temp.row_for('Miss Sidra')).code_id is not null,
  '9. and the day records that it was the PIN, against the code it came from');

select public.fn_my_checkin() as me \gset
select pg_temp.ok((:'me'::jsonb->'record'->>'method') = 'pin'
                  and (:'me'::jsonb->>'can_check_out')::boolean
                  and (:'me'::jsonb->>'out_opens_at') is not null,
  '10. the phone now shows the check-in, and when the check-out opens');

-- =============================================================================
-- 3. The PIN from the window before works, older does not, spaces are fine
-- =============================================================================
select pg_temp.be('Mr Hamza');
select public.fn_staff_check_in(pg_temp.pin_for('Gate School A', -2)) as r \gset
select pg_temp.ok((:'r'::jsonb->>'status') = 'refused' and (:'r'::jsonb->>'reason') = 'wrong PIN',
  '11. a PIN a minute old is refused');
select pg_temp.ok(pg_temp.attempts('wrong PIN') >= 1,
  '12. and the refusal is in the register the office reads');
select pg_temp.ok((pg_temp.row_for('Mr Hamza')).id is null, '13. and no day was written');

select public.fn_staff_check_in(pg_temp.pin_for('Gate School A', -1)) as r \gset
select pg_temp.ok((:'r'::jsonb->>'status') = 'ok',
  '14. the PIN from the window just gone still works, so a PIN read at the last second is not wasted');

select pg_temp.be('Mrs Nadia');
select public.fn_staff_check_in(
  substr(pg_temp.pin_for('Gate School A', 0), 1, 3) || ' ' || substr(pg_temp.pin_for('Gate School A', 0), 4)) as r \gset
select pg_temp.ok((:'r'::jsonb->>'status') = 'ok',
  '15. a PIN typed as "123 456" is read as 123456');

-- =============================================================================
-- 4. The QR still works, and says so
-- =============================================================================
select pg_temp.be('Gate Owner');
select public.fn_checkin_display() as disp \gset
select pg_temp.be('Mr Usman');
select public.fn_staff_check_in(:'disp'::jsonb->>'token') as r \gset
select pg_temp.ok((:'r'::jsonb->>'status') = 'ok' and (:'r'::jsonb->>'method') = 'qr',
  '16. the QR token checks in, recorded as a scan');

select pg_temp.be('Gate Owner');
select pg_temp.ok(
  (select method from public.fn_staff_register_day(null) where full_name = 'Mr Usman') = 'qr'
  and (select method from public.fn_staff_register_day(null) where full_name = 'Miss Sidra') = 'pin',
  '17. the register tells the office which days were scanned and which were typed from the PIN');

-- =============================================================================
-- 5. A double scan is not a check-out, even with no late grace
-- =============================================================================
update public.school_settings set late_grace_minutes = 0
 where school_id = public.current_school_id();
select pg_temp.be('Miss Sidra');
select public.fn_staff_check_in(pg_temp.pin_for('Gate School A', 0)) as r \gset
select pg_temp.ok((:'r'::jsonb->>'status') = 'already' and (:'r'::jsonb->>'out_opens_at') is not null,
  '18. a second PIN a minute after arriving is "already in", not a check-out at 07:46, '
  || 'even with the late grace set to zero');
select pg_temp.ok((pg_temp.row_for('Miss Sidra')).checked_out_at is null,
  '19. and no leaving time was written');

select pg_temp.backdate_arrival('Miss Sidra', 5);
select public.fn_staff_check_in(pg_temp.pin_for('Gate School A', 0)) as r \gset
select pg_temp.ok((:'r'::jsonb->>'status') = 'out' and (:'r'::jsonb->>'worked_minutes')::int >= 299,
  '20. five hours later the PIN checks the teacher out, with the time worked');

-- =============================================================================
-- 6. The office corrects a day
-- =============================================================================
select pg_temp.be('Gate Owner');
select public.fn_set_staff_attendance(pg_temp.staff('Mr Usman'), (now() at time zone 'Asia/Karachi')::date,
  'late'::public.attendance_status, 'Came at nine, gate clock was fast');
select pg_temp.backdate_arrival('Mr Usman', 5);
select pg_temp.be('Mr Usman');
select public.fn_my_checkin() as me \gset
select pg_temp.ok((:'me'::jsonb->>'can_check_out')::boolean,
  '21. a scanned day the office changed to Late still offers the check-out');
select public.fn_staff_check_in(pg_temp.pin_for('Gate School A', 0)) as r \gset
select pg_temp.ok((:'r'::jsonb->>'status') = 'out'
                  and (pg_temp.row_for('Mr Usman')).status = 'late',
  '22. and takes it, keeping the office''s Late. Before 0149 it answered "the office has recorded today"');

select pg_temp.be('Gate Owner');
select public.fn_set_staff_attendance(pg_temp.staff('Mrs Nadia'), (now() at time zone 'Asia/Karachi')::date,
  'absent'::public.attendance_status, 'Went home ill at nine');
select pg_temp.be('Mrs Nadia');
select public.fn_staff_check_in(pg_temp.pin_for('Gate School A', 0)) as r \gset
select pg_temp.ok((:'r'::jsonb->>'status') = 'office_marked',
  '23. an office Absent over a scan still outranks the teacher''s phone');
select public.fn_my_checkin() as me \gset
select pg_temp.ok(not (:'me'::jsonb->>'can_check_out')::boolean,
  '24. and the phone does not offer a check-out it would refuse');

-- =============================================================================
-- 7. Somebody who has left, somebody unlinked, somebody from another school
-- =============================================================================
select pg_temp.be('Gate Owner');
update public.staff set status = 'left', left_on = (now() at time zone 'Asia/Karachi')::date - 1
 where id = pg_temp.staff('Miss Gone');
select pg_temp.be('Miss Gone');
select public.fn_staff_check_in(pg_temp.pin_for('Gate School A', 0)) as r \gset
select pg_temp.ok((:'r'::jsonb->>'reason') = 'staff record marked as left',
  '25. a teacher marked as left cannot check in any more');

select pg_temp.be('Mr Unlinked');
select public.fn_my_checkin() as me \gset
select pg_temp.ok(not (:'me'::jsonb->>'linked')::boolean,
  '26. a login with no staff record is told so, not shown an empty register');

select pg_temp.be('Mr Bilal B');
select public.fn_staff_check_in(pg_temp.pin_for('Gate School A', 0)) as r \gset
select pg_temp.ok((:'r'::jsonb->>'status') = 'refused',
  '27. school A''s PIN means nothing at school B');

-- =============================================================================
-- 8. The teacher's own days
-- =============================================================================
select pg_temp.be('Miss Sidra');
select pg_temp.ok(
  (select count(*) from public.fn_my_staff_attendance(
     (now() at time zone 'Asia/Karachi')::date - 6, (now() at time zone 'Asia/Karachi')::date)) = 1
  and (select method from public.fn_my_staff_attendance(
     (now() at time zone 'Asia/Karachi')::date - 6, (now() at time zone 'Asia/Karachi')::date)) = 'pin',
  '28. a teacher reads their own week, and only their own day in it');
select pg_temp.ok(pg_temp.raises(
  'select * from public.fn_my_staff_attendance(current_date - 500, current_date)', '%at most a year%'),
  '29. a range of more than a year is refused rather than read');
select pg_temp.ok(pg_temp.raises(
  'select * from public.fn_my_staff_attendance(current_date, current_date - 1)', '%on or before%'),
  '30. and a range that ends before it starts');

-- =============================================================================
-- 9. A static poster code has a PIN of its own, and check-in can be switched off
-- =============================================================================
select pg_temp.be('Gate Owner');
select pg_temp.ok(pg_temp.raises(
  'select public.fn_generate_checkin_code(''Old'', null, (now() at time zone ''Asia/Karachi'')::date - 1, true, false)',
  '%already passed%'),
  '31. a code that expired yesterday is not made, and the working code is not switched off for it');
select pg_temp.ok((select count(*) from public.staff_checkin_codes where active) = 1,
  '32. so the rotating code is still the active one');

select public.fn_generate_checkin_code('Poster', null, null, true, false) as sc \gset
select pg_temp.ok((:'sc'::jsonb->>'pin') ~ '^[0-9]{6}$',
  '33. a poster code comes with its own six digit PIN');
select pg_temp.ok((:'sc'::jsonb->>'pin') !~ '^(.)\1{5}$'
                  and (:'sc'::jsonb->>'pin') not in ('123456', '654321', '012345'),
  '34. and not one a person would guess first');

select pg_temp.be('Mr Hamza');
select public.fn_staff_check_in(pg_temp.pin_for('Gate School A', 0)) as r \gset
select pg_temp.ok((:'r'::jsonb->>'status') = 'refused',
  '35. the rotating PIN stopped working the moment the poster replaced it');

select pg_temp.be('Mr Hamza');
select pg_temp.ok(pg_temp.raises('select public.fn_switch_off_checkin()', '%Not permitted%'),
  '36. a teacher cannot switch check-in off');
select pg_temp.be('Gate Owner');
select pg_temp.ok(public.fn_switch_off_checkin() = 1, '37. the office can, and one code closed');
select pg_temp.be('Mr Hamza');
select public.fn_staff_check_in(:'sc'::jsonb->>'pin') as r \gset
select pg_temp.ok((:'r'::jsonb->>'reason') = 'no check-in code today',
  '38. after that every PIN is refused with "check-in is not switched on today"');
select public.fn_my_checkin() as me \gset
select pg_temp.ok((:'me'::jsonb->>'mode') is null,
  '39. and the phone knows there is no check-in, so it can say the office marks you');

-- =============================================================================
-- 10. The bill: a school over its plan
-- =============================================================================
select pg_temp.be('Full Owner C');
select pg_temp.ok(pg_temp.raises(
  'select public.fn_request_student_limit(3, ''We have grown this term'', ''more_room'')',
  '%You have 3 pupils%'),
  '40. a school with 3 pupils on a 2 place plan cannot ask for room for 3: it would stay paused');
select pg_temp.ok(
  (public.fn_request_student_limit(10, 'We have grown this term', 'more_room')->>'status') = 'pending',
  '41. room for 10 is sent');

select pg_temp.ok(pg_temp.raises(format(
  'insert into public.enrollments (school_id, student_id, session_id, class_id, status) '
  'select school_id, id, (select id from public.academic_sessions where is_current and school_id = s.school_id), '
  '(select id from public.classes where school_id = s.school_id limit 1), ''active'' '
  'from public.students s where full_name = %L', 'Full Kid Left'), '%direct write to the roll%'),
  '42. a login cannot enrol a pupil by writing the table directly, past the plan');
select pg_temp.ok(pg_temp.raises(
  'update public.students set status = ''active'', left_on = null where full_name = ''Full Kid Left''',
  '%permission denied%'),
  '43. nor bring a pupil who left back onto the roll directly: the status column is not a login''s to write');
select pg_temp.ok(pg_temp.raises(
  'update public.enrollments set status = ''active'' where student_id = '
  '(select id from public.students where full_name = ''Full Kid Left'')', '%direct write to the roll%'),
  '44. nor by switching their enrolment back to active');
select pg_temp.ok(
  (select count(*) from public.students where full_name = 'Full Kid 1') = 1
  and pg_temp.raises('update public.students set phone = ''0300'' where full_name = ''Full Kid 1'' '
                     'returning 1/0', '%division by zero%'),
  '45. an ordinary edit to a pupil (a phone number) is still a direct write that goes through');
select pg_temp.ok(pg_temp.raises(
  format('select public.fn_set_student_status(%L, ''active''::public.student_status)',
         (select id from public.students where full_name = 'Full Kid Left')),
  '%plan covers%'),
  '46. and the way that is allowed, from the pupil''s profile, still meets the plan');

rollback;

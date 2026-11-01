-- =============================================================================
-- The work goes on without the internet (0157).
--
-- A device that was offline hands in COMMANDS. This file walks every way that
-- can go wrong between the device and the server and holds each one:
--
--   * a command sent twice is applied once, under either the same id or (for a
--     payment) the same printed receipt
--   * a receipt printed offline is final, can never be printed again by the
--     server, and a number that is used or not the device's own is recorded
--     under a fresh one and flagged, never refused
--   * a payment is filed under the day the money was taken
--   * an older offline entry never overwrites a newer one made elsewhere
--   * work is accepted only from inside a lease, and a locked school keeps the
--     work done before it locked while work after waits
--   * a switched-off device is refused and its numbers are closed
--   * anything refused is kept for the owner, with what was sent
--   * an offline admission keeps its pupil id, is never made twice, and a
--     likely duplicate child is stopped for a person to decide
--   * the online screens behave exactly as before
--
-- Run: psql -v ON_ERROR_STOP=1 -f supabase/tests/the_work_goes_on_without_the_internet.sql
-- =============================================================================
\set ON_ERROR_STOP on
begin;

create or replace function auth.uid() returns uuid language sql stable as
  $$ select nullif(current_setting('test.uid', true), '')::uuid $$;

create or replace function pg_temp.ok(p_cond boolean, p_label text)
returns void language plpgsql as $$
begin
  if coalesce(p_cond, false) then raise notice 'PASS  %', p_label;
  else raise exception 'FAIL  %', p_label; end if;
end;
$$;

create or replace function pg_temp.raises(p_sql text, p_label text, p_like text default null)
returns void language plpgsql as $$
begin
  begin
    execute p_sql;
  exception when others then
    if p_like is not null and sqlerrm not like p_like then
      raise exception 'FAIL  % (refused, but with: %)', p_label, sqlerrm;
    end if;
    raise notice 'PASS  % (refused: %)', p_label, left(sqlerrm, 90);
    return;
  end;
  raise exception 'FAIL  % (it was ALLOWED)', p_label;
end;
$$;

create or replace function pg_temp.be(p_name text) returns void language sql as $$
  select set_config('test.uid',
    (select id::text from public.profiles where full_name = p_name), false);
$$;

-- --- Fixture -----------------------------------------------------------------
-- Offline School, paid up for a month: an owner, a principal (who takes fees,
-- the clerk and accountant roles having been retired), a class teacher, a
-- subject teacher and an observer; Class 5 A with two pupils, a
-- maths paper, no fees set (a payment is simply held as credit). Other Offline
-- School, for isolation.
do $seed$
declare
  v_school uuid; v_other uuid;
  v_own uuid := '00000000-0000-0000-0000-0000000e0001';
  v_pr  uuid := '00000000-0000-0000-0000-0000000e0002';
  v_st  uuid := '00000000-0000-0000-0000-0000000e0003';
  v_ct  uuid := '00000000-0000-0000-0000-0000000e0005';
  v_ro  uuid := '00000000-0000-0000-0000-0000000e0006';
  v_oth uuid := '00000000-0000-0000-0000-0000000e0007';
  v_today date := (now() at time zone 'Asia/Karachi')::date;
  v_sess uuid; v_c5 uuid; v_5a uuid; v_sub uuid; v_term uuid; v_kid uuid;
begin
  insert into public.schools (name) values ('Offline School') returning id into v_school;
  insert into public.subscriptions (school_id, plan_code, status, trial_ends_on)
    values (v_school, 'growth', 'active', v_today + 30);
  insert into public.schools (name) values ('Other Offline School') returning id into v_other;
  insert into public.subscriptions (school_id, plan_code, status, trial_ends_on)
    values (v_other, 'growth', 'active', v_today + 30);

  alter table public.profiles disable trigger user;
  insert into auth.users (id, email) values
    (v_own, 'own@offline.test'), (v_pr, 'pr@offline.test'), (v_st, 'st@offline.test'),
    (v_ct, 'ct@offline.test'), (v_ro, 'ro@offline.test'),
    (v_oth, 'own@otheroffline.test')
    on conflict (id) do nothing;
  insert into public.profiles (id, full_name, role, school_id) values
    (v_own, 'Off Owner',      'owner',         v_school),
    (v_pr,  'Off Principal',  'principal',     v_school),
    (v_st,  'Off Subject',    'subject_teacher', v_school),
    (v_ct,  'Off Teacher',    'class_teacher', v_school),
    (v_ro,  'Off Observer',   'readonly',      v_school),
    (v_oth, 'Other Owner',    'owner',         v_other)
    on conflict (id) do update set school_id = excluded.school_id, role = excluded.role,
                                   full_name = excluded.full_name, active = true;
  alter table public.profiles enable trigger user;

  perform set_config('test.uid', v_own::text, false);
  insert into public.academic_sessions (school_id, name, starts_on, ends_on, is_current)
    values (v_school, 'This year', v_today - 60, v_today + 300, true)
    returning id into v_sess;
  update public.school_settings set current_session_id = v_sess where school_id = v_school;
  insert into public.classes (school_id, name, level_order) values (v_school, 'Class 5', 5)
    returning id into v_c5;
  insert into public.sections (school_id, class_id, name) values (v_school, v_c5, 'A')
    returning id into v_5a;
  insert into public.subjects (school_id, name, class_id) values (v_school, 'Maths', v_c5)
    returning id into v_sub;
  insert into public.exam_terms (school_id, session_id, name) values (v_school, v_sess, 'Mid Term')
    returning id into v_term;
  insert into public.exam_subjects (school_id, exam_term_id, class_id, subject_id, max_marks)
    values (v_school, v_term, v_c5, v_sub, 100);

  insert into public.students (school_id, full_name, father_name, status, admission_date)
    values (v_school, 'Ali Raza', 'Raza Khan', 'active', v_today - 60) returning id into v_kid;
  insert into public.enrollments (school_id, student_id, session_id, class_id, section_id, roll_no, status)
    values (v_school, v_kid, v_sess, v_c5, v_5a, '1', 'active');
  insert into public.students (school_id, full_name, father_name, status, admission_date)
    values (v_school, 'Sara Ahmed', 'Ahmed Ali', 'active', v_today - 60) returning id into v_kid;
  insert into public.enrollments (school_id, student_id, session_id, class_id, section_id, roll_no, status)
    values (v_school, v_kid, v_sess, v_c5, v_5a, '2', 'active');

  perform set_config('test.uid', v_oth::text, false);
  insert into public.students (school_id, full_name, status) values (v_other, 'Their Child', 'active');
  raise notice 'fixture ok';
end $seed$;

create or replace function pg_temp.school() returns uuid language sql stable as
  $$ select id from public.schools where name = 'Offline School' $$;
create or replace function pg_temp.kid(p_name text) returns uuid language sql stable as
  $$ select id from public.students where full_name = p_name $$;
create or replace function pg_temp.enr(p_name text) returns uuid language sql stable as
  $$ select e.id from public.enrollments e join public.students s on s.id = e.student_id
      where s.full_name = p_name $$;
create or replace function pg_temp.paper() returns uuid language sql stable as
  $$ select id from public.exam_subjects where school_id = pg_temp.school() $$;
create or replace function pg_temp.uid(p_name text) returns uuid language sql stable as
  $$ select id from public.profiles where full_name = p_name $$;

-- The devices. One phone per person; the owner also has the office computer.
create or replace function pg_temp.dev(p_name text) returns uuid language sql immutable as $$
  select case p_name
    when 'owner phone'  then '0ff1ce00-0000-4000-8000-000000000001'
    when 'owner pc'     then '0ff1ce00-0000-4000-8000-000000000002'
    when 'principal phone' then '0ff1ce00-0000-4000-8000-000000000003'
    when 'subject phone' then '0ff1ce00-0000-4000-8000-000000000004'
    when 'teacher phone' then '0ff1ce00-0000-4000-8000-000000000005'
    when 'other phone'  then '0ff1ce00-0000-4000-8000-000000000006'
  end::uuid $$;

create or replace function pg_temp.cmd(p_type text, p_at timestamptz, p_payload jsonb,
                                       p_id uuid default gen_random_uuid())
returns jsonb language sql as $$
  select jsonb_build_object('id', p_id, 'type', p_type, 'occurred_at', p_at,
                            'payload', p_payload, 'v', 1) $$;

-- Hand one command in, as whoever is signed in, and give back its answer.
create or replace function pg_temp.send(p_device text, p_cmd jsonb) returns jsonb
language sql as $$
  select public.fn_offline_apply(pg_temp.dev(p_device), jsonb_build_array(p_cmd))->'results'->0 $$;

-- A device that said hello some days ago and has been offline since.
create or replace function pg_temp.offline_since(p_device text, p_back interval) returns void
language sql as $$
  update public.sync_leases set from_at = now() - p_back
   where device_id = pg_temp.dev(p_device) $$;


-- =============================================================================
-- 1. Hello: a lease, the clock, and receipt numbers for those who take money
-- =============================================================================
do $t$
declare h jsonb; v_counter bigint;
begin
  perform pg_temp.be('Off Principal');
  h := public.fn_sync_hello(pg_temp.dev('principal phone'), 'android', '1.0.0', null);
  perform pg_temp.ok((h->>'can_write')::boolean and not (h->>'revoked')::boolean
                     and (h->>'server_time')::timestamptz = now(),
    '1a. the principal''s phone may write and is told the server''s clock');
  perform pg_temp.ok((h->>'lease_until')::timestamptz = now() + interval '7 days',
    '1b. the lease is seven days');
  select value into v_counter from public.counters
   where school_id = pg_temp.school() and key = 'receipt';
  perform pg_temp.ok(jsonb_array_length(h->'receipt_blocks') = 1
                     and (h->'receipt_blocks'->0->>'last_no')::bigint = v_counter
                     and (h->'receipt_blocks'->0->>'last_no')::bigint
                         - (h->'receipt_blocks'->0->>'first_no')::bigint = 199,
    '1c. the principal, who takes fees, gets 200 receipt numbers off the school''s own counter');

  h := public.fn_sync_hello(pg_temp.dev('principal phone'), 'android', '1.0.0', null);
  perform pg_temp.ok(jsonb_array_length(h->'receipt_blocks') = 1
                     and (select count(*) from public.receipt_blocks
                           where device_id = pg_temp.dev('principal phone')) = 1
                     and (select count(*) from public.sync_leases
                           where device_id = pg_temp.dev('principal phone')) = 1,
    '1d. saying hello again gives the same block and extends the same lease');

  perform pg_temp.be('Off Teacher');
  h := public.fn_sync_hello(pg_temp.dev('teacher phone'), 'android', '1.0.0', null);
  perform pg_temp.ok((h->>'can_write')::boolean and jsonb_array_length(h->'receipt_blocks') = 0,
    '1e. a teacher may write offline and is given no receipt numbers');

  perform pg_temp.be('Off Observer');
  h := public.fn_sync_hello(gen_random_uuid(), 'web', null, null);
  perform pg_temp.ok(not (h->>'can_write')::boolean and h->>'lease_until' is null,
    '1f. an observer has no lease: it only reads');

  perform pg_temp.be('Off Owner');
  perform public.fn_sync_hello(pg_temp.dev('owner phone'), 'android', '1.0.0', null);
  perform public.fn_sync_hello(pg_temp.dev('owner pc'), 'windows', '1.0.0', null);
  perform pg_temp.be('Off Subject');
  perform public.fn_sync_hello(pg_temp.dev('subject phone'), 'android', '1.0.0', null);
end $t$;


-- =============================================================================
-- 2. A receipt printed offline is final
-- =============================================================================
do $t$
declare
  v_first bigint; v_last bigint; r jsonb; v_id uuid := gen_random_uuid(); j jsonb;
  v_at timestamptz := now() - interval '2 days';
begin
  perform pg_temp.be('Off Principal');
  perform pg_temp.offline_since('principal phone', interval '3 days');
  select first_no, last_no into v_first, v_last from public.receipt_blocks
   where device_id = pg_temp.dev('principal phone');

  r := pg_temp.send('principal phone', pg_temp.cmd('fees.payment', v_at,
         jsonb_build_object('student_id', pg_temp.kid('Ali Raza'), 'amount', 2500,
                            'method', 'cash', 'receipt_no', v_first), v_id));
  perform pg_temp.ok(r->>'status' = 'applied'
                     and (r->'result'->>'receipt_no')::bigint = v_first,
    '2a. a payment taken offline is recorded under the number the device printed');
  perform pg_temp.ok((select created_at from public.payments
                       where school_id = pg_temp.school() and receipt_no = v_first) = v_at,
    '2b. and filed under the day the money was taken, not the day it arrived');

  r := pg_temp.send('principal phone', pg_temp.cmd('fees.payment', v_at,
         jsonb_build_object('student_id', pg_temp.kid('Ali Raza'), 'amount', 2500,
                            'method', 'cash', 'receipt_no', v_first), v_id));
  perform pg_temp.ok(r->>'status' = 'applied' and (r->>'repeat')::boolean
                     and (select count(*) from public.payments
                           where school_id = pg_temp.school() and receipt_no = v_first) = 1,
    '2c. sent again (the answer was lost on a weak signal): the same answer, one payment');

  r := pg_temp.send('principal phone', pg_temp.cmd('fees.payment', v_at,
         jsonb_build_object('student_id', pg_temp.kid('Ali Raza'), 'amount', 2500,
                            'method', 'cash', 'receipt_no', v_first)));
  perform pg_temp.ok(r->>'status' = 'rejected' and r->>'code' = 'duplicate'
                     and (select count(*) from public.payments
                           where school_id = pg_temp.school() and receipt_no = v_first) = 1,
    '2d. the same payment under a new id is recognised by its receipt and kept once');

  j := public.fn_record_payment(pg_temp.kid('Sara Ahmed'), 1000, 'cash', null, false);
  perform pg_temp.ok((j->>'receipt_no')::bigint > v_last,
    '2e. the server''s next receipt is past every number given to a device');

  r := pg_temp.send('principal phone', pg_temp.cmd('fees.payment', v_at,
         jsonb_build_object('student_id', pg_temp.kid('Sara Ahmed'), 'amount', 700,
                            'method', 'cash', 'receipt_no', (j->>'receipt_no')::bigint)));
  perform pg_temp.ok(r->>'status' = 'applied'
                     and r->'flags' ? 'receipt_renumbered'
                     and (r->'result'->>'printed_receipt_no')::bigint = (j->>'receipt_no')::bigint
                     and (r->'result'->>'receipt_no')::bigint <> (j->>'receipt_no')::bigint
                     and (select note from public.payments
                           where id = (r->'result'->>'payment_id')::uuid)
                         like '%printed as receipt%',
    '2f. a number already used is not refused: the money is recorded under a fresh '
    'number, flagged, and the payment says what was printed');

  r := pg_temp.send('principal phone', pg_temp.cmd('fees.payment', v_at,
         jsonb_build_object('student_id', pg_temp.kid('Sara Ahmed'), 'amount', 300,
                            'method', 'cash', 'receipt_no', 999999)));
  perform pg_temp.ok(r->>'status' = 'applied' and r->'flags' ? 'receipt_renumbered',
    '2g. so is a number this device was never given');

  r := pg_temp.send('principal phone', pg_temp.cmd('fees.family_payment', v_at,
         jsonb_build_object('family_id', (select family_id from public.students
                                            where id = pg_temp.kid('Ali Raza')),
                            'amount', 400, 'method', 'cash', 'receipt_no', v_first + 1)));
  perform pg_temp.ok(r->>'status' = 'applied' and (r->'result'->>'receipt_no')::bigint = v_first + 1
                     and r->'result' ? 'family_outstanding',
    '2h. a family payment taken offline works the same way');

  r := pg_temp.send('principal phone', pg_temp.cmd('fees.payment', v_at,
         jsonb_build_object('student_id', pg_temp.kid('Sara Ahmed'), 'amount', 100,
                            'method', 'cash')));
  perform pg_temp.ok(r->>'status' = 'applied' and (r->'result'->>'receipt_no')::bigint > v_last,
    '2i. a payment with no printed number gets the server''s next one');
end $t$;

do $t$
declare h jsonb; v_first bigint;
begin
  perform pg_temp.be('Off Principal');
  select first_no into v_first from public.receipt_blocks
   where device_id = pg_temp.dev('principal phone') order by first_no limit 1;
  h := public.fn_sync_hello(pg_temp.dev('principal phone'), 'android', '1.0.0', v_first + 150);
  perform pg_temp.ok(jsonb_array_length(h->'receipt_blocks') = 2,
    '2j. with fewer than 100 numbers left the device is topped up with a second block');
  h := public.fn_sync_hello(pg_temp.dev('principal phone'), 'android', '1.0.0', v_first + 200);
  perform pg_temp.ok((select closed_reason from public.receipt_blocks
                       where device_id = pg_temp.dev('principal phone') and first_no = v_first) = 'used'
                     and jsonb_array_length(h->'receipt_blocks') = 1,
    '2k. a block the device has finished is closed as used, and it carries on with the next');
end $t$;


-- =============================================================================
-- 3. The newer entry wins by when it was MADE
-- =============================================================================
do $t$
declare r jsonb; v_auth timestamptz;
begin
  perform pg_temp.be('Off Owner');
  perform pg_temp.offline_since('owner phone', interval '1 day');

  -- On the office computer, online, just now: Ali present.
  perform public.fn_mark_attendance(current_date,
    jsonb_build_array(jsonb_build_object('enrollment_id', pg_temp.enr('Ali Raza'), 'status', 'present')));
  -- The phone had marked the class two hours ago with no signal.
  r := pg_temp.send('owner phone', pg_temp.cmd('attendance.day', now() - interval '2 hours',
         jsonb_build_object('date', current_date, 'marks', jsonb_build_array(
           jsonb_build_object('enrollment_id', pg_temp.enr('Ali Raza'), 'status', 'absent'),
           jsonb_build_object('enrollment_id', pg_temp.enr('Sara Ahmed'), 'status', 'absent')))));
  perform pg_temp.ok(r->>'status' = 'applied'
                     and (r->'result'->'kept_newer') @> to_jsonb(array[pg_temp.enr('Ali Raza')])
                     and (select status::text from public.attendance_daily
                           where enrollment_id = pg_temp.enr('Ali Raza')
                             and attendance_date = current_date) = 'present'
                     and (select status::text from public.attendance_daily
                           where enrollment_id = pg_temp.enr('Sara Ahmed')
                             and attendance_date = current_date) = 'absent',
    '3a. an offline register older than a correction made online leaves that pupil alone, '
    'marks the rest, and says which it left');
  perform pg_temp.ok((select authored_at from public.attendance_daily
                       where enrollment_id = pg_temp.enr('Sara Ahmed')
                         and attendance_date = current_date) = now() - interval '2 hours',
    '3b. the entry it made carries the moment it was made');

  r := pg_temp.send('owner phone', pg_temp.cmd('attendance.day', now() - interval '1 hour',
         jsonb_build_object('date', current_date, 'marks', jsonb_build_array(
           jsonb_build_object('enrollment_id', pg_temp.enr('Sara Ahmed'), 'status', 'late')))));
  perform pg_temp.ok((select status::text from public.attendance_daily
                       where enrollment_id = pg_temp.enr('Sara Ahmed')
                         and attendance_date = current_date) = 'late',
    '3c. a later entry from the same phone replaces its earlier one');

  select authored_at into v_auth from public.attendance_daily
   where enrollment_id = pg_temp.enr('Sara Ahmed') and attendance_date = current_date;
  update public.attendance_daily set is_locked = true
   where enrollment_id = pg_temp.enr('Sara Ahmed') and attendance_date = current_date;
  perform pg_temp.ok((select authored_at from public.attendance_daily
                       where enrollment_id = pg_temp.enr('Sara Ahmed')
                         and attendance_date = current_date) = v_auth,
    '3d. finalising a day decides nothing new, so the entry keeps when it was made');
  update public.attendance_daily set is_locked = false
   where enrollment_id = pg_temp.enr('Sara Ahmed') and attendance_date = current_date;

  -- Marks: an online correction, then an older offline sheet.
  perform public.fn_enter_marks(pg_temp.paper(), jsonb_build_array(
    jsonb_build_object('enrollment_id', pg_temp.enr('Ali Raza'), 'marks', 88)));
  r := pg_temp.send('owner phone', pg_temp.cmd('marks.exam', now() - interval '3 hours',
         jsonb_build_object('exam_subject_id', pg_temp.paper(), 'marks', jsonb_build_array(
           jsonb_build_object('enrollment_id', pg_temp.enr('Ali Raza'), 'marks', 40),
           jsonb_build_object('enrollment_id', pg_temp.enr('Sara Ahmed'), 'marks', 75)))));
  perform pg_temp.ok(r->>'status' = 'applied'
                     and (select marks from public.mark_entries
                           where exam_subject_id = pg_temp.paper()
                             and enrollment_id = pg_temp.enr('Ali Raza')) = 88
                     and (select marks from public.mark_entries
                           where exam_subject_id = pg_temp.paper()
                             and enrollment_id = pg_temp.enr('Sara Ahmed')) = 75,
    '3e. the same for marks: a later correction survives an older offline sheet');
end $t$;


-- =============================================================================
-- 4. Leases, clocks and versions
-- =============================================================================
do $t$
declare r jsonb; v_id uuid := gen_random_uuid();
begin
  perform pg_temp.be('Off Teacher');
  r := pg_temp.send('teacher phone', pg_temp.cmd('attendance.day', now() - interval '1 day',
         jsonb_build_object('date', current_date - 1, 'marks', '[]'::jsonb), v_id));
  perform pg_temp.ok(r->>'status' = 'rejected' and r->>'code' = 'outside_lease'
                     and (select status from public.client_commands where id = v_id) = 'rejected',
    '4a. work dated before the device''s lease is refused, and kept');

  -- A lease that ran out three days ago, and a new one from today. The gap
  -- between them is when the device was working past its lease.
  update public.sync_leases set from_at = now() - interval '12 days',
                                until_at = now() - interval '5 days'
   where device_id = pg_temp.dev('teacher phone');
  perform public.fn_sync_hello(pg_temp.dev('teacher phone'), 'android', '1.0.0', null);
  perform pg_temp.ok((select count(*) from public.sync_leases
                       where device_id = pg_temp.dev('teacher phone')) = 2,
    '4b. a device back after its lease ran out starts a new lease, leaving the gap');
  r := pg_temp.send('teacher phone', pg_temp.cmd('attendance.day', now() - interval '3 days',
         jsonb_build_object('date', current_date - 3, 'marks', '[]'::jsonb)));
  perform pg_temp.ok(r->>'code' = 'outside_lease',
    '4c. work dated inside the gap is refused');
  r := pg_temp.send('teacher phone', pg_temp.cmd('attendance.day', now() - interval '8 days',
         jsonb_build_object('date', current_date - 8, 'marks', '[]'::jsonb)));
  perform pg_temp.ok(r->>'status' = 'applied',
    '4d. work from inside the old lease is still accepted, a week later');

  r := pg_temp.send('teacher phone', pg_temp.cmd('attendance.day', now() + interval '1 hour',
         jsonb_build_object('date', current_date, 'marks', '[]'::jsonb)));
  perform pg_temp.ok(r->>'code' = 'clock_ahead', '4e. a time in the future is refused');
  r := pg_temp.send('teacher phone', pg_temp.cmd('attendance.day', now() - interval '130 days',
         jsonb_build_object('date', current_date, 'marks', '[]'::jsonb)));
  perform pg_temp.ok(r->>'code' = 'too_old', '4f. so is anything over 120 days old');

  r := pg_temp.send('teacher phone', jsonb_build_object('id', gen_random_uuid(),
         'type', 'attendance.day', 'occurred_at', now(), 'payload', '{}'::jsonb, 'v', 2));
  perform pg_temp.ok(r->>'status' = 'deferred' and r->>'code' = 'server_behind',
    '4g. a command from a newer app waits on the device rather than being misread');
  r := pg_temp.send('teacher phone', pg_temp.cmd('attendance.week', now(), '{}'::jsonb));
  perform pg_temp.ok(r->>'code' = 'bad_command', '4h. an unknown kind of entry is refused');

  r := public.fn_offline_apply(gen_random_uuid(), jsonb_build_array(
         pg_temp.cmd('attendance.day', now(), '{}'::jsonb)))->'results'->0;
  perform pg_temp.ok(r->>'status' = 'deferred' and r->>'code' = 'device_unknown'
                     and not exists (select 1 from public.client_commands
                                      where id = (r->>'id')::uuid),
    '4i. a device that never said hello is asked to, and nothing is kept');

  r := public.fn_offline_apply(pg_temp.dev('teacher phone'), jsonb_build_array(
         jsonb_build_object('id', gen_random_uuid(), 'type', 'attendance.day',
                            'occurred_at', now(), 'payload', '{}'::jsonb, 'v', 9),
         pg_temp.cmd('attendance.day', now(), jsonb_build_object('date', current_date,
                                                                 'marks', '[]'::jsonb))));
  perform pg_temp.ok(jsonb_array_length(r->'results') = 1,
    '4j. a command that has to wait holds back the ones after it');

  perform pg_temp.raises($$select public.fn_offline_apply('0ff1ce00-0000-4000-8000-000000000005',
      (select jsonb_agg(pg_temp.cmd('attendance.day', now(), '{}'::jsonb))
         from generate_series(1, 26)))$$,
    '4k. more than 25 at a time is refused', '%at most 25%');
end $t$;


-- =============================================================================
-- 5. Refused, kept, and seen by the owner
-- =============================================================================
do $t$
declare r jsonb; v_id uuid := gen_random_uuid(); l jsonb;
begin
  perform pg_temp.be('Off Teacher');
  r := pg_temp.send('teacher phone', pg_temp.cmd('fees.payment', now(),
         jsonb_build_object('student_id', pg_temp.kid('Ali Raza'), 'amount', 500), v_id));
  perform pg_temp.ok(r->>'status' = 'rejected' and r->>'code' = 'refused'
                     and not exists (select 1 from public.payments
                                      where school_id = pg_temp.school() and amount = 500),
    '5a. a teacher cannot take a payment offline either, and nothing of it is left');
  perform pg_temp.ok((select payload->>'amount' from public.client_commands where id = v_id) = '500',
    '5b. what was sent is kept');

  l := public.fn_offline_review(false);
  perform pg_temp.ok(l @> jsonb_build_array(jsonb_build_object('id', v_id))
                     and not l @> jsonb_build_array(jsonb_build_object('name', 'Off Principal')),
    '5c. the teacher sees their own refused work and nobody else''s');
  perform pg_temp.be('Off Owner');
  l := public.fn_offline_review(false);
  perform pg_temp.ok(l @> jsonb_build_array(jsonb_build_object('id', v_id))
                     and l @> jsonb_build_array(jsonb_build_object('flags', jsonb_build_array('receipt_renumbered'))),
    '5d. the owner sees all of it, including payments recorded under a fresh number');
  perform pg_temp.ok((public.fn_offline_dismiss(v_id)->>'dismissed')::boolean
                     and not public.fn_offline_review(false) @> jsonb_build_array(jsonb_build_object('id', v_id))
                     and public.fn_offline_review(true) @> jsonb_build_array(jsonb_build_object('id', v_id)),
    '5e. once dealt with it leaves the list and stays on record');

  perform pg_temp.be('Other Owner');
  perform pg_temp.ok(public.fn_offline_review(true) = '[]'::jsonb
                     and public.fn_school_devices() = '[]'::jsonb,
    '5f. another school sees none of it');
  r := public.fn_offline_apply(pg_temp.dev('other phone'), jsonb_build_array(
         pg_temp.cmd('attendance.day', now(), '{}'::jsonb, v_id)))->'results'->0;
  perform pg_temp.ok(r->>'status' <> 'applied' and r->'result' is null and r->'payload' is null,
    '5g. and cannot read another school''s answer by sending its id');
end $t$;


-- =============================================================================
-- 6. A school that locks while a device is offline
-- =============================================================================
do $t$
declare r jsonb; h jsonb; v_before uuid := gen_random_uuid(); v_after uuid := gen_random_uuid();
begin
  perform pg_temp.be('Off Owner');
  perform pg_temp.offline_since('owner pc', interval '2 days');
  -- Suspended an hour ago.
  update public.subscriptions set suspended_at = now() - interval '1 hour',
                                  suspend_reason = 'Test: suspended an hour ago'
   where school_id = pg_temp.school();

  r := pg_temp.send('owner pc', pg_temp.cmd('expenses.record', now() - interval '5 hours',
         jsonb_build_object('amount', 1200, 'payee', 'Stationers', 'spent_on', current_date), v_before));
  perform pg_temp.ok(r->>'status' = 'applied'
                     and exists (select 1 from public.expenses where amount = 1200
                                  and school_id = pg_temp.school()),
    '6a. work done before the school locked is recorded after it locked');
  perform pg_temp.ok(coalesce(current_setting('app.offline_replay', true), '') = ''
                     and coalesce(current_setting('app.offline_at', true), '') = '',
    '6b. and the door it came through is shut behind it');
  perform pg_temp.raises($$select public.fn_record_expense(50, null, current_date, 'x', 'cash', null)$$,
    '6c. the school itself still cannot write', '%subscription has ended%');

  r := pg_temp.send('owner pc', pg_temp.cmd('expenses.record', now() - interval '10 minutes',
         jsonb_build_object('amount', 75, 'spent_on', current_date), v_after));
  perform pg_temp.ok(r->>'status' = 'deferred' and r->>'code' = 'school_locked'
                     and not exists (select 1 from public.client_commands where id = v_after),
    '6d. work done after the lock waits on the device for the renewal, and is not lost');

  h := public.fn_sync_hello(pg_temp.dev('owner pc'), 'windows', '1.0.0', null);
  perform pg_temp.ok(not (h->>'can_write')::boolean and h->>'lease_until' is null
                     and jsonb_array_length(h->'receipt_blocks') = 0
                     and (select max(until_at) from public.sync_leases
                           where device_id = pg_temp.dev('owner pc')) = now(),
    '6e. a locked school''s device is told so and its lease ends now');

  update public.subscriptions set suspended_at = null, suspend_reason = null
   where school_id = pg_temp.school();
  r := pg_temp.send('owner pc', pg_temp.cmd('expenses.record', now() - interval '10 minutes',
         jsonb_build_object('amount', 75, 'spent_on', current_date), v_after));
  perform pg_temp.ok(r->>'status' = 'applied',
    '6f. once the school is back the waiting work goes in');
end $t$;


-- =============================================================================
-- 7. A lost phone
-- =============================================================================
do $t$
declare r jsonb; h jsonb;
begin
  perform pg_temp.be('Off Principal');
  perform pg_temp.raises($$select public.fn_revoke_device('0ff1ce00-0000-4000-8000-000000000001',
      pg_temp.uid('Off Owner'), 'lost')$$,
    '7a. a principal cannot switch off the owner''s phone', '%Not permitted%');
  perform pg_temp.be('Off Teacher');
  perform pg_temp.raises($$select public.fn_revoke_device('0ff1ce00-0000-4000-8000-000000000003',
      pg_temp.uid('Off Principal'), 'lost')$$,
    '7b. a teacher cannot switch off the principal''s phone', '%Not permitted%');

  perform pg_temp.be('Off Principal');
  perform pg_temp.ok((public.fn_revoke_device(pg_temp.dev('subject phone'),
                        pg_temp.uid('Off Subject'), 'Left the school')->>'revoked')::boolean,
    '7c. the principal switches off a teacher''s phone');

  perform pg_temp.be('Off Owner');
  r := public.fn_revoke_device(pg_temp.dev('principal phone'), pg_temp.uid('Off Principal'), 'Lost on the bus');
  perform pg_temp.ok((r->>'revoked')::boolean
                     and not exists (select 1 from public.receipt_blocks
                                      where device_id = pg_temp.dev('principal phone')
                                        and closed_at is null),
    '7d. the owner switches off the principal''s lost phone and its numbers are closed');

  perform pg_temp.be('Off Principal');
  r := pg_temp.send('principal phone', pg_temp.cmd('fees.payment', now() - interval '1 hour',
         jsonb_build_object('student_id', pg_temp.kid('Ali Raza'), 'amount', 900)));
  perform pg_temp.ok(r->>'status' = 'rejected' and r->>'code' = 'device_revoked',
    '7e. whatever it sends afterwards is refused and kept for the owner');
  h := public.fn_sync_hello(pg_temp.dev('principal phone'), 'android', '1.0.0', null);
  perform pg_temp.ok((h->>'revoked')::boolean and not (h->>'can_write')::boolean
                     and jsonb_array_length(h->'receipt_blocks') = 0,
    '7f. and it is told it has been switched off');

  perform pg_temp.be('Off Teacher');
  perform pg_temp.ok((public.fn_revoke_device(pg_temp.dev('teacher phone'),
                        pg_temp.uid('Off Teacher'), null)->>'revoked')::boolean,
    '7g. anyone can switch off their own device');

  perform pg_temp.be('Off Owner');
  perform pg_temp.ok(jsonb_array_length(public.fn_school_devices()) = 6
                     and public.fn_school_devices() @> jsonb_build_array(jsonb_build_object(
                           'name', 'Off Principal', 'revoke_reason', 'Lost on the bus')),
    '7h. the owner sees every staff device and why one was switched off');
  perform pg_temp.be('Off Subject');
  perform pg_temp.ok(jsonb_array_length(public.fn_school_devices()) = 1,
    '7i. a teacher sees their own');
end $t$;


-- =============================================================================
-- 8. An admission taken offline
-- =============================================================================
do $t$
declare
  r jsonb; v_kid uuid := gen_random_uuid(); v_first bigint; v_at timestamptz := now() - interval '1 day';
  a jsonb;
begin
  perform pg_temp.be('Off Owner');
  perform pg_temp.offline_since('owner phone', interval '2 days');
  select first_no into v_first from public.receipt_blocks
   where device_id = pg_temp.dev('owner phone') and closed_at is null order by first_no limit 1;
  a := jsonb_build_object('full_name', 'Hamza Tariq', 'father_name', 'Tariq Mehmood',
         'b_form', '35202-1234567-1',
         'session_id', (select id from public.academic_sessions where school_id = pg_temp.school()),
         'class_id', (select id from public.classes where school_id = pg_temp.school()),
         'admission_fee', jsonb_build_object('charged', true, 'amount', 1500));

  r := pg_temp.send('owner phone', pg_temp.cmd('students.admit', v_at,
         jsonb_build_object('student_id', v_kid, 'admission', a,
                            'admission_fee_receipt_no', v_first)));
  perform pg_temp.ok(r->>'status' = 'applied'
                     and (r->'result'->>'student_id')::uuid = v_kid
                     and r->'result'->>'gr_no' is not null
                     and (r->'result'->>'admission_receipt_no')::bigint = v_first,
    '8a. an offline admission keeps the pupil id the device made, and its printed receipt');
  perform pg_temp.ok((select admission_date from public.students where id = v_kid)
                       = (v_at at time zone 'Asia/Karachi')::date
                     and (select created_at from public.payments
                           where school_id = pg_temp.school() and receipt_no = v_first) = v_at,
    '8b. dated the day it happened, admission fee included');

  r := pg_temp.send('owner phone', pg_temp.cmd('students.admit', v_at,
         jsonb_build_object('student_id', v_kid, 'admission', a)));
  perform pg_temp.ok(r->>'status' = 'rejected' and r->>'code' = 'duplicate'
                     and (select count(*) from public.students where full_name = 'Hamza Tariq') = 1,
    '8c. the same admission arriving again under another id makes no second child');

  r := pg_temp.send('owner phone', pg_temp.cmd('students.admit', v_at,
         jsonb_build_object('student_id', gen_random_uuid(), 'admission',
           a - 'admission_fee' || jsonb_build_object('b_form', null))));
  perform pg_temp.ok(r->>'status' = 'rejected' and r->>'code' = 'possible_duplicate'
                     and r->>'error' like 'Hamza Tariq (GR %',
    '8d. the same child admitted on another device is stopped and named');
  r := pg_temp.send('owner phone', pg_temp.cmd('students.admit', v_at,
         jsonb_build_object('student_id', gen_random_uuid(), 'allow_duplicate', true,
           'admission', a - 'admission_fee' || jsonb_build_object('b_form', null))));
  perform pg_temp.ok(r->>'status' = 'applied'
                     and (select count(*) from public.students where full_name = 'Hamza Tariq') = 2,
    '8e. and admitted when the person says they are different children');

  update public.subscriptions set student_limit_override = public.fn_count_students(pg_temp.school()),
                                  student_limit_override_until = current_date + 30,
                                  student_limit_override_reason = 'Test: the roll is full'
   where school_id = pg_temp.school();
  r := pg_temp.send('owner phone', pg_temp.cmd('students.admit', v_at,
         jsonb_build_object('student_id', gen_random_uuid(),
           'admission', a - 'admission_fee' || jsonb_build_object('full_name', 'Zara Khan',
                                                                  'father_name', 'Imran Khan',
                                                                  'b_form', null))));
  perform pg_temp.ok(r->>'status' = 'rejected' and r->>'error' like 'Your plan covers%'
                     and not exists (select 1 from public.students where full_name = 'Zara Khan')
                     and exists (select 1 from public.client_commands
                                  where id = (r->>'id')::uuid
                                    and payload->'admission'->>'full_name' = 'Zara Khan'),
    '8f. an admission over the plan''s limit is refused at sync and kept with its details');
  update public.subscriptions set student_limit_override = null, student_limit_override_until = null,
                                  student_limit_override_reason = null
   where school_id = pg_temp.school();
end $t$;


-- =============================================================================
-- 9. The screens work exactly as before
-- =============================================================================
do $t$
declare j jsonb; a jsonb;
begin
  perform pg_temp.be('Off Principal');
  j := public.fn_record_payment(pg_temp.kid('Ali Raza'), 250, 'cash', 'counter', false);
  perform pg_temp.ok(j ?& array['payment_id', 'receipt_no', 'allocated', 'unallocated',
                                'pending', 'applied']
                     and (select created_at from public.payments
                           where id = (j->>'payment_id')::uuid) = now(),
    '9a. fn_record_payment answers as before and dates the payment now');
  j := public.fn_record_payment(pg_temp.kid('Ali Raza'), 250, 'bank_transfer', null, true);
  perform pg_temp.ok(j ?& array['payment_id', 'receipt_no', 'allocated', 'unallocated', 'pending']
                     and (j->>'pending')::boolean,
    '9b. a pending bank transfer as before');
  j := public.fn_record_family_payment((select family_id from public.students
                                         where id = pg_temp.kid('Sara Ahmed')), 300, 'cash', null, false);
  perform pg_temp.ok(j ?& array['payment_id', 'receipt_no', 'allocated', 'credit',
                                'family_outstanding', 'applied', 'pending'],
    '9c. fn_record_family_payment answers as before');
  perform pg_temp.raises($$select public.fn_record_family_payment(gen_random_uuid(), 10, 'cash', null, false)$$,
    '9d. a family that is not ours is refused as before');

  perform pg_temp.be('Off Principal');
  a := public.fn_admit_student(jsonb_build_object('full_name', 'Online Child',
         'session_id', (select id from public.academic_sessions where school_id = pg_temp.school()),
         'class_id', (select id from public.classes where school_id = pg_temp.school()),
         'admission_fee', jsonb_build_object('charged', true, 'amount', 1000)));
  perform pg_temp.ok(a ?& array['student_id', 'enrollment_id', 'gr_no', 'roll_no', 'family_id',
                                'is_draft', 'admission_fee_amount', 'admission_receipt_no']
                     and (select admission_date from public.students
                           where id = (a->>'student_id')::uuid) = current_date,
    '9e. fn_admit_student answers as before and admits today');

  set local role authenticated;
  perform pg_temp.ok(not has_function_privilege('public.fn__offline_apply_one(uuid,uuid,uuid,jsonb)', 'execute')
                     and not has_function_privilege('public.fn__offline_reject(uuid,uuid,uuid,uuid,text,timestamptz,jsonb,text,text)', 'execute')
                     and has_function_privilege('public.fn_offline_apply(uuid,jsonb)', 'execute')
                     and has_function_privilege('public.fn_sync_hello(uuid,text,text,bigint)', 'execute')
                     and not has_table_privilege('public.client_commands', 'select')
                     and not has_table_privilege('public.receipt_blocks', 'insert')
                     and not has_table_privilege('public.sync_leases', 'update'),
    '9f. the inner functions and the four tables are out of a browser''s reach');
  reset role;

  -- A receipt number left set by an offline command must never reach the next
  -- payment taken at the counter.
  perform pg_temp.ok(coalesce(current_setting('app.offline_receipt_no', true), '') = ''
                     and coalesce(current_setting('app.offline_student_id', true), '') = '',
    '9g. nothing an offline command was told is left behind for the screens');
end $t$;


-- =============================================================================
-- 10. Forgetting is safe
-- =============================================================================
do $t$
declare r jsonb; v_id uuid := gen_random_uuid();
begin
  perform pg_temp.be('Off Owner');
  r := pg_temp.send('owner pc', pg_temp.cmd('attendance.day', now() - interval '1 minute',
         jsonb_build_object('date', current_date, 'marks', '[]'::jsonb), v_id));
  update public.client_commands set received_at = now() - interval '200 days' where id = v_id;
  perform public.fn_sync_hello(pg_temp.dev('owner pc'), 'windows', '1.0.0', null);
  perform pg_temp.ok(not exists (select 1 from public.client_commands where id = v_id),
    '10a. an applied command nobody needs is forgotten after 180 days');
  r := pg_temp.send('owner pc', pg_temp.cmd('attendance.day', now() - interval '200 days',
         jsonb_build_object('date', current_date, 'marks', '[]'::jsonb), v_id));
  perform pg_temp.ok(r->>'code' = 'too_old',
    '10b. and one that old sent again is refused for its age, never applied twice');
end $t$;

rollback;
\echo 'THE WORK GOES ON WITHOUT THE INTERNET: ALL TESTS PASSED'

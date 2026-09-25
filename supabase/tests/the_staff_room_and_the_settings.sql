-- =============================================================================
-- The staff room, the reports and the settings (0148).
--
-- The two holes are asserted as the AUTHENTICATED role, because a superuser is
-- exempt from RLS and would pass whatever the guards said: a login may not
-- repoint its own staff record or family, a principal may not make an owner or
-- change their own role, and a parent login never becomes a staff one.
--
-- Then the staff room (nobody who has left teaches, a typed day has no arrival
-- time, the bulk "present" leaves marked days alone), the fee receipts (a
-- family payment names its children, the day is the day in Karachi), the
-- report clock, the years (no duplicate, no overlap, no dates that orphan a
-- register) and the classes (no duplicate name, no switching off a full class).
--
-- Run: psql -v ON_ERROR_STOP=1 -f supabase/tests/the_staff_room_and_the_settings.sql
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
  if p_cond then raise notice 'PASS  %', p_label;
  else raise exception 'FAIL  %', p_label; end if;
end;
$$;

create or replace function pg_temp.be(p_name text) returns void language sql as $$
  select set_config('test.uid',
    (select id::text from public.profiles where full_name = p_name), false);
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
    raise notice 'PASS  % (refused: %)', p_label, left(sqlerrm, 80);
    return;
  end;
  raise exception 'FAIL  % (it was ALLOWED)', p_label;
end;
$$;

create or replace function pg_temp.k_today() returns date language sql stable as
  $$ select (now() at time zone 'Asia/Karachi')::date $$;

-- --- Fixture -----------------------------------------------------------------
do $seed$
declare
  v_a uuid;
  v_own uuid := '00000000-0000-0000-0000-0000000fb001';
  v_pr  uuid := '00000000-0000-0000-0000-0000000fb002';
  v_ct  uuid := '00000000-0000-0000-0000-0000000fb003';
  v_ct2 uuid := '00000000-0000-0000-0000-0000000fb004';
  v_ro  uuid := '00000000-0000-0000-0000-0000000fb005';
  v_par uuid := '00000000-0000-0000-0000-0000000fb006';
  v_sess uuid; v_class uuid; v_sec uuid; v_head uuid; v_empty uuid;
  v_s1 uuid; v_s2 uuid; v_sro uuid; v_gone uuid; v_fam uuid; v_fam2 uuid;
begin
  insert into public.schools (name) values ('Staff Room School') returning id into v_a;
  insert into public.subscriptions (school_id, plan_code, status, trial_ends_on)
    values (v_a, 'growth', 'active', current_date + 30);

  alter table public.profiles disable trigger user;
  insert into auth.users (id, email) values
    (v_own, 'own@staffroom.test'), (v_pr, 'pr@staffroom.test'), (v_ct, 'ct@staffroom.test'),
    (v_ct2, 'ct2@staffroom.test'), (v_ro, 'ro@staffroom.test'), (v_par, 'par@staffroom.test')
    on conflict (id) do nothing;
  insert into public.profiles (id, full_name, role, school_id) values
    (v_own, 'SR Owner',     'owner',         v_a),
    (v_pr,  'SR Principal', 'principal',     v_a),
    (v_ct,  'SR Teacher',   'class_teacher', v_a),
    (v_ct2, 'SR Teacher Two', 'class_teacher', v_a),
    (v_ro,  'SR Observer',  'readonly',      v_a),
    (v_par, 'SR Parent',    'parent',        v_a)
    on conflict (id) do update set school_id = excluded.school_id, role = excluded.role,
                                   full_name = excluded.full_name, active = true;
  alter table public.profiles enable trigger user;

  perform set_config('test.uid', v_own::text, false);
  insert into public.academic_sessions (name, is_current, school_id)
    values ('SR 2026-2027', true, v_a) returning id into v_sess;
  update public.school_settings set current_session_id = v_sess where school_id = v_a;
  insert into public.classes (name, level_order, school_id)
    values ('SR Class 1', 10, v_a) returning id into v_class;
  insert into public.classes (name, level_order, school_id)
    values ('SR Empty Class', 20, v_a) returning id into v_empty;
  insert into public.sections (class_id, name, school_id)
    values (v_class, 'A', v_a) returning id into v_sec;
  insert into public.fee_heads (name, type, is_recurring, sort_order, school_id)
    values ('SR Tuition', 'monthly', true, 10, v_a) returning id into v_head;
  insert into public.subjects (name, class_id, school_id) values ('SR Maths', v_class, v_a);
  insert into public.fee_structures (session_id, class_id, fee_head_id, amount, school_id)
    values (v_sess, v_class, v_head, 1000, v_a);

  insert into public.staff (full_name, school_id, joined_on) values ('SR Teacher', v_a, pg_temp.k_today() - 200) returning id into v_s1;
  insert into public.staff (full_name, school_id) values ('SR Teacher Two', v_a) returning id into v_s2;
  insert into public.staff (full_name, school_id) values ('SR Observer Staff', v_a) returning id into v_sro;
  insert into public.staff (full_name, school_id, status, left_on)
    values ('SR Gone', v_a, 'left', pg_temp.k_today() - 30) returning id into v_gone;
  perform public.fn_link_staff_profile(v_s1, v_ct);
  perform public.fn_link_staff_profile(v_s2, v_ct2);
  perform public.fn_link_staff_profile(v_sro, v_ro);
  perform public.fn_set_class_teacher(v_s1, v_sess, v_class, v_sec);
  perform public.fn_set_class_teacher(v_sro, v_sess, v_class, null);

  perform public.fn_admit_student(jsonb_build_object(
    'full_name', 'SR Aisha', 'father_name', 'SR Father', 'father_cnic', '35201-4848484-8',
    'session_id', v_sess, 'class_id', v_class, 'section_id', v_sec, 'roll_no', '1', 'links', '[]'::jsonb));
  perform public.fn_admit_student(jsonb_build_object(
    'full_name', 'SR Bilal', 'father_name', 'SR Father', 'father_cnic', '35201-4848484-8',
    'session_id', v_sess, 'class_id', v_class, 'section_id', v_sec, 'roll_no', '2', 'links', '[]'::jsonb));
  perform public.fn_generate_class_invoices(v_sess, v_class,
    date_trunc('month', pg_temp.k_today())::date, pg_temp.k_today() + 10);

  insert into public.families (school_id, head_name) values (v_a, 'SR Other Family') returning id into v_fam2;
  select family_id into v_fam from public.students where full_name = 'SR Aisha';
  perform set_config('sr.fam', coalesce(v_fam::text, ''), false);
  perform set_config('sr.fam2', v_fam2::text, false);
  perform set_config('sr.s2', v_s2::text, false);
  perform set_config('sr.sess', v_sess::text, false);
  perform set_config('sr.class', v_class::text, false);
  perform set_config('sr.empty', v_empty::text, false);
  perform set_config('sr.sec', v_sec::text, false);
  perform set_config('sr.gone', v_gone::text, false);
  perform set_config('sr.s1', v_s1::text, false);

  alter table public.profiles disable trigger user;
  update public.profiles set family_id = v_fam where id = v_par;
  alter table public.profiles enable trigger user;
end
$seed$;

-- =============================================================================
-- 1-3: a login cannot repoint itself
-- =============================================================================
do $t$
declare v_before uuid;
begin
  perform pg_temp.be('SR Teacher');
  set local role authenticated;
  perform pg_temp.raises(
    format('update public.profiles set staff_id = %L where id = auth.uid()', current_setting('sr.s2')),
    '1. a class teacher cannot point their login at a colleague''s staff record', '%cannot be repointed%');
  reset role;

  perform pg_temp.be('SR Parent');
  set local role authenticated;
  perform pg_temp.raises(
    format('update public.profiles set family_id = %L where id = auth.uid()', current_setting('sr.fam2')),
    '2. a parent cannot point their login at another family', '%cannot be repointed%');
  -- Their own name is still theirs to change.
  update public.profiles set full_name = 'SR Parent' where id = auth.uid();
  reset role;

  -- The function made for it still works: it runs as its owner.
  perform pg_temp.be('SR Owner');
  select staff_id into v_before from public.profiles where full_name = 'SR Teacher Two';
  perform public.fn_link_staff_profile(current_setting('sr.s2')::uuid, null);
  perform public.fn_link_staff_profile(current_setting('sr.s2')::uuid,
    (select id from public.profiles where full_name = 'SR Teacher Two'));
  perform pg_temp.ok((select staff_id from public.profiles where full_name = 'SR Teacher Two') = v_before,
    '3. the owner can still detach and re-attach a login through fn_link_staff_profile');
end
$t$;

-- =============================================================================
-- 4-8: who grants what
-- =============================================================================
do $t$
begin
  perform pg_temp.be('SR Principal');
  set local role authenticated;
  perform pg_temp.raises('update public.profiles set role = ''owner'' where id = auth.uid()',
    '4. a principal cannot make themselves owner', '%Only an owner%');
  perform pg_temp.raises('update public.profiles set role = ''owner'' where full_name = ''SR Teacher''',
    '5. a principal cannot make anybody else owner', '%Only an owner%');
  perform pg_temp.raises('update public.profiles set role = ''readonly'' where id = auth.uid()',
    '6. nobody but an owner changes their own role', '%your own role%');
  perform pg_temp.raises('update public.profiles set role = ''class_teacher'' where full_name = ''SR Parent''',
    '7. a parent''s login cannot be turned into a teacher''s', '%parent%');
  perform pg_temp.raises('update public.profiles set active = false where full_name = ''SR Owner''',
    '8. a principal cannot close the owner''s login', '%owner%');
  -- An ordinary change still goes through.
  update public.profiles set role = 'subject_teacher' where full_name = 'SR Teacher Two';
  update public.profiles set role = 'class_teacher' where full_name = 'SR Teacher Two';
  reset role;
end
$t$;

do $t$
begin
  perform pg_temp.be('SR Owner');
  set local role authenticated;
  update public.profiles set role = 'owner' where full_name = 'SR Principal';
  reset role;
  perform pg_temp.ok((select role::text from public.profiles where full_name = 'SR Principal') = 'owner',
    '9. an owner can make somebody an owner');
  set local role authenticated;
  update public.profiles set role = 'principal' where full_name = 'SR Principal';
  reset role;
end
$t$;

-- =============================================================================
-- 10-12: a staff login is a staff role
-- =============================================================================
do $t$
begin
  perform pg_temp.be('SR Owner');
  perform pg_temp.raises(
    format('select public.fn_link_staff_profile(%L, %L)', current_setting('sr.s2'),
           (select id from public.profiles where full_name = 'SR Parent')),
    '10. a parent''s login cannot be attached to a staff record', '%parent%');

  perform pg_temp.be('SR Observer');
  perform pg_temp.ok(not public.fn_may_manage_class(current_setting('sr.sess')::uuid,
                                                    current_setting('sr.class')::uuid, null),
    '11. a Read only login attached to a class teacher''s record does not get the class');
  perform pg_temp.be('SR Teacher');
  perform pg_temp.ok(public.fn_may_manage_class(current_setting('sr.sess')::uuid,
                                                current_setting('sr.class')::uuid,
                                                current_setting('sr.sec')::uuid),
    '12. the class teacher still does');
end
$t$;

-- =============================================================================
-- 13-18: the staff room
-- =============================================================================
do $t$
declare v_n integer; v_again integer;
begin
  perform pg_temp.be('SR Owner');
  perform pg_temp.raises(
    format('select public.fn_set_class_teacher(%L, %L, %L, %L)', current_setting('sr.gone'),
           current_setting('sr.sess'), current_setting('sr.class'), current_setting('sr.sec')),
    '13. somebody who has left cannot be made class teacher', '%has left%');
  perform pg_temp.raises(
    format('select public.fn_set_subject_teachers(%L, %L, null, %L, array[%L]::uuid[])',
           current_setting('sr.sess'), current_setting('sr.class'),
           (select id from public.subjects where class_id = current_setting('sr.class')::uuid limit 1),
           current_setting('sr.gone')),
    '14. nor a subject teacher', '%has left%');

  perform public.fn_set_staff_attendance(current_setting('sr.s1')::uuid, pg_temp.k_today() - 2, 'present', null);
  perform pg_temp.ok((select checked_at is null from public.staff_attendance
                       where staff_id = current_setting('sr.s1')::uuid and attendance_date = pg_temp.k_today() - 2),
    '15. a day typed by the office has no arrival time');
  perform pg_temp.raises(
    format('select public.fn_set_staff_attendance(%L, %L, ''present'', null)',
           current_setting('sr.s1'), pg_temp.k_today() - 300),
    '16. nor a day before they joined', '%joined on%');

  perform public.fn_set_staff_attendance(current_setting('sr.s1')::uuid, pg_temp.k_today() - 1, 'absent', 'unwell');
  v_n := public.fn_staff_mark_rest_present(pg_temp.k_today() - 1);
  -- Three on the staff and one of them already marked absent: two to mark.
  perform pg_temp.ok(v_n = 2,
    '17. everyone not yet marked is marked present, the other two (' || v_n || ')');
  perform pg_temp.ok((select status::text from public.staff_attendance
                       where staff_id = current_setting('sr.s1')::uuid and attendance_date = pg_temp.k_today() - 1) = 'absent',
    '18. and the absence already typed is left alone');
  v_again := public.fn_staff_mark_rest_present(pg_temp.k_today() - 1);
  perform pg_temp.ok(v_again = 0, '19. a second press marks nobody');
end
$t$;

-- =============================================================================
-- 20-24: the fee receipts
-- =============================================================================
do $t$
declare r jsonb; v_pid uuid; v_due numeric;
begin
  perform pg_temp.be('SR Owner');
  perform pg_temp.ok(nullif(current_setting('sr.fam'), '') is not null
                     and (select count(*) from public.students
                           where family_id = current_setting('sr.fam')::uuid) = 2,
    '20. the two children share one family');
  select sum(public.student_balance(s.id)) into v_due
    from public.students s where s.family_id = current_setting('sr.fam')::uuid;
  perform public.fn_record_family_payment(current_setting('sr.fam')::uuid, v_due, 'easypaisa', 'both', false);
  select id into v_pid from public.payments
   where family_id = current_setting('sr.fam')::uuid order by created_at desc limit 1;

  -- 20:30 UTC on the 30th is 01:30 on the 1st in Karachi.
  alter table public.payments disable trigger user;
  update public.payments set created_at = '2026-09-30 20:30:00+00' where id = v_pid;
  alter table public.payments enable trigger user;

  r := public.fn_fee_receipts('2026-10-01', '2026-10-01');
  perform pg_temp.ok((r->>'receipts')::int = 1 and (r->>'total')::numeric = v_due,
    '21. a receipt at 01:30 on the 1st in Karachi counts on the 1st');
  perform pg_temp.ok((r->'rows'->0->>'children') = 'SR Aisha, SR Bilal',
    '22. a family payment names both children (' || coalesce(r->'rows'->0->>'children', 'null') || ')');
  perform pg_temp.ok((r->'rows'->0->>'time') = '01:30' and (r->'by_method'->0->>'method') = 'easypaisa',
    '23. with the time in Karachi and the method');
  r := public.fn_fee_receipts('2026-09-30', '2026-09-30');
  perform pg_temp.ok((r->>'receipts')::int = 0, '24. and not on the 30th, which is where UTC put it');

  perform pg_temp.be('SR Teacher');
  perform pg_temp.raises('select public.fn_fee_receipts(''2026-10-01'', ''2026-10-01'')',
    '25. a teacher cannot read the receipts', '%Not permitted%');
  perform pg_temp.raises('select * from public.fn_report_admissions(null, null)',
    '26. nor the admissions register');
end
$t$;

-- =============================================================================
-- 27: the report clock
-- =============================================================================
do $t$
begin
  perform pg_temp.ok((select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                       where n.nspname = 'public'
                         and p.proname in ('fn_report_ledger', 'fn_report_balance_sheet', 'fn_report_unpaid_invoices',
                                           'fn_report_discounts', 'fn_report_admissions', 'fn_mark_corrections',
                                           'fn_attendance_corrections', 'fn_voided_invoices', 'fn__student_ledger')
                         and not ('TimeZone=Asia/Karachi' = any(coalesce(p.proconfig, '{}'::text[])))) = 0,
    '27. every report function counts days in Pakistan');
end
$t$;

do $t$
declare v_names text;
begin
  -- 27b. And nothing ELSE works out a date on the UTC clock. 0148 set every
  -- function it found, and this is what stops a function written later from
  -- quietly going back to UTC: set timezone on it, or it fails here.
  select string_agg(p.proname, ', ' order by p.proname) into v_names
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.prokind = 'f'
     and p.prosrc ~* '(\mcurrent_date\M|::date\M|date_trunc\s*\(|localtimestamp|to_char\s*\(\s*[a-z_.]*_at\M)'
     and not ('TimeZone=Asia/Karachi' = any(coalesce(p.proconfig, '{}'::text[])));
  perform pg_temp.ok(v_names is null,
    '27b. every function that works out a date counts days in Pakistan'
    || coalesce(' (not: ' || v_names || '. Add set timezone to ''Asia/Karachi'')', ''));
end
$t$;

-- =============================================================================
-- 28-32: the years
-- =============================================================================
do $t$
declare v_id uuid; v_sess uuid := current_setting('sr.sess')::uuid;
begin
  perform pg_temp.be('SR Owner');
  perform public.fn_set_session_dates(v_sess, pg_temp.k_today() - 150, pg_temp.k_today() + 200);
  perform pg_temp.ok((select starts_on from public.academic_sessions where id = v_sess) = pg_temp.k_today() - 150,
    '28. a year with no dates gets them on the year itself');
  perform pg_temp.raises(
    format('select public.fn_add_session(%L, %L, %L)', 'sr 2026-2027', pg_temp.k_today() + 300, pg_temp.k_today() + 600),
    '29. a second year of the same name is refused', '%already a year%');
  perform pg_temp.raises(
    format('select public.fn_add_session(%L, %L, %L)', 'SR Overlap', pg_temp.k_today() + 100, pg_temp.k_today() + 400),
    '30. a year that overlaps another is refused', '%overlap%');
  v_id := public.fn_add_session('SR 2027-2028', pg_temp.k_today() + 201, pg_temp.k_today() + 560);
  perform pg_temp.ok(v_id is not null, '31. the next year, after this one ends, is added');
  perform pg_temp.raises(
    format('select public.fn_add_session(%L, %L, %L)', 'SR 2062', '2062-04-01', '2063-03-31'),
    '31b. a year typed as 2062 for 2026 is refused', '%more than a year outside%');

  insert into public.attendance_daily (enrollment_id, attendance_date, status, school_id)
    select e.id, pg_temp.k_today() - 3, 'present', e.school_id
      from public.enrollments e join public.students s on s.id = e.student_id
     where s.full_name = 'SR Aisha';
  perform pg_temp.raises(
    format('select public.fn_set_session_dates(%L, %L, %L)', v_sess, pg_temp.k_today(), pg_temp.k_today() + 200),
    '32. dates that would leave a marked register outside the year are refused', '%attendance mark%');
end
$t$;

-- =============================================================================
-- 33-35: the classes
-- =============================================================================
do $t$
begin
  perform pg_temp.be('SR Owner');
  perform pg_temp.raises('insert into public.classes (name, level_order, school_id) '
                         || format('values (%L, 30, %L)', ' sr class 1 ', (select school_id from public.classes where id = current_setting('sr.class')::uuid)),
    '33. two classes cannot share a name', '%already a class%');
  perform pg_temp.raises(format('update public.classes set active = false where id = %L', current_setting('sr.class')),
    '34. a class with children in it this year cannot be switched off', '%child(ren)%');
  update public.classes set active = false where id = current_setting('sr.empty')::uuid;
  perform pg_temp.ok(not (select active from public.classes where id = current_setting('sr.empty')::uuid),
    '35. an empty one can');
end
$t$;

-- =============================================================================
-- 36: a teacher who leaves teaches nothing
-- =============================================================================
do $t$
declare v_sub uuid;
begin
  perform pg_temp.be('SR Owner');
  select id into v_sub from public.subjects where name = 'SR Maths';
  perform public.fn_set_subject_teachers(current_setting('sr.sess')::uuid, current_setting('sr.class')::uuid,
    null, v_sub, array[current_setting('sr.s2')::uuid]);
  perform pg_temp.ok((select count(*) from public.subject_teachers where staff_id = current_setting('sr.s2')::uuid) = 1,
    '36a. SR Teacher Two teaches Maths');
  perform public.fn_staff_leave(current_setting('sr.s2')::uuid, pg_temp.k_today(), 'Moved to Karachi');
  perform pg_temp.ok((select count(*) from public.subject_teachers where staff_id = current_setting('sr.s2')::uuid) = 0,
    '36. and when they leave, no longer does');
end
$t$;

rollback;

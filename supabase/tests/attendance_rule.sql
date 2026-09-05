-- =============================================================================
-- One attendance percentage: prove every surface reports the same number.
--
-- This product computed the same fact three different ways, and a school could
-- see three different figures for one child on one register:
--
--   the result card, the student profile, the teacher's screen   correct
--   THE PARENT PORTAL   late and half_day both counted as a FULL day
--   THE DASHBOARD       half_day counted whole, and `late` not counted AT ALL
--
-- The two that were wrong were the two most seen: the tile an owner looks at
-- every morning, and the figure a PARENT reads. A father saw one number, the
-- school saw another, and the result card in the child's hand printed a third.
--
-- So this seeds ONE register with every status in it and asserts that every
-- function agrees, against a percentage worked out by hand. A fourth opinion
-- would have to work to get in.
--
-- Run: psql -v ON_ERROR_STOP=1 -f supabase/tests/attendance_rule.sql
-- =============================================================================
\set ON_ERROR_STOP on
begin;

create or replace function auth.uid() returns uuid language sql stable as
  $$ select nullif(current_setting('test.uid', true), '')::uuid $$;

create temp table ids (k text primary key, v uuid);

do $seed$
declare
  s1 uuid := gen_random_uuid();
  own uuid := '00000000-0000-0000-0000-00000000b001';
  par uuid := '00000000-0000-0000-0000-00000000b002';
  ses uuid; cls uuid; sec uuid; fam uuid; stu uuid; enr uuid;
  d date := date '2026-03-02';
begin
  insert into public.schools (id, name, city) values (s1, 'Register School', 'Lahore');
  insert into public.subscriptions (school_id, plan_code, status, trial_ends_on)
    values (s1, 'starter', 'active', current_date + 90);
  insert into auth.users (id, email) values (own, 'owner@register.test'), (par, 'parent@register.test')
    on conflict (id) do nothing;

  insert into public.academic_sessions (school_id, name, starts_on, ends_on, is_current)
    values (s1, '2026-2027', d - 30, d + 300, true) returning id into ses;
  insert into public.classes (school_id, name, level_order) values (s1, 'Class 4', 4) returning id into cls;
  insert into public.sections (school_id, class_id, name) values (s1, cls, 'A') returning id into sec;
  insert into public.families (school_id, head_name) values (s1, 'Register Family') returning id into fam;
  insert into public.students (school_id, gr_no, full_name, family_id, admission_date, status)
    values (s1, 'GR-1', 'One Child', fam, d - 20, 'active') returning id into stu;
  insert into public.enrollments (school_id, student_id, session_id, class_id, section_id, roll_no)
    values (s1, stu, ses, cls, sec, '1') returning id into enr;

  alter table public.profiles disable trigger user;
  insert into public.profiles (id, school_id, full_name, role, family_id) values
    (own, s1, 'The Owner', 'owner', null),
    (par, s1, 'The Parent', 'parent', fam);
  alter table public.profiles enable trigger user;

  -- TWELVE marked days, one of every kind:
  --   8 present, 1 late, 2 half day, 1 absent
  -- The rule: (8 + 1 + 0.5*2) / 12 = 10/12 = 83.3
  insert into public.attendance_daily (school_id, enrollment_id, attendance_date, status, marked_by)
  select s1, enr, d + g, 'present', own from generate_series(0, 7) g;
  insert into public.attendance_daily (school_id, enrollment_id, attendance_date, status, marked_by)
  values (s1, enr, d + 8,  'late',     own),
         (s1, enr, d + 9,  'half_day', own),
         (s1, enr, d + 10, 'half_day', own),
         (s1, enr, d + 11, 'absent',   own);

  insert into ids values ('s1', s1), ('own', own), ('par', par), ('stu', stu), ('enr', enr);
end $seed$;

do $agree$
declare
  expected numeric := 83.3;
  v_rule numeric;
  v_profile numeric;
  v_portal numeric;
  j jsonb;
begin
  -- 1. The rule itself.
  v_rule := public.fn__attendance_pct(8, 1, 2, 12);
  if v_rule is distinct from expected then
    raise exception 'FAIL: fn__attendance_pct(8,1,2,12) = %, expected %', v_rule, expected;
  end if;

  -- 2. The student profile, which an office clerk reads.
  perform set_config('test.uid', (select v::text from ids where k='own'), false);
  j := public.fn_attendance_summary((select v from ids where k='enr'),
                                    date '2026-03-01', date '2026-03-31');
  v_profile := (j->>'present_pct')::numeric;
  if v_profile is distinct from expected then
    raise exception 'FAIL: the student profile says %, the rule says %', v_profile, expected;
  end if;

  -- 3. The parent portal, which is the one a FATHER reads and the one that was
  --    wrong. It used to count late and half_day as whole days: 11/12 = 92.
  perform set_config('test.uid', (select v::text from ids where k='par'), false);
  j := public.fn_portal_child_attendance((select v from ids where k='stu'),
                                         date '2026-03-01', date '2026-03-31');
  v_portal := (j->>'percent')::numeric;
  if v_portal is distinct from expected then
    raise exception 'FAIL: the parent sees %, the school sees %. That is the bug: '
                    'a father comparing the portal with the result card in his '
                    'child''s hand found two different numbers, and the portal''s '
                    'was always the higher.', v_portal, expected;
  end if;

  -- And it must report the RAW counts, not a weighted total dressed as
  -- "present". Reporting 11 as "present" is part of how this went unnoticed.
  if (j->>'present')::int <> 8 then
    raise exception 'FAIL: the portal reports % as present; only 8 days were '
                    'marked present. A weighted count reported as a plain one is '
                    'how the wrong percentage stayed invisible.', j->>'present';
  end if;
  if (j->>'late')::int <> 1 or (j->>'half_day')::int <> 2 or (j->>'absent')::int <> 1 then
    raise exception 'FAIL: the portal does not break the register down correctly: %', j;
  end if;

  raise notice 'ok: the rule, the student profile and the parent portal all say %', expected;
end $agree$;

-- =============================================================================
-- The properties that make the rule the rule, each written so that changing it
-- back makes this fail.
-- =============================================================================
do $props$
begin
  if public.fn__attendance_pct(0, 10, 0, 10) is distinct from 100.0 then
    raise exception 'FAIL: a child who arrived LATE is not being counted as having '
                    'come in. The dashboard used to drop late entirely, so a class '
                    'that all arrived late read as nobody attending.';
  end if;
  if public.fn__attendance_pct(0, 0, 10, 10) is distinct from 50.0 then
    raise exception 'FAIL: a half day is not being counted as HALF a day. Counting '
                    'it whole always flatters the figure, and a percentage a school '
                    'quotes to a parent must not be the flattering one by accident.';
  end if;
  if public.fn__attendance_pct(0, 0, 0, 0) is not null then
    raise exception 'FAIL: an unmarked register reports a number. Zero reads as '
                    '"nobody came in", which is a different and far more alarming '
                    'claim than "the register has not been taken".';
  end if;
  raise notice 'ok: late counts, a half day is half, and an empty register has no percentage';
end $props$;

-- =============================================================================
-- One rule, one implementation, and a check that stays true
--
-- 0097 created the shared rule and pointed the two BROKEN callers at it. It left
-- the three correct copies alone, which is how this bug happened in the first
-- place: every one of the four copies was correct on the day it was written.
-- 0100 removed the last three.
--
-- This is deliberately a catalogue query rather than a comparison of two
-- numbers. Comparing outputs proves the copies agree TODAY; that was true of
-- all four of them the week before a parent read 92% and the card printed
-- 83.3%. What has to hold is that there is only one copy to be wrong.
-- =============================================================================
do $one$
declare v_bad text; v_users text;
begin
  select string_agg(p.proname, ', ' order by p.proname) into v_bad
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public'
    and p.proname <> 'fn__attendance_pct'
    and p.prosrc like '%0.5 * count(*) filter (where status = ''half_day'')%';
  if v_bad is not null then
    raise exception 'FAIL: the attendance formula is written out inside %. It '
                    'belongs only in fn__attendance_pct. Four copies of a rule '
                    'is not four checks on it, it is four chances to diverge, '
                    'and this one has already diverged twice.', v_bad;
  end if;

  -- And the shared rule has to be REACHED, not merely present. A caller that
  -- stopped using it would pass the check above by having no formula at all.
  select string_agg(p.proname, ', ' order by p.proname) into v_users
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.prosrc like '%fn__attendance_pct%'
    and p.proname <> 'fn__attendance_pct';
  foreach v_bad in array array['fn_attendance_summary', 'fn_staff_attendance_summary',
                               'fn_generate_result_cards', 'fn_portal_child_attendance'] loop
    if coalesce(v_users, '') not like '%' || v_bad || '%' then
      raise exception 'FAIL: % no longer calls the shared attendance rule. It '
                      'now reports a percentage from somewhere this suite '
                      'cannot see. Callers found: %', v_bad, coalesce(v_users, 'none');
    end if;
  end loop;

  raise notice 'ok: the rule exists once and all four surfaces call it';
end $one$;

-- =============================================================================
-- A teacher's percentage and a pupil's are computed the same way
--
-- Different table, same rule. A school that docks pay on attendance will put
-- the two side by side, and there is no argument for a late teacher and a late
-- pupil counting differently.
-- =============================================================================
do $staff$
declare
  v_school uuid; v_staff uuid; v_owner uuid := '00000000-0000-0000-0000-0000000000a9';
  j jsonb; v_expected numeric;
begin
  select school_id into v_school from public.profiles
   where id = nullif(current_setting('test.uid', true), '')::uuid;

  insert into auth.users (id, email) values (v_owner, 'a9@att.test') on conflict (id) do nothing;
  insert into public.staff (school_id, full_name, designation, status)
    values (v_school, 'Attendance Test Teacher', 'Teacher', 'active')
    returning id into v_staff;

  -- The same twelve day register the pupil above has: 8 present, 1 late,
  -- 2 half days, 1 absent.
  insert into public.staff_attendance (school_id, staff_id, attendance_date, status)
  select v_school, v_staff, (date '2026-03-02' + n)::date,
         (case when n < 8 then 'present' when n = 8 then 'late'
               when n < 11 then 'half_day' else 'absent' end)::public.attendance_status
  from generate_series(0, 11) as n;

  j := public.fn_staff_attendance_summary(v_staff, date '2026-03-01', date '2026-03-31');
  v_expected := public.fn__attendance_pct(8, 1, 2, 12);

  if (j->>'present_pct')::numeric is distinct from v_expected then
    raise exception 'FAIL: the staff record says %, the rule says %',
      j->>'present_pct', v_expected;
  end if;
  if (j->>'present')::int <> 8 or (j->>'late')::int <> 1
     or (j->>'half_day')::int <> 2 or (j->>'absent')::int <> 1 then
    raise exception 'FAIL: the staff summary does not break the register down correctly: %', j;
  end if;

  raise notice 'ok: a teacher and a pupil are measured the same way (%)', v_expected;
end $staff$;

-- =============================================================================
-- The leave the school approved (0105)
--
-- Leave counts against the percentage in the same way as absence. That is the
-- decision, not an oversight: the figure has to answer "how much of the year
-- was this child here" to carry the 75% rule that decides who may sit the board
-- exams, and a number that quietly forgave granted leave would put a child with
-- two months off at 100%.
--
-- What was wrong is that neither surface a PARENT looks at ever said so. The
-- office profile has printed `P 160 · A 5 · L 15` for a long time; the portal
-- showed a percentage and a present count, and the card showed a percentage
-- alone. So a school granted the leave and then sent home a card that reads as
-- though the child did not turn up, and the only person available to argue with
-- was the clerk at the counter.
--
-- A SECOND PUPIL, deliberately, so the 83.3 fixture above is untouched. Its
-- register is the one every assertion in this file so far is written against.
-- =============================================================================
do $leave$
declare
  v_s1 uuid := (select v from ids where k='s1');
  v_own uuid := (select v from ids where k='own');
  v_fam uuid;
  v_ses uuid; v_cls uuid; v_sec uuid; v_stu uuid; v_enr uuid;
  d date := date '2026-04-06';
  j jsonb;
  v_counted numeric; v_forgiven numeric;
begin
  select family_id into v_fam from public.profiles where id = (select v from ids where k='par');
  select id into v_ses from public.academic_sessions where school_id = v_s1 and is_current;
  select id into v_cls from public.classes  where school_id = v_s1 limit 1;
  select id into v_sec from public.sections where school_id = v_s1 limit 1;

  insert into public.students (school_id, gr_no, full_name, family_id, admission_date, status)
    values (v_s1, 'GR-2', 'Leave Child', v_fam, d - 40, 'active') returning id into v_stu;
  insert into public.enrollments (school_id, student_id, session_id, class_id, section_id, roll_no)
    values (v_s1, v_stu, v_ses, v_cls, v_sec, '2') returning id into v_enr;

  -- TWENTY marked days: 12 present, 5 leave, 3 absent.
  --   counting leave against:  12 / 20 = 60.0
  --   forgiving leave:         12 / 15 = 80.0
  insert into public.attendance_daily (school_id, enrollment_id, attendance_date, status, marked_by)
  select v_s1, v_enr, d + g, 'present', v_own from generate_series(0, 11) g;
  insert into public.attendance_daily (school_id, enrollment_id, attendance_date, status, marked_by)
  select v_s1, v_enr, d + 12 + g, 'leave', v_own from generate_series(0, 4) g;
  insert into public.attendance_daily (school_id, enrollment_id, attendance_date, status, marked_by)
  select v_s1, v_enr, d + 17 + g, 'absent', v_own from generate_series(0, 2) g;

  v_counted  := public.fn__attendance_pct(12, 0, 0, 20);   -- 60.0
  v_forgiven := public.fn__attendance_pct(12, 0, 0, 15);   -- 80.0
  if v_counted is distinct from 60.0 or v_forgiven is distinct from 80.0 then
    raise exception 'FAIL: the fixture is wrong before anything is measured: '
                    'counted % and forgiven %, expected 60.0 and 80.0',
                    v_counted, v_forgiven;
  end if;

  -- 1. The shared counts function: every status, the marked total, and the
  --    percentage taken from the shared rule rather than computed again.
  j := public.fn__attendance_counts(v_enr, v_s1, d - 5, d + 30);
  if (j->>'leave')::int <> 5 or (j->>'present')::int <> 12
     or (j->>'absent')::int <> 3 or (j->>'marked_days')::int <> 20 then
    raise exception 'FAIL: fn__attendance_counts breaks the register down wrongly: %', j;
  end if;
  if (j->>'present_pct')::numeric is distinct from v_counted then
    raise exception 'FAIL: fn__attendance_counts says %, the shared rule says %',
      j->>'present_pct', v_counted;
  end if;

  -- 2. THE DECISION, pinned. Leave is in the denominator. Without this
  --    assertion a later change that quietly forgave approved leave would pass
  --    every other test in this file, and the number would stop being able to
  --    carry the 75% board-exam rule without anybody noticing.
  if (j->>'present_pct')::numeric = v_forgiven then
    raise exception 'FAIL: approved leave is no longer counted against the '
                    'percentage (% of 15 days rather than of 20). That number '
                    'cannot carry the 75%% rule that decides who may sit the '
                    'board exams: a child granted two months off would read '
                    '100%%. If this is a deliberate change, argue with this '
                    'assertion rather than deleting it.', j->>'present';
  end if;

  -- 3. The parent's own screen now reports the leave, and still reports the
  --    percentage that counts it.
  perform set_config('test.uid', (select v::text from ids where k='par'), false);
  j := public.fn_portal_child_attendance(v_stu, d - 5, d + 30);
  if (j->>'leave')::int <> 5 then
    raise exception 'FAIL: the portal reports % days of leave, not 5. A parent '
                    'shown a lower percentage with no way to see the days the '
                    'school itself approved has a complaint nobody at the '
                    'counter can settle.', coalesce(j->>'leave', 'nothing');
  end if;
  if (j->>'percent')::numeric is distinct from v_counted then
    raise exception 'FAIL: the portal says %, the rule says %', j->>'percent', v_counted;
  end if;

  -- 4. And the office profile, which had the breakdown all along, still agrees
  --    with the parent's screen. Two surfaces disagreeing about this exact
  --    number is what 0097 and 0100 were about.
  perform set_config('test.uid', (select v::text from ids where k='own'), false);
  j := public.fn_attendance_summary(v_enr, d - 5, d + 30);
  if (j->>'leave')::int <> 5
     or (j->>'present_pct')::numeric is distinct from v_counted then
    raise exception 'FAIL: the office profile and the parent portal disagree: %', j;
  end if;

  raise notice 'ok: leave is counted against the percentage (%) and reported on '
    'every surface that shows it', v_counted;
end $leave$;

-- The counts function edits nobody's data and reads one school's register, but
-- it takes the school id as an ARGUMENT, so it must not be reachable from a
-- browser session: a caller who could choose the school id would choose
-- somebody else's.
do $reach$
begin
  if has_function_privilege('anon', 'public.fn__attendance_counts(uuid,uuid,date,date)', 'execute')
     or has_function_privilege('authenticated', 'public.fn__attendance_counts(uuid,uuid,date,date)', 'execute')
  then
    raise exception 'FAIL: fn__attendance_counts is reachable from the browser, '
                    'and it takes the school id as an argument';
  end if;
  raise notice 'ok: the counts function is not reachable from a browser session';
end $reach$;

rollback;
\echo 'ATTENDANCE RULE: ALL TESTS PASSED'

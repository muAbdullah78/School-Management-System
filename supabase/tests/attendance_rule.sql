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

rollback;
\echo 'ATTENDANCE RULE: ALL TESTS PASSED'

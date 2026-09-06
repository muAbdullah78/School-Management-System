-- =============================================================================
-- The history feed says who, and three of them were not us
--
-- WHY THIS FILE EXISTS
--
-- 0108 went through every action name in this schema to give the operator's
-- History feed a readable sentence for each one. It found them with
--
--     grep -o "fn__log_operator_action('[a-z_]*'"
--
-- and that character class has no dot in it, so the three call sites in 0094
-- matched nothing and were never seen:
--
--     student.deleted     staff.deleted     login.deleted
--
-- Every other action in this schema is entity_verb with an underscore. These
-- three are entity.verb with a dot, so the app's fallback - replace(/_/g, ' ')
-- - left them exactly as stored and the console printed the literal string
-- "login.deleted" at the operator. A regex that excluded precisely the rows
-- that were misnamed.
--
-- The naming was hiding the bigger half. fn_delete_student, fn_delete_staff and
-- fn_delete_login are granted to `authenticated`: they are called by the
-- SCHOOL'S OWN OFFICE, from the school's own screens, and they write into
-- operator_actions - the table whose reader is titled, on screen, "What we have
-- done to this school". A principal deleting a duplicate pupil appeared in the
-- vendor's audit feed as something the vendor had done, with no actor beside
-- it. Read back a year later in a dispute about who removed a child's records,
-- that is not a cosmetic problem.
--
-- Run: psql -v ON_ERROR_STOP=1 -f supabase/tests/who_actually_did_it.sql
-- =============================================================================

\set ON_ERROR_STOP on
begin;

create or replace function auth.uid() returns uuid language sql stable as
  $$ select nullif(current_setting('test.uid', true), '')::uuid $$;

create temp table ids (k text primary key, v uuid);

do $seed$
declare
  sch uuid := gen_random_uuid();
  admin_u uuid := '00000000-0000-0000-0000-0000000000f1';
  clerk_u uuid := '00000000-0000-0000-0000-0000000000f2';
begin
  insert into public.schools (id, name, city) values (sch, 'Al Qalam School', 'Lahore');
  insert into public.subscriptions (school_id, plan_code, status, period_start, period_end)
    values (sch, 'starter', 'active', current_date - 30, current_date + 300);

  insert into auth.users (id, email) values
    (admin_u, 'operator@vendor.test'), (clerk_u, 'office@alqalam.test')
    on conflict (id) do nothing;
  insert into public.platform_admins (user_id, email)
    values (admin_u, 'operator@vendor.test') on conflict do nothing;

  -- The school's own office. Deliberately NOT a platform admin.
  alter table public.profiles disable trigger user;
  insert into public.profiles (id, school_id, full_name, role, active)
    values (clerk_u, sch, 'Office Clerk', 'owner', true);
  alter table public.profiles enable trigger user;

  insert into ids values ('sch', sch), ('admin', admin_u), ('clerk', clerk_u);
end $seed$;

-- 1. THE READER SAYS WHO. Two rows written by two different people, and the
--    feed has to separate them - from the membership table, not from
--    actor_email being null, because null there means EITHER a school clerk OR
--    a cron action and those are different sentences.
do $t$
declare r record; v_us int := 0; v_them int := 0;
begin
  perform set_config('test.uid', (select i.v::text from ids i where i.k='admin'), false);
  perform public.fn__log_operator_action('school_entered',
    (select i.v from ids i where i.k='sch'),
    jsonb_build_object('reason', 'They cannot find the fee report'));

  perform set_config('test.uid', (select i.v::text from ids i where i.k='clerk'), false);
  perform public.fn__log_operator_action('student_deleted',
    (select i.v from ids i where i.k='sch'),
    jsonb_build_object('name', 'Ahmed Raza (duplicate)'));

  perform set_config('test.uid', (select i.v::text from ids i where i.k='admin'), false);
  -- Only the two rows this block wrote. Creating the school fires 0073's own
  -- capture trigger, which logs school_created with no actor at all - a real
  -- third row, and counting it would have made this assertion pass or fail for
  -- a reason that has nothing to do with what is being tested.
  for r in select * from public.fn_platform_school_activity(
      (select i.v from ids i where i.k='sch'), 100)
     where action in ('school_entered', 'student_deleted')
  loop
    if r.by_operator then v_us := v_us + 1; else v_them := v_them + 1; end if;
  end loop;

  if v_us <> 1 then
    raise exception 'FAIL: % rows attributed to us, expected 1', v_us;
  end if;
  if v_them <> 1 then
    raise exception 'FAIL: % rows attributed to the school, expected 1. The feed '
      'cannot tell what WE did from what the SCHOOL did, and its heading claims '
      'everything on it is ours.', v_them;
  end if;
  raise notice '1. the feed separates our actions from the school''s - ok';
end $t$;

-- 2. AND IT IS THE RIGHT WAY ROUND. Counting one of each would pass if the
--    flag were inverted, so the actual rows are checked.
do $t$
declare v_by_us boolean;
begin
  perform set_config('test.uid', (select i.v::text from ids i where i.k='admin'), false);
  select a.by_operator into v_by_us from public.fn_platform_school_activity(
    (select i.v from ids i where i.k='sch'), 100) a
   where a.action = 'school_entered';
  if v_by_us is not true then
    raise exception 'FAIL: entering a school was not attributed to us';
  end if;
  select a.by_operator into v_by_us from public.fn_platform_school_activity(
    (select i.v from ids i where i.k='sch'), 100) a
   where a.action = 'student_deleted';
  if v_by_us is not false then
    raise exception 'FAIL: the school deleting its own pupil was attributed to us';
  end if;
  raise notice '2. and the right way round - ok';
end $t$;

-- 3. THE THREE DELETION FUNCTIONS NO LONGER LOG A DOTTED NAME. Asserted on the
--    stored source rather than by calling them: fn_delete_student needs a pupil
--    with no fee history, no attendance and no marks, and building one proves
--    nothing about the string this test is actually about.
do $t$
declare r record; v_bad text[] := '{}';
begin
  for r in
    select p.proname, p.prosrc
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and p.proname in ('fn_delete_student', 'fn_delete_staff', 'fn_delete_login')
  loop
    if r.prosrc like '%''student.deleted''%'
       or r.prosrc like '%''staff.deleted''%'
       or r.prosrc like '%''login.deleted''%' then
      v_bad := v_bad || r.proname::text;
    end if;
  end loop;
  if array_length(v_bad, 1) > 0 then
    raise exception 'FAIL: % still log an action name with a dot in it. Every other '
      'action in this schema is entity_verb, so the app''s fallback leaves these '
      'exactly as stored and the console prints "login.deleted" at the operator.',
      array_to_string(v_bad, ', ');
  end if;
  -- And the new names are actually there, so a function that lost the call
  -- entirely does not pass by being empty.
  if not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                  where n.nspname = 'public' and p.proname = 'fn_delete_login'
                    and p.prosrc like '%login_deleted%') then
    raise exception 'FAIL: fn_delete_login no longer logs anything at all';
  end if;
  raise notice '3. the three deletion actions use the schema''s own naming - ok';
end $t$;

-- 4. NOBODY ELSE CAN READ THE FEED. A new function starts with EXECUTE granted
--    to PUBLIC, and 0001 gives anon usage on this schema, so a new reader has to
--    close its own surface.
do $t$
declare v_msg text;
begin
  perform set_config('test.uid', (select i.v::text from ids i where i.k='clerk'), false);
  begin
    perform public.fn_platform_school_activity((select i.v from ids i where i.k='sch'), 10);
    raise exception 'FAIL: a school''s own clerk can read the operator''s audit feed';
  exception when others then
    get stacked diagnostics v_msg = message_text;
    if v_msg like 'FAIL:%' then raise exception '%', v_msg; end if;
    if v_msg <> 'Not permitted' then
      raise exception 'FAIL: refused for the wrong reason: %', v_msg;
    end if;
  end;
  if has_function_privilege('anon', 'public.fn_platform_school_activity(uuid, integer)', 'execute') then
    raise exception 'FAIL: anon can execute the audit feed reader';
  end if;
  raise notice '4. the new feed is platform-admin only - ok';
end $t$;

-- 5. THE OLD READER IS UNTOUCHED, which is the whole reason there are two.
--    Adding an OUT column means DROP and CREATE, and 0073 lives in bundle 7,
--    which is frozen and already pasted into a live school. Changing that
--    signature made re-pasting bundle 7 fail with "cannot change return type"
--    and roll the bundle back - and bundle 7 re-applying was the only thing
--    putting fn_may_mark_subject back after bundle 6's loop had rewritten it.
do $t$
declare v_cols text;
begin
  if to_regprocedure('public.fn_platform_school_actions(uuid, integer)') is null then
    raise exception 'FAIL: the original reader was dropped. Bundle 7 will fail to '
      're-paste, and a school is told to paste again whenever it is unsure.';
  end if;
  select string_agg(p.parameter_name, ',' order by p.ordinal_position) into v_cols
    from information_schema.parameters p
   where p.specific_schema = 'public' and p.parameter_mode = 'OUT'
     and p.specific_name in (
       select r.specific_name from information_schema.routines r
        where r.routine_schema = 'public' and r.routine_name = 'fn_platform_school_actions');
  if v_cols <> 'at,actor_email,action,detail' then
    raise exception 'FAIL: the original reader''s return type changed to (%). '
      'Bundle 7 carries the old one and will refuse to re-apply.', v_cols;
  end if;
  raise notice '5. the original reader keeps its signature, so bundle 7 re-pastes - ok';
end $t$;

-- 6. A READ-ONLY USER CANNOT ENTER MARKS.
--
--    0059 rewrites every STABLE SECURITY DEFINER function containing has_role(
--    into may_view(, which is has_role(...) OR has_role('readonly'). Its loop can
--    only see what exists when it runs, so fn_may_mark_subject - created later,
--    by 0085 - is invisible on a first install and correctly keeps has_role. On a
--    RE-PASTE the loop does see it, and the gate that decides who may enter marks
--    starts admitting the read-only role. Nothing caught it because the source
--    files are right: the damage exists only in the stored body of a database
--    that has been pasted twice.
do $t$
declare v_bad text[];
begin
  select coalesce(array_agg(p.proname order by p.proname), '{}') into v_bad
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and p.proname in ('fn_may_mark_subject', 'fn_may_manage_class',
                       'fn_may_write_school_file')
     and p.prosrc like '%may_view(%';
  if array_length(v_bad, 1) > 0 then
    raise exception 'FAIL: % is a WRITE gate built on may_view, so a read-only '
      'observer passes it. may_view is has_role(...) or has_role(''readonly'').',
      array_to_string(v_bad, ', ');
  end if;
  raise notice '6. the write gates still refuse a read-only observer - ok';
end $t$;

rollback;
\echo 'WHO ACTUALLY DID IT: ALL TESTS PASSED'

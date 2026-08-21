-- =============================================================================
-- Parent access: granting it, revoking it, and who may look.
--
-- WHY THIS FILE EXISTS
--
-- portal.sql has fourteen assertions and all of them passed while the parent
-- portal was completely unreachable, because the fixture sets
-- profiles.family_id by hand:
--
--     insert into public.profiles (id, ..., family_id) values (..., v_fam);
--
-- Nothing in the shipped product did that. fn_link_parent was the only writer
-- of that column and had zero callers, so in production my_family_id() was
-- always null and every portal read refused. The tests proved the portal works
-- GIVEN a linked parent; nothing proved a parent could ever become linked.
--
-- Same lesson as family_linkage.sql: a fixture that constructs the state under
-- test is testing itself. This file goes through fn_link_parent.
--
-- Run: psql -v ON_ERROR_STOP=1 -f supabase/tests/parent_access.sql
-- =============================================================================

\set ON_ERROR_STOP on

-- One transaction, rolled back. Schools cannot be deleted in this schema (34
-- non-cascading foreign keys), so a self-cleaning fixture is impossible and
-- committing would leave rows for other suites to trip over.
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

-- --- Fixture -----------------------------------------------------------------
-- Two schools. Each has an owner, a clerk, one family with two children, and an
-- unlinked parent login. Nothing is pre-linked — that is the whole point.
do $seed$
declare
  v_school uuid; v_other uuid;
  v_owner uuid := '00000000-0000-0000-0000-00000000e001';
  v_clerk uuid := '00000000-0000-0000-0000-00000000e002';
  v_par   uuid := '00000000-0000-0000-0000-00000000e003';
  v_par2  uuid := '00000000-0000-0000-0000-00000000e004';
  v_oown  uuid := '00000000-0000-0000-0000-00000000e005';
  v_opar  uuid := '00000000-0000-0000-0000-00000000e006';
  v_sess uuid; v_class uuid;
begin
  insert into public.schools (name) values ('Parent Access School') returning id into v_school;
  insert into public.subscriptions (school_id, plan_code, status, trial_ends_on)
    values (v_school, 'starter', 'active', current_date + 30);
  insert into public.schools (name) values ('Parent Access Other') returning id into v_other;
  insert into public.subscriptions (school_id, plan_code, status, trial_ends_on)
    values (v_other, 'starter', 'active', current_date + 30);

  alter table public.profiles disable trigger user;
  insert into auth.users (id, email) values
    (v_owner, 'e1@pa.test'), (v_clerk, 'e2@pa.test'), (v_par, 'father@pa.test'),
    (v_par2, 'mother@pa.test'), (v_oown, 'e5@pa.test'), (v_opar, 'foreign@pa.test')
    on conflict (id) do nothing;
  -- family_id left NULL on both parents on purpose.
  insert into public.profiles (id, full_name, role, school_id) values
    (v_owner, 'PA Owner',   'owner',       v_school),
    (v_clerk, 'PA Clerk',   'admin_clerk', v_school),
    (v_par,   'PA Father',  'parent',      v_school),
    (v_par2,  'PA Mother',  'parent',      v_school),
    (v_oown,  'Other Owner','owner',       v_other),
    (v_opar,  'Other Dad',  'parent',      v_other)
    on conflict (id) do update set school_id = excluded.school_id,
                                   role      = excluded.role,
                                   full_name = excluded.full_name,
                                   active    = true;
  alter table public.profiles enable trigger user;

  perform set_config('test.uid', v_owner::text, false);
  insert into public.academic_sessions (name, is_current, school_id)
    values ('2025-2026', true, v_school) returning id into v_sess;
  insert into public.classes (name, level_order, school_id)
    values ('Class 1', 1, v_school) returning id into v_class;

  -- Two brothers on one CNIC, so migration 0036 puts them in one family and
  -- linking the father covers both children in a single action.
  perform public.fn_admit_student(jsonb_build_object(
    'full_name', 'PA Elder', 'father_name', 'PA Father', 'father_cnic', '35201-7777777-7',
    'session_id', v_sess, 'class_id', v_class, 'links', '[]'::jsonb));
  perform public.fn_admit_student(jsonb_build_object(
    'full_name', 'PA Younger', 'father_name', 'PA Father', 'father_cnic', '35201-7777777-7',
    'session_id', v_sess, 'class_id', v_class, 'links', '[]'::jsonb));

  perform set_config('test.uid', v_oown::text, false);
  insert into public.academic_sessions (name, is_current, school_id)
    values ('2025-2026', true, v_other) returning id into v_sess;
  insert into public.classes (name, level_order, school_id)
    values ('Class 1', 1, v_other) returning id into v_class;
  perform public.fn_admit_student(jsonb_build_object(
    'full_name', 'Foreign Kid', 'father_name', 'Other Dad', 'father_cnic', '35201-8888888-8',
    'session_id', v_sess, 'class_id', v_class, 'links', '[]'::jsonb));
end $seed$;

-- =============================================================================
-- 1-3: an unlinked parent is locked out, and the error does not leak
-- =============================================================================
do $t$
declare v_kid uuid;
begin
  perform set_config('test.uid', '00000000-0000-0000-0000-00000000e003', false);

  perform pg_temp.ok(public.my_family_id() is null,
    '1. a freshly created parent login has no family (the pre-0037 state)');

  perform pg_temp.ok(
    jsonb_array_length(public.fn_portal_me()->'children') = 0,
    '2. and therefore sees no children at all');

  select id into v_kid from public.students where full_name = 'PA Elder';
  begin
    perform public.fn_portal_child_fees(v_kid);
    raise exception 'FAIL  3. an unlinked parent could read a child''s fees';
  exception
    when others then
      if sqlerrm like 'FAIL%' then raise; end if;
      raise notice 'PASS  3. an unlinked parent is refused (%)', sqlerrm;
  end;
end $t$;

-- =============================================================================
-- 4-7: linking works, and covers every child in the family at once
-- =============================================================================
do $t$
declare v_fam uuid; v_n int;
begin
  perform set_config('test.uid', '00000000-0000-0000-0000-00000000e001', false);
  select family_id into v_fam from public.students where full_name = 'PA Elder';

  perform public.fn_link_parent('00000000-0000-0000-0000-00000000e003', v_fam);

  perform set_config('test.uid', '00000000-0000-0000-0000-00000000e003', false);
  perform pg_temp.ok(public.my_family_id() = v_fam, '4. the parent is now attached to the family');

  v_n := jsonb_array_length(public.fn_portal_me()->'children');
  perform pg_temp.ok(v_n = 2,
    '5. one link covers BOTH brothers, not just one (' || v_n || ')');

  -- The reads that used to throw must now work.
  perform public.fn_portal_child_fees((select id from public.students where full_name = 'PA Elder'));
  perform public.fn_portal_child_attendance(
    (select id from public.students where full_name = 'PA Younger'), current_date - 30, current_date);
  raise notice 'PASS  6. child fees and attendance are readable once linked';

  -- And the isolation portal.sql covers must still hold from this direction.
  begin
    perform public.fn_portal_child_fees((select id from public.students where full_name = 'Foreign Kid'));
    raise exception 'FAIL  7. a linked parent read another school''s child';
  exception
    when others then
      if sqlerrm like 'FAIL%' then raise; end if;
      raise notice 'PASS  7. a linked parent still cannot reach another family (%)', sqlerrm;
  end;
end $t$;

-- =============================================================================
-- 8-10: fn_family_parents — the listing, and who may call it
-- =============================================================================
do $t$
declare v_fam uuid; v_n int; v_email text;
begin
  perform set_config('test.uid', '00000000-0000-0000-0000-00000000e001', false);
  select family_id into v_fam from public.students where full_name = 'PA Elder';

  select count(*) into v_n from public.fn_family_parents(v_fam);
  perform pg_temp.ok(v_n = 1, '8. staff see exactly the one linked parent (' || v_n || ')');

  select email into v_email from public.fn_family_parents(v_fam) limit 1;
  perform pg_temp.ok(v_email = 'father@pa.test',
    '9. the email is returned, so a school can tell two parents apart');

  -- A parent must not be able to enumerate logins, not even on their own family.
  perform set_config('test.uid', '00000000-0000-0000-0000-00000000e003', false);
  begin
    perform count(*) from public.fn_family_parents(v_fam);
    raise exception 'FAIL  10. a parent listed the logins on their own family';
  exception
    when others then
      if sqlerrm like 'FAIL%' then raise; end if;
      raise notice 'PASS  10. a parent cannot list logins (%)', sqlerrm;
  end;
end $t$;

-- =============================================================================
-- 11-12: the cross-tenant guards. auth.users is readable inside these
-- functions, so these are the assertions that actually matter.
-- =============================================================================
do $t$
declare v_foreign_fam uuid;
begin
  select family_id into v_foreign_fam from public.students where full_name = 'Foreign Kid';

  perform set_config('test.uid', '00000000-0000-0000-0000-00000000e001', false);
  begin
    perform count(*) from public.fn_family_parents(v_foreign_fam);
    raise exception 'FAIL  11. an owner read ANOTHER school''s parent emails out of auth.users';
  exception
    when others then
      if sqlerrm like 'FAIL%' then raise; end if;
      raise notice 'PASS  11. fn_family_parents refuses a foreign family (%)', sqlerrm;
  end;

  begin
    perform public.fn_link_parent('00000000-0000-0000-0000-00000000e006', v_foreign_fam);
    raise exception 'FAIL  12. an owner linked another school''s parent';
  exception
    when others then
      if sqlerrm like 'FAIL%' then raise; end if;
      raise notice 'PASS  12. fn_link_parent refuses a foreign profile (%)', sqlerrm;
  end;
end $t$;

-- =============================================================================
-- 13-15: revoking access
-- =============================================================================
do $t$
declare v_fam uuid; v_active boolean;
begin
  perform set_config('test.uid', '00000000-0000-0000-0000-00000000e001', false);
  select family_id into v_fam from public.students where full_name = 'PA Elder';

  perform public.fn_unlink_parent('00000000-0000-0000-0000-00000000e003');

  select active into v_active from public.profiles
   where id = '00000000-0000-0000-0000-00000000e003';
  perform pg_temp.ok(v_active = false, '13. revoking deactivates the login');

  perform set_config('test.uid', '00000000-0000-0000-0000-00000000e003', false);
  perform pg_temp.ok(public.my_family_id() is null,
    '14. and detaches the family, so the data is cut off immediately');

  begin
    perform public.fn_portal_child_fees((select id from public.students where full_name = 'PA Elder'));
    raise exception 'FAIL  15. a revoked parent could still read fees';
  exception
    when others then
      if sqlerrm like 'FAIL%' then raise; end if;
      raise notice 'PASS  15. a revoked parent is refused (%)', sqlerrm;
  end;
end $t$;

-- =============================================================================
-- 16-17: who may grant and revoke
-- =============================================================================
do $t$
declare v_fam uuid;
begin
  select family_id into v_fam from public.students where full_name = 'PA Elder';

  -- A clerk runs the fee counter and must not be able to hand out data access.
  perform set_config('test.uid', '00000000-0000-0000-0000-00000000e002', false);
  begin
    perform public.fn_link_parent('00000000-0000-0000-0000-00000000e004', v_fam);
    raise exception 'FAIL  16. a clerk granted portal access';
  exception
    when others then
      if sqlerrm like 'FAIL%' then raise; end if;
      raise notice 'PASS  16. a clerk cannot grant portal access (%)', sqlerrm;
  end;

  -- But a clerk SHOULD be able to see who already has it, or the fee counter
  -- cannot answer "does this father have the app?".
  perform pg_temp.ok((select count(*) from public.fn_family_parents(v_fam)) >= 0,
    '17. a clerk can still see who has access');
end $t$;

-- =============================================================================
-- 18-19: a parent cannot promote or re-link themselves
-- =============================================================================
do $t$
declare v_foreign_fam uuid;
begin
  select family_id into v_foreign_fam from public.students where full_name = 'Foreign Kid';
  perform set_config('test.uid', '00000000-0000-0000-0000-00000000e004', false);

  begin
    perform public.fn_link_parent('00000000-0000-0000-0000-00000000e004', v_foreign_fam);
    raise exception 'FAIL  18. a parent attached themselves to a family';
  exception
    when others then
      if sqlerrm like 'FAIL%' then raise; end if;
      raise notice 'PASS  18. a parent cannot attach themselves (%)', sqlerrm;
  end;

  begin
    perform public.fn_unlink_parent('00000000-0000-0000-0000-00000000e003');
    raise exception 'FAIL  19. a parent revoked another parent';
  exception
    when others then
      if sqlerrm like 'FAIL%' then raise; end if;
      raise notice 'PASS  19. a parent cannot revoke anyone (%)', sqlerrm;
  end;
end $t$;

-- =============================================================================
-- 20-21: only parent accounts can be linked, and the internals are not exposed
-- =============================================================================
do $t$
declare v_fam uuid; v_bad int;
begin
  perform set_config('test.uid', '00000000-0000-0000-0000-00000000e001', false);
  select family_id into v_fam from public.students where full_name = 'PA Elder';

  -- Linking a STAFF login to a family would give it my_family_id() while
  -- keeping its staff powers — a role muddle worth refusing outright.
  begin
    perform public.fn_link_parent('00000000-0000-0000-0000-00000000e002', v_fam);
    raise exception 'FAIL  20. a clerk login was linked to a family as if it were a parent';
  exception
    when others then
      if sqlerrm like 'FAIL%' then raise; end if;
      raise notice 'PASS  20. only parent accounts can be linked (%)', sqlerrm;
  end;

  select count(*) into v_bad
  from information_schema.routine_privileges
  where routine_schema = 'public'
    and routine_name in ('fn_family_parents', 'fn_unlink_parent', 'fn_link_parent')
    and grantee = 'anon';
  perform pg_temp.ok(v_bad = 0, '21. none of the parent-access functions are reachable by anon');
end $t$;

-- =============================================================================
-- 22-28: profiles.active is enforced (migration 0037 section 3)
--
-- Before 0037 the "Deactivate" button in Settings -> Users & Roles wrote a
-- column that nothing read. A dismissed clerk kept the fee counter. These are
-- the assertions that stop that regressing, and they are deliberately written
-- against the three chokepoints rather than against one screen.
-- =============================================================================
do $t$
declare v_n int;
begin
  -- Deactivate the clerk as the owner.
  perform set_config('test.uid', '00000000-0000-0000-0000-00000000e001', false);
  update public.profiles set active = false
   where id = '00000000-0000-0000-0000-00000000e002';

  perform set_config('test.uid', '00000000-0000-0000-0000-00000000e002', false);

  perform pg_temp.ok(public.current_school_id() is null,
    '22. a deactivated login resolves to no school');
  perform pg_temp.ok(public.has_role('admin_clerk') = false,
    '23. and fails its role check');
  perform pg_temp.ok(public.is_staff() = false,
    '24. and is no longer staff');

  -- The consequence that actually matters: every RLS policy in the schema is
  -- `school_id = current_school_id()`, so a null closes all of them at once.
  -- Checked through assert_own, which is what the SECURITY DEFINER functions use.
  begin
    perform public.assert_own('students',
      (select id from public.students where full_name = 'PA Elder'));
    raise exception 'FAIL  25. a deactivated clerk still passed assert_own on a student';
  exception
    when others then
      if sqlerrm like 'FAIL%' then raise; end if;
      raise notice 'PASS  25. a deactivated clerk cannot reach student rows (%)', sqlerrm;
  end;

  -- Reactivating restores it, or the button is a one-way door.
  perform set_config('test.uid', '00000000-0000-0000-0000-00000000e001', false);
  update public.profiles set active = true
   where id = '00000000-0000-0000-0000-00000000e002';
  perform set_config('test.uid', '00000000-0000-0000-0000-00000000e002', false);
  perform pg_temp.ok(public.has_role('admin_clerk'),
    '26. reactivating restores access');
end $t$;

do $t$
declare v_second_owner uuid := '00000000-0000-0000-0000-00000000e007';
begin
  perform set_config('test.uid', '00000000-0000-0000-0000-00000000e001', false);

  -- 27. The lockout guard. With active enforced, deactivating the only owner
  --     would leave nobody able to reactivate anybody.
  begin
    update public.profiles set active = false
     where id = '00000000-0000-0000-0000-00000000e001';
    raise exception 'FAIL  27. the school deactivated its only owner and locked itself out';
  exception
    when others then
      if sqlerrm like 'FAIL%' then raise; end if;
      raise notice 'PASS  27. deactivating the last owner is refused (%)', sqlerrm;
  end;

  -- 28. Demoting the last owner has the identical effect and is refused too.
  begin
    update public.profiles set role = 'principal'
     where id = '00000000-0000-0000-0000-00000000e001';
    raise exception 'FAIL  28. the school demoted its only owner';
  exception
    when others then
      if sqlerrm like 'FAIL%' then raise; end if;
      raise notice 'PASS  28. demoting the last owner is refused (%)', sqlerrm;
  end;

  -- 29. But with a second owner in place it must be allowed, or an owner can
  --     never hand the school over.
  alter table public.profiles disable trigger user;
  insert into auth.users (id, email) values (v_second_owner, 'e7@pa.test')
    on conflict (id) do nothing;
  insert into public.profiles (id, full_name, role, school_id)
    values (v_second_owner, 'PA Owner Two', 'owner',
            (select school_id from public.profiles where id = '00000000-0000-0000-0000-00000000e001'))
    on conflict (id) do update set role = 'owner', active = true;
  alter table public.profiles enable trigger user;

  update public.profiles set active = false
   where id = '00000000-0000-0000-0000-00000000e001';
  perform pg_temp.ok(
    (select not active from public.profiles where id = '00000000-0000-0000-0000-00000000e001'),
    '29. an owner CAN be deactivated once a second owner exists');
end $t$;

do $$ begin raise notice '--- parent_access.sql: all assertions passed'; end $$;

rollback;

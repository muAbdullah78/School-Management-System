-- =============================================================================
-- Two roles the school never needed: prove the removal cannot strand anybody.
--
-- 0133 retires Admin / Clerk and Accountant. Nothing about that is dangerous
-- EXCEPT what happens to the people who already hold them, and to the
-- invitations already sent that promise them. This file is about those two.
--
-- WHY IT RE-RUNS THE MIGRATION INSTEAD OF RESTATING IT
--
-- The suites run against a database where every migration has already applied,
-- so by the time this file starts, there are no clerks left to migrate: the
-- interesting moment has passed. A test that inserted a clerk and then ran its
-- own copy of the UPDATE would prove that the copy works.
--
-- So this puts the database back into the state a live school is in the
-- morning before it pastes the bundle -- constraint dropped, guard disabled, a
-- clerk and an accountant on the roll, an invitation in the post -- and then
-- runs the REAL migration file with \i. What is asserted afterwards is what
-- 0133 actually does, not a restatement of it.
--
-- That also makes the file an idempotency check, since it applies 0133 to a
-- database that already has it.
--
-- Run: psql -v ON_ERROR_STOP=1 -f supabase/tests/roles_pruned.sql
-- =============================================================================
\set ON_ERROR_STOP on
begin;

create or replace function auth.uid() returns uuid language sql stable as
  $$ select nullif(current_setting('test.uid', true), '')::uuid $$;

create temp table ids (k text primary key, v uuid);

-- --------------------------------------------------------- the school as it was
do $seed$
declare
  s1    uuid := gen_random_uuid();
  own   uuid := '00000000-0000-0000-0000-0000000000c1';
  clerk uuid := '00000000-0000-0000-0000-0000000000c2';
  acct  uuid := '00000000-0000-0000-0000-0000000000c3';
  head  uuid := '00000000-0000-0000-0000-0000000000c4';
begin
  insert into public.schools (id, name, city) values (s1, 'Roles School', 'Multan');
  insert into public.subscriptions (school_id, plan_code, status, trial_ends_on)
    values (s1, 'starter', 'active', current_date + 90);
  insert into auth.users (id, email) values
    (own,   'owner@roles.test'),
    (clerk, 'clerk@roles.test'),
    (acct,  'accounts@roles.test'),
    (head,  'head@roles.test')
  on conflict (id) do nothing;

  -- Back to before 0133: the constraint gone and the guard off, which is
  -- exactly the shape of the table on the morning of the upgrade.
  alter table public.profiles drop constraint profiles_role_live_chk;
  alter table public.user_invites drop constraint user_invites_role_live_chk;
  alter table public.profiles disable trigger user;

  insert into public.profiles (id, school_id, full_name, role) values
    (own,   s1, 'The Owner',      'owner'),
    (clerk, s1, 'The Fee Clerk',  'admin_clerk'),
    (acct,  s1, 'The Accountant', 'accountant'),
    (head,  s1, 'The Head',       'principal');

  -- An invitation sent yesterday, not yet redeemed. This is the case that
  -- would otherwise hand out a retired role TOMORROW.
  insert into public.user_invites (school_id, email, role, full_name, created_by)
    values (s1, 'newclerk@roles.test', 'admin_clerk', 'A New Clerk', own);
  -- And one already accepted, which must be left alone: it is a record of what
  -- happened, not an instruction about the future.
  insert into public.user_invites (school_id, email, role, full_name, created_by, accepted_at)
    values (s1, 'oldclerk@roles.test', 'accountant', 'An Old Clerk', own, now() - interval '30 days');

  alter table public.profiles enable trigger user;
  insert into ids values ('s1', s1), ('own', own), ('clerk', clerk), ('acct', acct), ('head', head);
end $seed$;

-- ------------------------------------------------------------ the migration --
\i supabase/migrations/0133_two_roles_the_school_never_needed.sql

-- ------------------------------------------------------------- what it did --
do $moved$
declare
  v_role public.user_role;
  v_left int;
begin
  -- 1. THE FEE CLERK IS A PRINCIPAL, NOT AN OBSERVER. This is the assertion
  --    that matters most, because readonly is the tidier answer and the one
  --    that would silently stop a live school taking money at the window.
  select role into v_role from public.profiles where id = (select v from ids where k='clerk');
  if v_role <> 'principal' then
    raise exception 'FAIL: the fee clerk became %, not principal. Fifty-two '
                    'functions let only owner, principal and the two retired '
                    'roles take money, so anything else means the person at '
                    'the fee counter cannot take a payment the morning this '
                    'bundle is pasted.', v_role;
  end if;

  select role into v_role from public.profiles where id = (select v from ids where k='acct');
  if v_role <> 'principal' then
    raise exception 'FAIL: the accountant became %, not principal', v_role;
  end if;

  -- 2. Nobody else was touched.
  select role into v_role from public.profiles where id = (select v from ids where k='own');
  if v_role <> 'owner' then
    raise exception 'FAIL: the owner became %. The owner holds the '
                    'subscription and must not be rewritten by a role cleanup.', v_role;
  end if;
  select role into v_role from public.profiles where id = (select v from ids where k='head');
  if v_role <> 'principal' then
    raise exception 'FAIL: the existing principal became %', v_role;
  end if;

  -- 3. Not one left anywhere.
  select count(*) into v_left from public.profiles
   where role in ('admin_clerk', 'accountant');
  if v_left <> 0 then
    raise exception 'FAIL: % profile(s) still hold a retired role', v_left;
  end if;
  raise notice 'ok: the office accounts are principals and nobody else moved';
end $moved$;

do $invites$
declare
  v_role public.user_role;
begin
  -- THE PENDING INVITATION IS REWRITTEN. Refusing it at redemption instead
  -- would strand somebody who has been told to expect a login and has no way
  -- to know why the link no longer works.
  select role into v_role from public.user_invites
   where email = 'newclerk@roles.test';
  if v_role <> 'principal' then
    raise exception 'FAIL: a pending invitation still promises %, so a retired '
                    'role would be handed out the day after the upgrade', v_role;
  end if;

  -- AN ACCEPTED ONE IS HISTORY AND IS LEFT ALONE. The profile it created has
  -- already been migrated; rewriting the record of what was offered would be
  -- editing the past for no benefit.
  select role into v_role from public.user_invites
   where email = 'oldclerk@roles.test';
  if v_role <> 'accountant' then
    raise exception 'FAIL: an ACCEPTED invitation was rewritten to %. That row '
                    'is a record of what happened.', v_role;
  end if;
  raise notice 'ok: the pending invitation was rewritten, the accepted one was not';
end $invites$;

-- ------------------------------------------------------------ the four doors --
do $doors$
declare
  v_msg text;
begin
  perform set_config('test.uid', (select v::text from ids where k='own'), false);

  -- DOOR 1: a direct UPDATE, which is what the Users screen does.
  begin
    update public.profiles set role = 'admin_clerk'
     where id = (select v from ids where k='head');
    raise exception 'FAIL: a profile was moved back to admin_clerk';
  exception when others then
    get stacked diagnostics v_msg = message_text;
    if v_msg like 'FAIL:%' then raise; end if;
    -- The message must be a sentence a school can act on, not a constraint
    -- name. That is the whole reason the guard says it as well as the
    -- constraint refusing it.
    if position('withdrawn' in v_msg) = 0 then
      raise exception 'FAIL: the refusal reads "%", which tells a school '
                      'nothing about what to do instead', v_msg;
    end if;
  end;

  -- DOOR 2: an INSERT, which 0001's trigger did not cover because it fired on
  -- UPDATE only.
  begin
    insert into auth.users (id, email)
      values ('00000000-0000-0000-0000-0000000000c9', 'sneak@roles.test')
      on conflict (id) do nothing;
    insert into public.profiles (id, school_id, full_name, role)
      values ('00000000-0000-0000-0000-0000000000c9',
              (select v from ids where k='s1'), 'Sneaked In', 'accountant');
    raise exception 'FAIL: a NEW profile was created as an accountant';
  exception when others then
    get stacked diagnostics v_msg = message_text;
    if v_msg like 'FAIL:%' then raise; end if;
  end;

  -- DOOR 3: fn_invite_user, at the point of asking.
  begin
    perform public.fn_invite_user('another@roles.test', 'admin_clerk', 'Another');
    raise exception 'FAIL: an invitation was issued for a retired role';
  exception when others then
    get stacked diagnostics v_msg = message_text;
    if v_msg like 'FAIL:%' then raise; end if;
    if position('withdrawn' in v_msg) = 0 then
      raise exception 'FAIL: fn_invite_user refused with "%", which does not '
                      'say what to use instead', v_msg;
    end if;
  end;

  -- DOOR 4: a direct INSERT into user_invites, going round the function.
  begin
    insert into public.user_invites (school_id, email, role, created_by)
      values ((select v from ids where k='s1'), 'direct@roles.test', 'accountant',
              (select v from ids where k='own'));
    raise exception 'FAIL: a retired role was written straight into user_invites';
  exception when others then
    get stacked diagnostics v_msg = message_text;
    if v_msg like 'FAIL:%' then raise; end if;
  end;

  raise notice 'ok: all four doors back to a retired role are shut';
end $doors$;

-- ------------------------------------------------------- what is left to give --
do $list$
declare
  v_roles text[];
begin
  select array(select unnest(public.fn_assignable_roles())::text order by 1) into v_roles;
  if v_roles <> array['class_teacher', 'parent', 'principal', 'readonly', 'subject_teacher'] then
    raise exception 'FAIL: the assignable roles are %, which is not the five '
                    'the product offers', v_roles;
  end if;

  -- The owner is deliberately absent. Exactly one exists per school, signup
  -- creates it, and 0065 has refused to invite one since it was written. A
  -- dropdown offering it would be offering something the database will refuse.
  if 'owner' = any(v_roles) then
    raise exception 'FAIL: owner is offered as an assignable role';
  end if;
  raise notice 'ok: five assignable roles, and owner is not one of them';
end $list$;

-- The five that are left must all still be legal values to hold, which is a
-- different question from whether they can be handed out: a school can have a
-- parent without it being in the staff dropdown.
do $legal$
declare
  r text;
begin
  foreach r in array array['owner','principal','class_teacher','subject_teacher','readonly','parent']
  loop
    if not exists (select 1 from pg_enum e join pg_type t on t.oid = e.enumtypid
                    where t.typname = 'user_role' and e.enumlabel = r) then
      raise exception 'FAIL: the % role is no longer a legal value', r;
    end if;
  end loop;

  -- And the two retired ones are STILL IN THE ENUM, on purpose. Postgres has no
  -- DROP VALUE, and 266 lines across 60 frozen migrations name them inside
  -- has_role() lists. Removing the type would break a school re-pasting an old
  -- bundle, and because a bundle is one transaction the whole thing would roll
  -- back. A value no row can hold is already unreachable.
  if not exists (select 1 from pg_enum e join pg_type t on t.oid = e.enumtypid
                  where t.typname = 'user_role' and e.enumlabel = 'admin_clerk') then
    raise exception 'FAIL: admin_clerk was removed from the enum. Sixty frozen '
                    'migrations name it, and a school re-pasting one of those '
                    'bundles would roll the whole bundle back.';
  end if;
  raise notice 'ok: the live roles are legal and the retired ones are merely unreachable';
end $legal$;

rollback;
\echo 'ROLES PRUNED: ALL TESTS PASSED'

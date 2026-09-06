-- =============================================================================
-- A school signed up and its owner could not get in
--
-- WHAT THIS FILE DEFENDS, AND WHY IT IS NOT HYPOTHETICAL
--
-- Two real schools signed up through the public form. Both times the school
-- row, the trial and the login were created and worked, and both owners were
-- shown the operator's own gate on the click meant to open their new school:
--
--     Not available
--     This area is for the system operator.
--     [Sign out]
--
-- The missing piece was the profiles row. handle_new_user() is an AFTER INSERT
-- trigger on auth.users which reads the school out of app metadata, and the auth
-- service does not always write app metadata in the statement that inserts the
-- row: some versions insert the user and update the metadata onto it a moment
-- later. An AFTER INSERT trigger sees the first statement only.
--
-- Reproduced before the fix was written, on a fresh database with every
-- migration applied. Two signups, identical but for how app metadata arrives:
--
--     name    |  email   | has_profile | role  | active
--   ----------+----------+-------------+-------+--------
--    Repro A  | a@x.test | t           | owner | t      <- written in the insert
--    Repro B  | b@x.test | f           |       |        <- written in an update
--
-- The rules this file defends:
--
--   1. THE SCHOOL ARRIVES WHENEVER IT ARRIVES. A signup attaches the owner
--      whether app metadata is written in the insert or in an update after it.
--      This is the defect. Both spellings are asserted, because a fix for the
--      second that broke the first would break every existing school at once.
--   2. NOTHING IS EVER REVISITED. An app metadata edit that happens later
--      cannot move an attached person into another school, promote them, or
--      reopen a closed login. The trigger now fires on updates, so this is what
--      makes that safe.
--   3. RUBBISH IN APP METADATA CANNOT FAIL A SIGNUP. A malformed uuid and a
--      school that no longer exists both create nothing and raise nothing.
--      Before this, either would have aborted the insert into auth.users with a
--      Postgres error and no account at all.
--   4. THE OPERATOR IS NEVER GIVEN A SCHOOL, not even by an invitation sent to
--      their own address. Their console works BECAUSE they have no profile.
--   5. USER METADATA STILL DECIDES NOTHING, and an invitation is still the only
--      other trusted path, still single-use, still refused when ambiguous. The
--      0065 rules must survive a rewrite of the function that enforces them.
--   6. THE DECISION IS REACHABLE BY NOBODY. fn__attach_login decides which
--      school a login belongs to, which is the whole tenancy boundary.
--   7. THE OPERATOR CAN SEE IT AND FIX IT, and a school user cannot see either.
--      A stranded login is invisible in every other screen of the console.
--
-- Run: psql -v ON_ERROR_STOP=1 -f supabase/tests/a_login_with_no_school.sql
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

create or replace function pg_temp.raises(p_sql text, p_needle text) returns boolean
language plpgsql as $$
begin
  execute p_sql;
  return false;
exception when others then
  if position(lower(p_needle) in lower(sqlerrm)) > 0 then return true; end if;
  raise notice '  (refused, but with the wrong message: %)', sqlerrm;
  return false;
end;
$$;

-- The auth service that writes app metadata IN the insert.
create or replace function pg_temp.signup_in_insert(
  p_id uuid, p_email text, p_school uuid, p_name text, p_role text default null)
returns void language sql as $$
  insert into auth.users (id, email, raw_user_meta_data, raw_app_meta_data)
  values (p_id, p_email, jsonb_build_object('full_name', p_name),
          jsonb_strip_nulls(jsonb_build_object(
            'school_id', p_school::text, 'role', p_role, 'provider', 'email')));
$$;

-- The auth service that writes app metadata in a SECOND statement. This is the
-- one that stranded two real schools.
create or replace function pg_temp.signup_then_update(
  p_id uuid, p_email text, p_school uuid, p_name text, p_role text default null)
returns void language plpgsql as $$
begin
  insert into auth.users (id, email, raw_user_meta_data, raw_app_meta_data)
  values (p_id, p_email, jsonb_build_object('full_name', p_name),
          '{"provider":"email","providers":["email"]}'::jsonb);
  update auth.users set raw_app_meta_data = raw_app_meta_data
    || jsonb_strip_nulls(jsonb_build_object('school_id', p_school::text, 'role', p_role))
   where id = p_id;
end;
$$;

-- A browser signup: user metadata only, which is what an attacker controls.
create or replace function pg_temp.browser_signup(
  p_id uuid, p_email text, p_meta jsonb) returns void language sql as $$
  insert into auth.users (id, email, raw_user_meta_data, raw_app_meta_data)
  values (p_id, p_email, p_meta, '{"provider":"email"}'::jsonb);
$$;

create or replace function pg_temp.prof(p_id uuid)
returns table (role text, active boolean, school text) language sql as $$
  select p.role::text, p.active, s.name
    from public.profiles p join public.schools s on s.id = p.school_id
   where p.id = p_id;
$$;

-- --- Fixture -----------------------------------------------------------------
-- Two schools created the way fn_signup_school creates them, so the trial rows
-- and the contact fields are real rather than approximated, plus an operator.
do $seed$
declare v_a uuid; v_b uuid; v_c uuid; ops uuid := '00000000-0000-0000-0000-0000000a0009';
begin
  v_a := (public.fn_signup_school('Strand A', 'Lahore',    'Owner A', null, 'a@strand.test')->>'school_id')::uuid;
  v_b := (public.fn_signup_school('Strand B', 'Islamabad', 'Owner B', null, 'b@strand.test')->>'school_id')::uuid;
  v_c := (public.fn_signup_school('Strand C', 'Multan',    'Owner C', null, 'c@strand.test')->>'school_id')::uuid;

  insert into auth.users (id, email) values (ops, 'ops@strand.test')
    on conflict (id) do nothing;
  insert into public.platform_admins (user_id, email) values (ops, 'ops@strand.test')
    on conflict (user_id) do nothing;

  create temp table _s (k text primary key, v uuid);
  insert into _s values ('a', v_a), ('b', v_b), ('c', v_c), ('ops', ops);
end
$seed$;

do $grant$
begin
  execute format('grant usage on schema %I to authenticated',
                 (select nspname from pg_namespace n
                   join pg_class c on c.relnamespace = n.oid
                  where c.relname = '_s' and n.nspname like 'pg_temp%'));
  execute 'grant select on _s to authenticated';
end
$grant$;

-- =============================================================================
-- 1. Rule 1 - the school arrives whenever it arrives
-- =============================================================================
do $r1$
declare v_a uuid := (select v from _s where k = 'a');
        v_b uuid := (select v from _s where k = 'b');
begin
  perform pg_temp.signup_in_insert(
    '00000000-0000-0000-0000-0000000a0001', 'a@strand.test', v_a, 'Owner A');
  perform pg_temp.signup_then_update(
    '00000000-0000-0000-0000-0000000a0002', 'b@strand.test', v_b, 'Owner B');
end
$r1$;

select pg_temp.ok(
  (select role = 'owner' and active and school = 'Strand A'
     from pg_temp.prof('00000000-0000-0000-0000-0000000a0001')),
  '1. app metadata written IN the insert still makes the first account an '
  || 'active owner of the school it names');

select pg_temp.ok(
  (select role = 'owner' and active and school = 'Strand B'
     from pg_temp.prof('00000000-0000-0000-0000-0000000a0002')),
  '2. THE DEFECT. app metadata written in an UPDATE after the insert now '
  || 'attaches the owner too. Before this, the school existed, the login '
  || 'worked, and its owner was shown the operator gate');

-- A teacher, created the broken way, keeps the role app metadata asked for
-- rather than landing as the school's owner or as an inert readonly.
do $r1b$
declare v_a uuid := (select v from _s where k = 'a');
begin
  perform pg_temp.signup_then_update(
    '00000000-0000-0000-0000-0000000a0003', 'teach@strand.test', v_a,
    'A Teacher', 'class_teacher');
end
$r1b$;

select pg_temp.ok(
  (select role = 'class_teacher' and active and school = 'Strand A'
     from pg_temp.prof('00000000-0000-0000-0000-0000000a0003')),
  '3. and the ROLE app metadata asked for is honoured on that path, so a '
  || 'teacher created by create-teacher does not become the school''s owner');

-- =============================================================================
-- 2. Rule 2 - nothing is ever revisited
--
-- The trigger fires on every app metadata write now. Without the "already
-- attached" exit this would be a way to move somebody between schools, which is
-- a tenant breach, and to reopen a login an owner had closed.
-- =============================================================================
do $r2$
declare v_c uuid := (select v from _s where k = 'c');
begin
  update auth.users
     set raw_app_meta_data = raw_app_meta_data
         || jsonb_build_object('school_id', v_c::text, 'role', 'principal')
   where id = '00000000-0000-0000-0000-0000000a0003';
end
$r2$;

select pg_temp.ok(
  (select role = 'class_teacher' and school = 'Strand A'
     from pg_temp.prof('00000000-0000-0000-0000-0000000a0003')),
  '4. a later app metadata edit naming ANOTHER school does not move an '
  || 'attached person into it, and does not promote them');

-- A closed login stays closed.
update public.profiles set active = false
 where id = '00000000-0000-0000-0000-0000000a0003';
update auth.users set raw_app_meta_data = raw_app_meta_data || '{"touched":true}'::jsonb
 where id = '00000000-0000-0000-0000-0000000a0003';

select pg_temp.ok(
  (select not active from pg_temp.prof('00000000-0000-0000-0000-0000000a0003')),
  '5. and a login an owner has CLOSED is not reopened by a metadata write');

update public.profiles set active = true
 where id = '00000000-0000-0000-0000-0000000a0003';

-- =============================================================================
-- 3. Rule 3 - rubbish in app metadata cannot fail a signup
-- =============================================================================
select pg_temp.ok(
  not pg_temp.raises($$
    insert into auth.users (id, email, raw_app_meta_data)
    values ('00000000-0000-0000-0000-0000000a0004', 'junk@strand.test',
            '{"school_id":"not-a-uuid"}'::jsonb)
  $$, 'invalid input syntax'),
  '6. a malformed school id in app metadata does not abort the insert into '
  || 'auth.users, so the person still gets an account');

select pg_temp.ok(
  not exists (select 1 from public.profiles
               where id = '00000000-0000-0000-0000-0000000a0004'),
  '7. and creates no profile, so nothing is guessed at');

select pg_temp.ok(
  not pg_temp.raises($$
    insert into auth.users (id, email, raw_app_meta_data)
    values ('00000000-0000-0000-0000-0000000a0005', 'gone@strand.test',
            '{"school_id":"11111111-2222-3333-4444-555555555555"}'::jsonb)
  $$, 'violates foreign key'),
  '8. a school id naming a school that does not exist does not abort the '
  || 'insert either, where the profiles foreign key would have');

select pg_temp.ok(
  not exists (select 1 from public.profiles
               where id = '00000000-0000-0000-0000-0000000a0005'),
  '9. and creates no profile');

-- =============================================================================
-- 4. Rule 4 - the operator is never given a school
--
-- The catastrophic version of this: an invitation for the vendor's own address
-- attaches them to a customer, current_school_id() starts answering, and the
-- console they run the business from refuses them.
-- =============================================================================
do $r4$
declare v_a uuid := (select v from _s where k = 'a');
begin
  insert into public.user_invites (school_id, email, role, full_name)
  values (v_a, 'ops@strand.test', 'principal', 'Sneaky');
  -- Fired the same way a metadata write fires it.
  update auth.users set raw_app_meta_data = coalesce(raw_app_meta_data, '{}'::jsonb)
   where id = (select v from _s where k = 'ops');
end
$r4$;

select pg_temp.ok(
  not exists (select 1 from public.profiles
               where id = (select v from _s where k = 'ops')),
  '10. the platform operator is given no profile even when a live invitation '
  || 'names their address, because their console works BY having none');

select pg_temp.ok(
  (select accepted_at is null from public.user_invites
    where email = 'ops@strand.test'),
  '11. and the invitation is left pending rather than silently burnt');

-- =============================================================================
-- 5. Rule 5 - the 0065 rules survive the rewrite
-- =============================================================================
do $r5$
declare v_a uuid := (select v from _s where k = 'a'); i integer := 0; r text;
begin
  foreach r in array array['principal','admin_clerk','accountant','class_teacher',
                           'subject_teacher','readonly','parent','owner'] loop
    i := i + 1;
    perform pg_temp.browser_signup(
      ('00000000-0000-0000-0000-0000000b00' || lpad(i::text, 2, '0'))::uuid,
      'attack' || i || '@strand.test',
      jsonb_build_object('full_name', 'Attacker', 'role', r,
                         'school_id', v_a::text));
  end loop;
end
$r5$;

select pg_temp.ok(
  (select count(*) = 0 from public.profiles where full_name = 'Attacker'),
  '12. USER metadata still decides nothing. Eight browser signups naming a '
  || 'school and a role, one for every role on the old whitelist, get no '
  || 'profile at all');

-- The invitation path, which is what lets a school add a teacher without the
-- Edge Function deployed.
do $r5b$
declare v_b uuid := (select v from _s where k = 'b');
begin
  insert into public.user_invites (school_id, email, role, full_name)
  values (v_b, 'invited@strand.test', 'accountant', 'Invited Person');
  perform pg_temp.browser_signup('00000000-0000-0000-0000-0000000c0001',
    'invited@strand.test', '{"full_name":"Typed Their Own Name"}'::jsonb);
end
$r5b$;

select pg_temp.ok(
  (select role = 'accountant' and active and school = 'Strand B'
     from pg_temp.prof('00000000-0000-0000-0000-0000000c0001')),
  '13. an invitation is still redeemed by email, with the role the SCHOOL chose');

select pg_temp.ok(
  (select accepted_at is not null and accepted_by = '00000000-0000-0000-0000-0000000c0001'
     from public.user_invites where email = 'invited@strand.test'),
  '14. and is marked used, by whom, so it cannot be redeemed twice');

-- Two schools inviting one address. There is no honest way to choose.
do $r5c$
declare v_a uuid := (select v from _s where k = 'a');
        v_b uuid := (select v from _s where k = 'b');
begin
  insert into public.user_invites (school_id, email, role, full_name) values
    (v_a, 'both@strand.test', 'class_teacher', 'Moonlighter'),
    (v_b, 'both@strand.test', 'class_teacher', 'Moonlighter');
  perform pg_temp.browser_signup('00000000-0000-0000-0000-0000000c0002',
    'both@strand.test', '{"full_name":"Moonlighter"}'::jsonb);
end
$r5c$;

select pg_temp.ok(
  not exists (select 1 from public.profiles
               where id = '00000000-0000-0000-0000-0000000c0002')
  and (select count(*) = 2 from public.user_invites
        where email = 'both@strand.test' and accepted_at is null),
  '15. two live invitations for one address create NOTHING and leave both '
  || 'pending, because a profile carries one school_id and picking either '
  || 'would put that person inside one school''s children''s records');

-- =============================================================================
-- 6. Rule 6 - the decision is reachable by nobody
-- =============================================================================
select pg_temp.ok(
  not has_function_privilege('authenticated', 'public.fn__attach_login(uuid)', 'execute')
  and not has_function_privilege('anon', 'public.fn__attach_login(uuid)', 'execute'),
  '16. fn__attach_login is executable by neither anon nor authenticated. It '
  || 'decides which school a login belongs to, which is the whole tenancy '
  || 'boundary');

-- =============================================================================
-- 7. Rule 7 - the operator can see it and fix it, and a school user cannot
--
-- Strand C has a login with no profile: the state two real schools were left in.
-- =============================================================================
do $r7$
declare v_c uuid := (select v from _s where k = 'c');
begin
  -- Written straight in, with the trigger off, to manufacture the exact state
  -- the old trigger left behind. Disabling it is the only honest way to
  -- reproduce a fault the trigger no longer allows.
  alter table auth.users disable trigger on_auth_user_created;
  insert into auth.users (id, email, raw_user_meta_data, raw_app_meta_data)
  values ('00000000-0000-0000-0000-0000000d0001', 'stranded@strand.test',
          '{"full_name":"Stranded Owner"}'::jsonb,
          jsonb_build_object('school_id', v_c::text));
  alter table auth.users enable trigger on_auth_user_created;
end
$r7$;

do $r7c$
declare v_ok boolean;
begin
  -- set local role authenticated IS LOAD-BEARING. A superuser is exempt from
  -- RLS, and is_platform_admin() is asked of platform_admins rather than of the
  -- role, so without this the two refusals below would be asserted against a
  -- caller nothing refuses and would pass whatever the guards said.
  set local role authenticated;
  perform set_config('test.uid', '00000000-0000-0000-0000-0000000a0001', false);
  v_ok := pg_temp.raises('select * from public.fn_platform_unattached_logins()',
                         'not permitted');
  reset role;
  perform pg_temp.ok(v_ok,
    '17. a school OWNER cannot read the list. It names logins and schools '
    || 'across every tenant on the platform');
  set local role authenticated;
  perform set_config('test.uid', '00000000-0000-0000-0000-0000000a0001', false);
  v_ok := pg_temp.raises(
    'select public.fn_platform_attach_login(''00000000-0000-0000-0000-0000000d0001'')',
    'not permitted');
  reset role;
  perform pg_temp.ok(v_ok, '18. and cannot attach one either');
end
$r7c$;

do $r7d$
declare n integer; v_out jsonb;
begin
  perform set_config('test.uid', (select v::text from _s where k = 'ops'), false);
  select count(*) into n from public.fn_platform_unattached_logins()
   where email = 'stranded@strand.test' and school_name = 'Strand C';
  perform pg_temp.ok(n = 1,
    '19. the operator sees exactly the stranded login, named with its school. '
    || 'Nothing else in the console can show this: the school is in the list, '
    || 'on trial, looking like one that has not opened the app yet');

  -- A login naming a school that no longer exists is NOT on the list, because
  -- there is nothing to attach it to and a permanent entry with no possible
  -- action is how a queue stops being read.
  select count(*) into n from public.fn_platform_unattached_logins()
   where email in ('gone@strand.test', 'junk@strand.test');
  perform pg_temp.ok(n = 0,
    '20. and a login whose metadata names nothing attachable is not on it');

  v_out := public.fn_platform_attach_login('00000000-0000-0000-0000-0000000d0001');
  perform pg_temp.ok(
    (select role = 'owner' and active and school = 'Strand C'
       from pg_temp.prof('00000000-0000-0000-0000-0000000d0001')),
    '21. attaching one uses the same rule a signup uses: the first account of '
    || 'a school becomes its owner, active');

  perform pg_temp.ok(
    exists (select 1 from public.operator_actions
             where action = 'login_attached'
               and school_id = (select v from _s where k = 'c')),
    '22. and it is written to THAT SCHOOL''S own activity log, because a login '
    || 'inside a customer''s data created by the vendor is something the school '
    || 'is entitled to see a record of');

  perform pg_temp.ok(
    (select count(*) = 0 from public.fn_platform_unattached_logins()),
    '23. after which the list is empty, which is what it should always be');

  -- Idempotent: pressing the button twice must not raise and must not change
  -- anything. The commonest thing anybody does with a new button is press it
  -- again.
  v_out := public.fn_platform_attach_login('00000000-0000-0000-0000-0000000d0001');
  perform pg_temp.ok(v_out->>'outcome' = 'already attached',
    '24. pressing Attach twice says so and changes nothing');
  perform set_config('test.uid', '', false);
end
$r7d$;

-- =============================================================================
-- 8. The trigger fires on BOTH events
--
-- The one-line fact the whole file rests on, asserted from the catalogue,
-- because a re-paste of bundle 1 puts the INSERT-only trigger back and every
-- assertion above would then be testing a database nobody has.
-- =============================================================================
select pg_temp.ok(
  (select (tgtype & 4) <> 0 and (tgtype & 16) <> 0
     from pg_trigger where tgname = 'on_auth_user_created'),
  '25. on_auth_user_created fires on INSERT and on UPDATE OF raw_app_meta_data, '
  || 'so it no longer matters which statement the auth service writes the '
  || 'school in');

rollback;

-- =============================================================================
-- Who is allowed to decide a new login's school and role?
--
-- Demonstrated on a real database before 0065 was written. handle_new_user()
-- read both from new.raw_user_meta_data — the field a browser fills in when it
-- calls auth.signUp({options:{data:{...}}}) with the PUBLIC anon key. Two
-- strangers signed up naming a victim school:
--
--        full_name       |    role    | active
--   ---------------------+------------+--------
--    Real Owner          | owner      | t
--    Totally Normal Pare | accountant | t     <-- self-assigned
--    Also Normal         | principal  | t     <-- self-assigned
--
-- Both passed has_role() and may_view(). Every signed-in user already knows
-- their own school_id, so the floor on this was: any parent, teacher or clerk
-- could create a second login and become PRINCIPAL of their own school.
--
-- The rules this file defends:
--
--   1. USER METADATA DECIDES NOTHING. A signup naming a school, a role, or both
--      in raw_user_meta_data gets NO profile. Asserted for every role on the old
--      whitelist, because a gate that holds for 'principal' and leaks for
--      'accountant' is not a gate.
--   2. APP METADATA IS TRUSTED, because only the service role can write it.
--      That is the Edge Functions' channel and it must keep working.
--   3. AN INVITATION IS THE OTHER TRUSTED PATH — a row an owner or principal
--      created for one email address. It is what lets a school add a teacher
--      without the create-teacher Edge Function deployed.
--   4. AN INVITATION IS SINGLE-USE, EXPIRES, AND CANNOT MINT AN OWNER.
--   5. ONLY AN OWNER OR PRINCIPAL MAY INVITE, and never across schools.
--
-- Run: psql -v ON_ERROR_STOP=1 -f supabase/tests/provisioning.sql
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

create or replace function pg_temp.sch(p_name text) returns uuid language sql as $$
  select id from public.schools where name = p_name;
$$;

create or replace function pg_temp.be(p_name text) returns void language sql as $$
  select set_config('test.uid',
    (select id::text from public.profiles where full_name = p_name), false);
$$;

-- A signup, exactly as the browser makes it: user metadata only.
create or replace function pg_temp.browser_signup(
  p_id uuid, p_email text, p_meta jsonb) returns void language sql as $$
  insert into auth.users (id, email, raw_user_meta_data, raw_app_meta_data)
  values (p_id, p_email, p_meta, '{}'::jsonb);
$$;

-- A signup as an Edge Function makes it: app metadata, service role only.
create or replace function pg_temp.service_signup(
  p_id uuid, p_email text, p_app jsonb, p_name text default null)
returns void language sql as $$
  insert into auth.users (id, email, raw_user_meta_data, raw_app_meta_data)
  values (p_id, p_email,
          case when p_name is null then '{}'::jsonb
               else jsonb_build_object('full_name', p_name) end,
          p_app);
$$;

-- --- Fixture -----------------------------------------------------------------
-- Two schools, each with a real owner, provisioned the trusted way.
do $seed$
declare v_a uuid; v_b uuid;
begin
  insert into public.schools (name) values ('Prov A') returning id into v_a;
  insert into public.schools (name) values ('Prov B') returning id into v_b;
  insert into public.subscriptions (school_id, plan_code, status, trial_ends_on)
  values (v_a, 'growth', 'active', current_date + 300),
         (v_b, 'growth', 'active', current_date + 300);

  -- The signup Edge Function's call: school in APP metadata, no role, and the
  -- school has no profiles yet, so this becomes its owner.
  perform pg_temp.service_signup('00000000-0000-0000-0000-0000000f0001',
    'ownera@prov.test', jsonb_build_object('school_id', v_a::text), 'Owner A');
  perform pg_temp.service_signup('00000000-0000-0000-0000-0000000f0002',
    'ownerb@prov.test', jsonb_build_object('school_id', v_b::text), 'Owner B');
end;
$seed$;

-- =============================================================================
-- 1. Rule 2 — the trusted path still works, and makes the first account an owner
-- =============================================================================
select pg_temp.ok(
  (select role::text = 'owner' and active from public.profiles
    where full_name = 'Owner A'),
  '1. the signup Edge Function''s call creates the school''s first account as an '
  || 'active OWNER — the path a real school signs up through must keep working');

select pg_temp.ok(
  (select school_id = pg_temp.sch('Prov A') from public.profiles
    where full_name = 'Owner A'),
  '2. attached to the school app_metadata named');

-- =============================================================================
-- 2. Rule 1 — user metadata decides NOTHING, for any role
--
-- Every role the old whitelist accepted is tried. A gate that holds for
-- 'principal' and leaks for 'accountant' is not a gate, and the original defect
-- was found on 'accountant' first.
-- =============================================================================
do $attack$
declare
  v_a uuid := pg_temp.sch('Prov A');
  v_roles text[] := array['principal','admin_clerk','accountant',
                          'class_teacher','subject_teacher','readonly','parent'];
  v_r text; i integer := 0;
begin
  foreach v_r in array v_roles loop
    i := i + 1;
    perform pg_temp.browser_signup(
      ('00000000-0000-0000-0000-00000000a1' || lpad(i::text, 2, '0'))::uuid,
      'attacker' || i || '@gmail.com',
      jsonb_build_object('school_id', v_a::text, 'role', v_r,
                         'full_name', 'Totally Normal Parent'));
  end loop;
end;
$attack$;

select pg_temp.ok(
  (select count(*) from public.profiles where school_id = pg_temp.sch('Prov A')) = 1,
  '3. seven browser signups naming the school and asking for every role on the '
  || 'old whitelist created NOT ONE profile — the school still has only its owner');

select pg_temp.ok(
  not exists (select 1 from public.profiles where full_name = 'Totally Normal Parent'),
  '4. and not one of them exists anywhere, under any school');

select pg_temp.ok(
  (select count(*) from auth.users where email like 'attacker%@gmail.com') = 7,
  '5. the LOGINS were created — the signup itself is not what we refuse. What we '
  || 'refuse is the login deciding what it is allowed to do');

-- The inert login, from its own point of view.
select set_config('test.uid', '00000000-0000-0000-0000-00000000a101', false);
set local role authenticated;
select pg_temp.ok(
  public.current_school_id() is null
  and not public.has_role('principal') and not public.has_role('accountant')
  and not public.may_view('owner','principal','admin_clerk','accountant'),
  '6. it has no school context and passes no gate — the profile-less login is '
  || 'genuinely inert, not merely unlisted');
reset role;

-- School_id alone, with no role, must not attach either.
select pg_temp.browser_signup('00000000-0000-0000-0000-00000000a201', 'sneak@gmail.com',
  jsonb_build_object('school_id', pg_temp.sch('Prov A')::text, 'full_name', 'Sneak'));
select pg_temp.ok(
  not exists (select 1 from public.profiles where full_name = 'Sneak'),
  '7. naming only the school, with no role, attaches nothing either — a stranger '
  || 'must not appear on a school''s Users screen at all');

-- =============================================================================
-- 3. Rule 3 — the invitation path
-- =============================================================================
select pg_temp.be('Owner A');

select public.fn_invite_user('ayesha@school.pk', 'class_teacher', 'Miss Ayesha') as inv \gset

select pg_temp.ok(
  (select count(*) from public.fn_pending_invites()) = 1,
  '8. the owner invites a class teacher and it shows as pending');

-- Redeemed with DIFFERENT capitalisation than it was issued in. A school that
-- types "Ayesha@School.pk" and gets refused raises a support ticket about a
-- working feature.
select pg_temp.browser_signup('00000000-0000-0000-0000-00000000b001',
  'Ayesha@School.PK', jsonb_build_object('full_name', 'ignored'));

select pg_temp.ok(
  (select role::text = 'class_teacher' and active and school_id = pg_temp.sch('Prov A')
     from public.profiles where id = '00000000-0000-0000-0000-00000000b001'),
  '9. signing up with that address — in any capitalisation — creates exactly the '
  || 'role the school chose, at the school that chose it');

select pg_temp.ok(
  (select full_name = 'Miss Ayesha' from public.profiles
    where id = '00000000-0000-0000-0000-00000000b001'),
  '10. and takes the name from the INVITE, not from the browser — the school '
  || 'decides how its staff are listed');

select pg_temp.ok(
  (select count(*) from public.fn_pending_invites()) = 0,
  '11. the invitation is consumed, so it cannot be redeemed twice');

select pg_temp.ok(
  (select accepted_by = '00000000-0000-0000-0000-00000000b001'
     from public.user_invites where email = 'ayesha@school.pk'),
  '12. and records who redeemed it');

-- =============================================================================
-- 4. Rule 4 — the limits on an invitation
-- =============================================================================
select pg_temp.ok(
  pg_temp.raises($$select public.fn_invite_user('boss@school.pk', 'owner')$$,
                 'owner cannot be invited'),
  '13. an OWNER cannot be invited — the school''s top privilege must not sit '
  || 'behind an email address');

select pg_temp.ok(
  pg_temp.raises($$select public.fn_invite_user('not-an-email', 'class_teacher')$$,
                 'valid email'),
  '14. a malformed address is refused rather than stored as a dead invite');

select pg_temp.ok(
  pg_temp.raises($$select public.fn_invite_user('ayesha@school.pk', 'accountant')$$,
                 'already has a login'),
  '15. re-inviting somebody who already has a login here is refused — two '
  || 'profiles for one teacher and no idea which is live');

-- An expired invitation.
select public.fn_invite_user('late@school.pk', 'admin_clerk') as late \gset
update public.user_invites set expires_at = now() - interval '1 day'
 where email = 'late@school.pk';

select pg_temp.browser_signup('00000000-0000-0000-0000-00000000b002',
  'late@school.pk', '{}'::jsonb);

select pg_temp.ok(
  not exists (select 1 from public.profiles
               where id = '00000000-0000-0000-0000-00000000b002'),
  '16. an EXPIRED invitation grants nothing — a stale invite forwarded months '
  || 'later must not still open the door');

-- Revoking one.
select public.fn_invite_user('gone@school.pk', 'accountant') as g \gset
select public.fn_revoke_invite((select id from public.user_invites
                                 where email = 'gone@school.pk'));
select pg_temp.browser_signup('00000000-0000-0000-0000-00000000b003',
  'gone@school.pk', '{}'::jsonb);
select pg_temp.ok(
  not exists (select 1 from public.profiles
               where id = '00000000-0000-0000-0000-00000000b003'),
  '17. and a REVOKED invitation grants nothing — the school changed its mind '
  || 'before the person signed up');

-- =============================================================================
-- 5. Rule 5 — who may invite, and across which boundary
-- =============================================================================
-- A clerk at Prov A.
select pg_temp.service_signup('00000000-0000-0000-0000-00000000b010', 'clerk@prov.test',
  jsonb_build_object('school_id', pg_temp.sch('Prov A')::text, 'role', 'admin_clerk'),
  'Clerk A');

select set_config('test.uid', '00000000-0000-0000-0000-00000000b010', false);
select pg_temp.ok(
  pg_temp.raises($$select public.fn_invite_user('x@school.pk', 'accountant')$$,
                 'owner or principal'),
  '18. a clerk cannot invite anybody — otherwise the weakest admin account is '
  || 'the way in');

select pg_temp.ok(
  pg_temp.raises('select public.fn_pending_invites()', 'not permitted'),
  '19. nor read the pending list. A list of addresses that are about to become '
  || 'logins is worth stealing');

-- Cross-school: B's owner must not see or touch A's invitations.
select pg_temp.be('Owner B');
select public.fn_invite_user('shared@school.pk', 'class_teacher') as sb \gset

select pg_temp.ok(
  (select count(*) from public.fn_pending_invites()) = 1
  and (select count(*) from public.fn_pending_invites() where email = 'late@school.pk') = 0,
  '20. school B''s pending list holds only school B''s invitation — A''s expired '
  || 'one is invisible to it');

select pg_temp.ok(
  pg_temp.raises(
    format('select public.fn_revoke_invite(%L)',
           (select id from public.user_invites where email = 'late@school.pk')),
    'not found'),
  '21. and B cannot revoke A''s invitation');

-- The same address invited by BOTH schools. There is no honest winner: a profile
-- carries ONE school_id, so choosing either would put this person inside one
-- school's children's records while the other school believes they are in. The
-- first version of the trigger took "order by created_at desc limit 1", which is
-- arbitrary the moment both rows share a timestamp — and both do when they are
-- written in one transaction, because now() is the transaction's start.
select pg_temp.be('Owner A');
select public.fn_invite_user('shared@school.pk', 'accountant') as sa \gset
select pg_temp.browser_signup('00000000-0000-0000-0000-00000000b020',
  'shared@school.pk', '{}'::jsonb);

select pg_temp.ok(
  not exists (select 1 from public.profiles
               where id = '00000000-0000-0000-0000-00000000b020'),
  '22. an address invited by TWO schools is refused outright — no profile. '
  || 'Guessing which school meant it is how a teacher ends up reading the wrong '
  || 'school''s pupils');

select pg_temp.ok(
  (select count(*) from public.user_invites
    where email = 'shared@school.pk' and accepted_at is null) = 2,
  '23. and BOTH invitations stay pending, so each school can see the clash on '
  || 'its own Users screen and one of them can withdraw');

-- Once the clash is resolved, the survivor redeems normally. Without this the
-- refusal above would be a dead end rather than a state to pass through.
select pg_temp.be('Owner B');
select public.fn_revoke_invite((select id from public.user_invites
                                 where email = 'shared@school.pk'
                                   and school_id = pg_temp.sch('Prov B')));
select pg_temp.browser_signup('00000000-0000-0000-0000-00000000b021',
  'shared@school.pk', '{}'::jsonb);

select pg_temp.ok(
  (select school_id = pg_temp.sch('Prov A') and role::text = 'accountant' and active
     from public.profiles where id = '00000000-0000-0000-0000-00000000b021'),
  '24. after one school withdraws, the remaining invitation redeems exactly as it '
  || 'would have on its own');

-- =============================================================================
-- 6. The table itself is append-only through RLS
-- =============================================================================
select set_config('test.uid', '00000000-0000-0000-0000-0000000f0001', false);
set local role authenticated;

select pg_temp.ok(
  (select count(*) from public.user_invites) = (
    select count(*) from public.user_invites
     where school_id = pg_temp.sch('Prov A')),
  '25. an owner reads only their own school''s invitations');

do $rls$
declare n integer;
begin
  begin
    insert into public.user_invites (school_id, email, role)
    values (public.current_school_id(), 'direct@school.pk', 'principal');
    n := 1;
  exception when others then n := 0;
  end;
  perform pg_temp.ok(n = 0,
    '26. and cannot INSERT one directly — every invitation goes through '
    || 'fn_invite_user, so one place decides what a valid invitation is');
end;
$rls$;

reset role;

do $$ begin raise notice 'ALL PROVISIONING TESTS PASSED'; end $$;

rollback;

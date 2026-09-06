-- =============================================================================
-- The addresses a school hands out, and the passwords it chose
--
-- WHAT THIS IS ABOUT
--
-- A Pakistani private school does not collect working email addresses from
-- parents. It invents them, and names repeat: three schools in one city can
-- each decide that the father of their Muhammad Ali is
-- muhammadali786@gmail.com. Two consequences follow and 0116 answers both.
--
-- The address may already be taken somewhere on the platform, and the office
-- found that out only after typing a name, an address, a password and a role,
-- in the auth service's own words.
--
-- And an invented address cannot receive a reset link, so a parent who forgot
-- their password was locked out permanently: the office could not reset it and
-- could not make a replacement login either, because the address was taken by
-- the login they were trying to replace.
--
-- Storing a password is normally indefensible, so the fences are the design and
-- they are what this file is mostly about. The argument for storing one at all
-- is that an owner or principal can ALREADY set any password in their school to
-- whatever they like, so they already hold access to every parent and teacher
-- account in the building; remembering the one they chose grants them nothing.
-- What must not happen is any of the following.
--
-- The rules this file defends:
--
--   1. THE CHECK ANSWERS FOR THE WHOLE PLATFORM, and says WHERE only about the
--      caller's own school. A school must not be able to learn that a
--      particular teacher has an account at a particular competitor.
--   2. A LIVE INVITATION IS A CLASH TOO. Two live invitations for one address
--      create no profile at all, so both schools believe they have a teacher
--      who can see nothing. Refusing at the keyboard is the only place this is
--      visible.
--   3. ONLY AN OWNER OR PRINCIPAL MAY ASK, and only about their own school.
--   4. THE KEY RING IS UNREACHABLE EXCEPT THROUGH ITS FUNCTIONS. No grant, no
--      policy, no query any client can write.
--   5. AN OWNER'S PASSWORD IS NEVER STORED. One leaked owner credential is the
--      whole school rather than one family.
--   6. NO OTHER SCHOOL, EVER. Not the ring, not a reveal, not a write.
--   7. NOT A CLERK, NOT AN OBSERVER. 'readonly' exists to look at everything and
--      change nothing, and a stored credential is a change waiting to happen.
--   8. NOT THE OPERATOR, EVEN INSIDE A SUPPORT VISIT. is_staff() and may_view()
--      honour an open session since 0074; these functions ask has_role(), which
--      does not, and that is why has_role was chosen.
--   9. A STALE ENTRY SAYS SO. A parent who changes their own password makes the
--      saved copy useless, and handing it out anyway is worse than not having
--      it.
--  10. EVERY REVEAL IS COUNTED, with who and when.
--  11. THERE IS NO school_id COLUMN, so the vendor's offboarding export, which
--      finds tables BY that column, cannot see it. This is the assertion that
--      keeps us out.
--
-- Run: psql -v ON_ERROR_STOP=1 -f supabase/tests/the_school_keeps_the_keys.sql
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

create or replace function pg_temp.verdict(p_email text) returns jsonb
language sql as $$ select public.fn_login_email_available(p_email) $$;

-- --- Fixture -----------------------------------------------------------------
-- Two schools with a full cast each, plus the operator. Logins are written with
-- the signup trigger DISABLED so the fixture can place people precisely; the
-- trigger's own behaviour is the subject of a different file.
do $seed$
declare
  a uuid; b uuid;
begin
  a := (public.fn_signup_school('Keys A', 'Lahore', 'Owner A', null, 'ownera@keys.test')->>'school_id')::uuid;
  b := (public.fn_signup_school('Keys B', 'Karachi', 'Owner B', null, 'ownerb@keys.test')->>'school_id')::uuid;

  alter table auth.users disable trigger on_auth_user_created;
  insert into auth.users (id, email, encrypted_password) values
    ('00000000-0000-0000-0000-00000000a001', 'ownera@keys.test',   '$2a$10$aaaaaaaaaaaaaaaaaaaaaa'),
    ('00000000-0000-0000-0000-00000000a002', 'principala@keys.test','$2a$10$bbbbbbbbbbbbbbbbbbbbbb'),
    ('00000000-0000-0000-0000-00000000a003', 'clerka@keys.test',    '$2a$10$cccccccccccccccccccccc'),
    ('00000000-0000-0000-0000-00000000a004', 'teachera@keys.test',  '$2a$10$dddddddddddddddddddddd'),
    ('00000000-0000-0000-0000-00000000a005', 'parenta@keys.test',   '$2a$10$eeeeeeeeeeeeeeeeeeeeee'),
    ('00000000-0000-0000-0000-00000000a006', 'observera@keys.test', '$2a$10$ffffffffffffffffffffff'),
    ('00000000-0000-0000-0000-00000000b001', 'ownerb@keys.test',    '$2a$10$gggggggggggggggggggggg'),
    ('00000000-0000-0000-0000-00000000b002', 'teacherb@keys.test',  '$2a$10$hhhhhhhhhhhhhhhhhhhhhh'),
    ('00000000-0000-0000-0000-0000000000ff', 'ops@keys.test',       '$2a$10$iiiiiiiiiiiiiiiiiiiiii');
  alter table auth.users enable trigger on_auth_user_created;

  insert into public.profiles (id, full_name, role, school_id, active) values
    ('00000000-0000-0000-0000-00000000a001', 'Owner A',    'owner',        a, true),
    ('00000000-0000-0000-0000-00000000a002', 'Principal A','principal',    a, true),
    ('00000000-0000-0000-0000-00000000a003', 'Clerk A',    'admin_clerk',  a, true),
    ('00000000-0000-0000-0000-00000000a004', 'Teacher A',  'class_teacher',a, true),
    ('00000000-0000-0000-0000-00000000a005', 'Parent A',   'parent',       a, true),
    ('00000000-0000-0000-0000-00000000a006', 'Observer A', 'readonly',     a, true),
    ('00000000-0000-0000-0000-00000000b001', 'Owner B',    'owner',        b, true),
    ('00000000-0000-0000-0000-00000000b002', 'Teacher B',  'class_teacher',b, true);

  insert into public.platform_admins (user_id, email)
  values ('00000000-0000-0000-0000-0000000000ff', 'ops@keys.test')
  on conflict (user_id) do nothing;

  create temp table _k (k text primary key, v uuid);
  insert into _k values ('a', a), ('b', b);
end
$seed$;

do $grant$
begin
  execute format('grant usage on schema %I to authenticated',
                 (select nspname from pg_namespace n
                   join pg_class c on c.relnamespace = n.oid
                  where c.relname = '_k' and n.nspname like 'pg_temp%'));
  execute 'grant select on _k to authenticated';
end
$grant$;

-- The whole file runs as `authenticated`. A superuser is exempt from RLS and
-- from nothing else that matters here, and every refusal below would pass for
-- the wrong reason without this.
set local role authenticated;

-- =============================================================================
-- 1. Rule 1 - the check answers for the platform and points only at home
-- =============================================================================
select set_config('test.uid', '00000000-0000-0000-0000-00000000a001', true);

select pg_temp.ok(
  (pg_temp.verdict('brand-new@keys.test')->>'available')::boolean
  and pg_temp.verdict('brand-new@keys.test')->>'why' = 'available',
  '1. an address nobody has is free');

select pg_temp.ok(
  not (pg_temp.verdict('teachera@keys.test')->>'available')::boolean
  and pg_temp.verdict('teachera@keys.test')->>'why' = 'in_use_here'
  and pg_temp.verdict('teachera@keys.test')->>'message' like '%Teacher A%'
  and pg_temp.verdict('teachera@keys.test')->>'message' like '%class teacher%',
  '2. an address inside the caller''s OWN school is named in full: who they are '
  || 'and what they can do, because that ends the question where "taken" starts '
  || 'an argument');

select pg_temp.ok(
  not (pg_temp.verdict('teacherb@keys.test')->>'available')::boolean
  and pg_temp.verdict('teacherb@keys.test')->>'why' = 'in_use_elsewhere'
  and pg_temp.verdict('teacherb@keys.test')->>'message' not like '%Teacher B%'
  and pg_temp.verdict('teacherb@keys.test')->>'message' not like '%Keys B%'
  and pg_temp.verdict('teacherb@keys.test')->>'message' not like '%class teacher%'
  and pg_temp.verdict('teacherb@keys.test')->'here' is null,
  '3. THE DISCLOSURE BOUNDARY. An address at ANOTHER school is refused with no '
  || 'school, no name and no role, so a school cannot learn that a particular '
  || 'teacher has an account at a particular competitor');

select pg_temp.ok(
  not (pg_temp.verdict('not-an-address')->>'available')::boolean
  and pg_temp.verdict('not-an-address')->>'why' = 'not_an_address',
  '4. nonsense is called nonsense rather than reported free');

-- Case and whitespace. The office types with a capital and a trailing space.
select pg_temp.ok(
  pg_temp.verdict('  TeacherA@Keys.Test  ')->>'why' = 'in_use_here',
  '5. matched folded and trimmed, so a capital letter does not report a taken '
  || 'address as free');

-- =============================================================================
-- 2. Rule 2 - a live invitation is a clash too
-- =============================================================================
reset role;
do $inv$
declare a uuid := (select v from _k where k = 'a');
        b uuid := (select v from _k where k = 'b');
begin
  insert into public.user_invites (school_id, email, role, full_name) values
    (a, 'invited-here@keys.test',  'class_teacher', 'Here'),
    (b, 'invited-there@keys.test', 'class_teacher', 'There'),
    -- Expired, so it must NOT count. An invitation that can never be redeemed
    -- blocking an address for ever is a slow leak of the address space.
    (a, 'expired@keys.test', 'class_teacher', 'Stale');
  update public.user_invites set expires_at = now() - interval '1 day'
   where email = 'expired@keys.test';
end
$inv$;
set local role authenticated;
select set_config('test.uid', '00000000-0000-0000-0000-00000000a001', true);

select pg_temp.ok(
  pg_temp.verdict('invited-here@keys.test')->>'why' = 'invited_here'
  and pg_temp.verdict('invited-here@keys.test')->>'message' like '%already invited%',
  '6. an address this school has already invited says so, which stops it '
  || 'issuing a second invitation to the same address');

select pg_temp.ok(
  pg_temp.verdict('invited-there@keys.test')->>'why' = 'invited_elsewhere'
  and pg_temp.verdict('invited-there@keys.test')->>'message' not like '%Keys B%',
  '7. an address ANOTHER school has invited is refused too, and this one '
  || 'prevents a silent failure: two live invitations for one address create no '
  || 'profile at all, so both schools would believe they had a teacher who '
  || 'could see nothing');

select pg_temp.ok(
  (pg_temp.verdict('expired@keys.test')->>'available')::boolean,
  '8. an EXPIRED invitation blocks nothing, or a mistyped invitation would '
  || 'reserve an address for ever');

-- =============================================================================
-- 3. Rule 3 - only an owner or principal may ask
-- =============================================================================
select pg_temp.ok(
  (select set_config('test.uid', '00000000-0000-0000-0000-00000000a002', true) is not null)
  and pg_temp.verdict('teachera@keys.test')->>'why' = 'in_use_here',
  '9. a principal may ask');

select set_config('test.uid', '00000000-0000-0000-0000-00000000a003', true);
select pg_temp.ok(
  pg_temp.raises('select public.fn_login_email_available(''x@y.test'')',
                 'only the owner or principal'),
  '10. a clerk may not. They can create a login and they cannot enumerate the '
  || 'platform''s addresses, and those are different privileges');

select set_config('test.uid', '00000000-0000-0000-0000-00000000a005', true);
select pg_temp.ok(
  pg_temp.raises('select public.fn_login_email_available(''x@y.test'')',
                 'only the owner or principal'),
  '11. and a PARENT certainly may not');

-- =============================================================================
-- 4. Rule 4 - the ring is unreachable except through its functions
-- =============================================================================
select pg_temp.ok(
  not has_table_privilege('authenticated', 'public.login_secrets', 'select')
  and not has_table_privilege('authenticated', 'public.login_secrets', 'insert')
  and not has_table_privilege('authenticated', 'public.login_secrets', 'update')
  and not has_table_privilege('authenticated', 'public.login_secrets', 'delete')
  and not has_table_privilege('anon', 'public.login_secrets', 'select'),
  '12. login_secrets is not selectable, insertable, updatable or deletable by '
  || 'anon or authenticated. Supabase grants the client roles on new tables in '
  || 'public by default, so this is the assertion that the revoke actually ran');

select pg_temp.ok(
  (select relrowsecurity and relforcerowsecurity
     from pg_class where oid = 'public.login_secrets'::regclass)
  and (select count(*) = 0 from pg_policies
        where schemaname = 'public' and tablename = 'login_secrets'),
  '13. RLS is on and FORCED and there is not one policy, so there is no query '
  || 'any client can write that reaches it');

-- =============================================================================
-- 5. Rule 11 - no school_id column, so our own export cannot see it
--
-- ASSERTED AGAINST THE FUNCTION THAT DRIVES THE EXPORT, not against the column
-- list, because the column is only the mechanism. fn__school_data_tables()
-- finds tables BY having a school_id, and fn_platform_export_table reads every
-- table it returns. A school_id here would have put every school's assigned
-- passwords into an export WE can take.
-- =============================================================================
reset role;
select pg_temp.ok(
  not exists (select 1 from public.fn__school_data_tables() t
               where t.table_name = 'login_secrets'),
  '14. THE ONE THAT KEEPS US OUT. login_secrets is not in the vendor''s '
  || 'offboarding export, because it has no school_id column and that is what '
  || 'the export enumerates on');
set local role authenticated;

-- =============================================================================
-- 6. Rules 5, 6, 7 - who may write to the ring, and about whom
-- =============================================================================
select set_config('test.uid', '00000000-0000-0000-0000-00000000a001', true);

select pg_temp.ok(
  (public.fn_remember_login_password(
     '00000000-0000-0000-0000-00000000a004', 'teach-me-1')->>'saved')::boolean,
  '15. an owner may save the password they chose for their own teacher');

select pg_temp.ok(
  pg_temp.raises(
    'select public.fn_remember_login_password('
    || '''00000000-0000-0000-0000-00000000a001'', ''hunter2'')',
    'owner'),
  '16. AN OWNER''S OWN PASSWORD IS NEVER SAVED. One leaked owner credential is '
  || 'the whole school; one leaked parent credential is one family, and an '
  || 'owner has a real address with working recovery');

select pg_temp.ok(
  pg_temp.raises(
    'select public.fn_remember_login_password('
    || '''00000000-0000-0000-0000-00000000b002'', ''hunter2'')',
    'not in your school'),
  '17. and never for a login at another school');

select set_config('test.uid', '00000000-0000-0000-0000-00000000a006', true);
select pg_temp.ok(
  pg_temp.raises(
    'select public.fn_remember_login_password('
    || '''00000000-0000-0000-0000-00000000a004'', ''x'')',
    'only the owner or principal'),
  '18. an OBSERVER cannot write to the ring. readonly exists to look at '
  || 'everything and change nothing, and a stored credential is a change '
  || 'waiting to happen');

select set_config('test.uid', '00000000-0000-0000-0000-00000000a003', true);
select pg_temp.ok(
  pg_temp.raises('select public.fn_school_key_ring()', 'only the owner or principal')
  and pg_temp.raises(
    'select public.fn_reveal_login_password('
    || '''00000000-0000-0000-0000-00000000a004'')', 'only the owner or principal'),
  '19. nor can a clerk read it, in either direction');

-- =============================================================================
-- 7. Rule 8 - not the operator, even inside a support visit
--
-- THE POINT OF THIS ASSERTION. current_school_id(), is_staff() and may_view()
-- have all honoured an open operator session since 0074, which is how we help a
-- school over the telephone. So the operator DOES get a school here. What they
-- must not get is has_role(), and these four functions ask for nothing else.
-- =============================================================================
reset role;
do $enter$
declare a uuid := (select v from _k where k = 'a');
begin
  perform set_config('test.uid', '00000000-0000-0000-0000-0000000000ff', true);
  perform public.fn_operator_enter(a, 'Owner rang about a parent login');
end
$enter$;
set local role authenticated;
select set_config('test.uid', '00000000-0000-0000-0000-0000000000ff', true);

select pg_temp.ok(
  public.current_school_id() = (select v from _k where k = 'a'),
  '20. the operator IS inside the school, so the assertions below are about '
  || 'has_role and not about an operator who never got in');

select pg_temp.ok(
  pg_temp.raises('select public.fn_school_key_ring()', 'only the owner or principal')
  and pg_temp.raises(
    'select public.fn_reveal_login_password('
    || '''00000000-0000-0000-0000-00000000a004'')', 'only the owner or principal')
  and pg_temp.raises(
    'select public.fn_remember_login_password('
    || '''00000000-0000-0000-0000-00000000a004'', ''x'')', 'only the owner or principal')
  and pg_temp.raises(
    'select public.fn_forget_login_password('
    || '''00000000-0000-0000-0000-00000000a004'')', 'only the owner or principal'),
  '21. AND THE VENDOR IS REFUSED ALL FOUR. A support visit can read a school''s '
  || 'records to help them; it cannot read the passwords they gave their '
  || 'parents');

reset role;
select set_config('test.uid', '00000000-0000-0000-0000-0000000000ff', true);
select public.fn_operator_leave();
set local role authenticated;

-- =============================================================================
-- 8. Rules 9 and 10 - stale says so, and every reveal is counted
-- =============================================================================
select set_config('test.uid', '00000000-0000-0000-0000-00000000a001', true);

select pg_temp.ok(
  (select has_password and not changed_since and reads = 0
     from public.fn_school_key_ring() where profile_id = '00000000-0000-0000-0000-00000000a004'),
  '22. a freshly saved password reads as saved, current, and never looked at');

select pg_temp.ok(
  public.fn_reveal_login_password('00000000-0000-0000-0000-00000000a004')->>'password'
    = 'teach-me-1',
  '23. and comes back exactly as it was typed');

select pg_temp.ok(
  (select reads = 1 and read_by_name = 'Owner A' and read_at is not null
     from public.fn_school_key_ring() where profile_id = '00000000-0000-0000-0000-00000000a004'),
  '24. counted, with the name of whoever looked, on the same screen they looked '
  || 'from. A principal reading forty parent passwords leaves a trace their '
  || 'owner can see');

-- The parent changes their own password from inside the portal. Nothing
-- server-side sees the value, so the fingerprint is the only way to know.
reset role;
update auth.users set encrypted_password = '$2a$10$parentchangeditthemselves'
 where id = '00000000-0000-0000-0000-00000000a004';
set local role authenticated;
select set_config('test.uid', '00000000-0000-0000-0000-00000000a001', true);

select pg_temp.ok(
  (select changed_since
     from public.fn_school_key_ring() where profile_id = '00000000-0000-0000-0000-00000000a004'),
  '25. once that person changes their own password the row says so. Handing out '
  || 'a password that silently stopped working is worse than not keeping one: '
  || 'the office reads it down the telephone, it fails, and the feature is '
  || 'never trusted again');

select pg_temp.ok(
  (public.fn_reveal_login_password(
     '00000000-0000-0000-0000-00000000a004')->>'changed_since')::boolean,
  '26. and the reveal says so too, so it cannot be read out of context');

-- Saving a new one clears the read count: it belongs to the password that was
-- read, not to this one.
do $again$
begin
  perform public.fn_remember_login_password(
    '00000000-0000-0000-0000-00000000a004', 'teach-me-2');
  perform pg_temp.ok(
    (select reads = 0 and not changed_since and read_by_name is null
       from public.fn_school_key_ring()
      where profile_id = '00000000-0000-0000-0000-00000000a004'),
    '27. a new password resets the count and clears the stale flag, so "nobody '
    || 'has looked at this" stays true of the password it describes');
end
$again$;

-- =============================================================================
-- 9. Reading and forgetting, and the refusals that must not leak
-- =============================================================================
select pg_temp.ok(
  pg_temp.raises(
    'select public.fn_reveal_login_password('
    || '''00000000-0000-0000-0000-00000000b002'')', 'no saved password'),
  '28. asking for another school''s login says only "no saved password". The '
  || 'same words as "there is none" and "that is an owner", so this cannot be '
  || 'used to ask whether a given id is a login somewhere else');

select pg_temp.ok(
  pg_temp.raises(
    'select public.fn_reveal_login_password('
    || '''00000000-0000-0000-0000-00000000a005'')', 'no saved password'),
  '29. and a login with nothing saved for it refuses in the same words');

-- A DO BLOCK, NOT ONE `and`. The first draft was
--
--     pg_temp.ok(fn_forget(...)->>'forgotten' and (select not has_password ...))
--
-- and it failed while the function was working perfectly: Postgres is free to
-- evaluate the right operand of AND first, so the ring was read BEFORE the
-- delete ran and reported the password still there. Sequential statements are
-- the only way to assert a before and an after.
do $forget$
begin
  perform pg_temp.ok(
    (public.fn_forget_login_password(
       '00000000-0000-0000-0000-00000000a004')->>'forgotten')::boolean,
    '30. the office can take one off the ring. A feature that can only ever '
    || 'accumulate credentials is one nobody can change their mind about');
  perform pg_temp.ok(
    (select not has_password from public.fn_school_key_ring()
      where profile_id = '00000000-0000-0000-0000-00000000a004'),
    '31. and the ring says so afterwards');
  perform pg_temp.ok(
    not (public.fn_forget_login_password(
       '00000000-0000-0000-0000-00000000b002')->>'forgotten')::boolean,
    '32. forgetting another school''s login does nothing at all rather than '
    || 'reporting success');
end
$forget$;

-- =============================================================================
-- 10. The ring's shape
-- =============================================================================
select pg_temp.ok(
  not exists (select 1 from public.fn_school_key_ring() where role = 'owner'),
  '33. the owner is not on the ring, so their row is not a permanent "no '
  || 'password saved" inviting somebody to fix it');

select pg_temp.ok(
  (select count(*) = 5 from public.fn_school_key_ring()),
  '34. and everybody else in the school is, whether or not they have a password '
  || 'saved, because "who could I set a password for" is the question the '
  || 'screen is opened to ask');

select pg_temp.ok(
  not exists (select 1 from public.fn_school_key_ring() r
               join public.profiles p on p.id = r.profile_id
              where p.school_id <> (select v from _k where k = 'a')),
  '35. and nobody from another school is on it');

reset role;
rollback;

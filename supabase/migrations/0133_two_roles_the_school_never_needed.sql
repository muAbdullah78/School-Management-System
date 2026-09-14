-- =============================================================================
-- 0133  Two roles the school never needed
--
-- -----------------------------------------------------------------------------
-- WHAT IS BEING REMOVED, AND WHY IT IS NOT A FEATURE CUT
--
-- The role list was designed for a large institution: owner, principal,
-- ADMIN/CLERK, ACCOUNTANT, class teacher, subject teacher, read only, parent.
-- Eight roles, of which two exist purely to split the office in half.
--
-- That split is a real idea and it is the wrong one for this market. These are
-- private schools of two to six hundred pupils. The office is a room with a
-- desk in it. The principal collects the fee, signs the receipt, admits the
-- child and reconciles the day, and when the work is too much for one person
-- the answer is a SECOND PRINCIPAL LOGIN, not a different kind of account with
-- a different set of buttons missing.
--
-- Eight roles in a dropdown for a school that needs three is not neutral. It is
-- a question the buyer cannot answer, asked at the moment they are setting up
-- the software, and getting it wrong is silent: the clerk they created cannot
-- unlock a register and nobody finds out until a Thursday.
--
-- What is left is what a school of this size actually has:
--
--   owner            the account signup created. Holds the subscription.
--   principal        the head, and anyone the head trusts with the office.
--   class_teacher    marks the daily register for their class.
--   subject_teacher  marks their own subject.
--   readonly         sees everything, changes nothing.
--   parent           the portal. Not staff, and never has been.
--
-- -----------------------------------------------------------------------------
-- WHERE THE EXISTING CLERKS AND ACCOUNTANTS GO: PRINCIPAL, NOT READ ONLY
--
-- This is the decision in this file that could hurt somebody, so it is the one
-- stated plainly.
--
-- Fifty-two functions in this database let exactly four roles take money:
-- owner, principal, admin_clerk, accountant. fn_record_payment, fn_open_till,
-- fn_verify_payment, fn_apply_fine, fn_add_discount, the receipt numbering,
-- the day's reconciliation. If a live school has a clerk sitting at the fee
-- counter this morning, moving that person to 'readonly' means that at the
-- moment the school pastes this bundle, the person taking money at the window
-- cannot take money any more. No warning, no error anybody could act on, just
-- a Save button that is gone. On the first of the month, with a queue.
--
-- Read only is the tidier answer and it is the one that breaks a school.
--
-- So they become PRINCIPAL, which is precisely the account the school would
-- have created for them if this list had been three roles long from the start.
-- The person keeps their login, their password and their job. What they gain is
-- approval rights they did not have: waiving a fine, voiding a receipt,
-- unlocking a register. That is a real widening and it is the smaller harm, and
-- it is what the school asked for: one kind of office account, as many as you
-- need.
--
-- The migration REPORTS every account it moved, by email, so the school can see
-- who now has those rights and demote anybody it would rather not.
--
-- -----------------------------------------------------------------------------
-- WHY THE ENUM VALUES SURVIVE, WHICH LOOKS LIKE A HALF MEASURE AND IS NOT
--
-- Postgres cannot remove a value from an enum. There is no DROP VALUE. The only
-- route is to build a new type, rewrite every column, every function signature
-- and every default that mentions the old one, and drop it -- and 266 lines
-- across 60 SHIPPED migrations name 'admin_clerk' or 'accountant' inside
-- has_role() lists. Those files are frozen. A school that re-pastes bundle 4
-- after this would hit a type that no longer exists, and because a bundle is
-- one transaction, the whole bundle rolls back.
--
-- The cost of leaving the values in place is zero, because a value no row can
-- hold and no function can be given is not reachable. has_role('owner',
-- 'principal','admin_clerk','accountant') in a frozen file keeps working and
-- keeps meaning "owner or principal", because after this migration nobody is
-- the other two. The check constraint is the thing that makes that true, and it
-- is one line rather than a type rewrite across a decade of files.
--
-- -----------------------------------------------------------------------------
-- FOUR DOORS A RETIRED ROLE COULD COME BACK THROUGH, AND ALL FOUR ARE SHUT
--
--   1. profiles.role          -- the constraint below
--   2. user_invites.role      -- the constraint below. An invite is a promise
--                                about a role that is redeemed later, possibly
--                                after this migration ran, so the pending ones
--                                are rewritten too, not just refused.
--   3. guard_profile_role()   -- the trigger that already polices role changes
--                                now refuses these two BY NAME, so the Users
--                                screen says something a person can act on
--                                rather than reporting a constraint violation
--   4. fn_invite_user()       -- same, at the point of asking
--
-- The constraints are the enforcement. The two functions exist so the error is
-- a sentence instead of 'new row for relation "profiles" violates check
-- constraint "profiles_role_live_chk"'.
-- =============================================================================

-- ---------------------------------------------------------------- migrate ---
-- THE GUARD COMES OFF FIRST, AND THIS ORDER IS THE WHOLE POINT OF THIS BLOCK.
--
-- 0001 put a trigger on profiles that refuses any role change unless
-- has_role('owner','principal'). has_role reads auth.uid(), and auth.uid() is
-- NULL in the SQL Editor, because a pasted migration is not a signed-in
-- session. So the migration's own UPDATE below is refused by the school's own
-- privilege-escalation guard:
--
--     ERROR:  Only an owner or principal may change a role
--     CONTEXT:  PL/pgSQL function guard_profile_role() line 5 at RAISE
--
-- On a fresh database that never happens, because there is no clerk to move.
-- It happens on exactly the databases this migration exists for: the live ones
-- with somebody at the fee counter. And a bundle is ONE transaction, so the
-- failure would not just skip this migration, it would roll back every
-- migration pasted with it, and the school would be told "already exists" if
-- they tried again.
--
-- Dropped rather than disabled because it is recreated at the bottom of this
-- file anyway, with INSERT added to its event list. Two statements instead of
-- four, and no window where the trigger exists but does nothing.
drop trigger if exists trg_profiles_role_guard on public.profiles;

do $$
declare
  v_moved  int;
  v_who    text;
begin
  select count(*), string_agg(coalesce(u.email, p.id::text), ', ' order by u.email)
    into v_moved, v_who
    from public.profiles p
    left join auth.users u on u.id = p.id
   where p.role in ('admin_clerk', 'accountant');

  if v_moved > 0 then
    update public.profiles
       set role = 'principal'
     where role in ('admin_clerk', 'accountant');

    -- Named, not counted. "3 accounts were changed" is not something a school
    -- can act on; three email addresses is.
    raise notice 'Moved % office account(s) to Principal: %', v_moved, v_who;
    raise notice 'They keep every right they had, and gain approval rights '
                 '(waive a fine, void a receipt, unlock a register). Demote '
                 'anyone who should not have those on Settings then Users.';
  end if;
end
$$;

-- Pending invitations carry a role that is redeemed LATER. One created
-- yesterday for a clerk would otherwise hand out a retired role tomorrow, and
-- refusing it at redemption would strand a person who was told to expect a
-- login. Rewritten to match what the account would have become anyway.
update public.user_invites
   set role = 'principal'
 where role in ('admin_clerk', 'accountant')
   and accepted_at is null;

-- ------------------------------------------------------------- constraints --
do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'profiles_role_live_chk') then
    alter table public.profiles add constraint profiles_role_live_chk
      check (role not in ('admin_clerk', 'accountant'));
  end if;
  if not exists (select 1 from pg_constraint where conname = 'user_invites_role_live_chk') then
    -- PENDING INVITATIONS ONLY, and the `accepted_at is not null` escape is not
    -- a loophole.
    --
    -- user_invites is an audit trail as well as a queue: a redeemed row records
    -- that on some Tuesday the head offered this address the Accountant role,
    -- and somebody accepted. Rewriting that to 'principal' would make the trail
    -- say something that did not happen, and a flat constraint would REFUSE TO
    -- BE ADDED AT ALL on any school that ever invited a clerk, which is the
    -- population this migration is for.
    --
    -- Nothing escapes through it. Every invitation is created pending, so a new
    -- one is covered; and redeeming one creates a PROFILE, which the constraint
    -- above refuses outright.
    alter table public.user_invites add constraint user_invites_role_live_chk
      check (accepted_at is not null or role not in ('admin_clerk', 'accountant'));
  end if;
end
$$;

-- ------------------------------------------------------------------ guard ---
-- The existing trigger from 0001, plus the two retired roles.
--
-- REPLACED WHOLE rather than wrapped, because it is a trigger function and
-- there is exactly one of it. The privilege-escalation rule it already carried
-- is reproduced below unchanged; read the two together as one policy on who may
-- hold what.
create or replace function public.guard_profile_role() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'UPDATE' and new.role is distinct from old.role then
    if not public.has_role('owner', 'principal') then
      raise exception 'Only an owner or principal may change a role'
        using errcode = '42501';
    end if;
  end if;

  -- Said in words, because this is what a school sees if it has an old tab
  -- open, or a bookmarked screen, or a browser that cached the page from
  -- before the update. The constraint would refuse it too; it would just
  -- refuse it in a language nobody at a school reads.
  if new.role in ('admin_clerk', 'accountant') then
    raise exception 'The Admin / Clerk and Accountant roles have been '
                    'withdrawn. Use Principal / Headmaster for office staff, '
                    'or Read only for someone who should see and not change.'
      using errcode = '22023';
  end if;

  return new;
end;
$$;

-- Put back, with INSERT added to its event list.
--
-- 0001 created it for UPDATE only, so a profile INSERTED with a retired role
-- would have walked past the guard and been caught by the constraint instead,
-- reporting 'new row for relation "profiles" violates check constraint
-- "profiles_role_live_chk"' to somebody who wanted to know which role to pick.
--
-- `drop trigger if exists` again above this, and not only at the top of the
-- file: `create trigger` has no `if not exists`, so re-pasting this bundle
-- would fail here, and a bundle is one transaction.
drop trigger if exists trg_profiles_role_guard on public.profiles;
create trigger trg_profiles_role_guard
  before insert or update on public.profiles
  for each row execute function public.guard_profile_role();

-- ----------------------------------------------------------------- invite ---
-- fn_invite_user, with the same body plus one refusal. Replaced rather than
-- extended for the same reason as the trigger: there is one of it, and the
-- alternative is a second function that the Users screen would have to be
-- taught to call.
create or replace function public.fn_invite_user(
  p_email text,
  p_role public.user_role,
  p_full_name text default null
) returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_school uuid := public.current_school_id();
  v_email  text := lower(btrim(coalesce(p_email, '')));
  v_id     uuid;
begin
  if not public.has_role('owner','principal') then
    raise exception 'Only an owner or principal may invite a user'
      using errcode = '42501';
  end if;
  if v_email = '' or position('@' in v_email) = 0 then
    raise exception 'A valid email address is required';
  end if;
  if p_role = 'owner' then
    raise exception 'An owner cannot be invited. Create the account with '
                    'another role, then promote it on the Users screen.';
  end if;
  if p_role in ('admin_clerk', 'accountant') then
    raise exception 'The Admin / Clerk and Accountant roles have been '
                    'withdrawn. Use Principal / Headmaster for office staff, '
                    'or Read only for someone who should see and not change.'
      using errcode = '22023';
  end if;

  -- Somebody already signed in with this address. Inviting them again would
  -- create a second profile for one person, which is how a school ends up with
  -- two logins for the same teacher and no idea which is live.
  if exists (select 1 from auth.users u
              join public.profiles p on p.id = u.id
             where lower(btrim(u.email)) = v_email and p.school_id = v_school) then
    raise exception '% already has a login at this school', v_email;
  end if;

  insert into public.user_invites (school_id, email, role, full_name, created_by)
  values (v_school, v_email, p_role,
          nullif(btrim(coalesce(p_full_name, '')), ''), auth.uid())
  on conflict (school_id, email) where accepted_at is null
    do update set role       = excluded.role,
                  full_name  = excluded.full_name,
                  created_by = excluded.created_by,
                  created_at = now(),
                  expires_at = now() + interval '7 days'
  returning id into v_id;

  insert into public.audit_log(school_id, actor, action, entity, entity_id, after)
  values (v_school, auth.uid(), 'user_invited', 'user_invites', v_id::text,
          jsonb_build_object('email', v_email, 'role', p_role));

  return jsonb_build_object('id', v_id, 'email', v_email, 'role', p_role,
                            'expires_at', now() + interval '7 days');
end;
$$;

-- ------------------------------------------------------------------- live ---
-- The one list of roles a school may hand out, readable by the app so the
-- dropdown and the database cannot disagree about it. Same reasoning as
-- fn_signup_regions in 0132: a second copy in TypeScript is a second thing to
-- forget.
--
-- 'owner' is NOT in it, and that is not an oversight. Exactly one owner exists
-- per school, created by signup, and it is where the subscription and the
-- billing screens hang. There is no circumstance in which a school hands the
-- role out from a dropdown, and 0065 has refused to invite one since it was
-- written.
create or replace function public.fn_assignable_roles()
returns public.user_role[] language sql immutable set search_path = public as $$
  select array['principal', 'class_teacher', 'subject_teacher',
               'readonly', 'parent']::public.user_role[];
$$;
-- Revoked from public and anon FIRST. Postgres grants EXECUTE to PUBLIC on
-- every new function, and `anon` is the role a request carries when it holds
-- only the anonymous key, which ships inside the browser bundle.
revoke all on function public.fn_assignable_roles() from public, anon;
grant execute on function public.fn_assignable_roles() to authenticated;

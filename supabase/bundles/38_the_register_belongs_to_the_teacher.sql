-- =============================================================================
-- GENERATED FILE — DO NOT EDIT.
-- Built from supabase/migrations/ by supabase/build-bundles.sh
--
-- Paste this whole file into the Supabase SQL Editor and press Run.
-- Run the bundles in order, one at a time, waiting for each to finish.
-- =============================================================================


-- ─────────────────────────────────────────────────────────────────────────
-- 0133_two_roles_the_school_never_needed.sql
-- ─────────────────────────────────────────────────────────────────────────
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

-- ─────────────────────────────────────────────────────────────────────────
-- 0134_the_register_belongs_to_the_teacher.sql
-- ─────────────────────────────────────────────────────────────────────────
-- =============================================================================
-- 0134  The register belongs to the teacher, and the head reads it
--
-- -----------------------------------------------------------------------------
-- WHAT WAS WRONG
--
-- A principal could mark attendance. Not correct it, not reopen it: MARK it,
-- from an empty register, exactly as the class teacher would.
--
-- That is not a permissions detail, it is the register losing its meaning. The
-- daily register is a statement by the person who stood in front of the class
-- and looked. When the head can also make that statement, nothing on the
-- record distinguishes "the teacher marked Bilal absent" from "the office
-- decided Bilal was absent", and the attendance percentage that ends up on a
-- result card, on the parent portal and in a fee decision is no longer
-- evidence of anything.
--
-- It also made the head's screen useless for the job the head actually has.
-- A principal opening Attendance got a class picker and a list of pupils: a
-- tool for marking one section. What a head needs at 9.40am is the opposite
-- shape. Which classes have marked? Which have not? Which said they were done
-- and never locked it? That question could not be asked of this software at
-- all, by anybody, in one screen.
--
-- -----------------------------------------------------------------------------
-- WHO MAY WRITE A REGISTER AFTER THIS
--
--   class_teacher    yes, for their class. The daily register is theirs.
--   subject_teacher  yes, for the classes they are assigned to.
--   principal        NO.
--   readonly         no, and never could.
--   owner            yes, and this is deliberate. See below.
--
-- THE OWNER IS LEFT ALONE ON PURPOSE, and it is the one loose thread in this
-- file, so it is stated rather than hidden.
--
-- 'owner' is not a job title, it is the account signup created: it holds the
-- subscription and the billing screens, and there is exactly one per school.
-- In a school of this size the head usually holds it, which means a head who
-- wants to mark a register can still do so by signing in as the owner. The
-- school's own instruction for a teacher who is off sick is to hand their
-- login to somebody else for the day, so an escape hatch of this kind is in
-- keeping with how these schools work, and closing it would mean a school with
-- one account and nobody able to mark.
--
-- No SCREEN offers it. The attendance page gives the owner the same oversight
-- dashboard as the principal, with marking one deliberate click away. If that
-- turns out to be too loose, the fix is to delete 'owner' from
-- fn_may_write_register below and from nothing else.
--
-- -----------------------------------------------------------------------------
-- WHAT THE PRINCIPAL KEEPS, WHICH IS THE POINT OF THE WHOLE CHANGE
--
--   * fn_unlock_attendance (0121). Reopening a finalised day is an APPROVAL,
--     not a marking. A child marked absent by mistake stays absent on every
--     result card ever printed unless somebody senior can reopen the day, and
--     that somebody is the head. Unchanged.
--   * Reading every register in the school, which they always had.
--   * fn_attendance_day, below, which is new and is the screen they never had.
--
-- -----------------------------------------------------------------------------
-- SUBJECT ATTENDANCE, AND WHY IT IS A SEPARATE AND DELIBERATELY WEAKER THING
--
-- The second half of this file adds a register a SUBJECT teacher may keep for
-- their own subject. It is optional, it is not locked, it is not finalised, it
-- does not feed the attendance percentage, and nothing anywhere asks for it.
--
-- Every one of those is a decision, not an omission. The daily register is the
-- school's legal record of who was present; making a second register that
-- behaves like it would mean two answers to one question, which is the exact
-- failure 0097 and 0100 were written to end. This one answers a different
-- question, for one reader: the head, wondering whether the children who were
-- in school at 8am were still in the chemistry lab at 11.
--
-- So a subject that nobody marked is NOT shown as outstanding, anywhere. There
-- is no "not done" for subject attendance, because nobody was ever asked to do
-- it. A panel listing forty unmarked subjects every morning would train the
-- head to ignore the screen that also tells them a class register is missing.
-- =============================================================================

-- ================================================= who may write a register ==
-- ONE predicate, named, called from the two functions and the two policies
-- that decide this. It used to be the same list of five roles written out in
-- four places, which is how three of them get updated.
--
-- NAMED fn_may_ AND NOT fn__, which is not a style choice. An fn__ helper is
-- revoked from `authenticated` by convention and by a guard, and a predicate
-- used inside a row-level policy is evaluated AS THE QUERYING USER: revoked,
-- it would make every insert into attendance_daily fail with a permission
-- error on the helper rather than a refusal from the policy. It sits with
-- fn_may_manage_class and fn_may_mark_subject, which are the same kind of
-- thing for the same reason.
create or replace function public.fn_may_write_register()
returns boolean language sql stable security definer set search_path = public as $$
  select public.has_role('owner', 'class_teacher', 'subject_teacher');
$$;

-- Revoked from anon and granted to authenticated explicitly: Postgres grants
-- EXECUTE to PUBLIC on every new function, and anon is the role a request
-- carries when it holds only the anonymous key from the browser bundle. The
-- grant to authenticated is required, not optional: this runs inside row-level
-- policies, which are evaluated as the querying user.
revoke all on function public.fn_may_write_register() from public, anon;
grant execute on function public.fn_may_write_register() to authenticated;

comment on function public.fn_may_write_register() is
  'Who may mark or finalise a daily register. The principal is deliberately '
  'absent: the register is a statement by the person who stood in front of '
  'the class. See 0134.';

-- fn_mark_attendance, byte for byte as 0130 left it apart from the two role
-- guards. Reproduced whole rather than patched because there is one of it and
-- a reader needs to see the order the checks run in.
create or replace function public.fn_mark_attendance(
  p_date date, p_marks jsonb, p_reason text default null
) returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_actor  uuid := auth.uid();
  v_total  integer;
  v_marked integer;
  v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
begin
  if not public.fn_may_write_register() then
    raise exception 'The daily register is marked by the class teacher. A '
                    'principal can read it, and can reopen a finalised day, '
                    'but cannot mark it.'
      using errcode = '42501';
  end if;
  perform public.fn__only_these_keys(p_marks, '{enrollment_id,status}'::text[], 'Attendance marking');
  if p_marks is null or jsonb_typeof(p_marks) <> 'array' then
    raise exception 'p_marks must be a JSON array';
  end if;

  -- Tenant scope: every enrolment must be in THIS school. Checked for all
  -- roles, because the teacher-scope check below is skipped for the owner,
  -- leaving them able to mark attendance against another school's enrolment ids.
  if exists (
    select 1 from jsonb_array_elements(p_marks) e
    where not exists (
      select 1 from public.enrollments en
      where en.id = (e->>'enrollment_id')::uuid
        and en.school_id = public.current_school_id()
    )
  ) then
    raise exception 'Unknown enrolment in this school' using errcode = '42501';
  end if;

  -- The owner is the only role left that is not scoped to an assignment, and
  -- it is the only one that ever was other than the two now removed.
  if not public.has_role('owner') then
    if exists (
      select 1 from jsonb_array_elements(p_marks) e
      join public.enrollments en on en.id = (e->>'enrollment_id')::uuid
      where not public.fn_may_manage_class(en.session_id, en.class_id, en.section_id)
    ) then
      raise exception 'You can only mark attendance for your assigned class';
    end if;
  end if;

  -- THE DATE (0130). Nothing bounded it: two calls put a school's
  -- register between 1900 and 2099. Two rules, both about a person
  -- mistyping a year rather than about an attacker.
  --
  -- Pakistan time for "today", the same expression fn_set_staff_attendance
  -- uses, because the two must agree about which day it is: from midnight
  -- to 5am in Karachi, UTC still says yesterday.
  if p_date > (now() at time zone 'Asia/Karachi')::date then
    raise exception 'Attendance cannot be marked for %, which has not '
      'happened yet.', to_char(p_date, 'DD Mon YYYY')
      using errcode = '22008';
  end if;
  -- And inside the academic year the enrolment belongs to. Checked per
  -- session rather than against the CURRENT one, because reopening last
  -- year's register to correct it is a thing fn_unlock_attendance exists
  -- to allow.
  perform public.fn__assert_date_in_session(en.session_id, p_date,
            'Marking attendance')
    from public.enrollments en
   where en.id in (select (e->>'enrollment_id')::uuid
                     from jsonb_array_elements(p_marks) e)
     and en.school_id = public.current_school_id();

  select count(distinct (e->>'enrollment_id')) into v_total
  from jsonb_array_elements(p_marks) e;

  with input as (
    select distinct on (enrollment_id) enrollment_id, status
    from (
      select (e->>'enrollment_id')::uuid as enrollment_id,
             (e->>'status')::public.attendance_status as status
      from jsonb_array_elements(p_marks) e
    ) q
    order by enrollment_id
  ),
  upserted as (
    insert into public.attendance_daily as ad
      (enrollment_id, attendance_date, status, marked_by)
    select enrollment_id, p_date, status, v_actor from input
    on conflict (enrollment_id, attendance_date) do update
      set status = excluded.status,
          marked_by = excluded.marked_by,
          corrected_from = case when ad.status is distinct from excluded.status
                                then ad.status else ad.corrected_from end,
          correction_reason = case when ad.status is distinct from excluded.status
                                   then v_reason else ad.correction_reason end
      where not ad.is_locked
    returning 1
  )
  select count(*) into v_marked from upserted;

  return jsonb_build_object('marked', v_marked, 'skipped', v_total - v_marked, 'total', v_total);
end;
$$;

-- Finalising is CLOSING YOUR OWN REGISTER, not an approval of somebody else's,
-- so it moves with marking. A principal who could finalise could lock a class
-- as complete at 9.00 with three pupils marked, and the class teacher would
-- then need the principal again to reopen what the principal shut.
create or replace function public.fn_finalize_attendance(
  p_session_id uuid, p_class_id uuid, p_section_id uuid, p_date date
) returns integer language plpgsql security definer set search_path = public as $$
declare v_count integer;
begin
  if not public.fn_may_write_register() then
    raise exception 'A register is finalised by the teacher who marked it.'
      using errcode = '42501';
  end if;
  if not public.fn_may_manage_class(p_session_id, p_class_id, p_section_id) then
    raise exception 'You can only finalize your assigned class';
  end if;
  -- `and not ad.is_locked`, from 0126: without it the statement rewrites every
  -- row of the section-day whether it was open or not, so the number it
  -- returns is "pupils in this section-day" while the screen prints it as
  -- "Finalized & locked 34 rows".
  update public.attendance_daily ad
    set is_locked = true
    from public.enrollments e
    where ad.enrollment_id = e.id
      and ad.attendance_date = p_date
      and e.session_id = p_session_id
      and e.class_id = p_class_id
      and e.section_id is not distinct from p_section_id
      and not ad.is_locked;
  get diagnostics v_count = row_count;

  if v_count > 0 then
    insert into public.audit_log (
      school_id, actor, actor_role, action, entity, entity_id, before, after)
    values (
      public.current_school_id(), auth.uid(),
      (select role from public.profiles where id = auth.uid()),
      'ATTENDANCE_FINALIZE', 'attendance_daily', p_date::text,
      jsonb_build_object('locked', false),
      jsonb_build_object('locked', true, 'rows', v_count,
                         'session_id', p_session_id, 'class_id', p_class_id,
                         'section_id', p_section_id));
  end if;

  begin
    perform public.fn_queue_absent_today(p_session_id, p_class_id, p_section_id, p_date);
  exception when others then
    raise notice 'attendance finalised; absence messages could not be queued: %', sqlerrm;
  end;

  return v_count;
end;
$$;

-- The policies, so a direct table write cannot do what the function refuses.
-- These two are the actual enforcement; the functions above are SECURITY
-- DEFINER and bypass them, which is why both have to change together.
drop policy if exists attendance_insert on public.attendance_daily;
create policy attendance_insert on public.attendance_daily for insert
  with check (school_id = public.current_school_id()
              and public.fn_may_write_register()
              and public.fn_may_manage_enrollment(enrollment_id));

drop policy if exists attendance_update on public.attendance_daily;
create policy attendance_update on public.attendance_daily for update
  using (school_id = public.current_school_id()
         and public.fn_may_write_register()
         and public.fn_may_manage_enrollment(enrollment_id))
  with check (school_id = public.current_school_id()
              and public.fn_may_write_register()
              and public.fn_may_manage_enrollment(enrollment_id));

-- ======================================================== the head's screen ==
-- One row per class-section for one day, with enough to sort them into the
-- three piles the head thinks in: done and locked, done and not locked, not
-- done.
--
-- IT COUNTS ENROLMENTS, NOT ATTENDANCE ROWS, and that distinction is the
-- entire value of it. A class with 34 pupils and 34 marks is done. A class with
-- 34 pupils and 12 marks is NOT done, and the old software had no way to say
-- so: the register looked marked to anybody who opened it, because the 22
-- unmarked children simply were not rows.
--
-- SECTIONS WITH NO PUPILS ARE OMITTED. A school that made a section in
-- September and never put anybody in it would otherwise show a permanent red
-- entry that can never be cleared.
-- DROPPED FIRST, because `create or replace function` REFUSES to change a
-- function's return type: "cannot change return type of existing function".
-- These return a table, and a column added to one later is exactly that
-- change. Without the drop, a school re-pasting a corrected bundle would hit
-- that error, and because a bundle is one transaction the whole bundle would
-- roll back. None of these is referenced by a policy, so nothing depends on
-- them; the grants below are reapplied straight afterwards.
drop function if exists public.fn_attendance_day(uuid, date);
create or replace function public.fn_attendance_day(p_session_id uuid, p_date date)
returns table(
  class_id uuid, class_name text, level_order integer,
  section_id uuid, section_name text,
  pupils integer, marked integer, locked integer,
  state text
) language plpgsql stable security definer set search_path = public as $$
begin
  -- Read-only and school-scoped, but it hands over the WHOLE school at once,
  -- which is a different thing from a teacher reading their own class. Kept to
  -- the three roles whose job is oversight.
  -- may_view, not has_role, which is 0059's rule: an observer is MEANT to see
  -- the oversight screens and is stopped from writing by having no write
  -- function to call. Gating a read on has_role is how `readonly` ended up
  -- with screens that rendered and returned nothing.
  if not public.may_view('owner', 'principal') then
    raise exception 'Only the head, the owner or an observer may read the '
                    'whole school''s register at once'
      using errcode = '42501';
  end if;
  if not exists (select 1 from public.academic_sessions s
                  where s.id = p_session_id
                    and s.school_id = public.current_school_id()) then
    raise exception 'Unknown academic year for this school' using errcode = '42501';
  end if;

  return query
  select c.id, c.name, c.level_order,
         sec.id, sec.name,
         count(*)::integer as pupils,
         count(ad.enrollment_id)::integer as marked,
         count(ad.enrollment_id) filter (where ad.is_locked)::integer as locked,
         case
           when count(ad.enrollment_id) = 0 then 'none'
           when count(ad.enrollment_id) < count(*) then 'partial'
           -- Every pupil marked. Locked only if EVERY row is locked: a
           -- half-locked section is the result of finalising, then admitting a
           -- child, and it is not finished.
           when count(*) filter (where ad.is_locked) = count(*) then 'locked'
           else 'unlocked'
         end as state
    from public.enrollments e
    join public.classes c on c.id = e.class_id
    left join public.sections sec on sec.id = e.section_id
    left join public.attendance_daily ad
           on ad.enrollment_id = e.id and ad.attendance_date = p_date
   where e.school_id = public.current_school_id()
     and e.session_id = p_session_id
     and e.status = 'active'
   group by c.id, c.name, c.level_order, sec.id, sec.name
   order by c.level_order, c.name, sec.name nulls first;
end;
$$;
revoke all on function public.fn_attendance_day(uuid, date) from public, anon;
grant execute on function public.fn_attendance_day(uuid, date) to authenticated;

-- ====================================================== subject attendance ==
create table if not exists public.attendance_subject (
  id              uuid primary key default gen_random_uuid(),
  school_id       uuid not null references public.schools(id) on delete cascade,
  enrollment_id   uuid not null references public.enrollments(id) on delete cascade,
  subject_id      uuid not null references public.subjects(id) on delete cascade,
  attendance_date date not null,
  status          public.attendance_status not null,
  marked_by       uuid references public.profiles(id),
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  -- One mark per child per subject per day. There is no timetable in this
  -- product, so "the chemistry period" is not a thing that can be named; the
  -- honest unit is the day.
  constraint attendance_subject_once unique (enrollment_id, subject_id, attendance_date)
);

create index if not exists attendance_subject_day
  on public.attendance_subject (school_id, attendance_date);

drop trigger if exists trg_attendance_subject_updated on public.attendance_subject;
create trigger trg_attendance_subject_updated before update on public.attendance_subject
  for each row execute function public.set_updated_at();

alter table public.attendance_subject enable row level security;

-- WHO MAY READ IT. The head, the owner, an observer, and the teacher who wrote
-- it. Not the rest of the staff room, and not parents: the school asked for
-- this to be something the head can see, and a second attendance figure
-- reaching a parent is precisely the confusion that must not happen.
drop policy if exists attendance_subject_select on public.attendance_subject;
create policy attendance_subject_select on public.attendance_subject for select
  using (school_id = public.current_school_id()
         and (public.has_role('owner', 'principal', 'readonly')
              or marked_by = auth.uid()));

-- Written only through the function below, which is SECURITY DEFINER. No
-- insert, update or delete policy exists at all, so a direct table write from
-- a browser session affects nothing whatever the caller's role.
--
-- That is stricter than attendance_daily, on purpose: there is one way in, so
-- there is one place the rules live.

/**
 * The roster for one subject on one day.
 *
 * Returns the same pupils the daily register would, plus this subject's mark
 * and, for context, what the class teacher recorded. A subject teacher looking
 * at an empty row wants to know whether the child is absent from school
 * altogether before they mark them absent from chemistry.
 */
drop function if exists public.fn_subject_roster(uuid, uuid, uuid, uuid, date);
create or replace function public.fn_subject_roster(
  p_session_id uuid, p_class_id uuid, p_section_id uuid, p_subject_id uuid, p_date date
) returns table(
  enrollment_id uuid, student_id uuid, full_name text, roll_no text,
  status public.attendance_status, day_status public.attendance_status
) language plpgsql stable security definer set search_path = public as $$
begin
  if not public.fn_may_mark_subject(p_session_id, p_class_id, p_section_id, p_subject_id)
     and not public.may_view('owner', 'principal') then
    raise exception 'You can only see subject attendance for a class and '
                    'subject you teach'
      using errcode = '42501';
  end if;

  return query
  select e.id, e.student_id, s.full_name, e.roll_no,
         asub.status, ad.status
    from public.enrollments e
    join public.students s on s.id = e.student_id
    left join public.attendance_subject asub
           on asub.enrollment_id = e.id
          and asub.subject_id = p_subject_id
          and asub.attendance_date = p_date
    left join public.attendance_daily ad
           on ad.enrollment_id = e.id and ad.attendance_date = p_date
   where e.school_id = public.current_school_id()
     and e.session_id = p_session_id
     and e.class_id = p_class_id
     and e.section_id is not distinct from p_section_id
     and e.status = 'active'
   order by
     -- Same order as every other roster in the product: by roll number read as
     -- a number where it is one, so 10 comes after 9 and not after 1.
     nullif(regexp_replace(coalesce(e.roll_no, ''), '\D', '', 'g'), '')::bigint
       nulls last,
     s.full_name;
end;
$$;
revoke all on function public.fn_subject_roster(uuid, uuid, uuid, uuid, date) from public, anon;
grant execute on function public.fn_subject_roster(uuid, uuid, uuid, uuid, date) to authenticated;

/**
 * Mark a subject's attendance for a day.
 *
 * Deliberately thinner than fn_mark_attendance: no locking, no correction
 * trail, no absence messages to parents. This register is optional and
 * informal, and dressing it in the daily register's machinery would make two
 * things look equally binding when only one of them is.
 *
 * THE PRINCIPAL IS REFUSED HERE TOO, for the same reason as the daily one.
 */
create or replace function public.fn_mark_subject_attendance(
  p_session_id uuid, p_class_id uuid, p_section_id uuid,
  p_subject_id uuid, p_date date, p_marks jsonb
) returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_actor uuid := auth.uid();
  v_school uuid := public.current_school_id();
  v_marked integer;
begin
  if not public.fn_may_write_register() then
    raise exception 'Subject attendance is marked by the subject teacher.'
      using errcode = '42501';
  end if;
  if not public.fn_may_mark_subject(p_session_id, p_class_id, p_section_id, p_subject_id) then
    raise exception 'You can only mark a subject you are assigned to teach in '
                    'this class'
      using errcode = '42501';
  end if;
  perform public.fn__only_these_keys(p_marks, '{enrollment_id,status}'::text[],
            'Subject attendance marking');
  if p_marks is null or jsonb_typeof(p_marks) <> 'array' then
    raise exception 'p_marks must be a JSON array';
  end if;

  -- The same date rules as the daily register, and for the same reason: a
  -- mistyped year is the realistic failure, not an attacker.
  if p_date > (now() at time zone 'Asia/Karachi')::date then
    raise exception 'Attendance cannot be marked for %, which has not '
      'happened yet.', to_char(p_date, 'DD Mon YYYY')
      using errcode = '22008';
  end if;
  perform public.fn__assert_date_in_session(p_session_id, p_date,
            'Marking subject attendance');

  -- Every enrolment must be in this school AND in the class being marked.
  -- Without the second half, a subject teacher assigned to 9-A could pass 10-B
  -- enrolment ids and mark them.
  if exists (
    select 1 from jsonb_array_elements(p_marks) e
    where not exists (
      select 1 from public.enrollments en
       where en.id = (e->>'enrollment_id')::uuid
         and en.school_id = v_school
         and en.session_id = p_session_id
         and en.class_id = p_class_id
         and en.section_id is not distinct from p_section_id
    )
  ) then
    raise exception 'A pupil in that list is not in this class'
      using errcode = '42501';
  end if;

  with input as (
    select distinct on (enrollment_id) enrollment_id, status
    from (
      select (e->>'enrollment_id')::uuid as enrollment_id,
             (e->>'status')::public.attendance_status as status
      from jsonb_array_elements(p_marks) e
    ) q
    order by enrollment_id
  ),
  upserted as (
    insert into public.attendance_subject
      (school_id, enrollment_id, subject_id, attendance_date, status, marked_by)
    select v_school, enrollment_id, p_subject_id, p_date, status, v_actor from input
    on conflict (enrollment_id, subject_id, attendance_date) do update
      set status = excluded.status, marked_by = excluded.marked_by
    returning 1
  )
  select count(*) into v_marked from upserted;

  return jsonb_build_object('marked', v_marked);
end;
$$;
revoke all on function public.fn_mark_subject_attendance(uuid, uuid, uuid, uuid, date, jsonb)
  from public, anon;
grant execute on function public.fn_mark_subject_attendance(uuid, uuid, uuid, uuid, date, jsonb)
  to authenticated;

/**
 * What the head sees under "Subject attendance" for a day.
 *
 * ONLY WHAT WAS ACTUALLY MARKED. There is no row for a subject nobody touched,
 * and that is the single most important line in this function. Subject
 * attendance is optional; listing every unmarked subject as outstanding would
 * put forty red rows on the head's screen every morning and teach them to stop
 * reading the panel that also tells them a class register is missing.
 */
drop function if exists public.fn_subject_attendance_day(uuid, date);
create or replace function public.fn_subject_attendance_day(p_session_id uuid, p_date date)
returns table(
  class_id uuid, class_name text, level_order integer,
  section_id uuid, section_name text,
  subject_id uuid, subject_name text,
  marked_by_name text,
  pupils integer, present integer, absent integer, other integer
) language plpgsql stable security definer set search_path = public as $$
begin
  if not public.may_view('owner', 'principal') then
    raise exception 'Subject attendance is shown to the head'
      using errcode = '42501';
  end if;

  return query
  select c.id, c.name, c.level_order,
         sec.id, sec.name,
         sub.id, sub.name,
         coalesce(pr.full_name, 'Unknown'),
         count(*)::integer,
         count(*) filter (where a.status = 'present')::integer,
         count(*) filter (where a.status = 'absent')::integer,
         count(*) filter (where a.status not in ('present', 'absent'))::integer
    from public.attendance_subject a
    join public.enrollments e on e.id = a.enrollment_id
    join public.classes c on c.id = e.class_id
    join public.subjects sub on sub.id = a.subject_id
    left join public.sections sec on sec.id = e.section_id
    left join public.profiles pr on pr.id = a.marked_by
   where a.school_id = public.current_school_id()
     and a.attendance_date = p_date
     and e.session_id = p_session_id
   group by c.id, c.name, c.level_order, sec.id, sec.name, sub.id, sub.name, pr.full_name
   order by c.level_order, c.name, sec.name nulls first, sub.name;
end;
$$;
revoke all on function public.fn_subject_attendance_day(uuid, date) from public, anon;
grant execute on function public.fn_subject_attendance_day(uuid, date) to authenticated;

-- ─────────────────────────────────────────────────────────────────────────
-- 0135_a_test_is_set_and_marked_by_the_teacher.sql
-- ─────────────────────────────────────────────────────────────────────────
-- =============================================================================
-- 0135  A test is set and marked by the teacher, and the head watches it happen
--
-- -----------------------------------------------------------------------------
-- THE SAME MISTAKE AS THE REGISTER, IN THE OTHER MODULE
--
-- A principal could create a class test, enter its marks and lock it. 0134
-- gives the reasoning at length for the daily register and it transfers whole:
-- a mark is a statement about a child's work by the person who set the paper
-- and read it. A head who can enter marks can produce a result nobody taught.
--
-- What the head needs instead, and did not have in any form:
--
--   * what tests my teachers have set, and for when
--   * which of them are marked and which are not
--   * and the ability to ask that question about LAST Tuesday, or about next
--     week, instead of only about today
--
-- -----------------------------------------------------------------------------
-- SCHEDULING A TEST FOR A DATE THAT HAS NOT HAPPENED
--
-- The database always allowed it: nothing bounded assessment_date in either
-- direction. That is not the same as supporting it. A test dated next Saturday
-- sat in the same list as a test held last Tuesday, with nothing to say which
-- was which, and the marks grid opened for both. A teacher could enter marks
-- for a paper that had not been sat.
--
-- So this file gives the date a meaning:
--
--   * a test may be dated in the future. That is scheduling, and it is what the
--     teachers asked for.
--   * MARKS MAY NOT BE ENTERED BEFORE THAT DATE. Refused in words, because the
--     alternative is a mark against a paper nobody has written.
--   * the date must fall inside the academic year, and no more than a year
--     ahead. Both are about somebody typing 2027 for 2026, and the second one
--     matters more than it looks: a test mistyped four years out never appears
--     in the unmarked list and is never noticed again.
--
-- -----------------------------------------------------------------------------
-- WHAT "UNMARKED" MEANS, WHICH IS THE ONLY SUBTLE THING IN THIS FILE
--
-- A test is unmarked when its date has PASSED and at least one pupil in it has
-- no mark and is not recorded absent. Not "has no marks at all": the common
-- failure is a teacher who marked twenty of thirty-four and was interrupted,
-- and a reminder that only fires on a completely blank test misses exactly
-- that case. A locked test is never unmarked, because locking is the teacher
-- saying they are finished.
--
-- A test dated TODAY is not chased. The paper may be sat this afternoon.
-- =============================================================================

-- ==================================================== who may set a test ====
-- The narrower cousin of fn_may_mark_subject.
--
-- fn_may_mark_subject itself is NOT changed and must not be: it also gates
-- fn_enter_marks, which is the formal EXAM path, and the school's exam process
-- is a different thing with a different chain of responsibility. Widening this
-- change into exams was not asked for and would be a surprise.
-- fn_may_ and not fn__, for the reason given at fn_may_write_register in 0134:
-- it is used inside a row-level policy and so must be executable by the
-- querying user.
create or replace function public.fn_may_set_a_test(
  p_session uuid, p_class uuid, p_section uuid, p_subject uuid
) returns boolean language sql stable security definer set search_path = public as $$
  select not public.has_role('principal')
     and public.fn_may_mark_subject(p_session, p_class, p_section, p_subject);
$$;

revoke all on function public.fn_may_set_a_test(uuid, uuid, uuid, uuid) from public, anon;
grant execute on function public.fn_may_set_a_test(uuid, uuid, uuid, uuid) to authenticated;

comment on function public.fn_may_set_a_test(uuid, uuid, uuid, uuid) is
  'Who may create, edit, mark or lock a class test. fn_may_mark_subject minus '
  'the principal, who oversees tests rather than setting them. Exams are '
  'unaffected and still use fn_may_mark_subject. See 0135.';

drop policy if exists assessments_insert on public.assessments;
create policy assessments_insert on public.assessments for insert
  with check (school_id = public.current_school_id()
              and public.has_role('owner', 'class_teacher', 'subject_teacher')
              and public.fn_may_set_a_test(session_id, class_id, section_id, subject_id));

drop policy if exists assessments_update on public.assessments;
create policy assessments_update on public.assessments for update
  using (school_id = public.current_school_id()
         and public.has_role('owner', 'class_teacher', 'subject_teacher')
         and public.fn_may_set_a_test(session_id, class_id, section_id, subject_id))
  with check (school_id = public.current_school_id()
              and public.has_role('owner', 'class_teacher', 'subject_teacher')
              and public.fn_may_set_a_test(session_id, class_id, section_id, subject_id));

-- ------------------------------------------------------------- the date -----
-- A trigger rather than a check constraint, because both bounds need the
-- academic year the test belongs to, and a check constraint may not read
-- another table.
create or replace function public.guard_assessment_date() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  v_starts date;
  v_ends   date;
begin
  if new.assessment_date is null then
    return new;   -- Allowed, and always was: an undated test is a draft.
  end if;

  -- Karachi, not UTC, for the same reason every other date bound in this
  -- product uses it: between midnight and 5am local, UTC still says yesterday.
  if new.assessment_date > (now() at time zone 'Asia/Karachi')::date + 365 then
    raise exception 'A test cannot be scheduled for %, which is more than a '
                    'year away. Check the year.', to_char(new.assessment_date, 'DD Mon YYYY')
      using errcode = '22008';
  end if;

  -- SCHOOL-SCOPED, and it has to be said out loud because this function is
  -- SECURITY DEFINER and RLS does not apply inside one. Reading
  -- academic_sessions by id alone would let a row naming ANOTHER school's
  -- session be validated against that school's dates. The row's own school_id
  -- is authoritative where it is set (a BEFORE trigger stamps it), and
  -- current_school_id() covers the ordering case where it is not yet.
  select starts_on, ends_on into v_starts, v_ends
    from public.academic_sessions
   where id = new.session_id
     and school_id = coalesce(new.school_id, public.current_school_id());
  if not found then
    raise exception 'That academic year does not belong to this school'
      using errcode = '42501';
  end if;
  -- A year with no dates on it is left alone. 0130 reports those separately
  -- and refusing here would block a school from working until somebody fills
  -- in a settings screen they do not know about.
  if v_starts is not null and new.assessment_date < v_starts then
    raise exception 'A test on % falls before the academic year began on %.',
      to_char(new.assessment_date, 'DD Mon YYYY'), to_char(v_starts, 'DD Mon YYYY')
      using errcode = '22008';
  end if;
  if v_ends is not null and new.assessment_date > v_ends then
    raise exception 'A test on % falls after the academic year ended on %.',
      to_char(new.assessment_date, 'DD Mon YYYY'), to_char(v_ends, 'DD Mon YYYY')
      using errcode = '22008';
  end if;
  return new;
end;
$$;

-- A trigger function is called by Postgres, never by a client, so nothing
-- needs execute on it.
revoke all on function public.guard_assessment_date() from public, anon, authenticated;

drop trigger if exists trg_assessment_date on public.assessments;
create trigger trg_assessment_date before insert or update on public.assessments
  for each row execute function public.guard_assessment_date();

-- ================================================== marking and locking =====
create or replace function public.fn_enter_assessment_marks(
  p_assessment_id uuid, p_marks jsonb, p_reason text default null
) returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_actor  uuid := auth.uid();
  v_a      record;
  v_total  integer;
  v_marked integer;
  v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
begin
  if not public.has_role('owner','class_teacher','subject_teacher') then
    raise exception 'A test is marked by the teacher who set it. A principal '
                    'can see which tests are marked and which are not, on the '
                    'Tests screen.'
      using errcode = '42501';
  end if;
  perform public.fn__only_these_keys(p_marks, '{enrollment_id,marks,is_absent}'::text[], 'Class test mark entry');
  perform public.assert_own('assessments', p_assessment_id);
  if p_marks is null or jsonb_typeof(p_marks) <> 'array' then
    raise exception 'p_marks must be a JSON array';
  end if;

  select * into v_a from public.assessments
  where id = p_assessment_id and school_id = public.current_school_id();
  if not found then raise exception 'Assessment not found'; end if;
  if v_a.is_locked then raise exception 'This assessment is locked'; end if;

  -- A PAPER THAT HAS NOT BEEN SAT HAS NO MARKS. New in 0135, and the reason
  -- scheduling needed more than letting the date field hold a future value.
  if v_a.assessment_date is not null
     and v_a.assessment_date > (now() at time zone 'Asia/Karachi')::date then
    raise exception 'This test is scheduled for %. Marks can be entered from '
                    'that day onwards.', to_char(v_a.assessment_date, 'DD Mon YYYY')
      using errcode = '22008';
  end if;

  -- Teacher scope. The owner is the one unscoped role left; see 0134 for why
  -- that is deliberate and where to change it.
  if not public.has_role('owner') then
    -- 0085: class AND subject. The class check alone let the Physics
    -- teacher of Class 9 enter Class 9's Islamiat marks.
    --
    -- WRITTEN AS TWO CHECKS RATHER THAN ONE CALL TO fn_may_set_a_test, AND
    -- BOTH REASONS MATTER.
    --
    -- The first is the school's. fn_may_set_a_test is fn_may_mark_subject with
    -- the principal taken out, so one call collapses two quite different
    -- refusals into one sentence. A principal needs to be told that marking is
    -- the teacher's, and a Physics teacher who opened the Islamiat paper needs
    -- to be told to ask the office about their subject assignment. Telling
    -- either of them the other's sentence sends them to the wrong person.
    --
    -- The second is this repository's, and it cost a red CI run to learn.
    -- MIGRATION 0085 IS A TEXT PATCH ON THIS FUNCTION, it is frozen inside
    -- bundle 7, and its idempotency guard is
    --
    --     if v_old like '%fn_may_mark_subject%' then  (skip, already done)
    --
    -- A body that no longer contains that name is one the guard does not
    -- recognise, so 0085 tries its regexp, matches nothing, and raises. Because
    -- a bundle is ONE transaction that rolls back all of bundle 7, and
    -- verify.sql tells a school in several of its FAIL messages to "re-run
    -- bundle 7". The repair path would have been a dead end on exactly the
    -- databases that needed it.
    --
    -- So the reference below is load bearing twice over: it is the check this
    -- function genuinely needs, and it is the anchor a frozen migration reads.
    -- Do not collapse it back into one call.
    if not public.fn_may_mark_subject(
             v_a.session_id, v_a.class_id, v_a.section_id, v_a.subject_id) then
      raise exception 'You can only enter marks for a class and subject you teach. '
        'Ask the office to add you under Settings, Staff, Subject Teachers.'
        using errcode = '42501';
    end if;
    if not public.fn_may_set_a_test(
             v_a.session_id, v_a.class_id, v_a.section_id, v_a.subject_id) then
      raise exception 'A test is marked by the teacher who set it. A principal '
                      'can see which tests are marked and which are not, on the '
                      'Tests screen.'
        using errcode = '42501';
    end if;
  end if;

  if exists (
    select 1 from jsonb_array_elements(p_marks) e
    where coalesce((e->>'is_absent')::boolean, false) = false
      and nullif(e->>'marks', '') is not null
      and ((e->>'marks')::numeric < 0 or (e->>'marks')::numeric > v_a.max_marks)
  ) then
    raise exception 'Marks must be between 0 and %', v_a.max_marks;
  end if;

  -- Every enrolment must be in this school.
  if exists (
    select 1 from jsonb_array_elements(p_marks) e
    where not exists (
      select 1 from public.enrollments en
      where en.id = (e->>'enrollment_id')::uuid
        and en.school_id = public.current_school_id())
  ) then
    raise exception 'Unknown enrolment in this school' using errcode = '42501';
  end if;

  select count(distinct (e->>'enrollment_id')) into v_total from jsonb_array_elements(p_marks) e;

  with input as (
    select distinct on (enrollment_id) enrollment_id, marks, is_absent
    from (
      select (e->>'enrollment_id')::uuid as enrollment_id,
             nullif(e->>'marks', '')::numeric as marks,
             coalesce((e->>'is_absent')::boolean, false) as is_absent
      from jsonb_array_elements(p_marks) e
    ) q
    order by enrollment_id
  ),
  upserted as (
    insert into public.mark_entries as me
      (assessment_id, enrollment_id, marks, max_marks, is_absent, marked_by)
    select p_assessment_id, enrollment_id, marks, v_a.max_marks, is_absent, v_actor from input
    on conflict (assessment_id, enrollment_id) where assessment_id is not null
    do update set marks = excluded.marks, is_absent = excluded.is_absent,
                  marked_by = excluded.marked_by,
                  corrected_from = case when me.marks is distinct from excluded.marks
                                        then me.marks else me.corrected_from end,
                  correction_reason = case when me.marks is distinct from excluded.marks
                                           then v_reason else me.correction_reason end
    where not me.is_locked
    returning 1
  )
  select count(*) into v_marked from upserted;

  return jsonb_build_object('marked', v_marked, 'skipped', v_total - v_marked, 'total', v_total);
end;
$$;

create or replace function public.fn_lock_assessment(p_assessment_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v_session uuid; v_class uuid; v_section uuid; v_subject uuid; v_marks integer;
begin
  if not public.has_role('owner','class_teacher','subject_teacher') then
    raise exception 'A test is locked by the teacher who marked it.'
      using errcode = '42501';
  end if;
  perform public.assert_own('assessments', p_assessment_id);
  select session_id, class_id, section_id, subject_id
    into v_session, v_class, v_section, v_subject
  from public.assessments where id = p_assessment_id;
  if v_session is null then raise exception 'Assessment not found'; end if;
  -- fn_may_set_a_test, not fn_may_manage_class: locking a test is finishing
  -- it, and the person who may finish it is the person who could mark it. The
  -- class check alone let the Physics teacher lock the Islamiat paper.
  if not public.fn_may_set_a_test(v_session, v_class, v_section, v_subject) then
    raise exception 'You can only lock a test for a class and subject you teach';
  end if;

  select count(*) into v_marks from public.mark_entries
   where assessment_id = p_assessment_id and not is_locked;

  update public.mark_entries set is_locked = true where assessment_id = p_assessment_id;
  update public.assessments set is_locked = true where id = p_assessment_id;

  if v_marks > 0 then
    insert into public.audit_log (
      school_id, actor, actor_role, action, entity, entity_id, before, after)
    values (
      public.current_school_id(), auth.uid(),
      (select role from public.profiles where id = auth.uid()),
      'ASSESSMENT_LOCK', 'assessments', p_assessment_id::text,
      jsonb_build_object('locked', false),
      jsonb_build_object('locked', true, 'marks', v_marks,
                         'session_id', v_session, 'class_id', v_class,
                         'section_id', v_section));
  end if;
end;
$$;

-- ================================================== the teacher's reminder ==
/**
 * Tests this teacher set, whose day has passed, that are not finished.
 *
 * Scoped to the CALLER: a teacher is reminded about their own papers and
 * nobody else's. The head's version is fn_tests_overview below, and it is a
 * different question with a different answer.
 */
-- DROPPED FIRST, because `create or replace function` REFUSES to change a
-- function's return type: "cannot change return type of existing function".
-- These return a table, and a column added to one later is exactly that
-- change. Without the drop, a school re-pasting a corrected bundle would hit
-- that error, and because a bundle is one transaction the whole bundle would
-- roll back. None of these is referenced by a policy, so nothing depends on
-- them; the grants below are reapplied straight afterwards.
drop function if exists public.fn_my_unmarked_tests(uuid);
create or replace function public.fn_my_unmarked_tests(p_session_id uuid)
returns table(
  assessment_id uuid, title text, assessment_date date,
  -- class_id as well as class_name, so the screen can OPEN the test rather
  -- than only naming it. A reminder you cannot act on from where it is shown
  -- is half a feature: the teacher reads "Weekly Test 3, four days ago" and
  -- then has to go and find it in a dropdown.
  class_id uuid, class_name text, section_name text, subject_name text,
  pupils integer, marked integer, days_late integer
) language plpgsql stable security definer set search_path = public as $$
declare
  v_today date := (now() at time zone 'Asia/Karachi')::date;
begin
  if not public.has_role('owner','class_teacher','subject_teacher') then
    -- Not an error for a principal so much as the wrong question: they have no
    -- tests of their own. Returning nothing would be a silent lie about it.
    raise exception 'This is a teacher''s own list of papers to mark'
      using errcode = '42501';
  end if;

  return query
  select a.id, a.title, a.assessment_date,
         c.id, c.name, sec.name, sub.name,
         cnt.pupils, cnt.marked,
         (v_today - a.assessment_date)::integer
    from public.assessments a
    join public.classes c on c.id = a.class_id
    left join public.sections sec on sec.id = a.section_id
    left join public.subjects sub on sub.id = a.subject_id
    cross join lateral (
      select count(*)::integer as pupils,
             count(*) filter (
               where me.id is not null
                 and (me.marks is not null or me.is_absent)
             )::integer as marked
        from public.enrollments e
        left join public.mark_entries me
               on me.assessment_id = a.id and me.enrollment_id = e.id
       where e.school_id = a.school_id
         and e.session_id = a.session_id
         and e.class_id = a.class_id
         and (a.section_id is null or e.section_id = a.section_id)
         and e.status = 'active'
    ) cnt
   where a.school_id = public.current_school_id()
     and a.session_id = p_session_id
     and not a.is_locked
     -- Strictly before today. A paper dated today may be sat this afternoon,
     -- and a reminder that fires the morning of the test is noise.
     and a.assessment_date is not null
     and a.assessment_date < v_today
     -- At least one pupil with neither a mark nor an absence. "No marks at
     -- all" would miss the common case: twenty of thirty-four done, then the
     -- bell went.
     and cnt.marked < cnt.pupils
     and public.fn_may_set_a_test(a.session_id, a.class_id, a.section_id, a.subject_id)
   order by a.assessment_date, c.name, sub.name;
end;
$$;
revoke all on function public.fn_my_unmarked_tests(uuid) from public, anon;
grant execute on function public.fn_my_unmarked_tests(uuid) to authenticated;

-- ==================================================== the head's overview ===
/**
 * Every test in a date range, with who set it and whether it is marked.
 *
 * A RANGE and not a day, which is what makes the calendar on the screen work.
 * The head looks back to audit last week and forward to see what is coming,
 * and both are the same question asked of a different pair of dates.
 *
 * `state` is computed here rather than in the browser so that the screen, a
 * future report and anybody reading the database by hand agree about what
 * "marked" means:
 *
 *   scheduled  the day has not come
 *   unmarked   the day has passed and nobody has entered anything
 *   partial    some pupils marked, some not
 *   marked     every pupil has a mark or an absence, not locked
 *   locked     the teacher has finished with it
 */
drop function if exists public.fn_tests_overview(uuid, date, date);
create or replace function public.fn_tests_overview(
  p_session_id uuid, p_from date, p_to date
) returns table(
  assessment_id uuid, title text, assessment_date date,
  class_id uuid, class_name text, level_order integer,
  section_name text, subject_name text,
  set_by_name text, max_marks numeric, is_locked boolean,
  pupils integer, marked integer, state text
) language plpgsql stable security definer set search_path = public as $$
declare
  v_today date := (now() at time zone 'Asia/Karachi')::date;
begin
  -- may_view, per 0059: an observer sees the oversight screens.
  if not public.may_view('owner', 'principal') then
    raise exception 'Only the head, the owner or an observer may see every '
                    'teacher''s tests'
      using errcode = '42501';
  end if;
  if not exists (select 1 from public.academic_sessions s
                  where s.id = p_session_id
                    and s.school_id = public.current_school_id()) then
    raise exception 'Unknown academic year for this school' using errcode = '42501';
  end if;
  if p_from is null or p_to is null or p_to < p_from then
    raise exception 'Give a start date and an end date, in that order';
  end if;
  -- A year at a time. Without a cap the screen can ask for a decade and the
  -- head waits for a spinner on a school connection.
  if p_to - p_from > 400 then
    raise exception 'Ask for a year at a time or less';
  end if;

  return query
  select a.id, a.title, a.assessment_date,
         c.id, c.name, c.level_order,
         sec.name, sub.name,
         coalesce(pr.full_name, 'Unknown'),
         a.max_marks, a.is_locked,
         cnt.pupils, cnt.marked,
         case
           when a.is_locked then 'locked'
           when a.assessment_date is null then 'undated'
           when a.assessment_date > v_today then 'scheduled'
           when cnt.marked = 0 then 'unmarked'
           when cnt.marked < cnt.pupils then 'partial'
           else 'marked'
         end
    from public.assessments a
    join public.classes c on c.id = a.class_id
    left join public.sections sec on sec.id = a.section_id
    left join public.subjects sub on sub.id = a.subject_id
    left join public.profiles pr on pr.id = a.created_by
    cross join lateral (
      select count(*)::integer as pupils,
             count(*) filter (
               where me.id is not null
                 and (me.marks is not null or me.is_absent)
             )::integer as marked
        from public.enrollments e
        left join public.mark_entries me
               on me.assessment_id = a.id and me.enrollment_id = e.id
       where e.school_id = a.school_id
         and e.session_id = a.session_id
         and e.class_id = a.class_id
         and (a.section_id is null or e.section_id = a.section_id)
         and e.status = 'active'
    ) cnt
   where a.school_id = public.current_school_id()
     and a.session_id = p_session_id
     and a.assessment_date between p_from and p_to
   order by a.assessment_date, c.level_order, c.name, sub.name;
end;
$$;
revoke all on function public.fn_tests_overview(uuid, date, date) from public, anon;
grant execute on function public.fn_tests_overview(uuid, date, date) to authenticated;

-- ─────────────────────────────────────────────────────────────────────────
-- Record what this bundle applied (no-op before 0069 creates the ledger)
-- ─────────────────────────────────────────────────────────────────────────
do $ledger$
begin
  if to_regprocedure('public.fn_record_migration(text,text,text)') is null then
    raise notice 'migration ledger not present yet — nothing recorded';
    return;
  end if;
  perform public.fn_record_migration('0133_two_roles_the_school_never_needed.sql', '38_the_register_belongs_to_the_teacher.sql');
  perform public.fn_record_migration('0134_the_register_belongs_to_the_teacher.sql', '38_the_register_belongs_to_the_teacher.sql');
  perform public.fn_record_migration('0135_a_test_is_set_and_marked_by_the_teacher.sql', '38_the_register_belongs_to_the_teacher.sql');
end $ledger$;

-- =============================================================================
-- GENERATED FILE — DO NOT EDIT.
-- Built from supabase/migrations/ by supabase/build-bundles.sh
--
-- Paste this whole file into the Supabase SQL Editor and press Run.
-- Run the bundles in order, one at a time, waiting for each to finish.
-- =============================================================================


-- ─────────────────────────────────────────────────────────────────────────
-- 0106_an_unpaid_school_is_closed.sql
-- ─────────────────────────────────────────────────────────────────────────
-- =============================================================================
-- 0106: An unpaid school stays open to everybody except the person who pays
--
-- TWO THINGS THAT COST THIS BUSINESS MONEY, BOTH MEASURED ON THE CONSOLE.
--
-- 1. THE TRIAL COULD BE EXTENDED FOREVER
--
-- fn_extend_trial caps ONE call at 30 days and caps nothing else. The operator
-- console renders a "+14d trial" button with no confirmation, so fourteen days
-- is one click, and a hundred and forty days is ten clicks. 0027's own comment
-- above the function reads:
--
--     Deliberately capped: an unbounded "extend" button turns into a free tier
--     by accident.
--
-- and the cap it describes is per press. The free tier shipped.
--
-- The decision is that there are NO extensions. A school that needs more time
-- is put on a plan, which is a conversation and an invoice rather than a
-- button. So the function refuses, in words, rather than being dropped: a
-- console still carrying the old button gets a sentence a person can act on
-- instead of "function does not exist".
--
-- 2. AN UNPAID SCHOOL'S PARENTS NEVER NOTICED
--
-- 0026 decided that a locked school may still read and export everything, and
-- for the OFFICE that remains right: their records are their own and holding
-- them hostage is how a late payment becomes a legal complaint.
--
-- But it was never only the office. The parent portal is a separate route in
-- the app, outside the browser's licence gate entirely, and every portal
-- function is SECURITY DEFINER, so it answers whatever the subscription says.
-- A school that stopped paying kept a working parent portal: fees, attendance
-- and results, for every family, indefinitely. Nobody in the building had any
-- reason to notice, which is the whole problem, because the parents are the
-- people who make a school renew.
--
-- So the parent portal now closes with the licence. The office does not: it
-- keeps read and export, and the write refusal in enforce_school_id() is
-- unchanged. The person who can fix it keeps the means to fix it, and the
-- people who apply the pressure feel it.
--
-- WHY TWO FUNCTIONS COVER THE WHOLE PORTAL
--
-- Measured, not assumed. Every child-scoped portal function calls
-- fn__assert_my_child first, and fn_portal_me is the entry point that lists
-- the children. Nothing else in the portal reaches data:
--
--   fn_portal_child_attendance  fn__assert_my_child
--   fn_portal_child_fees        fn__assert_my_child
--   fn_portal_child_ledger      fn__assert_my_child
--   fn_portal_child_results     fn__assert_my_child
--   fn_portal_me                the entry point
--
-- Guarding the choke point rather than five call sites is the difference
-- between a rule and five copies of a rule, which is what 0097 and 0100 were
-- both about.
--
-- Re-runnable.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. One answer to "may this school be used right now"
--
-- SECURITY DEFINER because it reads subscriptions, which a parent cannot see,
-- and it takes no argument a caller could point somewhere else: the school is
-- always the caller's own. That is the difference between this and the shape
-- check-definer-idor.py exists to catch.
-- ---------------------------------------------------------------------------
create or replace function public.fn__licence_permits_use()
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce(
    public.fn_effective_status(public.current_school_id())
      not in ('locked', 'cancelled'),
    -- No school context at all is not a licence question. Say yes and let the
    -- caller's own authorisation refuse, so a bug here cannot become a lock.
    true);
$$;

revoke all on function public.fn__licence_permits_use() from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2. The parent portal closes with the licence
--
-- WORDED FOR A PARENT, not for us. They cannot pay this bill and telling them
-- about a subscription they have no part in would send them to the school
-- angry at the wrong thing. It says the school will switch it back on, because
-- that is true and it is the sentence that makes a parent ring the office,
-- which is the point.
-- ---------------------------------------------------------------------------
create or replace function public.fn__require_live_licence() returns void
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.fn__licence_permits_use() then
    raise exception 'The parent portal for this school is closed at the moment. '
      'Please contact the school office; they can switch it back on.'
      using errcode = '42501';
  end if;
end;
$$;

revoke all on function public.fn__require_live_licence() from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 3. The two choke points, patched from their own definitions
--
-- Whitespace-blind, per supabase/check-patch-anchors.py: an anchor that assumes
-- one indentation matched on every database built here and missed on the first
-- real school, and took a whole bundle down with it.
--
-- The check goes FIRST in both, before "Not a parent account" and before any
-- read. A closed portal is not a place to answer questions about whose child is
-- whose.
-- ---------------------------------------------------------------------------
do $patch$
declare
  v_targets text[] := array['fn__assert_my_child', 'fn_portal_me'];
  v_name text; v_src text; v_new text; v_missing text[] := '{}';
begin
  foreach v_name in array v_targets loop
    begin
      select pg_get_functiondef(p.oid) into v_src
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'public' and p.proname = v_name;

      if v_src is null then
        v_missing := v_missing || v_name;
      elsif v_src like '%fn__require_live_licence%' then
        raise notice '0106: % already closes with the licence', v_name;
      else
        -- The first statement after the body's own `begin`. Not the shared
        -- fn__patch_after_gate from 0101: that one aims after a permission
        -- gate, and here the licence check must come BEFORE the gate, because
        -- "not your child" is an answer and a closed portal should give none.
        v_new := regexp_replace(v_src, '^begin[ \t\r]*$',
                   'begin' || chr(10) || '  perform public.fn__require_live_licence();',
                   'n');
        if v_new = v_src then
          v_missing := v_missing || v_name;
        else
          execute v_new;
        end if;
      end if;
    exception when others then
      v_missing := v_missing || (v_name || ' (' || sqlerrm || ')');
    end;
  end loop;

  if array_length(v_missing, 1) is not null then
    -- A WARNING, not an exception: this file is pasted inside a bundle the SQL
    -- editor runs as one transaction, and raising here would revert everything
    -- else in it. supabase/verify.sql names what is outstanding.
    raise warning '0106: the parent portal does NOT close with the licence for: %. '
      'An unpaid school keeps a working portal. Run supabase/verify.sql.',
      array_to_string(v_missing, ', ');
  end if;
end $patch$;

-- ---------------------------------------------------------------------------
-- 4. There are no trial extensions
--
-- The function stays and refuses, rather than being dropped. An operator
-- console that has not been redeployed still carries the button, and
-- "Trials are not extended" is something a person can act on where
-- "function public.fn_extend_trial does not exist" is not.
-- ---------------------------------------------------------------------------
create or replace function public.fn_extend_trial(p_school_id uuid, p_days integer default 14)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if not public.is_platform_admin() then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  raise exception 'Trials are not extended. A school that needs more time is '
    'activated on a plan, which is an invoice and a conversation rather than a '
    'button. The trial is fourteen days, once.'
    using errcode = '22023';
end;
$$;

-- ---------------------------------------------------------------------------
-- 5. Did it take?
-- ---------------------------------------------------------------------------
do $assert$
declare v_bad text[] := '{}';
begin
  if to_regprocedure('public.fn__licence_permits_use()') is null then
    v_bad := v_bad || 'fn__licence_permits_use is missing';
  end if;
  if not exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'fn__assert_my_child'
      and p.prosrc like '%fn__require_live_licence%') then
    v_bad := v_bad || 'the parent portal still answers for an unpaid school';
  end if;
  if not exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'fn_portal_me'
      and p.prosrc like '%fn__require_live_licence%') then
    v_bad := v_bad || 'the portal entry point still answers for an unpaid school';
  end if;
  if exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'fn_extend_trial'
      and p.prosrc not like '%Trials are not extended%') then
    v_bad := v_bad || 'the trial can still be extended';
  end if;

  if array_length(v_bad, 1) is null then
    raise notice '0106: the portal closes with the licence, and trials are not extended';
  else
    raise warning '0106: %. Everything else in this bundle applied. Send the '
      'output of supabase/verify.sql.', array_to_string(v_bad, '; ');
  end if;
end $assert$;

-- ─────────────────────────────────────────────────────────────────────────
-- 0107_midnight_in_karachi.sql
-- ─────────────────────────────────────────────────────────────────────────
-- =============================================================================
-- 0107: Between midnight and 5am, a school could not check anybody in
--
-- FOUND BY THE TEST SUITE FAILING AT 20:25 UTC, which is 01:25 in Karachi, and
-- it was not the suite that was wrong.
--
--     ERROR: new row for relation "staff_attendance" violates check constraint
--            "staff_attendance_not_future"
--
-- fn_staff_check_in is careful about this and always has been. It computes the
-- day as
--
--     v_today date := (now() at time zone 'Asia/Karachi')::date;
--
-- because a Pakistani school's today is Karachi's today, not the server's. Three
-- other functions agree: fn_checkin_display, fn_set_staff_attendance and
-- fn_staff_attendance_day all reckon in Asia/Karachi.
--
-- The TABLE did not. staff_attendance_not_future reads
--
--     check (attendance_date <= CURRENT_DATE)
--
-- and CURRENT_DATE is the database's date, which on Supabase is UTC. Pakistan
-- is UTC+5, so from 19:00 UTC every day the two disagree, and the row the
-- function correctly dated "today in Karachi" is refused as being in the future.
--
-- WHAT THAT MEANS FOR A SCHOOL. Staff check-in is dead every day from midnight
-- to five in the morning, Pakistan time. A night watchman scanning the QR at
-- 1am, a hostel warden, a caretaker opening up at 4:30: all refused, with a
-- constraint-violation message nobody in an office can act on. It would never
-- be reported as "the software breaks at night", it would be reported as "the
-- QR does not work", intermittently, by one person, and never reproduce when
-- somebody looked at it during the day.
--
-- Measured at the moment this was written: UTC said 2026-09-05 and Karachi said
-- 2026-09-06.
--
-- THE CONSTRAINT MOVES TO THE FUNCTIONS' RECKONING, not the other way round.
-- The functions are right. A school in Lahore marking attendance for the sixth
-- at half past midnight on the sixth is not recording the future, and a rule
-- that says otherwise is measuring from the wrong place.
--
-- The new constraint is strictly LOOSER than the old one, because Karachi's
-- date is never behind UTC's, so every row already stored satisfies it and the
-- validation scan cannot fail.
--
-- NOT PARAMETERISED BY SCHOOL, deliberately. A per-school timezone column would
-- be the general answer and it would be a lie here: a CHECK constraint cannot
-- read another table, so it would have to become a trigger, and every one of
-- the four functions above already hardcodes Asia/Karachi. One hardcoded zone
-- in five places that agree beats one configurable zone that only four of them
-- honour. When this product sells outside Pakistan, all five move together.
--
-- Re-runnable.
-- =============================================================================

do $tz$
declare v_def text;
begin
  select pg_get_constraintdef(oid) into v_def
  from pg_constraint
  where conname = 'staff_attendance_not_future'
    and conrelid = 'public.staff_attendance'::regclass;

  if v_def is null then
    raise warning '0107: staff_attendance_not_future is not present, so nothing '
      'was changed. Apply the earlier bundles first.';
  elsif v_def like '%Asia/Karachi%' then
    raise notice '0107: the check-in day already reckons in Asia/Karachi';
  else
    alter table public.staff_attendance drop constraint staff_attendance_not_future;
    alter table public.staff_attendance add constraint staff_attendance_not_future
      check (attendance_date <= ((now() at time zone 'Asia/Karachi')::date));
    raise notice '0107: the check-in day now reckons in Asia/Karachi, like the '
      'functions that write it';
  end if;
end $tz$;

-- ---------------------------------------------------------------------------
-- THE SAME SPLIT, IN THE FUNCTION THE OFFICE USES
--
-- fn_set_staff_attendance is how the office records a judgement: absent, leave,
-- a correction to a scan. It refuses a future date with
--
--     if p_date > current_date then
--
-- and formats the prior arrival time, four lines later, with
--
--     at time zone 'Asia/Karachi'
--
-- so it displays in Karachi and validates in UTC. Between 19:00 and midnight
-- UTC -- midnight to 5am in Pakistan -- the office cannot mark TODAY, because
-- today is the future by the server's reckoning. Same five hours as the
-- constraint above, same cause, different door.
--
-- Patched from its own definition and whitespace-blind, per
-- supabase/check-patch-anchors.py.
-- ---------------------------------------------------------------------------
do $office$
declare v_src text; v_new text;
begin
  begin
    select pg_get_functiondef(p.oid) into v_src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'fn_set_staff_attendance';

    if v_src is null then
      raise warning '0107: fn_set_staff_attendance is not present. Apply the '
        'earlier bundles first.';
    elsif v_src ~ 'p_date\s*>\s*\(\s*now\(\)\s*at time zone' then
      raise notice '0107: the office already reckons the day in Asia/Karachi';
    else
      v_new := regexp_replace(v_src,
        'p_date\s*>\s*current_date',
        'p_date > (now() at time zone ''Asia/Karachi'')::date');
      if v_new = v_src then
        raise warning '0107: could not find the future-date check in '
          'fn_set_staff_attendance, so the office still cannot mark today '
          'between midnight and 5am. Run supabase/verify.sql.';
      else
        execute v_new;
        raise notice '0107: the office now reckons the day in Asia/Karachi too';
      end if;
    end if;
  exception when others then
    raise warning '0107: fn_set_staff_attendance was left as it was: %', sqlerrm;
  end;
end $office$;

-- ---------------------------------------------------------------------------
-- WHAT IS DELIBERATELY LEFT ALONE, and it is worth naming rather than leaving
-- somebody to wonder whether it was missed.
--
-- Six other functions compare a date against current_date: fn_add_enquiry,
-- fn_enquiry_list, fn_enquiry_summary, fn_dashboard_summary, fn_fee_amount and
-- fn_set_fee_amount. Every one is a business-date question -- a follow-up due,
-- a fee effective from, the dashboard's "today" -- where a five-hour offset
-- shifts a boundary rather than refusing an action. None of them stops anybody
-- doing anything.
--
-- The two changed here BREAK a school: between midnight and 5am, staff cannot
-- scan in and the office cannot mark them. That is the line, and moving the
-- other six is a separate decision about what "today" means on a report, taken
-- on purpose rather than swept in behind a bug fix.
--
-- The pupil register is not affected at all: attendance_daily has no
-- future-date constraint and fn_mark_attendance does not compare p_date to
-- anything. Checked, not assumed.
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- Did it take?
-- ---------------------------------------------------------------------------
do $assert$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'staff_attendance_not_future'
      and conrelid = 'public.staff_attendance'::regclass
      and pg_get_constraintdef(oid) like '%Asia/Karachi%')
  then
    raise warning '0107: staff_attendance_not_future still measures the school '
      'day from UTC, so check-in stays broken between midnight and 5am. '
      'Everything else in this bundle applied. Run supabase/verify.sql.';
  elsif not exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'fn_set_staff_attendance'
      and p.prosrc like '%Asia/Karachi'')::date%')
  then
    raise warning '0107: the office still cannot mark today between midnight '
      'and 5am. Everything else in this bundle applied.';
  else
    raise notice '0107: staff check-in and the office both work after midnight';
  end if;
end $assert$;

-- ─────────────────────────────────────────────────────────────────────────
-- Record what this bundle applied (no-op before 0069 creates the ledger)
-- ─────────────────────────────────────────────────────────────────────────
do $ledger$
begin
  if to_regprocedure('public.fn_record_migration(text,text,text)') is null then
    raise notice 'migration ledger not present yet — nothing recorded';
    return;
  end if;
  perform public.fn_record_migration('0106_an_unpaid_school_is_closed.sql', '14_the_unpaid_school.sql');
  perform public.fn_record_migration('0107_midnight_in_karachi.sql', '14_the_unpaid_school.sql');
end $ledger$;

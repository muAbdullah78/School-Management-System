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

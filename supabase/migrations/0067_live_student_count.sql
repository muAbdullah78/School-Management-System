-- =============================================================================
-- 0067 — A school could outgrow its plan and nobody would ever find out
--
-- subscriptions.student_count is a STORED number, and it drives everything the
-- operator uses to price a school: the console's "N students / limit",
-- limit_state, over_limit_flagged_at, suggested_plan, needs_upgrade, and the
-- licence banner the SCHOOL itself sees.
--
-- Before this migration it was refreshed from exactly two places:
-- fn_activate_subscription (0064) and the manual "Refresh counts" button. No
-- trigger on students, none on enrollments. So the number was whatever it had
-- been the last time a human clicked.
--
-- Proven on a real database — 400 children actually enrolled, Starter plan:
--
--   actually_enrolled | console_shows | plan_allows | flagged_over_limit
--   ------------------+---------------+-------------+--------------------
--                 400 |             0 |         100 | f
--
-- and the school's own licence banner also read 0 of 100, so neither side ever
-- learned. A school on Starter (Rs 9,500) that should be on Institution
-- (Rs 35,000) is Rs 25,500 a year of invisible revenue, per school. It is also
-- what made the owner's console show "0 students" for a school with two.
--
-- 0064 fixed the RENEWAL path — it re-counts before deciding, so it cannot price
-- a school onto a plan it has outgrown. This fixes the DETECTION path, which was
-- the half that tells anybody to act.
--
-- WHY A STATEMENT-LEVEL TRIGGER
--
-- Row-level would call fn_refresh_student_count once per row. That function
-- counts the whole school, updates subscriptions and upserts a snapshot — so
-- importing 400 pupils would do that 400 times, and every one of them takes a
-- row lock on the same subscriptions row, serialising the import against itself.
--
-- REFERENCING NEW TABLE (Postgres 10+) lets one statement see every row it
-- touched, so a 400-row insert refreshes once. The transition table also carries
-- school_id, which is what makes a statement trigger able to scope the work at
-- all — without it a statement-level trigger has no idea which school changed.
--
-- Re-runnable.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. The trigger function
--
-- One function for both tables and all three verbs. Which transition tables
-- exist depends on the verb — an INSERT has no OLD, a DELETE has no NEW — so it
-- branches on TG_OP and refreshes each affected school exactly once.
-- ---------------------------------------------------------------------------
create or replace function public.fn__refresh_counts_touched()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_schools uuid[];
  v_school  uuid;
begin
  -- Branch on TG_OP rather than declaring both transition tables everywhere:
  -- Postgres refuses OLD TABLE on an INSERT trigger and NEW TABLE on a DELETE
  -- one ("OLD TABLE can only be specified for a DELETE or UPDATE trigger"), so
  -- only the pair that exists for this verb may be named. plpgsql plans a
  -- statement the first time it is reached, so the unreachable branches never
  -- try to resolve a table that is not there.
  if tg_op = 'INSERT' then
    select array_agg(distinct school_id) into v_schools
      from touched_new where school_id is not null;
  elsif tg_op = 'DELETE' then
    select array_agg(distinct school_id) into v_schools
      from touched_old where school_id is not null;
  else
    select array_agg(distinct s) into v_schools
      from (select school_id as s from touched_new
            union
            select school_id as s from touched_old) x
     where s is not null;
  end if;

  foreach v_school in array coalesce(v_schools, '{}'::uuid[])
  loop
    -- Guard, not laziness: a school row can exist before its subscription does
    -- (the signup Edge Function creates the school, then the subscription), and
    -- fn_refresh_student_count raises 'No subscription for school %'. A pupil
    -- import must never fail because of a counter.
    if exists (select 1 from public.subscriptions where school_id = v_school) then
      perform public.fn_refresh_student_count(v_school);
    end if;
  end loop;
  return null;
end;
$$;

revoke all on function public.fn__refresh_counts_touched() from public;

-- ---------------------------------------------------------------------------
-- 2. The triggers
--
-- On enrollments AND students, because fn_count_students joins both: an
-- enrolment appearing or its status changing moves the count, and so does a
-- pupil being marked withdrawn or soft-deleted while their enrolment row sits
-- untouched.
--
-- Statement-level AFTER, so a bulk import refreshes once. DEFERRABLE is
-- deliberately NOT used — 0060 learned that a deferred constraint trigger fires
-- at COMMIT, detached from the statement that caused it and impossible to catch.
-- ---------------------------------------------------------------------------
drop trigger if exists trg_enrollments_count_ins on public.enrollments;
create trigger trg_enrollments_count_ins
  after insert on public.enrollments
  referencing new table as touched_new
  for each statement execute function public.fn__refresh_counts_touched();

drop trigger if exists trg_enrollments_count_upd on public.enrollments;
create trigger trg_enrollments_count_upd
  after update on public.enrollments
  referencing new table as touched_new old table as touched_old
  for each statement execute function public.fn__refresh_counts_touched();

drop trigger if exists trg_enrollments_count_del on public.enrollments;
create trigger trg_enrollments_count_del
  after delete on public.enrollments
  referencing old table as touched_old
  for each statement execute function public.fn__refresh_counts_touched();

drop trigger if exists trg_students_count_ins on public.students;
create trigger trg_students_count_ins
  after insert on public.students
  referencing new table as touched_new
  for each statement execute function public.fn__refresh_counts_touched();

drop trigger if exists trg_students_count_upd on public.students;
create trigger trg_students_count_upd
  after update on public.students
  referencing new table as touched_new old table as touched_old
  for each statement execute function public.fn__refresh_counts_touched();

drop trigger if exists trg_students_count_del on public.students;
create trigger trg_students_count_del
  after delete on public.students
  referencing old table as touched_old
  for each statement execute function public.fn__refresh_counts_touched();

-- ---------------------------------------------------------------------------
-- 3. Bring every existing school's count up to date
--
-- Without this, a database that already has the stale number keeps it until
-- somebody edits a pupil. The owner's console showing "0 students / 100" for a
-- school with pupils is exactly that state, and a migration that fixes the
-- mechanism while leaving the wrong number on screen has not fixed the
-- complaint.
-- ---------------------------------------------------------------------------
do $backfill$
declare v_school uuid; v_n integer := 0;
begin
  for v_school in select school_id from public.subscriptions loop
    perform public.fn_refresh_student_count(v_school);
    v_n := v_n + 1;
  end loop;
  raise notice '0067: recounted % school(s)', v_n;
end;
$backfill$;

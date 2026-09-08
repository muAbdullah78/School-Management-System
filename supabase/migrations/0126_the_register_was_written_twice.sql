-- =============================================================================
-- 0126 - The audit log was the register, written a second time
--
-- MEASURED, ON A TWO-YEAR SCHOOL OF 266 CHILDREN, not estimated:
--
--   audit_log                      214,787 rows      479 MB
--   the whole rest of the database                    92 MB
--
-- Eighty-four per cent of everything the school stores is its audit log, and
-- this is the whole of it, by what the rows are about:
--
--   entity               action    rows     jsonb
--   attendance_daily     UPDATE   89,432    87 MB
--   attendance_daily     INSERT   89,634    50 MB
--   staff_attendance     INSERT   11,654   7.5 MB
--   mark_entries         INSERT   10,794   7.3 MB
--   mark_entries         UPDATE    5,295   6.4 MB
--   payments             INSERT    4,845   2.9 MB
--   everything else               ~3,100   4.5 MB
--
-- 206,809 of the 214,787 rows are the register and the mark sheet. The next
-- line down is money, at 4,845 rows, and money is not touched by this
-- migration or by any other.
--
-- WHAT THOSE ROWS SAY. This is the part that decided the change, and it was
-- read off the rows rather than assumed.
--
--   1. THE INSERTS ARE THE ROW AGAIN. audit_log holds actor, actor_role,
--      created_at and `after`. attendance_daily, mark_entries and
--      staff_attendance each carry `marked_by` and `created_at` of their own,
--      the trigger runs in the same transaction, and `after` is to_jsonb(new),
--      which IS the row. Checked on all 112,082 of them:
--
--        actor is not distinct from (after->>'marked_by')  112,082 of 112,082
--
--      There is no exception. The only field an insert audit row holds that
--      the row itself does not is actor_role, and "what title did the teacher
--      hold on the third of March" is not a question anybody asks about an
--      attendance mark. This migration gives that field up and says so.
--
--   2. THE UPDATES ARE ALL ONE BOOLEAN. Asked which keys actually differ
--      between `before` and `after` on every one of the 94,727 update rows on
--      those two tables:
--
--        entity               changed keys     rows
--        attendance_daily     {is_locked}     89,432
--        mark_entries         {is_locked}      5,295
--
--      Nothing else, anywhere. That is fn_finalize_attendance and
--      fn_lock_assessment, which set is_locked on every pupil of a section-day
--      or every mark of a test in one statement. 210 audit rows of a kilobyte
--      each to record one act by one person, and the act is already legible
--      from the row (`is_locked` is true) and from the register itself.
--
--   3. IT ALSO MADE THE AUDIT SCREEN USELESS, which is the part a school would
--      have complained about first if the screen were reachable enough to
--      complain about. Settings -> Audit log reads the most recent 300 rows.
--      A school that marked its registers this morning has 300 rows of
--      "INSERT attendance_daily" and nothing else: the discount somebody gave,
--      the payment somebody reversed and the permission somebody granted are
--      all behind 90,000 attendance marks. The log recorded everything and
--      showed nothing.
--
-- SO THE RULE, and it is deliberately narrow:
--
--   For attendance_daily, mark_entries and staff_attendance ONLY, the trigger
--   skips the audit row in exactly two cases:
--
--     (a) an INSERT, because the audit row is a copy of the row; and
--     (b) an UPDATE whose only difference is is_locked going false -> true,
--         or which changed nothing at all because somebody pressed Save
--         twice. An audit row whose `before` equals its `after` records
--         nothing by definition.
--
--   Everything else keeps its full audit row. A status changed from present to
--   absent, a mark changed from 45 to 40, an absence flag, a DELETE, and every
--   row of every other table including all fourteen money and permission
--   tables: unchanged, because those `before` images hold what the row cannot.
--
-- WHY (b) IS ONE-DIRECTIONAL and not "is_locked changed". Reopening a
-- finalised register is audited by fn_unlock_attendance (0121) as one
-- ATTENDANCE_UNLOCK row carrying the reason, so the per-pupil rows for an
-- unlock are redundant too and skipping them would save another few thousand.
-- It is still wrong to skip them. Today fn_unlock_attendance is the only route
-- that sets is_locked back to false; the day a second route is added and its
-- author forgets the audit row, a one-directional skip still records it and a
-- symmetric one loses it silently. A few thousand rows is a cheap price for
-- not having to be right about the future.
--
-- WHAT THE SKIP WOULD HAVE COST, AND THE TWO ROWS THAT PAY IT BACK. Skipping
-- (b) throws away the one thing those 94,727 rows did answer: who closed the
-- day. Nothing else recorded it, because fn_finalize_attendance and
-- fn_lock_assessment wrote no audit row of their own. So both now write one,
-- exactly as fn_unlock_attendance already does:
--
--   ATTENDANCE_FINALIZE   one row per section-day, entity_id = the date
--   ASSESSMENT_LOCK       one row per test, entity_id = the assessment
--
-- 210 rows become 1, and the 1 says what happened. The audit log gets BETTER
-- and not merely smaller: "Miss Ayesha finalised 5-A for 3 March, 34 pupils"
-- is a sentence, and 34 rows each saying "a boolean changed" is not.
--
-- AND THE ROWS ALREADY WRITTEN. A rule that only applies going forward leaves
-- every existing school paying for the old one, which is the actual complaint
-- that started this. So the rows the new rule would not have written are
-- removed, and NOTHING IS LOST DOING IT:
--
--   * the update rows are FOLDED FIRST into the ATTENDANCE_FINALIZE and
--     ASSESSMENT_LOCK rows they should always have been, carrying the original
--     actor, role, timestamp and count, and only the exact ids that were
--     folded are then deleted;
--   * an insert row is deleted only if its own actor equals the marked_by on
--     its own `after` image, so the losslessness is checked per row rather
--     than trusted from the survey above.
--
-- Anything that fails either test is KEPT. The migration reports what it kept
-- and why.
--
-- DELETING DOES NOT RETURN THE SPACE, and this is the one thing the reader has
-- to do by hand. Postgres marks a deleted row dead and reuses the page later;
-- the file on disk does not shrink. Demonstrated: a table of 40,000 rows at
-- 79 MB, minus 39,800 rows, is still 79 MB, and `vacuum full` rewrites it to
-- 408 kB. So AFTER this bundle, run this on its own, because VACUUM cannot run
-- inside a transaction and a pasted file is one:
--
--     vacuum full public.audit_log;
--
-- Until that runs the dashboard keeps reporting the old size.
--
-- Re-runnable. Idempotent: the trigger rewrite detects its own text, the two
-- functions are restated, and the fold-and-delete finds nothing left to do.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. THE TRIGGER
--
-- Rewritten programmatically and asserted, exactly as 0092 rewrote it and for
-- the same reason: restating the whole function would silently discard
-- whatever a later migration changed about it. 0092 itself is the proof that
-- happens.
--
-- The guard goes at the very TOP of the body, above
-- `select role into v_role from public.profiles`, so a skipped row does not
-- pay for a profiles lookup either. Its own nested declare block holds the two
-- jsonb images, so the outer declare is left alone and the comparison builds
-- each of them once.
-- ---------------------------------------------------------------------------
do $audit$
declare v_src text; v_new text; v_from text; v_to text;
begin
  v_src := pg_get_functiondef('public.audit_trigger()'::regprocedure);

  -- Already rewritten by an earlier run of this file.
  if position('0126' in v_src) > 0 then
    raise notice '0126: audit_trigger() already skips the duplicate register rows';
    return;
  end if;

  -- THE ANCHOR CARRIES NO NEWLINE, AND THE FIRST VERSION DID.
  --
  -- It read E'begin\n  select role into v_role ...', which matches the body as
  -- this repository stores it and NOT the body of a bundle pasted from an
  -- editor that writes CRLF: there the stored text has \r\n and the anchor
  -- finds nothing, so the migration stopped with its own "has been rewritten
  -- since" exception on a database where nothing had been rewritten at all.
  -- Caught by scripts/preflight.sh, which applies every bundle a second time
  -- with CRLF line endings for exactly this. 0092 edits the same function and
  -- was never exposed to it, because its anchor is a single line by luck.
  v_from := '  select role into v_role from public.profiles where id = v_actor;';
  if position(v_from in v_src) = 0 then
    raise exception
      '0126: audit_trigger() no longer contains the line this migration inserts '
      'its guard above. It has been rewritten since, and the guard must be '
      're-read against the new text rather than applied blind. It belongs at the '
      'TOP of the body, above the profiles lookup, and it skips the audit row in '
      'three cases and only on attendance_daily, mark_entries and '
      'staff_attendance: an INSERT; an UPDATE that changed nothing; and an '
      'UPDATE whose only difference is is_locked going false to true.';
  end if;

  v_to :=
    '  -- THE REGISTER IS NOT WRITTEN TWICE (0126). Two cases, on three tables,' || E'\n' ||
    '  -- where the audit row holds nothing the audited row does not:' || E'\n' ||
    '  --   (a) a first entry: `after` IS the row, and actor IS its marked_by;' || E'\n' ||
    '  --   (b) finalising: one boolean, set on every pupil of a section-day at' || E'\n' ||
    '  --       once, and now recorded once as ATTENDANCE_FINALIZE /' || E'\n' ||
    '  --       ASSESSMENT_LOCK by the function that does it.' || E'\n' ||
    '  -- One-directional on purpose: an unlock is still audited row by row, so' || E'\n' ||
    '  -- a future second unlock path cannot go unrecorded by forgetting to.' || E'\n' ||
    '  if tg_table_name in (''attendance_daily'', ''mark_entries'', ''staff_attendance'') then' || E'\n' ||
    '    declare' || E'\n' ||
    '      v_o jsonb;' || E'\n' ||
    '      v_n jsonb;' || E'\n' ||
    '    begin' || E'\n' ||
    '      if tg_op = ''INSERT'' then' || E'\n' ||
    '        return coalesce(new, old);' || E'\n' ||
    '      end if;' || E'\n' ||
    '      if tg_op = ''UPDATE'' then' || E'\n' ||
    '        v_o := to_jsonb(old);' || E'\n' ||
    '        v_n := to_jsonb(new);' || E'\n' ||
    '        if v_o - ''is_locked'' - ''updated_at''' || E'\n' ||
    '             = v_n - ''is_locked'' - ''updated_at'' then' || E'\n' ||
    '          -- Nothing but the lock and the touch time differs. So either' || E'\n' ||
    '          -- nothing changed at all (somebody pressed Save twice), or the' || E'\n' ||
    '          -- day was closed, which the function that closed it now records' || E'\n' ||
    '          -- once. An UNLOCK is NOT skipped: see the migration header.' || E'\n' ||
    '          if v_o ->> ''is_locked'' is not distinct from v_n ->> ''is_locked''' || E'\n' ||
    '             or (v_o ->> ''is_locked'' = ''false''' || E'\n' ||
    '                 and v_n ->> ''is_locked'' = ''true'') then' || E'\n' ||
    '            return coalesce(new, old);' || E'\n' ||
    '          end if;' || E'\n' ||
    '        end if;' || E'\n' ||
    '      end if;' || E'\n' ||
    '    end;' || E'\n' ||
    '  end if;' || E'\n' ||
    v_from;

  v_new := replace(v_src, v_from, v_to);
  if v_new = v_src then
    raise exception '0126: the audit_trigger() rewrite changed nothing';
  end if;
  execute v_new;
  raise notice '0126: audit_trigger() no longer copies the register into the '
    'audit log';
end $audit$;

do $assert$
declare v_src text := pg_get_functiondef('public.audit_trigger()'::regprocedure);
begin
  if position('0126' in v_src) = 0
     or position('tg_op = ''INSERT'' then' in v_src) = 0
     or position('- ''is_locked'' - ''updated_at''' in v_src) = 0 then
    raise exception '0126: audit_trigger() is not guarded after the rewrite';
  end if;
  -- And 0092's guard, which sits below this one, must still be there: an edit
  -- that dropped it would let one missing school row refuse every write again.
  if position('not exists (select 1 from public.schools s where s.id = v_school)'
              in v_src) = 0 then
    raise exception '0126: the rewrite lost 0092''s missing-school guard';
  end if;
end $assert$;

-- ---------------------------------------------------------------------------
-- 2. FINALISING A REGISTER SAYS SO, ONCE
--
-- Restated rather than patched: it is twenty lines, 0025 is its last author,
-- and the shape of the audit row is copied deliberately from
-- fn_unlock_attendance (0121) so the pair reads as a pair on the screen.
--
-- The audit row is written only when rows were actually locked. A finalise
-- that matched nothing is not an event, and an audit log with rows in it for
-- things that did not happen is the same failure as one with 90,000 rows for
-- one thing that did.
--
-- The absence-message queueing keeps its own exception block, and keeps it
-- AFTER the audit row: a school whose WhatsApp queue is misconfigured still
-- gets a record of who closed the register.
-- ---------------------------------------------------------------------------
create or replace function public.fn_finalize_attendance(
  p_session_id uuid, p_class_id uuid, p_section_id uuid, p_date date
) returns integer language plpgsql security definer set search_path = public as $$
declare v_count integer;
begin
  if not public.has_role('owner','principal','admin_clerk','class_teacher','subject_teacher') then
    raise exception 'Not permitted to finalize attendance';
  end if;
  if not public.fn_may_manage_class(p_session_id, p_class_id, p_section_id) then
    raise exception 'You can only finalize your assigned class';
  end if;
  -- `and not ad.is_locked`, WHICH IS NEW AND IS A SECOND FIX. Without it the
  -- statement rewrites every row of the section-day whether it was open or
  -- not, so the number it returns is "pupils in this section-day" while the
  -- screen prints it as "Finalized & locked 34 rows", and finalising an
  -- already finalised day reported 34 again. It also made this migration's own
  -- audit row wrong: a second press recorded a second closing of a day that
  -- was already closed. Now it locks what is open, says how many, and a second
  -- press is a no-op that records nothing. A partly marked day gets the right
  -- answer too: mark 30 of 34, finalise (30), mark the last 4, finalise again
  -- (4, not 34).
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

  -- ONE ROW FOR THE ACT, replacing one row per pupil. Same entity and same
  -- entity_id shape as ATTENDANCE_UNLOCK, so a reader following one section-day
  -- sees it closed and reopened in the same list.
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

-- ---------------------------------------------------------------------------
-- 3. LOCKING A TEST SAYS SO, ONCE
--
-- `assessments` carries no audit trigger of its own (seventeen tables do, and
-- that is not one of them), so before this the ONLY record that a test had
-- been locked was the per-mark rows. Skipping those without this would have
-- left locking a test entirely untraced.
--
-- The count is read before the update, because `get diagnostics` after two
-- updates reports the second.
-- ---------------------------------------------------------------------------
create or replace function public.fn_lock_assessment(p_assessment_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v_session uuid; v_class uuid; v_section uuid; v_marks integer;
begin
  if not public.has_role('owner','principal','admin_clerk','class_teacher','subject_teacher') then
    raise exception 'Not permitted to lock this test';
  end if;
  perform public.assert_own('assessments', p_assessment_id);
  select session_id, class_id, section_id into v_session, v_class, v_section
  from public.assessments where id = p_assessment_id;
  if v_session is null then raise exception 'Assessment not found'; end if;
  if not public.fn_may_manage_class(v_session, v_class, v_section) then
    raise exception 'You can only lock tests for your assigned class';
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

-- ---------------------------------------------------------------------------
-- 4. THE ROWS ALREADY WRITTEN: FOLD, THEN DELETE EXACTLY WHAT WAS FOLDED
--
-- Order matters and it is fold-first. The other way round loses the actor and
-- the timestamp, and there is no getting them back.
--
-- The ids that were folded are collected into a temp table and only those are
-- deleted. A lock-only update row whose enrolment or assessment can no longer
-- be found does not become an ATTENDANCE_FINALIZE row, so it is not in the
-- table, so it survives: the migration would rather leave a row it cannot
-- summarise than delete one it cannot replace.
-- ---------------------------------------------------------------------------
do $fold$
declare
  v_att_folded  bigint := 0;
  v_att_new     bigint := 0;
  v_asm_folded  bigint := 0;
  v_asm_new     bigint := 0;
  v_ins         bigint := 0;
  v_noop        bigint := 0;
  v_kept_upd    bigint := 0;
  v_kept_ins    bigint := 0;
begin
  -- Nothing to do on a database with no audit log at all, which is every fresh
  -- install. Said out loud so a school pasting this does not wonder.
  if not exists (
    select 1 from public.audit_log
     where entity in ('attendance_daily', 'mark_entries', 'staff_attendance')
       and action in ('INSERT', 'UPDATE') limit 1) then
    raise notice '0126: no register rows in the audit log to fold or remove';
    return;
  end if;

  create temp table if not exists tmp_0126_folded (id bigint primary key)
    on commit drop;
  delete from tmp_0126_folded;

  -- --- 4a. The register, per section-day ------------------------------------
  insert into tmp_0126_folded (id)
  select a.id
    from public.audit_log a
    join public.enrollments e on e.id = (a.before ->> 'enrollment_id')::uuid
   where a.action = 'UPDATE'
     and a.entity = 'attendance_daily'
     and a.before ->> 'is_locked' = 'false'
     and a.after  ->> 'is_locked' = 'true'
     and a.before - 'is_locked' - 'updated_at' = a.after - 'is_locked' - 'updated_at'
  on conflict (id) do nothing;
  get diagnostics v_att_folded = row_count;

  insert into public.audit_log (
    school_id, actor, actor_role, action, entity, entity_id, before, after, created_at)
  select a.school_id, a.actor, a.actor_role,
         'ATTENDANCE_FINALIZE', 'attendance_daily', a.before ->> 'attendance_date',
         jsonb_build_object('locked', false),
         jsonb_build_object('locked', true, 'rows', count(*),
                            'session_id', e.session_id, 'class_id', e.class_id,
                            'section_id', e.section_id, 'rebuilt_by', '0126'),
         min(a.created_at)
    from public.audit_log a
    join tmp_0126_folded f on f.id = a.id
    join public.enrollments e on e.id = (a.before ->> 'enrollment_id')::uuid
   where a.entity = 'attendance_daily'
   group by a.school_id, a.actor, a.actor_role, a.before ->> 'attendance_date',
            e.session_id, e.class_id, e.section_id;
  get diagnostics v_att_new = row_count;

  -- --- 4b. The mark sheet, per test -----------------------------------------
  insert into tmp_0126_folded (id)
  select a.id
    from public.audit_log a
    join public.assessments s on s.id = (a.before ->> 'assessment_id')::uuid
   where a.action = 'UPDATE'
     and a.entity = 'mark_entries'
     and a.before ->> 'is_locked' = 'false'
     and a.after  ->> 'is_locked' = 'true'
     and a.before - 'is_locked' - 'updated_at' = a.after - 'is_locked' - 'updated_at'
  on conflict (id) do nothing;
  get diagnostics v_asm_folded = row_count;

  insert into public.audit_log (
    school_id, actor, actor_role, action, entity, entity_id, before, after, created_at)
  select a.school_id, a.actor, a.actor_role,
         'ASSESSMENT_LOCK', 'assessments', s.id::text,
         jsonb_build_object('locked', false),
         jsonb_build_object('locked', true, 'marks', count(*),
                            'session_id', s.session_id, 'class_id', s.class_id,
                            'section_id', s.section_id, 'rebuilt_by', '0126'),
         min(a.created_at)
    from public.audit_log a
    join tmp_0126_folded f on f.id = a.id
    join public.assessments s on s.id = (a.before ->> 'assessment_id')::uuid
   where a.entity = 'mark_entries'
   group by a.school_id, a.actor, a.actor_role, s.id, s.session_id, s.class_id,
            s.section_id;
  get diagnostics v_asm_new = row_count;

  delete from public.audit_log a using tmp_0126_folded f where f.id = a.id;

  -- --- 4c. Updates that changed nothing -------------------------------------
  -- `before` equals `after`, so the row records nothing. There were none of
  -- these in the school this was measured on, because the seed marks each
  -- section-day once; a real school where a teacher presses Save twice has one
  -- per pupil per press.
  delete from public.audit_log a
   where a.action = 'UPDATE'
     and a.entity in ('attendance_daily', 'mark_entries', 'staff_attendance')
     and a.before - 'updated_at' = a.after - 'updated_at';
  get diagnostics v_noop = row_count;

  -- --- 4d. The first entries, checked one at a time -------------------------
  -- `actor is not distinct from marked_by` is the whole claim, and it is made
  -- of the row being deleted rather than of the survey in the header. A row
  -- where they differ is a row that holds something, so it stays.
  delete from public.audit_log a
   where a.action = 'INSERT'
     and a.entity in ('attendance_daily', 'mark_entries', 'staff_attendance')
     and a.actor is not distinct from (a.after ->> 'marked_by')::uuid;
  get diagnostics v_ins = row_count;

  select count(*) into v_kept_ins from public.audit_log a
   where a.action = 'INSERT'
     and a.entity in ('attendance_daily', 'mark_entries', 'staff_attendance');
  select count(*) into v_kept_upd from public.audit_log a
   where a.action = 'UPDATE'
     and a.entity in ('attendance_daily', 'mark_entries')
     and a.before ->> 'is_locked' = 'false'
     and a.after  ->> 'is_locked' = 'true'
     and a.before - 'is_locked' - 'updated_at' = a.after - 'is_locked' - 'updated_at';
  -- 4c cannot leave a no-op row behind, so this is the fold's residue only.

  raise notice '0126: % register locks folded into % ATTENDANCE_FINALIZE rows',
    v_att_folded, v_att_new;
  raise notice '0126: % mark locks folded into % ASSESSMENT_LOCK rows',
    v_asm_folded, v_asm_new;
  raise notice '0126: % first-entry rows removed (each one checked: its actor '
    'was the marked_by on its own row)', v_ins;
  if v_noop > 0 then
    raise notice '0126: % rows removed whose before image equalled their after '
      'image, so they recorded nothing', v_noop;
  end if;
  if v_kept_ins > 0 then
    raise notice '0126: % first-entry rows KEPT, because their actor is not the '
      'marked_by on the row they describe, so they hold something the row does '
      'not', v_kept_ins;
  end if;
  if v_kept_upd > 0 then
    raise notice '0126: % lock rows KEPT, because the enrolment or the test they '
      'point at could not be found, so they could not be summarised', v_kept_upd;
  end if;
  raise notice '0126: audit_log now holds % rows. Run `vacuum full '
    'public.audit_log;` ON ITS OWN to give the space back: a delete marks rows '
    'dead and does not shrink the file.',
    (select count(*) from public.audit_log);
end $fold$;

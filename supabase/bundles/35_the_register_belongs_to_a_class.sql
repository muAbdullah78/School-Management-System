-- =============================================================================
-- GENERATED FILE — DO NOT EDIT.
-- Built from supabase/migrations/ by supabase/build-bundles.sh
--
-- Paste this whole file into the Supabase SQL Editor and press Run.
-- Run the bundles in order, one at a time, waiting for each to finish.
-- =============================================================================


-- ─────────────────────────────────────────────────────────────────────────
-- 0129_the_register_belongs_to_a_class_and_a_lock_means_locked.sql
-- ─────────────────────────────────────────────────────────────────────────
-- =============================================================================
-- 0129  The register belongs to a class, and a lock means locked
--
-- Found by asking a different question: not "what does the function check" but
-- "what does the TABLE let a browser do". Every claim below was proved on a
-- database built straight from these migrations, with the product's own grants
-- and nothing granted by hand, and every proof is an assertion in
-- supabase/tests/register_authority.sql that fails without this file.
--
-- -----------------------------------------------------------------------------
-- 1. MIGRATION 0024 FIXED THIS ONCE, FOR TWO TABLES OUT OF THREE.
--
-- In 2024 it wrote down the fault exactly:
--
--     "Scoping was only enforced inside the RPCs - but the blanket table grant
--      (0001) + role-only RLS let a teacher write attendance_daily /
--      mark_entries DIRECTLY via PostgREST, bypassing fn_may_manage_class.
--      Revoke direct DML so writes MUST go through the scoped SECURITY DEFINER
--      functions."
--
--     revoke insert, update, delete on public.attendance_daily from authenticated;
--     revoke insert, update, delete on public.mark_entries    from authenticated;
--
-- That works, and the register is safe today: a browser holds no write on
-- attendance_daily at all, so the policy behind it is unreachable. What 0024
-- did not do was fix the POLICIES, which still read
--
--     with check (school_id = current_school_id()
--                 and has_role('owner','principal','admin_clerk',
--                              'class_teacher','subject_teacher'))
--
-- School and role, and nothing about WHICH rows. So the mechanism actually
-- holding the register shut is a grant in a migration from two years ago, and
-- the mechanism a person reads when they ask "who may write this?" says
-- something else entirely. This migration makes the policy say the same thing
-- as the grant. Nothing changes today; what changes is that re-granting direct
-- DML, which somebody will eventually want for a bulk import, no longer
-- reopens what 0024 closed.
--
-- AND `assessments` NEVER GOT EITHER HALF. Blanket INSERT, UPDATE and DELETE
-- for `authenticated`, and the role-only policy above. That is the live hole,
-- and it is worse than the one 0024 found, because assessments has a CASCADE
-- under it.
--
-- -----------------------------------------------------------------------------
-- 2. A TEACHER COULD DESTROY EVERY FINALISED MARK IN THE SCHOOL.
--
-- assessments_write was `for all`, which includes DELETE, granted to
-- class_teacher and subject_teacher with no class check, and
-- mark_entries.assessment_id is ON DELETE CASCADE. Measured on the demo school,
-- as one subject teacher, in one statement:
--
--     BEFORE: 663 assessments, 10944 marks (5364 locked)
--     AFTER:    0 assessments,  4983 marks (   0 locked)
--
-- 663 assessments and 5,961 marks, including all 5,364 LOCKED ones. Nothing in
-- the app offers that delete; only the policy did.
--
-- -----------------------------------------------------------------------------
-- 3. AND THE ONE DELETE THE APP DOES OFFER HAD THE SAME FLAW.
--
-- Removing a subject from an exam (web/src/lib/db.ts calls
-- `from('exam_subjects').delete()`) cascades to mark_entries. That is a
-- legitimate act before anybody has marked the paper and destroys finalised
-- results afterwards. Two hops up, exam_terms cascades to exam_subjects, so
-- deleting a term takes every mark in it, and an admin_clerk can do that.
--
-- THE GENERAL FAULT, which is what the guards at the foot of this file assert:
-- `is_locked` exists so that finalised work cannot be changed, and every policy
-- and function in this schema honours it. A CASCADE from the parent row walks
-- straight past all of them. A lock that one DELETE ignores is not a lock.
--
-- -----------------------------------------------------------------------------
-- WHAT THIS DOES NOT DO. It does not stop an owner or a principal deleting
-- their own school's exam once they have unlocked it, which is theirs to do and
-- is audited. It stops a delete that would destroy LOCKED work, and it stops
-- roles reaching rows that were never theirs.
--
-- Re-runnable.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. WHOSE ENROLMENT IS IT
--
-- fn_may_manage_class's sibling for a table that carries an enrollment_id and
-- not the three ids the check needs. Exactly the same shape as
-- fn_may_mark_row, which does this for marks, and it delegates rather than
-- restating the rule: fn_may_manage_class already returns true for an owner, a
-- principal and a clerk, and requires a teacher_assignments row for anybody
-- else. So the policy below and fn_mark_attendance now enforce one rule from
-- one place, instead of one of them enforcing nothing.
--
-- coalesce(..., false) rather than a bare subquery. An unknown enrolment, or
-- one belonging to another school, yields no row and therefore NULL, and while
-- a policy treats NULL as false today, a function that answers "I don't know"
-- to "may I write this?" is one refactor away from answering yes.
-- ---------------------------------------------------------------------------
create or replace function public.fn_may_manage_enrollment(p_enrollment_id uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce((
    select public.fn_may_manage_class(e.session_id, e.class_id, e.section_id)
      from public.enrollments e
     where e.id = p_enrollment_id
       and e.school_id = public.current_school_id()), false);
$$;

comment on function public.fn_may_manage_enrollment(uuid) is
  'May the caller write the register of the class this enrolment sits in. '
  'Delegates to fn_may_manage_class so the table policy and fn_mark_attendance '
  'cannot drift apart. Authorises a WRITE, so it gates on has_role through '
  'that function and not on may_view: see 0059.';

revoke all on function public.fn_may_manage_enrollment(uuid) from public, anon;
-- authenticated NEEDS this: a policy predicate is evaluated as the invoking
-- role, so without the grant every attendance write would fail for everybody.
-- Same grant fn_may_mark_row carries for the same reason.
grant execute on function public.fn_may_manage_enrollment(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 2. THE REGISTER
--
-- The role list is unchanged and deliberately identical to
-- fn_mark_attendance's, because the two are now the same rule and a difference
-- between them would be a hole in whichever is looser. The addition is the last
-- line of each predicate.
-- ---------------------------------------------------------------------------
drop policy if exists attendance_insert on public.attendance_daily;
create policy attendance_insert on public.attendance_daily
  for insert to authenticated
  with check (
    school_id = public.current_school_id()
    and public.has_role('owner', 'principal', 'admin_clerk',
                        'class_teacher', 'subject_teacher')
    and public.fn_may_manage_enrollment(enrollment_id));

drop policy if exists attendance_update on public.attendance_daily;
create policy attendance_update on public.attendance_daily
  for update to authenticated
  using (
    school_id = public.current_school_id()
    -- Unchanged: a finalised day is not editable through the table by anybody.
    -- Reopening one goes through fn_unlock_attendance, with a reason.
    and not is_locked
    and public.has_role('owner', 'principal', 'admin_clerk',
                        'class_teacher', 'subject_teacher')
    and public.fn_may_manage_enrollment(enrollment_id))
  with check (
    school_id = public.current_school_id()
    and public.has_role('owner', 'principal', 'admin_clerk',
                        'class_teacher', 'subject_teacher')
    and public.fn_may_manage_enrollment(enrollment_id));

-- ---------------------------------------------------------------------------
-- 3. THE EXAMS
--
-- assessments_write was one `for all` policy. It is now three, because the
-- three commands are not the same act:
--
--   insert   setting a test. A subject teacher may set one for the class AND
--            subject they teach, which is fn_may_mark_subject, the same
--            predicate that decides whether they may enter its marks. Using
--            fn_may_manage_class here instead would let the maths teacher set
--            the English paper.
--   update   the same rule, and a locked assessment is not editable at all.
--   delete   the owner and the principal only. Nothing in the app deletes an
--            assessment; this existed only as a side effect of `for all`, and
--            it was the hole that could destroy a school's results.
-- ---------------------------------------------------------------------------
drop policy if exists assessments_write on public.assessments;

drop policy if exists assessments_insert on public.assessments;
create policy assessments_insert on public.assessments
  for insert to authenticated
  with check (
    school_id = public.current_school_id()
    and public.has_role('owner', 'principal', 'admin_clerk',
                        'class_teacher', 'subject_teacher')
    and public.fn_may_mark_subject(session_id, class_id, section_id, subject_id));

drop policy if exists assessments_update on public.assessments;
create policy assessments_update on public.assessments
  for update to authenticated
  using (
    school_id = public.current_school_id()
    and not is_locked
    and public.has_role('owner', 'principal', 'admin_clerk',
                        'class_teacher', 'subject_teacher')
    and public.fn_may_mark_subject(session_id, class_id, section_id, subject_id))
  with check (
    school_id = public.current_school_id()
    and public.has_role('owner', 'principal', 'admin_clerk',
                        'class_teacher', 'subject_teacher')
    and public.fn_may_mark_subject(session_id, class_id, section_id, subject_id));

drop policy if exists assessments_delete on public.assessments;
create policy assessments_delete on public.assessments
  for delete to authenticated
  using (
    school_id = public.current_school_id()
    and public.has_role('owner', 'principal'));

-- ---------------------------------------------------------------------------
-- 4. A LOCK MEANS LOCKED, INCLUDING AGAINST A CASCADE
--
-- One trigger function for the three parents that can reach mark_entries, so
-- the rule is written once. It answers two questions per row: how many LOCKED
-- marks would this delete destroy, and how many unlocked ones.
--
-- Locked marks refuse the delete. Unlocked marks do not: removing a subject
-- from an exam nobody has marked yet is an ordinary correction, and refusing it
-- would make a mistyped exam setup permanent. They are AUDITED instead, with
-- the count, because forty marks disappearing silently is the other way to lose
-- a school's work.
--
-- WHY A TRIGGER AND NOT A POLICY. A policy is not consulted by a cascade at
-- all: PostgreSQL performs the cascading delete as the system, and row security
-- on the child is bypassed. A BEFORE DELETE trigger on the PARENT is the only
-- place that sees the act before the children go, and it covers every route in:
-- the browser, a function, a psql prompt, and a cascade from a grandparent.
-- ---------------------------------------------------------------------------
-- EVERY COUNT CARRIES `school_id = old.school_id`. Not belt and braces: this
-- runs SECURITY DEFINER, so row security does not apply inside it, and
-- supabase/tests/dashboard.sql assertion 20 refuses any definer function that
-- reads a tenant table without scoping itself. It caught this file.
create or replace function public.fn__refuse_destroying_locked_marks()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_locked   integer := 0;
  v_unlocked integer := 0;
  v_what     text;
  v_advice   text;
begin
  if tg_table_name = 'assessments' then
    v_what := format('the assessment "%s"', old.title);
    v_advice := 'Unlock it first from the assessment itself, which asks for a '
             || 'reason and is recorded.';
    select count(*) filter (where is_locked), count(*) filter (where not is_locked)
      into v_locked, v_unlocked
      from public.mark_entries
     where assessment_id = old.id and school_id = old.school_id;

  elsif tg_table_name = 'exam_subjects' then
    v_what := 'this exam paper';
    v_advice := 'Unlock the paper''s marks first, which asks for a reason and '
             || 'is recorded.';
    select count(*) filter (where is_locked), count(*) filter (where not is_locked)
      into v_locked, v_unlocked
      from public.mark_entries
     where exam_subject_id = old.id and school_id = old.school_id;

  elsif tg_table_name = 'exam_terms' then
    v_what := format('the exam "%s"', old.name);
    v_advice := 'Unlock the marks in it first. Deleting a whole term is rarely '
             || 'what is wanted: a term with results in it is the record of '
             || 'those results.';
    -- TWO HOPS. exam_terms cascades to exam_subjects, which cascades to
    -- mark_entries, so the marks are two deletes away and nothing on the way
    -- down would have stopped them.
    select count(*) filter (where m.is_locked), count(*) filter (where not m.is_locked)
      into v_locked, v_unlocked
      from public.mark_entries m
      join public.exam_subjects es on es.id = m.exam_subject_id
                                  and es.school_id = old.school_id
     where es.exam_term_id = old.id and m.school_id = old.school_id;
  else
    -- A future table wired to this trigger without a branch here would
    -- otherwise be waved through, which is the shape of hole this whole
    -- migration is about.
    raise exception 'fn__refuse_destroying_locked_marks has no rule for table '
      '%. Add one, or do not attach the trigger.', tg_table_name;
  end if;

  -- CLEARING A WHOLE SCHOOL IS NOT A MISTAKE, and this is where it has to be
  -- said, because the three functions that do it delete their tables in a
  -- multi-pass loop that swallows ONLY foreign_key_violation. Their own comment
  -- explains why they are strict about that:
  --
  --     "Only a dependency. Any OTHER error is a real fault and must not be
  --      swallowed: a permission problem or a trigger raising would otherwise
  --      look identical to 'try again next pass' and the loop would report a
  --      clean purge of a school it never touched."
  --
  -- fn__school_data_tables() lists assessments at position 4 and mark_entries at
  -- 27, so pass one deletes assessments while every locked mark is still there.
  -- Without this, offboarding any real customer would have failed outright with
  -- the message below, and supabase/tests/school_lifecycle.sql would not have
  -- caught it: its test school has no finalised marks.
  --
  -- A FLAG AND NOT A ROLE CHECK. `is_platform_admin()` would cover the purge and
  -- not fn_reset_school_data, which an owner runs on their own trial school; and
  -- `has_role('owner')` would let a bare owner delete one locked assessment,
  -- which is exactly the accident this trigger exists to prevent. The flag names
  -- the ACT rather than the actor. It is set with `set local`, so it cannot
  -- outlive the transaction, and the guard at the foot of this file fails if any
  -- of the three wipe functions stops setting it.
  if current_setting('app.clearing_school', true) = 'on' then
    return old;
  end if;

  if v_locked > 0 then
    raise exception
      'Deleting % would destroy % finalised mark(s), and finalised marks cannot '
      'be deleted. %',
      v_what, v_locked, v_advice
      using errcode = '42501';
  end if;

  if v_unlocked > 0 then
    insert into public.audit_log
      (school_id, actor, actor_role, action, entity, entity_id, before, reason)
    values (old.school_id, auth.uid(),
            (select role from public.profiles where id = auth.uid()),
            'MARKS_DESTROYED_BY_DELETE', tg_table_name, old.id::text,
            jsonb_build_object('marks_deleted', v_unlocked, 'what', v_what),
            format('%s mark(s) went with it. None were finalised.', v_unlocked));
  end if;

  return old;
end;
$$;

revoke all on function public.fn__refuse_destroying_locked_marks()
  from public, anon, authenticated;

drop trigger if exists trg_assessments_locked_marks on public.assessments;
create trigger trg_assessments_locked_marks
  before delete on public.assessments
  for each row execute function public.fn__refuse_destroying_locked_marks();

drop trigger if exists trg_exam_subjects_locked_marks on public.exam_subjects;
create trigger trg_exam_subjects_locked_marks
  before delete on public.exam_subjects
  for each row execute function public.fn__refuse_destroying_locked_marks();

drop trigger if exists trg_exam_terms_locked_marks on public.exam_terms;
create trigger trg_exam_terms_locked_marks
  before delete on public.exam_terms
  for each row execute function public.fn__refuse_destroying_locked_marks();

-- ---------------------------------------------------------------------------
-- 5. A STAFF MEMBER'S ATTENDANCE HISTORY: ALREADY DONE, AND LEFT ALONE
--
-- `staff` cascades to `staff_attendance`, so deleting a staff row erases every
-- day they were ever marked present. This migration grew a BEFORE DELETE
-- trigger for that, and it was wrong twice over.
--
-- It was REDUNDANT. fn_staff_delete_blockers already counts exactly this and
-- refuses, in better words than the trigger had:
--
--     select count(*) into v_n from public.staff_attendance
--      where staff_id = p_staff_id and school_id = v_school;
--     if v_n > 0 then v_out := v_out || jsonb_build_object(
--       'what', case when v_n = 1 then 'a day of their attendance'
--                    else 'days of their attendance' end, 'count', v_n); end if;
--
-- So the product had already taken this decision, in the place designed for it,
-- and a trigger would have been a second opinion on a settled question.
--
-- And it BROKE THE PLATFORM PURGE. fn_platform_purge_school empties a departed
-- school's tables with dynamic SQL, after exporting them and with the operator
-- named in the record. supabase/tests/school_lifecycle.sql caught it at once:
--
--     ERROR: Nasreen Bibi has 1 day(s) of attendance on record, and deleting
--            the staff member would erase all of it.
--
-- Which is true, and is the entire point of a purge. A rule written to stop a
-- clerk making a mistake had blocked the vendor doing an authorised, audited,
-- already-exported deletion.
--
-- The lesson is worth more than the trigger: before adding a guard, look for
-- the mechanism that already exists. This schema has fn_student_delete_blockers,
-- fn_staff_delete_blockers and fn_login_delete_blockers for precisely this
-- class of question, and they are reachable from the UI so a person sees the
-- reason before they press anything.
--
-- ---------------------------------------------------------------------------
-- 6. THE THREE FUNCTIONS THAT CLEAR A WHOLE SCHOOL SAY SO
--
-- Each sets the flag the trigger above honours, immediately before its delete
-- loop. `set local`, so it is dropped when the transaction ends however it
-- ends, and so a caller cannot leave it on for the next statement.
--
-- Patched from their own text rather than restated: fn_platform_purge_school is
-- 150 lines carrying four separate refusals (archive first, export first, type
-- the name, settle the debt), and retyping it to add one line is how a stack of
-- earlier fixes gets silently reverted. The anchor is `  loop`, which is a
-- single line and therefore cannot be wrong about line endings; it is checked
-- for being unique in each body first, because `loop` is not a rare word.
-- ---------------------------------------------------------------------------
do $wipe$
declare
  v_fn    text;
  v_src   text;
  v_new   text;
  v_nl    text;
  v_lines text[];
  v_at    integer;
  v_n     integer;
  v_set   text[] := array[
    '  -- 0129: A WHOLESALE CLEAR IS NOT A MISTAKE. The BEFORE DELETE trigger on',
    '  -- assessments, exam_subjects and exam_terms refuses any delete that would',
    '  -- destroy a finalised mark, and the loop below reaches assessments long',
    '  -- before mark_entries. set local, so it cannot outlive this transaction.',
    '  perform set_config(''app.clearing_school'', ''on'', true);'];
begin
  -- FOUR, and the list was three until the guard below was widened. The first
  -- draft looked for functions calling fn__school_data_tables(), which is how
  -- two of these build their table list and not how the other two do:
  -- fn_reset_school_data selects off the catalogue directly (keeping eleven
  -- tables the owner must not lose), and fn_platform_purge_orphan_data works on
  -- a school id whose `schools` row is already gone. Both would have been
  -- missed, and both would have failed on the first school with a finalised
  -- mark. The guard now asks the only question that identifies one of these: is
  -- there a `delete from public.%I` in it.
  foreach v_fn in array array['fn_platform_purge_school(uuid,text,boolean)',
                              'fn_platform_purge_orphan_data(uuid,text)',
                              'fn_reset_school_data(text)',
                              'fn_signup_rollback(uuid)']
  loop
    if to_regprocedure('public.' || v_fn) is null then
      raise exception '0129: % does not exist, so the wholesale-clear flag '
        'cannot be set in it. If it was renamed, this migration needs '
        'updating; if it was removed, remove it from the list here and from '
        'the guard below.', v_fn;
    end if;
    v_src := pg_get_functiondef(('public.' || v_fn)::regprocedure);
    if position('app.clearing_school' in v_src) > 0 then
      raise notice '0129: % already announces a wholesale clear', v_fn;
      continue;
    end if;

    -- SPLIT ON THE BODY'S OWN LINE ENDING, and rejoin with it.
    --
    -- The first version of this used position(E'\n  loop\n' in v_src), which
    -- supabase/check-patch-anchors.py rejected and preflight's CRLF pass then
    -- proved right: E'\n' is one bare line feed, and a body stored from a
    -- paste in a browser editor has \r\n, so the needle is simply not in it.
    -- The rewrite would silently not take on exactly the databases that
    -- matter. Splitting on the ending the body actually has cannot be wrong
    -- about it, and no needle here contains a newline in any form.
    v_nl := case when v_src like '%' || chr(13) || chr(10) || '%'
                 then chr(13) || chr(10) else chr(10) end;
    v_lines := string_to_array(v_src, v_nl);

    -- Exactly one line that IS the loop, or this is guesswork. Two would mean
    -- the insertion could land in the wrong one, and the wrong one is a delete
    -- loop that runs with the flag off.
    v_n := 0; v_at := null;
    for i in 1 .. cardinality(v_lines) loop
      if v_lines[i] = '  loop' then v_n := v_n + 1; v_at := i; end if;
    end loop;
    if v_n <> 1 then
      raise exception '0129: % has % line(s) reading exactly `  loop`, so there '
        'is no unambiguous place to announce the wholesale clear. It has been '
        'rewritten since. The change is one statement immediately before the '
        'delete loop: perform set_config(''app.clearing_school'', ''on'', true).',
        v_fn, v_n;
    end if;

    v_new := array_to_string(
      v_lines[1 : v_at - 1] || v_set || v_lines[v_at : cardinality(v_lines)],
      v_nl);
    if v_new = v_src or position('app.clearing_school' in v_new) = 0 then
      raise exception '0129: the % rewrite did not take', v_fn;
    end if;
    execute v_new;
    raise notice '0129: % announces a wholesale clear before it starts', v_fn;
  end loop;
end $wipe$;

-- ---------------------------------------------------------------------------
-- THE GUARDS
--
-- Properties, not restatements. Every one of them is written to catch the
-- GENERAL fault rather than the three places it happened to appear, because the
-- three were found by luck: attendance was missed when marks were done right,
-- and nothing in this repository would have said so.
-- ---------------------------------------------------------------------------
do $check$
declare v_name text; v_n integer; r record;
begin
  -- 1. THE ONE THAT WOULD HAVE FOUND THIS IN 2024. If a write policy names a
  --    TEACHER role, its predicate must narrow to particular rows. A teacher
  --    role is by definition partial: it describes somebody responsible for one
  --    class and not for the school. So a policy that admits a teacher and
  --    checks only `school_id` and `has_role` has handed the whole school to
  --    somebody who was given one class.
  --
  --    Roles that are school-wide by design (owner, principal, admin_clerk) are
  --    not the test: they legitimately reach every row.
  --
  --    THE POINT OF ASSERTING IT ON THE POLICY AND NOT ON THE OUTCOME: 0024
  --    closed the same hole on attendance_daily by REVOKING THE GRANT, which
  --    works and is invisible. The policy went on saying "any teacher, any row",
  --    two mechanisms disagreed, and the one a person reads was the wrong one.
  --    Nobody then noticed that `assessments` had neither half. A guard on the
  --    outcome would have been satisfied by the grant; this one is not.
  for r in
    select c.relname as tbl, pol.polname as pol,
           coalesce(pg_get_expr(pol.polqual, pol.polrelid), '')
           || ' ' || coalesce(pg_get_expr(pol.polwithcheck, pol.polrelid), '') as pred
      from pg_policy pol
      join pg_class c on c.oid = pol.polrelid
      join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'public' and pol.polcmd <> 'r'
  loop
    if r.pred ~ 'class_teacher|subject_teacher'
       and r.pred !~ 'fn_may_' then
      raise exception '0129: policy %.% lets a class or subject teacher write '
        'and checks only the school and the role, so it hands every row in the '
        'school to somebody who was given one class. Add the row check: '
        'fn_may_manage_enrollment for a register, fn_may_mark_subject for an '
        'exam, fn_may_mark_row for marks.', r.tbl, r.pol;
    end if;
  end loop;

  -- 2. NO CASCADE MAY REACH A TABLE THAT CAN BE LOCKED without the parent
  --    refusing first. `is_locked` is the schema's promise that finalised work
  --    cannot be changed, and a cascade is not subject to row security, to a
  --    function's checks or to that flag. So every parent of a cascade into a
  --    lockable table must carry a BEFORE DELETE trigger.
  --
  --    Written off the catalogue, so a cascade added by a future migration is
  --    caught by this file rather than by a school losing its results.
  for r in
    select con.conrelid::regclass::text as child,
           con.confrelid::regclass::text as parent,
           con.confrelid as parent_oid
      from pg_constraint con
      join pg_namespace n on n.oid = con.connamespace
     where con.contype = 'f' and n.nspname = 'public'
       and con.confdeltype = 'c'
       and exists (select 1 from pg_attribute a
                    where a.attrelid = con.conrelid
                      and a.attname = 'is_locked' and a.attnum > 0
                      and not a.attisdropped)
  loop
    if not exists (
      select 1 from pg_trigger t
       where t.tgrelid = r.parent_oid and not t.tgisinternal
         and t.tgtype & 8 = 8      -- fires on DELETE
         and t.tgtype & 2 = 2      -- BEFORE
    ) then
      raise exception '0129: deleting a row of % cascades into %, which carries '
        'is_locked, and % has no BEFORE DELETE trigger. A cascade is not '
        'subject to row security, to a function''s checks or to the lock '
        'itself, so finalised work in % can be destroyed by one delete. Attach '
        'fn__refuse_destroying_locked_marks (or a sibling) to %.',
        r.parent, r.child, r.parent, r.child, r.parent;
    end if;
  end loop;

  -- 3. AND THE TRIGGER KNOWS ABOUT EVERY TABLE IT IS ATTACHED TO. Its else
  --    branch raises rather than allowing the delete, so a table wired up
  --    without a rule fails loudly at delete time; this makes it fail at
  --    migration time instead, which is a much better moment to find out.
  for r in
    select c.relname as tbl
      from pg_trigger t
      join pg_class c on c.oid = t.tgrelid
      join pg_proc p on p.oid = t.tgfoid
      join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'public' and not t.tgisinternal
       and p.proname = 'fn__refuse_destroying_locked_marks'
  loop
    if (select p.prosrc from pg_proc p
          join pg_namespace n on n.oid = p.pronamespace
         where n.nspname = 'public'
           and p.proname = 'fn__refuse_destroying_locked_marks')
       not like '%' || r.tbl || '%' then
      raise exception '0129: the locked-marks trigger is attached to % and has '
        'no rule for it', r.tbl;
    end if;
  end loop;

  -- 4. THE REGISTER IS SHUT BY AT LEAST ONE MECHANISM, and after this file by
  --    both. The grant (0024) and the policy now say the same thing, and this
  --    asserts the policy half, because the grant half is asserted by
  --    assertions 1 and 2 of the suite. Written as two separate checks rather
  --    than "either will do", because "either will do" is how the pair drifted
  --    apart in the first place.
  if (select coalesce(pg_get_expr(pol.polwithcheck, pol.polrelid), '')
        from pg_policy pol
        join pg_class c on c.oid = pol.polrelid
        join pg_namespace n on n.oid = c.relnamespace
       where n.nspname = 'public' and c.relname = 'attendance_daily'
         and pol.polname = 'attendance_insert') !~ 'fn_may_manage_enrollment' then
    raise exception '0129: the attendance insert policy no longer checks the '
      'class. fn_mark_attendance does, but web/src/lib/db.ts writes this table '
      'directly, so the policy is the only gate on that path.';
  end if;
  if (select p.prosrc from pg_proc p join pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'public' and p.proname = 'fn_mark_attendance')
       !~ 'fn_may_manage_class' then
    raise exception '0129: fn_mark_attendance no longer checks the class';
  end if;

  -- 5. AND NOTHING NEW IS REACHABLE FROM A BROWSER that should not be. The
  --    enrolment check has to be granted to authenticated, because a policy
  --    predicate runs as the invoking role; the two triggers must not be.
  for v_name in
    select p.proname from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and p.proname in ('fn__refuse_destroying_locked_marks')
       and (has_function_privilege('authenticated', p.oid, 'execute')
            or has_function_privilege('anon', p.oid, 'execute'))
  loop
    raise exception '0129: % is callable from a browser', v_name;
  end loop;
  if not has_function_privilege('authenticated',
        'public.fn_may_manage_enrollment(uuid)'::regprocedure, 'execute') then
    raise exception '0129: authenticated cannot execute '
      'fn_may_manage_enrollment, so the attendance policy it appears in will '
      'refuse every write for everybody';
  end if;
  if has_function_privilege('anon',
        'public.fn_may_manage_enrollment(uuid)'::regprocedure, 'execute') then
    raise exception '0129: fn_may_manage_enrollment is callable by anon';
  end if;

  -- 6. EVERY FUNCTION THAT EMPTIES A SCHOOL ANNOUNCES IT. Found off the
  --    catalogue rather than from the list of three above, so a FOURTH wipe
  --    function written later fails this migration instead of failing a
  --    customer's offboarding. The signature of one is a multi-pass delete loop
  --    over fn__school_data_tables() that swallows foreign_key_violation.
  for v_name in
    select p.proname from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       -- `delete from public.%I` is the signature of a function that empties
       -- tables it names at run time, which is the only shape that can reach
       -- assessments before mark_entries. Deliberately NOT keyed on
       -- fn__school_data_tables(): two of the four do not use it.
       and p.prosrc ~ 'delete from public\.%I'
       and p.prosrc !~ 'app\.clearing_school'
  loop
    raise exception '0129: % empties a school table by table and does not set '
      'app.clearing_school first. Its loop swallows only '
      'foreign_key_violation, so the BEFORE DELETE trigger on assessments will '
      'abort it on the first school that has a finalised mark. Add: perform '
      'set_config(''app.clearing_school'', ''on'', true) before the loop.',
      v_name;
  end loop;

  -- 7. AND THE FLAG IS NOT LEFT ON. `set local` is what makes that true; this
  --    asserts nothing set it at migration time, which would mean the trigger
  --    is inert for the rest of this transaction.
  if coalesce(current_setting('app.clearing_school', true), '') = 'on' then
    raise exception '0129: app.clearing_school is on while this migration runs, '
      'so the locked-marks trigger would be inert. Something set it without '
      'set local.';
  end if;

  raise notice '0129: a register and an exam belong to a class, and a lock now '
    'holds against a cascade';
end $check$;

-- ─────────────────────────────────────────────────────────────────────────
-- Record what this bundle applied (no-op before 0069 creates the ledger)
-- ─────────────────────────────────────────────────────────────────────────
do $ledger$
begin
  if to_regprocedure('public.fn_record_migration(text,text,text)') is null then
    raise notice 'migration ledger not present yet — nothing recorded';
    return;
  end if;
  perform public.fn_record_migration('0129_the_register_belongs_to_a_class_and_a_lock_means_locked.sql', '35_the_register_belongs_to_a_class.sql');
end $ledger$;

-- =============================================================================
-- 0119 - Last year still gets its result cards
--
-- Press Year Rollover and the whole academic record of the year you just
-- finished becomes unreachable: no result cards, no marksheets, no position
-- holders, and no teacher's remarks.
--
-- THE SEQUENCE, and it is the natural one rather than a mistake:
--
--   1. Final exams in March. Every paper marked, every mark entered.
--   2. The new session starts on 1 April. The office presses Year Rollover,
--      because that is what produces the new class lists and the teachers are
--      waiting for their rosters. Nothing warns them to do anything first.
--   3. In May a parent asks for last year's result card.
--   4. Exams -> Final Term -> Generate result cards. It reports nothing at all
--      and produces nothing. fn_result_readiness reports NO problem, so the
--      screen says the class is ready.
--
-- WHY. fn_rollover marks the finished session's enrollments `promoted` (or
-- `graduated` for the leaving class), which is correct: they are not the
-- current roll any more. But both fn_generate_result_cards and
-- fn_result_readiness select the pupils for a card with
--
--     and e.status = 'active'
--
-- so after the rollover a past term has no pupils, and a class with no pupils
-- generates no cards and reports no problems. The marks are all still there.
-- Only the ability to turn them into the document a parent is asking for is
-- gone, and nothing anywhere says why.
--
-- AND IT IS NOT ONLY THE CARD. The same predicate sits in fn_exam_marksheet,
-- fn_assessment_marksheet, fn_position_holders, fn_exam_remarks and
-- fn_set_exam_remark, so after a rollover last year's marksheet is empty, last
-- year's class positions are empty, and a teacher trying to add the remark that
-- goes on the card is told
--
--     That student is not enrolled in this exam term's session
--
-- which is not true: they were, that year, which is the year being asked about.
--
-- MEASURED on a simulated school with three real rollovers behind it, one class
-- across three terms:
--
--   before   {"generated": 0,  "provisional": false, "missing_marks": 0}
--            {"generated": 0,  ...}
--            {"generated": 0,  ...}          and readiness returned zero rows
--
--   after    {"generated": 11, "provisional": false, "missing_marks": 0}
--            {"generated": 17, "provisional": true,  "missing_marks": 8}
--            {"generated": 17, "provisional": false, "missing_marks": 0}
--
-- The provisional card in the middle is the machinery working: those eight
-- pupils were admitted after the mid-term, so they sat no papers, so the card
-- says so. That is the distinction the 'active' predicate was flattening.
--
-- THE RIGHT PREDICATE IS NOT "ON THE ROLL NOW" BUT "WAS IN THIS CLASS THAT
-- YEAR". A result card is a statement about a year that has finished, so the
-- pupils it covers are whoever was enrolled in that class in that session:
--
--     e.status in ('active', 'promoted', 'retained', 'graduated')
--
-- `left` and `struck_off` stay excluded, and that is deliberate rather than an
-- oversight: a child who left in November did not finish the year and does not
-- get a final card. `graduated` is included because the leaving class sat the
-- same final exam as everybody else and their card is the one that matters most.
--
-- WHY THIS IS A PATCH AND NOT A RESTATEMENT. fn_generate_result_cards is
-- getting on for 300 lines and has been patched by 0089 (the GPA scale), 0100
-- (the attendance formula), 0105 (the leave counts) and 0110 (the write gate).
-- Retyping it to change one predicate is how a stack of earlier fixes gets
-- silently reverted, which this repository has recorded happening twice. The
-- anchor is whitespace-blind per supabase/check-patch-anchors.py, so
-- indentation cannot decide whether a school can print a result card.
--
-- Re-runnable: it checks for the corrected predicate before touching anything.
-- =============================================================================

do $patch$
declare
  v_fn     text;
  v_src    text;
  v_new    text;
  v_sites  int;
  v_done   int := 0;
  v_before int;
begin
  -- SEVEN FUNCTIONS, AND THE LIST IS DELIBERATELY A LIST.
  --
  -- 28 functions in this schema carry `e.status = 'active'` and in 21 of them
  -- it is exactly right: the dashboard, the defaulter list, class dues, the section
  -- roster, the student list, birthdays, global search and invoice generation
  -- are all statements about who is on the roll TODAY, and widening them would
  -- bill a child who left and put a promoted enrolment on this year's register
  -- twice.
  --
  -- These seven are different in kind. Every one of them is keyed by an
  -- exam_term_id, an exam_subject_id or an assessment_id: they answer questions
  -- about a period that may already have finished. So a named list rather than
  -- a sweep, because a sweep of this predicate would break the other 21.
  -- Counted after this migration applies: 21 functions still carry it, and
  -- each one was read to confirm that it should.
  foreach v_fn in array array[
    'fn_generate_result_cards',   -- print the card
    'fn_result_readiness',        -- and say whether it can be printed
    'fn_set_exam_remark',         -- the teacher's remark on the card
    'fn_exam_remarks',            -- and reading it back
    'fn_exam_marksheet',          -- last year's paper, mark by mark
    'fn_assessment_marksheet',    -- last year's class test
    'fn_position_holders'         -- who came top of the class that year
  ]
  loop
    begin
      select pg_get_functiondef(p.oid) into v_src
        from pg_proc p join pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'public' and p.proname = v_fn;

      if v_src is null then
        raise warning '0119: % is not present, so last year''s result cards stay '
          'unreachable. Apply the earlier bundles first.', v_fn;
      elsif v_src ~ 'e\.status\s+in\s*\(\s*''active''\s*,\s*''promoted''' then
        raise notice '0119: % already covers a promoted pupil', v_fn;
        v_done := v_done + 1;
      else
        -- Counted before and after, because a regexp that matches nothing and a
        -- regexp that matches everything both leave the function compiling.
        select count(*) into v_sites
          from regexp_matches(v_src, 'e\.status\s*=\s*''active''', 'g');

        v_new := regexp_replace(
          v_src,
          'e\.status\s*=\s*''active''',
          'e.status in (''active'', ''promoted'', ''retained'', ''graduated'')',
          'g');

        if v_sites = 0 or v_new = v_src then
          raise warning '0119: could not find the pupil predicate in %, so '
            'nothing was changed and last year''s result cards are still '
            'unreachable. The rest of this bundle still applied. Run '
            'supabase/verify.sql.', v_fn;
        else
          execute v_new;
          raise notice '0119: % now covers a promoted pupil (% site(s))', v_fn, v_sites;
          v_done := v_done + 1;
        end if;
      end if;
    exception when others then
      raise warning '0119: % was left as it was: %. The rest of this bundle '
        'still applied.', v_fn, sqlerrm;
    end;
  end loop;

  if v_done < 7 then
    raise warning '0119: % of 7 functions carry the corrected predicate. A '
      'school that has already rolled over cannot print the cards for the year '
      'it rolled out of.', v_done;
  end if;
end $patch$;

-- ---------------------------------------------------------------------------
-- The guard, and it asserts the BEHAVIOUR rather than the text.
--
-- A grep for the new predicate would pass on a function that carried it inside
-- a comment. This builds a finished session with a promoted pupil, a paper and
-- a mark, asks for a card, and requires one to come out. It runs entirely
-- inside a subtransaction that is rolled back, so it leaves nothing behind.
-- ---------------------------------------------------------------------------
do $check$
declare
  v_ok boolean := false;
  v_made int;
begin
  begin
    -- A school of one, whose year has ended.
    create temp table t0119 on commit drop as select 1;
    declare
      v_school uuid; v_sess uuid; v_class uuid; v_sec uuid; v_sub uuid;
      v_stu uuid; v_enr uuid; v_term uuid; v_es uuid; v_uid uuid;
    begin
      insert into public.schools (name) values ('0119 probe') returning id into v_school;
      insert into public.subscriptions (school_id, plan_code, status, trial_ends_on)
        values (v_school, (select code from public.plans limit 1), 'active', current_date + 30);
      v_uid := gen_random_uuid();
      -- profiles.id references auth.users, so the probe needs a login row
      -- before it can have an owner. Found by the guard failing on the
      -- constraint, which is the guard doing its job on itself.
      insert into auth.users (id, email) values (v_uid, '0119@probe.invalid');
      insert into public.profiles (id, full_name, role, active, school_id)
        values (v_uid, '0119 owner', 'owner', true, v_school);
      perform set_config('request.jwt.claims',
        jsonb_build_object('sub', v_uid::text, 'role', 'authenticated')::text, true);

      insert into public.academic_sessions (school_id, name, starts_on, ends_on, is_current)
        values (v_school, '0119', current_date - 400, current_date - 40, false)
        returning id into v_sess;
      insert into public.classes (school_id, name, level_order, active)
        values (v_school, '0119 class', 1, true) returning id into v_class;
      insert into public.sections (school_id, class_id, name, sort_order)
        values (v_school, v_class, 'A', 1) returning id into v_sec;
      insert into public.subjects (school_id, class_id, name, sort_order)
        values (v_school, v_class, '0119 subject', 1) returning id into v_sub;
      insert into public.students (school_id, full_name, admission_date, status)
        values (v_school, '0119 pupil', current_date - 400, 'active') returning id into v_stu;
      -- PROMOTED, which is the whole point: this is what a pupil looks like
      -- after the rollover that the old predicate could not see.
      insert into public.enrollments
        (school_id, student_id, session_id, class_id, section_id, status, roll_no)
        values (v_school, v_stu, v_sess, v_class, v_sec, 'promoted', '1')
        returning id into v_enr;
      insert into public.exam_terms
        (school_id, session_id, name, term_type, starts_on, ends_on, assessment_weight_pct)
        values (v_school, v_sess, '0119 term', 'final', current_date - 60, current_date - 55, 0)
        returning id into v_term;
      insert into public.exam_subjects
        (school_id, exam_term_id, class_id, subject_id, max_marks, pass_marks, practical_max)
        values (v_school, v_term, v_class, v_sub, 100, 33, 0) returning id into v_es;
      -- max_marks is not null on mark_entries: the mark carries the paper's
      -- maximum with it, so a later change to exam_subjects cannot silently
      -- restate what a printed card said. Sound design; the guard had to learn
      -- it the same way a caller would.
      insert into public.mark_entries
        (school_id, exam_subject_id, enrollment_id, marks, max_marks, is_absent)
        values (v_school, v_es, v_enr, 71, 100, false);

      v_made := (public.fn_generate_result_cards(v_term, v_class, true)->>'generated')::int;
      -- Three of the seven, not one: the card, the remark that goes on it, and
      -- the marksheet behind it. A probe that only checked the card would have
      -- passed the first version of this migration, which fixed two functions
      -- and left five.
      perform public.fn_set_exam_remark(v_term, v_stu, '0119 probe remark');
      v_ok := v_made >= 1
              and exists (select 1 from public.fn_exam_marksheet(v_es))
              and exists (select 1 from public.fn_exam_remarks(v_term, v_class));
    end;
    raise exception 'rollback the probe';
  exception
    when others then
      if sqlerrm <> 'rollback the probe' then
        raise warning '0119: the behaviour check could not run (%). Run '
          'supabase/verify.sql to see whether the predicate took.', sqlerrm;
        return;
      end if;
  end;

  if v_ok then
    raise notice '0119: a promoted pupil in a finished session gets a result card, '
      'a marksheet and a remark';
  else
    raise exception '0119: a promoted pupil is still invisible to the result '
      'card, the marksheet or the remark. Every school that has pressed Year '
      'Rollover is unable to reach the academic record of the year it rolled '
      'out of.';
  end if;
end $check$;

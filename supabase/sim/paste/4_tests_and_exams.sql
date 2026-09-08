-- =============================================================================
-- GENERATED FILE. DO NOT EDIT except for the one line marked below.
-- Built from supabase/sim/ by scripts/build-sim-bundle.py
--
-- TWO YEARS OF ONE SCHOOL'S USE. FILE 4 OF 7: tests and exams
--
-- 663 class tests, 5 exam terms, 380 papers, result cards, teacher remarks and certificates. Seconds.
--
-- HOW TO RUN THE SET. Paste each file into the Supabase SQL editor and press
-- Run, IN ORDER, waiting for each to finish before starting the next. Exactly
-- like the numbered migration bundles. Each file is one transaction, so if one
-- fails it writes nothing and can be fixed and re-run on its own.
--
-- WHAT THE SET DOES. It finds the school named below and fills it with February
-- 2024 to today: about 220 children on the roll, 589 school days of register,
-- three year-end rollovers, 6,000 challans, 4,600 payments, 663 class tests,
-- 5 exam terms, 715 result cards, a cash drawer counted daily, and today half
-- marked the way a real register is at eleven in the morning. About 370,000
-- rows.
--
-- Every row arrives through the application's OWN functions, with a real
-- signed-in owner's session and Row Level Security on. Raw inserts would fill
-- the tables faster and prove nothing, because it is those functions that keep
-- the ledger balanced and the receipt numbers gapless.
--
-- BEFORE YOU START
--
--   1. IT IS NOT REVERSIBLE BY THESE FILES. To undo it, sign in as the owner
--      and clear the school's data from Settings, which calls
--      fn_reset_school_data. That works only while the school is still on its
--      free trial. Once the trial has ended there is no undo.
--   2. Only run it against a school you are willing to fill with invented
--      data. It writes nothing outside the one tenant named below.
--   3. It creates NO logins. See the note at the end of file 7.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- THE ONE LINE TO EDIT, and it must be the same in every file of the set: the
-- exact name of the school to fill. It must match
-- Settings -> School Profile -> School name character for character. If it
-- does not, the file stops with "No owner session." and writes nothing.
-- ---------------------------------------------------------------------------
set local "sim.school" = 'Chaudhary Puclix High School Ghauriii';

-- Some of these files take minutes, which is longer than the editor's default
-- limit. Only a superuser can lift it, which the SQL editor is.
set local statement_timeout = 0;

-- ---------------------------------------------------------------------------
-- CAN THIS FILE DO ANYTHING AT ALL? Four questions, asked here at the top
-- rather than found out four minutes into a file, and each one answered with
-- WHAT IS ACTUALLY THERE rather than with the fact that something is wrong.
--
-- THE FIRST VERSION OF THIS ASKED ONLY THE FIRST QUESTION, and the file then
-- died on the school name with
--
--     ERROR: No owner session. Is the school name exactly right?
--
-- seven times in a row. That message names the right suspect and then leaves
-- the reader with nowhere to go: the name is in Settings, truncated in the
-- sidebar, and the difference is usually a trailing space or one letter. A
-- diagnostic that can read the answer and does not print it is not a
-- diagnostic. So this one lists the school names it can see.
-- ---------------------------------------------------------------------------
do $prereq$
declare
  -- NOT btrim'd: see question 3. `nullif` on the raw value only asks whether
  -- anything arrived at all.
  v_name   text := coalesce(current_setting('sim.school', true), '');
  v_school uuid;
  v_near   integer;   -- schools whose name differs only in case or spacing
  v_owners integer;
  v_all    text;
begin
  -- 1. Is the schema new enough? The register section reopens a finalised day
  --    and corrects it, which no database could do before migration 0121.
  if to_regprocedure('public.fn_unlock_attendance(uuid,uuid,uuid,date,text)') is null then
    raise exception 'This project is behind the application. Run '
      'supabase/verify.sql, paste every bundle it names in a FAIL row (the '
      'first of them is 27_a_finalised_register_can_be_reopened.sql), then '
      'start this set again.';
  end if;

  -- 2. Did the school name survive as far as this statement? `set local` only
  --    holds for the transaction, and pressing Run on a pasted file makes the
  --    whole file one transaction. Run a SELECTION of it and the setting is
  --    gone by the time anything reads it, and every later error then blames
  --    the school name instead of the way it was run. Outside a transaction
  --    `set local` does not fail: it warns, and reads back EMPTY.
  if btrim(v_name) = '' then
    raise exception 'The school name never arrived: "sim.school" is empty here. '
      'Paste and run the WHOLE file in one go rather than a selection of it, '
      'because the line that sets the name only holds for as long as the file '
      'runs as one batch.';
  end if;

  -- 3. Is there a school of that name? And if not, SAY WHAT THERE IS, and fix
  --    it where the answer is not in doubt.
  --
  --    THE COMPARISON HERE IS EXACTLY THE ONE THE REST OF THE FILE USES: plain
  --    equality on the name. An earlier version trimmed the setting before
  --    comparing, which made this check PASS on a name the body then failed on,
  --    and a check that disagrees with the code it guards is worse than no
  --    check. So instead of loosening the comparison, this loosens the SEARCH
  --    and then corrects the setting, which every later statement reads.
  select id into v_school from public.schools where name = v_name;

  if v_school is null then
    -- One near miss and no ambiguity: almost always a trailing space, which is
    -- invisible in Settings and in the sidebar, or a capital letter. Fix it and
    -- say so loudly enough that nobody could think a different school was
    -- filled by accident.
    select count(*), min(name) into v_near, v_all
      from public.schools
     where lower(btrim(name)) = lower(btrim(v_name));

    if v_near = 1 then
      raise notice 'The name given was "%" and this school is stored as "%". '
        'Same school, so continuing with the stored spelling.', v_name, v_all;
      perform set_config('sim.school', v_all, true);
      v_name := v_all;
      select id into v_school from public.schools where name = v_name;
    else
      select string_agg('"' || name || '"', ', ' order by name) into v_all
        from public.schools;
      raise exception 'No school is named "%". This project holds %. Copy the '
        'one you want, character for character including any spaces, into the '
        '"sim.school" line at the top of every file in this set.',
        v_name, coalesce(v_all, 'no schools at all');
    end if;
  end if;

  -- 4. Is there an owner to act as? Every row in this set is written through
  --    the application's own functions with a real signed-in owner's session,
  --    so without one there is nobody to be. Kept separate from question 3 on
  --    purpose: the two were one message before, and "is the school name
  --    right?" is unanswerable advice when the name was right all along.
  select count(*) into v_owners from public.profiles
   where school_id = v_school and role = 'owner' and active;
  if v_owners = 0 then
    raise exception 'The school "%" exists but has no active owner login, and '
      'this set writes as its owner. Sign in as the school and check Settings, '
      'Users & Roles.', v_name;
  end if;

  raise notice 'Filling "%", which has an owner to write as. This whole file is '
    'one transaction: if it stops, it writes nothing.', v_name;
end $prereq$;



-- ------------------------------------------------------------------------
-- 06_academics.sql
-- ------------------------------------------------------------------------
reset role;
-- =============================================================================
-- SIMULATION, PART 6: three years of tests, exams, results and certificates.
--
-- TESTS AND EXAMS ARE TWO DIFFERENT SYSTEMS in this schema and the difference
-- is not cosmetic. Tests are `assessments` plus `mark_entries`, set per SECTION
-- by the teacher who teaches it, weighted, and lockable. Exams are `exam_terms`
-- plus `exam_subjects` plus `mark_entries` plus `result_cards`, set per CLASS,
-- with a pass mark, an optional practical component, a withhold flag for
-- defaulters, and a publish gate that decides whether a parent can see anything
-- at all. A simulation that populated one and not the other would leave half
-- the academic half of the product untested, and they share `mark_entries`, so
-- the two partial unique indexes on that table (uq_mark_assessment and
-- uq_mark_exam) are only both exercised if both paths run.
--
-- THE PUBLISH GATE IS THE POINT OF THE EXAM HALF. Marks stay invisible to a
-- parent until fn_publish_results is called for that term and class, and one
-- term is deliberately left UNPUBLISHED at the end so the portal has something
-- to correctly refuse. A simulation where everything is published cannot tell
-- you whether the gate works.
--
-- MARKS ARE NOT UNIFORM. Each child has a persistent ability drawn from their
-- own id, so the same child is roughly the same standard in every paper and
-- across every term. Random marks per paper would give every class the same
-- mean, no position holders worth the name, and a "top of class" that changes
-- every term for no reason.
--
-- Run: psql -v ON_ERROR_STOP=1 -f supabase/sim/06_academics.sql
-- =============================================================================



select set_config('request.jwt.claims',
  jsonb_build_object('sub', p.id::text, 'role','authenticated')::text, true)
from public.profiles p join public.schools s on s.id = p.school_id
where s.name = current_setting('sim.school')
  and p.role = 'owner' and p.active limit 1;
set local role authenticated;

-- --- 1. Monthly class tests ---------------------------------------------------
do $sim$
declare
  v_school uuid := public.current_school_id();
  r record; v_month date; v_a uuid; v_marks jsonb; v_max numeric;
  v_tests int := 0; v_marked int := 0;
begin
  if v_school is null then raise exception 'No owner session.'; end if;

  for r in
    select s.id as section_id, s.class_id, c.level_order, sub.id as subject_id,
           a.id as session_id, a.starts_on, a.ends_on
      from public.sections s
      join public.classes c on c.id = s.class_id
      join public.subjects sub on sub.class_id = c.id
      join public.academic_sessions a on a.school_id = c.school_id
     where c.school_id = v_school
       and a.ends_on >= date '2024-02-01' and a.starts_on <= current_date
       -- Three subjects a section, not all seven. A school does not set a
       -- written test in every subject every month, and 17 sections x 7
       -- subjects x 31 months would be 3,700 tests, which is not a school.
       and sub.sort_order <= 3
     order by a.starts_on, c.level_order
  loop
    for v_month in
      select generate_series(
        greatest(date_trunc('month', r.starts_on)::date, date '2024-02-01'),
        least(date_trunc('month', r.ends_on)::date, date_trunc('month', current_date)::date),
        interval '2 months')::date
    loop
      -- No tests in the summer break or over the winter one.
      continue when extract(month from v_month) in (6, 7);
      v_max := 20;
      insert into public.assessments
        (session_id, class_id, section_id, subject_id, title, assessment_date, max_marks, weightage)
      values (r.session_id, r.class_id, r.section_id, r.subject_id,
              to_char(v_month, 'Mon') || ' test',
              least(v_month + 12, current_date), v_max, 10)
      returning id into v_a;
      v_tests := v_tests + 1;

      select jsonb_agg(jsonb_build_object(
               'enrollment_id', q.id,
               'marks', q.m,
               'is_absent', q.absent))
        into v_marks
        from (
          select e.id,
                 -- A persistent ability per child, so the same child is roughly
                 -- the same standard in every paper. This is what makes
                 -- fn_position_holders mean anything.
                 case when (hashtextextended(e.id::text || v_a::text, 5) % 100 + 100) % 100 < 4
                      then null
                      else round(least(v_max, greatest(2,
                             (v_max * 0.45)
                             + (v_max * 0.5) * ((hashtextextended(e.student_id::text, 71) % 100 + 100) % 100) / 100.0
                             + (((hashtextextended(e.id::text || v_a::text, 13) % 7 + 7) % 7) - 3)
                           )))::numeric end as m,
                 ((hashtextextended(e.id::text || v_a::text, 5) % 100 + 100) % 100 < 4) as absent
            from public.enrollments e
            join public.students st on st.id = e.student_id
           where e.section_id = r.section_id and e.session_id = r.session_id
             and st.admission_date <= v_month
        ) q;

      if v_marks is not null then
        perform public.fn_enter_assessment_marks(v_a, v_marks, null);
        v_marked := v_marked + 1;
        -- Locked once the term it belongs to is over, which is what stops a
        -- teacher quietly changing a mark after a result card went home.
        if v_month < date_trunc('month', current_date)::date - interval '2 months' then
          perform public.fn_lock_assessment(v_a);
        end if;
      end if;
    end loop;
  end loop;
  raise notice 'tests=% marked=% mark rows=%', v_tests, v_marked,
    (select count(*) from public.mark_entries where school_id = v_school and assessment_id is not null);
end
$sim$;

-- --- 1b. Which subjects have a practical, and which stream they belong to -----
-- THE PRACTICAL FLAG LIVES ON THE SUBJECT AND NOT ON THE PAPER, which is right
-- and which this file got wrong first time round. fn_upsert_exam_subject reads
-- subjects.is_practical and refuses outright:
--
--   Mark this subject as having a practical before giving it practical marks
--
-- A paper that carries 25 practical marks in one term and none in the next,
-- for the same subject, is a data-entry mistake rather than a curriculum
-- decision, so the flag belongs one level up. fn_set_subject_details is the
-- only way to set it, and it sets the stream at the same time, which is the
-- other subject-level fact this simulation would otherwise never have written.
do $sim$
declare
  v_school uuid := public.current_school_id();
  r record; v_n int := 0;
begin
  for r in
    select sub.id, sub.name, c.level_order
      from public.subjects sub
      join public.classes c on c.id = sub.class_id
     where c.school_id = v_school
  loop
    perform public.fn_set_subject_details(
      r.id,
      -- Streams only exist in the senior classes, and only for the science
      -- papers: a Nursery child is not on Pre-Medical.
      case when r.level_order >= 11 and r.name in ('Physics','Chemistry','Biology')
             then 'Pre-Medical'
           when r.level_order >= 11 and r.name in ('Computer')
             then 'Pre-Engineering'
           else null end,
      r.level_order >= 11 and r.name in ('Physics','Chemistry','Biology','Computer'));
    v_n := v_n + 1;
  end loop;
  raise notice 'subject details set on % subjects (practical: %)', v_n,
    (select count(*) from public.subjects sub join public.classes c on c.id = sub.class_id
      where c.school_id = v_school and sub.is_practical);
end
$sim$;

-- --- 2. Exam terms, papers, marks, result cards -------------------------------
do $sim$
declare
  v_school uuid := public.current_school_id();
  v_ses record; v_term record; v_cls record; v_sub record;
  v_term_id uuid; v_es uuid; v_marks jsonb; v_max numeric; v_pass numeric;
  v_terms int := 0; v_papers int := 0; v_cards int := 0; v_pub int := 0;
  v_last_term uuid;
begin
  for v_ses in
    select id, name, starts_on, ends_on from public.academic_sessions
     where school_id = v_school and ends_on >= date '2024-02-01'
       and starts_on <= current_date order by starts_on
  loop
    -- Two terms a year: a mid-term in October and a final in March. Only the
    -- ones whose dates have actually passed.
    for v_term in
      select * from (values
        ('Mid Term',   'mid'::public.term_type,   (date_trunc('year', v_ses.starts_on) + interval '9 months')::date),
        ('Final Term', 'final'::public.term_type, (v_ses.ends_on - interval '20 days')::date)
      ) as t(nm, tt, on_date)
     where t.on_date <= current_date and t.on_date >= date '2024-02-01'
    loop
      select id into v_term_id from public.exam_terms
       where school_id = v_school and session_id = v_ses.id and name = v_term.nm;
      if v_term_id is null then
        insert into public.exam_terms (session_id, name, term_type, starts_on, ends_on,
                                       result_withheld_for_defaulters, assessment_weight_pct)
        values (v_ses.id, v_term.nm, v_term.tt, v_term.on_date, v_term.on_date + 8,
                -- Withheld for defaulters on the final only: a school leans on
                -- the result card at the end of the year, not mid-term. This is
                -- the flag fn_result_readiness reports on.
                v_term.tt = 'final', 20)
        returning id into v_term_id;
        v_terms := v_terms + 1;
      end if;
      v_last_term := v_term_id;

      for v_cls in select id, level_order from public.classes
                    where school_id = v_school order by level_order loop
        for v_sub in select id, name, sort_order from public.subjects
                      where class_id = v_cls.id order by sort_order loop
          v_max  := case when v_cls.level_order <= 2 then 50 else 100 end;
          v_pass := round(v_max * 0.33);
          -- A practical only for the science papers in the senior classes,
          -- which is the case that makes fn_enter_marks validate a second
          -- number against a different maximum.
          v_es := public.fn_upsert_exam_subject(
            v_term_id, v_cls.id, v_sub.id, v_max, v_pass,
            case when v_cls.level_order >= 11
                   and v_sub.name in ('Physics','Chemistry','Biology','Computer')
                 then 25 else 0 end,
            v_term.on_date + (v_sub.sort_order - 1),
            case when (v_sub.sort_order % 2) = 1 then '08:30' else '11:00' end);
          v_papers := v_papers + 1;

          select jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
                   'enrollment_id', q.id, 'marks', q.m, 'is_absent', q.absent,
                   'practical_marks', q.pm)))
            into v_marks
            from (
              select e.id,
                     case when (hashtextextended(e.id::text || v_es::text, 5) % 100 + 100) % 100 < 3
                          then null
                          else round(least(v_max, greatest(5,
                                 (v_max * 0.40)
                                 + (v_max * 0.52) * ((hashtextextended(e.student_id::text, 71) % 100 + 100) % 100) / 100.0
                                 + (((hashtextextended(e.id::text || v_es::text, 13) % 15 + 15) % 15) - 7)
                               )))::numeric end as m,
                     ((hashtextextended(e.id::text || v_es::text, 5) % 100 + 100) % 100 < 3) as absent,
                     case when v_cls.level_order >= 11
                            and v_sub.name in ('Physics','Chemistry','Biology','Computer')
                          then round(15 + ((hashtextextended(e.id::text, 23) % 10 + 10) % 10))::numeric
                          else null end as pm
                from public.enrollments e
                join public.students st on st.id = e.student_id
               where e.class_id = v_cls.id and e.session_id = v_ses.id
                 and st.admission_date <= v_term.on_date
            ) q;

          if v_marks is not null then
            begin
              perform public.fn_enter_marks(v_es, v_marks, null);
            exception when others then
              raise notice '  marks refused for % %: %', v_cls.level_order, v_sub.name, sqlerrm;
            end;
          end if;
        end loop;

        -- The result cards, then the publish gate.
        begin
          perform public.fn_generate_result_cards(v_term_id, v_cls.id, true);
          v_cards := v_cards + 1;
          -- EVERY TERM PUBLISHED EXCEPT THE MOST RECENT ONE. A school marks
          -- papers for a fortnight before results go out, so the current term
          -- sitting unpublished is the true state, and it is the only way to
          -- test that the portal correctly shows a parent nothing.
          if v_term.on_date < current_date - 30 then
            perform public.fn_publish_results(v_term_id, v_cls.id);
            v_pub := v_pub + 1;
          end if;
        exception when others then
          raise notice '  result cards refused for class %: %', v_cls.level_order, sqlerrm;
        end;
      end loop;
    end loop;
  end loop;

  raise notice 'exam terms=% papers=% class result-card runs=% published=%',
    v_terms, v_papers, v_cards, v_pub;
  raise notice 'exam mark rows=%  result cards=%',
    (select count(*) from public.mark_entries where school_id = v_school and exam_subject_id is not null),
    (select count(*) from public.result_cards where school_id = v_school);
end
$sim$;

-- --- 3. Teacher remarks on the result cards -----------------------------------
do $sim$
declare
  v_school uuid := public.current_school_id();
  r record; v_n int := 0;
begin
  for r in
    select rc.student_id, rc.exam_term_id,
           row_number() over (order by rc.exam_term_id, rc.student_id) as k
      from public.result_cards rc
     where rc.school_id = v_school
     limit 400
  loop
    begin
      perform public.fn_set_exam_remark(r.exam_term_id, r.student_id,
        (array[
          'Hardworking and attentive. Keep it up.',
          'Needs to work on handwriting and neatness.',
          'Improved a great deal this term. Well done.',
          'Must be more regular. Absences are affecting the marks.',
          'Excellent in Mathematics, needs help with English.',
          'A pleasure to teach. Should aim for the top three next term.'
        ])[((r.k % 6) + 1)]);
      v_n := v_n + 1;
    exception when others then
      raise notice '  remark skipped: %', sqlerrm;
    end;
  end loop;
  raise notice 'exam remarks=%', v_n;
end
$sim$;

-- --- 4. Certificates ----------------------------------------------------------
-- A leaving certificate for the children who left, character and bonafide
-- certificates on request, and one cancelled certificate, because a register
-- with no cancellation in it has never had its cancellation path read.
do $sim$
declare
  v_school uuid := public.current_school_id();
  r record; v_c jsonb; v_n int := 0; v_cancelled int := 0; v_first uuid;
begin
  for r in
    select st.id, st.status, st.left_on,
           row_number() over (order by st.id) as k
      from public.students st
     where st.school_id = v_school and st.status <> 'active'
     limit 20
  loop
    begin
      v_c := public.fn_issue_certificate('leaving', r.id, '{}'::jsonb,
               coalesce(r.left_on, current_date - 30),
               'Left the school', r.status, true,
               'Dues written off by the principal at leaving');
      v_n := v_n + 1;
      if v_first is null then v_first := (v_c->>'certificate_id')::uuid; end if;
    exception when others then
      raise notice '  leaving certificate refused: %', sqlerrm;
    end;
  end loop;

  for r in
    select st.id, row_number() over (order by st.id) as k
      from public.students st
     where st.school_id = v_school and st.status = 'active'
       and (hashtextextended(st.id::text, 61) % 100 + 100) % 100 < 12
     limit 30
  loop
    begin
      v_c := public.fn_issue_certificate(
               case when (r.k % 3) = 0 then 'character'
                    when (r.k % 3) = 1 then 'bonafide'
                    else 'id_card' end::public.certificate_type,
               r.id, jsonb_build_object('purpose',
                 case when (r.k % 3) = 1 then 'For a bank account' else 'On parent request' end),
               null, null, 'withdrawn', false, null);
      v_n := v_n + 1;
      if v_first is null then v_first := (v_c->>'certificate_id')::uuid; end if;
    exception when others then
      raise notice '  certificate refused: %', sqlerrm;
    end;
  end loop;

  -- One cancellation, on the first certificate issued.
  if v_first is not null then
    begin
      perform public.fn_cancel_certificate(v_first, 'Issued with the father''s name spelt wrong; reissued');
      v_cancelled := 1;
    exception when others then
      raise notice '  cancellation refused: %', sqlerrm;
    end;
  end if;

  raise notice 'certificates=% cancelled=%', v_n, v_cancelled;
end
$sim$;


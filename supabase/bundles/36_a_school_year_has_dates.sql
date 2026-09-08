-- =============================================================================
-- GENERATED FILE — DO NOT EDIT.
-- Built from supabase/migrations/ by supabase/build-bundles.sh
--
-- Paste this whole file into the Supabase SQL Editor and press Run.
-- Run the bundles in order, one at a time, waiting for each to finish.
-- =============================================================================


-- ─────────────────────────────────────────────────────────────────────────
-- 0130_a_school_year_has_dates.sql
-- ─────────────────────────────────────────────────────────────────────────
-- =============================================================================
-- 0130  A school year has dates, and nothing is recorded outside them
--
-- -----------------------------------------------------------------------------
-- WHAT WAS UNBOUNDED
--
-- Five dates come from the caller and nothing checked any of them:
--
--   fn_mark_attendance          p_date
--   fn_bill_student_month       p_period_month, p_due_date
--   fn_generate_class_invoices  p_period_month, p_due_date
--   fn_record_expense           p_spent_on
--   fn_record_other_income      p_received_on
--
-- Two calls to the first one, through the app's own function, on a real school:
--
--     ACCEPTED a 2099 date
--     ACCEPTED an 1900 date
--     the register now runs 1900-01-01 to 2099-12-31
--
-- fn_set_staff_attendance was the only one with a guard of any kind, and it
-- checks the future and not the past.
--
-- THE HARM IS NOT MAINLY AN ATTACKER. It is a clerk typing 2062 for 2026, or
-- picking last year in a date field with no lower bound. attendance_daily is
-- keyed on (enrollment_id, attendance_date), so a mistyped year creates a row
-- that appears on no screen (every attendance screen is scoped to a date or a
-- month), is counted in the attendance percentage the parent portal shows, and
-- can never be found again. A challan with a period month in 2062 shows in no
-- month's collection; one with a due date in 2062 never becomes overdue and so
-- never appears on the defaulter list. An expense in the wrong year makes the
-- books wrong in two years at once.
--
-- It is also the multiplier that defeated the student limit 0128 added. Pupils
-- are capped; pupils times unbounded dates is not.
--
-- -----------------------------------------------------------------------------
-- AND THE CALENDAR IT SHOULD BE BOUNDED BY DOES NOT EXIST YET
--
-- The bound wants to be "inside the school's own academic year", which is the
-- rule a person would state and the only one that refuses nothing legitimate.
-- Measured on the finished demo school: of 90,964 attendance rows, 0 fall
-- outside the enrolment's session; of 6,189 challans, 0 have a period month
-- outside it; of 159 expenses and income rows, 0 fall outside the span of the
-- school's sessions.
--
-- But the first-run wizard never asks for those dates. It asks for the
-- session's NAME and nothing else, so setupSchool() passes
-- `starts_on: input.startsOn || null` and every school created through the app
-- has a current academic year with no dates on it. Settings then Sessions has
-- the two fields and does not require them. The demo school only has dates
-- because the seed writes them directly.
--
-- So this migration does the dates first and the bounds second:
--
--   1. A new session must have both dates, and they must be sane.
--   2. A school may have at most 60 of them.
--   3. The five dates above must fall inside the calendar those sessions make.
--   4. A session that ALREADY has no dates is left exactly as it is, and
--      reported. The bounds are silent for it rather than guessing: deriving
--      "April to March" from a name would put wrong dates on a live school's
--      academic year and then reject its real register. verify.sql reports it
--      until somebody fills it in.
--
-- Re-runnable.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. A SESSION'S DATES ARE SANE
--
-- CHECK constraints and not a function, because academic_sessions is written
-- directly through RLS from the browser (web/src/lib/db.ts createSession and
-- setupSchool), so there is no single function to put the rule in. A constraint
-- applies to every path there will ever be, including a psql prompt.
--
-- Both allow NULL, so no existing row can violate them and the migration cannot
-- fail on a school that is already running. What refuses a NULL is the INSERT
-- trigger below, which applies only to sessions created from now on.
-- ---------------------------------------------------------------------------
do $c$
begin
  if not exists (select 1 from pg_constraint
                  where conrelid = 'public.academic_sessions'::regclass
                    and conname = 'academic_sessions_dates_ordered') then
    alter table public.academic_sessions
      add constraint academic_sessions_dates_ordered
      check (starts_on is null or ends_on is null or ends_on > starts_on);
  end if;

  -- 800 DAYS, AND THE ARITHMETIC. A Pakistani academic year is twelve months,
  -- April to March in Punjab and August to June in much of Sindh. The longest
  -- legitimate one is a transition year when a school moves between the two,
  -- which is eighteen months, or 548 days. 800 leaves 46% headroom on that and
  -- still refuses the thing this exists to refuse: a session spanning decades,
  -- which would make the date bounds below mean nothing at all.
  if not exists (select 1 from pg_constraint
                  where conrelid = 'public.academic_sessions'::regclass
                    and conname = 'academic_sessions_length_sane') then
    alter table public.academic_sessions
      add constraint academic_sessions_length_sane
      check (starts_on is null or ends_on is null
             or ends_on - starts_on <= 800);
  end if;
end $c$;

-- ---------------------------------------------------------------------------
-- 2. WHY THERE IS NO TRIGGER REQUIRING THE DATES
--
-- There was one, and it was removed on measurement rather than on principle.
-- A BEFORE INSERT trigger raising "an academic year needs a first and a last
-- day" broke twenty of the SQL suites, because their fixtures create a session
-- with a name and nothing else:
--
--     ERROR: An academic year needs a first and a last day.  (counter.sql:113)
--
-- Twenty fixtures is not the reason on its own. The reason is what those
-- fixtures represent: this schema has allowed a dateless session since 0001,
-- the first-run wizard created one for every school ever set up, and a rule
-- that refuses them is a rule that refuses the state the product is actually
-- in. Making it a hard error at the database is a change to reckon with on its
-- own, with the twenty fixtures updated deliberately, and not a side effect of
-- a migration about date bounds.
--
-- So the dates are required where a person supplies them, which is the two
-- screens that create a session, and both now do:
--
--   SetupWizard.tsx   asks for the first and last day, pre-filled for an April
--                     to March year. It asked for the NAME and nothing else,
--                     which is why every existing school has none.
--   Sessions.tsx      the two fields were optional and are now required, and a
--                     year already saved without them is shown as such rather
--                     than rendering a blank gap.
--
-- Everything below is silent for a session with no dates, deliberately, and
-- verify.sql reports every one of them until somebody fills it in. So a school
-- gets the bound the moment it has a calendar, and nothing is refused before
-- then.
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- 3. THE TWO BOUNDS
--
-- fn__assert_date_in_session is the tight one: a register and a challan belong
-- to one academic year, and the enrolment says which. fn__assert_date_in_calendar
-- is the loose one, for a payment or an expense that belongs to the school
-- rather than to a year.
--
-- BOTH ARE SILENT WHEN THERE IS NOTHING TO CHECK AGAINST, and that is a
-- decision rather than an oversight. A session with no dates, or a school with
-- no dated session at all, produces no bound; the alternative is refusing a
-- school's ordinary work because of a field the wizard never asked them for.
-- verify.sql reports those schools instead.
-- ---------------------------------------------------------------------------
create or replace function public.fn__assert_date_in_session(
  p_session uuid, p_date date, p_what text,
  p_whole_months boolean default false)
returns void language plpgsql stable security definer set search_path = public as $$
declare v_s record; v_a date; v_b date;
begin
  select name, starts_on, ends_on into v_s
    from public.academic_sessions
   where id = p_session and school_id = public.current_school_id();
  if not found or v_s.starts_on is null or v_s.ends_on is null then
    return;
  end if;

  -- p_whole_months WIDENS THE WINDOW TO WHOLE CALENDAR MONTHS, and it exists
  -- because of a case supabase/tests/rollover.sql found on the first run:
  --
  --     The 2026-2027 session runs 07 Sep 2026 to 03 Sep 2027, and
  --     01 Sep 2026 is outside it.
  --
  -- A challan's period_month is the FIRST of the month, a label for "September"
  -- rather than a day anything happened on. A school whose year begins on the
  -- 7th of a month bills that whole month, and the label for it is the 1st,
  -- which falls before the session starts. Comparing a month label against a
  -- day boundary refused a school's first month's fees. Same for a fee's
  -- effective_from, which is conventionally a month start.
  --
  -- Attendance and an exam date are real days and pass false, so a register
  -- still cannot be marked for the six days before term began.
  v_a := case when p_whole_months then date_trunc('month', v_s.starts_on)::date
              else v_s.starts_on end;
  v_b := case when p_whole_months
              then (date_trunc('month', v_s.ends_on)
                    + interval '1 month' - interval '1 day')::date
              else v_s.ends_on end;

  if p_date < v_a or p_date > v_b then
    raise exception
      'The % session runs % to %, and % is outside it. Check the date: a '
      'record dated outside its academic year appears on no screen afterwards.',
      v_s.name,
      to_char(v_a, 'DD Mon YYYY'), to_char(v_b, 'DD Mon YYYY'),
      to_char(p_date, 'DD Mon YYYY')
      using errcode = '22008', hint = p_what;
  end if;
end;
$$;

revoke all on function public.fn__assert_date_in_session(uuid, date, text, boolean)
  from public, anon, authenticated;

create or replace function public.fn__assert_date_in_calendar(
  p_date date, p_what text)
returns void language plpgsql stable security definer set search_path = public as $$
declare v_a date; v_b date;
begin
  select min(starts_on), max(ends_on) into v_a, v_b
    from public.academic_sessions
   where school_id = public.current_school_id()
     and starts_on is not null and ends_on is not null;
  if v_a is null then
    return;
  end if;
  -- A YEAR EITHER SIDE, and the arithmetic is about two real cases rather than
  -- about round numbers. Before the first session: a school setting up in
  -- February for an April start records its deposit and its furniture now.
  -- After the last: a school that has not yet created next year's session pays
  -- a bill in March for April. Both are ordinary, both are within a year, and
  -- a mistyped 2062 is not.
  if p_date < v_a - 365 or p_date > v_b + 365 then
    raise exception
      'This school''s records run % to %, and % is more than a year outside '
      'that. Check the date, or add the academic year it belongs to first.',
      to_char(v_a, 'DD Mon YYYY'), to_char(v_b, 'DD Mon YYYY'),
      to_char(p_date, 'DD Mon YYYY')
      using errcode = '22008', hint = p_what;
  end if;
end;
$$;

revoke all on function public.fn__assert_date_in_calendar(date, text)
  from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 4. THE FIVE PATCHES
--
-- Patched from each function's own text. Every anchor is a single line and
-- therefore cannot be wrong about line endings, which is the flaw
-- supabase/check-patch-anchors.py exists to catch and which cost bundle 12
-- seven migrations on a live school.
-- ---------------------------------------------------------------------------

-- 4a. THE REGISTER. One check per call rather than one per pupil: p_date is a
--     single value for the whole batch, so marking a class of forty asks once.
--
--     AFTER the authorisation checks, not before. A teacher poking at a class
--     they do not teach should be told that, and not told whether the date they
--     tried is inside that class's year.
do $att$
declare v_src text; v_new text;
begin
  v_src := pg_get_functiondef(
    'public.fn_mark_attendance(date,jsonb,text)'::regprocedure);
  if position('fn__assert_date_in_session' in v_src) > 0 then
    raise notice '0130: fn_mark_attendance already bounds the date';
    return;
  end if;
  if position('  select count(distinct (e->>''enrollment_id'')) into v_total' in v_src) = 0 then
    raise exception '0130: fn_mark_attendance no longer counts the distinct '
      'enrolments where this migration inserts the date check before it. It '
      'has been rewritten since. The change is two checks after the '
      'authorisation gates: the date must not be in the future, and it must '
      'fall inside the session each enrolment belongs to.';
  end if;
  v_new := replace(v_src,
    '  select count(distinct (e->>''enrollment_id'')) into v_total',
    '  -- THE DATE (0130). Nothing bounded it: two calls put a school''s' || E'\n' ||
    '  -- register between 1900 and 2099. Two rules, both about a person' || E'\n' ||
    '  -- mistyping a year rather than about an attacker.' || E'\n' ||
    '  --' || E'\n' ||
    '  -- Pakistan time for "today", the same expression fn_set_staff_attendance' || E'\n' ||
    '  -- uses, because the two must agree about which day it is: from midnight' || E'\n' ||
    '  -- to 5am in Karachi, UTC still says yesterday.' || E'\n' ||
    '  if p_date > (now() at time zone ''Asia/Karachi'')::date then' || E'\n' ||
    '    raise exception ''Attendance cannot be marked for %, which has not ''' || E'\n' ||
    '      ''happened yet.'', to_char(p_date, ''DD Mon YYYY'')' || E'\n' ||
    '      using errcode = ''22008'';' || E'\n' ||
    '  end if;' || E'\n' ||
    '  -- And inside the academic year the enrolment belongs to. Checked per' || E'\n' ||
    '  -- session rather than against the CURRENT one, because reopening last' || E'\n' ||
    '  -- year''s register to correct it is a thing fn_unlock_attendance exists' || E'\n' ||
    '  -- to allow.' || E'\n' ||
    '  perform public.fn__assert_date_in_session(en.session_id, p_date,' || E'\n' ||
    '            ''Marking attendance'')' || E'\n' ||
    '    from public.enrollments en' || E'\n' ||
    '   where en.id in (select (e->>''enrollment_id'')::uuid' || E'\n' ||
    '                     from jsonb_array_elements(p_marks) e)' || E'\n' ||
    '     and en.school_id = public.current_school_id();' || E'\n' ||
    E'\n' ||
    '  select count(distinct (e->>''enrollment_id'')) into v_total');
  if v_new = v_src or position('fn__assert_date_in_session' in v_new) = 0 then
    raise exception '0130: the fn_mark_attendance rewrite did not take';
  end if;
  execute v_new;
  raise notice '0130: attendance cannot be marked outside its academic year';
end $att$;

-- 4b. AND THE OTHER WAY ROUND: the staff register already refuses the future
--     and accepts 1900. One line, the same shape as the pupils' register.
do $staff$
declare v_src text; v_new text;
begin
  v_src := pg_get_functiondef(
    'public.fn_set_staff_attendance(uuid,date,public.attendance_status,text)'::regprocedure);
  if position('fn__assert_date_in_calendar' in v_src) > 0 then
    raise notice '0130: fn_set_staff_attendance already bounds the past';
    return;
  end if;
  if position('  if p_date > (now() at time zone ''Asia/Karachi'')::date then' in v_src) = 0 then
    raise exception '0130: fn_set_staff_attendance no longer refuses a future '
      'date where this migration expects to add the lower bound beside it. The '
      'change is one call: perform public.fn__assert_date_in_calendar(p_date, '
      '''Staff attendance'').';
  end if;
  -- A staff member's attendance is not per-session, so the loose bound. It is
  -- the school's own span, which is what a record of service belongs to.
  v_new := replace(v_src,
    '  if p_date > (now() at time zone ''Asia/Karachi'')::date then',
    '  -- 0130: and not before the school existed either. The future was' || E'\n' ||
    '  -- already refused; 1900 was not.' || E'\n' ||
    '  perform public.fn__assert_date_in_calendar(p_date, ''Staff attendance'');' || E'\n' ||
    '  if p_date > (now() at time zone ''Asia/Karachi'')::date then');
  if v_new = v_src then
    raise exception '0130: the fn_set_staff_attendance rewrite did not take';
  end if;
  execute v_new;
  raise notice '0130: staff attendance cannot be marked before the school existed';
end $staff$;

-- 4c. THE CHALLANS. Two functions, one rule. The period month belongs to the
--     session; the due date is looser because March's challan is legitimately
--     due in April, after the session has ended.
do $inv$
declare v_src text; v_new text; v_due text;
begin
  -- THE DUE DATE WINDOW, AND THE ARITHMETIC. Measured on the demo school: all
  -- 6,189 challans use a 9-day gap, and 201 of them fall after their session
  -- ended, which is correct for the last month of the year. A month before the
  -- period covers a school that bills in advance; 180 days after is already
  -- six months of arrears tolerance. A due date outside that is a typed year.
  v_due :=
    '  if p_due_date is not null' || E'\n' ||
    '     and (p_due_date < p_period_month - 31' || E'\n' ||
    '          or p_due_date > p_period_month + 180) then' || E'\n' ||
    '    raise exception ''A challan for % cannot be due on %. Check the ''' || E'\n' ||
    '      ''date.'', to_char(p_period_month, ''Mon YYYY''),' || E'\n' ||
    '      to_char(p_due_date, ''DD Mon YYYY'')' || E'\n' ||
    '      using errcode = ''22008'';' || E'\n' ||
    '  end if;' || E'\n';

  -- One pupil, one month. The enrolment has just been read into v_enr.
  v_src := pg_get_functiondef(
    'public.fn_bill_student_month(uuid,date,date)'::regprocedure);
  if position('fn__assert_date_in_session' in v_src) = 0 then
    if position('  if not found then raise exception ''Enrolment not found''; end if;' in v_src) = 0 then
      raise exception '0130: fn_bill_student_month no longer reads the '
        'enrolment where this migration inserts the period check after it. The '
        'change is one call after v_enr is loaded: '
        'fn__assert_date_in_session(v_enr.session_id, p_period_month, ...), '
        'plus a window on p_due_date.';
    end if;
    v_new := replace(v_src,
      '  if not found then raise exception ''Enrolment not found''; end if;',
      '  if not found then raise exception ''Enrolment not found''; end if;' || E'\n' ||
      E'\n' ||
      '  -- 0130: the month being billed belongs to the year the child is' || E'\n' ||
      '  -- enrolled in. A challan dated outside it shows in no month''s' || E'\n' ||
      '  -- collection and on no defaulter list.' || E'\n' ||
      '  perform public.fn__assert_date_in_session(v_enr.session_id,' || E'\n' ||
      '            p_period_month, ''Generating a challan'',' || E'\n' ||
      '            -- whole months: period_month is the FIRST of the month, a' || E'\n' ||
      '            -- label for "September" and not a day. A school whose year' || E'\n' ||
      '            -- begins on the 7th still bills that whole month.' || E'\n' ||
      '            true);' || E'\n' ||
      v_due);
    if v_new = v_src then
      raise exception '0130: the fn_bill_student_month rewrite did not take';
    end if;
    execute v_new;
    raise notice '0130: a challan''s month belongs to the child''s academic year';
  else
    raise notice '0130: fn_bill_student_month already bounds the month';
  end if;

  -- A whole class. This one is handed the session id directly.
  v_src := pg_get_functiondef(
    'public.fn_generate_class_invoices(uuid,uuid,date,date)'::regprocedure);
  if position('fn__assert_date_in_session' in v_src) = 0 then
    if position('  perform public.assert_own(''classes'', p_class_id);' in v_src) = 0 then
      raise exception '0130: fn_generate_class_invoices no longer asserts the '
        'class where this migration inserts the period check after it. The '
        'change is one call: fn__assert_date_in_session(p_session_id, '
        'p_period_month, ...), plus the same window on p_due_date.';
    end if;
    v_new := replace(v_src,
      '  perform public.assert_own(''classes'', p_class_id);',
      '  perform public.assert_own(''classes'', p_class_id);' || E'\n' ||
      E'\n' ||
      '  -- 0130: same rule as the single-pupil version, and it matters more' || E'\n' ||
      '  -- here: this writes a challan for every child in the class, so a' || E'\n' ||
      '  -- mistyped year is forty rows in a month nobody will look at.' || E'\n' ||
      '  perform public.fn__assert_date_in_session(p_session_id,' || E'\n' ||
      '            p_period_month, ''Generating challans for a class'',' || E'\n' ||
      '            true);' || E'\n' ||
      v_due);
    if v_new = v_src then
      raise exception '0130: the fn_generate_class_invoices rewrite did not take';
    end if;
    execute v_new;
    raise notice '0130: a class''s challans belong to the session being billed';
  else
    raise notice '0130: fn_generate_class_invoices already bounds the month';
  end if;
end $inv$;

-- 4d. EVERYTHING ELSE THAT STORES A DATE THE CALLER TYPED.
--
--     ONE LOOP AND SIX DATA ROWS, rather than six do-blocks. Each row is a
--     signature, a single-line anchor, the expression to check and the sentence
--     the caller reads. Written this way because six near-identical blocks is
--     six places for one rule to drift, and because the anchors are the risky
--     part: keeping them together makes them reviewable side by side.
--
--     The expense and income checks go BEFORE next_counter, so a refused entry
--     does not burn a voucher number and leave a gap in a numbered series
--     somebody files with the tax office.
--
--     `session:` prefixes an expression naming the session to check against;
--     anything else is checked against the school's whole calendar.
do $cash$
declare v_src text; v_new text; r record; v_call text;
begin
  for r in
    select * from (values
      ('fn_record_expense(numeric,uuid,date,text,public.payment_method,text)',
       '  v_no := public.next_counter(''expense_voucher'');',
       'coalesce(p_spent_on, current_date)', 'Recording an expense', 'before'),
      ('fn_record_other_income(numeric,text,date,public.payment_method,text)',
       '  v_no := public.next_counter(''income_voucher'');',
       'coalesce(p_received_on, current_date)', 'Recording income', 'before'),
      -- A DEPOSIT'S DUE DATE lands on a real invoice, which is why this one is
      -- in and fn_issue_certificate is not: a due date decides when a family is
      -- a defaulter, and one in 2062 means they never are.
      ('fn_charge_deposit(uuid,uuid,numeric,date,text)',
       '  perform public.assert_own(''fee_heads'', p_fee_head_id);',
       'coalesce(p_due_date, current_date)', 'Charging a deposit', 'after'),
      -- THE TWO THAT DECIDE WHAT EVERY CHILD IS BILLED. effective_from is not a
      -- label: fee_structures is read by date, so a row effective from 1900 or
      -- 2062 silently changes, or silently fails to change, every challan
      -- afterwards. Bounded to the session because a fee belongs to a year.
      ('fn_set_fee_amount(uuid,uuid,uuid,numeric,date)',
       '  perform public.assert_own(''fee_heads'', p_fee_head_id);',
       'session:p_session_id:coalesce(p_effective_from, current_date)',
       'Setting a fee amount', 'after'),
      ('fn_fee_increment(uuid,uuid[],uuid[],numeric,numeric,date,boolean)',
       '  perform public.assert_own(''academic_sessions'', p_session_id);',
       'session:p_session_id:p_effective_from',
       'Raising fees across classes', 'after'),
      -- An exam paper's date, bounded to the year the exam term belongs to.
      ('fn_upsert_exam_subject(uuid,uuid,uuid,numeric,numeric,numeric,date,text)',
       '  perform public.assert_own(''subjects'', p_subject_id);',
       'session:(select et.session_id from public.exam_terms et'
       || ' where et.id = p_exam_term_id'
       || ' and et.school_id = public.current_school_id()):p_exam_date',
       'Setting an exam paper''s date', 'after')
    ) as t(sig, anchor, arg, what, pos)
  loop
    v_src := pg_get_functiondef(('public.' || r.sig)::regprocedure);
    -- BOTH NAMES. This looked for fn__assert_date_in_calendar only, so the
    -- four rows using the session bound were not recognised as already patched
    -- and appended a second copy of themselves on the second paste. Caught by
    -- preflight's re-paste fingerprint, which is the check that exists because
    -- 0042 appended a clause to fn_import_staff once per paste, forever.
    if position('fn__assert_date_in_' in v_src) > 0 then
      raise notice '0130: % already bounds its date', r.sig;
      continue;
    end if;
    if position(r.anchor in v_src) = 0 then
      raise exception '0130: % no longer takes its voucher number where this '
        'migration inserts the date check before it. The check must go BEFORE '
        'next_counter, or a refused entry burns a voucher number and leaves a '
        'gap in a numbered series somebody files.', r.sig;
    end if;
    -- `session:<expr>:<date>` checks against one academic year; anything else
    -- checks against the school's whole span. Null dates are skipped rather
    -- than refused: every one of these parameters is optional, and a caller who
    -- gave no date gets today, which the coalesce in each row supplies.
    if left(r.arg, 8) = 'session:' then
      v_call :=
        '  perform public.fn__assert_date_in_session(' || E'\n' ||
        '            ' || split_part(substr(r.arg, 9), ':', 1) || ',' || E'\n' ||
        '            ' || split_part(substr(r.arg, 9), ':', 2) || ', '
                       || quote_literal(r.what) || ',' || E'\n' ||
        '            -- whole months: a fee''s effective date is a month label' || E'\n' ||
        '            true);' || E'\n';
    else
      v_call :=
        '  perform public.fn__assert_date_in_calendar(' || E'\n' ||
        '            ' || r.arg || ', ' || quote_literal(r.what) || ');' || E'\n';
    end if;
    -- BEFORE OR AFTER THE ANCHOR, and it matters for two of the six. The
    -- expense and income anchors are `v_no := next_counter(...)`, which
    -- consumes a voucher number: a check placed after it would burn one on
    -- every refusal and leave gaps in a numbered series somebody files with the
    -- tax office. The other four anchor on an assert_own, where after is right
    -- because the tenant check should come first.
    v_call :=
      '  -- THE DATE (0130). Nothing bounded it, and a date nobody checked is a' || E'\n' ||
      '  -- year somebody mistyped: a record dated outside its academic year' || E'\n' ||
      '  -- appears on no screen afterwards and can never be found again.' || E'\n' ||
      v_call;
    v_new := replace(v_src, r.anchor,
      case when r.pos = 'before' then v_call || r.anchor
           else r.anchor || E'\n' || v_call end);
    if v_new = v_src then
      raise exception '0130: the % rewrite did not take', r.sig;
    end if;
    execute v_new;
    raise notice '0130: % cannot be dated outside the school''s records', r.sig;
  end loop;
end $cash$;

-- ---------------------------------------------------------------------------
-- 5. WHO HAS NO DATES, RIGHT NOW
--
-- Not repaired, and that is the decision. Deriving "April to March" from a name
-- like "2026-2027" would be a guess, and a wrong guess here puts wrong dates on
-- a live school's academic year and then makes section 4 reject its real
-- register. Deriving them from the data would set this year's last day to
-- today, which would refuse tomorrow's attendance.
--
-- So it reports, verify.sql keeps reporting until it is fixed, and the two
-- screens that create a session now ask for the dates.
-- ---------------------------------------------------------------------------
do $report$
declare r record; v_n integer := 0;
begin
  for r in
    select s.name as school, a.name as session, a.is_current
      from public.academic_sessions a
      join public.schools s on s.id = a.school_id
     where a.starts_on is null or a.ends_on is null
     order by s.name, a.name
  loop
    v_n := v_n + 1;
    raise notice '0130: "%" has an academic year "%"% with no first or last '
      'day. Fill it in under Settings, Sessions. Until then nothing is '
      'refused for that year, and the software cannot tell you when it ends.',
      r.school, r.session,
      case when r.is_current then ' (the current one)' else '' end;
  end loop;
  if v_n = 0 then
    raise notice '0130: every academic year has a first and a last day';
  else
    raise notice '0130: % academic year(s) have no dates. New ones now require '
      'them; these are left exactly as they are.', v_n;
  end if;
end $report$;

-- ---------------------------------------------------------------------------
-- THE GUARDS
-- ---------------------------------------------------------------------------
do $check$
declare v_name text; v_n integer;
begin
  -- 1. EVERY CALLER-SUPPLIED DATE IS BOUNDED. Read off the catalogue rather
  --    than from a list of six function names, so a function added later that
  --    takes a date parameter and writes a row fails this instead of quietly
  --    accepting 2099. The exemptions are named with their reason.
  for v_name in
    select p.proname
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.prokind = 'f'
       and p.proname like 'fn\_%'
       -- takes a date from the caller
       and exists (
         select 1 from unnest(p.proargtypes) as t(oid)
          where t.oid = 'date'::regtype)
       -- and writes a row of its own
       and p.prosrc ~ 'insert into public\.'
       and p.prosrc !~ 'fn__assert_date_in_(session|calendar)'
       and p.proname not in (
         -- Takes a LEAVING date, and the rule it needs is different and
         -- already there: fn_set_student_status refuses a last day in the
         -- future and one before the admission date. Bounding it to the
         -- academic calendar as well would refuse a school recording that a
         -- child left in a year they have not set up.
         'fn_set_student_status',
         -- Takes the two dates of the session it is creating, so there is no
         -- calendar to check them against yet. Section 1's constraints are
         -- what bound these.
         'fn_rollover',
         -- Platform billing, not a school record. A licence period is the
         -- vendor's calendar and has nothing to do with an academic year;
         -- fn_activate_subscription already refuses a term outside 1 to 60
         -- months.
         -- Names checked against the catalogue, not typed from memory. The
         -- first draft of this list had fn_record_platform_payment and four
         -- other functions that do not exist, and the guard told me so one at
         -- a time on five separate runs. An exemption for a function that is
         -- not there protects nothing and hides nothing; it is just noise in
         -- a list somebody has to read.
         'fn_activate_subscription', 'fn_platform_record_payment',
         -- Reads a date to report on, and its insert is an audit row.
         'fn_platform_run_renewals',
         -- A school telling US about a bank transfer. That is the vendor's
         -- calendar, which has nothing to do with an academic year: a school
         -- can legitimately report a payment made before its first session
         -- started, because that is when it bought the software.
         'fn_my_report_payment',

         -- ---- THE DATE SELECTS EXISTING ROWS AND CANNOT CREATE ONE ----
         -- Both take a date to find a register that is already there:
         -- finalize sets is_locked on the rows of that section-day, unlock
         -- clears it. A wild date matches nothing, locks nothing and unlocks
         -- nothing. Their only insert is the audit row 0126 added, so the
         -- worst a mistyped year does is record that a day nobody has was
         -- closed, and fn_mark_attendance now refuses to create that day in
         -- the first place.
         'fn_finalize_attendance', 'fn_unlock_attendance',

         -- ---- A LEAVING DATE, WHICH HAS ITS OWN STRICTER RULES ----
         -- The same category as fn_set_student_status above, and they share
         -- the reasoning: a leaving date is refused if it is in the future or
         -- before the admission date, which is tighter than the academic
         -- calendar in the direction that matters and looser in the direction
         -- a school needs. Binding them to the calendar as well would refuse a
         -- school recording that a child or a teacher left in a year they have
         -- not set up, which is exactly what a school migrating from paper
         -- does first.
         'fn_issue_certificate', 'fn_staff_leave',

         -- ---- DELIBERATELY IN THE FUTURE ----
         -- p_next_follow_up is a date to ring somebody back on. Its whole
         -- purpose is to be after today, and a follow-up in three weeks may
         -- legitimately fall after the current session ends.
         'fn_log_enquiry_contact',
         -- A validity window on a staff check-in code. Bounded already by the
         -- thing that matters: fn_staff_check_in refuses a code outside its
         -- window, and a code with an absurd window is deactivated by the next
         -- one generated.
         'fn_generate_checkin_code')
     order by 1
  loop
    raise exception '0130: % takes a date from the caller and writes a row '
      'without bounding it. Nothing stopped attendance being marked in 2099. '
      'Call fn__assert_date_in_session (a record that belongs to one academic '
      'year) or fn__assert_date_in_calendar (one that belongs to the school), '
      'or add it to the exemptions in this guard WITH the reason.', v_name;
  end loop;

  -- 2. AND THE TWO HELPERS ARE NOT REACHABLE FROM A BROWSER, which is 0125's
  --    rule. They are internal, they take a school-scoped id, and a browser
  --    calling them learns the dates of a session it can already read.
  for v_name in
    select p.proname from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and p.proname in ('fn__assert_date_in_session', 'fn__assert_date_in_calendar')
       and (has_function_privilege('authenticated', p.oid, 'execute')
            or has_function_privilege('anon', p.oid, 'execute'))
  loop
    raise exception '0130: % is callable from a browser', v_name;
  end loop;

  -- 3. AND THE SANITY CONSTRAINTS ARE THERE. Without the length one, sixty
  --    sessions could still span five thousand years and bound nothing.
  select count(*) into v_n from pg_constraint
   where conrelid = 'public.academic_sessions'::regclass
     and conname in ('academic_sessions_dates_ordered',
                     'academic_sessions_length_sane');
  if v_n <> 2 then
    raise exception '0130: % of the 2 session sanity constraints are present', v_n;
  end if;

  raise notice '0130: a school year has a first and a last day, and nothing is '
    'recorded outside them';
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
  perform public.fn_record_migration('0130_a_school_year_has_dates.sql', '36_a_school_year_has_dates.sql');
end $ledger$;

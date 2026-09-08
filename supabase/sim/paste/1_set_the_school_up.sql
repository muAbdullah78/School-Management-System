-- =============================================================================
-- GENERATED FILE. DO NOT EDIT except for the one line marked below.
-- Built from supabase/sim/ by scripts/build-sim-bundle.py
--
-- TWO YEARS OF ONE SCHOOL'S USE. FILE 1 OF 7: set the school up
--
-- The school profile, four academic years, 12 classes, 17 sections, 76 subjects, 7 fee heads with a full fee sheet, 23 staff, and the 120 children who were already on the roll in February 2024. Seconds.
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
  --    equality on schools.name. An earlier version trimmed the setting before
  --    comparing, which made this check PASS on a name the body then failed on,
  --    and a check that disagrees with the code it guards is worse than no
  --    check. So instead of loosening the comparison, this loosens the SEARCH
  --    and then corrects the setting, which every later statement reads.
  --
  --    IT SEARCHES BOTH NAME COLUMNS, and that is not belt and braces: it is
  --    the defect migration 0123 fixes. school_settings.name is the only one a
  --    school can edit, schools.name is the one this file matches on, and until
  --    0123 nothing kept them in step. So a school reading its own name off its
  --    own screen and pasting it in here would be pasting the OTHER column, and
  --    every file in the set refused. That is exactly how it was reported.
  select id into v_school from public.schools where name = v_name;

  if v_school is null then
    -- The name the school sees on its own screens, which is the one a reader
    -- copies. Matched exactly first, before any fuzziness.
    select s.id, s.name into v_school, v_all
      from public.schools s
      join public.school_settings st on st.school_id = s.id
     where st.name = v_name;

    if v_school is not null then
      raise notice 'That is the name on this school''s own screens. In the '
        'database it is still stored as "%", which is what the console and its '
        'invoices show: two names for one school, which '
        'supabase/bundles/29_a_school_has_one_name.sql puts right. Continuing '
        'with the stored one.', v_all;
      perform set_config('sim.school', v_all, true);
      v_name := v_all;
    else
      -- One near miss and no ambiguity, across either column: almost always a
      -- trailing space, which is invisible in Settings and in the sidebar, or a
      -- capital letter. Fix it and say so loudly enough that nobody could think
      -- a different school was filled by accident.
      select count(*), min(s.name) into v_near, v_all
        from public.schools s
        left join public.school_settings st on st.school_id = s.id
       where lower(btrim(s.name))  = lower(btrim(v_name))
          or lower(btrim(st.name)) = lower(btrim(v_name));

      if v_near = 1 then
        raise notice 'The name given was "%" and this school is stored as "%". '
          'Same school, so continuing with the stored spelling.', v_name, v_all;
        perform set_config('sim.school', v_all, true);
        v_name := v_all;
      else
        -- BOTH names per school, because the whole difficulty here is that a
        -- school has two and can only see one of them.
        select string_agg('"' || s.name || '"'
                 || case when st.name is distinct from s.name
                           then ' (its own screens say "' || st.name || '")'
                         else '' end, ', ' order by s.name)
          into v_all
          from public.schools s
          left join public.school_settings st on st.school_id = s.id;
        raise exception 'No school is named "%". This project holds %. Copy the '
          'one you want, character for character including any spaces, into the '
          '"sim.school" line at the top of every file in this set.',
          v_name, coalesce(v_all, 'no schools at all');
      end if;
    end if;
    select id into v_school from public.schools where name = v_name;
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
-- 01_foundation.sql
-- ------------------------------------------------------------------------
reset role;
-- =============================================================================
-- SIMULATION, PART 1 OF N: the school as it was set up in February 2024.
--
-- WHAT THIS IS FOR, AND WHY IT IS NOT A FIXTURE
--
-- This is not test data in the usual sense. It is a two-year QA run against the
-- application's OWN write paths: every row below arrives through the same
-- function or the same insert the user interface uses, with a real signed-in
-- owner's session and Row Level Security switched on. Raw inserts would fill
-- the tables faster and prove nothing at all: fn_record_payment is what keeps
-- the ledger balanced, fn_close_till is what catches a till variance, and
-- fn_publish_results is what stops a parent seeing an unpublished mark. A seed
-- that bypasses them tests the shape of the schema and none of its behaviour.
--
-- HOW THE SESSION IS FAKED, AND WHY THIS EXACT WAY
--
-- Every one of those functions keys off auth.uid(), which on Supabase reads
-- request.jwt.claims: the GUC PostgREST sets on a real HTTP request. So this
-- file sets that GUC and nothing else. It does NOT redefine auth.uid(), which
-- is how supabase/tests/*.sql do it. That is correct for a test that runs in a
-- transaction on a throwaway database and catastrophic here: redefining
-- auth.uid() on a live project breaks every request from every real school for
-- as long as the definition stands.
--
-- IDEMPOTENT. Every insert is guarded. Running this file twice adds nothing and
-- raises nothing, because a paste that half-succeeded and cannot be repeated is
-- worse than one that fails outright.
--
-- Run: psql -v ON_ERROR_STOP=1 -f supabase/sim/01_foundation.sql
-- =============================================================================



-- --- Become the school's owner -----------------------------------------------
-- Looked up while still superuser, because profiles is behind RLS and the
-- context needed to read it is the thing being established.
select set_config(
  'request.jwt.claims',
  jsonb_build_object('sub', p.id::text, 'role', 'authenticated')::text,
  true)
from public.profiles p
join public.schools s on s.id = p.school_id
where s.name = current_setting('sim.school')
  and p.role = 'owner' and p.active
limit 1;

-- RLS applies from here down. If any statement below fails on a policy, that is
-- a finding about the application and not about this file.
set local role authenticated;

do $sim$
declare
  v_school uuid := public.current_school_id();
  v_sess_2324 uuid; v_sess_2425 uuid; v_sess_2526 uuid; v_sess_2627 uuid;
  v_class uuid;
  r record;
begin
  if v_school is null then
    raise exception 'No owner session. Is the school name exactly right?';
  end if;

  -- --- 1. School profile -----------------------------------------------------
  -- The screenshot that started this run showed every one of these fields
  -- empty, which is what a school looks like on day one and not what one looks
  -- like after two years of use.
  -- day_starts_at, the grace window and the geofence are set too. They are not
  -- cosmetic: they are what fn_staff_check_in judges a check-in against, so a
  -- school with them at their defaults never produces a "late" staff row and
  -- the lateness half of that feature would go untested.
  update public.school_settings set
    name_short         = 'CPHS Ghauri',
    principal_name     = 'Rana Abdul Rasheed',
    phone              = '051-4938271',
    email              = 'office@chaudharypuclix.pk',
    address            = 'Street 7, Ghauri Town Phase 3, Islamabad',
    grade_scale        = 'letter',
    pass_percent       = 33,
    gr_prefix          = 'GR-',
    receipt_prefix     = 'R-',
    day_starts_at      = time '07:45',
    day_ends_at        = time '13:30',
    late_grace_minutes = 10,
    geofence_enabled   = true,
    geo_lat            = 33.5651,
    geo_lng            = 73.1234,
    geo_radius_m       = 150
  where school_id = v_school;

  -- --- 2. Academic sessions --------------------------------------------------
  -- April to March, the Punjab private-school year. Four of them, because the
  -- school joined mid-2023-2024 and today is inside 2026-2027: three year-end
  -- rollovers happen inside this simulation, not the two originally asked for.
  insert into public.academic_sessions (name, starts_on, ends_on, is_current)
  select v.name, v.s, v.e, false
    from (values
      ('2023-2024', date '2023-04-01', date '2024-03-31'),
      ('2024-2025', date '2024-04-01', date '2025-03-31'),
      ('2025-2026', date '2025-04-01', date '2026-03-31'),
      ('2026-2027', date '2026-04-01', date '2027-03-31')
    ) as v(name, s, e)
   where not exists (select 1 from public.academic_sessions a
                      where a.school_id = v_school and a.name = v.name);

  select id into v_sess_2324 from public.academic_sessions
   where school_id = v_school and name = '2023-2024';
  select id into v_sess_2425 from public.academic_sessions
   where school_id = v_school and name = '2024-2025';
  select id into v_sess_2526 from public.academic_sessions
   where school_id = v_school and name = '2025-2026';
  select id into v_sess_2627 from public.academic_sessions
   where school_id = v_school and name = '2026-2027';

  -- The school starts the simulation in its 2023-2024 year. fn_rollover moves
  -- this forward three times in 04_the_years.sql, which is the point.
  --
  -- GUARDED, AND THIS FILE CLAIMED TO BE IDEMPOTENT WITHOUT IT. Every insert
  -- above is guarded by a `not exists`; this line is an UPDATE, and it was the
  -- one destructive statement in the file. Re-running it on a finished school
  -- rewound the current year from 2026-2027 to 2023-2024, so the dashboard,
  -- the register, the fee screens and the class lists all went blank: they read
  -- the current session, and the current session suddenly had nothing in it.
  -- Measured on the finished simulation, which is how this was found.
  --
  -- Anybody who re-runs a set of seven files "to be sure" would hit that, and
  -- would reasonably conclude the data had been lost when it was all still
  -- there. The guard is enrolments in a later year: on a first run there are
  -- none, and after 04_the_years.sql there are hundreds.
  if not exists (select 1 from public.enrollments e
                  where e.school_id = v_school
                    and e.session_id is distinct from v_sess_2324) then
    update public.academic_sessions set is_current = (id = v_sess_2324)
     where school_id = v_school;
  else
    raise notice 'this school has already been rolled past 2023-2024, so the '
      'current session is left as it is';
  end if;

  -- --- 3. Classes ------------------------------------------------------------
  -- Nursery to Class 10: a high school, which is what the name says. level_order
  -- is what the rollover walks up, so it has to be right or promotion sends
  -- Class 9 into Nursery.
  insert into public.classes (name, level_order, active)
  select v.name, v.lvl, true
    from (values
      ('Nursery', 1), ('Prep', 2), ('Class 1', 3), ('Class 2', 4),
      ('Class 3', 5), ('Class 4', 6), ('Class 5', 7), ('Class 6', 8),
      ('Class 7', 9), ('Class 8', 10), ('Class 9', 11), ('Class 10', 12)
    ) as v(name, lvl)
   where not exists (select 1 from public.classes c
                      where c.school_id = v_school and c.name = v.name);

  -- --- 4. Sections -----------------------------------------------------------
  -- Every class gets A. Classes 1 to 5 get a B as well, because the primary
  -- years are where the numbers actually are in a school of this size. Two
  -- sections in one class is also the case that catches a roster query which
  -- silently assumes one.
  for r in select id, name, level_order from public.classes
            where school_id = v_school order by level_order loop
    insert into public.sections (class_id, name, sort_order)
    select r.id, 'A', 1
     where not exists (select 1 from public.sections s
                        where s.class_id = r.id and s.name = 'A');
    if r.level_order between 3 and 7 then
      insert into public.sections (class_id, name, sort_order)
      select r.id, 'B', 2
       where not exists (select 1 from public.sections s
                          where s.class_id = r.id and s.name = 'B');
    end if;
  end loop;

  -- --- 5. Subjects -----------------------------------------------------------
  -- Per class, because that is how the table is keyed. The senior classes get
  -- the extra papers, which is what makes a result card for Class 9 different
  -- in shape from one for Prep and therefore worth testing separately.
  for r in select id, name, level_order from public.classes
            where school_id = v_school order by level_order loop
    insert into public.subjects (name, class_id, sort_order)
    select v.name, r.id, v.ord
      from (values
        ('English', 1), ('Urdu', 2), ('Mathematics', 3), ('Islamiat', 4)
      ) as v(name, ord)
     where not exists (select 1 from public.subjects s
                        where s.class_id = r.id and s.name = v.name);
    if r.level_order >= 5 then
      insert into public.subjects (name, class_id, sort_order)
      select v.name, r.id, v.ord
        from (values ('Science', 5), ('Social Studies', 6), ('Computer', 7)) as v(name, ord)
       where not exists (select 1 from public.subjects s
                          where s.class_id = r.id and s.name = v.name);
    end if;
    if r.level_order >= 11 then
      insert into public.subjects (name, class_id, sort_order)
      select v.name, r.id, v.ord
        from (values ('Physics', 8), ('Chemistry', 9), ('Biology', 10), ('Pak Studies', 11)) as v(name, ord)
       where not exists (select 1 from public.subjects s
                          where s.class_id = r.id and s.name = v.name);
      -- Science subjects replaced by the real papers at this level.
      delete from public.subjects
       where class_id = r.id and name in ('Science', 'Social Studies');
    end if;
  end loop;

  raise notice 'sessions=% classes=% sections=% subjects=%',
    (select count(*) from public.academic_sessions where school_id = v_school),
    (select count(*) from public.classes where school_id = v_school),
    (select count(*) from public.sections s join public.classes c on c.id = s.class_id
      where c.school_id = v_school),
    (select count(*) from public.subjects s join public.classes c on c.id = s.class_id
      where c.school_id = v_school);
end
$sim$;




-- ------------------------------------------------------------------------
-- 02_money_and_staff.sql
-- ------------------------------------------------------------------------
reset role;
-- =============================================================================
-- SIMULATION, PART 2: what the school charges, and who works there.
--
-- FEE HEADS GO THROUGH fn_upsert_fee_head AND NOT AN INSERT, because that
-- function is what decides whether a head is billable monthly, once a year, or
-- held as a refundable deposit, and those three behave differently everywhere
-- downstream. A security deposit that arrives as a plain insert with the wrong
-- is_refundable flag looks identical in the table and produces a balance sheet
-- that does not balance.
--
-- AMOUNTS RISE WITH THE CLASS AND WITH THE YEAR. A flat fee across twelve
-- classes and three sessions would leave fn_fee_increment, the head-wise dues
-- report and the class dues report all reading the same number, and none of
-- them would be telling us anything.
--
-- Run: psql -v ON_ERROR_STOP=1 -f supabase/sim/02_money_and_staff.sql
-- =============================================================================



select set_config(
  'request.jwt.claims',
  jsonb_build_object('sub', p.id::text, 'role', 'authenticated')::text, true)
from public.profiles p join public.schools s on s.id = p.school_id
where s.name = current_setting('sim.school')
  and p.role = 'owner' and p.active limit 1;
set local role authenticated;

do $sim$
declare
  v_school uuid := public.current_school_id();
  v_admission uuid; v_tuition uuid; v_annual uuid; v_exam uuid;
  v_deposit uuid; v_transport uuid; v_misc uuid;
  r record; s record;
  v_base numeric; v_year_factor numeric;
begin
  if v_school is null then raise exception 'No owner session.'; end if;

  -- --- 1. Fee heads ----------------------------------------------------------
  select id into v_admission from public.fee_heads where school_id = v_school and name = 'Admission Fee';
  if v_admission is null then
    v_admission := public.fn_upsert_fee_head('Admission Fee', 'admission', false, false, 1);
  end if;
  select id into v_tuition from public.fee_heads where school_id = v_school and name = 'Monthly Tuition';
  if v_tuition is null then
    v_tuition := public.fn_upsert_fee_head('Monthly Tuition', 'monthly', true, false, 2);
  end if;
  select id into v_annual from public.fee_heads where school_id = v_school and name = 'Annual Charges';
  if v_annual is null then
    v_annual := public.fn_upsert_fee_head('Annual Charges', 'annual', false, false, 3);
  end if;
  select id into v_exam from public.fee_heads where school_id = v_school and name = 'Exam Fee';
  if v_exam is null then
    v_exam := public.fn_upsert_fee_head('Exam Fee', 'exam', false, false, 4);
  end if;
  -- REFUNDABLE, and the only one. fn_charge_deposit, fn_deposits_held and
  -- fn_refund_deposit all hang off this flag, and migration 0117's invoice
  -- trigger refuses to mix a refundable line with a normal one on one challan.
  select id into v_deposit from public.fee_heads where school_id = v_school and name = 'Security Deposit';
  if v_deposit is null then
    v_deposit := public.fn_upsert_fee_head('Security Deposit', 'security_deposit', false, true, 5);
  end if;
  select id into v_transport from public.fee_heads where school_id = v_school and name = 'Transport';
  if v_transport is null then
    v_transport := public.fn_upsert_fee_head('Transport', 'transport', true, false, 6);
  end if;
  select id into v_misc from public.fee_heads where school_id = v_school and name = 'Stationery';
  if v_misc is null then
    v_misc := public.fn_upsert_fee_head('Stationery', 'misc', false, false, 7);
  end if;

  -- --- 2. Fee structures, per class per session ------------------------------
  -- Rs 900 in Nursery rising to Rs 2,550 in Class 10, and the whole sheet up
  -- roughly 10% a year. Transport is deliberately NOT set for every class: a
  -- head with no amount in some classes is what "classes without fee" on the
  -- dashboard counts, and a school where that number is always zero never
  -- exercises it.
  for s in select id, name, starts_on from public.academic_sessions
            where school_id = v_school order by starts_on loop
    v_year_factor := case s.name
      when '2023-2024' then 1.00 when '2024-2025' then 1.10
      when '2025-2026' then 1.21 else 1.33 end;
    for r in select id, name, level_order from public.classes
              where school_id = v_school order by level_order loop
      v_base := 900 + (r.level_order - 1) * 150;

      -- THROUGH fn_set_fee_amount, NOT AN INSERT, and the reason is a finding:
      -- `authenticated` has no INSERT grant on fee_structures at all. Every
      -- table where money or a permanent record lives is RPC-only in this
      -- schema (invoices, payments, allocations, discounts, attendance, marks,
      -- result cards, certificates, fee heads and structures, login secrets),
      -- while reference data and settings are directly writable behind RLS.
      -- The first draft of this file inserted straight into the table and was
      -- refused, which is the boundary working exactly as designed.
      perform public.fn_set_fee_amount(s.id, r.id, v.head, round(v.amt), s.starts_on)
        from (values
          (v_tuition,   v_base * v_year_factor),
          (v_admission, 3000 * v_year_factor),
          (v_annual,    (1500 + r.level_order * 100) * v_year_factor),
          (v_exam,      (300 + r.level_order * 25) * v_year_factor),
          (v_deposit,   1000::numeric),
          (v_misc,      (250 + r.level_order * 20) * v_year_factor)
        ) as v(head, amt);

      -- Transport only for the classes that actually use the van, so that
      -- "classes without a fee" on the dashboard has something real to count.
      if r.level_order between 3 and 10 then
        perform public.fn_set_fee_amount(s.id, r.id, v_transport,
                                         round(1200 * v_year_factor), s.starts_on);
      end if;
    end loop;
  end loop;

  raise notice 'fee heads=%  fee structure rows=%',
    (select count(*) from public.fee_heads where school_id = v_school),
    (select count(*) from public.fee_structures where school_id = v_school);
end
$sim$;

-- --- 3. Staff ----------------------------------------------------------------
-- Twenty-three people, with joining dates spread across the two years and two
-- who have since left. A roster where everybody joined on day one and nobody
-- ever left leaves fn_staff_leave, fn_staff_rejoin and the left_on filters in
-- every roster query completely unvisited.
do $sim$
declare
  v_school uuid := public.current_school_id();
  r record;
begin
  insert into public.staff (full_name, designation, employee_no, mobile, whatsapp,
                            cnic, joined_on, left_on, status, dob)
  select v.nm, v.desig, v.emp, v.mob, v.mob, v.cnic, v.joined, v.left_on, v.st, v.dob
    from (values
      ('Rana Abdul Rasheed', 'Principal',        'E-001', '03005512340', '61101-2233445-1', date '2019-04-01', null::date, 'active', date '1974-06-12'),
      ('Nasreen Akhtar',     'Vice Principal',   'E-002', '03215512341', '61101-2233446-2', date '2020-04-01', null,        'active', date '1980-02-28'),
      ('Bilal Ahmed Khan',   'Admin Clerk',      'E-003', '03335512342', '61101-2233447-3', date '2021-08-16', null,        'active', date '1993-11-05'),
      ('Sadia Parveen',      'Admin Clerk',      'E-004', '03455512343', '61101-2233448-4', date '2024-05-02', null,        'active', date '1996-07-19'),
      ('Muhammad Tanveer',   'Accountant',       'E-005', '03005512344', '61101-2233449-5', date '2022-01-10', null,        'active', date '1988-03-30'),
      ('Ayesha Siddiqua',    'Class Teacher',    'E-006', '03215512345', '61101-2233450-6', date '2021-04-01', null,        'active', date '1994-09-14'),
      ('Farhat Naz',         'Class Teacher',    'E-007', '03335512346', '61101-2233451-7', date '2021-04-01', null,        'active', date '1991-12-01'),
      ('Kausar Bibi',        'Class Teacher',    'E-008', '03455512347', '61101-2233452-8', date '2022-04-01', null,        'active', date '1985-05-23'),
      ('Shazia Rehman',      'Class Teacher',    'E-009', '03005512348', '61101-2233453-9', date '2022-04-01', null,        'active', date '1990-08-08'),
      ('Iram Shahzadi',      'Class Teacher',    'E-010', '03215512349', '61101-2233454-0', date '2023-04-03', null,        'active', date '1997-01-17'),
      ('Saima Noreen',       'Class Teacher',    'E-011', '03335512350', '61101-2233455-1', date '2023-04-03', null,        'active', date '1995-04-04'),
      ('Zubair Hussain',     'Class Teacher',    'E-012', '03455512351', '61101-2233456-2', date '2023-09-01', null,        'active', date '1992-10-26'),
      ('Abdul Waheed',       'Class Teacher',    'E-013', '03005512352', '61101-2233457-3', date '2024-04-01', null,        'active', date '1989-02-11'),
      ('Rukhsana Kausar',    'Class Teacher',    'E-014', '03215512353', '61101-2233458-4', date '2024-04-01', null,        'active', date '1998-06-30'),
      ('Naveed Iqbal',       'Class Teacher',    'E-015', '03335512354', '61101-2233459-5', date '2024-08-19', null,        'active', date '1993-07-07'),
      ('Hina Aslam',         'Class Teacher',    'E-016', '03455512355', '61101-2233460-6', date '2025-04-01', null,        'active', date '1999-03-21'),
      ('Tahira Yasmin',      'Class Teacher',    'E-017', '03005512356', '61101-2233461-7', date '2025-04-01', null,        'active', date '1996-11-11'),
      ('Imran Sajid',        'Subject Teacher',  'E-018', '03215512357', '61101-2233462-8', date '2022-04-01', null,        'active', date '1987-08-15'),
      ('Asma Batool',        'Subject Teacher',  'E-019', '03335512358', '61101-2233463-9', date '2023-04-03', null,        'active', date '1994-05-09'),
      ('Waqar Younis Butt',  'Subject Teacher',  'E-020', '03455512359', '61101-2233464-0', date '2025-08-18', null,        'active', date '1990-01-25'),
      ('Allah Ditta',        'Caretaker',        'E-021', '03005512360', '61101-2233465-1', date '2019-04-01', null,        'active', date '1968-04-02'),
      -- The two who left. One resigned mid-session, one at a year end.
      ('Sumaira Kanwal',     'Class Teacher',    'E-022', '03215512361', '61101-2233466-2', date '2021-04-01', date '2024-11-30', 'left', date '1992-02-14'),
      ('Ghulam Murtaza',     'Subject Teacher',  'E-023', '03335512362', '61101-2233467-3', date '2022-04-01', date '2025-03-31', 'left', date '1986-09-19')
    ) as v(nm, desig, emp, mob, cnic, joined, left_on, st, dob)
   where not exists (select 1 from public.staff st2
                      where st2.school_id = v_school and st2.employee_no = v.emp);

  -- --- 4. Class teachers -----------------------------------------------------
  -- fn_set_class_teacher rather than an update, because it is the function that
  -- keeps one teacher per section and writes the teacher_assignments row the
  -- teacher's own "my assignments" screen reads.
  -- One teacher per section, in every session, because teacher_assignments is
  -- keyed by session: an assignment made once in 2023-2024 leaves a teacher
  -- with no classes for the next three years, and "my assignments" empty.
  for r in
    with secs as (
      select s.id as section_id, s.class_id,
             row_number() over (order by c.level_order, s.sort_order) as pos
        from public.sections s
        join public.classes c on c.id = s.class_id
       where c.school_id = v_school
    ), tchr as (
      select id, row_number() over (order by employee_no) as k,
             count(*) over () as total
        from public.staff
       where school_id = v_school and designation = 'Class Teacher' and status = 'active'
    )
    select sec.section_id, sec.class_id, t.id as staff_id, ses.id as session_id
      from secs sec
      join tchr t on t.k = ((sec.pos - 1) % t.total) + 1
      cross join (select id from public.academic_sessions where school_id = v_school) ses
  loop
    begin
      perform public.fn_set_class_teacher(r.staff_id, r.session_id, r.class_id, r.section_id);
    exception when others then
      raise notice 'class teacher assignment skipped: %', sqlerrm;
    end;
  end loop;

  raise notice 'staff=% (active=%)  teacher assignments=%',
    (select count(*) from public.staff where school_id = v_school),
    (select count(*) from public.staff where school_id = v_school and status = 'active'),
    (select count(*) from public.teacher_assignments where school_id = v_school);
end
$sim$;




-- ------------------------------------------------------------------------
-- 03_students.sql
-- ------------------------------------------------------------------------
reset role;
-- =============================================================================
-- SIMULATION, PART 3: the hundred and twenty children already on the roll.
--
-- EVERY ONE THROUGH fn_admit_student, which is the only way the family model
-- gets exercised. That function reads father_cnic and puts siblings in the SAME
-- family (migration 0036), which is what makes one payment cover two children.
-- Inserting into students directly would produce 260 families of one and leave
-- fn_record_family_payment, fn_family_sheet, the sibling discount and
-- fn_apply_family_credit with nothing to act on.
--
-- ONLY THE OPENING ROLL IS HERE. The school bought the software in February
-- 2024 with about 120 children already enrolled, and those are the ones this
-- file admits. Every later arrival comes through 04_the_years.sql as an
-- enquiry that was followed up and converted, in the session it belongs to,
-- because that is the only order in which the chronology can be true: a child
-- admitted into 2025-2026 cannot exist before the rollover that created that
-- year's roll.
--
-- SIBLINGS ARE DELIBERATE AND CLUSTERED. Roughly one child in four shares a
-- father CNIC with another, which is what a Pakistani private school actually
-- looks like, and it is the difference between a family sheet with one line on
-- it and one worth printing.
--
-- Run: psql -v ON_ERROR_STOP=1 -f supabase/sim/03_students.sql
-- =============================================================================



select set_config('request.jwt.claims',
  jsonb_build_object('sub', p.id::text, 'role','authenticated')::text, true)
from public.profiles p join public.schools s on s.id = p.school_id
where s.name = current_setting('sim.school')
  and p.role = 'owner' and p.active limit 1;
set local role authenticated;

-- --- Name pools ---------------------------------------------------------------
-- Punjabi, Pashto, Sindhi and Muhajir naming patterns mixed, because a roll of
-- thirty Ahmeds is not what a school in Islamabad looks like and a search test
-- against thirty identical names proves nothing about the search.
drop table if exists sim_boy;
create temp table sim_boy(n text) on commit drop;
insert into sim_boy(n) values
 ('Ahmed'),('Hamza'),('Bilal'),('Usman'),('Zain'),('Hassan'),('Hussain'),('Umar'),
 ('Talha'),('Saad'),('Ibrahim'),('Ali'),('Abdullah'),('Ayan'),('Rayyan'),('Arham'),
 ('Shahzaib'),('Faizan'),('Danish'),('Salman'),('Adnan'),('Waleed'),('Zohaib'),
 ('Noman'),('Kashif'),('Junaid'),('Asad'),('Fahad'),('Rehan'),('Sufyan'),
 ('Mudassir'),('Waqas'),('Shoaib'),('Imran'),('Naveed'),('Tariq'),('Yasir');
drop table if exists sim_girl;
create temp table sim_girl(n text) on commit drop;
insert into sim_girl(n) values
 ('Ayesha'),('Fatima'),('Maryam'),('Zainab'),('Khadija'),('Hafsa'),('Amna'),
 ('Iqra'),('Sana'),('Hira'),('Rabia'),('Nimra'),('Areeba'),('Laiba'),('Eman'),
 ('Aleena'),('Zoya'),('Mahnoor'),('Anaya'),('Iman'),('Alishba'),('Kinza'),
 ('Mehak'),('Sidra'),('Tayyaba'),('Warda'),('Nida'),('Saba'),('Bushra'),
 ('Shanzay'),('Minahil'),('Umaima'),('Hoorain');
drop table if exists sim_fam;
create temp table sim_fam(n text) on commit drop;
insert into sim_fam(n) values
 ('Chaudhary'),('Malik'),('Khan'),('Butt'),('Awan'),('Gujjar'),('Rajput'),
 ('Qureshi'),('Sheikh'),('Mughal'),('Abbasi'),('Satti'),('Janjua'),('Kiyani'),
 ('Bhatti'),('Cheema'),('Sandhu'),('Warraich'),('Dar'),('Mir'),('Baig'),
 ('Durrani'),('Yousafzai'),('Afridi'),('Shinwari'),('Soomro'),('Jatoi'),
 ('Memon'),('Ansari'),('Siddiqui'),('Farooqi'),('Zaidi'),('Naqvi'),('Rizvi');
drop table if exists sim_dad;
create temp table sim_dad(n text) on commit drop;
insert into sim_dad(n) values
 ('Muhammad Aslam'),('Abdul Rehman'),('Ghulam Nabi'),('Muhammad Akram'),
 ('Zafar Iqbal'),('Nasir Mahmood'),('Shahid Anwar'),('Riaz Ahmed'),
 ('Tanveer Abbas'),('Mushtaq Ali'),('Sajjad Haider'),('Khalid Pervaiz'),
 ('Muhammad Yousaf'),('Rashid Minhas'),('Amjad Hussain'),('Liaqat Ali'),
 ('Muhammad Shafiq'),('Ijaz Ahmad'),('Sabir Hussain'),('Manzoor Elahi'),
 ('Sarfraz Khan'),('Iftikhar Ahmed'),('Tahir Mehmood'),('Javed Iqbal'),
 ('Muhammad Naeem'),('Asghar Ali'),('Zulfiqar Ahmed'),('Noor Muhammad'),
 ('Muhammad Ramzan'),('Allah Yar'),('Bashir Ahmad'),('Sultan Mehmood');
drop table if exists sim_mum;
create temp table sim_mum(n text) on commit drop;
insert into sim_mum(n) values
 ('Naseem Akhtar'),('Parveen Bibi'),('Shamim Akhtar'),('Razia Sultana'),
 ('Nasreen Begum'),('Zubaida Khatoon'),('Rukhsana Kausar'),('Shahnaz Bibi'),
 ('Tahira Bano'),('Farzana Kausar'),('Rehana Kausar'),('Sajida Parveen'),
 ('Kaneez Fatima'),('Surraya Begum'),('Iqbal Bano'),('Zarina Bibi');

-- --- The admissions ------------------------------------------------------------
do $sim$
declare
  v_school uuid := public.current_school_id();
  v_sess_2324 uuid; v_sess_2425 uuid; v_sess_2526 uuid; v_sess_2627 uuid;
  v_i int; v_boy boolean; v_first text; v_fam text; v_dad text; v_mum text;
  v_lvl int; v_class uuid; v_section uuid; v_sess uuid;
  v_admit date; v_dob date; v_cnic text; v_phone text;
  v_sib int; v_cnic_pool text[]; v_res jsonb;
  v_nboy int; v_ngirl int; v_nfam int; v_ndad int; v_nmum int;
  v_made int := 0;
begin
  if v_school is null then raise exception 'No owner session.'; end if;
  if exists (select 1 from public.students where school_id = v_school) then
    raise notice 'students already present (%), nothing to do',
      (select count(*) from public.students where school_id = v_school);
    return;
  end if;

  select id into v_sess_2324 from public.academic_sessions where school_id=v_school and name='2023-2024';
  select id into v_sess_2425 from public.academic_sessions where school_id=v_school and name='2024-2025';
  select id into v_sess_2526 from public.academic_sessions where school_id=v_school and name='2025-2026';
  select id into v_sess_2627 from public.academic_sessions where school_id=v_school and name='2026-2027';

  select count(*) into v_nboy  from sim_boy;
  select count(*) into v_ngirl from sim_girl;
  select count(*) into v_nfam  from sim_fam;
  select count(*) into v_ndad  from sim_dad;
  select count(*) into v_nmum  from sim_mum;

  -- A HUNDRED AND NINETY CNICs, SHARED ACROSS THE WHOLE TWO YEARS, and the
  -- arithmetic matters.
  -- Reusing a father's CNIC is the only thing that makes fn_admit_student put
  -- two children in one family (migration 0036), so the sibling rate is set
  -- here and nowhere else.
  -- The first draft used a pool of 80 for 260 children and produced 80 families
  -- of 3.25 each: every single family had siblings, which exercises the family
  -- model hard and is not what a school looks like. A pool of 190 across the
  -- full intake gives ~190 families of which ~70 gain a second child, an
  -- average of 1.37, which is about right for a Pakistani private school and
  -- still leaves plenty of family sheets worth printing. The later years draw
  -- from the same pool, so a sibling pair can be admitted two years apart:
  -- that is the case which catches a family query assuming one enrollment.
  select array_agg('61101-' || lpad((3000000 + g)::text, 7, '0') || '-' ||
                   ((g % 9) + 1)::text)
    into v_cnic_pool
    from generate_series(1, 190) g;

  for v_i in 1..120 loop
    v_boy   := (v_i % 100) < 54;               -- 54% boys, roughly national
    v_first := case when v_boy
      then (select n from sim_boy  offset ((v_i * 7) % v_nboy)  limit 1)
      else (select n from sim_girl offset ((v_i * 11) % v_ngirl) limit 1) end;
    -- The opening roll takes CNICs 1..120 from the pool. 04_the_years.sql
    -- continues at 121 and then deliberately reuses 1..70 for second children.
    v_sib   := v_i;
    v_fam   := (select n from sim_fam offset ((v_sib * 5) % v_nfam) limit 1);
    v_dad   := (select n from sim_dad offset ((v_sib * 3) % v_ndad) limit 1);
    v_mum   := (select n from sim_mum offset ((v_sib * 13) % v_nmum) limit 1);
    v_cnic  := v_cnic_pool[v_sib];
    v_phone := '03' || lpad(((v_sib * 1234567) % 100000000)::text, 9, '0');

    -- WHEN each child arrives, and this is the whole chronology.
    --   1..120  : already on the roll when the school bought the software
    --   121..165: admitted during 2024-2025
    --   166..215: during 2025-2026
    --   216..260: during 2026-2027, up to today
    -- These children were admitted between 2019 and early 2024: they were
    -- already at the school when it started paying us. Their admission dates
    -- are historical and their enrollment is in the 2023-2024 session, which
    -- is the year in progress in February 2024.
    v_admit := date '2019-04-01' + ((v_i * 37) % 1750);
    v_sess  := v_sess_2324;
    v_lvl   := ((v_i * 5) % 12) + 1;
    select id into v_class from public.classes
     where school_id = v_school and level_order = v_lvl;
    select id into v_section from public.sections
     where class_id = v_class order by sort_order
     offset (v_i % (select count(*) from public.sections where class_id = v_class)) limit 1;

    -- Age that matches the class, so the Birthdays screen and any age report
    -- have something coherent to show.
    v_dob := (date_trunc('year', v_admit)::date - ((v_lvl + 3) * 365))
             + ((v_i * 29) % 365);

    v_res := public.fn_admit_student(jsonb_build_object(
      'full_name',      v_first || ' ' || v_fam,
      'father_name',    v_dad,
      'mother_name',    v_mum,
      'father_cnic',    v_cnic,
      'b_form',         '61101-' || lpad((7000000 + v_i)::text, 7, '0') || '-' || ((v_i % 9) + 1)::text,
      'dob',            v_dob,
      'gender',         case when v_boy then 'male' else 'female' end,
      'address',        'House ' || (10 + (v_i % 300))::text || ', Street ' ||
                        (1 + (v_i % 24))::text || ', Ghauri Town Phase ' ||
                        (1 + (v_i % 5))::text || ', Islamabad',
      'phone',          v_phone,
      'whatsapp',       v_phone,
      'admission_date', v_admit,
      'session_id',     v_sess,
      'class_id',       v_class,
      'section_id',     v_section,
      -- The admission fee is charged for most, waived for a handful. A school
      -- where every single admission fee was charged never exercises the
      -- "charged: false" branch or the discount report.
      'admission_fee',  jsonb_build_object('charged', (v_i % 11) <> 0)
    ));
    v_made := v_made + 1;
  end loop;

  raise notice 'opening roll admitted=%  students=%  families=%  enrollments=%',
    v_made,
    (select count(*) from public.students where school_id = v_school),
    (select count(*) from public.families where school_id = v_school),
    (select count(*) from public.enrollments where school_id = v_school);
  raise notice 'families with more than one child = %',
    (select count(*) from (select family_id from public.students
                            where school_id = v_school and family_id is not null
                            group by family_id having count(*) > 1) q);
end
$sim$;


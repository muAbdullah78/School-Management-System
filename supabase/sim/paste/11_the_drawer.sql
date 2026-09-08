-- =============================================================================
-- GENERATED FILE. DO NOT EDIT except for the one line marked below.
-- Built from supabase/sim/ by scripts/build-sim-bundle.py
--
-- TWO YEARS OF ONE SCHOOL'S USE. FILE 11 OF 13: the drawer
--
-- Guardians, the cash drawer counted daily, payment reversals, adjustments, voids, defers, deposit refunds, and the outbox worked down to a realistic backlog. Seconds.
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
--   3. It creates NO logins. See the note at the end of file 13.
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
-- 07_drawer_guardians_outbox.sql
-- ------------------------------------------------------------------------
reset role;
-- =============================================================================
-- SIMULATION, PART 7: the cash drawer, the guardians, and draining the outbox.
--
-- THREE THINGS THE FIRST SIX PARTS LEFT AT ZERO, and each of them turned out to
-- be worth a note of its own.
--
-- 1. THE DRAWER. fn__ensure_till() opens a till automatically the first time a
--    cash payment is taken and nothing ever closes it. So after two years of
--    collection this school had exactly ONE till session, still open, holding
--    2,236 cash payments. That is a true picture of a school that never uses
--    the close-drawer feature, and it means fn_close_till's variance arithmetic
--    had never run. This part opens and closes a drawer for each of the last
--    sixty school days, with real top-up payments inside it, so the whole
--    open -> collect -> count -> close -> approve cycle is exercised including
--    the days the count does not agree.
--
-- 2. THE GUARDIANS. fn_admit_student accepts a `guardian` object and this
--    simulation never passed one, so `guardians` sat empty through 260
--    admissions. A grandfather or an uncle who collects the child is a normal
--    thing for a Pakistani school to record and the table exists for it.
--
-- 3. THE OUTBOX. Every enquiry, admission and receipt queues a WhatsApp
--    automatically, and 6,176 of them were sitting in `queued` because nothing
--    in the product ever drains the queue by itself. A school that never
--    presses Send accumulates them for ever. This part sends most, skips some
--    with a reason, and deliberately leaves the recent ones queued, because
--    that is what an outbox looks like on any given afternoon.
--
-- Run: psql -v ON_ERROR_STOP=1 -f supabase/sim/07_drawer_guardians_outbox.sql
-- =============================================================================



select set_config('request.jwt.claims',
  jsonb_build_object('sub', p.id::text, 'role','authenticated')::text, true)
from public.profiles p join public.schools s on s.id = p.school_id
where s.name = current_setting('sim.school')
  and p.role = 'owner' and p.active limit 1;
set local role authenticated;

-- --- 1. Guardians -------------------------------------------------------------
do $sim$
declare
  v_school uuid := public.current_school_id();
  r record; v_n int := 0;
begin
  if v_school is null then raise exception 'No owner session.'; end if;

  for r in
    select st.id, st.father_name, st.phone,
           row_number() over (order by st.id) as k
      from public.students st
     where st.school_id = v_school
       and not exists (select 1 from public.guardians g where g.student_id = st.id)
  loop
    -- The father is the primary guardian on every child, which is what the
    -- admission form records.
    insert into public.guardians (student_id, name, relation, phone, whatsapp, is_primary)
    values (r.id, r.father_name, 'Father', r.phone, r.phone, true);
    v_n := v_n + 1;

    -- About one child in five has a second person named: the grandfather, an
    -- uncle, or an elder brother who does the school run. A single-guardian
    -- table never exercises is_primary at all.
    if (r.k % 5) = 0 then
      insert into public.guardians (student_id, name, relation, phone, whatsapp, is_primary)
      values (r.id,
              (array['Muhammad Siddique','Abdul Ghafoor','Haji Nazir Ahmed',
                     'Ch. Muhammad Ashraf','Mian Abdul Sattar'])[((r.k / 5) % 5) + 1],
              (array['Grandfather','Uncle','Elder brother','Guardian','Grandfather'])[((r.k / 5) % 5) + 1],
              '0300' || lpad(((r.k * 313) % 10000000)::text, 7, '0'),
              '0300' || lpad(((r.k * 313) % 10000000)::text, 7, '0'),
              false);
      v_n := v_n + 1;
    end if;
  end loop;
  raise notice 'guardians=% (primary=%)', v_n,
    (select count(*) from public.guardians g
      join public.students st on st.id = g.student_id
     where st.school_id = v_school and g.is_primary);
end
$sim$;

-- --- 2. The cash drawer, day by day, for the last sixty school days -----------
do $sim$
declare
  v_school uuid := public.current_school_id();
  v_day date; v_till uuid; v_close jsonb; r record;
  v_taken numeric; v_counted numeric; v_float numeric;
  v_days int := 0; v_short int := 0; v_over int := 0; v_approved int := 0;
  v_pay jsonb;
begin
  -- Close the drawer that fn__ensure_till opened two years ago and nobody ever
  -- shut. The count is deliberately a little under: two years of a drawer
  -- nobody balanced does not come out to the penny, and a school's first close
  -- is the one that finds that out.
  select id into v_till from public.till_sessions
   where school_id = v_school and status = 'open'
   order by opened_at limit 1;
  if v_till is not null then
    select coalesce(sum(p.amount), 0) into v_taken
      from public.payments p where p.till_session_id = v_till and p.status = 'verified';
    begin
      v_close := public.fn_close_till(round(v_taken * 0.998),
        'First close after two years. Short by the odd note, written off.');
      raise notice 'the long-open drawer closed: expected=% counted=% variance=%',
        v_close->>'expected_cash', v_close->>'counted_cash', v_close->>'variance';
    exception when others then
      raise notice '  could not close the long-open till: %', sqlerrm;
    end;
  end if;

  -- Then a proper daily cycle. Fee collection in a Pakistani school clusters in
  -- the first half of the month, so the top-ups follow that shape.
  for v_day in
    select d::date from generate_series(current_date - 120, current_date, interval '1 day') d
     where extract(dow from d) <> 0
       and not (extract(month from d) in (6, 7))
     order by d
  loop
    v_float := 2000;
    v_till := public.fn_open_till(v_float);
    v_days := v_days + 1;
    v_taken := 0;

    -- Two to five parents come to the counter with a part payment. Real
    -- fn_record_payment calls, so the allocation, the receipt number and the
    -- till binding are all the product's own.
    for r in
      select st.id, st.full_name
        from public.students st
        join public.enrollments e on e.student_id = st.id and e.status = 'active'
       where st.school_id = v_school
         and public.student_balance(st.id) > 500
         and (hashtextextended(st.id::text || v_day::text, 101) % 100 + 100) % 100 < 3
       limit 5
    loop
      begin
        v_pay := public.fn_record_payment(r.id, 1000, 'cash',
                   'Part payment at the counter, ' || to_char(v_day, 'DD Mon'), false);
        v_taken := v_taken + 1000;
      exception when others then
        raise notice '  counter payment refused: %', sqlerrm;
      end;
    end loop;

    -- The count. Most days it agrees. One day in nine it does not, and both
    -- directions happen: a note stuck to another, or change given wrong.
    v_counted := v_float + v_taken;
    -- The direction is taken from the day of the month rather than a second
    -- hash of the same string: the first draft used two hashes of one input,
    -- they turned out correlated, and fifty days produced five overs and not a
    -- single short. A variance test that can only go one way is half a test.
    if (hashtextextended(v_day::text, 202) % 9 + 9) % 9 = 0 then
      if (extract(day from v_day)::int % 2) = 0 then
        v_counted := v_counted - 100; v_short := v_short + 1;
      else
        v_counted := v_counted + 50;  v_over := v_over + 1;
      end if;
    end if;

    begin
      v_close := public.fn_close_till(v_counted,
        case when v_counted <> v_float + v_taken
             then 'Counted twice. Recorded as it was found.' else null end);
      -- The owner approves the day. A drawer closed and never approved is the
      -- state that fn_approve_till exists to clear, so the last few days are
      -- left unapproved on purpose.
      if v_day < current_date - 4 then
        perform public.fn_approve_till((v_close->>'till_id')::uuid);
        v_approved := v_approved + 1;
      end if;
    exception when others then
      raise notice '  could not close the drawer for %: %', v_day, sqlerrm;
    end;
  end loop;

  raise notice 'drawer: % days, % short, % over, % approved (% left for the owner to sign off)',
    v_days, v_short, v_over, v_approved, v_days - v_approved;
end
$sim$;

-- --- 3. Reversals, adjustments, refunds, voids and defers ---------------------
-- The correction paths. A ledger with no reversal in it has never had its
-- reversal read, and every one of these is a thing a real clerk does in the
-- first month: a payment entered against the wrong child, a challan raised for
-- a child who had already left, a family given until the end of the month.
do $sim$
declare
  v_school uuid := public.current_school_id();
  r record; v_n_rev int := 0; v_n_adj int := 0; v_n_void int := 0;
  v_n_defer int := 0; v_n_refund int := 0; v_n_verify int := 0;
begin
  -- A handful of payments reversed: entered against the wrong child.
  for r in
    select p.id from public.payments p
     where p.school_id = v_school and p.status = 'verified' and p.reversal_of is null
       and (hashtextextended(p.id::text, 401) % 1000 + 1000) % 1000 < 4
     limit 12
  loop
    begin
      perform public.fn_reverse_payment(r.id, 'Entered against the wrong child; re-entered correctly');
      v_n_rev := v_n_rev + 1;
    exception when others then raise notice '  reversal refused: %', sqlerrm; end;
  end loop;

  -- The pending online payments a clerk later confirmed against the bank app.
  for r in select p.id from public.payments p
            where p.school_id = v_school and p.status = 'pending' limit 40 loop
    begin
      perform public.fn_verify_payment(r.id);
      v_n_verify := v_n_verify + 1;
    exception when others then raise notice '  verify refused: %', sqlerrm; end;
  end loop;

  -- Adjustments: a book returned, a bus month not used, an old balance written
  -- off by the principal.
  for r in
    select st.id, row_number() over (order by st.id) as k
      from public.students st
     where st.school_id = v_school and st.status = 'active'
       and (hashtextextended(st.id::text, 501) % 100 + 100) % 100 < 8
     limit 20
  loop
    begin
      perform public.fn_add_adjustment(r.id,
        case when (r.k % 3) = 0 then -500 else 300 end,
        case when (r.k % 3) = 0 then 'Van not used in Ramzan, credited'
             when (r.k % 3) = 1 then 'Library book lost, charged'
             else 'Old balance corrected after checking the register' end);
      v_n_adj := v_n_adj + 1;
    exception when others then raise notice '  adjustment refused: %', sqlerrm; end;
  end loop;

  -- Challans raised for children who had already left, and voided.
  for r in
    select i.id from public.invoices i
      join public.students st on st.id = i.student_id
     where i.school_id = v_school and st.status <> 'active'
       and i.status in ('issued','partial')
     limit 10
  loop
    begin
      perform public.fn_void_invoice(r.id, 'Child had already left; challan raised in error');
      v_n_void := v_n_void + 1;
    exception when others then raise notice '  void refused: %', sqlerrm; end;
  end loop;

  -- And a few families given until the end of the month.
  for r in
    select i.id from public.invoices i
     where i.school_id = v_school and i.status in ('issued','partial')
       and i.period_month >= date_trunc('month', current_date) - interval '2 months'
       and i.deferred_until is null
     limit 15
  loop
    begin
      perform public.fn_defer_invoice(r.id, (date_trunc('month', current_date) + interval '1 month - 1 day')::date,
        'Father asked for time until his salary; principal agreed');
      v_n_defer := v_n_defer + 1;
    exception when others then raise notice '  defer refused: %', sqlerrm; end;
  end loop;

  -- Security deposits returned to the children who left.
  for r in
    select st.id from public.students st
     where st.school_id = v_school and st.status <> 'active'
       and public.fn_deposit_held(st.id) > 0
     limit 12
  loop
    begin
      perform public.fn_refund_deposit(r.id, null, true, 'cash',
        'Security deposit returned at leaving, net of what was owed');
      v_n_refund := v_n_refund + 1;
    exception when others then raise notice '  refund refused: %', sqlerrm; end;
  end loop;

  raise notice 'reversals=% verified=% adjustments=% voided=% deferred=% deposit refunds=%',
    v_n_rev, v_n_verify, v_n_adj, v_n_void, v_n_defer, v_n_refund;
end
$sim$;

-- --- 4. Draining the outbox ---------------------------------------------------
do $sim$
declare
  v_school uuid := public.current_school_id();
  r record; v_sent int := 0; v_skipped int := 0; v_total bigint;
begin
  select count(*) into v_total from public.message_outbox
   where school_id = v_school and status = 'queued';
  for r in
    select m.id, m.created_at,
           row_number() over (order by m.created_at) as k
      from public.message_outbox m
     where m.school_id = v_school and m.status = 'queued'
     order by m.created_at
  loop
    -- A backlog is left behind on purpose: that is what the WhatsApp screen
    -- looks like when somebody logs in this afternoon.
    --
    -- BY POSITION AND NOT BY DATE, and that is not laziness. Every row in this
    -- outbox was queued by a function during the seed, so they all carry the
    -- same created_at down to the second; 08_the_clock.sql is what gives them
    -- their real dates, and it runs after this. The first draft read created_at
    -- and exited on the very first row, draining nothing and reporting
    -- "sent=0 skipped=0" as though it had worked.
    exit when r.k > (v_total * 88) / 100;
    if (r.k % 11) = 0 then
      perform public.fn_skip_message(r.id,
        case when (r.k % 33) = 0 then 'No WhatsApp on this number'
             when (r.k % 22) = 0 then 'Father asked us not to message'
             else 'Spoke to them on the phone instead' end);
      v_skipped := v_skipped + 1;
    else
      perform public.fn_mark_message_sent(r.id, 'whatsapp');
      v_sent := v_sent + 1;
    end if;
  end loop;
  raise notice 'outbox: sent=% skipped=% still queued=%', v_sent, v_skipped,
    (select count(*) from public.message_outbox where school_id = v_school and status = 'queued');
end
$sim$;


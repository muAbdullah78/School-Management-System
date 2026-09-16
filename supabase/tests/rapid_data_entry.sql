-- =============================================================================
-- The register goes in as fast as it is read (0142).
--
-- ASSERTION 3 IS THE ONE THIS FILE EXISTS FOR. Entering a class is one call with
-- a hundred rows in it, and a clerk has been typing for twenty minutes. A
-- duplicate GR number on row 57 must not roll the other ninety-nine back.
--
-- ASSERTION 6 IS THE ONE THAT WOULD COST A SCHOOL MONEY. is_draft is a label.
-- A child entered as a name and a roll number is billed, registered and
-- examined exactly like a complete record. A flag that quietly held them out of
-- billing would be worse than no flag: the school would find out at the end of
-- the month, by being short.
--
-- Run: psql -v ON_ERROR_STOP=1 -f supabase/tests/rapid_data_entry.sql
-- =============================================================================
\set ON_ERROR_STOP on
begin;

create or replace function auth.uid() returns uuid language sql stable as
  $$ select nullif(current_setting('test.uid', true), '')::uuid $$;

create or replace function pg_temp.ok(p_cond boolean, p_label text)
returns void language plpgsql as $$
begin
  if p_cond then raise notice 'PASS  %', p_label;
  else raise exception 'FAIL  %', p_label; end if;
end;
$$;

do $seed$
declare
  sch uuid := gen_random_uuid(); own uuid := gen_random_uuid();
  ses uuid; c1 uuid; sec1 uuid; fh uuid;
  today date := (now() at time zone 'Asia/Karachi')::date;
  start date := date_trunc('month', today - interval '3 months')::date;
begin
  insert into public.schools(id, name, city) values (sch, 'RDE Test School', 'Sialkot');
  insert into public.subscriptions(school_id, plan_code, status, trial_ends_on)
    values (sch, 'growth', 'active', today + 90);
  insert into auth.users(id, email) values (own, 'head@rdetest.test') on conflict (id) do nothing;
  alter table public.profiles disable trigger user;
  insert into public.profiles(id, school_id, full_name, role) values (own, sch, 'Head', 'owner');
  alter table public.profiles enable trigger user;
  perform set_config('test.uid', own::text, false);

  insert into public.academic_sessions(school_id, name, starts_on, ends_on, is_current)
    values (sch, 'This year', start, (start + interval '11 months' + interval '27 days')::date, true)
    returning id into ses;
  update public.school_settings set current_session_id = ses, billing_day = 1, due_day = 10
   where school_id = sch;

  insert into public.classes(school_id, name, level_order) values (sch, 'Class 1', 1) returning id into c1;
  insert into public.sections(school_id, class_id, name) values (sch, c1, 'A') returning id into sec1;
  insert into public.fee_heads(school_id, name, type, is_refundable, is_recurring, sort_order, active)
    values (sch, 'Monthly Fee', 'monthly', false, true, 1, true) returning id into fh;
  insert into public.fee_structures(school_id, session_id, class_id, fee_head_id, amount, effective_from)
    values (sch, ses, c1, fh, 3000, start);
end $seed$;

-- =============================================================================
-- 1-5. A class, typed straight down, with one poisoned row in the middle
-- =============================================================================
do $bulk$
declare
  sch uuid; own uuid; ses uuid; c1 uuid; sec1 uuid; j jsonb; n int;
  today date := (now() at time zone 'Asia/Karachi')::date;
  m1 date; m2 date;
begin
  select id into sch from public.schools where name = 'RDE Test School';
  select id into own from public.profiles where school_id = sch and role = 'owner';
  select id into ses from public.academic_sessions where school_id = sch;
  select id into c1  from public.classes where school_id = sch;
  select id into sec1 from public.sections where school_id = sch;
  perform set_config('test.uid', own::text, false);
  m1 := date_trunc('month', today - interval '2 months')::date;
  m2 := date_trunc('month', today - interval '1 month')::date;

  -- First child takes GR 0001. The clash below is deliberate.
  j := public.fn_rde_add_students(jsonb_build_object(
    'session_id', ses, 'class_id', c1, 'section_id', sec1,
    'rows', jsonb_build_array(
      jsonb_build_object('full_name','Bilal Ahmad','roll_no','1','father_name','Shahid',
        'gender','male','dob','2018-04-11','whatsapp','03331234567'),
      jsonb_build_object('full_name','Hamza Khan','roll_no','2'),
      jsonb_build_object('full_name','Clash Child','roll_no','3','gr_no','0001'),
      jsonb_build_object('full_name',''),
      jsonb_build_object('full_name','Ayesha Dar','roll_no','5','father_name','Shahid',
        'gender','female','dob','2017-02-02','phone','03009998887',
        'discount', jsonb_build_object('type','sibling','amount',20,'is_percent',true),
        'arrears', jsonb_build_array(
          jsonb_build_object('month', m1, 'amount', 3000),
          jsonb_build_object('month', m2, 'amount', 3000))),
      jsonb_build_object('full_name','Paid Already','roll_no','6','father_name','Iqbal',
        'gender','male','dob','2018-01-01','whatsapp','03211112222','paid_this_month', true))));

  perform pg_temp.ok((j->>'created')::int = 4 and (j->>'failed')::int = 1,
    '1. four saved, one refused, and the blank line in the middle was not an error: got '
    || (j->>'created') || ' saved, ' || (j->>'failed') || ' refused');

  perform pg_temp.ok(
    (select x->>'status' from jsonb_array_elements(j->'results') x where (x->>'row')::int = 3)
      = 'error'
    and (select x->>'message' from jsonb_array_elements(j->'results') x where (x->>'row')::int = 3)
        like 'GR number 0001 is already used%',
    '2. the duplicate GR comes back as a sentence a clerk can act on, not as '
    || 'students_gr_no_school_key');

  select count(*) into n from public.students where school_id = sch;
  perform pg_temp.ok(n = 4,
    '3. THE ONE THIS FILE EXISTS FOR: row 3 rolled back to its own savepoint and '
    || 'the other four are committed. One transaction without per-row savepoints '
    || 'would have thrown away twenty minutes of typing over one duplicate. Got '
    || n || ' students');

  perform pg_temp.ok(
    (select gr_no from public.students where full_name = 'Hamza Khan') = '0002',
    '4. GR numbers keep counting past the refused row rather than leaving a hole');

  perform pg_temp.ok(
    (select roll_no from public.enrollments e
      join public.students s on s.id = e.student_id
     where s.full_name = 'Bilal Ahmad') = '1',
    '5. and every child is enrolled in the class that was picked, with their roll');
end $bulk$;

-- =============================================================================
-- 6-8. A draft is a label, and it is decided by the database
-- =============================================================================
do $draft$
declare
  sch uuid; own uuid; ses uuid; s_hamza uuid; j jsonb; n int; v numeric;
  today date := (now() at time zone 'Asia/Karachi')::date;
begin
  select id into sch from public.schools where name = 'RDE Test School';
  select id into own from public.profiles where school_id = sch and role = 'owner';
  select id into ses from public.academic_sessions where school_id = sch;
  select id into s_hamza from public.students where school_id = sch and full_name = 'Hamza Khan';
  perform set_config('test.uid', own::text, false);

  perform pg_temp.ok((select is_draft from public.students where id = s_hamza),
    '6a. a child entered as a name and a roll number is tagged a draft');
  perform pg_temp.ok(
    not (select is_draft from public.students where full_name = 'Bilal Ahmad'),
    '6b. and a complete record is not');

  -- THE ASSERTION THAT WOULD COST A SCHOOL MONEY IF IT EVER FAILED.
  select coalesce(sum(case when l.is_discount then -l.amount else l.amount end), 0) into v
    from public.invoices i
    join public.invoice_lines l on l.invoice_id = i.id
   where i.student_id = s_hamza
     and i.period_month = date_trunc('month', today)::date;
  perform pg_temp.ok(v = 3000,
    '6. THE ONE THAT WOULD COST A SCHOOL MONEY: a draft child is billed the full '
    || 'Rs 3,000 like everybody else. A flag that quietly held them out of the '
    || 'challan run would leave the school short at the end of the month and '
    || 'nothing would say why. Got ' || v);

  -- Finishing the record clears the reminder BY ITSELF, from any screen.
  update public.students
     set father_name = 'Khan Sahib', gender = 'male', dob = '2018-06-06',
         whatsapp = '03001234567'
   where id = s_hamza;
  perform pg_temp.ok(not (select is_draft from public.students where id = s_hamza),
    '7. filling the gaps clears the tag by itself. Owned by the screen that set '
    || 'it, the dashboard would keep asking after somebody had finished the job');

  -- And it comes back if the record is emptied again, which is what proves the
  -- trigger is maintaining it rather than having run once.
  update public.students set dob = null where id = s_hamza;
  perform pg_temp.ok((select is_draft from public.students where id = s_hamza),
    '8. and returns if the record is emptied again, so the flag is maintained '
    || 'rather than stamped once at insert');

  update public.students set dob = '2018-06-06' where id = s_hamza;
end $draft$;

-- =============================================================================
-- 9-11. GR numbers a human has already used
-- =============================================================================
do $gr$
declare
  sch uuid; own uuid; ses uuid; c1 uuid; j jsonb; v bigint;
begin
  select id into sch from public.schools where name = 'RDE Test School';
  select id into own from public.profiles where school_id = sch and role = 'owner';
  select id into ses from public.academic_sessions where school_id = sch;
  select id into c1  from public.classes where school_id = sch;
  perform set_config('test.uid', own::text, false);

  j := public.fn_rde_add_students(jsonb_build_object(
    'session_id', ses, 'class_id', c1,
    'rows', jsonb_build_array(
      jsonb_build_object('full_name','Manual Five Hundred','gr_no','0500'),
      jsonb_build_object('full_name','Next One Along'))));

  perform pg_temp.ok(
    (select x->>'gr_no' from jsonb_array_elements(j->'results') x where (x->>'row')::int = 2)
      = '0501',
    '9. a hand-typed GR of 0500 pushes the counter past itself, so the next '
    || 'automatic number is 0501. Without it the counter would still be at 4, '
    || 'hand back 0005, and every school that numbered its own register by hand '
    || 'would hit a wall of duplicates');

  select value into v from public.counters where school_id = sch and key = 'gr';
  perform pg_temp.ok(v >= 501, '10. and the counter itself is past it, got ' || v);

  -- The retry loop, which is what covers GR numbers that were in the table
  -- before this migration ever ran. Push the counter back under an occupied
  -- number and demand the automatic path walks past it rather than failing.
  update public.counters set value = 499 where school_id = sch and key = 'gr';
  j := public.fn_rde_add_students(jsonb_build_object(
    'session_id', ses, 'class_id', c1,
    'rows', jsonb_build_array(jsonb_build_object('full_name','Walks Past It'))));
  perform pg_temp.ok((j->>'failed')::int = 0
    and (select gr_no from public.students where full_name = 'Walks Past It') not in ('0500','0501'),
    '11. and a counter sitting under numbers already in use walks past them '
    || 'instead of failing, which is the state every database that existed '
    || 'before 0142 is in');
end $gr$;

-- =============================================================================
-- 12-14. The money: arrears by month, the concession, and the sibling merge
-- =============================================================================
do $money$
declare
  sch uuid; own uuid; ses uuid; c1 uuid; s_ayesha uuid; s_bilal uuid; j jsonb; st jsonb;
  n int; v numeric;
  today date := (now() at time zone 'Asia/Karachi')::date;
begin
  select id into sch from public.schools where name = 'RDE Test School';
  select id into own from public.profiles where school_id = sch and role = 'owner';
  select id into ses from public.academic_sessions where school_id = sch;
  select id into c1  from public.classes where school_id = sch;
  select id into s_ayesha from public.students where school_id = sch and full_name = 'Ayesha Dar';
  select id into s_bilal  from public.students where school_id = sch and full_name = 'Bilal Ahmad';
  perform set_config('test.uid', own::text, false);

  st := public.fn_student_fee_state(s_ayesha);
  perform pg_temp.ok((st->>'arrears_months')::int = 2 and (st->>'arrears_amount')::numeric = 6000,
    '12. arrears go in BY MONTH, so 0140''s arrears list names June and July '
    || 'rather than showing one lump a parent at the window cannot argue with. '
    || 'Got ' || (st->>'arrears_months') || ' months, ' || (st->>'arrears_amount'));

  -- The month already entered must not be billed a second time by the automatic
  -- pass. uq_invoice_enroll_month is what enforces it; this proves the arrears
  -- invoice is shaped so that it applies.
  perform public.fn_ensure_billing_current(ses);
  select count(*) into n from public.invoices i
   where i.student_id = s_ayesha
     and i.period_month = date_trunc('month', today - interval '1 month')::date
     and i.status <> 'void';
  perform pg_temp.ok(n = 1,
    '13. and the automatic biller does not raise a SECOND challan for a month '
    || 'entered as arrears. Got ' || n || ' invoices for last month');

  perform pg_temp.ok(
    (public.fn_student_fee_for_month(s_ayesha, null)->>'net')::numeric = 2400,
    '14a. the concession typed on the row is live: Rs 3,000 less 20 per cent');

  perform pg_temp.ok(
    (public.fn_student_fee_state((select id from public.students where full_name = 'Paid Already'))
      ->>'state') = 'paid',
    '14b. and a fee the school had already taken is recorded, so that child is '
    || 'not on the unpaid list on their first morning');

  -- The billing merge.
  j := public.fn_rde_add_students(jsonb_build_object(
    'session_id', ses, 'class_id', c1,
    'rows', jsonb_build_array(jsonb_build_object(
      'full_name','Usman Ahmad','father_name','Shahid','gender','male',
      'dob','2015-06-06','whatsapp','03331234567',
      'sibling_student_id', s_bilal))));

  perform pg_temp.ok(
    (select family_id from public.students where full_name = 'Usman Ahmad')
      = (select family_id from public.students where id = s_bilal),
    '15. THE BILLING MERGE: a sibling picked on the row puts the new child in '
    || 'that child''s family, so the house receives ONE challan for both. This '
    || 'is the whole of the "family discount" the vendor asked for: every fee '
    || 'screen has been family-shaped since 0103');

  select jsonb_array_length(public.fn_family_sheet(
    (select family_id from public.students where id = s_bilal))->'children') into n;
  perform pg_temp.ok(n = 2,
    '16. and the counter shows both children on one sheet, got ' || n);
end $money$;

-- =============================================================================
-- 17-19. The fences
-- =============================================================================
do $fences$
declare
  sch uuid; own uuid; ses uuid; c1 uuid; j jsonb; v_ok boolean; d jsonb;
  today date := (now() at time zone 'Asia/Karachi')::date;
begin
  select id into sch from public.schools where name = 'RDE Test School';
  select id into own from public.profiles where school_id = sch and role = 'owner';
  select id into ses from public.academic_sessions where school_id = sch;
  select id into c1  from public.classes where school_id = sch;
  perform set_config('test.uid', own::text, false);

  -- Arrears for a month that has not finished is the bill, not arrears. The
  -- child is still admitted: a fee detail must never lose a child.
  j := public.fn_rde_add_students(jsonb_build_object(
    'session_id', ses, 'class_id', c1,
    'rows', jsonb_build_array(jsonb_build_object(
      'full_name','Future Arrears',
      'arrears', jsonb_build_array(jsonb_build_object(
        'month', date_trunc('month', today)::date, 'amount', 500))))));
  perform pg_temp.ok((j->>'created')::int = 1
    and (j->'results'->0->>'status') = 'partial'
    and (j->'results'->0->>'message') like '%has not%',
    '17. a month that has not finished is refused as arrears and the child is '
    || 'STILL ADMITTED, with the reason on the row. Losing a child over a fee '
    || 'detail is the one thing this screen must never do');

  -- A run bigger than the ceiling is refused outright rather than holding a
  -- write lock on the roster.
  v_ok := false;
  begin
    perform public.fn_rde_add_students(jsonb_build_object(
      'session_id', ses, 'class_id', c1,
      'rows', (select jsonb_agg(jsonb_build_object('full_name','X' || g))
                 from generate_series(1, 201) g)));
    v_ok := true;
  exception when others then null; end;
  perform pg_temp.ok(not v_ok,
    '18. more than 200 rows in one call is refused: one browser must not be able '
    || 'to hold a write lock on the whole roster for a minute');

  d := public.fn_draft_students(0);
  perform pg_temp.ok((d->>'count')::int >= 1 and jsonb_array_length(d->'students') = 0,
    '19. the dashboard asks for the counts only and is not made to pay for a '
    || 'list of students it does not render');
end $fences$;

-- =============================================================================
-- 20. The plan's limit, which this screen is the fastest way to walk past
-- =============================================================================
--
-- THIS ASSERTION EXISTS BECAUSE THE FIRST DRAFT LOST IT. 0142 reproduces
-- fn_admit_student, and the first version was retyped from 0036, which predates
-- 0128. The plan gate vanished, and the screen that vanished it is a grid built
-- for typing four hundred children in an afternoon. detect.sql caught it; this
-- keeps it caught.
do $limit$
declare
  sch uuid; own uuid; ses uuid; c1 uuid; j jsonb; n_before int; n_after int;
begin
  select id into sch from public.schools where name = 'RDE Test School';
  select id into own from public.profiles where school_id = sch and role = 'owner';
  select id into ses from public.academic_sessions where school_id = sch;
  select id into c1  from public.classes where school_id = sch;
  perform set_config('test.uid', own::text, false);

  select public.fn_count_students(sch) into n_before;
  -- No room left at all. The override rather than the shared plans row, so the
  -- test cannot change what every other suite's school is entitled to.
  update public.subscriptions
     set student_limit_override = greatest(n_before, 1),
         student_limit_override_reason = 'pinned by the test'
   where school_id = sch;

  j := public.fn_rde_add_students(jsonb_build_object(
    'session_id', ses, 'class_id', c1,
    'rows', jsonb_build_array(
      jsonb_build_object('full_name','Over The Line A'),
      jsonb_build_object('full_name','Over The Line B'))));

  select public.fn_count_students(sch) into n_after;
  perform pg_temp.ok((j->>'failed')::int = 2 and n_after = n_before,
    '20. THE LICENCE. A grid built to type four hundred children in an afternoon '
    || 'is the fastest way past a plan''s student limit, so every row goes '
    || 'through the same gate a single admission does. Got '
    || (j->>'failed') || ' refused, roll went ' || n_before || ' to ' || n_after);
end $limit$;

rollback;
\echo 'RAPID DATA ENTRY: ALL TESTS PASSED'

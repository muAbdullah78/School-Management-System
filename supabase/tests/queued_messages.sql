-- =============================================================================
-- The two WhatsApp messages nothing used to send
--
-- THE DEFECT THIS FILE EXISTS FOR. `absent_today` and `result_published` were
-- seeded into every school, listed in Settings → Messages with their merge tags
-- and an Enabled toggle, and queued by NOTHING. Asked directly, the function
-- that DEFINES them was the only function in the database that mentioned them.
-- A school would write the wording it wanted, switch it on, and no parent would
-- ever receive one — no error, no empty state, nothing to notice.
--
-- The rules defended here:
--
--   1. Finalising a register queues one message per ABSENT child.
--   2. It names THAT CHILD, not every child in the family. fn_queue_message
--      fills {children} with the whole family, which is right for a fee
--      reminder to a payer and absurd for an absence.
--   3. It carries the ATTENDANCE date, not today — a register finalised on
--      Monday for Friday must not say "absent today".
--   4. `leave`, `half_day` and `present` are not messaged.
--   5. Finalising twice does not message twice, and the guard is a unique index
--      rather than a "was anything sent today" heuristic, which breaks on a
--      register finalised three days late.
--   6. A school that switched the message off gets none, and finalising still
--      succeeds.
--   7. Publishing results tells each family, once per term.
--   8. A WITHHELD result is never announced — the portal shows that family
--      "Result withheld until outstanding fees are cleared", so telling them the
--      result can be viewed would be false for exactly the families most likely
--      to go and look.
--   9. Nothing crosses a school boundary.
--
-- Run: psql -v ON_ERROR_STOP=1 -f supabase/tests/queued_messages.sql
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

-- How many queued messages of one kind name this child.
create or replace function pg_temp.msgs(p_key text, p_child text) returns bigint
language sql stable as $$
  select count(*)
  from public.message_outbox o
  join public.students s on s.id = o.student_id
  where o.template_key = p_key and s.full_name = p_child;
$$;

create or replace function pg_temp.body(p_key text, p_child text) returns text
language sql stable as $$
  select o.rendered_text
  from public.message_outbox o
  join public.students s on s.id = o.student_id
  where o.template_key = p_key and s.full_name = p_child
  order by o.created_at desc limit 1;
$$;

-- --- Fixture -----------------------------------------------------------------
-- One class of four, all four in ONE family, which is what makes rule 2 testable:
-- a family message would name all four children in every one of the four
-- messages. Two are absent, one is on leave, one is present.
--
-- The register is marked for THREE DAYS AGO, so rule 3 can tell the attendance
-- date from today.
do $seed$
declare
  v_school uuid;
  v_owner uuid := '00000000-0000-0000-0000-00000000dd01';
  v_sess uuid; v_class uuid; v_sec uuid; v_fam uuid; v_term uuid;
  v_sub uuid; v_es uuid;
  v_names text[] := array['Absent One', 'Absent Two', 'On Leave', 'Present One'];
  v_stat text[]  := array['absent', 'absent', 'leave', 'present'];
  v_stu uuid; v_enr uuid; i int;
  v_marks jsonb := '[]'::jsonb;
  v_day date := current_date - 3;
begin
  perform set_config('test.uid', '', false);
  insert into public.schools (name) values ('Message Test School') returning id into v_school;
  insert into public.subscriptions (school_id, plan_code, status, trial_ends_on)
    values (v_school, 'starter', 'active', current_date + 30);

  alter table public.profiles disable trigger user;
  insert into auth.users (id, email) values (v_owner, 'o@msgs.test') on conflict (id) do nothing;
  insert into public.profiles (id, full_name, role, school_id)
    values (v_owner, 'Msgs Owner', 'owner', v_school)
    on conflict (id) do update set school_id = excluded.school_id, role = excluded.role;
  alter table public.profiles enable trigger user;

  perform set_config('test.uid', v_owner::text, false);
  insert into public.school_settings (school_id, name)
    values (v_school, 'Message Test School') on conflict (school_id) do nothing;
  insert into public.academic_sessions (name, is_current, school_id)
    values ('2025-2026', true, v_school) returning id into v_sess;
  insert into public.classes (name, level_order, school_id)
    values ('Class 3', 3, v_school) returning id into v_class;
  insert into public.sections (class_id, name, school_id)
    values (v_class, 'A', v_school) returning id into v_sec;
  insert into public.exam_terms (school_id, session_id, name)
    values (v_school, v_sess, 'Term 1') returning id into v_term;
  insert into public.subjects (school_id, name) values (v_school, 'English')
    returning id into v_sub;
  insert into public.exam_subjects (school_id, exam_term_id, class_id, subject_id,
                                    max_marks, pass_marks)
    values (v_school, v_term, v_class, v_sub, 100, 33) returning id into v_es;

  -- FOUR SIBLINGS, ONE FAMILY, one WhatsApp number.
  insert into public.families (school_id, head_name, whatsapp)
    values (v_school, 'The Only Payer', '03001234567') returning id into v_fam;

  for i in 1..4 loop
    insert into public.students (full_name, father_name, status, school_id, family_id)
      values (v_names[i], 'The Only Payer', 'active', v_school, v_fam) returning id into v_stu;
    insert into public.enrollments (student_id, session_id, class_id, section_id,
                                    status, school_id)
      values (v_stu, v_sess, v_class, v_sec, 'active', v_school) returning id into v_enr;
    v_marks := v_marks || jsonb_build_object('enrollment_id', v_enr, 'status', v_stat[i]);
    insert into public.mark_entries (school_id, exam_subject_id, enrollment_id,
                                     marks, max_marks)
      values (v_school, v_es, v_enr, 70, 100);
  end loop;

  perform public.fn_mark_attendance(v_day, v_marks, null);

  create table public._qm (k text primary key, v uuid);
  insert into public._qm values ('school', v_school), ('sess', v_sess),
                                ('class', v_class), ('sec', v_sec),
                                ('term', v_term), ('fam', v_fam);
  create table public._qmd (k text primary key, v date);
  insert into public._qmd values ('day', v_day);
  raise notice 'fixture: 4 siblings in 1 family — 2 absent, 1 on leave, 1 present, register for %', v_day;
end $seed$;

-- =============================================================================
-- 1. Finalising the register queues the absences
-- =============================================================================
select pg_temp.ok(
  (select count(*) from public.message_outbox where template_key = 'absent_today') = 0,
  '1. nothing is queued before the register is finalised');

select public.fn_finalize_attendance(
  (select v from public._qm where k = 'sess'),
  (select v from public._qm where k = 'class'),
  (select v from public._qm where k = 'sec'),
  (select v from public._qmd where k = 'day'));

select pg_temp.ok(
  (select count(*) from public.message_outbox where template_key = 'absent_today') = 2,
  '2. finalising queues exactly two — one per ABSENT child, not one per family '
  || 'and not one for the whole class');

select pg_temp.ok(
  pg_temp.msgs('absent_today', 'Absent One') = 1
  and pg_temp.msgs('absent_today', 'Absent Two') = 1,
  '3. and each is attached to the child it is about');

select pg_temp.ok(
  pg_temp.msgs('absent_today', 'On Leave') = 0
  and pg_temp.msgs('absent_today', 'Present One') = 0,
  '4. `leave` and `present` are not messaged — a parent who told the school '
  || 'their child would be away does not need telling back');

-- =============================================================================
-- 2. The two things the obvious wiring would have got wrong
-- =============================================================================
select pg_temp.ok(
  pg_temp.body('absent_today', 'Absent One') like '%Absent One%'
  and pg_temp.body('absent_today', 'Absent One') not like '%Absent Two%'
  and pg_temp.body('absent_today', 'Absent One') not like '%On Leave%'
  and pg_temp.body('absent_today', 'Absent One') not like '%Present One%',
  '5. THE FIRST ONE. {children} is the ONE absent child. fn_queue_message fills '
  || 'it with the whole family, so without the override this family of four '
  || 'would have been told "Absent One, Absent Two, On Leave, Present One was '
  || 'marked absent today"');

select pg_temp.ok(
  pg_temp.body('absent_today', 'Absent One')
    like '%' || to_char((select v from public._qmd where k = 'day'), 'DD Mon YYYY') || '%',
  '6. THE SECOND ONE. The message carries the ATTENDANCE date, three days ago, '
  || 'not today — a register finalised late must not say "absent today" about a '
  || 'day the child was in school');

select pg_temp.ok(
  pg_temp.body('absent_today', 'Absent One') not like '%{%',
  '7. and every merge tag resolved — no parent receives a literal {children}');

-- =============================================================================
-- 3. Finalising twice does not message twice
-- =============================================================================
select public.fn_finalize_attendance(
  (select v from public._qm where k = 'sess'),
  (select v from public._qm where k = 'class'),
  (select v from public._qm where k = 'sec'),
  (select v from public._qmd where k = 'day'));

select pg_temp.ok(
  (select count(*) from public.message_outbox where template_key = 'absent_today') = 2,
  '8. still two after a second finalise — enforced by uq_outbox_ref rather than '
  || 'by a "was anything sent today" guess, which would break on a register '
  || 'finalised three days late (which this one was)');

do $rerun$
declare v_out jsonb;
begin
  v_out := public.fn_queue_absent_today(
    (select v from public._qm where k = 'sess'),
    (select v from public._qm where k = 'class'),
    (select v from public._qm where k = 'sec'),
    (select v from public._qmd where k = 'day'));
  if (v_out->>'queued')::int <> 0 or (v_out->>'already_queued')::int <> 2 then
    raise exception 'FAIL  9. re-running reported %', v_out;
  end if;
  raise notice 'PASS  9. and re-running by hand reports 0 queued / 2 already, so the '
    'office can safely re-run it after correcting a register';
end $rerun$;

-- =============================================================================
-- 4. A school that switched it off gets none, and finalising still works
-- =============================================================================
do $off$
declare v_day date := current_date - 4; v_marks jsonb := '[]'::jsonb; v_n bigint;
begin
  update public.message_templates set enabled = false
   where school_id = (select v from public._qm where k = 'school')
     and template_key = 'absent_today';

  select jsonb_agg(jsonb_build_object('enrollment_id', e.id, 'status', 'absent'))
    into v_marks
  from public.enrollments e
  where e.class_id = (select v from public._qm where k = 'class');
  perform public.fn_mark_attendance(v_day, v_marks, null);
  perform public.fn_finalize_attendance(
    (select v from public._qm where k = 'sess'),
    (select v from public._qm where k = 'class'),
    (select v from public._qm where k = 'sec'), v_day);

  select count(*) into v_n from public.message_outbox where template_key = 'absent_today';
  if v_n <> 2 then
    raise exception 'FAIL  10. a disabled template still queued (% rows)', v_n;
  end if;
  if (select count(*) from public.attendance_daily ad
       join public.enrollments e on e.id = ad.enrollment_id
      where ad.attendance_date = v_day and ad.is_locked
        and e.class_id = (select v from public._qm where k = 'class')) <> 4 then
    raise exception 'FAIL  10. the register did not finalise';
  end if;
  raise notice 'PASS  10. a school that switched the message off gets none — and '
    'the register still finalises, because the lock must never depend on a message';

  update public.message_templates set enabled = true
   where school_id = (select v from public._qm where k = 'school')
     and template_key = 'absent_today';
end $off$;

-- =============================================================================
-- 5. Results published
-- =============================================================================
select public.fn_generate_result_cards(
  (select v from public._qm where k = 'term'),
  (select v from public._qm where k = 'class'), false);

select pg_temp.ok(
  (select count(*) from public.message_outbox where template_key = 'result_published') = 0,
  '11. generating the cards tells nobody — generating is not releasing');

select public.fn_publish_results(
  (select v from public._qm where k = 'term'),
  (select v from public._qm where k = 'class'));

select pg_temp.ok(
  (select count(*) from public.message_outbox where template_key = 'result_published') = 4,
  '12. publishing tells all four families, one message per child');

select pg_temp.ok(
  pg_temp.body('result_published', 'Present One') like '%Present One%'
  and pg_temp.body('result_published', 'Present One') not like '%Absent One%',
  '13. and again it names the one child, not the family');

select public.fn_unpublish_results(
  (select v from public._qm where k = 'term'),
  (select v from public._qm where k = 'class'));
select public.fn_publish_results(
  (select v from public._qm where k = 'term'),
  (select v from public._qm where k = 'class'));

select pg_temp.ok(
  (select count(*) from public.message_outbox where template_key = 'result_published') = 4,
  '14. unpublishing and republishing does not message again — one per child per '
  || 'term, ever. A parent told twice has been given a reason to think something '
  || 'is wrong; a correction is a conversation, not a broadcast');

-- =============================================================================
-- 6. A withheld result is never announced
-- =============================================================================
do $withheld$
declare
  v_head uuid; v_n bigint; v_stu uuid;
begin
  -- Turn on withholding, give the family a debt, regenerate and publish a fresh
  -- term. The whole family owes, so all four cards are withheld.
  update public.exam_terms set result_withheld_for_defaulters = true
   where id = (select v from public._qm where k = 'term');

  insert into public.fee_heads (name, type, is_recurring, active, school_id)
    values ('Tuition', 'monthly', true, true, (select v from public._qm where k = 'school'))
    returning id into v_head;
  insert into public.fee_structures (session_id, class_id, fee_head_id, amount, school_id)
    values ((select v from public._qm where k = 'sess'),
            (select v from public._qm where k = 'class'), v_head, 4500,
            (select v from public._qm where k = 'school'));
  perform public.fn_generate_class_invoices(
    (select v from public._qm where k = 'sess'),
    (select v from public._qm where k = 'class'),
    date_trunc('month', current_date)::date,
    (date_trunc('month', current_date) + interval '10 days')::date);

  perform public.fn_generate_result_cards(
    (select v from public._qm where k = 'term'),
    (select v from public._qm where k = 'class'), false);

  -- Clear the outbox so this section counts only what the withheld publish does.
  delete from public.message_outbox where template_key = 'result_published';
  update public.result_cards set published_at = null
   where exam_term_id = (select v from public._qm where k = 'term');

  perform public.fn_publish_results(
    (select v from public._qm where k = 'term'),
    (select v from public._qm where k = 'class'));

  select count(*) into v_n from public.message_outbox where template_key = 'result_published';
  if v_n <> 0 then
    raise exception
      'FAIL  15. % message(s) announced a WITHHELD result. The portal shows those '
      'families "Result withheld until outstanding fees are cleared", so the '
      'message would be false for exactly the families most likely to look', v_n;
  end if;
  raise notice 'PASS  15. a withheld result is not announced';
end $withheld$;

do $reported$
declare v_out jsonb;
begin
  v_out := public.fn_queue_result_published(
    (select v from public._qm where k = 'term'),
    (select v from public._qm where k = 'class'));
  if (v_out->>'withheld')::int <> 4 then
    raise exception 'FAIL  16. the function reported %', v_out;
  end if;
  raise notice 'PASS  16. and it REPORTS the four it withheld rather than silently '
    'sending nothing, so the office knows why the parents heard nothing';
end $reported$;

-- =============================================================================
-- 7. Nothing crosses a school boundary
-- =============================================================================
do $tenant$
declare
  v_school2 uuid; v_owner2 uuid := '00000000-0000-0000-0000-00000000dd02';
begin
  perform set_config('test.uid', '', false);
  insert into public.schools (name) values ('Other Message School') returning id into v_school2;
  insert into public.subscriptions (school_id, plan_code, status, trial_ends_on)
    values (v_school2, 'starter', 'active', current_date + 30);
  alter table public.profiles disable trigger user;
  insert into auth.users (id, email) values (v_owner2, 'o2@msgs.test') on conflict (id) do nothing;
  insert into public.profiles (id, full_name, role, school_id)
    values (v_owner2, 'Other Msgs Owner', 'owner', v_school2)
    on conflict (id) do update set school_id = excluded.school_id, role = excluded.role;
  alter table public.profiles enable trigger user;
  perform set_config('test.uid', v_owner2::text, false);
end $tenant$;

do $cross$
begin
  begin
    perform public.fn_queue_absent_today(
      (select v from public._qm where k = 'sess'),
      (select v from public._qm where k = 'class'),
      (select v from public._qm where k = 'sec'),
      (select v from public._qmd where k = 'day'));
  exception when others then
    raise notice 'PASS  17. another school cannot queue messages about our pupils '
      '(refused: %)', left(sqlerrm, 50);
    return;
  end;
  raise exception 'FAIL  17. another school queued messages about our pupils';
end $cross$;

do $cross2$
begin
  begin
    perform public.fn_queue_result_published(
      (select v from public._qm where k = 'term'),
      (select v from public._qm where k = 'class'));
  exception when others then
    raise notice 'PASS  18. and cannot announce our results (refused: %)', left(sqlerrm, 50);
    return;
  end;
  raise exception 'FAIL  18. another school announced our results';
end $cross2$;

rollback;

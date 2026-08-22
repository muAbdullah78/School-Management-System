-- =============================================================================
-- Message settings: does switching a message OFF actually stop it?
--
-- The rules this file defends:
--
--  1. Disabling a template really blocks the message. A toggle that only greys
--     out a checkbox while parents keep receiving the message is worse than no
--     toggle, because the school believes it has stopped.
--  2. Edited wording is what goes out, with the merge tags filled in.
--  3. Restore puts the original back, and the original lives in exactly one
--     place — so the seed and the reset cannot drift apart.
--  4. Re-seeding never overwrites a school's edited wording.
--  5. A clerk may READ what goes out over their name but not change it; a
--     parent may not even read it.
--  6. Nothing crosses a school boundary: two schools' wording is independent.
--
-- A NOTE ON TESTING RLS AT ALL
--
-- Assertion 16 needs `set local role authenticated`, because the test session is
-- the table OWNER and Row Level Security does not apply to the owner. Without
-- it, the assertion measured the harness and reported a clerk's forbidden edit
-- as succeeding — which it did on the first run of this file.
--
-- Every other negative assertion across these suites rests on a SECURITY
-- DEFINER function's own role check or on a trigger, both of which fire
-- regardless of the caller's role; those were re-checked after finding this and
-- are sound. But any NEW assertion of the form "role X cannot write table Y"
-- must switch role, or it proves nothing.
--
-- Run: psql -v ON_ERROR_STOP=1 -f supabase/tests/message_settings.sql
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

-- --- Fixture -----------------------------------------------------------------
do $seed$
declare
  v_a uuid; v_b uuid;
  v_oa uuid := '00000000-0000-0000-0000-00000000ba01';
  v_cl uuid := '00000000-0000-0000-0000-00000000ba02';
  v_pa uuid := '00000000-0000-0000-0000-00000000ba03';
  v_ob uuid := '00000000-0000-0000-0000-00000000ba04';
  v_sess uuid; v_class uuid;
begin
  insert into public.schools (name) values ('Msg School') returning id into v_a;
  insert into public.subscriptions (school_id, plan_code, status, trial_ends_on)
    values (v_a, 'starter', 'active', current_date + 30);
  insert into public.schools (name) values ('Msg Other') returning id into v_b;
  insert into public.subscriptions (school_id, plan_code, status, trial_ends_on)
    values (v_b, 'starter', 'active', current_date + 30);

  -- Templates are seeded per school by a DO block at install; new schools made
  -- inside a test need it run explicitly.
  perform public.fn__seed_message_templates(v_a);
  perform public.fn__seed_message_templates(v_b);

  alter table public.profiles disable trigger user;
  insert into auth.users (id, email) values
    (v_oa, 'msa@msg.test'), (v_cl, 'msc@msg.test'),
    (v_pa, 'msp@msg.test'), (v_ob, 'mso@msg.test') on conflict (id) do nothing;
  insert into public.profiles (id, full_name, role, school_id) values
    (v_oa, 'Msg Owner',  'owner',       v_a),
    (v_cl, 'Msg Clerk',  'admin_clerk', v_a),
    (v_pa, 'Msg Parent', 'parent',      v_a),
    (v_ob, 'Other Owner','owner',       v_b)
    on conflict (id) do update set school_id = excluded.school_id,
                                   role      = excluded.role,
                                   full_name = excluded.full_name,
                                   active    = true;
  alter table public.profiles enable trigger user;

  perform set_config('test.uid', v_oa::text, false);
  insert into public.academic_sessions (name, is_current, school_id)
    values ('2025-2026', true, v_a) returning id into v_sess;
  insert into public.classes (name, level_order, school_id)
    values ('Msg Class', 1, v_a) returning id into v_class;
  perform public.fn_admit_student(jsonb_build_object(
    'full_name', 'MS Child', 'father_name', 'MS Father', 'father_cnic', '35201-9090909-9',
    'phone', '0300-9999999', 'session_id', v_sess, 'class_id', v_class,
    'links', '[]'::jsonb));
end $seed$;

-- =============================================================================
-- 1-3: what the settings screen reads
-- =============================================================================
do $t$
declare v_n int; r record;
begin
  perform set_config('test.uid', '00000000-0000-0000-0000-00000000ba01', false);

  -- Asserted against fn__default_message_templates() rather than a hard-coded
  -- count. The count WAS 5, then 0046 added the two enquiry templates and this
  -- assertion failed for no good reason — a magic number here means every new
  -- template breaks a test that was not testing the new template. The real
  -- invariant is that the settings screen offers every template the schema
  -- defines: one missing is a message a school cannot switch off.
  select count(*) into v_n
  from public.fn__default_message_templates() d
  where not exists (select 1 from public.fn_message_settings() m
                     where m.template_key = d.template_key);
  perform pg_temp.ok(v_n = 0,
    '1. every default template is offered on the settings screen (' || v_n || ' missing)');

  -- ...and nothing extra, so a stale row cannot linger after a template is
  -- renamed.
  select count(*) into v_n
  from public.fn_message_settings() m
  where not exists (select 1 from public.fn__default_message_templates() d
                     where d.template_key = m.template_key);
  perform pg_temp.ok(v_n = 0,
    '1b. and nothing is listed that the schema does not define (' || v_n || ' extra)');

  select * into r from public.fn_message_settings() where template_key = 'payment_received';
  perform pg_temp.ok(r.is_default, '2. an untouched template reports itself as default');
  perform pg_temp.ok('receipt' = any(r.tags) and 'balance' = any(r.tags),
    '3. and carries the tags its call site actually provides');

  -- {receipt} is only passed by the payment-receipt trigger, so offering it on
  -- a fee reminder would put a literal "{receipt}" in front of a parent.
  select * into r from public.fn_message_settings() where template_key = 'fee_reminder';
  perform pg_temp.ok(not ('receipt' = any(r.tags)),
    '4. and NOT tags that would never resolve there');
end $t$;

-- =============================================================================
-- 5-7: THE ONE THAT MATTERS — off means off
-- =============================================================================
do $t$
declare v_fam uuid; v_id uuid; v_before int; v_after int;
begin
  perform set_config('test.uid', '00000000-0000-0000-0000-00000000ba01', false);
  select family_id into v_fam from public.students where full_name = 'MS Child';

  -- Enabled: the message queues.
  v_id := public.fn_queue_message('fee_reminder', v_fam, '{}'::jsonb, null, null);
  perform pg_temp.ok(v_id is not null, '5. an enabled template queues a message');

  -- Now switch it off through the same column the UI writes.
  update public.message_templates set enabled = false
   where school_id = public.current_school_id() and template_key = 'fee_reminder';

  select count(*) into v_before from public.message_outbox
   where family_id = v_fam and template_key = 'fee_reminder';
  v_id := public.fn_queue_message('fee_reminder', v_fam, '{}'::jsonb, null, null);
  select count(*) into v_after from public.message_outbox
   where family_id = v_fam and template_key = 'fee_reminder';

  perform pg_temp.ok(v_id is null, '6. a disabled template queues nothing');
  perform pg_temp.ok(v_after = v_before,
    '7. and writes no outbox row at all — the toggle is not cosmetic');

  update public.message_templates set enabled = true
   where school_id = public.current_school_id() and template_key = 'fee_reminder';
end $t$;

-- =============================================================================
-- 8-9: bulk reminders respect the toggle too
--
-- fn_queue_class_reminders loops over families and swallows per-family errors.
-- A school that has switched reminders off must not have that decision
-- overridden by a bulk action.
-- =============================================================================
do $t$
declare v_sess uuid; v_class uuid; v_res jsonb; v_before int; v_after int;
begin
  perform set_config('test.uid', '00000000-0000-0000-0000-00000000ba01', false);
  select id into v_sess from public.academic_sessions
   where school_id = public.current_school_id() and is_current;
  select id into v_class from public.classes where school_id = public.current_school_id() limit 1;

  update public.message_templates set enabled = false
   where school_id = public.current_school_id()
     and template_key in ('fee_reminder', 'fee_reminder_final');

  select count(*) into v_before from public.message_outbox
   where school_id = public.current_school_id() and template_key like 'fee_reminder%';
  v_res := public.fn_queue_class_reminders(v_sess, v_class, null);
  select count(*) into v_after from public.message_outbox
   where school_id = public.current_school_id() and template_key like 'fee_reminder%';

  perform pg_temp.ok(v_after = v_before,
    '8. "WhatsApp everyone who owes" respects a switched-off reminder');
  -- It should report that nothing went out rather than claiming success.
  perform pg_temp.ok((v_res->>'queued')::int = 0,
    '9. and reports zero queued rather than a false success ('
      || coalesce(v_res->>'queued', 'null') || ')');

  update public.message_templates set enabled = true
   where school_id = public.current_school_id()
     and template_key in ('fee_reminder', 'fee_reminder_final');
end $t$;

-- =============================================================================
-- 10-13: edited wording, and getting the original back
-- =============================================================================
do $t$
declare v_fam uuid; v_id uuid; v_text text; r record; v_restored text;
begin
  perform set_config('test.uid', '00000000-0000-0000-0000-00000000ba01', false);
  select family_id into v_fam from public.students where full_name = 'MS Child';

  update public.message_templates
     set body = 'Salam {parent}, {children} owes Rs {balance}. Regards, {school}.'
   where school_id = public.current_school_id() and template_key = 'fee_reminder';

  select * into r from public.fn_message_settings() where template_key = 'fee_reminder';
  perform pg_temp.ok(not r.is_default,
    '10. an edited template no longer reports itself as default');

  v_id := public.fn_queue_message('fee_reminder', v_fam, '{}'::jsonb, null, null);
  select rendered_text into v_text from public.message_outbox where id = v_id;

  perform pg_temp.ok(v_text like 'Salam MS Father,%',
    '11. the edited wording is what goes out, with tags filled in (' || left(v_text, 40) || '…)');
  perform pg_temp.ok(v_text not like '%{%',
    '12. and no unresolved tag reaches the parent');

  v_restored := public.fn_reset_message_template('fee_reminder');
  select * into r from public.fn_message_settings() where template_key = 'fee_reminder';
  perform pg_temp.ok(r.is_default and r.body = v_restored,
    '13. restore puts the original back');
end $t$;

-- =============================================================================
-- 14: re-seeding must never overwrite a school's own wording
-- =============================================================================
do $t$
declare v_body text;
begin
  perform set_config('test.uid', '00000000-0000-0000-0000-00000000ba01', false);
  update public.message_templates set body = 'Our own words, {parent}.'
   where school_id = public.current_school_id() and template_key = 'absent_today';

  perform public.fn__seed_message_templates(public.current_school_id());

  select body into v_body from public.message_templates
   where school_id = public.current_school_id() and template_key = 'absent_today';
  perform pg_temp.ok(v_body = 'Our own words, {parent}.',
    '14. re-seeding leaves an edited template alone');
end $t$;

-- =============================================================================
-- 15-18: who may read and who may change
-- =============================================================================
do $t$
declare v_n int; v_ok boolean := false;
begin
  -- A clerk should see what goes out over their name — the SAME list an owner
  -- sees, not a hard-coded count that has to be bumped whenever a template is
  -- added. "A clerk sees everything the school defines" is the actual promise.
  perform set_config('test.uid', '00000000-0000-0000-0000-00000000ba02', false);
  select count(*) into v_n from public.fn_message_settings();
  perform pg_temp.ok(
    v_n > 0 and v_n = (select count(*) from public.fn__default_message_templates()),
    '15. a clerk reads the same message settings an owner does (' || v_n || ')');

  -- But not change them.
  --
  -- `set local role authenticated` is load-bearing: the test session is the
  -- table OWNER, and Row Level Security does not apply to the owner unless the
  -- table is FORCE ROW LEVEL SECURITY. Without switching role this assertion
  -- would measure the harness rather than the policy — it did, on the first
  -- run, and reported the clerk's edit as succeeding. Real users connect as
  -- `authenticated`, which is what this reproduces.
  set local role authenticated;
  update public.message_templates set body = 'clerk was here'
   where template_key = 'absent_today';
  reset role;

  select count(*) into v_n from public.message_templates
   where body = 'clerk was here';
  perform pg_temp.ok(v_n = 0,
    '16. and cannot change them — the write policy matches no rows for a clerk');

  begin
    perform public.fn_reset_message_template('absent_today');
    raise exception 'FAIL  17. a clerk restored a template';
  exception when others then
    if sqlerrm like 'FAIL%' then raise; end if;
    raise notice 'PASS  17. a clerk cannot restore a template (%)', sqlerrm;
  end;

  -- A parent may not read them at all.
  perform set_config('test.uid', '00000000-0000-0000-0000-00000000ba03', false);
  begin
    perform count(*) from public.fn_message_settings();
    raise exception 'FAIL  18. a parent read the message settings';
  exception when others then
    if sqlerrm like 'FAIL%' then raise; end if;
    raise notice 'PASS  18. a parent cannot read the message settings (%)', sqlerrm;
  end;
end $t$;

-- =============================================================================
-- 19-20: two schools' wording is independent
-- =============================================================================
do $t$
declare v_a_body text; v_b_body text; v_n int;
begin
  perform set_config('test.uid', '00000000-0000-0000-0000-00000000ba01', false);
  update public.message_templates set body = 'School A wording {parent}'
   where school_id = public.current_school_id() and template_key = 'result_published';
  select body into v_a_body from public.message_templates
   where school_id = public.current_school_id() and template_key = 'result_published';

  perform set_config('test.uid', '00000000-0000-0000-0000-00000000ba04', false);
  select count(*) into v_n from public.fn_message_settings();
  perform pg_temp.ok(
    v_n > 0 and v_n = (select count(*) from public.fn__default_message_templates()),
    '19. the other school is seeded with its own full set of templates (' || v_n || ')');

  select body into v_b_body from public.message_templates
   where school_id = public.current_school_id() and template_key = 'result_published';
  perform pg_temp.ok(v_b_body <> v_a_body,
    '20. and school A''s edit did not change school B''s wording');
end $t$;

do $$ begin raise notice '--- message_settings.sql: all assertions passed'; end $$;

rollback;

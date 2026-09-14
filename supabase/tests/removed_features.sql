-- =============================================================================
-- What survives removing the cash drawer and the WhatsApp outbox.
--
-- 0136 is the first migration in this project that is mostly a REMOVAL, and a
-- removal is tested differently from an addition: what matters is not that the
-- thing is gone, which is easy, but that nothing else went with it.
--
-- WHY THESE ASSERT A SEAL AND NOT AN ABSENCE. 0136 does not drop the three
-- tables or the functions, and that is deliberate. Bundles 4, 7, 8, 24 and 28
-- are frozen by supabase/bundles/MANIFEST and name them in plain DDL, so a
-- drop makes every one of those files raise and roll back whole. verify.sql,
-- supabase/repair/detect.sql and CI's upgrade job all tell a school to paste
-- bundles again, and all three would then stop on a red error before reaching
-- anything that fixes anything. The first draft of the migration did drop
-- them; this is what came back. So the feature is closed off from every
-- direction instead, and closed off is what is asserted here: no rows, no
-- policy, RLS forced so even the table owner reads nothing, and not one
-- function of either feature executable by anon, authenticated or
-- service_role.
--
-- ASSERTIONS 6 AND 7 ARE THE TWO SECURITY BOUNDARIES that a rolled-back bundle
-- would silently reopen. They are kept even though no bundle rolls back any
-- more, because they cost nothing and they fail loudly here rather than in a
-- school's database.
--
-- Run: psql -v ON_ERROR_STOP=1 -f supabase/tests/removed_features.sql
-- =============================================================================
\set ON_ERROR_STOP on
begin;

-- Adopt an identity the way every suite here does. Without this, auth.uid() is
-- null, has_role() is false for everybody, and assertion 10 fails with
-- "Not permitted to record payments" while proving nothing about the drawer.
create or replace function auth.uid() returns uuid language sql stable as
  $$ select nullif(current_setting('test.uid', true), '')::uuid $$;

create or replace function pg_temp.ok(p_cond boolean, p_label text)
returns void language plpgsql as $$
begin
  if p_cond then raise notice 'PASS  %', p_label;
  else raise exception 'FAIL  %', p_label; end if;
end;
$$;

-- =============================================================================
-- 1-5. Both features are closed off, by every route they had
-- =============================================================================
do $gone$
declare
  v_left  text;
  v_open  text;
begin
  -- Every policy dropped. With none left, RLS denies by default, so this is
  -- the read gate and the write gate in one.
  perform pg_temp.ok(
    not exists (select 1 from pg_policies
                 where schemaname = 'public'
                   and tablename in ('till_sessions','message_outbox',
                                     'message_templates')),
    '1. the retired tables have no policy left, so RLS denies every read and '
    || 'every write by default');

  -- FORCE, not merely ENABLE. Enabled RLS does not apply to the table owner,
  -- and every SECURITY DEFINER function in this schema runs as the owner.
  -- Forced is what makes the seal hold against the code as well as the client.
  perform pg_temp.ok(
    (select count(*) from pg_class c join pg_namespace n on n.oid = c.relnamespace
      where n.nspname = 'public'
        and c.relname in ('till_sessions','message_outbox','message_templates')
        and c.relrowsecurity and c.relforcerowsecurity) = 3,
    '2. and RLS is FORCED on all three, which binds the owner too, so a '
    || 'SECURITY DEFINER function that named one would still read nothing');

  perform pg_temp.ok(
    (select count(*) from public.till_sessions) = 0
    and (select count(*) from public.message_outbox) = 0
    and (select count(*) from public.message_templates) = 0,
    '3. nothing is left in any of them: no message a parent could still '
    || 'receive, no drawer anybody could reopen');

  perform pg_temp.ok(
    not exists (select 1 from public.payments where till_session_id is not null),
    '4. and no payment names a drawer. This is the half a screen would not '
    || 'show: the column outlived the feature and every payment path was '
    || 'still filling it in');

  -- Named, so a failure says WHICH one came back rather than that one did.
  -- has_function_privilege is the honest question here, not existence: the
  -- functions are still in the catalogue because frozen bundles recreate them,
  -- and what matters is that nothing can call them.
  select string_agg(p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')',
                    ', ' order by p.proname) into v_open
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and (p.proname ~ 'till'
          or p.proname in ('fn_queue_message','fn_queue_absent_today',
                           'fn_queue_class_reminders','fn_queue_enquiry_message',
                           'fn_queue_result_published','fn__queue_payment_receipt',
                           'fn_mark_message_sent','fn_skip_message',
                           'fn_message_settings','fn_reset_message_template',
                           'fn_provision_message_templates',
                           'fn__seed_message_templates','fn__default_message_templates',
                           'fn_unsent_receipts','fn__render_template'))
     and (has_function_privilege('anon',          p.oid, 'execute')
          or has_function_privilege('authenticated', p.oid, 'execute')
          or has_function_privilege('service_role',  p.oid, 'execute'));
  perform pg_temp.ok(v_open is null,
    '5. and not one till or outbox function can be executed by anon, '
    || 'authenticated or service_role, so a hand-written PostgREST call fails '
    || 'on permission rather than finding a working feature: '
    || coalesce(v_open, 'none open'));

  -- The template list itself. Kept as a function because bundle 7 revokes it
  -- by name, but it offers nothing, which is what lets bundle 7's own 0088
  -- sweep pass truthfully instead of by a comment that happens to match.
  select string_agg(template_key, ', ') into v_left
    from public.fn__default_message_templates();
  perform pg_temp.ok(v_left is null,
    '5b. and a school is offered no template at all, because nothing sends '
    || 'one: ' || coalesce(v_left, 'none'));
end $gone$;

-- =============================================================================
-- 6-7. THE TWO SECURITY BOUNDARIES A ROLLED-BACK BUNDLE WOULD REOPEN
-- =============================================================================
do $scopes$
declare v_src text;
begin
  -- fn_enter_marks writes the marks printed on the result card, the
  -- certificate and the tabulation sheet. 0085 narrowed it from "your class"
  -- to "your class AND your subject", which is what stops the Physics teacher
  -- of Class 9 rewriting Class 9's Islamiat result.
  select prosrc into v_src from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'fn_enter_marks';
  perform pg_temp.ok(
    position('fn_may_mark_subject' in regexp_replace(v_src, '--[^' || chr(10) || ']*', '', 'g')) > 0,
    '6. fn_enter_marks still CALLS fn_may_mark_subject. Without it any teacher '
    || 'can write any class''s exam marks, and nothing errors when they do');

  -- fn_global_search reads across the school's records from one box. 0072
  -- added the school predicate; without it the box reaches the platform.
  select prosrc into v_src from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'fn_global_search';
  perform pg_temp.ok(
    position('current_school_id' in regexp_replace(v_src, '--[^' || chr(10) || ']*', '', 'g')) > 0,
    '7. fn_global_search is still scoped to the caller''s school. Without it '
    || 'the search box reaches another school''s children');
end $scopes$;

-- Comments stripped before looking, in both, and that is the point of the
-- assertion rather than a detail. pg_get_functiondef and prosrc carry the
-- comments, so a body that merely MENTIONS the helper in a note passes a naive
-- check while calling nothing. A guard satisfied by a comment keeps passing
-- after somebody deletes the code, which is worse than no guard.

-- =============================================================================
-- 8-10. What the removal must NOT have taken with it
-- =============================================================================
do $kept$
begin
  -- Click-to-chat is not the outbox and was deliberately kept: it opens
  -- WhatsApp with the message typed, stores nothing and queues nothing.
  perform pg_temp.ok(
    exists (select 1 from information_schema.columns
             where table_schema = 'public' and table_name = 'students'
               and column_name = 'whatsapp'),
    '8. a pupil still has a WhatsApp number, because it is a phone number the '
    || 'office typed');

  perform pg_temp.ok(
    to_regprocedure('public.fn_record_payment(uuid,numeric,payment_method,text,boolean)') is not null
    and to_regprocedure('public.fn_record_family_payment(uuid,numeric,payment_method,text,boolean)') is not null,
    '9. both ways of taking a fee still exist');

  -- fn_platform_renewal_message is the VENDOR's renewal reminder to a school,
  -- not a school's message to a parent. Its name matches the sweep 0136 used,
  -- so this asserts the sweep was scoped rather than greedy.
  perform pg_temp.ok(
    exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
             where n.nspname = 'public' and p.proname = 'fn_platform_renewal_message'),
    '10. the operator console still has its renewal message, which shares a word '
    || 'with what was removed and nothing else');
end $kept$;

-- =============================================================================
-- 11. A payment still works, end to end, with no drawer under it
-- =============================================================================
do $pay$
declare
  s1 uuid := gen_random_uuid();
  own uuid := '00000000-0000-0000-0000-00000000d001';
  ses uuid; cls uuid; fam uuid; stu uuid; enr uuid; inv uuid; j jsonb;
  today date := (now() at time zone 'Asia/Karachi')::date;
begin
  insert into public.schools (id, name, city) values (s1, 'No Drawer School', 'Jhelum');
  insert into public.subscriptions (school_id, plan_code, status, trial_ends_on)
    values (s1, 'growth', 'active', today + 90);
  insert into auth.users (id, email) values (own, 'owner@nodrawer.test')
    on conflict (id) do nothing;
  insert into public.academic_sessions (school_id, name, starts_on, ends_on, is_current)
    values (s1, '2026-2027', today - 30, today + 240, true) returning id into ses;
  insert into public.classes (school_id, name, level_order) values (s1, 'Class 1', 1)
    returning id into cls;
  insert into public.families (school_id, head_name) values (s1, 'Payer Family')
    returning id into fam;
  insert into public.students (school_id, gr_no, full_name, family_id, admission_date, status)
    values (s1, 'GR-D1', 'Paying Child', fam, today - 10, 'active') returning id into stu;
  insert into public.enrollments (school_id, student_id, session_id, class_id, roll_no)
    values (s1, stu, ses, cls, '1') returning id into enr;
  insert into public.invoices (school_id, student_id, session_id, period_month, due_date, status)
    values (s1, stu, ses, date_trunc('month', today)::date, today + 5, 'issued')
    returning id into inv;
  insert into public.invoice_lines (school_id, invoice_id, description, amount)
    values (s1, inv, 'Tuition', 3000);

  alter table public.profiles disable trigger user;
  insert into public.profiles (id, school_id, full_name, role)
    values (own, s1, 'No Drawer Owner', 'owner');
  alter table public.profiles enable trigger user;

  perform set_config('test.uid', own::text, false);
  j := public.fn_record_payment(stu, 3000, 'cash', 'first instalment', false);

  perform pg_temp.ok((j->>'receipt_no') is not null,
    '11. a cash fee is taken and a receipt number issued with no drawer to '
    || 'open. That was the one thing the till genuinely did in the payment '
    || 'path, and it did it by opening a drawer nobody had asked for');
end $pay$;

rollback;
\echo 'REMOVED FEATURES: ALL TESTS PASSED'

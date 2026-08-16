-- =============================================================================
-- Message outbox.
--
-- Rules defended here:
--  1. Every verified payment queues a receipt message automatically, whichever
--     of the three payment paths created it.
--  2. The message quotes the balance AFTER the payment, not before. This is
--     why the trigger is deferred; a plain AFTER INSERT fires before
--     allocation and would tell every parent their pre-payment balance.
--  3. Reversals and pending challans do NOT queue a thank-you.
--  4. fn_unsent_receipts() shows payments taken vs receipts actually sent —
--     the number the whole table exists for.
--  5. A messaging failure never rolls back a payment.
--
-- Run: psql -v ON_ERROR_STOP=1 -f supabase/tests/outbox.sql
-- =============================================================================

\set ON_ERROR_STOP on

create or replace function auth.uid() returns uuid language sql stable as
  $$ select nullif(current_setting('test.uid', true), '')::uuid $$;

do $seed$
declare
  v_school uuid; v_owner uuid := '00000000-0000-0000-0000-00000000c001';
  v_sess uuid; v_class uuid; v_sec uuid; v_head uuid; v_fam uuid; v_stu uuid;
begin
  perform set_config('test.uid', '', false);
  delete from public.schools where name = 'Outbox Test School';
  insert into public.schools (name) values ('Outbox Test School') returning id into v_school;
  insert into public.subscriptions (school_id, plan_code, status, trial_ends_on)
    values (v_school, 'starter', 'active', current_date + 30);

  alter table public.profiles disable trigger user;
  insert into auth.users (id, email) values (v_owner, 'c1@outbox.test') on conflict (id) do nothing;
  insert into public.profiles (id, full_name, role, school_id)
    values (v_owner, 'Outbox Owner', 'owner', v_school)
    on conflict (id) do update set school_id = excluded.school_id, role = excluded.role;
  alter table public.profiles enable trigger user;

  perform set_config('test.uid', v_owner::text, false);
  insert into public.school_settings (school_id, name) values (v_school, 'Outbox Test School')
    on conflict (school_id) do update set name = excluded.name;

  insert into public.academic_sessions (name, is_current, school_id)
    values ('2025-2026', true, v_school) returning id into v_sess;
  insert into public.classes (name, level_order, school_id)
    values ('Class 1', 1, v_school) returning id into v_class;
  insert into public.sections (class_id, name, school_id)
    values (v_class, 'A', v_school) returning id into v_sec;
  insert into public.fee_heads (name, type, is_recurring, active, school_id)
    values ('Tuition', 'monthly', true, true, v_school) returning id into v_head;
  insert into public.fee_structures (session_id, class_id, fee_head_id, amount, school_id)
    values (v_sess, v_class, v_head, 5000, v_school);

  insert into public.families (school_id, head_name, phone, whatsapp)
    values (v_school, 'Rashid Mehmood', '03001112222', '03001112222')
    returning id into v_fam;
  insert into public.students (full_name, status, school_id, family_id)
    values ('Hamza Rashid', 'active', v_school, v_fam) returning id into v_stu;
  insert into public.enrollments (student_id, session_id, class_id, section_id, status, school_id)
    values (v_stu, v_sess, v_class, v_sec, 'active', v_school);

  perform public.fn_generate_class_invoices(v_sess, v_class, date '2025-09-01', date '2025-09-10');
  raise notice 'fixture ok';
end $seed$;

-- NOTE ON STRUCTURE: the receipt trigger is a DEFERRED constraint trigger, so
-- it fires at COMMIT. A single DO block is one transaction and therefore cannot
-- observe its own queued row — each payment is made in one block and asserted
-- in the next. That is also exactly how the app behaves: one RPC, one
-- transaction, trigger fires as it commits.
create table if not exists public._ob (k text primary key, v uuid);

-- 1. A payment queues a receipt, and the BALANCE IS POST-PAYMENT
do $t$
declare v_fam uuid; j jsonb;
begin
  select id into v_fam from public.families where head_name = 'Rashid Mehmood';
  -- owes 5000, pays 2000 -> remaining balance must read 3000, not 5000
  j := public.fn_record_family_payment(v_fam, 2000, 'cash', null);
  insert into public._ob(k, v) values ('pay1', (j->>'payment_id')::uuid)
    on conflict (k) do update set v = excluded.v;
end $t$;

do $t$
declare o record;
begin
  select * into o from public.message_outbox
  where payment_id = (select v from public._ob where k = 'pay1');
  if not found then raise exception 'FAIL: no receipt message queued for a payment'; end if;
  if o.status <> 'queued' then raise exception 'FAIL: expected queued, got %', o.status; end if;
  if o.to_phone <> '03001112222' then raise exception 'FAIL: wrong phone %', o.to_phone; end if;

  if o.rendered_text not like '%Rs 2,000%' then
    raise exception 'FAIL: amount missing from message: %', o.rendered_text;
  end if;
  if o.rendered_text not like '%Rs 3,000%' then
    raise exception 'FAIL: message quotes the PRE-payment balance (deferred trigger?): %',
      o.rendered_text;
  end if;
  if o.rendered_text not like '%Hamza Rashid%' or o.rendered_text not like '%Rashid Mehmood%' then
    raise exception 'FAIL: names not substituted: %', o.rendered_text;
  end if;
  if o.rendered_text like '%{%' then
    raise exception 'FAIL: unsubstituted placeholder left in message: %', o.rendered_text;
  end if;
  raise notice '1. receipt queued with the POST-payment balance — ok';
end $t$;

-- 2. A PENDING challan queues nothing
do $t$
declare v_fam uuid; j jsonb;
begin
  select id into v_fam from public.families where head_name = 'Rashid Mehmood';
  j := public.fn_record_family_payment(v_fam, 500, 'bank_challan', null, true);
  insert into public._ob(k, v) values ('pending', (j->>'payment_id')::uuid)
    on conflict (k) do update set v = excluded.v;
end $t$;

do $t$
begin
  if exists (select 1 from public.message_outbox
             where payment_id = (select v from public._ob where k = 'pending')) then
    raise exception 'FAIL: a PENDING challan queued a thank-you message';
  end if;
  raise notice '2. pending challan queues nothing — ok';
end $t$;

-- 2b. A REVERSAL queues nothing
do $t$
declare v_fam uuid; j jsonb; v_rev uuid;
begin
  select id into v_fam from public.families where head_name = 'Rashid Mehmood';
  j := public.fn_record_family_payment(v_fam, 1000, 'cash', null);
  v_rev := public.fn_reverse_payment((j->>'payment_id')::uuid, 'test');
  insert into public._ob(k, v) values ('rev', v_rev)
    on conflict (k) do update set v = excluded.v;
end $t$;

do $t$
begin
  if exists (select 1 from public.message_outbox
             where payment_id = (select v from public._ob where k = 'rev')) then
    raise exception 'FAIL: a REVERSAL queued a thank-you message';
  end if;
  raise notice '2b. reversal queues nothing — ok';
end $t$;

-- 3. Sent / skipped transitions
do $t$
declare v_id uuid; v_st public.message_status; v_school uuid;
begin
  -- Scope to THIS school. Other suites in the same run create payments in their
  -- own schools, which queue their own messages; picking the globally-first
  -- queued row would (correctly) be refused by assert_own.
  select id into v_school from public.schools where name = 'Outbox Test School';

  select id into v_id from public.message_outbox
   where school_id = v_school and status = 'queued' order by created_at limit 1;
  perform public.fn_mark_message_sent(v_id);
  select status into v_st from public.message_outbox where id = v_id;
  if v_st <> 'sent' then raise exception 'FAIL: mark sent did not take (%)', v_st; end if;

  select id into v_id from public.message_outbox
   where school_id = v_school and status = 'queued' order by created_at limit 1;
  if v_id is not null then
    perform public.fn_skip_message(v_id, 'no phone');
    select status into v_st from public.message_outbox where id = v_id;
    if v_st <> 'skipped' then raise exception 'FAIL: skip did not take (%)', v_st; end if;
  end if;
  raise notice '3. sent / skipped transitions — ok';
end $t$;

-- 4. The number the table exists for
do $t$
declare j jsonb;
begin
  j := public.fn_unsent_receipts(current_date - 1, current_date + 1);
  if (j->>'payments')::int < 2 then
    raise exception 'FAIL: expected at least 2 payments, got %', j->>'payments';
  end if;
  if (j->>'receipts_sent')::int < 1 then
    raise exception 'FAIL: expected at least 1 sent receipt, got %', j->>'receipts_sent';
  end if;
  raise notice '4. payments vs receipts-sent report works (%) — ok', j;
end $t$;

-- 5. A family with no phone must not break payments
do $t$
declare v_school uuid; v_fam uuid; v_stu uuid; j jsonb;
begin
  select id into v_school from public.schools where name = 'Outbox Test School';
  insert into public.families (school_id, head_name) values (v_school, 'No Phone Sahib')
    returning id into v_fam;
  insert into public.students (full_name, status, school_id, family_id)
    values ('Silent Child', 'active', v_school, v_fam) returning id into v_stu;

  j := public.fn_record_family_payment(v_fam, 300, 'cash', null);
  if j is null or (j->>'receipt_no') is null then
    raise exception 'FAIL: a payment failed because the family had no phone number';
  end if;
  raise notice '5. no phone number never blocks a payment — ok';
end $t$;

-- 6. Cross-tenant
do $t$
declare v_other uuid; v_owner uuid := '00000000-0000-0000-0000-00000000c009'; v_n bigint;
begin
  perform set_config('test.uid', '', false);
  delete from public.schools where name = 'Other Outbox School';
  insert into public.schools (name) values ('Other Outbox School') returning id into v_other;
  insert into public.subscriptions (school_id, plan_code, status, trial_ends_on)
    values (v_other, 'starter', 'active', current_date + 30);
  alter table public.profiles disable trigger user;
  insert into auth.users (id, email) values (v_owner, 'c9@outbox.test') on conflict (id) do nothing;
  insert into public.profiles (id, full_name, role, school_id)
    values (v_owner, 'Other Outbox Owner', 'owner', v_other)
    on conflict (id) do update set school_id = excluded.school_id, role = excluded.role;
  alter table public.profiles enable trigger user;

  perform set_config('test.uid', v_owner::text, false);
  set local role authenticated;
  select count(*) into v_n from public.message_outbox;
  reset role;
  if v_n > 0 then raise exception 'FAIL: read % outbox rows from another school', v_n; end if;
  raise notice '6. cross-tenant outbox access refused — ok';
end $t$;

drop table if exists public._ob;
do $$ begin raise notice 'ALL OUTBOX TESTS PASSED'; end $$;

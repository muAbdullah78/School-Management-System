-- =============================================================================
-- A school can leave, keeps what it paid for, and cancelling buys it nothing
--
-- WHY THIS FILE EXISTS
--
-- 0112 added cancel_at_period_end so that cancelling would keep a school
-- running to the end of what it had paid for. That was right and it left
-- something behind: fn_effective_status knew nothing about the flag, so once
-- the period passed the school fell into the ordinary ladder and read 'grace'.
--
-- Grace exists for exactly one reason, which 0026 states: the period has ended
-- and a payment is in flight, so the software keeps working while the money
-- arrives. A school that has CANCELLED has no payment in flight. So pressing
-- Cancel would have bought a free fortnight, every time, and the only way to
-- notice would have been an operator wondering why a departed customer was
-- still marking attendance.
--
-- Measured before the fix, not assumed: period_end three days ago plus
-- cancel_at_period_end reported 'grace'.
--
-- The other three properties are about not frightening people. A product with
-- no self-service cancellation is a product people are afraid to start, and a
-- cancellation that takes effect the same second takes money already received
-- and gives nothing back for it.
--
-- Run: psql -v ON_ERROR_STOP=1 -f supabase/tests/leaving_and_coming_back.sql
-- =============================================================================

\set ON_ERROR_STOP on
begin;

create or replace function auth.uid() returns uuid language sql stable as
  $$ select nullif(current_setting('test.uid', true), '')::uuid $$;

create temp table ids (k text primary key, v uuid);

do $seed$
declare
  sch uuid := gen_random_uuid(); lapsed uuid := gen_random_uuid();
  own_u uuid := '00000000-0000-0000-0000-0000000000d1';
  clerk_u uuid := '00000000-0000-0000-0000-0000000000d2';
  own_l uuid := '00000000-0000-0000-0000-0000000000d3';
begin
  insert into public.schools (id, name) values
    (sch, 'Leaving School'), (lapsed, 'Already Gone');
  -- Paid to twenty days from now. The whole point of cancelling at period end.
  insert into public.subscriptions (school_id, plan_code, status, cycle,
                                    period_start, period_end, term_months)
    values (sch, 'starter', 'active', 'monthly', current_date - 10, current_date + 20, 1);
  -- Period ended a week ago and already set to end: the state where coming back
  -- is a purchase rather than an undo.
  insert into public.subscriptions (school_id, plan_code, status, cycle,
                                    period_start, period_end, cancel_at_period_end)
    values (lapsed, 'starter', 'active', 'monthly', current_date - 40,
            current_date - 7, true);

  insert into auth.users (id, email) values
    (own_u, 'owner@leaving.test'), (clerk_u, 'clerk@leaving.test'),
    (own_l, 'owner@gone.test') on conflict (id) do nothing;
  alter table public.profiles disable trigger user;
  insert into public.profiles (id, school_id, full_name, role, active) values
    (own_u, sch, 'Owner', 'owner', true),
    (clerk_u, sch, 'Clerk', 'admin_clerk', true),
    (own_l, lapsed, 'Gone Owner', 'owner', true);
  alter table public.profiles enable trigger user;

  insert into ids values ('sch', sch), ('lapsed', lapsed),
    ('own', own_u), ('clerk', clerk_u), ('own_l', own_l);
end $seed$;

-- 1. CANCELLING DOES NOT END ACCESS TODAY. They paid to a date; ending access
--    the moment somebody clicks takes money already received and gives nothing
--    back for it.
do $t$
declare j jsonb;
begin
  perform set_config('test.uid', (select v::text from ids where k='own'), false);
  j := public.fn_cancel_my_subscription('Too expensive for our size');

  if (j->>'runs_until')::date <> current_date + 20 then
    raise exception 'FAIL: cancelling reported the software running until % when '
      'they have paid to %', j->>'runs_until', current_date + 20;
  end if;
  if public.fn_effective_status((select v from ids where k='sch'))::text <> 'active' then
    raise exception 'FAIL: a school that cancelled today, having paid for twenty '
      'more days, reads as % rather than active',
      public.fn_effective_status((select v from ids where k='sch'));
  end if;
  -- The fear that stops people cancelling is not knowing whether their records
  -- go with it, so the answer is part of the response rather than a help page.
  if j->>'keeps' not like '%Nothing is deleted%' then
    raise exception 'FAIL: cancelling does not say what the school keeps: %', j->>'keeps';
  end if;
  raise notice '1. cancelling keeps the software running to the paid date - ok';
end $t$;

-- 2. AND AUTO-RENEWAL GOES OFF WITH IT. Left on, the renewal runner and this
--    flag would disagree about whether the school is still a customer, and the
--    schema's own constraint would be satisfied either way.
do $t$
declare v_auto boolean;
begin
  select auto_renew into v_auto from public.subscriptions
   where school_id = (select v from ids where k='sch');
  if v_auto then
    raise exception 'FAIL: a cancelled subscription is still set to renew automatically';
  end if;
  raise notice '2. cancelling switches automatic renewal off - ok';
end $t$;

-- 3. THE ASSERTION THIS FILE EXISTS FOR. Once the period passes, a cancelled
--    school is cancelled, not in grace.
do $t$
declare v_status text;
begin
  update public.subscriptions set period_end = current_date - 3
   where school_id = (select v from ids where k='sch');
  v_status := public.fn_effective_status((select v from ids where k='sch'))::text;
  if v_status = 'grace' then
    raise exception 'FAIL: three days after its paid period ended, a school that '
      'CANCELLED reads as grace. Grace exists for a payment in flight and a '
      'cancelled school has none, so pressing Cancel buys a free fortnight.';
  end if;
  if v_status <> 'cancelled' then
    raise exception 'FAIL: a cancelled school past its period reads as %', v_status;
  end if;
  raise notice '3. cancelling buys no grace period - ok';
end $t$;

-- 4. AND AN ORDINARY LAPSE STILL GETS ITS GRACE. The branch added for 3 must
--    not have taken grace away from the schools it was built for: one that has
--    not cancelled, whose payment really may be in flight.
do $t$
declare v_status text; v_other uuid := gen_random_uuid();
begin
  -- The caller identity is cleared first. Creating a school fires the
  -- expense-category provisioning trigger, and enforce_school_id refuses a row
  -- addressed to one school while the caller belongs to another - which is
  -- exactly right, and which the first draft of this block tripped over twice
  -- in this session.
  perform set_config('test.uid', '', false);
  insert into public.schools (id, name) values (v_other, 'Just Late');
  insert into public.subscriptions (school_id, plan_code, status, cycle,
                                    period_start, period_end)
    values (v_other, 'starter', 'active', 'monthly', current_date - 40, current_date - 3);
  v_status := public.fn_effective_status(v_other)::text;
  if v_status <> 'grace' then
    raise exception 'FAIL: a school three days past its period that has NOT '
      'cancelled reads as % rather than grace. The fix for the cancellation case '
      'has taken grace away from the case it was built for.', v_status;
  end if;
  raise notice '4. a school that is merely late still gets its grace - ok';
end $t$;

-- 5. CHANGING YOUR MIND WORKS WHILE THE PERIOD IS RUNNING.
do $t$
declare j jsonb;
begin
  update public.subscriptions set period_end = current_date + 20
   where school_id = (select v from ids where k='sch');
  perform set_config('test.uid', (select v::text from ids where k='own'), false);
  j := public.fn_resume_my_subscription();

  if (j->>'resumed')::boolean is not true then
    raise exception 'FAIL: resuming did not report success';
  end if;
  if (select cancel_at_period_end from public.subscriptions
       where school_id = (select v from ids where k='sch')) then
    raise exception 'FAIL: the subscription is still set to end after resuming';
  end if;
  -- It must NOT quietly switch automatic renewal back on: it depends on a
  -- payment method the school may since have removed, and a school assuming
  -- renewal is automatic when it is not is the failure this whole stage is
  -- built to avoid.
  if (select auto_renew from public.subscriptions
       where school_id = (select v from ids where k='sch')) then
    raise exception 'FAIL: resuming silently turned automatic renewal back on';
  end if;
  if j->>'note' not like '%switched off when you cancelled%' then
    raise exception 'FAIL: resuming does not mention that renewal is still off: %',
      j->>'note';
  end if;
  raise notice '5. changing your mind restores the subscription, not the autopilot - ok';
end $t$;

-- 6. BUT COMING BACK AFTER IT HAS ENDED IS A PURCHASE, NOT AN UNDO. A function
--    that reinstated a lapsed school would hand the product to anybody who
--    cancelled and waited.
do $t$
declare v_msg text;
begin
  perform set_config('test.uid', (select v::text from ids where k='own_l'), false);
  begin
    perform public.fn_resume_my_subscription();
    raise exception 'FAIL: a school whose period ended a week ago resumed itself '
      'for free';
  exception when others then
    get stacked diagnostics v_msg = message_text;
    if v_msg like 'FAIL:%' then raise exception '%', v_msg; end if;
    if v_msg not like '%Choose a plan to start again%' then
      raise exception 'FAIL: refused for the wrong reason: %', v_msg;
    end if;
  end;
  raise notice '6. a lapsed school cannot resume itself for free - ok';
end $t$;

-- 7. AND ONLY LEADERSHIP CAN DO ANY OF IT. Cancelling the software the whole
--    school runs on is not a clerk's decision.
do $t$
declare v_msg text;
begin
  perform set_config('test.uid', (select v::text from ids where k='clerk'), false);
  begin
    perform public.fn_cancel_my_subscription('I resign');
    raise exception 'FAIL: a clerk cancelled the school''s subscription';
  exception when others then
    get stacked diagnostics v_msg = message_text;
    if v_msg like 'FAIL:%' then raise exception '%', v_msg; end if;
  end;
  begin
    perform public.fn_resume_my_subscription();
    raise exception 'FAIL: a clerk restarted the school''s subscription';
  exception when others then
    get stacked diagnostics v_msg = message_text;
    if v_msg like 'FAIL:%' then raise exception '%', v_msg; end if;
  end;
  if has_function_privilege('anon', 'public.fn_cancel_my_subscription(text)', 'execute') then
    raise exception 'FAIL: anon can cancel a subscription';
  end if;
  raise notice '7. cancelling is a leadership decision, and anon cannot - ok';
end $t$;

-- 8. CANCELLING TWICE IS REFUSED WITH A SENTENCE, not silently repeated. A
--    second confirmation screen for something already done reads as a failure.
do $t$
declare v_msg text;
begin
  perform set_config('test.uid', (select v::text from ids where k='own'), false);
  perform public.fn_cancel_my_subscription(null);
  begin
    perform public.fn_cancel_my_subscription(null);
    raise exception 'FAIL: cancelling twice went through';
  exception when others then
    get stacked diagnostics v_msg = message_text;
    if v_msg like 'FAIL:%' then raise exception '%', v_msg; end if;
    if v_msg not like '%already set to end%' then
      raise exception 'FAIL: refused for the wrong reason: %', v_msg;
    end if;
  end;
  raise notice '8. cancelling twice says so rather than repeating itself - ok';
end $t$;

-- 9. THE RENEWAL RUNNER LEAVES A LEAVING SCHOOL ALONE. Billing a school that
--    has told us it is going is the single rudest thing this system could do.
do $t$
declare v_admin uuid := '00000000-0000-0000-0000-0000000000d9';
begin
  insert into auth.users (id, email) values (v_admin, 'op@vendor.test')
    on conflict (id) do nothing;
  insert into public.platform_admins (user_id, email)
    values (v_admin, 'op@vendor.test') on conflict do nothing;
  perform set_config('test.uid', v_admin::text, false);

  update public.subscriptions set period_end = current_date - 1
   where school_id = (select v from ids where k='sch');
  if exists (select 1 from public.fn__renewals_due(current_date)
              where school_id = (select v from ids where k='sch')) then
    raise exception 'FAIL: a school that cancelled is on the list to be invoiced';
  end if;
  raise notice '9. a leaving school is not billed for the period after it leaves - ok';
end $t$;

rollback;
\echo 'LEAVING AND COMING BACK: ALL TESTS PASSED'

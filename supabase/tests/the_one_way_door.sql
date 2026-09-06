-- =============================================================================
-- Cancelling is reversible, and the console stops promising what 0106 undid
--
-- WHY THIS FILE EXISTS
--
-- 0106 shipped two days before this and changed the meaning of one word.
-- fn__licence_permits_use refuses a school whose effective status is 'locked'
-- or 'cancelled', so from that day cancelling a subscription threw every
-- teacher and parent out of the software the same second. That was the
-- decision.
--
-- What nobody changed was the two sentences the operator console prints
-- immediately afterwards, both written by 0079 back when 0026's rule still
-- held:
--
--     cancel : their data is untouched and they keep read and export access
--     archive: their staff can still sign in, read, print and export
--
-- So the console told the operator, in writing, with a tick beside it, that a
-- departing school's teachers could still print - and they could not. That is
-- the sort of defect no test catches, because nothing throws: the words are
-- wrong and the schema is fine. So the words are asserted here.
--
-- The other half is structural. Suspend had unsuspend, archive had unarchive,
-- and cancel had NOTHING, on a dialog whose heading offers the things you can
-- do to a school SHORT of destroying it. The only route back was Activate,
-- which raises an invoice - so undoing a mis-click meant billing a school that
-- had already paid, or editing the subscriptions table by hand.
--
-- Run: psql -v ON_ERROR_STOP=1 -f supabase/tests/the_one_way_door.sql
-- =============================================================================

\set ON_ERROR_STOP on
begin;

create or replace function auth.uid() returns uuid language sql stable as
  $$ select nullif(current_setting('test.uid', true), '')::uuid $$;

create temp table ids (k text primary key, v uuid);

do $seed$
declare
  paid uuid := gen_random_uuid();
  trial uuid := gen_random_uuid();
  lapsed uuid := gen_random_uuid();
  admin_u uuid := '00000000-0000-0000-0000-0000000000e1';
begin
  insert into public.schools (id, name, city) values
    (paid,   'Paid Through June', 'Lahore'),
    (trial,  'Still On Trial',    'Multan'),
    (lapsed, 'Ran Out In March',  'Karachi');

  -- Paid ten months ahead. This is the school a mis-click costs the most.
  insert into public.subscriptions (school_id, plan_code, status, period_start, period_end)
    values (paid, 'starter', 'active', current_date - 60, current_date + 300);
  insert into public.subscriptions (school_id, plan_code, status, trial_ends_on)
    values (trial, 'starter', 'trialing', current_date + 7);
  insert into public.subscriptions (school_id, plan_code, status, period_start, period_end)
    values (lapsed, 'starter', 'active', current_date - 400, current_date - 180);

  insert into auth.users (id, email) values (admin_u, 'operator@vendor.test')
    on conflict (id) do nothing;
  insert into public.platform_admins (user_id, email) values (admin_u, 'operator@vendor.test')
    on conflict do nothing;

  insert into ids values ('paid', paid), ('trial', trial), ('lapsed', lapsed),
    ('admin', admin_u);
end $seed$;

-- 0. THE FIXTURE. Three schools in three different states, all live.
do $t$
begin
  perform set_config('test.uid', (select i.v::text from ids i where i.k='admin'), false);
  if public.fn_effective_status((select v from ids where k='paid'))::text <> 'active' then
    raise exception 'FAIL: the paid school is not active, so nothing below proves anything';
  end if;
  if public.fn_effective_status((select v from ids where k='trial'))::text <> 'trialing' then
    raise exception 'FAIL: the trial school is not trialing';
  end if;
  if public.fn_effective_status((select v from ids where k='lapsed'))::text <> 'locked' then
    raise exception 'FAIL: a licence 180 days expired is not locked';
  end if;
  raise notice '0. fixture: one active, one trialing, one locked - ok';
end $t$;

-- 1. CANCELLING SAYS WHAT IT ACTUALLY DOES NOW.
--
--    The old sentence is asserted as ABSENT rather than the new one as present,
--    because the failure being guarded is somebody restoring 0079's wording
--    without noticing 0106.
do $t$
declare j jsonb;
begin
  perform set_config('test.uid', (select v::text from ids where k='admin'), false);
  j := public.fn_platform_cancel_subscription(
         (select v from ids where k='paid'), 'Moved to a competitor on price');

  if j->>'data' like '%keep read and export access%' then
    raise exception 'FAIL: cancelling still tells the operator the school keeps read '
      'and export access. 0106 closed the app to everyone but the owner, and to '
      'the owner it offers an export screen, not the software: %', j->>'data';
  end if;
  if j->>'data' not like '%closed sign%' then
    raise exception 'FAIL: cancelling does not mention what teachers and parents see: %',
      j->>'data';
  end if;

  -- 2. AND WHAT IT COSTS. Ten months paid for, ended today.
  if coalesce((j->>'days_given_up')::int, 0) < 250 then
    raise exception 'FAIL: cancelling a school paid 300 days ahead reported % days '
      'given up. The operator has to be able to read that number before pressing.',
      j->>'days_given_up';
  end if;
  if j->>'gave_up' is null then
    raise exception 'FAIL: no sentence naming the paid period being thrown away';
  end if;
  if j->>'reversible' is null then
    raise exception 'FAIL: nothing tells the operator this can be undone';
  end if;
  raise notice '1. cancelling describes 0106''s product and prices itself - ok';
end $t$;

-- 3. AND THE SCHOOL IS ACTUALLY SHUT. The console copy is only worth asserting
--    if the behaviour it describes is real.
do $t$
begin
  if public.fn_effective_status((select v from ids where k='paid'))::text <> 'cancelled' then
    raise exception 'FAIL: a cancelled school does not read as cancelled';
  end if;
  raise notice '3. a cancelled school is shut whatever its dates say - ok';
end $t$;

-- 4. THE DOOR BACK EXISTS, AND IT RESTORES THE DATES RATHER THAN INVENTING A
--    LICENCE.
do $t$
declare j jsonb;
begin
  perform set_config('test.uid', (select v::text from ids where k='admin'), false);
  j := public.fn_platform_reinstate_subscription(
         (select v from ids where k='paid'), 'Cancelled the wrong row');

  if (j->>'back_in')::boolean is not true then
    raise exception 'FAIL: reinstating a school paid 300 days ahead left it out: %', j;
  end if;
  if public.fn_effective_status((select v from ids where k='paid'))::text <> 'active' then
    raise exception 'FAIL: reinstated but not active';
  end if;
  if (j->>'invoiced')::boolean is not false then
    raise exception 'FAIL: reinstating raised an invoice. Undoing a mis-click must not '
      'bill a school that has already paid.';
  end if;
  -- Nothing was billed. Checked against the table rather than the return value,
  -- because the return value is the thing under test.
  if exists (select 1 from public.platform_invoices
              where school_id = (select v from ids where k='paid')) then
    raise exception 'FAIL: reinstating wrote an invoice row';
  end if;
  raise notice '4. reinstate puts a paid school back, free - ok';
end $t$;

-- 5. IT CANNOT BE USED TO GIVE THE PRODUCT AWAY. A school whose paid period ran
--    out in March comes back exactly as locked as it was, and the return value
--    says so rather than reporting a success the operator would misread.
do $t$
declare j jsonb;
begin
  perform set_config('test.uid', (select v::text from ids where k='admin'), false);
  perform public.fn_platform_cancel_subscription(
    (select v from ids where k='lapsed'), 'Closed down');
  j := public.fn_platform_reinstate_subscription(
    (select v from ids where k='lapsed'), null);

  if (j->>'back_in')::boolean is not false then
    raise exception 'FAIL: reinstating a licence that expired 180 days ago reported the '
      'school as back in. That is a free renewal behind an undo button: %', j;
  end if;
  if public.fn_effective_status((select v from ids where k='lapsed'))::text <> 'locked' then
    raise exception 'FAIL: a school with a six-month-dead licence is not locked after '
      'reinstatement: %', public.fn_effective_status((select v from ids where k='lapsed'));
  end if;
  if j->>'note' not like '%locked%' then
    raise exception 'FAIL: the note does not say they are still locked: %', j->>'note';
  end if;
  raise notice '5. reinstate never sells anything - ok';
end $t$;

-- 6. A TRIAL COMES BACK AS THE TRIAL IT WAS, not as a new one. 0106 removed
--    trial extension entirely, and an undo button that quietly restarted the
--    clock would put it straight back.
do $t$
declare j jsonb; v_ends date;
begin
  perform set_config('test.uid', (select v::text from ids where k='admin'), false);
  select trial_ends_on into v_ends from public.subscriptions
    where school_id = (select v from ids where k='trial');

  perform public.fn_platform_cancel_subscription(
    (select v from ids where k='trial'), 'Never got started');
  j := public.fn_platform_reinstate_subscription(
    (select v from ids where k='trial'), null);

  if public.fn_effective_status((select v from ids where k='trial'))::text <> 'trialing' then
    raise exception 'FAIL: a trial with a week left did not come back as a trial: %', j;
  end if;
  if (select trial_ends_on from public.subscriptions
        where school_id = (select v from ids where k='trial')) <> v_ends then
    raise exception 'FAIL: reinstating moved the trial end date. That is the +14d button '
      'again, wearing an undo label.';
  end if;
  raise notice '6. a reinstated trial is the same trial - ok';
end $t$;

-- 7. REINSTATE REFUSES ON A SCHOOL THAT IS NOT CANCELLED, AND ON AN ARCHIVED
--    ONE. The second matters: archiving cancels as a side effect, so quietly
--    reinstating an archived school would leave a live licence on a customer
--    who is hidden from the console and off the renewal list.
do $t$
declare v_msg text;
begin
  perform set_config('test.uid', (select v::text from ids where k='admin'), false);
  begin
    perform public.fn_platform_reinstate_subscription((select v from ids where k='paid'), null);
    raise exception 'FAIL: reinstated a school that was never cancelled';
  exception when others then
    get stacked diagnostics v_msg = message_text;
    if v_msg like 'FAIL:%' then raise exception '%', v_msg; end if;
    if v_msg not like '%not cancelled%' then
      raise exception 'FAIL: refused for the wrong reason: %', v_msg;
    end if;
  end;

  perform public.fn_platform_archive_school(
    (select v from ids where k='paid'), 'Left in August');
  begin
    perform public.fn_platform_reinstate_subscription((select v from ids where k='paid'), null);
    raise exception 'FAIL: reinstated an archived school, which would leave a live '
      'licence on a customer nobody can see';
  exception when others then
    get stacked diagnostics v_msg = message_text;
    if v_msg like 'FAIL:%' then raise exception '%', v_msg; end if;
    if v_msg not like '%archived%' then
      raise exception 'FAIL: refused for the wrong reason: %', v_msg;
    end if;
  end;
  raise notice '7. reinstate refuses where it would confuse the books - ok';
end $t$;

-- 8. ARCHIVING TELLS THE TRUTH TOO. Same defect as cancelling, same fix, and
--    the one an operator is most likely to read: archiving is what you do to a
--    school that is leaving, so "their staff can still sign in, read, print and
--    export" was the last thing said before a departing customer's teachers
--    found the door shut.
do $t$
declare j jsonb; v_line text; v_ok boolean := false;
begin
  perform set_config('test.uid', (select v::text from ids where k='admin'), false);
  perform public.fn_platform_unarchive_school((select v from ids where k='paid'));
  perform public.fn_platform_reinstate_subscription((select v from ids where k='paid'), null);
  j := public.fn_platform_archive_school(
    (select v from ids where k='paid'), 'Left in August, keeping their data for a year');

  for v_line in select jsonb_array_elements_text(j->'what_this_did') loop
    if v_line like '%staff can still sign in%' then
      raise exception 'FAIL: archiving still tells the operator the school''s staff can '
        'sign in, read, print and export. Since 0106 they get a closed sign: %', v_line;
    end if;
    if v_line like '%closed sign%' then v_ok := true; end if;
  end loop;
  if not v_ok then
    raise exception 'FAIL: archiving never says what teachers and parents will see: %',
      j->'what_this_did';
  end if;
  if j->>'how_to_reverse' is null then
    raise exception 'FAIL: archiving does not say how to undo it';
  end if;
  raise notice '8. archiving describes 0106''s product - ok';
end $t$;

-- 9. UNARCHIVING POINTS AT THE DOOR THAT NOW EXISTS. 0079 correctly refused to
--    hand back a licence on unarchive, and correctly said so - but the only
--    thing it could offer instead was "activate or renew them", which bills a
--    school archived by mistake.
do $t$
declare j jsonb;
begin
  perform set_config('test.uid', (select v::text from ids where k='admin'), false);
  j := public.fn_platform_unarchive_school((select v from ids where k='paid'));
  if j->>'note' not like '%Reinstate%' then
    raise exception 'FAIL: unarchiving does not mention reinstating, so the only route '
      'it offers a school archived by mistake is an invoice: %', j->>'note';
  end if;
  raise notice '9. unarchive offers the free route back - ok';
end $t$;

-- 10. AND NONE OF IT IS REACHABLE BY ANYBODY ELSE.
do $t$
declare v_msg text; v_outsider uuid := '00000000-0000-0000-0000-0000000000e9';
begin
  insert into auth.users (id, email) values (v_outsider, 'nobody@example.test')
    on conflict (id) do nothing;
  perform set_config('test.uid', v_outsider::text, false);
  begin
    perform public.fn_platform_reinstate_subscription((select v from ids where k='lapsed'), null);
    raise exception 'FAIL: someone who is not a platform admin reinstated a subscription';
  exception when others then
    get stacked diagnostics v_msg = message_text;
    if v_msg like 'FAIL:%' then raise exception '%', v_msg; end if;
    if v_msg <> 'Not permitted' then
      raise exception 'FAIL: refused for the wrong reason: %', v_msg;
    end if;
  end;
  raise notice '10. reinstate is platform-admin only - ok';
end $t$;

rollback;
\echo 'THE ONE WAY DOOR: ALL TESTS PASSED'

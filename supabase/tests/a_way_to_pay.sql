-- =============================================================================
-- A card number cannot get into this database, and a school is told the truth
-- about what happens next
--
-- WHY THIS FILE EXISTS
--
-- Two properties, and one of them is the highest-consequence thing in the
-- product.
--
-- 1. THE CREDENTIAL IS UNREACHABLE FROM THE APPLICATION.
--
-- payment_methods holds what a screen needs to say "Visa ending 4242". The
-- gateway token - the thing that can actually move money - is in
-- payment_method_tokens, which has RLS on with NO POLICIES and no grants. In
-- Postgres that denies every row to every non-owner role whatever the grants
-- say, so a mistaken policy on the display table cannot leak it, because it is
-- not in the display table.
--
-- Asserted here rather than trusted, because "we were careful" is not a
-- boundary. Also asserted: the tripwire constraints that refuse PAN-shaped text
-- in the free-text fields, which is how a card number actually reaches a
-- database - somebody types it into a notes box.
--
-- 2. A SCHOOL IS NEVER TOLD RENEWAL IS AUTOMATIC WHEN IT IS NOT.
--
-- Under a twelfth of Pakistani adults hold a card, so most schools will pay by
-- transfer for years. The failure mode is not technical: it is a school that
-- has "set up payment", believes it is on autopilot, and is locked out having
-- done everything it was asked. auto_renew is false unless there is something
-- to charge, the schema refuses the other combination, and the sentence the
-- school reads says which it is.
--
-- Run: psql -v ON_ERROR_STOP=1 -f supabase/tests/a_way_to_pay.sql
-- =============================================================================

\set ON_ERROR_STOP on
begin;

create or replace function auth.uid() returns uuid language sql stable as
  $$ select nullif(current_setting('test.uid', true), '')::uuid $$;

create temp table ids (k text primary key, v uuid);

do $seed$
declare
  sch uuid := gen_random_uuid(); other uuid := gen_random_uuid();
  own_u uuid := '00000000-0000-0000-0000-0000000000b1';
  clerk_u uuid := '00000000-0000-0000-0000-0000000000b2';
  own_o uuid := '00000000-0000-0000-0000-0000000000b3';
begin
  insert into public.schools (id, name, city) values
    (sch, 'Al Qalam School', 'Lahore'), (other, 'Someone Else', 'Karachi');
  insert into public.subscriptions (school_id, plan_code, status, trial_ends_on, term_months)
    values (sch, 'starter', 'trialing', current_date + 14, 12);
  insert into public.subscriptions (school_id, plan_code, status, trial_ends_on)
    values (other, 'starter', 'trialing', current_date + 14);

  insert into auth.users (id, email) values
    (own_u, 'owner@alqalam.test'), (clerk_u, 'clerk@alqalam.test'),
    (own_o, 'owner@other.test') on conflict (id) do nothing;

  alter table public.profiles disable trigger user;
  insert into public.profiles (id, school_id, full_name, role, active) values
    (own_u, sch, 'Owner', 'owner', true),
    (clerk_u, sch, 'Clerk', 'admin_clerk', true),
    (own_o, other, 'Other Owner', 'owner', true);
  alter table public.profiles enable trigger user;

  insert into ids values ('sch', sch), ('other', other),
    ('own', own_u), ('clerk', clerk_u), ('own_o', own_o);
end $seed$;

-- 1. THE TOKEN TABLE IS SHUT. RLS on, no policies, nothing granted. Checked
--    three ways because each could be undone independently by a later migration.
do $t$
declare v_policies int; v_rls boolean; v_forced boolean;
begin
  select count(*) into v_policies from pg_policies
   where schemaname = 'public' and tablename = 'payment_method_tokens';
  if v_policies <> 0 then
    raise exception 'FAIL: payment_method_tokens has % policy(ies). It must have '
      'NONE: a policy is the only thing that could let an application role read '
      'a gateway credential.', v_policies;
  end if;
  select relrowsecurity, relforcerowsecurity into v_rls, v_forced
    from pg_class where oid = 'public.payment_method_tokens'::regclass;
  if not v_rls or not v_forced then
    raise exception 'FAIL: row level security is not both enabled and forced on '
      'payment_method_tokens (enabled=%, forced=%)', v_rls, v_forced;
  end if;
  if has_table_privilege('authenticated', 'public.payment_method_tokens', 'select')
     or has_table_privilege('anon', 'public.payment_method_tokens', 'select') then
    raise exception 'FAIL: an application role has SELECT on the credential table';
  end if;
  raise notice '1. the credential table is closed to every application role - ok';
  -- And read AS the application role, because a grant check alone would pass on
  -- a table that had a permissive policy and a grant added by a later
  -- migration. This is the assertion that survives somebody being helpful.
  declare v_leaked int;
  begin
    set local role authenticated;
    begin
      select count(*) into v_leaked from public.payment_method_tokens;
      reset role;
      raise exception 'FAIL: `authenticated` read % row(s) from the credential table',
        v_leaked;
    exception when insufficient_privilege then
      reset role;
    end;
  end;
  raise notice '1b. and reading it as `authenticated` is refused outright - ok';
end $t$;

-- 2. AND A CARD NUMBER IS REFUSED even by the table that is supposed to hold a
--    token. The last place this can be stopped.
do $t$
declare v_pm uuid; v_msg text;
begin
  insert into public.payment_methods (school_id, kind, provider, brand, last4)
  values ((select v from ids where k='sch'), 'card', 'safepay', 'visa', '4242')
  returning id into v_pm;
  begin
    insert into public.payment_method_tokens (payment_method_id, school_id, provider, provider_token)
    values (v_pm, (select v from ids where k='sch'), 'safepay', '4242424242424242');
    raise exception 'FAIL: a sixteen digit card number was stored as a "token"';
  exception when others then
    get stacked diagnostics v_msg = message_text;
    if v_msg like 'FAIL:%' then raise exception '%', v_msg; end if;
  end;
  -- A real token goes in without complaint.
  insert into public.payment_method_tokens (payment_method_id, school_id, provider, provider_token)
  values (v_pm, (select v from ids where k='sch'), 'safepay', 'tok_live_29fj3o2ifj');
  delete from public.payment_methods where id = v_pm;
  raise notice '2. a PAN cannot be stored even in the token column - ok';
end $t$;

-- 3. AND NOT IN A FREE-TEXT FIELD EITHER, which is how it really happens.
--
--    EVERY SPELLING, which is the part the first draft of this got wrong. The
--    constraint tested the raw text for twelve consecutive digits, so it caught
--    "4242424242424242" and waved through "4242 4242 4242 4242" - the way a
--    card number is written on the card. Punctuation is stripped before the
--    check now, and every one of these is refused.
do $t$
declare v_try text; v_accepted text[] := '{}';
begin
  perform set_config('test.uid', (select v::text from ids where k='own'), false);
  foreach v_try in array array[
    'My card 4242424242424242',
    '4242 4242 4242 4242',
    '4242-4242-4242-4242',
    '5123 4567 8901 2346'
  ] loop
    begin
      perform public.fn_set_manual_payment_method(v_try, null);
      v_accepted := v_accepted || v_try;
    exception when others then null;
    end;
  end loop;
  if array_length(v_accepted, 1) > 0 then
    raise exception 'FAIL: these were accepted into a free-text payment field: %. '
      'A card number reaches a database because somebody types it into a notes '
      'box, so the notes box has to refuse it however it is punctuated.',
      array_to_string(v_accepted, ' | ');
  end if;
  raise notice '3. a pasted card number is refused however it is punctuated - ok';
end $t$;

-- 4. A SCHOOL SEES ITS OWN METHODS AND NOBODY ELSE'S.
--
--    `set local role authenticated` matters here and the first draft of this
--    file did without it. RLS does not apply to a superuser, so every SELECT in
--    this suite ran with the policies switched off - and the cross-school
--    assertion below would have passed for the wrong reason on a table with no
--    policies at all. It is the same trap enquiries.sql documents at line 630.
do $t$
declare v_mine int; v_theirs int;
begin
  perform set_config('test.uid', (select v::text from ids where k='own'), false);
  perform public.fn_set_manual_payment_method('HBL account', 'Transfer from HBL 1234');

  set local role authenticated;
  select count(*) into v_mine from public.payment_methods;
  reset role;
  if v_mine <> 1 then
    raise exception 'FAIL: the owner sees % of their own payment methods, not 1', v_mine;
  end if;

  perform set_config('test.uid', (select v::text from ids where k='own_o'), false);
  set local role authenticated;
  select count(*) into v_theirs from public.payment_methods;
  reset role;
  if v_theirs <> 0 then
    raise exception 'FAIL: another school''s owner can see % payment method(s)', v_theirs;
  end if;
  raise notice '4. payment methods are scoped to the school - ok';
end $t$;

-- 5. AND A CLERK CANNOT SEE OR CHANGE THEM. How the school pays is a
--    governance fact for whoever signs the cheques, on the same reasoning 0074
--    gives for support visits.
do $t$
declare v_n int; v_msg text;
begin
  perform set_config('test.uid', (select v::text from ids where k='clerk'), false);
  set local role authenticated;
  select count(*) into v_n from public.payment_methods;
  reset role;
  if v_n <> 0 then
    raise exception 'FAIL: a clerk can read the school''s payment methods';
  end if;
  begin
    perform public.fn_set_manual_payment_method('Clerk''s own account', null);
    raise exception 'FAIL: a clerk changed how the school pays';
  exception when others then
    get stacked diagnostics v_msg = message_text;
    if v_msg like 'FAIL:%' then raise exception '%', v_msg; end if;
  end;
  begin
    perform public.fn_my_next_payment();
    raise exception 'FAIL: a clerk can read the subscription';
  exception when others then
    get stacked diagnostics v_msg = message_text;
    if v_msg like 'FAIL:%' then raise exception '%', v_msg; end if;
  end;
  raise notice '5. a clerk is not shown the subscription or the payment method - ok';
end $t$;

-- 6. AUTO-RENEWAL WITH NOTHING TO CHARGE IS REFUSED BY THE SCHEMA.
--    The state that silently stops collecting money.
do $t$
declare v_msg text;
begin
  begin
    update public.subscriptions set auto_renew = true, payment_method_id = null
     where school_id = (select v from ids where k='sch');
    raise exception 'FAIL: auto_renew was set true with no payment method. Renewal '
      'would run every month, find nothing to charge, and quietly collect nothing.';
  exception when others then
    get stacked diagnostics v_msg = message_text;
    if v_msg like 'FAIL:%' then raise exception '%', v_msg; end if;
  end;
  raise notice '6. auto-renewal requires something to charge - ok';
end $t$;

-- 7. THE MANUAL PATH SAYS SO IN WORDS.
--
--    The whole failure mode of this path is a school believing it is on
--    autopilot. Asserted on the sentence, because the sentence is the feature.
do $t$
declare j jsonb;
begin
  perform set_config('test.uid', (select v::text from ids where k='own'), false);
  j := public.fn_set_manual_payment_method('Easypaisa', 'From 0300-1234567');
  if (j->>'auto_renew')::boolean is not false then
    raise exception 'FAIL: a manual method reported auto_renew true';
  end if;
  if j->>'note' not like '%Nothing is charged automatically%' then
    raise exception 'FAIL: the manual path does not say that nothing is charged '
      'automatically: %', j->>'note';
  end if;
  raise notice '7. the manual path states that nothing is charged automatically - ok';
end $t$;

-- 8. ONE DEFAULT PER SCHOOL, enforced by an index rather than by hope. Two
--    defaults is the state that charges the wrong card.
do $t$
declare v_n int;
begin
  perform set_config('test.uid', (select v::text from ids where k='own'), false);
  perform public.fn_set_manual_payment_method('Bank Alfalah', null);
  select count(*) into v_n from public.payment_methods
   where school_id = (select v from ids where k='sch') and is_default and status = 'active';
  if v_n <> 1 then
    raise exception 'FAIL: % active default payment methods after three were added', v_n;
  end if;
  raise notice '8. exactly one default survives, whatever is added - ok';
end $t$;

-- 9. THE SENTENCE THE SCHOOL READS, in a trial with no card.
do $t$
declare j jsonb;
begin
  perform set_config('test.uid', (select v::text from ids where k='own'), false);
  j := public.fn_my_next_payment();
  if (j->>'in_trial')::boolean is not true then
    raise exception 'FAIL: a trialing school does not report itself in a trial';
  end if;
  if (j->>'next_charge_on')::date <> current_date + 14 then
    raise exception 'FAIL: the next charge is on % and the trial ends on %',
      j->>'next_charge_on', current_date + 14;
  end if;
  -- Starter, twelve months, at the 0111 price list.
  if (j->>'next_charge_amount')::numeric <> public.fn__plan_price('starter', 12) then
    raise exception 'FAIL: the amount quoted to the school is Rs % and the price '
      'list says Rs %', j->>'next_charge_amount', public.fn__plan_price('starter', 12);
  end if;
  if j->>'sentence' not like '%charged nothing today%' then
    raise exception 'FAIL: the trial sentence does not say the school is charged '
      'nothing today: %', j->>'sentence';
  end if;
  if j->>'sentence' like '%you will be charged%' then
    raise exception 'FAIL: a school with NO card is told it "will be charged". '
      'Nothing can charge it. The sentence has to say the money is due, not '
      'that it will be taken: %', j->>'sentence';
  end if;
  raise notice '9. the trial sentence names the date and the amount, and does '
    'not promise a charge nothing can make - ok';
end $t$;

-- 10. CHOOSING A TERM CHANGES THE AMOUNT, AND ONLY THE THREE SOLD TERMS ARE
--     OFFERED to a school choosing for itself.
do $t$
declare j jsonb; v_msg text;
begin
  perform set_config('test.uid', (select v::text from ids where k='own'), false);
  j := public.fn_choose_term(1);
  if (j->'next'->>'next_charge_amount')::numeric <> public.fn__plan_price('starter', 1) then
    raise exception 'FAIL: choosing one month did not change the amount due';
  end if;
  j := public.fn_choose_term(3);
  if (j->'next'->>'next_charge_amount')::numeric <> public.fn__plan_price('starter', 3) then
    raise exception 'FAIL: choosing three months did not price it at the quarterly rate';
  end if;
  begin
    perform public.fn_choose_term(7);
    raise exception 'FAIL: a school chose a term that is not on the price list';
  exception when others then
    get stacked diagnostics v_msg = message_text;
    if v_msg like 'FAIL:%' then raise exception '%', v_msg; end if;
  end;
  raise notice '10. a school picks from the price list, and the amount follows - ok';
end $t$;

-- 11. CANCELLING AT PERIOD END MEANS NO NEXT CHARGE, and says so rather than
--     quoting Rs 0, which a screen renders as "free".
do $t$
declare j jsonb;
begin
  update public.subscriptions
     set status = 'active', period_start = current_date - 10,
         period_end = current_date + 20, trial_ends_on = null,
         cancel_at_period_end = true
   where school_id = (select v from ids where k='sch');
  perform set_config('test.uid', (select v::text from ids where k='own'), false);
  j := public.fn_my_next_payment();
  if j->>'next_charge_on' is not null then
    raise exception 'FAIL: a subscription cancelled at period end still has a next charge';
  end if;
  if j->>'next_charge_amount' is not null then
    raise exception 'FAIL: an amount is quoted for a charge that will not happen';
  end if;
  if j->>'sentence' not like '%ends on%' or j->>'sentence' not like '%Nothing further%' then
    raise exception 'FAIL: the ending is not stated plainly: %', j->>'sentence';
  end if;
  raise notice '11. a cancelled subscription has an ending, not a charge of zero - ok';
end $t$;

-- 12. AND A SUSPENDED SCHOOL IS NOT BILLED. We stopped them; asking for money
--     for the period we switched off is indefensible.
do $t$
begin
  update public.subscriptions
     set cancel_at_period_end = false, suspended_at = now(),
         suspend_reason = 'Testing the suspension path'
   where school_id = (select v from ids where k='sch');
  if public.fn__next_charge_on((select v from ids where k='sch')) is not null then
    raise exception 'FAIL: a school we suspended is still scheduled to be charged';
  end if;
  raise notice '12. a school we suspended is not charged - ok';
end $t$;

rollback;
\echo 'A WAY TO PAY: ALL TESTS PASSED'

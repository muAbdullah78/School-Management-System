-- =============================================================================
-- The bill goes out on the day it is due, and running it twice is safe
--
-- WHY THIS FILE EXISTS
--
-- Every renewal invoice in this product existed because somebody opened the
-- console and pressed a button. The failure mode was not a bug, it was a
-- Tuesday: the list is not opened, a school's period ends with no invoice ever
-- raised, and it lapses into grace and locks having never been asked for money.
--
-- The runner fixes that, and a batch job that moves money has to be held to
-- four properties, each of which is a way it could quietly do harm:
--
--   1. RUNNING IT TWICE MUST NOT BILL TWICE. The commonest thing anybody does
--      with a new button is press it again.
--   2. ONE SCHOOL'S FAILURE MUST NOT ABORT THE RUN. Without a per-school
--      savepoint, one school over its student limit stops every school after it
--      in the loop from being billed, and the run reports a success for the
--      ones it never reached.
--   3. IT MUST NOT INVENT A CUSTOMER. A trial that ends having never recorded a
--      way to pay has agreed to nothing. Billing it manufactures a receivable
--      against a stranger and puts a fictional number in the outstanding total
--      the whole console is built on.
--   4. IT MUST NOT BILL FOR A PERIOD WE SWITCHED OFF. A suspended or cancelled
--      school owes nothing for the time it could not use the software.
--
-- Run: psql -v ON_ERROR_STOP=1 -f supabase/tests/the_renewal_run.sql
-- =============================================================================

\set ON_ERROR_STOP on
begin;

create or replace function auth.uid() returns uuid language sql stable as
  $$ select nullif(current_setting('test.uid', true), '')::uuid $$;

create temp table ids (k text primary key, v uuid);

do $seed$
declare
  admin_u uuid := '00000000-0000-0000-0000-0000000000a1';
  due uuid := gen_random_uuid();         -- active, period ended yesterday
  early uuid := gen_random_uuid();       -- active, period ends in a month
  trial_yes uuid := gen_random_uuid();   -- trial over, told us how they will pay
  trial_no uuid := gen_random_uuid();    -- trial over, never said
  susp uuid := gen_random_uuid();        -- we switched them off
  cancelled uuid := gen_random_uuid();
  ending uuid := gen_random_uuid();      -- cancelling at period end
  big uuid := gen_random_uuid();         -- outgrew its plan
  own_y uuid := '00000000-0000-0000-0000-0000000000a2';
  v_class uuid;
begin
  insert into auth.users (id, email) values
    (admin_u, 'operator@vendor.test'), (own_y, 'owner@trialyes.test')
    on conflict (id) do nothing;
  insert into public.platform_admins (user_id, email)
    values (admin_u, 'operator@vendor.test') on conflict do nothing;

  insert into public.schools (id, name) values
    (due, 'Due Yesterday'), (early, 'Not Due Yet'),
    (trial_yes, 'Trial Said Yes'), (trial_no, 'Trial Said Nothing'),
    (susp, 'Suspended School'), (cancelled, 'Cancelled School'),
    (ending, 'Ending At Period End'), (big, 'Outgrew Its Plan');

  insert into public.subscriptions (school_id, plan_code, status, cycle,
                                    period_start, period_end, term_months)
  values
    (due,       'starter', 'active', 'monthly', current_date - 31, current_date - 1, 1),
    (early,     'starter', 'active', 'yearly',  current_date - 10, current_date + 30, 12),
    (ending,    'starter', 'active', 'monthly', current_date - 31, current_date - 1, 1),
    (big,       'starter', 'active', 'monthly', current_date - 31, current_date - 1, 1),
    (cancelled, 'starter', 'cancelled', 'monthly', current_date - 31, current_date - 1, 1);
  insert into public.subscriptions (school_id, plan_code, status, trial_ends_on, term_months)
  values (trial_yes, 'starter', 'trialing', current_date - 1, 12),
         (trial_no,  'starter', 'trialing', current_date - 1, 12);
  insert into public.subscriptions (school_id, plan_code, status, cycle,
                                    period_start, period_end, term_months,
                                    suspended_at, suspend_reason)
  values (susp, 'starter', 'active', 'monthly', current_date - 31, current_date - 1, 1,
          now(), 'Testing that we do not bill for time we switched off');

  update public.subscriptions set cancel_at_period_end = true where school_id = ending;

  -- One school genuinely over Starter's limit plus its margin, so
  -- fn_activate_subscription's own refusal is what the runner meets.
  --
  -- SEEDED BEFORE test.uid IS SET TO ANY OWNER. enforce_school_id refuses a row
  -- addressed to one school while the caller belongs to another, which is
  -- exactly right and exactly what the first draft of this fixture tripped over
  -- by setting the caller first and inserting afterwards.
  insert into public.academic_sessions (school_id, name, starts_on, ends_on, is_current)
    values (big, '2026', current_date - 60, current_date + 300, true);
  insert into public.classes (school_id, name, level_order)
    values (big, 'One', 1) returning id into v_class;
  -- ENROLLED, not merely admitted. fn_count_students joins students AND
  -- enrollments, so 190 student rows with no enrolment count as zero - the
  -- first draft of this fixture did exactly that, and the "over its plan"
  -- school sailed through the runner as a comfortable renewal.
  declare v_sess uuid;
  begin
    select id into v_sess from public.academic_sessions where school_id = big;
    with ins as (
      insert into public.students (school_id, full_name, father_name, status)
      select big, 'Child ' || g, 'F', 'active'
        from generate_series(1, (select (student_limit * 1.1)::int + 25
                                   from public.plans where code = 'starter')) g
      returning id, full_name
    )
    insert into public.enrollments (school_id, student_id, session_id, class_id, roll_no, status)
    select big, ins.id, v_sess, v_class, ins.full_name, 'active' from ins;
  end;
  perform public.fn_refresh_student_count(big);

  -- The trial that said yes gets an owner and a recorded payment method, which
  -- is what "said yes" means here. Last, because it is the only step that needs
  -- a caller identity.
  alter table public.profiles disable trigger user;
  insert into public.profiles (id, school_id, full_name, role, active)
    values (own_y, trial_yes, 'Owner', 'owner', true);
  alter table public.profiles enable trigger user;
  perform set_config('test.uid', own_y::text, false);
  perform public.fn_set_manual_payment_method('HBL account', null);
  perform set_config('test.uid', '', false);

  insert into ids values ('admin', admin_u), ('due', due), ('early', early),
    ('trial_yes', trial_yes), ('trial_no', trial_no), ('susp', susp),
    ('cancelled', cancelled), ('ending', ending), ('big', big);
end $seed$;

-- 1. WHO IS DUE, and just as importantly who is not.
do $t$
declare v_names text;
begin
  perform set_config('test.uid', (select i.v::text from ids i where i.k='admin'), false);
  select string_agg(school_name, ', ' order by school_name) into v_names
    from public.fn__renewals_due(current_date);
  if v_names is distinct from 'Due Yesterday, Outgrew Its Plan, Trial Said Nothing, Trial Said Yes' then
    raise exception 'FAIL: the due list is "%". Expected exactly the four whose '
      'payment has fallen due: the two ended trials, the ended month, and the '
      'school that outgrew its plan. A school not due yet, one we suspended, one '
      'cancelled and one ending at period end must all be absent.', v_names;
  end if;
  raise notice '1. only the schools actually due are picked up - ok';
end $t$;

-- 2. A DRY RUN CHANGES NOTHING. The default, because a money-moving batch job
--    whose default is "go" is one somebody runs by accident while exploring.
do $t$
declare j jsonb; v_before int; v_after int;
begin
  perform set_config('test.uid', (select i.v::text from ids i where i.k='admin'), false);
  select count(*) into v_before from public.platform_invoices;
  j := public.fn_platform_run_renewals();          -- no arguments at all
  select count(*) into v_after from public.platform_invoices;

  if (j->>'dry_run')::boolean is not true then
    raise exception 'FAIL: calling the runner with no arguments was NOT a dry run';
  end if;
  if v_after <> v_before then
    raise exception 'FAIL: a dry run raised % invoice(s)', v_after - v_before;
  end if;
  if (j->>'invoiced')::int <> 0 then
    raise exception 'FAIL: a dry run reported % invoiced', j->>'invoiced';
  end if;
  if j->>'note' not like '%Nothing was changed%' then
    raise exception 'FAIL: a dry run does not say it changed nothing: %', j->>'note';
  end if;
  raise notice '2. the default is a dry run, and it changes nothing - ok';
end $t$;

-- 3. THE REAL RUN BILLS THE RIGHT SCHOOLS AND LEAVES THE REST ALONE.
do $t$
declare j jsonb; v_out text; v_run uuid;
begin
  perform set_config('test.uid', (select i.v::text from ids i where i.k='admin'), false);
  j := public.fn_platform_run_renewals(false);
  -- THE RUN JUST MADE, not "the latest attempt for this school". The dry run
  -- above also wrote an attempt row per school, so an unqualified lookup finds
  -- "would_invoice" and the first draft of this file failed on exactly that.
  v_run := (j->>'run_id')::uuid;

  -- The plain renewal.
  select a.outcome into v_out from public.billing_attempts a
   where a.run_id = v_run
     and a.school_id = (select i.v from ids i where i.k='due');
  if v_out <> 'invoiced' then
    raise exception 'FAIL: a school whose month ended yesterday was not invoiced (%)', v_out;
  end if;

  -- The trial that recorded a way to pay: a customer, and billed.
  select a.outcome into v_out from public.billing_attempts a
   where a.run_id = v_run
     and a.school_id = (select i.v from ids i where i.k='trial_yes');
  if v_out <> 'invoiced' then
    raise exception 'FAIL: a trial that told us how it would pay was not invoiced (%)', v_out;
  end if;

  -- THE ONE THAT MATTERS. A trial that never said yes has agreed to nothing.
  select a.outcome into v_out from public.billing_attempts a
   where a.run_id = v_run
     and a.school_id = (select i.v from ids i where i.k='trial_no');
  if v_out <> 'trial_never_said_yes' then
    raise exception 'FAIL: a trial that never recorded a way to pay was treated as '
      '"%". Billing it invents a receivable against somebody who signed up to '
      'look around.', v_out;
  end if;

  -- Outgrown its plan: left for a person, not renewed onto the wrong plan.
  select a.outcome into v_out from public.billing_attempts a
   where a.run_id = v_run
     and a.school_id = (select i.v from ids i where i.k='big');
  if v_out <> 'needs_decision' then
    raise exception 'FAIL: a school over its student limit was handled as "%". '
      'fn_activate_subscription refuses that on purpose and the runner must not '
      'talk it round.', v_out;
  end if;

  raise notice '3. the right schools are billed and the rest are recorded, not silently skipped - ok';
end $t$;

-- 4. ONE SCHOOL'S FAILURE DID NOT ABORT THE RUN.
--
--    The school that outgrew its plan raises inside the loop. Without a
--    per-school savepoint it would stop every school after it in name order -
--    "Trial Said Nothing" and "Trial Said Yes" both sort after "Outgrew Its
--    Plan" - and the run would report success for schools it never reached.
do $t$
declare v_n int;
begin
  select count(*) into v_n from public.billing_attempts a
    join public.billing_runs r on r.id = a.run_id
   where not r.dry_run;
  if v_n <> 4 then
    raise exception 'FAIL: the real run recorded % attempt(s), not 4. A raise '
      'inside the loop aborted it and the schools after the failure were never '
      'considered.', v_n;
  end if;
  if exists (select 1 from public.billing_attempts where outcome = 'failed') then
    raise exception 'FAIL: something failed outright: %',
      (select message from public.billing_attempts where outcome = 'failed' limit 1);
  end if;
  raise notice '4. a refusal for one school did not stop the others - ok';
end $t$;

-- 5. RUNNING IT AGAIN THE SAME DAY BILLS NOBODY TWICE.
--
--    The commonest thing anybody does with a new button is press it again.
do $t$
declare j jsonb; v_before numeric; v_after numeric; v_out text;
begin
  perform set_config('test.uid', (select i.v::text from ids i where i.k='admin'), false);
  select coalesce(sum(net_total), 0) into v_before
    from public.platform_invoices where voided_at is null;

  j := public.fn_platform_run_renewals(false);

  select coalesce(sum(net_total), 0) into v_after
    from public.platform_invoices where voided_at is null;
  if v_after <> v_before then
    raise exception 'FAIL: a second run the same day billed another Rs %. '
      'Re-running has to be free.', v_after - v_before;
  end if;
  if (j->>'invoiced')::int <> 0 then
    raise exception 'FAIL: the second run reported % invoiced', j->>'invoiced';
  end if;
  -- And it says WHY rather than silently doing nothing, because "it did
  -- nothing" and "it was already done" look identical from the outside.
  select a.outcome into v_out from public.billing_attempts a
   where a.run_id = (j->>'run_id')::uuid
     and a.school_id = (select i.v from ids i where i.k='due');
  if v_out <> 'already_invoiced' then
    raise exception 'FAIL: the second run recorded "%" for a school it had already '
      'billed, rather than saying so', v_out;
  end if;
  raise notice '5. running it twice bills nobody twice, and says why - ok';
end $t$;

-- 6. AND THE PERIOD ACTUALLY MOVED, so the school is not immediately due again.
do $t$
declare v_end date; v_term int;
begin
  select period_end, term_months into v_end, v_term
    from public.subscriptions where school_id = (select i.v from ids i where i.k='due');
  if v_end <= current_date then
    raise exception 'FAIL: the invoice was raised but the period still ends on %, '
      'so the school is due again immediately and the next run would bill it '
      'for the period after that.', v_end;
  end if;
  raise notice '6. the paid-through date moved with the invoice - ok';
end $t$;

-- 7. NOBODY BUT THE OPERATOR CAN RUN IT. A school triggering the billing run
--    for the whole platform is not a hypothetical worth leaving open.
do $t$
declare v_msg text;
begin
  perform set_config('test.uid', (select i.v::text from ids i where i.k='trial_yes'), false);
  perform set_config('test.uid', '00000000-0000-0000-0000-0000000000a2', false);
  begin
    perform public.fn_platform_run_renewals(false);
    raise exception 'FAIL: a school owner ran the platform billing job';
  exception when others then
    get stacked diagnostics v_msg = message_text;
    if v_msg like 'FAIL:%' then raise exception '%', v_msg; end if;
    if v_msg <> 'Not permitted' then
      raise exception 'FAIL: refused for the wrong reason: %', v_msg;
    end if;
  end;
  if has_function_privilege('anon', 'public.fn_platform_run_renewals(boolean, date)', 'execute') then
    raise exception 'FAIL: anon can execute the billing run';
  end if;
  raise notice '7. only a platform admin can run it - ok';
end $t$;

-- 8. AND EVERY RUN IS ANSWERABLE AFTERWARDS. A batch job whose only output is
--    the screen of whoever pressed it is a job nobody can audit.
do $t$
declare j jsonb;
begin
  perform set_config('test.uid', (select i.v::text from ids i where i.k='admin'), false);
  j := public.fn_platform_renewal_runs(10);
  if jsonb_array_length(j) < 3 then
    raise exception 'FAIL: only % run(s) are readable after the fact',
      jsonb_array_length(j);
  end if;
  if (j->0->>'triggered_by_email') is distinct from 'operator@vendor.test' then
    raise exception 'FAIL: the run does not record who triggered it (%)',
      j->0->>'triggered_by_email';
  end if;
  if jsonb_array_length(j->0->'attempts') = 0 then
    raise exception 'FAIL: the run history carries no per-school detail, so '
      '"why was this school not billed" has no answer';
  end if;
  raise notice '8. every run records who ran it and what it did to each school - ok';
end $t$;

rollback;
\echo 'THE RENEWAL RUN: ALL TESTS PASSED'

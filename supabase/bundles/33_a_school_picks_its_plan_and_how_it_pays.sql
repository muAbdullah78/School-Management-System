-- =============================================================================
-- GENERATED FILE — DO NOT EDIT.
-- Built from supabase/migrations/ by supabase/build-bundles.sh
--
-- Paste this whole file into the Supabase SQL Editor and press Run.
-- Run the bundles in order, one at a time, waiting for each to finish.
-- =============================================================================


-- ─────────────────────────────────────────────────────────────────────────
-- 0127_a_school_picks_its_plan_and_how_it_pays.sql
-- ─────────────────────────────────────────────────────────────────────────
-- =============================================================================
-- 0127 - Nobody was ever asked which plan they were on, or how they wanted to
--        pay, and three places disagreed about what the answer was
--
-- REPORTED BY THE VENDOR, looking at Settings on a school he had just created:
-- "a starter plan is by default, annual payment showing in the settings. When
-- they create a school the system should give them a choice to pick a plan and
-- pick how they will want to continue: monthly, quarterly or yearly."
--
-- He is right, and pulling on it found three separate faults, two of which are
-- about money and are wrong for real schools today.
--
-- -----------------------------------------------------------------------------
-- FAULT 1. THE CHOICE IS NOT OFFERED, AND THE DEFAULT IS SILENT.
--
-- fn_signup_school, in full, on the subscription it creates:
--
--     insert into public.subscriptions (school_id, plan_code, status, trial_ends_on)
--     values (v_id, 'starter', 'trialing', current_date + 14);
--
-- Plan `starter`, hardcoded. `cycle` left to the column default of `yearly`.
-- `term_months` left to the column default of 12. So every school in the
-- console is on Starter paying annually whatever was actually agreed on the
-- phone, and Settings quotes them a yearly figure they never chose. It is not
-- a display bug: fn_my_next_payment prices the next charge from term_months,
-- so a school that agreed Rs 2,000 a month is shown Rs 20,000 and told that is
-- what is due when the trial ends.
--
-- -----------------------------------------------------------------------------
-- FAULT 2. QUARTERLY IS PRICED AND CANNOT BE RECORDED.
--
-- plans.price_quarterly exists, is populated for all three sold plans, is
-- charged by fn__plan_price and is offered to the school by
-- fn_my_next_payment's three terms. And:
--
--     select enumlabel from pg_enum ... where typname = 'billing_cycle'
--       monthly
--       yearly
--
-- There is no `quarterly`. So fn_activate_subscription writes
-- `case when p_months >= 12 then 'yearly' else 'monthly' end`, and a school
-- that pays every three months gets an invoice, a console entry and a credit
-- note that all say monthly. This migration adds the value and gives the rule
-- one home, public.fn__cycle_for_months, so the two writers cannot drift.
--
-- -----------------------------------------------------------------------------
-- FAULT 3, AND THIS ONE IS A WRONG NUMBER SENT TO A SCHOOL. Two places work
-- out how many months the next invoice covers by GUESSING FROM THE CYCLE:
--
--     fn_platform_due_soon        case when b.cycle = 'yearly' then 12 else 1 end
--     fn_platform_renewal_message case when v.cycle = 'yearly' then 12 else 1 end
--
-- The invoice itself is not built that way. fn__renewals_due, which is what
-- actually creates it, prices `fn__plan_price(sub.plan_code, sub.term_months)`.
-- And fn_activate_subscription never wrote term_months at all, so the two
-- diverge the moment a school uses the term chooser in Settings:
--
--   cycle      term_months   quoted      invoiced    the school is told
--   yearly              12   12 months   12 months   correctly
--   monthly              3    1 month     3 months   a THIRD of the truth
--   monthly             12    1 month    12 months   a TWELFTH of the truth
--   yearly               1   12 months    1 month    TWELVE TIMES the truth
--
-- fn_platform_due_soon's own comment says "priced on the plan they SHOULD be on
-- and the cycle they are on now, so the number in the reminder is the number on
-- the invoice". That is the right intention and the code does not do it. Both
-- now read term_months, which is the column the invoice is built from, and
-- fn_activate_subscription sets term_months to the months it just invoiced so
-- there is one answer to "what term is this school on" instead of two.
--
-- -----------------------------------------------------------------------------
-- WHAT DOES NOT CHANGE, and it was checked rather than assumed:
--
--   * fn_choose_term still does not touch `cycle`, and that is correct.
--     `cycle` labels the period that was invoiced; term_months is the intent
--     for the next one. A school switching to monthly halfway through a year
--     it has paid for must not have that year relabelled.
--   * The 14-day trial is unchanged and applies to every plan and every term.
--     A trial is 14 days of the software, not 14 days of a particular price.
--   * No school's existing plan_code, term_months or cycle is rewritten. This
--     migration cannot know what a school that was never asked would have
--     said, and guessing would put a school on a plan it did not pick. What it
--     does instead is make the choice reachable: Settings -> Subscription has
--     had the term chooser since 0112, and now shows which one is in force.
--
-- Re-runnable.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. `quarterly`
--
-- ALTER TYPE ... ADD VALUE is allowed inside a transaction block on Postgres 12
-- and later, which matters because a pasted bundle IS one transaction. What is
-- NOT allowed is USING the new value in that same transaction:
--
--     begin; alter type bc add value 'c'; select 'c'::bc;
--     ERROR:  unsafe use of new value "c" of enum type bc
--     HINT:   New enum values must be committed before they can be used.
--
-- Verified both ways on Postgres 16 before this was written. So:
--
--   * the existence check below reads pg_enum by LABEL TEXT and never casts;
--   * fn__cycle_for_months is plpgsql and not sql, because a plpgsql body is
--     parsed on first execution and a sql body is parsed at CREATE, where the
--     literal would be checked and refused;
--   * nothing else in this file evaluates the value.
-- ---------------------------------------------------------------------------
do $enum$
begin
  if exists (
    select 1 from pg_enum e
      join pg_type t on t.oid = e.enumtypid
      join pg_namespace n on n.oid = t.typnamespace
     where n.nspname = 'public' and t.typname = 'billing_cycle'
       and e.enumlabel = 'quarterly'
  ) then
    raise notice '0127: billing_cycle already has quarterly';
    return;
  end if;
  -- `before 'yearly'`, so the type reads monthly, quarterly, yearly and any
  -- screen that orders by the enum gets the shortest term first.
  alter type public.billing_cycle add value 'quarterly' before 'yearly';
  raise notice '0127: billing_cycle can now record a quarterly subscription';
end $enum$;

-- ---------------------------------------------------------------------------
-- 2. ONE RULE FOR WHAT A TERM IS CALLED
--
-- Both writers called it something different by hand. A helper is the only way
-- the two cannot drift again, and it is the reason fault 2 could exist at all.
--
-- Twelve months or more is yearly, three to eleven is quarterly, less is
-- monthly. Not exact multiples: an operator can invoice any number of months
-- from 1 to 60, and a six-month term has to be called something. The name is a
-- label on a period, and "the nearest standard term at or below the length"
-- is the honest one.
-- ---------------------------------------------------------------------------
create or replace function public.fn__cycle_for_months(p_months integer)
returns public.billing_cycle
language plpgsql immutable set search_path = public as $$
begin
  if p_months is null then
    return null;
  elsif p_months >= 12 then
    return 'yearly';
  elsif p_months >= 3 then
    return 'quarterly';
  else
    return 'monthly';
  end if;
end;
$$;

revoke all on function public.fn__cycle_for_months(integer)
  from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 3. fn_activate_subscription: name the term properly, and record it
--
-- Rewritten programmatically and asserted, the way 0092 and 0126 rewrite
-- audit_trigger, and for the same reason: restating a hundred-line function to
-- change two lines silently discards anything a later migration did to the
-- other ninety-eight.
--
-- BOTH ANCHORS ARE SINGLE LINES WITH NO NEWLINE IN THEM. 0126 shipped an
-- anchor containing \n, which matches a body as this repository stores it and
-- not a body pasted from an editor that writes CRLF, and it stopped with its
-- own "has been rewritten since" message on a database where nothing had been.
-- ---------------------------------------------------------------------------
do $act$
declare v_src text; v_new text;
begin
  v_src := pg_get_functiondef(
    'public.fn_activate_subscription(uuid,text,integer,numeric,text,boolean)'::regprocedure);

  if position('fn__cycle_for_months' in v_src) > 0 then
    raise notice '0127: fn_activate_subscription already names the term properly';
    return;
  end if;

  v_new := v_src;

  -- (a) the label
  if position('v_cycle := case when p_months >= 12 then ''yearly'' else ''monthly'' end::public.billing_cycle;'
      in v_new) = 0 then
    raise exception '0127: fn_activate_subscription no longer contains the line '
      'that names the billing cycle. It has been rewritten since. The change is '
      'to call public.fn__cycle_for_months(p_months) instead of deciding between '
      'yearly and monthly inline, so a three month term is recorded as '
      'quarterly rather than as monthly.';
  end if;
  v_new := replace(v_new,
    'v_cycle := case when p_months >= 12 then ''yearly'' else ''monthly'' end::public.billing_cycle;',
    'v_cycle := public.fn__cycle_for_months(p_months);');

  -- (b) the term itself. Without this the console quotes a renewal figure the
  --     invoice will not match: see fault 3 in the header.
  if position('         grace_ends_on = v_end + public.grace_days()' in v_new) = 0 then
    raise exception '0127: fn_activate_subscription no longer contains the '
      'subscription update this migration expects to extend. It has been '
      'rewritten since. The change is to set term_months = p_months alongside '
      'grace_ends_on, so the term the operator just invoiced is the term the '
      'next renewal is priced on.';
  end if;
  v_new := replace(v_new,
    '         grace_ends_on = v_end + public.grace_days()',
    '         grace_ends_on = v_end + public.grace_days(),' || E'\n' ||
    '         -- 0127: the term the operator just invoiced IS the term this' || E'\n' ||
    '         -- school is on. Without this line term_months kept whatever the' || E'\n' ||
    '         -- school last chose in Settings, fn__renewals_due priced the next' || E'\n' ||
    '         -- invoice on that, and the console quoted a different figure.' || E'\n' ||
    '         term_months   = p_months');

  if v_new = v_src then
    raise exception '0127: the fn_activate_subscription rewrite changed nothing';
  end if;
  execute v_new;
  raise notice '0127: fn_activate_subscription records the term it invoiced and '
    'names a quarterly term quarterly';
end $act$;

-- ---------------------------------------------------------------------------
-- 4. The two places that guessed the months from the cycle
--
-- Each takes two anchors: add term_months to what the query already selects
-- from subscriptions, then price on it. A correlated subquery at the point of
-- use would have been one anchor instead of two and would also have re-read a
-- table both functions already join, so the reader of the result would be left
-- wondering why.
-- ---------------------------------------------------------------------------
do $due$
declare v_src text; v_new text;
begin
  v_src := pg_get_functiondef('public.fn_platform_due_soon(integer)'::regprocedure);
  if position('b.term_months)' in v_src) > 0 then
    raise notice '0127: fn_platform_due_soon already prices on the term';
    return;
  end if;

  if position('             sub.plan_code, sub.status as raw_status, sub.cycle,' in v_src) = 0
     or position('                            case when b.cycle = ''yearly'' then 12 else 1 end),' in v_src) = 0 then
    raise exception '0127: fn_platform_due_soon does not contain the two lines '
      'this migration expects to edit. It has been rewritten since. The change '
      'is to select sub.term_months in the base CTE and price the renewal on '
      'b.term_months instead of on case when b.cycle = ''yearly'' then 12 else '
      '1 end, which understates a three month renewal by two thirds.';
  end if;

  v_new := replace(v_src,
    '             sub.plan_code, sub.status as raw_status, sub.cycle,',
    '             sub.plan_code, sub.status as raw_status, sub.cycle,' || E'\n' ||
    '             -- 0127: the term the next invoice will actually cover.' || E'\n' ||
    '             sub.term_months,');
  v_new := replace(v_new,
    '                            case when b.cycle = ''yearly'' then 12 else 1 end),',
    '                            b.term_months),');

  if v_new = v_src then
    raise exception '0127: the fn_platform_due_soon rewrite changed nothing';
  end if;
  execute v_new;
  raise notice '0127: the renewals worklist quotes the figure the invoice will say';
end $due$;

do $msg$
declare v_src text; v_new text;
begin
  v_src := pg_get_functiondef('public.fn_platform_renewal_message(uuid,text)'::regprocedure);
  if position('v.term_months)' in v_src) > 0 then
    raise notice '0127: fn_platform_renewal_message already prices on the term';
    return;
  end if;

  if position('         sub.plan_code, sub.cycle, sub.student_count, sub.period_end,' in v_src) = 0
     or position('           case when v.cycle = ''yearly'' then 12 else 1 end)' in v_src) = 0 then
    raise exception '0127: fn_platform_renewal_message does not contain the two '
      'lines this migration expects to edit. It has been rewritten since. The '
      'change is to select sub.term_months and price on v.term_months, so the '
      'renewal figure sent to a school by WhatsApp is the figure on its invoice.';
  end if;

  v_new := replace(v_src,
    '         sub.plan_code, sub.cycle, sub.student_count, sub.period_end,',
    '         sub.plan_code, sub.cycle, sub.term_months, sub.student_count,' || E'\n' ||
    '         sub.period_end,');
  v_new := replace(v_new,
    '           case when v.cycle = ''yearly'' then 12 else 1 end)',
    '           v.term_months)');

  if v_new = v_src then
    raise exception '0127: the fn_platform_renewal_message rewrite changed nothing';
  end if;
  execute v_new;
  raise notice '0127: the renewal message quotes the figure the invoice will say';
end $msg$;

-- ---------------------------------------------------------------------------
-- 5. fn_signup_school asks
--
-- DROPPED AND RECREATED, not create-or-replace. create-or-replace cannot change
-- an argument list, and adding two defaulted parameters as a second function
-- leaves the old five-argument one in place and every existing five-argument
-- call AMBIGUOUS between them. 0048 hit exactly this and had to drop three
-- functions to add a reason parameter.
--
-- Both new parameters default, so the Edge Function keeps working through a
-- deploy in either order: an old deployment calling with five arguments gets
-- Starter on a yearly term, which is what it gets today, and a new one passes
-- the school's answers.
--
-- VALIDATED HERE AND NOT ONLY IN THE FORM. The Edge Function runs as the
-- service role and is the one public unauthenticated entry point in the
-- product; a body posted straight at it must not be able to put a school on a
-- plan that does not exist, on a retired plan, or on a 47-month term.
-- ---------------------------------------------------------------------------
drop function if exists public.fn_signup_school(text, text, text, text, text);

create or replace function public.fn_signup_school(
  p_name          text,
  p_city          text default null,
  p_contact_name  text default null,
  p_contact_phone text default null,
  p_contact_email text default null,
  p_plan_code     text default 'starter',
  p_term_months   integer default 12)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_id    uuid;
  v_plan  record;
  v_term  integer := coalesce(p_term_months, 12);
  v_trial date    := current_date + 14;
begin
  if nullif(btrim(p_name), '') is null then
    raise exception 'School name is required';
  end if;

  -- The plan must be one we sell today, AND ONE THAT HAS A PRICE.
  --
  -- `active` matters: a plan withdrawn from sale stays in the table because old
  -- invoices point at it, and a new school must not be able to land on one.
  --
  -- `price_monthly > 0` MATTERS MORE, and it was found by writing the signup
  -- form rather than by reading this function. The `custom` plan is active, is
  -- named "Custom (601+ students - contact us)", has price_monthly, price_yearly
  -- and price_quarterly all zero, and has student_limit NULL. Null means no
  -- limit at all: plan_margin_limit(null) is null and fn_my_licence reports
  -- limit_state 'ok' for any roll. So a school choosing it at signup would get
  -- unlimited pupils, for nothing, for ever, and every renewal invoice would be
  -- for Rs 0. It is the correct plan for a 900-pupil school and it is priced in
  -- a conversation, which is exactly why it cannot be self-served.
  --
  -- Expressed as "has a price" rather than as "is not called custom", so a
  -- second by-arrangement plan added later is barred by the same clause instead
  -- of walking straight through it.
  select * into v_plan from public.plans
   where code = coalesce(nullif(btrim(p_plan_code), ''), 'starter')
     and active and price_monthly > 0;
  if not found then
    if exists (select 1 from public.plans
                where code = btrim(p_plan_code) and active and price_monthly = 0) then
      -- `%` and not `%s`. RAISE's only placeholder is a bare percent, so
      -- `%s` consumes the argument AND leaves a stray "s" in the sentence:
      -- this line read "The Custom (601+ students - contact us)s plan" until
      -- it was actually triggered and read. scripts/check-raise-format.py now
      -- refuses the shape.
      raise exception 'The "%" plan is priced by arrangement rather than from '
        'the price list, so it cannot be chosen at signup. Start on any of '
        'these and we will move you: %',
        (select name from public.plans where code = btrim(p_plan_code)),
        (select string_agg(code, ', ' order by sort_order) from public.plans
          where active and price_monthly > 0);
    end if;
    raise exception 'There is no plan called "%". The plans on sale are: %',
      p_plan_code,
      (select string_agg(code, ', ' order by sort_order)
         from public.plans where active and price_monthly > 0);
  end if;

  -- The three terms that are sold, the same three fn_choose_term accepts and
  -- fn_my_next_payment quotes. An operator can invoice any number of months;
  -- a school choosing for itself picks from the price list.
  if v_term not in (1, 3, 12) then
    raise exception 'Choose one month, three months or a year';
  end if;

  insert into public.schools (name, city, contact_name, contact_phone, contact_email)
  values (btrim(p_name), p_city, p_contact_name, p_contact_phone, p_contact_email)
  returning id into v_id;

  -- THE TRIAL IS THE SAME FOURTEEN DAYS WHATEVER THEY PICKED. A trial is
  -- fourteen days of the software, not fourteen days of a price, and making it
  -- depend on the plan would give a school a reason to pick the wrong one.
  --
  -- cycle is set from the term rather than left to the column default, which is
  -- how every school ended up labelled yearly. During a trial it is the
  -- INTENDED cycle; fn_activate_subscription confirms it when the first period
  -- is actually invoiced.
  insert into public.subscriptions
    (school_id, plan_code, status, cycle, term_months, trial_ends_on)
  values
    (v_id, v_plan.code, 'trialing',
     public.fn__cycle_for_months(v_term), v_term, v_trial);

  return jsonb_build_object(
    'school_id',     v_id,
    'trial_ends_on', v_trial,
    -- Echoed back so the caller can show what was recorded rather than what it
    -- sent. A signup that quietly fell back to Starter used to be invisible.
    'plan_code',     v_plan.code,
    'plan_name',     v_plan.name,
    'term_months',   v_term,
    'student_limit', v_plan.student_limit,
    'first_amount',  public.fn__plan_price(v_plan.code, v_term));
end;
$$;

-- The same grants the five-argument version carried: service role only, which
-- is what stops signup being a way to mint schools from a browser.
revoke all on function
  public.fn_signup_school(text, text, text, text, text, text, integer)
  from public, anon, authenticated;
grant execute on function
  public.fn_signup_school(text, text, text, text, text, text, integer)
  to service_role;

-- ---------------------------------------------------------------------------
-- 6. fn_my_licence SAYS HOW OFTEN, AS WELL AS HOW MUCH
--
-- The Subscription screen's "Your plan" block reads fn_my_licence, which
-- returned the plan, the price for all three terms and `cycle`, and not
-- term_months. So the screen could say what a year costs and could not say
-- whether this school pays yearly. The panel above it knew (it reads
-- fn_my_next_payment) and the block below it did not, which is how the same
-- screen ended up quoting an annual figure to a school on a monthly term.
--
-- One anchor, on the line that already returns the other subscription figures.
-- ---------------------------------------------------------------------------
do $lic$
declare v_src text; v_new text;
begin
  v_src := pg_get_functiondef('public.fn_my_licence()'::regprocedure);
  if position('''term_months''' in v_src) > 0 then
    raise notice '0127: fn_my_licence already reports the term';
    return;
  end if;
  if position('    ''cycle'',          v_sub.cycle,' in v_src) = 0 then
    raise exception '0127: fn_my_licence no longer returns cycle on the line '
      'this migration expects to extend. It has been rewritten since. The '
      'change is to return term_months beside it, so the Subscription screen '
      'can say how often a school pays and not only what a year costs.';
  end if;
  v_new := replace(v_src,
    '    ''cycle'',          v_sub.cycle,',
    '    ''cycle'',          v_sub.cycle,' || E'\n' ||
    '    -- 0127: how often, as well as how much. `cycle` labels the period that' || E'\n' ||
    '    -- was invoiced; term_months is what the NEXT invoice will cover, which' || E'\n' ||
    '    -- is what a school reading this screen is asking about.' || E'\n' ||
    '    ''term_months'',    v_sub.term_months,');
  if v_new = v_src then
    raise exception '0127: the fn_my_licence rewrite changed nothing';
  end if;
  execute v_new;
  raise notice '0127: fn_my_licence reports how often the school pays';
end $lic$;

-- ---------------------------------------------------------------------------
-- 7. THE PLAN LIST THE SIGNUP FORM READS
--
-- The form has to show three plans and nine prices, and NONE of that
-- arithmetic belongs in a browser. fn__plan_price is not a lookup: it takes
-- the cheaper of the laddered price and the cheapest single standard term that
-- covers the period, and price_quarterly falls back to the monthly rate when
-- it is zero. Reimplementing that in TypeScript would work until somebody
-- changed one of the three rates, and then the form would quote a figure the
-- first invoice contradicts, on the screen where a school decides to buy.
--
-- So one function, one round trip, and the same fn__plan_price the invoice
-- uses. It is also the only place that decides WHICH plans a school may pick,
-- so the form cannot offer the by-arrangement plan even by mistake: the filter
-- lives here beside the one in fn_signup_school rather than in the component.
--
-- GRANTED TO anon, WHICH IS DELIBERATE AND IS THE WHOLE POINT. A school filling
-- in the signup form has no login. It returns the published price list and
-- nothing else: no school, no count, no name. `plans` already carries a
-- SELECT policy for anon (plans_select_public) for the same reason.
-- ---------------------------------------------------------------------------
create or replace function public.fn_signup_plans()
returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'code',          p.code,
           'name',          p.name,
           'student_limit', p.student_limit,
           'terms', (
             select jsonb_agg(jsonb_build_object(
                      'months', m.months,
                      'amount', public.fn__plan_price(p.code, m.months),
                      -- The saving against paying monthly for the same time,
                      -- in rupees. A school can weigh "Rs 4,000" against
                      -- something it wants; "16.7 percent" is homework.
                      'saving', greatest(0, round(p.price_monthly * m.months, 2)
                                            - public.fn__plan_price(p.code, m.months)))
                      order by m.months)
               from (values (1), (3), (12)) as m(months))
         ) order by p.sort_order), '[]'::jsonb)
    from public.plans p
   where p.active
     -- Same clause as fn_signup_school: a plan priced in a conversation has no
     -- student limit, so offering it would be unlimited pupils for nothing.
     and p.price_monthly > 0;
$$;

revoke all on function public.fn_signup_plans() from public;
grant execute on function public.fn_signup_plans() to anon, authenticated;

-- ---------------------------------------------------------------------------
-- THE GUARDS. Properties, not restatements.
-- ---------------------------------------------------------------------------
do $check$
declare v_n integer; v_src text;
begin
  -- 1. The enum can express all three terms.
  select count(*) into v_n from pg_enum e
    join pg_type t on t.oid = e.enumtypid
    join pg_namespace n on n.oid = t.typnamespace
   where n.nspname = 'public' and t.typname = 'billing_cycle'
     and e.enumlabel in ('monthly', 'quarterly', 'yearly');
  if v_n <> 3 then
    raise exception '0127: billing_cycle cannot express all three sold terms '
      '(found % of monthly, quarterly, yearly)', v_n;
  end if;

  -- 2. Exactly one fn_signup_school, so no call of it is ambiguous.
  select count(*) into v_n from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'fn_signup_school';
  if v_n <> 1 then
    raise exception '0127: there are % functions named fn_signup_school. Two '
      'overloads make every existing five-argument call ambiguous, which is '
      'why the old one is dropped rather than replaced.', v_n;
  end if;

  -- 3. It is still service-role only. This is the one public unauthenticated
  --    path in the product; reachable from a browser it mints schools.
  if has_function_privilege('authenticated',
       'public.fn_signup_school(text,text,text,text,text,text,integer)'::regprocedure, 'EXECUTE')
     or has_function_privilege('anon',
       'public.fn_signup_school(text,text,text,text,text,text,integer)'::regprocedure, 'EXECUTE') then
    raise exception '0127: fn_signup_school is callable from a browser, which '
      'is a way to create schools without signing up';
  end if;

  -- 4. Nothing decides what a term is called by hand any more.
  for v_src in
    select p.proname from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.prokind = 'f'
       and p.proname <> 'fn__cycle_for_months'
       and p.prosrc ~ 'then ''yearly'' else ''monthly'''
  loop
    raise exception '0127: % still decides the billing cycle inline instead of '
      'calling fn__cycle_for_months, so it cannot record a quarterly '
      'subscription', v_src;
  end loop;

  -- 5. And nothing works the months out from the cycle. This is the money one:
  --    the invoice is priced on term_months, so anything that quotes a figure
  --    from the cycle quotes a figure the invoice will not match.
  for v_src in
    select p.proname from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.prokind = 'f'
       and p.prosrc ~ 'cycle = ''yearly'' then 12 else 1 end'
  loop
    raise exception '0127: % still works out the number of months from the '
      'billing cycle. fn__renewals_due prices the invoice on term_months, so '
      'this quotes a school a figure its invoice will not match: a third of it '
      'on a quarterly term, a twelfth on a yearly one.', v_src;
  end loop;

  -- 6. AND SIGNUP CANNOT REACH A PLAN THAT IS PRICED IN A CONVERSATION. Every
  --    such plan has no student limit, so reaching one is unlimited pupils for
  --    nothing. Asserted by trying it rather than by reading the function: the
  --    whole point is that the form is not the only way in.
  declare v_free text;
  begin
    select code into v_free from public.plans
     where active and price_monthly = 0 order by sort_order limit 1;
    if v_free is not null then
      begin
        perform public.fn_signup_school('0127 probe', null, null, null, null,
                                        v_free, 12);
        raise exception '0127: fn_signup_school accepted the "%" plan, which has '
          'no price and no student limit, so that is unlimited pupils for '
          'nothing for ever', v_free;
      exception
        when others then
          -- The refusal is the pass. Anything else, including the raise above,
          -- is a real failure and goes on up. The subtransaction rolls back
          -- either way, so the probe leaves no school behind.
          if position('priced by arrangement' in sqlerrm) = 0 then
            raise;
          end if;
      end;
    end if;
  end;

  -- 7. THE FORM AND THE FUNCTION OFFER THE SAME PLANS. Two filters, in two
  --    places, saying the same thing. If they ever disagree the form shows a
  --    plan the signup refuses, which is a dead end on the buying screen.
  select count(*) into v_n
    from jsonb_array_elements(public.fn_signup_plans()) e
    join public.plans p on p.code = e->>'code'
   where not p.active or p.price_monthly = 0;
  if v_n > 0 then
    raise exception '0127: fn_signup_plans offers % plan(s) that fn_signup_school '
      'would refuse', v_n;
  end if;
  if jsonb_array_length(public.fn_signup_plans()) = 0 then
    raise exception '0127: fn_signup_plans offers nothing, so the signup form '
      'would have no plan to pick';
  end if;

  raise notice '0127: a school picks its plan and its term at signup, the term '
    'is recorded when it is invoiced, and one column decides what the renewal '
    'costs';
end $check$;

-- ─────────────────────────────────────────────────────────────────────────
-- Record what this bundle applied (no-op before 0069 creates the ledger)
-- ─────────────────────────────────────────────────────────────────────────
do $ledger$
begin
  if to_regprocedure('public.fn_record_migration(text,text,text)') is null then
    raise notice 'migration ledger not present yet — nothing recorded';
    return;
  end if;
  perform public.fn_record_migration('0127_a_school_picks_its_plan_and_how_it_pays.sql', '33_a_school_picks_its_plan_and_how_it_pays.sql');
end $ledger$;

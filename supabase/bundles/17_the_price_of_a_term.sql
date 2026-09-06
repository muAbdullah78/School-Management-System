-- =============================================================================
-- GENERATED FILE — DO NOT EDIT.
-- Built from supabase/migrations/ by supabase/build-bundles.sh
--
-- Paste this whole file into the Supabase SQL Editor and press Run.
-- Run the bundles in order, one at a time, waiting for each to finish.
-- =============================================================================


-- ─────────────────────────────────────────────────────────────────────────
-- 0111_the_price_of_a_term.sql
-- ─────────────────────────────────────────────────────────────────────────
-- =============================================================================
-- 0111: Three lengths to buy, and one place that says what each costs
--
-- THE COMMERCIAL CHANGE
--
-- New bands and new prices, decided on the strength of what the software now
-- does rather than what it did when 0025 guessed at them:
--
--     1 to 150 students      Rs 2,000 a month
--     151 to 350 students    Rs 3,500 a month
--     351 to 600 students    Rs 5,500 a month
--     601+                   a conversation
--
-- and a THIRD term to buy. There were two, monthly and yearly. Three months now
-- sits between them at about 5% off, because the gap between "Rs 2,000, I will
-- think about it monthly" and "Rs 20,000 up front" is where a school that means
-- to buy quietly stops.
--
--     term        starter    growth     institution
--     1 month     2,000      3,500      5,500
--     3 months    5,700      10,000     15,700      (about 5% off)
--     12 months   20,000     35,000     55,000      (pay for ten)
--
-- Yearly is deliberately "pay for ten months, get twelve" rather than a
-- percentage. It is round in rupees, and it is a sentence a person can say on
-- the phone without a calculator.
--
-- Nobody is grandfathered because nobody is paying yet: the product is in
-- testing and has no live customers. That will not be true again, so the next
-- price change is a harder migration than this one.
--
-- WHY THIS IS ALSO A CORRECTNESS FIX
--
-- The price of N months was computed in TWO places that agreed only by
-- coincidence:
--
--   fn__plan_price (0064)      months >= 12 ? yearly * months/12 : monthly * months
--   ActivationDialog (the app) months >= 12 ? yearly * months/12 : monthly * months
--
-- The second is a copy of the first, in TypeScript, in the browser. They match
-- today. The moment a third rate exists they stop matching: the console would
-- quote three months at Rs 6,000 while the database charged Rs 5,700, and the
-- operator would find out from the invoice. So the ladder gains a step AND a
-- granted wrapper, and the console is changed to ask rather than to calculate.
--
-- WHY price_quarterly RATHER THAN A plan_prices TABLE
--
-- A child table keyed by (plan_code, term_months) is the better shape in the
-- abstract and would take any future term for free. It would also mean
-- rewriting fn_my_licence, 0068's copy of it, the site's REST query, the
-- operator console and check-site-prices.sh, none of which can be tested
-- against a real customer today. A third column and one helper is the change
-- that can be verified end to end this afternoon. If a fourth term is ever
-- wanted, that is the migration to reconsider it in.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. The third rate
-- ---------------------------------------------------------------------------
alter table public.plans
  add column if not exists price_quarterly numeric(12,2) not null default 0;

comment on column public.plans.price_quarterly is
  'What THREE months cost, as a whole, not per month. Zero means the plan is '
  'not sold quarterly, and fn__plan_price falls back to the monthly rate.';

-- ---------------------------------------------------------------------------
-- 2. The price list
--
-- Plan CODES are unchanged, exactly as 0028 argued: subscriptions.plan_code
-- references plans(code), so renaming would orphan every school that ever
-- signs up. Only the sizes, the names and the money move.
-- ---------------------------------------------------------------------------
update public.plans set
  name            = 'Starter (up to 150 students)',
  student_limit   = 150,
  price_monthly   = 2000,
  price_quarterly = 5700,
  price_yearly    = 20000
where code = 'starter';

update public.plans set
  name            = 'Growth (151-350 students)',
  student_limit   = 350,
  price_monthly   = 3500,
  price_quarterly = 10000,
  price_yearly    = 35000
where code = 'growth';

update public.plans set
  name            = 'Institution (351-600 students)',
  student_limit   = 600,
  price_monthly   = 5500,
  price_quarterly = 15700,
  price_yearly    = 55000
where code = 'institution';

update public.plans set
  name            = 'Custom (601+ students - contact us)',
  student_limit   = null,
  price_monthly   = 0,
  price_quarterly = 0,
  price_yearly    = 0
where code = 'custom';

-- The limits shrank again, so re-flag anyone the new bands put over. The
-- soft-limit rule stands and always has: going over flags the school on the
-- operator console and never blocks an admission. A school mid-term does not
-- get told its pupils are a licence problem.
update public.subscriptions s
   set over_limit_flagged_at = coalesce(s.over_limit_flagged_at, now())
  from public.plans p
 where p.code = s.plan_code
   and p.student_limit is not null
   and s.student_count > p.student_limit;

-- ---------------------------------------------------------------------------
-- 3. What a term costs, in ONE place
--
-- THE LADDER, and the rule that keeps it honest.
--
-- Three standard terms are sold: 1, 3 and 12 months. Anything else an operator
-- types is priced from the longest standard term that fits into it, which is
-- how a 6-month deal gets the quarterly rate twice rather than the monthly rate
-- six times.
--
-- And then a CAP, because a ladder alone produces an absurdity. Eleven months
-- at the quarterly rate is 5,700 * 11/3 = Rs 20,900, while twelve months is
-- Rs 20,000 - so a school buying less would pay more, and the operator would
-- have to notice. Nobody notices. The cap says: never charge more than the
-- shortest standard term that covers the period. It costs one line and it makes
-- the price list impossible to trip over.
-- ---------------------------------------------------------------------------
create or replace function public.fn__plan_price(p_plan_code text, p_months integer)
returns numeric language sql stable as $$
  with p as (select * from public.plans where code = p_plan_code),
  -- What the ladder asks for: the longest standard term that fits, repeated.
  laddered as (
    select case
      when p_months >= 12 and p.price_yearly > 0
        then p.price_yearly * (p_months::numeric / 12)
      when p_months >= 3 and p.price_quarterly > 0
        then p.price_quarterly * (p_months::numeric / 3)
      else p.price_monthly * p_months
    end as amount
    from p
  ),
  -- The cheapest single standard term that covers the whole period. Null when
  -- the period is longer than a year, where no single term covers it.
  covering as (
    select min(x.amount) as amount from p, lateral (values
      (case when p_months <= 1  then p.price_monthly   end),
      (case when p_months <= 3  and p.price_quarterly > 0 then p.price_quarterly end),
      (case when p_months <= 12 and p.price_yearly    > 0 then p.price_yearly    end)
    ) as x(amount)
    where x.amount is not null
  )
  select round(least(
           (select amount from laddered),
           coalesce((select amount from covering), (select amount from laddered))
         ), 2);
$$;

revoke all on function public.fn__plan_price(text, integer) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 4. The same answer, for the browser to ask rather than compute
--
-- fn__plan_price is revoked from everybody because it answers without checking
-- who is asking. This is the wrapper the operator console calls, and it returns
-- the parts a person needs to read the quote rather than only the total: what
-- the list rate is, what the saving is, and what it works out to per month.
--
-- Granted to `authenticated` and not to anon: a price list is public
-- information and the marketing site reads `plans` directly for it, but a
-- QUOTE is a number the console puts on an invoice and there is no reason for
-- the internet to be able to generate one.
-- ---------------------------------------------------------------------------
create or replace function public.fn_plan_quote(p_plan_code text, p_months integer)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_plan record; v_price numeric; v_list numeric;
begin
  if p_months is null or p_months < 1 or p_months > 60 then
    raise exception 'A term is between 1 and 60 months';
  end if;
  select * into v_plan from public.plans where code = p_plan_code;
  if not found then
    raise exception 'No such plan: %', p_plan_code;
  end if;

  v_price := public.fn__plan_price(p_plan_code, p_months);
  -- The list price is always the monthly rate times the months. That is the
  -- number the discount is measured against, and it is the number a school
  -- compares to when it is deciding whether the longer term is worth it.
  v_list  := round(v_plan.price_monthly * p_months, 2);

  return jsonb_build_object(
    'plan_code', v_plan.code,
    'plan_name', v_plan.name,
    'months', p_months,
    'amount', v_price,
    'list_amount', v_list,
    'saving', greatest(0, v_list - v_price),
    'per_month', case when p_months > 0 then round(v_price / p_months, 2) else v_price end,
    -- Only true for a plan that is actually sold. The custom plan is priced in
    -- a conversation and every figure above is zero for it, which a screen
    -- must be able to tell apart from "this costs nothing".
    'sold_at_list', v_plan.price_monthly > 0,
    'student_limit', v_plan.student_limit);
end;
$$;

grant  execute on function public.fn_plan_quote(text, integer) to authenticated;
revoke execute on function public.fn_plan_quote(text, integer) from public, anon;

-- ---------------------------------------------------------------------------
-- 5. The school's own licence screen learns the third rate
--
-- Patched in place rather than restated: fn_my_licence is ninety lines that
-- 0068 argued through, and copying it here to add one key would leave two
-- versions of that argument in the repository. The anchor is a SINGLE LINE
-- with no newline inside it, which is 0101's lesson: a match spanning a line
-- break fails on a database whose bodies are stored CRLF, and every one of
-- this customer's is, because bundles are pasted through a browser editor.
-- ---------------------------------------------------------------------------
do $patch$
declare v_src text; v_new text;
begin
  if to_regprocedure('public.fn_my_licence()') is null then
    raise warning '0111: fn_my_licence does not exist; skipping';
    return;
  end if;
  v_src := pg_get_functiondef('public.fn_my_licence()'::regprocedure);
  if v_src like '%price_quarterly%' then
    raise notice '0111: fn_my_licence already reports the quarterly rate';
    return;
  end if;
  v_new := replace(v_src,
    '''price_yearly'',   v_plan.price_yearly,',
    '''price_yearly'',   v_plan.price_yearly,'
    || chr(10) || '    ''price_quarterly'', v_plan.price_quarterly,');
  if v_new = v_src then
    raise warning '0111: fn_my_licence does not carry the price_yearly key in the '
      'expected shape; the school''s own screen will not show the three-month '
      'rate. Check it by hand.';
  else
    execute v_new;
    raise notice '0111: fn_my_licence now reports the quarterly rate';
  end if;
end
$patch$;

-- ─────────────────────────────────────────────────────────────────────────
-- Record what this bundle applied (no-op before 0069 creates the ledger)
-- ─────────────────────────────────────────────────────────────────────────
do $ledger$
begin
  if to_regprocedure('public.fn_record_migration(text,text,text)') is null then
    raise notice 'migration ledger not present yet — nothing recorded';
    return;
  end if;
  perform public.fn_record_migration('0111_the_price_of_a_term.sql', '17_the_price_of_a_term.sql');
end $ledger$;

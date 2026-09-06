-- =============================================================================
-- A longer term never costs more than a shorter one, and one place says so
--
-- WHY THIS FILE EXISTS
--
-- Two reasons, and the second is the one that would have cost real money.
--
-- 1. A LADDER PRODUCES ABSURDITIES UNLESS SOMETHING STOPS IT.
--
-- Three terms are sold: one month, three months at about 5% off, and twelve
-- months for the price of ten. Price anything else by repeating the longest
-- term that fits and eleven months comes to Rs 20,900 while twelve months is
-- Rs 20,000. A school buying less would pay more, an operator typing 11 into
-- the months box would never notice, and the only person who would find out is
-- the school reading its own invoice.
--
-- So the price list is asserted MONOTONIC over the whole range an operator can
-- type. Not "the cap works", which is a test of the implementation: monotonic,
-- which is the property a customer can feel.
--
-- 2. THE PRICE WAS COMPUTED IN TWO PLACES.
--
-- fn__plan_price has always held the ladder, and the operator console held a
-- copy of it in TypeScript so the activation dialog could show a total without
-- a round trip. They agreed exactly as long as the ladder had two steps. Adding
-- a third would have made the console quote three months at Rs 6,000 while the
-- database charged Rs 5,700 - a disagreement nothing in this repository could
-- have caught, because each side is correct about its own rule.
--
-- The console now asks fn_plan_quote instead of calculating. This file asserts
-- the quote and the charge are the same number, so if anybody ever puts the
-- copy back, a suite fails rather than a customer.
--
-- Run: psql -v ON_ERROR_STOP=1 -f supabase/tests/the_price_of_a_term.sql
-- =============================================================================

\set ON_ERROR_STOP on
begin;

create or replace function auth.uid() returns uuid language sql stable as
  $$ select nullif(current_setting('test.uid', true), '')::uuid $$;

-- 1. THE PRICE LIST IS WHAT WAS AGREED. Asserted by value, because a typo in a
--    price is silent, ships, and is discovered by a customer.
do $t$
declare r record; v_bad text[] := '{}';
begin
  for r in
    select * from (values
      ('starter',     150,  2000, 5700,  20000),
      ('growth',      350,  3500, 10000, 35000),
      ('institution', 600,  5500, 15700, 55000)
    ) as t(code, lim, m, q, y)
  loop
    if not exists (
      select 1 from public.plans p
       where p.code = r.code and p.student_limit = r.lim
         and p.price_monthly = r.m and p.price_quarterly = r.q
         and p.price_yearly = r.y) then
      v_bad := v_bad || r.code::text;
    end if;
  end loop;
  if array_length(v_bad, 1) > 0 then
    raise exception 'FAIL: the price list does not match what was agreed, for: %. '
      'Expected 150/2000/5700/20000, 350/3500/10000/35000, 600/5500/15700/55000.',
      array_to_string(v_bad, ', ');
  end if;
  -- The custom plan is priced in a conversation and must stay at zero, so that
  -- every screen can tell "free" apart from "ask us".
  if not exists (select 1 from public.plans
                  where code = 'custom' and student_limit is null
                    and price_monthly = 0 and price_yearly = 0) then
    raise exception 'FAIL: the custom plan is no longer open-ended and unpriced';
  end if;
  raise notice '1. the price list is the agreed one - ok';
end $t$;

-- 2. TWELVE MONTHS IS TEN MONTHS OF MONEY. The discount is the promise on the
--    website, so it is asserted as arithmetic rather than as a stored number.
do $t$
declare r record;
begin
  for r in select code, price_monthly, price_yearly from public.plans where price_monthly > 0
  loop
    if r.price_yearly <> r.price_monthly * 10 then
      raise exception 'FAIL: % sells a year for % when ten months is %. The site says '
        '"pay yearly and get two months free" and that sentence has to stay true.',
        r.code, r.price_yearly, r.price_monthly * 10;
    end if;
  end loop;
  raise notice '2. a year still costs ten months - ok';
end $t$;

-- 3. THREE MONTHS SAVES SOMETHING, AND NOT TOO MUCH. A quarterly rate that
--    saved nothing would be a term nobody takes; one that beat the annual rate
--    per month would cannibalise the term this business actually wants to sell.
do $t$
declare r record; v_pct numeric;
begin
  for r in select code, price_monthly, price_quarterly, price_yearly
             from public.plans where price_monthly > 0
  loop
    v_pct := round(100 * (1 - r.price_quarterly / (r.price_monthly * 3)), 1);
    if v_pct <= 0 then
      raise exception 'FAIL: three months on % saves nothing (% percent). Nobody '
        'takes a longer commitment for no discount.', r.code, v_pct;
    end if;
    if v_pct > 12 then
      raise exception 'FAIL: three months on % saves % percent, which is close '
        'enough to the annual discount that the annual plan stops being worth '
        'selling.', r.code, v_pct;
    end if;
    if r.price_quarterly / 3 <= r.price_yearly / 12 then
      raise exception 'FAIL: three months on % is cheaper per month than a year. '
        'The longest commitment must always be the cheapest per month.', r.code;
    end if;
  end loop;
  raise notice '3. three months saves about 5 percent, and a year still beats it - ok';
end $t$;

-- 4. THE PRICE NEVER FALLS AS THE TERM GROWS.
--
--    THE ASSERTION THIS FILE EXISTS FOR. Every term an operator can type, on
--    every sold plan, checked pairwise. Before the cap, 11 months cost Rs 900
--    MORE than 12 on the starter plan.
do $t$
declare r record; m integer; v_prev numeric; v_this numeric;
begin
  for r in select code from public.plans where price_monthly > 0 order by code
  loop
    v_prev := 0;
    for m in 1..60 loop
      v_this := public.fn__plan_price(r.code, m);
      if v_this < v_prev then
        raise exception 'FAIL: on %, % months costs Rs % but % months costs Rs %. '
          'A school buying a longer term would pay less, and one buying a shorter '
          'term would pay more than the next term up.',
          r.code, m, v_this, m - 1, v_prev;
      end if;
      v_prev := v_this;
    end loop;
  end loop;
  raise notice '4. the price never falls as the term grows, 1 to 60 months - ok';
end $t$;

-- 5. AND IT NEVER EXCEEDS THE NEXT STANDARD TERM UP. The cap, stated directly,
--    because monotonicity alone would be satisfied by charging 11 months the
--    same as 12 AND 12 the same as 13.
do $t$
declare r record; m integer; v_this numeric; v_year numeric;
begin
  for r in select code from public.plans where price_monthly > 0
  loop
    v_year := public.fn__plan_price(r.code, 12);
    for m in 1..12 loop
      v_this := public.fn__plan_price(r.code, m);
      if v_this > v_year then
        raise exception 'FAIL: on %, % months costs Rs % against Rs % for a whole '
          'year.', r.code, m, v_this, v_year;
      end if;
    end loop;
  end loop;
  raise notice '5. no term inside a year costs more than the year - ok';
end $t$;

-- 6. THE THREE STANDARD TERMS ARE PRICED AT THEIR OWN RATE, exactly. A ladder
--    that rounded 3 months to 3 x monthly would pass every assertion above and
--    still charge the wrong price for the term actually being sold.
do $t$
declare r record;
begin
  for r in select code, price_monthly, price_quarterly, price_yearly
             from public.plans where price_monthly > 0
  loop
    if public.fn__plan_price(r.code, 1) <> r.price_monthly then
      raise exception 'FAIL: one month on % is not the monthly rate', r.code;
    end if;
    if public.fn__plan_price(r.code, 3) <> r.price_quarterly then
      raise exception 'FAIL: three months on % is Rs %, not the quarterly rate Rs %',
        r.code, public.fn__plan_price(r.code, 3), r.price_quarterly;
    end if;
    if public.fn__plan_price(r.code, 12) <> r.price_yearly then
      raise exception 'FAIL: twelve months on % is not the yearly rate', r.code;
    end if;
  end loop;
  raise notice '6. each standard term is charged its own rate - ok';
end $t$;

-- 7. THE QUOTE AND THE CHARGE ARE THE SAME NUMBER.
--
--    The console used to compute the total itself. It now asks, and this is
--    what makes that worth doing: if the two ever diverge again, this fails
--    rather than a customer noticing on an invoice.
do $t$
declare
  r record; m integer; j jsonb;
  v_admin uuid := '00000000-0000-0000-0000-00000000c001';
begin
  insert into auth.users (id, email) values (v_admin, 'operator@vendor.test')
    on conflict (id) do nothing;
  insert into public.platform_admins (user_id, email)
    values (v_admin, 'operator@vendor.test') on conflict do nothing;
  perform set_config('test.uid', v_admin::text, false);

  for r in select code from public.plans where price_monthly > 0
  loop
    foreach m in array array[1, 2, 3, 6, 11, 12, 24] loop
      j := public.fn_plan_quote(r.code, m);
      if (j->>'amount')::numeric <> public.fn__plan_price(r.code, m) then
        raise exception 'FAIL: the quote for % months on % says Rs % and the charge '
          'is Rs %.', m, r.code, j->>'amount', public.fn__plan_price(r.code, m);
      end if;
      -- The saving is what the screen shows a school to justify the longer
      -- term, so it has to be the real difference and never negative.
      if (j->>'saving')::numeric <> greatest(0,
            (j->>'list_amount')::numeric - (j->>'amount')::numeric) then
        raise exception 'FAIL: the saving on % months of % does not match the '
          'difference between the list price and the price', m, r.code;
      end if;
    end loop;
  end loop;
  raise notice '7. the quote the console shows is the price the invoice charges - ok';
end $t$;

-- 8. AND THE QUOTE REFUSES NONSENSE rather than returning a plausible number.
do $t$
declare v_msg text;
begin
  perform set_config('test.uid', '00000000-0000-0000-0000-00000000c001', false);
  begin
    perform public.fn_plan_quote('starter', 0);
    raise exception 'FAIL: quoted a term of zero months';
  exception when others then
    get stacked diagnostics v_msg = message_text;
    if v_msg like 'FAIL:%' then raise exception '%', v_msg; end if;
  end;
  begin
    perform public.fn_plan_quote('no_such_plan', 12);
    raise exception 'FAIL: quoted a plan that does not exist';
  exception when others then
    get stacked diagnostics v_msg = message_text;
    if v_msg like 'FAIL:%' then raise exception '%', v_msg; end if;
  end;
  -- The custom plan is real but unpriced, and must say so rather than quoting
  -- Rs 0, which a screen would render as "free".
  if (public.fn_plan_quote('custom', 12)->>'sold_at_list')::boolean is not false then
    raise exception 'FAIL: the custom plan reports itself as sold at a list price';
  end if;
  raise notice '8. the quote refuses nonsense and flags the unpriced plan - ok';
end $t$;

rollback;
\echo 'THE PRICE OF A TERM: ALL TESTS PASSED'

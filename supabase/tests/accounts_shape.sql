-- =============================================================================
-- The Accounts screen and the database agree about field names
--
-- WHY THIS FILE EXISTS
--
-- 0030 built fn_finance_summary and fn_profit_snapshot with a key called
-- `by_category`. 0060 rewrote both and renamed it to `expenses_by_category`.
-- Nothing on the app side was changed, so from the day a school applied bundle
-- 6 the Accounts screen threw while rendering, and the runtime guard reported
--
--     This school's database is behind the app: fn_profit_snapshot returned
--     something this version does not understand. Apply the latest file from
--     supabase/bundles...
--
-- which is backwards. The database was AHEAD; the app had never been updated.
-- A school reading that re-applies bundles it has already applied, twice, and
-- the screen still does not work.
--
-- WHY NOTHING CAUGHT IT
--
-- supabase/check-rpc-contract.sh checks that every function the app calls
-- exists and that every parameter it passes is real. It cannot see the shape of
-- what comes BACK, and `data as FinanceSummary` in TypeScript is a cast that
-- checks nothing at runtime. So a renamed key in a jsonb payload compiles,
-- deploys, and fails in front of the school.
--
-- This asserts the seam from the database side: every key the app requires is
-- actually emitted. It has to be kept in step with web/src/lib/db.ts by hand,
-- which is worth saying plainly, but a list that has to agree with one other
-- named file beats no list at all -- and it is the only thing that would have
-- caught a rename.
--
-- Run: psql -v ON_ERROR_STOP=1 -f supabase/tests/accounts_shape.sql
-- =============================================================================

\set ON_ERROR_STOP on
begin;

create or replace function auth.uid() returns uuid language sql stable as
  $$ select nullif(current_setting('test.uid', true), '')::uuid $$;

do $seed$
declare
  s1 uuid := gen_random_uuid();
  own uuid := '00000000-0000-0000-0000-00000000c001';
  cat uuid;
begin
  insert into public.schools (id, name, city) values (s1, 'Accounts School', 'Lahore');
  insert into public.subscriptions (school_id, plan_code, status, trial_ends_on)
    values (s1, 'starter', 'active', current_date + 30);
  insert into auth.users (id, email) values (own, 'owner@accounts.test')
    on conflict (id) do nothing;
  alter table public.profiles disable trigger user;
  insert into public.profiles (id, school_id, full_name, role, active)
    values (own, s1, 'The Owner', 'owner', true);
  alter table public.profiles enable trigger user;
  perform set_config('test.uid', own::text, false);

  -- One expense, so the category list has something in it. A shape asserted
  -- only against an empty school proves less: an aggregate over no rows can
  -- return the right keys by accident.
  -- A school is created with a default set of categories already in it, so
  -- this uses one rather than inserting a duplicate name.
  select id into cat from public.expense_categories
   where school_id = s1 order by sort_order, name limit 1;
  if cat is null then
    insert into public.expense_categories (school_id, name)
      values (s1, 'Shape Test Category') returning id into cat;
  end if;
  insert into public.expenses (school_id, spent_on, amount, payee, method, category_id)
    values (s1, current_date, 5000, 'K-Electric', 'cash', cat);
end $seed$;

do $shape$
declare
  -- EXACTLY what web/src/lib/db.ts requires. asFinanceSummary throws unless it
  -- finds all four, and AccountsPage reads the category list to render the
  -- "where the money went" table.
  v_required text[] := array['total_income', 'expenses', 'profit', 'expenses_by_category'];
  v_period   text;
  v_obj      jsonb;
  v_missing  text;
  v_snap     jsonb;
begin
  -- 1. fn_finance_summary, which the date-range panel calls.
  v_obj := public.fn_finance_summary(current_date - 30, current_date);
  select string_agg(k, ', ') into v_missing
  from unnest(v_required) k where not (v_obj ? k);
  if v_missing is not null then
    raise exception 'FAIL: fn_finance_summary does not return %. The Accounts '
      'screen throws on this and reports it as the school''s database being out '
      'of date, which is the wrong diagnosis. It returns: %',
      v_missing, (select string_agg(k, ', ' order by k) from jsonb_object_keys(v_obj) k);
  end if;
  if jsonb_typeof(v_obj->'expenses_by_category') <> 'array' then
    raise exception 'FAIL: expenses_by_category is a %, and the app calls .map on it',
      jsonb_typeof(v_obj->'expenses_by_category');
  end if;
  if jsonb_array_length(v_obj->'expenses_by_category') <> 1 then
    raise exception 'FAIL: one expense was recorded and the category list has % entries',
      jsonb_array_length(v_obj->'expenses_by_category');
  end if;
  -- The element shape, because a list of the wrong objects renders as blanks
  -- rather than failing, which is the quieter and worse outcome.
  if not (v_obj->'expenses_by_category'->0 ? 'category')
     or not (v_obj->'expenses_by_category'->0 ? 'total') then
    raise exception 'FAIL: a category row is %, and the app reads .category and '
      '.total from it', v_obj->'expenses_by_category'->0;
  end if;

  -- 2. fn_profit_snapshot, which is the first thing the screen calls on open.
  --    Three periods, each of which goes through the same guard.
  v_snap := public.fn_profit_snapshot();
  foreach v_period in array array['today', 'month', 'year'] loop
    if not (v_snap ? v_period) then
      raise exception 'FAIL: fn_profit_snapshot has no "%" block', v_period;
    end if;
    select string_agg(k, ', ') into v_missing
    from unnest(v_required) k where not ((v_snap->v_period) ? k);
    if v_missing is not null then
      raise exception 'FAIL: fn_profit_snapshot''s % block does not return %. '
        'It returns: %', v_period, v_missing,
        (select string_agg(k, ', ' order by k) from jsonb_object_keys(v_snap->v_period) k);
    end if;
  end loop;

  raise notice 'ok: both finance functions return every key the Accounts screen reads';
end $shape$;

-- 3. And the name that was renamed is gone, so nobody re-adds the old one
--    alongside the new and leaves two names meaning the same thing.
do $legacy$
declare v_obj jsonb := public.fn_finance_summary(current_date - 30, current_date);
begin
  if v_obj ? 'by_category' then
    raise exception 'FAIL: fn_finance_summary emits BOTH by_category and '
      'expenses_by_category. One of them is dead weight that the next reader '
      'has to work out, and the app now reads the second.';
  end if;
  raise notice 'ok: the pre-0060 name is not emitted alongside the new one';
end $legacy$;

rollback;
\echo 'ACCOUNTS SHAPE: ALL TESTS PASSED'

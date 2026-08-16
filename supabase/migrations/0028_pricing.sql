-- =============================================================================
-- Repricing to the published Pakistani market rates.
--
-- The original tiers (Rs 3,500 for 200 students) put us at the most expensive
-- entry point in the market while demoing fewer features than the incumbents.
-- These are the rates we go to market with:
--
--   Starter      up to   100 students   Rs   950 / month
--   Growth       up to   300 students   Rs 2,000 / month
--   Institution  up to 1,000 students   Rs 3,500 / month
--   Custom       above 1,000 students   quoted, contact us
--
-- Yearly stays at 10x monthly ("two months free"), matching how schools
-- actually budget — one payment at session start out of admission income.
--
-- There is deliberately NO free tier. A free plan would have to be enforced,
-- supported and migrated off, and it attracts schools that never convert. The
-- 14-day trial already removes the risk of buying blind.
--
-- Plan CODES are unchanged on purpose: subscriptions.plan_code references
-- plans(code), so renaming would orphan every existing school. Only the
-- student_limit, prices and display names move.
-- =============================================================================

update public.plans set
  name          = 'Starter (up to 100 students)',
  student_limit = 100,
  price_monthly = 950,
  price_yearly  = 9500
where code = 'starter';

update public.plans set
  name          = 'Growth (101-300 students)',
  student_limit = 300,
  price_monthly = 2000,
  price_yearly  = 20000
where code = 'growth';

update public.plans set
  name          = 'Institution (301-1000 students)',
  student_limit = 1000,
  price_monthly = 3500,
  price_yearly  = 35000
where code = 'institution';

update public.plans set
  name          = 'Custom (1000+ students - contact us)',
  student_limit = null,
  price_monthly = 0,
  price_yearly  = 0
where code = 'custom';

-- Schools already on a plan whose limit just shrank are NOT downgraded, moved,
-- or blocked. The soft-limit rule stands: going over the limit flags the school
-- on the operator console and never blocks an admission. Re-flag them so the
-- console shows the truth on the next refresh rather than after their next
-- admission.
--
-- fn_platform_refresh_counts() is the guarded entry point and would raise here
-- (a migration has no platform-admin identity), so call the internal directly.
select public.fn_refresh_all_student_counts();

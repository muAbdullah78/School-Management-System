-- =============================================================================
-- 0132  Where the school is, and a plan the school can actually choose
--
-- -----------------------------------------------------------------------------
-- TWO THINGS THE SIGNUP FORM CLAIMED AND THE SOFTWARE COULD NOT DO
--
-- 1. THE FORM PROMISES SOMETHING THAT DOES NOT EXIST. Its last line reads
--    "you can change the plan or the term any time from Settings". There is no
--    such function. Every fn_my_ in the product is listed below and not one of
--    them writes plan_code or term_months:
--
--      fn_my_assignments  fn_my_billing  fn_my_licence  fn_my_login_state
--      fn_my_next_payment fn_my_platform_invoice  fn_my_report_payment
--      fn_my_student_limit
--
--    Settings shows the plan as a read-only line. A school that picked the
--    wrong band at signup has to telephone the vendor, which is the exact
--    friction the plan chooser was added to remove.
--
-- 2. CITY IS A FREE TEXT BOX AND THERE IS NOTHING ABOVE IT. A market this
--    product is sold in by province has no province on the record, so the
--    console cannot group by one and no campaign can be aimed at one. City
--    alone does not answer it: "Model Town" is in three provinces and a
--    spelling of a city is not a region.
--
-- -----------------------------------------------------------------------------
-- WHAT A SCHOOL MAY CHANGE ABOUT ITS OWN SUBSCRIPTION, AND WHAT IT MAY NOT
--
-- This is the whole design of fn_my_choose_plan and it is deliberately narrow.
--
-- WHILE TRIALING: the plan and the term, freely. No money has moved, nothing
-- has been invoiced, and the entitlement they get during a trial is the trial.
-- This is the signup flow's second step and it is also the honest answer to
-- "they picked Starter and then counted their pupils".
--
-- WHILE ACTIVE: the TERM only.
--
--   The term is safe because it changes nothing today: it prices the NEXT
--   invoice and the next period's length. A school deciding to pay yearly from
--   now on is a decision about the future.
--
--   The PLAN is not safe, in either direction, and this is the part that would
--   have been a hole. Upward, a school that has paid for Starter until March
--   could move itself to Institution and get the bigger student limit for
--   nothing until the renewal. Downward, a school that has paid for
--   Institution would lose the limit it has already paid for. Both are wrong,
--   and the honest fix for the first is a pro-rata invoice for the difference,
--   which is a billing subsystem this product does not have and should not grow
--   by accident inside a signup change.
--
--   So an active school is refused, in words that say what to do, and the
--   operator console can still move them in one click. That is a smaller
--   product than "change your plan any time" and it is one that cannot
--   overcharge or undercharge anybody.
--
-- AND IT CANNOT BE USED TO DOWNGRADE INTO A WALL. A school with 300 pupils
-- choosing a 150-pupil plan is refused with both numbers, because the
-- alternative is a school that cannot admit a child the next morning and does
-- not know why.
-- =============================================================================

-- ------------------------------------------------------------------ region --
alter table public.schools add column if not exists region text;

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'schools_region_chk') then
    -- THE LIST IS IN THE CONSTRAINT, not in a lookup table, and that is a
    -- judgement rather than laziness. Pakistan's provinces and territories
    -- change about once a generation; a lookup table would be five more
    -- objects, a policy, a grant and a seed for a list that is shorter than
    -- this comment. When it does change, one migration edits one constraint.
    --
    -- Spelled as the Government of Pakistan spells them, because these end up
    -- on a page a school reads.
    alter table public.schools add constraint schools_region_chk check (
      region is null or region in (
        'Punjab', 'Sindh', 'Khyber Pakhtunkhwa', 'Balochistan',
        'Islamabad Capital Territory', 'Azad Jammu and Kashmir',
        'Gilgit-Baltistan'));
  end if;
end
$$;

/**
 * The regions a signup form may offer, from the constraint rather than from a
 * second list in TypeScript.
 *
 * Granted to anon: the signup form has no session, and a list of Pakistan's
 * provinces is not a secret. It exists so the form and the database cannot
 * disagree about the spelling, which is how a check constraint rejects a
 * signup at the last step.
 */
create or replace function public.fn_signup_regions()
returns text[] language sql immutable set search_path = public as $$
  select array[
    'Punjab', 'Sindh', 'Khyber Pakhtunkhwa', 'Balochistan',
    'Islamabad Capital Territory', 'Azad Jammu and Kashmir',
    'Gilgit-Baltistan'];
$$;
grant execute on function public.fn_signup_regions() to anon, authenticated;

-- ------------------------------------------- the region reaches the signup --
--
-- A NEW NAME, NOT AN EIGHTH PARAMETER, AND NOT A DROP AND RECREATE EITHER.
--
-- Migration 0127's header already spells this trap out and the first version of
-- this file walked into it anyway, so it is worth writing down what happened.
--
-- Adding an eighth parameter to fn_signup_school_on_plan is not a replacement:
-- Postgres treats a different argument list as a different function, so the
-- seven-parameter one stays standing beside it and a seven-argument call then
-- matches both and is refused as "is not unique". Public signup goes down.
--
-- Dropping the seven first fixes that on a clean install and breaks something
-- worse. Bundle 33, which creates it, HAS SHIPPED AND IS FROZEN, and a school
-- that re-pastes its bundles brings the seven-argument version back. Then both
-- exist, the Edge Function's call is ambiguous, and public signup is down on a
-- live deployment for a reason nobody would find. Preflight's re-paste check
-- caught exactly that:
--
--     ERROR:  function public.fn_signup_school_on_plan(unknown, unknown,
--             unknown, unknown, unknown, text, integer) is not unique
--
-- and the damage did not stop there: bundle 33 aborting on a re-paste means
-- everything else in it rolls back too.
--
-- So this is a new name beside the old one, which is precisely what 0127 did to
-- fn_signup_school for precisely this reason. The chain now reads
-- fn_signup_school (5) -> fn_signup_school_on_plan (7) -> this (8), each one
-- still standing, each one still correct for the caller that knows about it,
-- and none of them ambiguous with any other. The Edge Function asks for the
-- newest name it can get.
create or replace function public.fn_signup_school_on_plan_in_region(
  p_name text,
  p_city text default null,
  p_contact_name text default null,
  p_contact_phone text default null,
  p_contact_email text default null,
  p_plan_code text default 'starter',
  p_term_months integer default 12,
  p_region text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_id    uuid;
  v_plan  record;
  v_term  integer := coalesce(p_term_months, 12);
  v_trial date    := current_date + 14;
  v_region text   := nullif(btrim(coalesce(p_region, '')), '');
begin
  if nullif(btrim(p_name), '') is null then
    raise exception 'School name is required';
  end if;

  -- The plan must be one we sell today, AND ONE THAT HAS A PRICE. The `custom`
  -- plan is active, costs nothing and has no student limit, so a school
  -- choosing it at signup would get unlimited pupils for nothing for ever.
  -- Expressed as "has a price" rather than as "is not called custom", so a
  -- second by-arrangement plan added later is barred by the same clause.
  select * into v_plan from public.plans
   where code = coalesce(nullif(btrim(p_plan_code), ''), 'starter')
     and active and price_monthly > 0;
  if not found then
    if exists (select 1 from public.plans
                where code = btrim(p_plan_code) and active and price_monthly = 0) then
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

  if v_term not in (1, 3, 12) then
    raise exception 'Choose one month, three months or a year';
  end if;

  -- Checked here as well as by the constraint, so a signup gets a sentence
  -- rather than a constraint name at the last step of a six-field form.
  if v_region is not null and not (v_region = any (public.fn_signup_regions())) then
    raise exception 'There is no region called "%". Choose one of: %',
      v_region, array_to_string(public.fn_signup_regions(), ', ');
  end if;

  insert into public.schools
    (name, city, region, contact_name, contact_phone, contact_email)
  values
    (btrim(p_name), p_city, v_region, p_contact_name, p_contact_phone, p_contact_email)
  returning id into v_id;

  -- THE TRIAL IS THE SAME FOURTEEN DAYS WHATEVER THEY PICKED.
  insert into public.subscriptions
    (school_id, plan_code, status, cycle, term_months, trial_ends_on)
  values
    (v_id, v_plan.code, 'trialing',
     public.fn__cycle_for_months(v_term), v_term, v_trial);

  return jsonb_build_object(
    'school_id',     v_id,
    'trial_ends_on', v_trial,
    'plan_code',     v_plan.code,
    'plan_name',     v_plan.name,
    'term_months',   v_term,
    'region',        v_region,
    'student_limit', v_plan.student_limit,
    'first_amount',  public.fn__plan_price(v_plan.code, v_term));
end;
$$;
-- The same door as the other two names, and shut the same way. Dropping a
-- function drops its grants, and creating one hands EXECUTE to PUBLIC, so this
-- is asserted by plan_and_term.sql rather than assumed.
revoke all on function public.fn_signup_school_on_plan_in_region(
  text, text, text, text, text, text, integer, text) from public, anon, authenticated;

-- ------------------------------------------ the school chooses for itself --

/**
 * Change my own school's plan and term.
 *
 * The rules and why they are these rules are in the file header. In short:
 * while trialing, both; while active, the term only; never into a plan that is
 * already too small for the roll.
 *
 * IT RAISES NO INVOICE AND TAKES NO MONEY. A trial is free, and an active
 * school's term change prices its next renewal rather than today. Nothing in
 * this function writes to platform_invoices, which is what keeps the money path
 * in one place.
 */
create or replace function public.fn_my_choose_plan(
  p_plan_code text, p_term_months integer)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_school uuid := public.current_school_id();
  s public.subscriptions; v_plan record; v_term integer := coalesce(p_term_months, 1);
  v_count integer; v_margin integer; v_changed_plan boolean := false;
begin
  if v_school is null then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  if not public.has_role('owner', 'principal') then
    raise exception 'Only the owner or the principal can change the plan.'
      using errcode = '42501';
  end if;

  select * into s from public.subscriptions where school_id = v_school;
  if not found then
    raise exception 'This school has no subscription.';
  end if;

  -- Same wall as signup: on sale, and priced from the price list. A plan with
  -- no price has no student limit either, so self-serving onto it would be
  -- unlimited pupils for nothing.
  select * into v_plan from public.plans
   where code = coalesce(nullif(btrim(p_plan_code), ''), s.plan_code)
     and active and price_monthly > 0;
  if not found then
    raise exception
      'That plan is not one you can move onto yourself. Tell us how many '
      'children you have and we will price it with you and move you across, '
      'and nothing you have entered is affected.';
  end if;

  if v_term not in (1, 3, 12) then
    raise exception 'Choose one month, three months or a year.';
  end if;

  v_changed_plan := v_plan.code is distinct from s.plan_code;

  if v_changed_plan and s.status <> 'trialing' then
    raise exception
      'Your subscription is already running, so the plan cannot be swapped part '
      'way through a period you have paid for. Ask us and we will move you and '
      'settle the difference. You can change how often you pay from here at any '
      'time, and it takes effect at your next renewal.'
      using errcode = '22023';
  end if;

  -- NEVER INTO A WALL. Counted fresh, because the whole refusal turns on it and
  -- a stale count would wave a school into a plan it cannot admit into.
  if v_changed_plan then
    perform public.fn_refresh_student_count(v_school);
    select student_count into v_count from public.subscriptions where school_id = v_school;
    v_margin := public.plan_margin_limit(v_plan.student_limit);
    if v_plan.student_limit is not null and v_count > v_margin then
      raise exception
        'You have % children on the roll and % allows % (% with the margin), so '
        'moving there would stop you admitting anybody tomorrow. Choose a plan '
        'that fits, or ask us.',
        v_count, v_plan.name, v_plan.student_limit, v_margin
        using errcode = '22023';
    end if;
  end if;

  update public.subscriptions
     set plan_code   = v_plan.code,
         term_months = v_term,
         -- The INTENDED cycle while trialing; fn_activate_subscription confirms
         -- it when the first period is actually invoiced.
         cycle       = public.fn__cycle_for_months(v_term)
   where school_id = v_school;

  insert into public.audit_log(school_id, actor, action, entity, entity_id, before, after)
  values (v_school, auth.uid(), 'plan_chosen', 'subscriptions', v_school::text,
          jsonb_build_object('plan_code', s.plan_code, 'term_months', s.term_months),
          jsonb_build_object('plan_code', v_plan.code, 'term_months', v_term));

  return jsonb_build_object(
    'plan_code', v_plan.code, 'plan_name', v_plan.name,
    'student_limit', v_plan.student_limit,
    'term_months', v_term,
    'status', s.status,
    'trial_ends_on', s.trial_ends_on,
    'amount', public.fn__plan_price(v_plan.code, v_term),
    'what_next', case when s.status = 'trialing'
      then format('Nothing is charged today. Your free trial runs to %s and the '
                  'first invoice is raised after that.',
                  to_char(s.trial_ends_on, 'DD Mon YYYY'))
      else 'This takes effect at your next renewal. Nothing is charged today.'
      end);
end;
$$;
grant execute on function public.fn_my_choose_plan(text, integer) to authenticated;
revoke all on function public.fn_my_choose_plan(text, integer) from public, anon;

-- =============================================================================
-- Guards
-- =============================================================================
do $guard$
declare v_bad text;
begin
  -- 1. The form's region list and the database's must be one list. Two copies
  --    of seven strings is how a signup gets refused by a check constraint at
  --    the last step of a six-field form.
  if exists (
    select 1 from unnest(public.fn_signup_regions()) r
     where not exists (
       select 1 from pg_constraint c
        where c.conname = 'schools_region_chk'
          and pg_get_constraintdef(c.oid) like '%' || r || '%')) then
    raise exception '0132: fn_signup_regions offers a region that '
      'schools_region_chk would refuse. The two lists have to agree.';
  end if;

  -- 2. A school must not be able to put itself on a plan with no price. That
  --    plan has no student limit either, so it would be unlimited pupils for
  --    nothing, and it is the same hole fn_signup_school_on_plan guards.
  if (select prosrc from pg_proc p join pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'public' and p.proname = 'fn_my_choose_plan')
     not like '%price_monthly > 0%' then
    raise exception '0132: fn_my_choose_plan no longer requires a priced plan, '
      'so a school could move itself onto the by-arrangement plan and get '
      'unlimited pupils for nothing.';
  end if;

  -- 3. NO NAME IN THE SIGNUP CHAIN MAY BE OVERLOADED. Each of the three is one
  --    function with one argument list. Two copies of any of them and a call
  --    that matches both is refused as "is not unique", which takes public
  --    signup down on a live deployment. This is the guard the first version of
  --    this migration needed and did not have.
  select string_agg(x.proname || ' (' || x.n || ')', ', ') into v_bad
    from (select p.proname, count(*) as n
            from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public'
             and p.proname in ('fn_signup_school', 'fn_signup_school_on_plan',
                               'fn_signup_school_on_plan_in_region')
           group by p.proname having count(*) > 1) x;
  if v_bad is not null then
    raise exception '0132: % is overloaded. A call that matches more than one '
      'candidate is refused as not unique, and public signup stops working.',
      v_bad;
  end if;
  -- And the newest name has to be there at all, or the region is silently
  -- dropped on every signup while everything looks fine.
  if to_regprocedure('public.fn_signup_school_on_plan_in_region'
       || '(text,text,text,text,text,text,integer,text)') is null then
    raise exception '0132: fn_signup_school_on_plan_in_region is missing, so no '
      'signup can record which province the school is in.';
  end if;

  -- 4. Nothing in the self-serve path may raise an invoice. The money has one
  --    door and this is not it.
  if (select prosrc from pg_proc p join pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'public' and p.proname = 'fn_my_choose_plan')
     like '%platform_invoices%' then
    raise exception '0132: fn_my_choose_plan writes to platform_invoices. Every '
      'invoice in this product comes out of fn_activate_subscription and a '
      'second writer would be a second set of rules about money.';
  end if;
end
$guard$;

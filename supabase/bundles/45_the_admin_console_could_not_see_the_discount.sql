-- =============================================================================
-- GENERATED FILE — DO NOT EDIT.
-- Built from supabase/migrations/ by supabase/build-bundles.sh
--
-- Paste this whole file into the Supabase SQL Editor and press Run.
-- Run the bundles in order, one at a time, waiting for each to finish.
-- =============================================================================


-- ─────────────────────────────────────────────────────────────────────────
-- 0144_the_admin_console_could_not_see_the_discount.sql
-- ─────────────────────────────────────────────────────────────────────────
-- =============================================================================
-- 0144: the admin console could not see the discount, and the code creator
--       leaned on the table constraints for its refusals.
--
-- Two thin holes 0131 left.
--
-- (1) fn_platform_school_detail returned money and licence but no discount
--     block, so an operator opening one school in particular could tell you
--     they owe Rs 9,600 and could not tell you Rs 2,400 came off it. The
--     Discounts tab knew; the school's own page knew; this one did not.
--
-- (2) fn_platform_save_discount let discount_codes' check constraints do the
--     talking, so the console showed "new row for relation discount_codes
--     violates check constraint discount_codes_percent_chk (value >= 1 and
--     value <= 100)" instead of a sentence a person can act on. This adds
--     pre-checks that raise plain-language errors before the constraints ever
--     see the row.
--
-- fn_platform_school_detail is REWRITTEN IN PLACE via pg_get_functiondef +
-- regexp_replace + execute, in exactly the pattern 0077 / 0128 / 0136 use, so
-- this migration adds a discount computation and a jsonb key WITHOUT reverting
-- what those three did. Asserting the end state below makes a partial edit
-- fail here rather than silently pass.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- fn_platform_school_detail: add a discount block, in place.
-- -----------------------------------------------------------------------------
do $rewrite$
declare
  v_src text;
  v_new text;
begin
  v_src := pg_get_functiondef('public.fn_platform_school_detail(uuid)'::regprocedure);
  v_new := v_src;

  -- (a) Declare v_disc_block beside v_ready, so the function computes it later.
  --     Matched with regexp_replace and \s+ for whitespace, in the pattern 0077
  --     established: a literal-string match is defeated by one wrong indent.
  v_new := regexp_replace(v_new,
    '(v_ready jsonb := ''\[\]''::jsonb;)',
    '\1' || E'\n  v_disc record;\n  v_disc_block jsonb := ''null''::jsonb;');

  -- (b) Fill v_disc / v_disc_block just before the RETURN statement. Anchored
  --     on the specific `return jsonb_build_object(` that opens the payload.
  --     Same live rule as fn__discount_live: not removed, not past its end,
  --     use left if it counts them. Selected directly so times_applied and
  --     total_saved come with it without a second round trip.
  v_new := regexp_replace(v_new,
    '(return jsonb_build_object\(\s*''school'',)',
    '  select d.code, d.kind, d.value, d.duration, d.ends_on, d.uses_left,'
    || E'\n         d.times_applied, d.total_saved, d.trial_days_added,'
    || E'\n         d.redeemed_at, dc.description'
    || E'\n    into v_disc'
    || E'\n    from public.subscription_discounts d'
    || E'\n    join public.discount_codes dc on dc.code = d.code'
    || E'\n   where d.school_id = p_school_id'
    || E'\n     and d.removed_at is null'
    || E'\n     and (d.ends_on is null or d.ends_on >= current_date)'
    || E'\n     and (d.uses_left is null or d.uses_left > 0)'
    || E'\n   order by d.redeemed_at desc'
    || E'\n   limit 1;'
    || E'\n'
    || E'\n  if v_disc.code is not null then'
    || E'\n    v_disc_block := jsonb_build_object('
    || E'\n      ''code'', v_disc.code,'
    || E'\n      ''description'', v_disc.description,'
    || E'\n      ''kind'', v_disc.kind, ''value'', v_disc.value,'
    || E'\n      ''duration'', v_disc.duration, ''ends_on'', v_disc.ends_on,'
    || E'\n      ''uses_left'', v_disc.uses_left,'
    || E'\n      ''times_applied'', v_disc.times_applied,'
    || E'\n      ''total_saved'', v_disc.total_saved,'
    || E'\n      ''trial_days_added'', v_disc.trial_days_added,'
    || E'\n      ''redeemed_at'', v_disc.redeemed_at,'
    || E'\n      ''summary'', public.fn__discount_sentence(v_disc.kind, v_disc.value,'
    || E'\n                                              v_disc.duration, null, v_disc.ends_on));'
    || E'\n  end if;'
    || E'\n'
    || E'\n' || '  \1');

  -- (c) Insert the 'discount' key into the RETURN payload, right before
  --     'people'. Anchored on `''people'', coalesce((` which is unique.
  v_new := regexp_replace(v_new,
    '(''people'', coalesce\(\()',
    '''discount'', v_disc_block,' || E'\n\n' || '    \1');

  if v_new <> v_src then
    execute v_new;
  end if;

  -- End-state asserts. Same pattern as 0077 / 0128: a partial match must fail
  -- here rather than pass a probe.
  v_src := pg_get_functiondef('public.fn_platform_school_detail(uuid)'::regprocedure);
  if position('v_disc_block' in v_src) = 0 then
    raise exception '0144: fn_platform_school_detail was not extended with a discount block';
  end if;
  if position('''discount'', v_disc_block' in v_src) = 0 then
    raise exception '0144: fn_platform_school_detail carries v_disc_block but does not return it';
  end if;
  -- The rewrites already made by 0077, 0128 and 0136 MUST still be there. This
  -- catches a naive create-or-replace that reverts them without noticing.
  if position('fn__platform_billed(p_school_id)' in v_src) = 0
     or position('fn__platform_settled(p_school_id)' in v_src) = 0 then
    raise exception '0144: rewrite reverted 0077''s money helpers on fn_platform_school_detail';
  end if;
  if position('fn__student_limit(p_school_id)' in v_src) = 0 then
    raise exception '0144: rewrite reverted 0128''s student_limit helper';
  end if;
  raise notice '0144: fn_platform_school_detail now carries a discount block';
end $rewrite$;

-- -----------------------------------------------------------------------------
-- fn_platform_save_discount: the messages the constraint used to give.
--
-- Every check here duplicates a table constraint. That is on purpose: the
-- table constraint is the belt against a caller that bypasses this function,
-- and this block is what a person sees when they mis-fill the code creation
-- form. Without it the console shows postgres's "violates check constraint
-- discount_codes_percent_chk" and the head teacher creating a launch code has
-- to guess what that means.
--
-- ADD-ONLY: nothing here rejects a code the old version accepted. Existing
-- codes and every subscription that redeemed one are untouched.
-- -----------------------------------------------------------------------------
create or replace function public.fn_platform_save_discount(
  p_code text,
  p_description text,
  p_kind text,
  p_value numeric,
  p_duration text,
  p_duration_months integer default null,
  p_duration_until date default null,
  p_redeem_from date default null,
  p_redeem_until date default null,
  p_max_redemptions integer default null,
  p_plan_codes text[] default null,
  p_min_term_months integer default null,
  p_active boolean default true)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_code text := upper(btrim(coalesce(p_code, ''))); v_existing boolean;
  v_bad text; v_redeemed integer;
begin
  if not public.is_platform_admin() then
    raise exception 'Not permitted' using errcode = '42501';
  end if;

  -- ----- SHAPE ---------------------------------------------------------------
  if v_code !~ '^[A-Z0-9][A-Z0-9_-]{2,31}$' then
    raise exception
      'A code has to be 3 to 32 characters of letters, digits, hyphen or '
      'underscore, and it is stored in capitals. Got: %', coalesce(p_code, '');
  end if;
  if btrim(coalesce(p_description, '')) = '' then
    raise exception 'A code needs a description so the operator can tell them apart later.';
  end if;

  -- ----- KIND / VALUE --------------------------------------------------------
  if p_kind is null or p_kind not in ('percent', 'flat', 'trial_days') then
    raise exception 'Kind has to be percent, flat, or trial_days. Got: %', coalesce(p_kind, '(nothing)');
  end if;
  if p_value is null or p_value <= 0 then
    raise exception 'Amount has to be more than zero. A discount of zero is not a discount.';
  end if;
  if p_kind = 'percent' and p_value > 100 then
    raise exception
      'A percentage over 100 is not a discount, it is a payment to the customer. Got %',
      p_value::text;
  end if;
  if p_kind = 'percent' and p_value < 1 then
    -- The constraint would allow 0.5%, but a fractional percent under 1 is
    -- almost always a mis-typed rupee amount. Ask before writing.
    raise exception
      'A percentage under 1%% is unusual. If you meant flat rupees, choose Flat.';
  end if;
  if p_kind = 'trial_days' then
    if p_value <> round(p_value) or p_value < 1 or p_value > 365 then
      raise exception
        'Trial days have to be a whole number between 1 and 365. Got %', p_value::text;
    end if;
    if p_duration <> 'once' then
      raise exception
        'A trial extension moves a date and cannot repeat. Set duration to Once.';
    end if;
  end if;

  -- ----- DURATION ------------------------------------------------------------
  if p_duration is null or p_duration not in ('once','forever','months','until') then
    raise exception
      'Duration has to be once, forever, months, or until. Got %', coalesce(p_duration, '(nothing)');
  end if;
  if p_duration = 'months' then
    if p_duration_months is null or p_duration_months < 1 or p_duration_months > 120 then
      raise exception
        'For a months-long discount, choose 1 to 120 months. Got %', coalesce(p_duration_months::text, '(nothing)');
    end if;
    if p_duration_until is not null then
      raise exception 'Set the length in months OR an end date, not both.';
    end if;
  elsif p_duration = 'until' then
    if p_duration_until is null then
      raise exception 'A "runs until" discount needs an end date.';
    end if;
    if p_duration_months is not null then
      raise exception 'Set the end date OR the length in months, not both.';
    end if;
  else
    -- once / forever
    if p_duration_months is not null or p_duration_until is not null then
      raise exception
        'A % discount takes neither a length nor an end date. Clear those.', p_duration;
    end if;
  end if;

  -- ----- WINDOW / LIMITS -----------------------------------------------------
  if p_redeem_from is not null and p_redeem_until is not null
     and p_redeem_until < p_redeem_from then
    raise exception
      'The redemption window ends (%) before it starts (%). Swap the dates.',
      p_redeem_until::text, p_redeem_from::text;
  end if;
  if p_max_redemptions is not null and p_max_redemptions < 1 then
    raise exception
      'A maximum of zero redemptions is a switched-off code. Leave the box blank for unlimited, or use 1 or more.';
  end if;
  if p_min_term_months is not null
     and (p_min_term_months < 1 or p_min_term_months > 60) then
    raise exception
      'Minimum term must be between 1 and 60 months. Got %', p_min_term_months::text;
  end if;

  -- ----- PLAN CODES ----------------------------------------------------------
  if p_plan_codes is not null then
    select string_agg(x, ', ') into v_bad from unnest(p_plan_codes) x
     where x not in (select code from public.plans);
    if v_bad is not null then
      raise exception 'No such plan: %', v_bad;
    end if;
    if array_length(p_plan_codes, 1) is null then
      raise exception 'Leave the plans empty for "any plan" rather than sending none.';
    end if;
  end if;

  -- ----- WRITE ---------------------------------------------------------------
  select true into v_existing from public.discount_codes where code = v_code;

  perform public.fn__discount_write(row(
    v_code, btrim(p_description), p_kind, p_value, p_duration,
    p_duration_months, p_duration_until, p_redeem_from, p_redeem_until,
    p_max_redemptions, p_plan_codes, p_min_term_months,
    coalesce(p_active, true), auth.uid(), now(), now())::public.discount_codes);

  select count(*) into v_redeemed from public.subscription_discounts where code = v_code;

  perform public.fn__log_operator_action(
    case when v_existing then 'discount_edited' else 'discount_created' end, null,
    jsonb_build_object('code', v_code, 'kind', p_kind, 'value', p_value,
                       'duration', p_duration, 'active', coalesce(p_active, true)));

  return jsonb_build_object(
    'code', v_code, 'created', not coalesce(v_existing, false),
    'summary', public.fn__discount_sentence(p_kind, p_value, p_duration,
                                            p_duration_months, p_duration_until),
    'note', case when coalesce(v_existing, false) and v_redeemed > 0
      then format('%s school(s) already redeemed this code and keep the terms '
                  'they were given. This edit applies to new redemptions only.',
                  v_redeemed)
      else null end);
end;
$$;

grant  execute on function public.fn_platform_save_discount(
  text, text, text, numeric, text, integer, date, date, date,
  integer, text[], integer, boolean) to authenticated;
revoke all on function public.fn_platform_save_discount(
  text, text, text, numeric, text, integer, date, date, date,
  integer, text[], integer, boolean) from public, anon;

-- ─────────────────────────────────────────────────────────────────────────
-- Record what this bundle applied (no-op before 0069 creates the ledger)
-- ─────────────────────────────────────────────────────────────────────────
do $ledger$
begin
  if to_regprocedure('public.fn_record_migration(text,text,text)') is null then
    raise notice 'migration ledger not present yet — nothing recorded';
    return;
  end if;
  perform public.fn_record_migration('0144_the_admin_console_could_not_see_the_discount.sql', '45_the_admin_console_could_not_see_the_discount.sql');
end $ledger$;

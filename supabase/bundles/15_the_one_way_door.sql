-- =============================================================================
-- GENERATED FILE — DO NOT EDIT.
-- Built from supabase/migrations/ by supabase/build-bundles.sh
--
-- Paste this whole file into the Supabase SQL Editor and press Run.
-- Run the bundles in order, one at a time, waiting for each to finish.
-- =============================================================================


-- ─────────────────────────────────────────────────────────────────────────
-- 0108_the_one_way_door.sql
-- ─────────────────────────────────────────────────────────────────────────
-- =============================================================================
-- 0108: Cancelling is a one-way door, and the console does not say where it goes
--
-- THREE FINDINGS, ALL IN THE Manage DIALOG, ALL ABOUT THE SAME WORD.
--
-- 1. THE CONSOLE PROMISES SOMETHING 0106 MADE FALSE
--
-- 0079 wrote the sentences the operator reads after cancelling and after
-- archiving, and both were true when they were written:
--
--     cancel : 'Their data is untouched and they keep read and export access.'
--     archive: 'Licence cancelled - their staff can still sign in, read, print
--               and export'
--
-- 0026's rule was that a school which stops paying keeps reading. 0106 changed
-- that rule two days ago: fn__licence_permits_use refuses 'locked' and
-- 'cancelled' alike, the browser gate shows the owner an export screen and
-- shows every teacher a closed sign, and the parent portal answers nothing.
-- That was the decision and it stands. What did NOT get changed is the two
-- sentences above, which the Manage dialog still prints verbatim.
--
-- So the operator archives a departing school having just been told its staff
-- can still sign in and print, and the next morning the school's teachers
-- cannot open the software. The console lied, in writing, with a tick beside
-- it. Nothing in the schema was wrong; the words were.
--
-- 2. CANCEL TAKES A PAID SCHOOL OFFLINE THE SAME SECOND
--
-- fn_effective_status tests `s.status = 'cancelled'` ABOVE it tests the dates,
-- which is correct - a cancellation must not be undone by the calendar. But it
-- means cancelling a school that has paid through next June ends June today.
-- The dialog offers this behind one click, with a reason box, and says only
-- that the relationship is ending and the debt still stands. It never says the
-- word "today", and it never says how much of a paid period is being thrown
-- away.
--
-- 3. THERE IS NO WAY BACK
--
-- Suspend has Unsuspend. Archive has Unarchive. Cancel has NOTHING. Once the
-- status reads 'cancelled' the only route back in the whole console is
-- Activate/Renew, which raises an invoice - so undoing a mis-click on a school
-- that has already paid means either billing them twice or hand-editing the
-- subscriptions table. Archive makes this worse: it cancels as a side effect,
-- and Unarchive deliberately does not put the licence back, so archiving a
-- live customer by mistake and immediately unarchiving leaves them locked out
-- with no console path to recovery.
--
-- WHAT THIS MIGRATION DOES
--
--   a. Rewrites what cancel and archive SAY, so the console describes the
--      product as it is after 0106.
--   b. Gives cancel the two facts the operator needs before pressing it: the
--      date they have paid to, and how many days of it are being given up.
--   c. Adds fn_platform_reinstate_subscription - the missing opposite. It
--      restores the status the dates imply and cannot invent a licence: a
--      school with no paid period and a finished trial comes back locked,
--      exactly as it would have been had it never been cancelled.
--
-- WHAT IT DELIBERATELY DOES NOT DO
--
-- It does not move the 'cancelled' test below the date test in
-- fn_effective_status. A cancellation that expires by itself when the calendar
-- rolls forward is not a cancellation, and 0079 argued that correctly.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. Cancel: say what actually happens, and say what is being given up
-- ---------------------------------------------------------------------------
create or replace function public.fn_platform_cancel_subscription(
  p_school_id uuid, p_reason text
) returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
  v_owed numeric; v_sub record; v_paid_until date; v_days_given_up integer;
begin
  if not public.is_platform_admin() then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  if v_reason is null then
    raise exception 'Say why they cancelled - it is the only churn data this business will ever have';
  end if;
  select * into v_sub from public.subscriptions where school_id = p_school_id;
  if not found then
    raise exception 'Unknown school %', p_school_id;
  end if;
  if v_sub.status = 'cancelled' then
    raise exception 'That subscription is already cancelled';
  end if;

  v_owed := public.fn__platform_billed(p_school_id) - public.fn__platform_settled(p_school_id);

  -- What is being thrown away. A school cancelled on the day it expires loses
  -- nothing; one cancelled in September having paid to June loses nine months,
  -- and the operator should have read that number before pressing, not after.
  v_paid_until := case when v_sub.status = 'trialing' then v_sub.trial_ends_on
                       else v_sub.period_end end;
  v_days_given_up := greatest(0, coalesce(v_paid_until, current_date) - current_date);

  update public.subscriptions set status = 'cancelled' where school_id = p_school_id;

  perform public.fn__log_operator_action('subscription_cancelled', p_school_id,
    jsonb_build_object('reason', v_reason, 'outstanding_at_cancellation', v_owed,
                       'paid_until', v_paid_until,
                       'days_given_up', v_days_given_up));

  insert into public.audit_log(school_id, actor, action, entity, entity_id, reason)
  values (p_school_id, auth.uid(), 'subscription_cancelled', 'subscriptions',
          p_school_id::text, v_reason);

  return jsonb_build_object(
    'school_id', p_school_id, 'status', 'cancelled',
    -- Cancelling does not write off a debt, and the console must not imply it
    -- has. An invoice stays owed until it is paid, credited or voided.
    'outstanding', v_owed,
    'paid_until', v_paid_until,
    'days_given_up', v_days_given_up,
    'note', case when v_owed > 0
      then format('They still owe %s. Cancelling does not write that off - raise a '
                  || 'credit note if you are forgiving it.',
                  to_char(v_owed, 'FM999,999,999.00'))
      else 'Nothing outstanding.' end,
    -- REWRITTEN FOR 0106. The old sentence read "their data is untouched and
    -- they keep read and export access", which stopped being true the moment
    -- fn__licence_permits_use started refusing 'cancelled'.
    'data', 'Nothing is deleted. From now the owner and principal see a screen '
      || 'that downloads everything, and nobody else gets in: teachers and '
      || 'parents are shown a closed sign when they sign in.',
    'gave_up', case when v_days_given_up > 0
      then format('They had paid to %s. That %s day(s) ended today.',
                  to_char(v_paid_until, 'YYYY-MM-DD'), v_days_given_up)
      else null end,
    'reversible', 'Reinstate them from this same screen if this was a mistake. '
      || 'It puts back whatever their dates say and raises no invoice.');
end;
$$;

-- ---------------------------------------------------------------------------
-- 2. The missing opposite
--
-- Suspend/unsuspend and archive/unarchive both exist. This is the third pair,
-- and its absence made Cancel the only irreversible thing in a dialog whose own
-- heading is "the things you can do to a school SHORT of destroying it".
--
-- It restores the status the DATES imply and nothing more. It cannot be used to
-- give a licence away: a school with no period_end and a finished trial is put
-- back to exactly the locked state it was in before somebody pressed Cancel.
-- ---------------------------------------------------------------------------
create or replace function public.fn_platform_reinstate_subscription(
  p_school_id uuid, p_reason text default null
) returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_sub record; v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
  v_new public.subscription_status; v_archived timestamptz; v_effective public.subscription_status;
begin
  if not public.is_platform_admin() then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  select * into v_sub from public.subscriptions where school_id = p_school_id;
  if not found then
    raise exception 'Unknown school %', p_school_id;
  end if;
  if v_sub.status <> 'cancelled' then
    raise exception 'That subscription is not cancelled - there is nothing to reinstate';
  end if;

  -- An archived school is hidden from the console and off the renewal list, and
  -- fn_platform_archive_school cancels as part of archiving. Quietly reinstating
  -- one would leave a live licence on a school nobody can see. Unarchive first,
  -- which is one click and is the decision this is really asking about.
  select archived_at into v_archived from public.schools where id = p_school_id;
  if v_archived is not null then
    raise exception 'That school is archived. Bring them back into the list first, '
      'then reinstate the subscription.';
  end if;

  -- The status the calendar implies, with no generosity anywhere in it.
  --   paid period on record -> 'active', and fn_effective_status decides from
  --     the dates whether that reads active, grace or locked TODAY.
  --   no paid period, trial not finished -> back on the trial they had.
  --   no paid period, trial finished -> 'active' with period_end in the past,
  --     which fn_effective_status reads as locked. It is put back exactly as
  --     locked as it was, and Activate is still the only way to sell it.
  v_new := case
    when v_sub.period_end is not null then 'active'::public.subscription_status
    when v_sub.trial_ends_on is not null
         and current_date <= v_sub.trial_ends_on then 'trialing'::public.subscription_status
    else 'active'::public.subscription_status
  end;

  update public.subscriptions set status = v_new where school_id = p_school_id;
  v_effective := public.fn_effective_status(p_school_id);

  perform public.fn__log_operator_action('subscription_reinstated', p_school_id,
    jsonb_build_object('reason', v_reason, 'status', v_new,
                       'effective_status', v_effective,
                       'period_end', v_sub.period_end,
                       'trial_ends_on', v_sub.trial_ends_on));

  insert into public.audit_log(school_id, actor, action, entity, entity_id, reason)
  values (p_school_id, auth.uid(), 'subscription_reinstated', 'subscriptions',
          p_school_id::text, v_reason);

  return jsonb_build_object(
    'school_id', p_school_id,
    'status', v_effective,
    -- The honest half. Reinstating a school whose paid period ran out in March
    -- reads 'locked', and saying "reinstated" without saying that would send the
    -- operator away believing the phone would stop ringing.
    'back_in', v_effective not in ('locked', 'cancelled'),
    'note', case
      when v_effective in ('locked', 'cancelled')
        then 'Reinstated, but their dates have run out, so they are still locked. '
          || 'Renewing them is what opens the software.'
      when v_effective = 'grace'
        then 'Reinstated. They are inside their grace window, so the software works '
          || 'while the payment arrives.'
      when v_effective = 'trialing'
        then format('Reinstated onto the trial they already had, which ends %s.',
                    to_char(v_sub.trial_ends_on, 'YYYY-MM-DD'))
      else format('Reinstated. They are back in, paid to %s.',
                  to_char(v_sub.period_end, 'YYYY-MM-DD')) end,
    'invoiced', false);
end;
$$;

-- ---------------------------------------------------------------------------
-- 3. Archive: the same correction, in the place the operator reads it
--
-- Recreated whole rather than patched in place. 0101 cost a live school seven
-- migrations by matching a string across a newline that turned out to be CRLF
-- in the database and LF in the file, and the sentence below sits inside a
-- jsonb_build_array spread over three lines. A twenty-line function whose
-- source is right here does not need an anchor at all.
-- ---------------------------------------------------------------------------
create or replace function public.fn_platform_archive_school(
  p_school_id uuid, p_reason text
) returns jsonb language plpgsql security definer set search_path = public as $$
declare v_name text; v_reason text := nullif(btrim(coalesce(p_reason, '')), ''); v_owed numeric;
begin
  if not public.is_platform_admin() then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  if v_reason is null then
    raise exception 'Say why this school is being archived';
  end if;
  select name into v_name from public.schools where id = p_school_id;
  if v_name is null then
    raise exception 'Unknown school %', p_school_id;
  end if;
  if exists (select 1 from public.schools
              where id = p_school_id and archived_at is not null) then
    raise exception '% is already archived', v_name;
  end if;

  v_owed := public.fn__platform_billed(p_school_id) - public.fn__platform_settled(p_school_id);

  update public.schools
     set archived_at = now(), archived_by = auth.uid(), archive_reason = v_reason,
         -- `active` is what fn_platform_due_soon already filters on, so setting
         -- it here is what stops an archived school appearing on the renewal
         -- worklist. Two flags rather than one because they answer different
         -- questions: active is "should we chase them", archived is "should we
         -- show them at all".
         active = false
   where id = p_school_id;

  -- Cancelled as well, unless they were already. An archived school with a live
  -- licence is a school still counted in the paying total.
  update public.subscriptions set status = 'cancelled'
   where school_id = p_school_id and status <> 'cancelled';

  perform public.fn__log_operator_action('school_archived', p_school_id,
    jsonb_build_object('reason', v_reason, 'outstanding', v_owed));

  insert into public.audit_log(school_id, actor, action, entity, entity_id, reason)
  values (p_school_id, auth.uid(), 'school_archived', 'schools',
          p_school_id::text, v_reason);

  return jsonb_build_object(
    'school_id', p_school_id, 'archived', true,
    'outstanding', v_owed,
    -- Every one of these is a thing somebody will assume happened. Stating them
    -- costs a sentence; discovering them costs a customer.
    'what_this_did', jsonb_build_array(
      'Hidden from the school list and the renewal worklist',
      -- CORRECTED FOR 0106. This line used to read "their staff can still sign
      -- in, read, print and export", which was 0026's rule and was true until
      -- fn__licence_permits_use started refusing a cancelled school two days
      -- ago. An operator archiving a departing customer was being told, in
      -- writing, that its teachers would still be able to print - and they
      -- cannot.
      'Licence cancelled: the owner and principal get a screen that exports '
        || 'everything, and teachers and parents are shown a closed sign',
      'Nothing was deleted, and nothing was exported'),
    'reversible', true,
    'how_to_reverse', 'Bring them back into the list, then Reinstate. Neither '
      || 'raises an invoice.');
end;
$$;

-- ---------------------------------------------------------------------------
-- 4. Unarchive: point at the door that now exists
-- ---------------------------------------------------------------------------
create or replace function public.fn_platform_unarchive_school(p_school_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_was text; v_since timestamptz;
begin
  if not public.is_platform_admin() then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  select archive_reason, archived_at into v_was, v_since
    from public.schools where id = p_school_id;
  if v_since is null then
    raise exception 'That school is not archived';
  end if;

  update public.schools
     set archived_at = null, archived_by = null, archive_reason = null, active = true
   where id = p_school_id;

  perform public.fn__log_operator_action('school_unarchived', p_school_id,
    jsonb_build_object('was_archived_on', v_since, 'was_reason', v_was));

  return jsonb_build_object(
    'school_id', p_school_id, 'archived', false,
    -- Deliberately NOT reactivated. Unarchiving makes a school visible again;
    -- deciding what licence they get is a separate, priced decision and doing
    -- it silently here would give away a year.
    --
    -- What 0079 could not say, because it did not exist, is that there is now a
    -- difference between "we are done with this customer" and "that was the
    -- wrong row". Reinstate covers the second without selling anything.
    'note', 'Visible again, and still cancelled, so nobody at the school can get '
      || 'in yet. If they were archived by mistake, Reinstate puts back whatever '
      || 'their dates say and raises no invoice. Otherwise activate or renew them.');
end;
$$;

-- ---------------------------------------------------------------------------
-- 5. Grants
-- ---------------------------------------------------------------------------
grant  execute on function public.fn_platform_reinstate_subscription(uuid, text) to authenticated;
revoke execute on function public.fn_platform_reinstate_subscription(uuid, text) from public, anon;

-- ─────────────────────────────────────────────────────────────────────────
-- Record what this bundle applied (no-op before 0069 creates the ledger)
-- ─────────────────────────────────────────────────────────────────────────
do $ledger$
begin
  if to_regprocedure('public.fn_record_migration(text,text,text)') is null then
    raise notice 'migration ledger not present yet — nothing recorded';
    return;
  end if;
  perform public.fn_record_migration('0108_the_one_way_door.sql', '15_the_one_way_door.sql');
end $ledger$;

-- =============================================================================
-- 0114: A school can leave, and cancelling must not buy it free time
--
-- WHAT THIS ADDS
--
-- The school's own way out. Until now the only cancellation was
-- fn_platform_cancel_subscription, which the VENDOR calls and which takes
-- effect the same second - right for "we are ending this relationship", wrong
-- for a school that has paid to the end of June and would like to stop after
-- that. A product with no self-service cancellation is a product people are
-- afraid to start.
--
-- AND IT CLOSES A HOLE 0112 OPENED
--
-- 0112 added subscriptions.cancel_at_period_end so that cancelling keeps the
-- school running to the end of what it paid for. Correct, and it left something
-- behind: fn_effective_status knew nothing about the flag, so once the period
-- passed the school fell into the ordinary ladder and read 'grace'.
--
-- Grace exists for one reason, stated in 0026: the period has ended and a
-- payment is in flight, so the software keeps working while the money arrives.
-- A school that has CANCELLED has no payment in flight. Reading 'grace' would
-- have handed it a fortnight of free software for pressing Cancel, every time,
-- and the only way to notice would have been an operator wondering why a
-- departed customer was still marking attendance.
--
-- Proven before writing this, not assumed: a school with period_end three days
-- ago and cancel_at_period_end true reported 'grace'.
--
-- WHY THE STATUS IS DERIVED RATHER THAN FINALISED BY A JOB
--
-- The alternative is a nightly task that flips status to 'cancelled' when the
-- period passes. That is a second thing that has to run for the truth to be
-- true, and the day it does not run is the day a departed school is still
-- inside the software. fn_effective_status already derives every other state
-- from the dates; this is one more branch in the same ladder and it cannot fail
-- to happen.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. The status ladder learns about leaving
--
-- Recreated whole rather than patched. 0101 cost a live school seven migrations
-- by matching a string across a newline that turned out to be CRLF in the
-- database and LF in the file; a fifteen-line function whose source is right
-- here does not need an anchor at all.
--
-- The ONLY change is the third branch. Everything else is 0079's, unaltered,
-- including the comments, because this migration has no business relitigating
-- the trial and grace ladder that 0026 and 0079 argued through.
-- ---------------------------------------------------------------------------
create or replace function public.fn_effective_status(p_school_id uuid)
returns public.subscription_status
language sql stable security definer set search_path = public as $$
  select case
    -- Suspended by hand beats every date. It is the only state an operator can
    -- put a school into directly, and it must not be undone by the calendar
    -- rolling forward.
    when s.suspended_at is not null then 'locked'::public.subscription_status
    when s.status = 'cancelled' then 'cancelled'::public.subscription_status
    -- LEAVING, AND THE PERIOD HAS RUN OUT. Added by 0114. A school that has
    -- cancelled keeps working to the end of what it paid for - which the branch
    -- below still gives it, because this one only fires once period_end has
    -- passed - and then it is finished. Without this it fell through to the
    -- grace branch, and grace exists for a payment in flight: a cancelled
    -- school has none, so pressing Cancel would have bought a free fortnight.
    when s.cancel_at_period_end
         and s.period_end is not null
         and current_date > s.period_end
      then 'cancelled'::public.subscription_status
    -- Trial: live until it ends, then straight to locked (no grace on a trial —
    -- nothing has been paid, so there is no payment in flight to wait for).
    when s.status = 'trialing' then
      case when current_date <= coalesce(s.trial_ends_on, current_date)
           then 'trialing'::public.subscription_status
           else 'locked'::public.subscription_status
      end
    -- Paid: live to period_end, then grace, then locked.
    when s.period_end is null then s.status
    when current_date <= s.period_end then 'active'::public.subscription_status
    when current_date <= s.period_end
                       + coalesce(s.grace_days_override, public.grace_days())
      then 'grace'::public.subscription_status
    else 'locked'::public.subscription_status
  end
  from public.subscriptions s
  where s.school_id = p_school_id;
$$;

-- ---------------------------------------------------------------------------
-- 2. Leaving
--
-- AT PERIOD END, NEVER IMMEDIATELY. The school has paid for a period; ending
-- access the moment somebody clicks Cancel takes money already received and
-- gives nothing back for it. So the flag is set, the dates are untouched, and
-- the software keeps working until the day it was paid to.
--
-- THE REASON IS ASKED FOR AND IS OPTIONAL. 0079 calls the cancellation reason
-- "the only churn data this business will ever have" and it is right, but that
-- is an argument for asking, not for refusing to let somebody leave until they
-- explain themselves. A cancel button that demands a paragraph is a cancel
-- button people work around by stopping paying.
-- ---------------------------------------------------------------------------
create or replace function public.fn_cancel_my_subscription(p_reason text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_school uuid := public.current_school_id();
  v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
  v_sub record;
begin
  if v_school is null or not public.has_role('owner', 'principal') then
    raise exception 'Only the owner or principal can cancel the subscription'
      using errcode = '42501';
  end if;
  select * into v_sub from public.subscriptions where school_id = v_school;
  if not found then
    raise exception 'There is no subscription to cancel';
  end if;
  if v_sub.status = 'cancelled' then
    raise exception 'This subscription is already cancelled';
  end if;
  if v_sub.cancel_at_period_end then
    raise exception 'This subscription is already set to end. Nothing further is due.';
  end if;

  update public.subscriptions
     set cancel_at_period_end = true,
         -- Auto-renewal off in the same statement. Leaving it on would mean the
         -- renewal runner and this flag disagreeing about whether the school is
         -- a customer, and the schema's own constraint would still be satisfied.
         auto_renew = false
   where school_id = v_school;

  -- Recorded on BOTH sides. The audit_log entry is the school's own record of
  -- who ended it, and the operator action is the churn data.
  insert into public.audit_log(school_id, actor, action, entity, entity_id, reason)
  values (v_school, auth.uid(), 'subscription_cancel_requested', 'subscriptions',
          v_school::text, v_reason);
  perform public.fn__log_operator_action('cancel_requested_by_school', v_school,
    jsonb_build_object('reason', v_reason,
                       'runs_until', coalesce(v_sub.period_end, v_sub.trial_ends_on)));

  return jsonb_build_object(
    'cancelled', true,
    'runs_until', coalesce(v_sub.period_end, v_sub.trial_ends_on),
    -- What they keep, said plainly, because the fear that stops people
    -- cancelling is not knowing whether their records go with it.
    'keeps', 'Nothing is deleted. You keep everything until the date above, and '
      || 'you can download all of your records at any time, including afterwards.',
    'reversible', 'You can start again from this screen before that date and '
      || 'nothing will have changed.',
    'next', public.fn_my_next_payment());
end;
$$;

grant  execute on function public.fn_cancel_my_subscription(text) to authenticated;
revoke execute on function public.fn_cancel_my_subscription(text) from public, anon;

-- ---------------------------------------------------------------------------
-- 3. Changing your mind
--
-- Only while the period is still running. Once it has passed the school is
-- cancelled and coming back is a purchase, not an undo - and a function that
-- quietly reinstated a lapsed school would be giving the product away to
-- anybody who cancelled and waited.
-- ---------------------------------------------------------------------------
create or replace function public.fn_resume_my_subscription()
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_school uuid := public.current_school_id(); v_sub record;
begin
  if v_school is null or not public.has_role('owner', 'principal') then
    raise exception 'Only the owner or principal can restart the subscription'
      using errcode = '42501';
  end if;
  select * into v_sub from public.subscriptions where school_id = v_school;
  if not found or not v_sub.cancel_at_period_end then
    raise exception 'This subscription is not set to end, so there is nothing to restart';
  end if;
  if v_sub.period_end is not null and current_date > v_sub.period_end then
    raise exception 'Your subscription ended on %. Choose a plan to start again.',
      to_char(v_sub.period_end, 'FMDD Mon YYYY');
  end if;

  update public.subscriptions set cancel_at_period_end = false where school_id = v_school;

  insert into public.audit_log(school_id, actor, action, entity, entity_id)
  values (v_school, auth.uid(), 'subscription_cancel_withdrawn', 'subscriptions',
          v_school::text);
  perform public.fn__log_operator_action('cancel_withdrawn_by_school', v_school, '{}'::jsonb);

  return jsonb_build_object(
    'resumed', true,
    -- Deliberately NOT turning auto_renew back on. It was switched off by the
    -- cancellation and it depends on a payment method the school may since have
    -- removed; the schema would refuse the combination anyway. Saying so beats
    -- a school assuming renewal is automatic again when it is not.
    'note', 'Your subscription will carry on as before. Check how you pay below: '
      || 'automatic renewal was switched off when you cancelled.',
    'next', public.fn_my_next_payment());
end;
$$;

grant  execute on function public.fn_resume_my_subscription() to authenticated;
revoke execute on function public.fn_resume_my_subscription() from public, anon;

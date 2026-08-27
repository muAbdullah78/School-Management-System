-- =============================================================================
-- 0079 — A school could be started and never stopped
--
-- Phase 4 of docs/SUPER-ADMIN-DESIGN.md, first of two. 0080 does the ending;
-- this does everything up to it.
--
-- FOUR DEFECTS, reproduced on a real database.
--
-- 1. LOCKING IS PURELY CALENDAR-DRIVEN
--
--    fn_effective_status derives everything from trial_ends_on, period_end and
--    grace_days(). So a school that has stopped paying, stopped answering the
--    phone, and told a competitor it is switching stays fully live until its
--    renewal date — which may be eleven months away, because the operator
--    granted the year on trust.
--
--    There is no way to stop it. The only lever is fn_activate_subscription,
--    which only ever grants MORE time, and a direct UPDATE that RLS refuses.
--    Reproduced: no function in the schema can move a live school out of
--    'active' before its period_end.
--
-- 2. THE SAME CALENDAR, FOR EVERY SCHOOL
--
--    grace_days() is a global 14. Two real cases it gets wrong in opposite
--    directions: the school that has paid on time for three years and whose
--    accountant is on Hajj (14 days is not enough, and locking them is
--    self-harm), and the school that has needed chasing every single quarter
--    (14 days is a habit we are subsidising).
--
--    Per-school, with a reason recorded, or it becomes a favour nobody can
--    explain later.
--
-- 3. A SUSPENDED SCHOOL WOULD NOT KNOW WHY
--
--    This is the part that decides whether suspending is usable. A school whose
--    software stops with no explanation phones in a panic, and the person
--    answering is the person who suspended it. So `suspend_reason` is NOT an
--    operator note: fn_my_licence returns it and the banner shows it. If we are
--    going to stop somebody working, they get told why by the software, in the
--    same breath.
--
-- 4. A SCHOOL IS PERMANENT
--
--    34 tables reference public.schools with ON DELETE NO ACTION, and the
--    console lists every row in `schools` unconditionally. A demo school, a
--    school that never completed signup, a customer who left in 2027 — all
--    permanently in the list, forever, with nothing to distinguish them from
--    live customers.
--
--    Archive is the reversible half and the right default: hidden from the
--    console, licence dead, data completely intact. 0080 does the irreversible
--    half.
--
-- WHY NO NEW ENUM VALUE
--
-- The obvious modelling is `alter type subscription_status add value 'suspended'`.
-- Two reasons not to:
--
--   * ALTER TYPE ... ADD VALUE cannot be used in the same transaction that adds
--     it, and this project applies each bundle as ONE transaction (CI asserts
--     that). The migration would fail on its own next statement.
--
--   * 'locked' already means exactly the right thing: reading and exporting
--     never stop, new entries do. A suspended school needs identical BEHAVIOUR
--     and a different EXPLANATION, and an explanation is a text column, not an
--     enum member. Everything that switches on the enum keeps working untouched.
--
-- So suspension is `suspended_at` + `suspend_reason` on the subscription, and
-- fn_effective_status returns 'locked' while it is set. The operator console
-- and the school's own banner both distinguish the two, because both read the
-- reason.
--
-- Re-runnable.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. Columns
-- ---------------------------------------------------------------------------
alter table public.subscriptions
  add column if not exists suspended_at    timestamptz,
  add column if not exists suspended_by    uuid,
  add column if not exists suspend_reason  text,
  -- Null means "use grace_days()". An explicit number overrides it for this
  -- school only, and requires a reason for the same argument 0064 makes about
  -- a discount: a favour that leaves no trace is how a business loses track of
  -- what it has given away.
  add column if not exists grace_days_override integer,
  add column if not exists grace_override_reason text;

alter table public.schools
  add column if not exists archived_at    timestamptz,
  add column if not exists archived_by    uuid,
  add column if not exists archive_reason text;

do $ddl$
begin
  -- Suspended with no reason is the state this migration exists to prevent —
  -- see defect 3. Enforced rather than merely intended.
  if not exists (select 1 from pg_constraint where conname = 'subscriptions_suspend_chk') then
    alter table public.subscriptions add constraint subscriptions_suspend_chk
      check ((suspended_at is null and suspend_reason is null)
          or (suspended_at is not null and btrim(coalesce(suspend_reason, '')) <> ''));
  end if;
  if not exists (select 1 from pg_constraint where conname = 'subscriptions_grace_override_chk') then
    alter table public.subscriptions add constraint subscriptions_grace_override_chk
      check (grace_days_override is null
          or (grace_days_override between 0 and 180
              and btrim(coalesce(grace_override_reason, '')) <> ''));
  end if;
  if not exists (select 1 from pg_constraint where conname = 'schools_archive_chk') then
    alter table public.schools add constraint schools_archive_chk
      check ((archived_at is null and archive_reason is null)
          or (archived_at is not null and btrim(coalesce(archive_reason, '')) <> ''));
  end if;
end $ddl$;

create index if not exists idx_schools_live on public.schools(name)
  where archived_at is null;

-- ---------------------------------------------------------------------------
-- 2. The status derivation
--
-- Two changes and nothing else: a manual suspension wins over the calendar, and
-- the grace window can be per school. The trial/active/grace/locked ladder is
-- untouched — 0026 argued it carefully and this is not the migration to
-- relitigate it.
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
-- 3. The school is told why
--
-- Rewritten in place rather than restated: fn_my_licence is 90 lines that 0068
-- argued through in detail, and copying it here to add three keys would leave
-- two versions of that argument in the repository. The END STATE is asserted.
-- ---------------------------------------------------------------------------
do $rewrite$
declare v_src text; v_new text;
begin
  v_src := pg_get_functiondef('public.fn_my_licence()'::regprocedure);
  v_new := v_src;

  -- (a) the three new keys, inserted before limit_state so the reason sits
  --     beside the status it explains.
  v_new := replace(v_new,
    E'    -- The truth, always, whatever we choose to say out loud.',
    E'    -- Suspended by hand, and WHY. A school whose software stops with no\n'
    || E'    -- explanation phones in a panic, and the person answering is the person\n'
    || E'    -- who suspended it. 0079 makes the reason mandatory at the database so\n'
    || E'    -- this key can never be null while `suspended` is true.\n'
    || E'    ''suspended'',      v_sub.suspended_at is not null,\n'
    || E'    ''suspended_on'',   v_sub.suspended_at,\n'
    || E'    ''suspend_reason'', v_sub.suspend_reason,\n'
    || E'    -- The grace window that actually applies to THIS school, so the\n'
    || E'    -- banner can say "until the 28th" and be right for the school that\n'
    || E'    -- was given longer.\n'
    || E'    ''grace_days'',     coalesce(v_sub.grace_days_override, public.grace_days()),\n'
    || E'    -- The truth, always, whatever we choose to say out loud.');

  -- (b) the grace expiry must use the same per-school window, or the school is
  --     told a date the software will not honour.
  v_new := replace(v_new,
    'when v_status = ''grace''    then v_sub.period_end + public.grace_days()',
    'when v_status = ''grace''    then v_sub.period_end'
      || ' + coalesce(v_sub.grace_days_override, public.grace_days())');

  if v_new <> v_src then
    execute v_new;
  end if;

  v_src := pg_get_functiondef('public.fn_my_licence()'::regprocedure);
  if position('''suspend_reason''' in v_src) = 0 then
    raise exception '0079: fn_my_licence does not tell a suspended school why — the text it was matched on has changed. Fix the rewrite in 0079.';
  end if;
  if position('coalesce(v_sub.grace_days_override' in v_src) = 0 then
    raise exception '0079: fn_my_licence still uses the global grace window, so a school given longer would be told the wrong date';
  end if;
  raise notice '0079: fn_my_licence now explains a suspension';
end $rewrite$;

-- ---------------------------------------------------------------------------
-- 4. Suspend, and put it back
--
-- Deliberately NOT called "lock". Lock is what the calendar does; this is what a
-- person does, and the two need different words in the console or the operator
-- will not be able to tell why a school stopped.
-- ---------------------------------------------------------------------------
create or replace function public.fn_platform_suspend_school(
  p_school_id uuid, p_reason text
) returns jsonb language plpgsql security definer set search_path = public as $$
declare v_name text; v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
begin
  if not public.is_platform_admin() then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  -- The school is SHOWN this. Not an internal note.
  if v_reason is null then
    raise exception 'Give a reason — the school is shown it on their own screen';
  end if;
  select name into v_name from public.schools where id = p_school_id;
  if v_name is null then
    raise exception 'Unknown school %', p_school_id;
  end if;
  if not exists (select 1 from public.subscriptions where school_id = p_school_id) then
    raise exception '% has no subscription to suspend', v_name;
  end if;
  if exists (select 1 from public.subscriptions
              where school_id = p_school_id and suspended_at is not null) then
    raise exception '% is already suspended', v_name;
  end if;

  update public.subscriptions
     set suspended_at = now(), suspended_by = auth.uid(), suspend_reason = v_reason
   where school_id = p_school_id;

  perform public.fn__log_operator_action('school_suspended', p_school_id,
    jsonb_build_object('reason', v_reason));

  -- In the SCHOOL's own audit log too. They are entitled to a record of the
  -- vendor stopping their software, with a date and a reason, that we cannot
  -- later be vague about.
  insert into public.audit_log(school_id, actor, action, entity, entity_id, reason)
  values (p_school_id, auth.uid(), 'subscription_suspended', 'subscriptions',
          p_school_id::text, v_reason);

  return jsonb_build_object(
    'school_id', p_school_id, 'suspended', true, 'reason', v_reason,
    -- Stated in the return value so the console can say it in the confirmation
    -- rather than the operator having to remember it.
    'what_still_works', 'They can still open every screen, print and export. '
      || 'Only new entries are paused.');
end;
$$;

create or replace function public.fn_platform_unsuspend_school(
  p_school_id uuid, p_note text default null
) returns jsonb language plpgsql security definer set search_path = public as $$
declare v_was text; v_since timestamptz;
begin
  if not public.is_platform_admin() then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  select suspend_reason, suspended_at into v_was, v_since
    from public.subscriptions where school_id = p_school_id;
  if v_since is null then
    raise exception 'That school is not suspended';
  end if;

  update public.subscriptions
     set suspended_at = null, suspended_by = null, suspend_reason = null
   where school_id = p_school_id;

  -- The reason it was suspended is carried into the log entry that lifts it.
  -- Clearing the column would otherwise erase the only record of why, and
  -- "unsuspended" with no context is useless six months later.
  perform public.fn__log_operator_action('school_unsuspended', p_school_id,
    jsonb_build_object('was_suspended_on', v_since, 'was_reason', v_was,
                       'note', nullif(btrim(coalesce(p_note, '')), ''),
                       'days_suspended', (current_date - v_since::date)));

  insert into public.audit_log(school_id, actor, action, entity, entity_id, before, reason)
  values (p_school_id, auth.uid(), 'subscription_unsuspended', 'subscriptions',
          p_school_id::text, jsonb_build_object('suspend_reason', v_was),
          nullif(btrim(coalesce(p_note, '')), ''));

  return jsonb_build_object('school_id', p_school_id, 'suspended', false,
                            'status', public.fn_effective_status(p_school_id));
end;
$$;

-- ---------------------------------------------------------------------------
-- 5. Cancel, and un-cancel
--
-- Cancelled is the end of the commercial relationship while the data stays
-- exactly where it is. It is NOT archive (which hides the school) and NOT purge
-- (which destroys it) — a school that cancels in June and comes back in August
-- must find everything as it was, which happens more often than not.
-- ---------------------------------------------------------------------------
create or replace function public.fn_platform_cancel_subscription(
  p_school_id uuid, p_reason text
) returns jsonb language plpgsql security definer set search_path = public as $$
declare v_reason text := nullif(btrim(coalesce(p_reason, '')), ''); v_owed numeric;
begin
  if not public.is_platform_admin() then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  if v_reason is null then
    raise exception 'Say why they cancelled — it is the only churn data this business will ever have';
  end if;
  if not exists (select 1 from public.subscriptions where school_id = p_school_id) then
    raise exception 'Unknown school %', p_school_id;
  end if;

  v_owed := public.fn__platform_billed(p_school_id) - public.fn__platform_settled(p_school_id);

  update public.subscriptions set status = 'cancelled' where school_id = p_school_id;

  perform public.fn__log_operator_action('subscription_cancelled', p_school_id,
    jsonb_build_object('reason', v_reason, 'outstanding_at_cancellation', v_owed));

  insert into public.audit_log(school_id, actor, action, entity, entity_id, reason)
  values (p_school_id, auth.uid(), 'subscription_cancelled', 'subscriptions',
          p_school_id::text, v_reason);

  return jsonb_build_object(
    'school_id', p_school_id, 'status', 'cancelled',
    -- Cancelling does not write off a debt, and the console must not imply it
    -- has. An invoice stays owed until it is paid, credited or voided.
    'outstanding', v_owed,
    'note', case when v_owed > 0
      then format('They still owe %s. Cancelling does not write that off — raise a '
                  || 'credit note if you are forgiving it.',
                  to_char(v_owed, 'FM999,999,999.00'))
      else 'Nothing outstanding.' end,
    'data', 'Their data is untouched and they keep read and export access. '
      || 'Archive them to hide them from this list.');
end;
$$;

-- ---------------------------------------------------------------------------
-- 6. A different grace window for one school
-- ---------------------------------------------------------------------------
create or replace function public.fn_platform_set_grace(
  p_school_id uuid, p_days integer, p_reason text default null
) returns jsonb language plpgsql security definer set search_path = public as $$
declare v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
begin
  if not public.is_platform_admin() then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  if not exists (select 1 from public.subscriptions where school_id = p_school_id) then
    raise exception 'Unknown school %', p_school_id;
  end if;
  -- Null days = back to the standard window, and that needs no justification.
  -- Anything else does: a longer grace period is a favour, a shorter one is
  -- pressure, and both should be explainable a year later.
  if p_days is not null and v_reason is null then
    raise exception 'A different grace period for one school needs a reason';
  end if;
  if p_days is not null and (p_days < 0 or p_days > 180) then
    raise exception 'A grace period must be between 0 and 180 days';
  end if;

  update public.subscriptions
     set grace_days_override = p_days,
         grace_override_reason = case when p_days is null then null else v_reason end
   where school_id = p_school_id;

  perform public.fn__log_operator_action('grace_changed', p_school_id,
    jsonb_build_object('days', p_days, 'standard', public.grace_days(),
                       'reason', v_reason));

  return jsonb_build_object(
    'school_id', p_school_id,
    'grace_days', coalesce(p_days, public.grace_days()),
    'is_override', p_days is not null,
    'status', public.fn_effective_status(p_school_id));
end;
$$;

-- ---------------------------------------------------------------------------
-- 7. Archive: out of the list, data intact
--
-- The reversible half of offboarding and the right default. 0080 does the
-- irreversible half, and it refuses to run on a school that has not been
-- archived first — so archiving is also the deliberate pause between "we are
-- done with this customer" and "destroy their records".
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
      'Licence cancelled — their staff can still sign in, read, print and export',
      'Nothing was deleted, and nothing was exported'),
    'reversible', true);
end;
$$;

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
    'note', 'Visible again, and still cancelled. Activate or renew them to give '
      || 'them a licence.');
end;
$$;

-- ---------------------------------------------------------------------------
-- 8. The console list learns about all of it
--
-- DROP first: three columns and a parameter. Archived schools are excluded by
-- DEFAULT rather than by the caller remembering to ask — a console that shows
-- last year's departed customers alongside this year's is a console whose
-- totals nobody trusts.
-- ---------------------------------------------------------------------------
drop function if exists public.fn_platform_schools();
drop function if exists public.fn_platform_schools(boolean);
create function public.fn_platform_schools(p_include_archived boolean default false)
returns table (
  school_id uuid, school_name text, city text,
  contact_name text, contact_phone text,
  plan_code text, status public.subscription_status,
  expires_on date, days_left integer,
  student_count integer, student_limit integer,
  limit_state text, suggested_plan text, needs_upgrade boolean,
  outstanding numeric, last_paid_on date,
  suspended boolean, suspend_reason text, archived boolean
) language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_platform_admin() then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  return query
    select
      s.id, s.name, s.city, s.contact_name, s.contact_phone,
      sub.plan_code,
      public.fn_effective_status(s.id),
      case when sub.status = 'trialing' then sub.trial_ends_on else sub.period_end end,
      (case when sub.status = 'trialing' then sub.trial_ends_on else sub.period_end end
        - current_date)::integer,
      sub.student_count,
      p.student_limit,
      case
        when p.student_limit is null then 'ok'
        when sub.student_count <= p.student_limit then 'ok'
        when sub.student_count <= public.plan_margin_limit(p.student_limit) then 'within_margin'
        else 'over' end,
      sug.code,
      sug.code is distinct from sub.plan_code,
      public.fn__platform_billed(s.id) - public.fn__platform_settled(s.id),
      (select max(pm.paid_on) from public.platform_payments pm
        where pm.school_id = s.id),
      -- `status` reads 'locked' for a suspended school and for an expired one.
      -- These two columns are what let the console tell them apart, which is the
      -- whole reason 0079 does not add an enum value.
      sub.suspended_at is not null,
      sub.suspend_reason,
      s.archived_at is not null
    from public.schools s
    join public.subscriptions sub on sub.school_id = s.id
    join public.plans p on p.code = sub.plan_code
    cross join lateral (
      select p2.code from public.plans p2
       where p2.active and (p2.student_limit is null or p2.student_limit >= sub.student_count)
       order by p2.sort_order limit 1
    ) sug
   where coalesce(p_include_archived, false) or s.archived_at is null
   order by s.name;
end;
$$;

-- ---------------------------------------------------------------------------
-- 9. Provisioning from the console
--
-- fn_provision_school (0026) takes six positional text arguments, always gives
-- exactly 14 days, and cannot record a note. Replaced rather than extended: a
-- seventh positional text parameter on a function whose first six are all text
-- is a call site waiting to be got wrong.
--
-- It does NOT create the owner login — that needs the service_role key to mint
-- an auth user, which must never reach a browser. The Edge Function
-- `provision-school` calls this and then creates the owner, exactly as
-- `signup-school` does for self-signup. What this returns is the school and a
-- plain statement of what is still missing, so a school created here and left
-- without an owner cannot look finished.
-- ---------------------------------------------------------------------------
create or replace function public.fn_platform_create_school(p jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_id uuid; v_name text; v_plan text; v_days integer; v_trial date;
begin
  if not public.is_platform_admin() then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  if p is null or jsonb_typeof(p) <> 'object' then
    raise exception 'Give the school''s details';
  end if;

  v_name := nullif(btrim(coalesce(p->>'name', '')), '');
  if v_name is null then
    raise exception 'The school name is required';
  end if;
  -- Same name twice is almost always the operator not realising it is already
  -- there. Refused with the id, so they can go and look rather than guess.
  if exists (select 1 from public.schools
              where lower(btrim(name)) = lower(v_name) and archived_at is null) then
    raise exception 'A school called "%" already exists (%). Archive it first if this is a different one.',
      v_name, (select id from public.schools
                where lower(btrim(name)) = lower(v_name) and archived_at is null limit 1);
  end if;

  v_plan := coalesce(nullif(btrim(coalesce(p->>'plan_code', '')), ''), 'starter');
  if not exists (select 1 from public.plans where code = v_plan) then
    raise exception 'Unknown plan %', v_plan;
  end if;

  v_days := coalesce((p->>'trial_days')::integer, 14);
  if v_days < 0 or v_days > 180 then
    raise exception 'A trial must be between 0 and 180 days';
  end if;
  v_trial := current_date + v_days;

  insert into public.schools (name, city, contact_name, contact_phone, contact_email, notes)
  values (v_name,
          nullif(btrim(coalesce(p->>'city', '')), ''),
          nullif(btrim(coalesce(p->>'contact_name', '')), ''),
          nullif(btrim(coalesce(p->>'contact_phone', '')), ''),
          nullif(btrim(lower(coalesce(p->>'contact_email', ''))), ''),
          nullif(btrim(coalesce(p->>'notes', '')), ''))
  returning id into v_id;

  insert into public.subscriptions (school_id, plan_code, status, trial_ends_on)
  values (v_id, v_plan, 'trialing', v_trial);

  return jsonb_build_object(
    'school_id', v_id, 'name', v_name, 'plan_code', v_plan,
    'trial_ends_on', v_trial, 'trial_days', v_days,
    -- Stated, not implied. A school row with no owner login is invisible from
    -- the school's side: nobody can sign in, and the console would show it as a
    -- perfectly ordinary trialing customer.
    'still_needed', 'Nobody can sign in to this school yet. Create the owner '
      || 'login, or send them the signup link.');
end;
$$;

-- ---------------------------------------------------------------------------
-- 10. Grants
-- ---------------------------------------------------------------------------
grant  execute on function public.fn_platform_schools(boolean)   to authenticated;
revoke execute on function public.fn_platform_schools(boolean) from public, anon;
grant  execute on function public.fn_platform_suspend_school(uuid, text)   to authenticated;
revoke execute on function public.fn_platform_suspend_school(uuid, text) from public, anon;
grant  execute on function public.fn_platform_unsuspend_school(uuid, text)   to authenticated;
revoke execute on function public.fn_platform_unsuspend_school(uuid, text) from public, anon;
grant  execute on function public.fn_platform_cancel_subscription(uuid, text)   to authenticated;
revoke execute on function public.fn_platform_cancel_subscription(uuid, text) from public, anon;
grant  execute on function public.fn_platform_set_grace(uuid, integer, text)   to authenticated;
revoke execute on function public.fn_platform_set_grace(uuid, integer, text) from public, anon;
grant  execute on function public.fn_platform_archive_school(uuid, text)   to authenticated;
revoke execute on function public.fn_platform_archive_school(uuid, text) from public, anon;
grant  execute on function public.fn_platform_unarchive_school(uuid)   to authenticated;
revoke execute on function public.fn_platform_unarchive_school(uuid) from public, anon;
grant  execute on function public.fn_platform_create_school(jsonb)   to authenticated;
revoke execute on function public.fn_platform_create_school(jsonb) from public, anon;

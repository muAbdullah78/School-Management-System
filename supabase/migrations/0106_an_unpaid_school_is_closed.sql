-- =============================================================================
-- 0106: An unpaid school stays open to everybody except the person who pays
--
-- TWO THINGS THAT COST THIS BUSINESS MONEY, BOTH MEASURED ON THE CONSOLE.
--
-- 1. THE TRIAL COULD BE EXTENDED FOREVER
--
-- fn_extend_trial caps ONE call at 30 days and caps nothing else. The operator
-- console renders a "+14d trial" button with no confirmation, so fourteen days
-- is one click, and a hundred and forty days is ten clicks. 0027's own comment
-- above the function reads:
--
--     Deliberately capped: an unbounded "extend" button turns into a free tier
--     by accident.
--
-- and the cap it describes is per press. The free tier shipped.
--
-- The decision is that there are NO extensions. A school that needs more time
-- is put on a plan, which is a conversation and an invoice rather than a
-- button. So the function refuses, in words, rather than being dropped: a
-- console still carrying the old button gets a sentence a person can act on
-- instead of "function does not exist".
--
-- 2. AN UNPAID SCHOOL'S PARENTS NEVER NOTICED
--
-- 0026 decided that a locked school may still read and export everything, and
-- for the OFFICE that remains right: their records are their own and holding
-- them hostage is how a late payment becomes a legal complaint.
--
-- But it was never only the office. The parent portal is a separate route in
-- the app, outside the browser's licence gate entirely, and every portal
-- function is SECURITY DEFINER, so it answers whatever the subscription says.
-- A school that stopped paying kept a working parent portal: fees, attendance
-- and results, for every family, indefinitely. Nobody in the building had any
-- reason to notice, which is the whole problem, because the parents are the
-- people who make a school renew.
--
-- So the parent portal now closes with the licence. The office does not: it
-- keeps read and export, and the write refusal in enforce_school_id() is
-- unchanged. The person who can fix it keeps the means to fix it, and the
-- people who apply the pressure feel it.
--
-- WHY TWO FUNCTIONS COVER THE WHOLE PORTAL
--
-- Measured, not assumed. Every child-scoped portal function calls
-- fn__assert_my_child first, and fn_portal_me is the entry point that lists
-- the children. Nothing else in the portal reaches data:
--
--   fn_portal_child_attendance  fn__assert_my_child
--   fn_portal_child_fees        fn__assert_my_child
--   fn_portal_child_ledger      fn__assert_my_child
--   fn_portal_child_results     fn__assert_my_child
--   fn_portal_me                the entry point
--
-- Guarding the choke point rather than five call sites is the difference
-- between a rule and five copies of a rule, which is what 0097 and 0100 were
-- both about.
--
-- Re-runnable.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. One answer to "may this school be used right now"
--
-- SECURITY DEFINER because it reads subscriptions, which a parent cannot see,
-- and it takes no argument a caller could point somewhere else: the school is
-- always the caller's own. That is the difference between this and the shape
-- check-definer-idor.py exists to catch.
-- ---------------------------------------------------------------------------
create or replace function public.fn__licence_permits_use()
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce(
    public.fn_effective_status(public.current_school_id())
      not in ('locked', 'cancelled'),
    -- No school context at all is not a licence question. Say yes and let the
    -- caller's own authorisation refuse, so a bug here cannot become a lock.
    true);
$$;

revoke all on function public.fn__licence_permits_use() from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2. The parent portal closes with the licence
--
-- WORDED FOR A PARENT, not for us. They cannot pay this bill and telling them
-- about a subscription they have no part in would send them to the school
-- angry at the wrong thing. It says the school will switch it back on, because
-- that is true and it is the sentence that makes a parent ring the office,
-- which is the point.
-- ---------------------------------------------------------------------------
create or replace function public.fn__require_live_licence() returns void
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.fn__licence_permits_use() then
    raise exception 'The parent portal for this school is closed at the moment. '
      'Please contact the school office; they can switch it back on.'
      using errcode = '42501';
  end if;
end;
$$;

revoke all on function public.fn__require_live_licence() from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 3. The two choke points, patched from their own definitions
--
-- Whitespace-blind, per supabase/check-patch-anchors.py: an anchor that assumes
-- one indentation matched on every database built here and missed on the first
-- real school, and took a whole bundle down with it.
--
-- The check goes FIRST in both, before "Not a parent account" and before any
-- read. A closed portal is not a place to answer questions about whose child is
-- whose.
-- ---------------------------------------------------------------------------
do $patch$
declare
  v_targets text[] := array['fn__assert_my_child', 'fn_portal_me'];
  v_name text; v_src text; v_new text; v_missing text[] := '{}';
begin
  foreach v_name in array v_targets loop
    begin
      select pg_get_functiondef(p.oid) into v_src
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'public' and p.proname = v_name;

      if v_src is null then
        v_missing := v_missing || v_name;
      elsif v_src like '%fn__require_live_licence%' then
        raise notice '0106: % already closes with the licence', v_name;
      else
        -- The first statement after the body's own `begin`. Not the shared
        -- fn__patch_after_gate from 0101: that one aims after a permission
        -- gate, and here the licence check must come BEFORE the gate, because
        -- "not your child" is an answer and a closed portal should give none.
        v_new := regexp_replace(v_src, '^begin[ \t\r]*$',
                   'begin' || chr(10) || '  perform public.fn__require_live_licence();',
                   'n');
        if v_new = v_src then
          v_missing := v_missing || v_name;
        else
          execute v_new;
        end if;
      end if;
    exception when others then
      v_missing := v_missing || (v_name || ' (' || sqlerrm || ')');
    end;
  end loop;

  if array_length(v_missing, 1) is not null then
    -- A WARNING, not an exception: this file is pasted inside a bundle the SQL
    -- editor runs as one transaction, and raising here would revert everything
    -- else in it. supabase/verify.sql names what is outstanding.
    raise warning '0106: the parent portal does NOT close with the licence for: %. '
      'An unpaid school keeps a working portal. Run supabase/verify.sql.',
      array_to_string(v_missing, ', ');
  end if;
end $patch$;

-- ---------------------------------------------------------------------------
-- 4. There are no trial extensions
--
-- The function stays and refuses, rather than being dropped. An operator
-- console that has not been redeployed still carries the button, and
-- "Trials are not extended" is something a person can act on where
-- "function public.fn_extend_trial does not exist" is not.
-- ---------------------------------------------------------------------------
create or replace function public.fn_extend_trial(p_school_id uuid, p_days integer default 14)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if not public.is_platform_admin() then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  raise exception 'Trials are not extended. A school that needs more time is '
    'activated on a plan, which is an invoice and a conversation rather than a '
    'button. The trial is fourteen days, once.'
    using errcode = '22023';
end;
$$;

-- ---------------------------------------------------------------------------
-- 5. Did it take?
-- ---------------------------------------------------------------------------
do $assert$
declare v_bad text[] := '{}';
begin
  if to_regprocedure('public.fn__licence_permits_use()') is null then
    v_bad := v_bad || 'fn__licence_permits_use is missing';
  end if;
  if not exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'fn__assert_my_child'
      and p.prosrc like '%fn__require_live_licence%') then
    v_bad := v_bad || 'the parent portal still answers for an unpaid school';
  end if;
  if not exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'fn_portal_me'
      and p.prosrc like '%fn__require_live_licence%') then
    v_bad := v_bad || 'the portal entry point still answers for an unpaid school';
  end if;
  if exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'fn_extend_trial'
      and p.prosrc not like '%Trials are not extended%') then
    v_bad := v_bad || 'the trial can still be extended';
  end if;

  if array_length(v_bad, 1) is null then
    raise notice '0106: the portal closes with the licence, and trials are not extended';
  else
    raise warning '0106: %. Everything else in this bundle applied. Send the '
      'output of supabase/verify.sql.', array_to_string(v_bad, '; ');
  end if;
end $assert$;

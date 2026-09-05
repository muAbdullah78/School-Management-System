-- =============================================================================
-- 0096  Starting again
--
-- WHY. Every school's first week is the same: somebody types in fifteen made-up
-- children to see how it works, raises a few challans, marks a register, and
-- then wants the practice gone before the real admissions start. Until 0094
-- nothing could be deleted at all. With 0094 they can now remove records one at
-- a time, which is right for a typo and absurd for forty rows of practice.
--
-- WHAT IT DELETES. Every operational row belonging to the school: children,
-- families, staff records, classes, sessions, the fee structure, challans,
-- receipts, attendance, marks, exams, certificates, expenses, messages.
--
-- WHAT IT KEEPS, and each for a reason:
--
--   the school, its subscription and its settings   it is the same school
--   every login                                     a person is not data. The
--     owner would otherwise reset themselves out of their own account, and
--     deleting a login here cannot remove the auth user, so the address could
--     never be reused. Unwanted logins are removed one at a time on the Staff
--     screen, where the reason for each refusal can be shown.
--   the audit log                                   we do not build a button
--     that erases an audit trail. Not once, not for a trial.
--   anything of OURS: platform invoices, payments, claims, exports, operator
--     actions and support visits, and the school's review. Those are the
--     vendor's records that happen to name this school, and 0080 already made
--     them survive a school being deleted outright.
--
-- WHY ONLY DURING A TRIAL. A paying school with three years of fee history has
-- no legitimate use for this and one bad afternoon would end them. The trial is
-- exactly the period when the data is known to be practice.
--
-- HOW IT DELETES, AND WHY NOT A HAND-WRITTEN ORDER. Fifty-six tables carry a
-- school_id. A hand-written delete order would be wrong the first time somebody
-- adds a table and would fail with a foreign key error a school cannot act on.
-- So this loops: try every table, ignore the ones still referenced, go round
-- again, and stop when a pass changes nothing. Then it CHECKS, and raises if
-- any row is left. A new table is therefore covered the day it is created, and
-- if it somehow is not, this says so loudly instead of half-clearing a school.
-- =============================================================================

create or replace function public.fn_reset_school_data(p_confirm_name text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_school uuid := public.current_school_id();
  v_name   text;
  v_status public.subscription_status;
  -- Ours, not theirs. Never cleared by a school.
  v_keep   text[] := array[
    'subscriptions', 'school_settings', 'profiles', 'audit_log', 'reviews',
    'operator_actions', 'operator_sessions', 'platform_invoices',
    'platform_payments', 'platform_payment_claims', 'platform_exports'
  ];
  v_tables text[];
  v_t      text;
  v_before bigint;
  v_after  bigint;
  v_pass   int := 0;
  v_left   text[];
  v_total  bigint := 0;
  v_n      bigint;
begin
  if not public.has_role('owner') then
    raise exception 'Only the owner may clear the school''s data';
  end if;

  select s.name into v_name from public.schools s where s.id = v_school;
  select sub.status into v_status from public.subscriptions sub where sub.school_id = v_school;

  if v_status is distinct from 'trialing' then
    raise exception 'This is only available during the free trial. Ask us if you '
                    'really need to start again.';
  end if;

  -- Typing the school's name is the whole confirmation. A dialog that only
  -- needs one click gets clicked.
  if btrim(lower(coalesce(p_confirm_name, ''))) <> btrim(lower(coalesce(v_name, ''))) then
    raise exception 'Type the school''s name exactly to confirm';
  end if;

  select array_agg(c.relname order by c.relname) into v_tables
    from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
    join pg_attribute a on a.attrelid = c.oid and a.attname = 'school_id' and a.attnum > 0
   where n.nspname = 'public' and c.relkind = 'r'
     and not (c.relname = any(v_keep));

  -- Count what is about to go, for the message afterwards.
  foreach v_t in array v_tables loop
    execute format('select count(*) from public.%I where school_id = $1', v_t)
      into v_n using v_school;
    v_total := v_total + v_n;
  end loop;

  -- The fixpoint. Ten passes is far more than the dependency depth of this
  -- schema; the check below is what actually decides whether it worked.
  loop
    v_pass := v_pass + 1;
    v_before := 0; v_after := 0;
    foreach v_t in array v_tables loop
      execute format('select count(*) from public.%I where school_id = $1', v_t)
        into v_n using v_school;
      v_before := v_before + v_n;
      begin
        execute format('delete from public.%I where school_id = $1', v_t) using v_school;
      exception when foreign_key_violation then
        -- Something else still points at these rows. A later pass will have
        -- removed it.
        null;
      end;
      execute format('select count(*) from public.%I where school_id = $1', v_t)
        into v_n using v_school;
      v_after := v_after + v_n;
    end loop;
    exit when v_after = 0 or v_after = v_before or v_pass >= 10;
  end loop;

  -- Prove it, rather than assume it. A half-cleared school is worse than an
  -- uncleared one, because the owner believes it is empty.
  v_left := array[]::text[];
  foreach v_t in array v_tables loop
    execute format('select count(*) from public.%I where school_id = $1', v_t)
      into v_n using v_school;
    if v_n > 0 then v_left := v_left || v_t; end if;
  end loop;

  if array_length(v_left, 1) > 0 then
    raise exception 'Could not clear everything: % still has rows. Nothing has been '
                    'left half done on purpose; please tell us.', array_to_string(v_left, ', ');
  end if;

  perform public.fn__log_operator_action('school.data_reset', v_school,
    jsonb_build_object('school', v_name, 'rows_removed', v_total, 'passes', v_pass));

  return jsonb_build_object('cleared', true, 'rows_removed', v_total, 'school', v_name);
end;
$$;

-- Postgres grants EXECUTE to PUBLIC by default and anon inherits it. This one
-- empties a school; it is not reachable without a login.
revoke execute on function public.fn_reset_school_data(text) from public, anon;
grant execute on function public.fn_reset_school_data(text) to authenticated;

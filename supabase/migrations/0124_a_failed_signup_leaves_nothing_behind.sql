-- =============================================================================
-- 0124 - A failed signup leaves nothing behind
--
-- REPORTED BY A SCHOOL, alongside 0123: they tried to sign up twice with the
-- same email address, the second attempt was correctly refused, and it left a
-- school behind that nobody could open and they could not delete.
--
-- WHAT THEY WERE LOOKING AT
--
--   [Al Qalam School]          1 active owner, 2 students
--   [Choudhary Public School]  1 active owner, 0 students   <- theirs
--   [Chaudhary School]         0 active owners, 0 students  <- the wreckage
--
-- WHY. supabase/functions/signup-school does the only thing it can do in the
-- order it must: the school has to exist before the login, because the login's
-- profile needs a school to attach to. So on "email already registered" it
-- rolls the school back:
--
--     await admin.from('schools').delete().eq('id', schoolId)
--
-- That statement CANNOT SUCCEED. A trigger on schools creates the
-- school_settings row the instant the school is inserted, and
-- school_settings.school_id is ON DELETE NO ACTION, so the delete fails with a
-- foreign key violation every single time. Reproduced:
--
--     ERROR: update or delete on table "schools" violates foreign key
--            constraint "school_settings_school_id_fkey" on table
--            "school_settings"
--
-- And the result of that call is never read, so the function returns the
-- correct, friendly "that email already has an account" and the school stays.
-- A signup creates rows in SIX tables (audit_log 8, expense_categories 8,
-- message_templates 7, operator_actions 1, school_settings 1, subscriptions 1),
-- so no single delete was ever going to do it.
--
-- WHAT IT COSTS. The school is left in the operator console looking like an
-- ordinary new customer that nobody can open, and getting rid of it needs a
-- platform admin to archive it, take an export of it and then purge it, which
-- are three deliberate safeguards written for a REAL school and exactly the
-- wrong ceremony for a signup that never happened.
--
-- WHY A FUNCTION AND NOT A CASCADE. Making school_settings.school_id ON DELETE
-- CASCADE would fix this one delete and quietly widen every other delete of a
-- schools row for ever. The fix is instead a named, granted, logged operation
-- whose result the Edge Function can check, and which REFUSES on anything that
-- is not a failed signup.
--
-- THE SAFETY PROPERTY IS "NO OWNER AND NO PUPIL", not a time window. A real
-- school always has an owner profile, and a school with a pupil is real
-- whatever else is true of it. A school that has sat ownerless for a month is
-- still a signup that never completed.
--
-- Re-runnable.
-- =============================================================================

create or replace function public.fn_signup_rollback(p_school_id uuid)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_school    record;
  v_profiles  bigint;
  v_students  bigint;
  v_payments  bigint;
  r           record;
  v_n         bigint;
  v_total     bigint := 0;
  v_deleted   jsonb := '{}'::jsonb;
  v_pass      integer := 0;
  v_progress  boolean;
  v_left      text;
begin
  select * into v_school from public.schools where id = p_school_id;
  if not found then
    -- Not an error. The caller wants the school gone and it is gone, and a
    -- rollback that raises on a second attempt is a rollback nobody can retry.
    return jsonb_build_object('school_id', p_school_id, 'already_absent', true);
  end if;

  select count(*) into v_profiles from public.profiles where school_id = p_school_id;
  select count(*) into v_students from public.students where school_id = p_school_id;
  select count(*) into v_payments from public.payments  where school_id = p_school_id;

  if v_profiles > 0 or v_students > 0 or v_payments > 0 then
    raise exception 'This is not a failed signup. "%" has % login(s), % pupil(s) '
      'and % payment(s), so it is somebody''s school. Archive, export and purge '
      'it from the console if it really is to be deleted: those three steps are '
      'there so a real school cannot go by accident.',
      v_school.name, v_profiles, v_students, v_payments
      using errcode = '42501';
  end if;

  -- AND THE OPERATOR'S OWN MONEY, which is a different question from whether
  -- the school is real. platform_invoices and platform_payments are the two
  -- tables this function will not touch under any circumstances: they are the
  -- vendor's accounting record of what was billed and collected, they outlive
  -- the school they refer to on purpose, and fn_platform_purge_school leaves
  -- them alone for the same reason. A signup that never completed has none, so
  -- finding one means this is not what it appears to be.
  if exists (select 1 from public.platform_invoices where school_id = p_school_id)
     or exists (select 1 from public.platform_payments where school_id = p_school_id) then
    raise exception 'There are invoices or payments on "%" and this would '
      'destroy the record of them. Nothing has been deleted.', v_school.name
      using errcode = '42501';
  end if;

  -- THE RECORD GOES FIRST, and with school_id null so it survives the delete
  -- of the school it describes. operator_actions.school_id is ON DELETE NO
  -- ACTION, so a row pointing at this school would block the delete, and a
  -- rollback that erases its own record is not an audit trail. Same reasoning
  -- as fn_platform_purge_school, which is where this shape comes from.
  perform public.fn__log_operator_action('signup_rolled_back', null,
    jsonb_build_object(
      'school_id',   p_school_id,
      'school_name', v_school.name,
      'city',        v_school.city,
      'contact_email', v_school.contact_email,
      'created_at',  v_school.created_at,
      'reason', 'no owner login and no pupil: the signup did not complete'));

  -- Up to 12 passes, the same loop fn_platform_purge_school uses and for the
  -- same reason: the tables point at each other, so a pass that hits a
  -- dependency simply comes back next time.
  --
  -- THE TABLE LIST IS DERIVED FROM THE FOREIGN KEYS, not from
  -- fn__school_data_tables(), and the difference is the whole reason the first
  -- version of this failed its own probe:
  --
  --     ERROR: update or delete on table "schools" violates foreign key
  --            constraint "operator_actions_school_id_fkey"
  --
  -- fn__school_data_tables() lists the 51 tables that hold a SCHOOL'S data.
  -- Fifty-nine tables carry a foreign key to schools, and the eight it leaves
  -- out are the platform's own: operator_actions, operator_sessions,
  -- platform_exports, platform_invoices, platform_payment_claims,
  -- platform_payments, student_count_snapshots, subscriptions. A signup writes
  -- to two of those, so a loop over the 51 could never finish the job.
  --
  -- Deriving the list from pg_constraint means a table added next year is
  -- covered without anybody remembering this function, and the two money
  -- tables are the single named exception, already refused above.
  loop
    v_pass := v_pass + 1;
    v_progress := false;
    for r in
      select c.conrelid::regclass::text as table_name
        from pg_constraint c
       where c.confrelid = 'public.schools'::regclass
         and c.contype = 'f'
         and c.conrelid::regclass::text not in ('platform_invoices', 'platform_payments')
       group by 1
       order by 1
    loop
      begin
        execute format('delete from public.%I where school_id = $1', r.table_name)
          using p_school_id;
        get diagnostics v_n = row_count;
        if v_n > 0 then
          v_progress := true;
          v_total := v_total + v_n;
          v_deleted := v_deleted || jsonb_build_object(
            r.table_name, coalesce((v_deleted->>r.table_name)::bigint, 0) + v_n);
        end if;
      exception
        -- ONLY a dependency is swallowed. Any other error is a real fault and
        -- must not be: a permission problem or a trigger raising would
        -- otherwise look identical to "try again next pass", and the loop would
        -- report a clean rollback of a school it never touched.
        when foreign_key_violation then null;
      end;
    end loop;
    exit when not v_progress or v_pass >= 12;
  end loop;

  delete from public.schools where id = p_school_id;
  if found then
    return jsonb_build_object(
      'school_id', p_school_id, 'school_name', v_school.name,
      'rows_removed', v_total, 'by_table', v_deleted, 'passes', v_pass);
  end if;

  -- Never silently. If something still points at the school, name it.
  select string_agg(c.conrelid::regclass::text, ', ')
    into v_left
    from pg_constraint c
   where c.confrelid = 'public.schools'::regclass and c.contype = 'f';
  raise exception 'Could not remove "%" after % passes. Something outside the '
    'school-scoped tables still refers to it; the tables with a foreign key to '
    'schools are: %.', v_school.name, v_pass, v_left;
end;
$$;

-- Service role only, exactly like fn_signup_school, which is the only caller.
-- Never granted to a client role: a browser able to call this could delete a
-- school that had not yet admitted its first pupil.
revoke execute on function public.fn_signup_rollback(uuid) from public, anon, authenticated;
grant  execute on function public.fn_signup_rollback(uuid) to service_role;

-- ---------------------------------------------------------------------------
-- THE GUARD, and it asserts the BEHAVIOUR both ways: a failed signup goes, and
-- a school with an owner or a pupil does not. A check that the function exists
-- would pass on a body that raised every time, which is the state this
-- migration is fixing.
--
-- The probe runs in a subtransaction that is rolled back either way.
-- ---------------------------------------------------------------------------
do $check$
declare
  v_gone     boolean := false;
  v_refused  boolean := false;
  v_had_rows boolean := false;
begin
  begin
    declare
      v_a uuid; v_b uuid; v_res jsonb; v_stu uuid;
    begin
      -- 1. A failed signup: created, then nothing else. It must go, and the
      --    count must show it took its six tables of seed rows with it.
      v_a := (public.fn_signup_school('0124 failed signup', 'Lahore', 'A Person',
                                      '03001234567', 'a@probe.invalid')
              ->> 'school_id')::uuid;
      v_res := public.fn_signup_rollback(v_a);
      v_had_rows := (v_res->>'rows_removed')::bigint > 0;
      v_gone := not exists (select 1 from public.schools where id = v_a);

      -- 2. A school with a pupil must be refused, however empty it looks
      --    otherwise. This is the half that stops the function being a way to
      --    delete a real school without archiving or exporting it.
      v_b := (public.fn_signup_school('0124 real school', 'Lahore', 'A Person',
                                      '03001234567', 'b@probe.invalid')
              ->> 'school_id')::uuid;
      insert into public.students (school_id, full_name, admission_date, status)
        values (v_b, '0124 pupil', current_date, 'active') returning id into v_stu;
      begin
        perform public.fn_signup_rollback(v_b);
        v_refused := false;
      exception when insufficient_privilege then
        v_refused := true;
      end;
    end;
    raise exception 'rollback the probe';
  exception
    when others then
      if sqlerrm <> 'rollback the probe' then
        raise warning '0124: the behaviour check could not finish (%). The '
          'function is installed; supabase/verify.sql says whether it is '
          'correct.', sqlerrm;
        return;
      end if;
  end;

  if not v_gone then
    raise exception '0124: a failed signup still leaves a school behind, which '
      'is the whole defect.';
  end if;
  if not v_had_rows then
    raise exception '0124: the school row went but nothing else did, so the '
      'settings, subscription and seeded templates are orphaned.';
  end if;
  if not v_refused then
    raise exception '0124: a school WITH A PUPIL IN IT was rolled back. That is '
      'far worse than the orphan this was written to remove.';
  end if;
  raise notice '0124: a failed signup leaves nothing behind, and a school with '
    'a pupil in it cannot be rolled back';
end $check$;

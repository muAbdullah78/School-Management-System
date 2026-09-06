-- =============================================================================
-- An unpaid school is closed to the parents, and open to the office
--
-- WHY THIS FILE EXISTS
--
-- 0026 decided that a locked school may still read and export everything. For
-- the OFFICE that is right and stays: their records are their own, and holding
-- them hostage is how a late payment becomes a legal complaint rather than a
-- payment.
--
-- It was never only the office, though. The parent portal is a separate route
-- outside the browser's licence gate, and every portal function is SECURITY
-- DEFINER, so it answered whatever the subscription said. A school that stopped
-- paying kept a fully working parent portal -- fees, attendance and results, for
-- every family, indefinitely -- and nobody in the building had any reason to
-- notice. The parents are the people who make a school renew, and they felt
-- nothing.
--
-- So this asserts the shape of the decision, in both directions, because half
-- of it is as important as the other half:
--
--   a locked school's parent  gets nothing
--   a locked school's office  still reads and still exports
--   a paid school's parent    is unaffected
--
-- and that trials cannot be extended, at all, by anybody.
--
-- Run: psql -v ON_ERROR_STOP=1 -f supabase/tests/unpaid_school.sql
-- =============================================================================

\set ON_ERROR_STOP on
begin;

create or replace function auth.uid() returns uuid language sql stable as
  $$ select nullif(current_setting('test.uid', true), '')::uuid $$;

create temp table ids (k text primary key, v uuid);

do $seed$
declare
  paid uuid := gen_random_uuid(); unpaid uuid := gen_random_uuid();
  own_p uuid := '00000000-0000-0000-0000-00000000d001';
  par_p uuid := '00000000-0000-0000-0000-00000000d002';
  own_u uuid := '00000000-0000-0000-0000-00000000d003';
  par_u uuid := '00000000-0000-0000-0000-00000000d004';
  fam_p uuid; fam_u uuid; stu_p uuid; stu_u uuid;
begin
  insert into public.schools (id, name, city) values
    (paid, 'Paid School', 'Lahore'), (unpaid, 'Unpaid School', 'Karachi');

  -- One paying, one whose trial ended a fortnight ago and who never paid.
  insert into public.subscriptions (school_id, plan_code, status, period_start, period_end)
    values (paid, 'starter', 'active', current_date - 30, current_date + 300);
  insert into public.subscriptions (school_id, plan_code, status, trial_ends_on)
    values (unpaid, 'starter', 'trialing', current_date - 14);

  insert into auth.users (id, email) values
    (own_p, 'owner@paid.test'), (par_p, 'parent@paid.test'),
    (own_u, 'owner@unpaid.test'), (par_u, 'parent@unpaid.test')
    on conflict (id) do nothing;

  insert into public.families (school_id, head_name) values (paid, 'Paid Family')
    returning id into fam_p;
  insert into public.families (school_id, head_name) values (unpaid, 'Unpaid Family')
    returning id into fam_u;
  insert into public.students (school_id, gr_no, full_name, family_id, admission_date, status)
    values (paid, 'P-1', 'Paid Child', fam_p, current_date - 100, 'active')
    returning id into stu_p;
  insert into public.students (school_id, gr_no, full_name, family_id, admission_date, status)
    values (unpaid, 'U-1', 'Unpaid Child', fam_u, current_date - 100, 'active')
    returning id into stu_u;

  alter table public.profiles disable trigger user;
  insert into public.profiles (id, school_id, full_name, role, family_id, active) values
    (own_p, paid,   'Paid Owner',   'owner',  null,  true),
    (par_p, paid,   'Paid Parent',  'parent', fam_p, true),
    (own_u, unpaid, 'Unpaid Owner', 'owner',  null,  true),
    (par_u, unpaid, 'Unpaid Parent','parent', fam_u, true);
  alter table public.profiles enable trigger user;

  insert into ids values ('paid', paid), ('unpaid', unpaid),
    ('own_p', own_p), ('par_p', par_p), ('own_u', own_u), ('par_u', par_u),
    ('stu_p', stu_p), ('stu_u', stu_u);
end $seed$;

-- 1. THE FIXTURE IS THE FIXTURE. If the unpaid school is not actually locked,
--    every assertion below passes for the wrong reason.
do $t$
declare v_paid text; v_unpaid text;
begin
  v_paid   := public.fn_effective_status((select v from ids where k='paid'))::text;
  v_unpaid := public.fn_effective_status((select v from ids where k='unpaid'))::text;
  if v_paid <> 'active' then
    raise exception 'FAIL: the paying school reads as %, so this suite proves nothing', v_paid;
  end if;
  if v_unpaid <> 'locked' then
    raise exception 'FAIL: a trial that ended 14 days ago reads as %, not locked. '
      'A trial has no grace period (0026), so this is the fixture being wrong '
      'or the status rule having changed.', v_unpaid;
  end if;
  raise notice '1. one school active, one locked - ok';
end $t$;

-- 2. THE PAYING SCHOOL'S PARENT IS UNAFFECTED. First, because a licence check
--    that closes everybody is not a licence check.
do $t$
declare j jsonb;
begin
  perform set_config('test.uid', (select v::text from ids where k='par_p'), false);
  j := public.fn_portal_me();
  if j is null or not (j ? 'children') then
    raise exception 'FAIL: a paying school''s parent cannot open the portal: %', j;
  end if;
  j := public.fn_portal_child_fees((select v from ids where k='stu_p'));
  if j is null then
    raise exception 'FAIL: a paying school''s parent cannot read their child''s fees';
  end if;
  raise notice '2. a paying school''s parent still sees everything - ok';
end $t$;

-- 3. THE UNPAID SCHOOL'S PARENT GETS NOTHING, at the entry point and at every
--    child-scoped call. Both matter: closing only the entry point leaves four
--    functions a bookmarked URL still reaches.
do $t$
-- `v_open || 'name'` without the cast is ambiguous: Postgres can read the
-- literal as an ARRAY literal and dies with "malformed array literal", inside
-- the exception handler, which then reports the refusal as being for the wrong
-- reason. Found by deleting the guard to check this assertion was not vacuous:
-- it failed, and it failed with the wrong sentence.
declare j jsonb; v_msg text; v_open text[] := '{}';
begin
  perform set_config('test.uid', (select v::text from ids where k='par_u'), false);

  begin
    j := public.fn_portal_me();
    v_open := v_open || 'fn_portal_me'::text;
  exception when others then
    get stacked diagnostics v_msg = message_text;
    if v_msg not like '%parent portal%' then
      raise exception 'FAIL: fn_portal_me refused for the wrong reason: %', v_msg;
    end if;
  end;

  begin
    j := public.fn_portal_child_fees((select v from ids where k='stu_u'));
    v_open := v_open || 'fn_portal_child_fees'::text;
  exception when others then null;
  end;
  begin
    j := public.fn_portal_child_attendance((select v from ids where k='stu_u'),
                                           current_date - 30, current_date);
    v_open := v_open || 'fn_portal_child_attendance'::text;
  exception when others then null;
  end;
  begin
    j := public.fn_portal_child_results((select v from ids where k='stu_u'));
    v_open := v_open || 'fn_portal_child_results'::text;
  exception when others then null;
  end;
  begin
    j := public.fn_portal_child_ledger((select v from ids where k='stu_u'));
    v_open := v_open || 'fn_portal_child_ledger'::text;
  exception when others then null;
  end;

  if array_length(v_open, 1) is not null then
    raise exception 'FAIL: an unpaid school''s parent can still read %. The '
      'parents are the people who make a school renew, and they feel nothing.',
      array_to_string(v_open, ', ');
  end if;
  raise notice '3. an unpaid school''s parent gets nothing, at all five doors - ok';
end $t$;

-- 4. AND THE OFFICE IS NOT LOCKED OUT OF ITS OWN RECORDS. This is the half that
--    protects the school, and it is the half a future change is most likely to
--    break while "tightening" the lock. Their data is theirs.
do $t$
declare v_n int;
begin
  perform set_config('test.uid', (select v::text from ids where k='own_u'), false);
  select count(*) into v_n from public.students
   where school_id = (select v from ids where k='unpaid');
  if v_n <> 1 then
    raise exception 'FAIL: the unpaid school''s owner can no longer read their '
      'own pupils (% found). A school locked out of its own records is how a '
      'late payment becomes a legal complaint.', v_n;
  end if;
  raise notice '4. the unpaid school''s office still reads its own records - ok';
end $t$;

-- 5. AND STILL CANNOT WRITE, which is 0026's rule and must survive this file.
do $t$
declare v_msg text;
begin
  perform set_config('test.uid', (select v::text from ids where k='own_u'), false);
  begin
    insert into public.students (school_id, gr_no, full_name, admission_date, status)
    values ((select v from ids where k='unpaid'), 'U-2', 'New Child', current_date, 'active');
    raise exception 'FAIL: an unpaid school just admitted a pupil';
  exception when others then
    get stacked diagnostics v_msg = message_text;
    if v_msg like 'FAIL:%' then raise exception '%', v_msg; end if;
    if v_msg not like '%subscription has ended%' then
      raise exception 'FAIL: the write was refused for the wrong reason: %', v_msg;
    end if;
  end;
  raise notice '5. an unpaid school still cannot write - ok';
end $t$;

-- 6. TRIALS ARE NOT EXTENDED, and the refusal says so in words. The console
--    used to render a button that added fourteen days per press with no
--    confirmation and no ceiling.
do $t$
declare v_msg text; v_admin uuid := '00000000-0000-0000-0000-00000000d009';
begin
  insert into auth.users (id, email) values (v_admin, 'operator@vendor.test')
    on conflict (id) do nothing;
  insert into public.platform_admins (user_id, email) values (v_admin, 'operator@vendor.test')
    on conflict do nothing;
  perform set_config('test.uid', v_admin::text, false);

  begin
    perform public.fn_extend_trial((select v from ids where k='unpaid'), 14);
    raise exception 'FAIL: the trial was extended. One press is fourteen free '
      'days and nothing caps the number of presses.';
  exception when others then
    get stacked diagnostics v_msg = message_text;
    if v_msg like 'FAIL:%' then raise exception '%', v_msg; end if;
    if v_msg not like '%not extended%' then
      raise exception 'FAIL: fn_extend_trial refused for the wrong reason: %', v_msg;
    end if;
  end;
  raise notice '6. trials are not extended, by anybody - ok';
end $t$;

rollback;
\echo 'UNPAID SCHOOL: ALL TESTS PASSED'

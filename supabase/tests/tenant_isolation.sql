-- =============================================================================
-- Cross-tenant break-in test.
--
-- Sets up two schools, logs in as School A's owner, and then tries every way we
-- can think of to reach School B's data. Any success raises an exception, which
-- fails CI.
--
-- The per-table sweeps are generated from the catalogue rather than a hardcoded
-- list, so a table added later is covered automatically — a hardcoded list is
-- exactly how a leak gets shipped.
--
-- Run: psql -v ON_ERROR_STOP=1 -f supabase/tests/tenant_isolation.sql
-- =============================================================================

\set ON_ERROR_STOP on

-- Wrapped in a transaction that is rolled back at the end, like the ten newer
-- suites. It was not, and the "clean slate" delete below hid why: nothing
-- cascades from public.schools — 34 tables reference it with NO ACTION — so on
-- a fresh database that delete matches zero rows and does nothing, while on a
-- second run it fails outright on the profiles foreign key. This suite could
-- therefore only ever be run ONCE per database, and the rows it committed were
-- what made counter.sql pass alone and fail after fee_ops.sql.
begin;

-- --- Make auth.uid() switchable so we can act as different users -------------
create or replace function auth.uid() returns uuid language sql stable as
  $$ select nullif(current_setting('test.uid', true), '')::uuid $$;

-- =============================================================================
-- Seed two schools
-- =============================================================================
do $seed$
declare
  a_school uuid; b_school uuid;
  a_owner  uuid := '00000000-0000-0000-0000-0000000000aa';
  b_owner  uuid := '00000000-0000-0000-0000-0000000000bb';
  a_sess uuid; b_sess uuid;
  a_class uuid; b_class uuid;
  a_sec uuid; b_sec uuid;
  a_stu uuid; b_stu uuid;
  a_enr uuid; b_enr uuid;
begin
  -- Clean slate
  -- (No "clean slate" delete here. Nothing cascades from public.schools —
  -- 34 tables reference it with NO ACTION — so the delete that used to sit
  -- on this line matched zero rows on a fresh database and failed outright
  -- on a re-run. The suite rolls back instead, which actually works.)

  insert into public.schools (id, name) values (gen_random_uuid(), 'Alpha School') returning id into a_school;
  insert into public.schools (id, name) values (gen_random_uuid(), 'Beta School')  returning id into b_school;

  insert into public.subscriptions (school_id, plan_code, status, trial_ends_on)
    values (a_school, 'starter', 'active', current_date + 14),
           (b_school, 'starter', 'active', current_date + 14);

  -- Owners. Triggers off while seeding fixtures: the role guard and the
  -- school guard exist to stop the APP doing this, and we are standing in for
  -- the service-role provisioning path that legitimately may.
  alter table public.profiles disable trigger user;
  insert into auth.users (id, email) values (a_owner, 'a@alpha.test'), (b_owner, 'b@beta.test')
    on conflict (id) do nothing;
  insert into public.profiles (id, full_name, role, school_id) values
    (a_owner, 'Alpha Owner', 'owner', a_school),
    (b_owner, 'Beta Owner',  'owner', b_school)
  on conflict (id) do update set school_id = excluded.school_id, role = excluded.role;
  alter table public.profiles enable trigger user;

  -- Minimal academic data in BOTH schools
  insert into public.academic_sessions (name, is_current, school_id)
    values ('2025-2026', true, a_school) returning id into a_sess;
  insert into public.academic_sessions (name, is_current, school_id)
    values ('2025-2026', true, b_school) returning id into b_sess;

  insert into public.classes (name, level_order, school_id) values ('Class 1', 1, a_school) returning id into a_class;
  insert into public.classes (name, level_order, school_id) values ('Class 1', 1, b_school) returning id into b_class;

  insert into public.sections (class_id, name, school_id) values (a_class, 'A', a_school) returning id into a_sec;
  insert into public.sections (class_id, name, school_id) values (b_class, 'A', b_school) returning id into b_sec;

  -- Both schools use GR number "001" — proof the old global unique is gone.
  insert into public.students (gr_no, full_name, school_id)
    values ('001', 'Alpha Student', a_school) returning id into a_stu;
  insert into public.students (gr_no, full_name, school_id)
    values ('001', 'Beta Student', b_school) returning id into b_stu;

  insert into public.enrollments (student_id, session_id, class_id, section_id, school_id)
    values (a_stu, a_sess, a_class, a_sec, a_school) returning id into a_enr;
  insert into public.enrollments (student_id, session_id, class_id, section_id, school_id)
    values (b_stu, b_sess, b_class, b_sec, b_school) returning id into b_enr;

  insert into public.fee_heads (name, type, is_recurring, school_id)
    values ('Tuition', 'monthly', true, a_school), ('Tuition', 'monthly', true, b_school);

  insert into public.staff (full_name, school_id)
    values ('Alpha Teacher', a_school), ('Beta Teacher', b_school);

  -- Stash the ids for the test blocks below
  create table if not exists public._test_ids (k text primary key, v uuid);
  delete from public._test_ids;
  insert into public._test_ids values
    ('a_school', a_school), ('b_school', b_school),
    ('a_owner', a_owner),   ('b_owner', b_owner),
    ('a_sess', a_sess),     ('b_sess', b_sess),
    ('a_class', a_class),   ('b_class', b_class),
    ('a_sec', a_sec),       ('b_sec', b_sec),
    ('a_stu', a_stu),       ('b_stu', b_stu),
    ('a_enr', a_enr),       ('b_enr', b_enr);

  raise notice 'seeded: Alpha=% Beta=%', a_school, b_school;
end $seed$;

-- Both schools issuing GR "001" must have succeeded.
do $$
begin
  if (select count(*) from public.students where gr_no = '001') <> 2 then
    raise exception 'FAIL: two schools cannot both issue GR number 001';
  end if;
  raise notice 'ok: GR numbers are per-school';
end $$;

-- Per-school receipt counters must both start at 1.
do $$
declare a1 bigint; b1 bigint;
begin
  perform set_config('test.uid', (select v::text from public._test_ids where k='a_owner'), false);
  a1 := public.next_counter('receipt');
  perform set_config('test.uid', (select v::text from public._test_ids where k='b_owner'), false);
  b1 := public.next_counter('receipt');
  if a1 <> 1 or b1 <> 1 then
    raise exception 'FAIL: receipt series not per-school (alpha=%, beta=%)', a1, b1;
  end if;
  raise notice 'ok: receipt series restart per school';
end $$;

-- =============================================================================
-- TEST 1 — READS. As Alpha's owner, no Beta row may be visible anywhere.
-- Generated across every tenant table in the catalogue.
-- =============================================================================
do $reads$
declare
  t         text;
  b_school  uuid := (select v from public._test_ids where k='b_school');
  leaked    bigint;
  failures  text := '';
  checked   int := 0;
begin
  perform set_config('test.uid', (select v::text from public._test_ids where k='a_owner'), false);
  set local role authenticated;

  for t in
    select c.relname
    from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
    join pg_attribute a on a.attrelid = c.oid and a.attname = 'school_id' and not a.attisdropped
    where n.nspname = 'public' and c.relkind = 'r'
      and c.relname <> '_test_ids'
    order by c.relname
  loop
    execute format('select count(*) from public.%I where school_id = $1', t)
      into leaked using b_school;
    checked := checked + 1;
    if leaked > 0 then
      failures := failures || format('  %s: %s Beta rows visible%s', t, leaked, chr(10));
    end if;
  end loop;

  reset role;

  if failures <> '' then
    raise exception E'CROSS-TENANT READ LEAK across % tables:\n%', checked, failures;
  end if;
  raise notice 'ok: no cross-tenant reads (% tables swept)', checked;
end $reads$;

-- =============================================================================
-- TEST 2 — WRITES. Alpha must not be able to insert a row addressed to Beta,
-- nor update/delete a Beta row.
-- =============================================================================
do $writes$
declare
  b_school uuid := (select v from public._test_ids where k='b_school');
  b_stu    uuid := (select v from public._test_ids where k='b_stu');
  ok       boolean;
  n        bigint;
begin
  perform set_config('test.uid', (select v::text from public._test_ids where k='a_owner'), false);
  set local role authenticated;

  -- 2a. Insert addressed to Beta must be refused.
  ok := false;
  begin
    insert into public.students (gr_no, full_name, school_id)
      values ('HACK-1', 'Injected', b_school);
  exception when others then ok := true;
  end;
  if not ok then
    reset role;
    raise exception 'FAIL: Alpha inserted a student into Beta';
  end if;

  -- 2b. Update of a Beta row must affect nothing.
  update public.students set full_name = 'Overwritten' where id = b_stu;
  get diagnostics n = row_count;
  if n > 0 then
    reset role;
    raise exception 'FAIL: Alpha updated % Beta student row(s)', n;
  end if;

  -- 2c. Delete of a Beta row must affect nothing.
  delete from public.students where id = b_stu;
  get diagnostics n = row_count;
  if n > 0 then
    reset role;
    raise exception 'FAIL: Alpha deleted % Beta student row(s)', n;
  end if;

  -- 2d. Moving one of our own rows into Beta must be refused.
  ok := false;
  begin
    update public.students
      set school_id = b_school
      where id = (select v from public._test_ids where k='a_stu');
  exception when others then ok := true;
  end;
  if not ok then
    reset role;
    raise exception 'FAIL: Alpha moved its own student into Beta';
  end if;

  reset role;
  raise notice 'ok: no cross-tenant writes';
end $writes$;

-- =============================================================================
-- TEST 3 — RPC INJECTION. The dangerous class: SECURITY DEFINER functions
-- bypass RLS, so passing Beta's ids to them must be refused explicitly.
-- =============================================================================
do $rpc$
declare
  b_stu   uuid := (select v from public._test_ids where k='b_stu');
  b_enr   uuid := (select v from public._test_ids where k='b_enr');
  b_sess  uuid := (select v from public._test_ids where k='b_sess');
  b_class uuid := (select v from public._test_ids where k='b_class');
  a_sess  uuid := (select v from public._test_ids where k='a_sess');
  failures text := '';
  ok boolean;
  n  bigint;
begin
  perform set_config('test.uid', (select v::text from public._test_ids where k='a_owner'), false);
  set local role authenticated;

  -- 3a. Record a payment against Beta's student.
  ok := false;
  begin
    perform public.fn_record_payment(b_stu, 100, 'cash', 'injection test', false);
  exception when others then ok := true;
  end;
  if not ok then failures := failures || '  fn_record_payment accepted a Beta student' || chr(10); end if;

  -- 3b. Change Beta's student status.
  ok := false;
  begin
    perform public.fn_set_student_status(b_stu, 'struck_off', 'injection test');
  exception when others then ok := true;
  end;
  if not ok then failures := failures || '  fn_set_student_status accepted a Beta student' || chr(10); end if;

  -- 3c. Issue a certificate in Beta's name.
  ok := false;
  begin
    perform public.fn_issue_certificate('character', b_stu, '{}'::jsonb);
  exception when others then ok := true;
  end;
  if not ok then failures := failures || '  fn_issue_certificate accepted a Beta student' || chr(10); end if;

  -- 3d. Bill Beta's enrollment.
  ok := false;
  begin
    perform public.fn_bill_student_month(b_enr, date_trunc('month', current_date)::date, null);
  exception when others then ok := true;
  end;
  if not ok then failures := failures || '  fn_bill_student_month accepted a Beta enrollment' || chr(10); end if;

  -- 3e. Read Beta's defaulter list.
  begin
    select count(*) into n from public.fn_defaulters(b_sess);
    if n > 0 then failures := failures || '  fn_defaulters returned Beta rows' || chr(10); end if;
  exception when others then null;  -- refusing outright is also correct
  end;

  -- 3f. Read Beta's roster.
  begin
    select count(*) into n from public.fn_section_roster(b_sess, b_class, null, current_date);
    if n > 0 then failures := failures || '  fn_section_roster returned Beta rows' || chr(10); end if;
  exception when others then null;
  end;

  -- 3g. Bulk-generate invoices for a Beta class.
  ok := false;
  begin
    perform public.fn_generate_class_invoices(b_sess, b_class, date_trunc('month', current_date)::date, null);
  exception when others then ok := true;
  end;
  if not ok then failures := failures || '  fn_generate_class_invoices accepted a Beta class' || chr(10); end if;

  -- 3h. Import students into Beta's session.
  ok := false;
  begin
    perform public.fn_import_students(b_sess, '[{"full_name":"Injected","class":"Class 1"}]'::jsonb, false);
  exception when others then ok := true;
  end;
  if not ok then failures := failures || '  fn_import_students accepted a Beta session' || chr(10); end if;

  -- 3i. Switch OUR current academic session. The original body ran
  --     `update academic_sessions set is_current = (id = p_session_id)` with no
  --     WHERE clause, so this one legitimate call would clear the current-session
  --     flag for every other school in the database.
  begin
    perform public.fn_set_current_session(a_sess);
  exception when others then null;
  end;

  -- 3j. Link one of our students to a Beta student.
  ok := false;
  begin
    perform public.fn_link_students((select v from public._test_ids where k='a_stu'), b_stu, 'Brother');
  exception when others then ok := true;
  end;
  if not ok then failures := failures || '  fn_link_students accepted a Beta student' || chr(10); end if;

  -- Back to superuser BEFORE inspecting Beta: as Alpha, RLS hides Beta's rows,
  -- so a "did Beta survive?" check run here would always report damage.
  reset role;

  if not exists (select 1 from public.academic_sessions
                 where id = b_sess and is_current) then
    failures := failures || '  fn_set_current_session cleared Beta''s current session' || chr(10);
  end if;

  if failures <> '' then
    raise exception E'CROSS-TENANT RPC INJECTION:\n%', failures;
  end if;
  raise notice 'ok: no cross-tenant RPC injection';
end $rpc$;

-- =============================================================================
-- TEST 4 — STRUCTURAL GUARDS. Catch a future change that reintroduces a hole.
-- =============================================================================
do $guards$
declare
  bad text := '';
  -- Tables that describe the PLATFORM rather than a tenant. Named once, used by
  -- 4a, 4b, 4b-ii and 4b-iii below, so adding a platform table cannot mean
  -- remembering to edit four `not in` lists — and forgetting one of them is how
  -- an exclusion list becomes a hole.
  --
  -- Everything here must satisfy 4b-ii (gates on is_platform_admin) and 4b-iii
  -- (no write policy) instead of the tenant rules, and 4d (RLS on) regardless.
  -- Being on this list buys exemption from the school_id and current_school_id
  -- checks, never from all of them.
  platform_tables text[] := array[
    'schools', 'plans', 'subscriptions', 'student_count_snapshots',
    'platform_admins', 'platform_invoices', 'platform_payments',
    -- The deployment record added by 0069. It has no school_id because it
    -- describes the database, and its only policy is a SELECT gated on
    -- is_platform_admin() — a schema history is not a tenant's business, and a
    -- clerk who could edit it could hide which migrations a school is missing.
    'schema_migrations',
    -- 0073. What the operator did to a school: prices chosen, trials extended,
    -- discounts given. It carries school_id because it is keyed on one, but a
    -- school must see none of it, so current_school_id() would be the wrong gate
    -- and its presence would be the bug. 4b-ii asserts is_platform_admin instead.
    'operator_actions',
    -- 0074. Support sessions. The one platform table a SCHOOL may read part of —
    -- its own visits, by design, see §2.1 — so it has TWO select policies, one
    -- on is_platform_admin and one on current_school_id + has_role. 4b-ii accepts
    -- either, which is exactly why 4b-ii is stated as "one or the other" rather
    -- than per-table.
    'operator_sessions',
    -- 0076. The VENDOR's own registered name, NTN, address and bank account. No
    -- school_id because it describes us, not a customer, and exactly one row
    -- exists. Its only policy is a SELECT on is_platform_admin(); the four bank
    -- fields a school needs in order to pay reach it through fn_my_billing,
    -- which hand-picks them — platform_billing.sql assertions 73c and 73d prove
    -- the rest of the row does not travel.
    'platform_settings',
    -- 0078. A school telling us it has transferred money. Like operator_sessions
    -- it has TWO select policies — the operator sees every report, the school
    -- sees its own — because a school that cannot see its own report has no way
    -- to know the first one arrived. It has NO write policy: the insert goes
    -- through fn_my_report_payment, and a school-writable `status` column would
    -- be a school writing money.
    'platform_payment_claims',
    -- 0080. What was handed to a school before its records were destroyed. No
    -- school_id in the tenant sense — the column is nullable and ON DELETE SET
    -- NULL precisely so the row OUTLIVES the school it describes, which is the
    -- whole point of it: if a school ever says "you deleted our records", this
    -- is the dated row saying what was given to them first. current_school_id()
    -- would be the wrong gate and its presence would be the bug.
    'platform_exports'
  ];
begin
  -- 4a. Every tenant table must carry school_id.
  select coalesce(string_agg('  ' || c.relname, chr(10)), '') into bad
  from pg_class c join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'public' and c.relkind = 'r'
    and not (c.relname = any (platform_tables)) and c.relname <> '_test_ids'
    and not exists (select 1 from pg_attribute a
                    where a.attrelid = c.oid and a.attname = 'school_id' and not a.attisdropped);
  if bad <> '' then
    raise exception E'Tables missing school_id:\n%', bad;
  end if;

  -- 4b. Every policy on a tenant table must reference current_school_id().
  --
  -- The `platform_%` tables are excluded because they are the OPERATOR's own
  -- books — what each school was charged and what it paid. They carry school_id
  -- because they are keyed on it, but a school must see none of them, so
  -- current_school_id() is the wrong gate and its presence would be the bug.
  -- 4b-ii below is what replaces it for them: excluding a table from a guard
  -- without asserting what DOES hold is how an exclusion list becomes a hole.
  select coalesce(string_agg('  ' || tablename || '.' || policyname, chr(10)), '') into bad
  from pg_policies
  where schemaname = 'public'
    and not (tablename = any (platform_tables))
    and coalesce(qual, '') not like '%current_school_id%'
    and coalesce(with_check, '') not like '%current_school_id%';
  if bad <> '' then
    raise exception E'Policies with no tenant check:\n%', bad;
  end if;

  -- 4b-ii. What 4b's exclusion has to be replaced by.
  --
  -- 4b above cannot check the platform tables: several of them are read by the
  -- OPERATOR, for whom current_school_id() is null and would be the wrong gate.
  -- But excluding a table from a guard without asserting what DOES hold is how
  -- an exclusion list becomes a hole, so every policy on every one of them must
  -- gate on one of the two legitimate authorities — the school's own tenancy, or
  -- platform-admin identity. What this forbids is `using (true)`, which on
  -- platform_invoices would make every school's billing history readable by
  -- every signed-in user of every school.
  --
  -- Stated as "either function" rather than per-table, because these tables are
  -- not uniform and a per-table list gets one wrong. student_count_snapshots
  -- carries BOTH kinds — a school may read its own growth, the operator may read
  -- everyone's — and an earlier version of this check that demanded
  -- is_platform_admin() on it failed against a policy that was entirely correct.
  --
  -- platform_admins is the one exception and it has to be: its policy is "you may
  -- see your own row", and is_platform_admin() ANSWERS ITSELF by reading this
  -- table, so gating it on that function would be circular. 4b-iv asserts what
  -- holds for it instead.
  select coalesce(string_agg('  ' || tablename || '.' || policyname, chr(10)), '') into bad
  from pg_policies
  where schemaname = 'public'
    and tablename = any (platform_tables)
    -- `plans` is the price list, and it is DELIBERATELY world-readable: the
    -- marketing website reads it so the site can never quote a price the console
    -- does not charge, and a signed-in school sees its own plan's name. It holds
    -- no tenant data and no school_id. Its exemption is paid for in 4b-iii,
    -- which requires it to have no write policy — world-readable must not
    -- become world-writable, or any parent with a login could reprice the
    -- product.
    and tablename not in ('platform_admins', 'plans')
    and coalesce(qual, '') || coalesce(with_check, '') not like '%is_platform_admin%'
    and coalesce(qual, '') || coalesce(with_check, '') not like '%current_school_id%';
  if bad <> '' then
    raise exception E'Policies on a platform table gated on neither is_platform_admin() nor current_school_id():\n%', bad;
  end if;

  -- 4b-iv. And platform_admins itself, the table 4b-ii cannot check without
  -- circularity, must be scoped to the caller's own row. `using (true)` here
  -- would publish the operator's email address to every parent with a login,
  -- and — worse — is_platform_admin() reads this table, so a policy that
  -- widened it would widen every other check in this file at the same time.
  select coalesce(string_agg('  ' || policyname || ' (' || cmd || ')', chr(10)), '') into bad
  from pg_policies
  where schemaname = 'public' and tablename = 'platform_admins'
    and coalesce(qual, '') || coalesce(with_check, '') not like '%uid()%';
  if bad <> '' then
    raise exception E'A policy on platform_admins is not scoped to the caller''s own row:\n%', bad;
  end if;

  -- 4b-iii. And the operator's books must be READ-ONLY through RLS: every write
  -- goes through a SECURITY DEFINER function, so there is one place that decides
  -- what a valid charge or receipt looks like. An UPDATE path would let an
  -- invoice be edited into something it never was.
  select coalesce(string_agg('  ' || tablename || '.' || policyname || ' (' || cmd || ')', chr(10)), '')
    into bad
  from pg_policies
  where schemaname = 'public'
    -- The operator-only records: what a school was charged, what it paid, and
    -- which migrations this database has. student_count_snapshots is NOT here —
    -- a school may read its own growth, so it is dual-policy and 4b-ii covers
    -- it. platform_admins is not here either; membership is managed by the
    -- service role.
    --
    -- `plans` is here for the other reason: it is world-readable by design, so
    -- the thing that must never appear on it is a write path. A parent with a
    -- login repricing Institution to Rs 0 would be a policy away.
    and tablename in ('platform_invoices', 'platform_payments', 'schema_migrations',
                      'plans', 'operator_actions', 'operator_sessions')
    and cmd <> 'SELECT';
  if bad <> '' then
    raise exception E'A platform table has a write policy; writes must go through a definer function:\n%', bad;
  end if;

  -- 4c. Every tenant table must have RLS enabled.
  select coalesce(string_agg('  ' || c.relname, chr(10)), '') into bad
  from pg_class c join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'public' and c.relkind = 'r' and not c.relrowsecurity
    and c.relname <> '_test_ids'
    and exists (select 1 from pg_attribute a
                where a.attrelid = c.oid and a.attname = 'school_id' and not a.attisdropped);
  if bad <> '' then
    raise exception E'Tenant tables with RLS disabled:\n%', bad;
  end if;

  -- 4d. EVERY table in public must have RLS enabled — not only those carrying a
  -- school_id, which is all 4c above checks.
  --
  -- 0001:704 grants SELECT, INSERT, UPDATE and DELETE on all tables in public to
  -- `authenticated`, and 0025:768 makes that the DEFAULT for every table created
  -- afterwards. Verified: `authenticated` holds all four verbs on certificates,
  -- audit_log, platform_invoices and user_invites right now.
  --
  -- Those grants are inert today only because RLS denies a verb with no matching
  -- policy — every table has RLS on, and no write policy is unconditionally
  -- permissive. So the blanket grant is not the exposure; a table arriving
  -- WITHOUT RLS is, and it would be readable and writable by every signed-in
  -- user of every school from the moment it is created, with no policy needed
  -- and nothing in the app looking different.
  --
  -- 4c cannot catch that: a new platform or reference table with no school_id
  -- column passes it silently. This closes the gap by making RLS the rule for
  -- the whole schema rather than for the tables somebody remembered to key.
  select coalesce(string_agg('  ' || c.relname, chr(10)), '') into bad
  from pg_class c join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'public' and c.relkind = 'r' and not c.relrowsecurity
    and c.relname <> '_test_ids';
  if bad <> '' then
    raise exception E'Tables in public with RLS DISABLED — the blanket grant in 0001:704 makes these fully readable and writable by every signed-in user:\n%', bad;
  end if;

  raise notice 'ok: structural guards hold';
end $guards$;

-- =============================================================================
-- TEST 5 — A PLATFORM ADMIN, WITH NO SUPPORT SESSION OPEN, REACHES NO TENANT DATA.
--
-- The qualifier is new and it is the whole of 0074. Managing schools,
-- subscriptions and payments never requires reading a child's records, so the
-- platform role has no standing path to them — and "just let platform admins see
-- everything" would still be a one-line change nobody would notice, turning one
-- compromised platform login into a breach of every school at once.
--
-- What 0074 added is a DELIBERATE, LOGGED, READ-ONLY path, opened by
-- fn_operator_enter and closed by fn_operator_leave. So the invariant this test
-- defends is now precisely: with no session open, the platform role sees nothing.
-- TEST 8 covers the other half — with a session open, reads work and every write
-- is still refused — and the two together are what make the boundary a boundary
-- rather than a door left ajar.
-- =============================================================================
do $platform$
declare
  v_ops uuid := '00000000-0000-0000-0000-0000000000fe';
  t        text;
  visible  bigint;
  failures text := '';
  n        bigint;
begin
  insert into auth.users (id, email) values (v_ops, 'ops@isolation.test')
    on conflict (id) do nothing;
  insert into public.platform_admins (user_id, email) values (v_ops, 'ops@isolation.test')
    on conflict (user_id) do nothing;

  perform set_config('test.uid', v_ops::text, false);
  set local role authenticated;

  -- Tenant tables: nothing at all, for any school. `subscriptions` and
  -- `student_count_snapshots` also carry school_id but are platform tables, not
  -- school records — excluded here and checked as visible below instead.
  for t in
    select c.relname
    from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
    join pg_attribute a on a.attrelid = c.oid and a.attname = 'school_id' and not a.attisdropped
    where n.nspname = 'public' and c.relkind = 'r'
      -- operator_actions and operator_sessions carry school_id and are keyed on
      -- it, but they are the OPERATOR's own records of what they did to a
      -- school, not the school's records. Excluded here and asserted visible
      -- below, because excluding a table from a guard without asserting what
      -- DOES hold is how an exclusion list becomes a hole.
      and c.relname not in ('_test_ids', 'subscriptions', 'student_count_snapshots',
                            'operator_actions', 'operator_sessions')
    order by c.relname
  loop
    execute format('select count(*) from public.%I', t) into visible;
    if visible > 0 then
      failures := failures || format('  %s: %s rows visible to a platform admin%s', t, visible, chr(10));
    end if;
  end loop;

  -- But the platform tables they actually need ARE readable, or the admin panel
  -- could not work. A test that only checked the denials could pass with the
  -- whole panel broken.
  select count(*) into n from public.schools;
  if n < 2 then
    failures := failures || '  platform admin cannot see the schools list' || chr(10);
  end if;
  select count(*) into n from public.subscriptions;
  if n < 2 then
    failures := failures || '  platform admin cannot see subscriptions' || chr(10);
  end if;

  -- And with no session open, current_school_id() must be NULL for them. This is
  -- the single value the whole read boundary turns on: if it ever returned a
  -- school for an operator who had not entered one, every tenant policy would
  -- open at once and the sweep above would have to catch 40 tables to notice.
  if public.current_school_id() is not null then
    failures := failures
      || '  a platform admin with NO support session has a current_school_id ('
      || public.current_school_id()::text || ')' || chr(10);
  end if;
  if public.is_operator_session() then
    failures := failures || '  is_operator_session() is true with no session open' || chr(10);
  end if;
  if public.is_staff() then
    failures := failures || '  is_staff() is true for an operator with no session open' || chr(10);
  end if;

  reset role;

  if failures <> '' then
    raise exception E'PLATFORM ROLE REACHES TOO FAR (or not far enough):\n%', failures;
  end if;
  raise notice 'ok: platform admin with no session sees schools and subscriptions, no tenant data';
end $platform$;

-- =============================================================================
-- TEST 6 — A DEFINER FUNCTION MUST NOT HAND OVER ANOTHER SCHOOL'S FAMILY.
--
-- This is a reproduction, not a hypothetical. It is the exact attack that
-- worked, kept as an assertion so it cannot come back.
--
-- fn_queue_message is SECURITY DEFINER, so RLS does not apply inside it, and it
-- looked up the family with `where id = p_family_id` and nothing else. The
-- children's names came from an equally unscoped students query, and the balance
-- from family_outstanding(), which summed students by family_id alone.
--
-- School A's owner passed School B's family id, and School A's own outbox — a
-- table School A is entitled to read — received:
--
--     to_name : Haji Abdul Rehman VICTIMHEAD
--     to_phone: 0300-9998887
--     text    : "...A balance of Rs 7,777 is outstanding for Fatima Rehman
--                VICTIMCHILD..."
--
-- Another school's family head, their phone number, their child's name and their
-- exact debt, enumerable one uuid at a time.
--
-- The markers are deliberately absurd. An assertion that checked only "did a row
-- appear" would pass on a row correctly built from School A's OWN data, which is
-- what a half-fix produces; searching the rendered text for VICTIM proves the
-- leaked values are the victim's and not the attacker's.
--
-- Note the ORDER of assertions below. Proving the fixture is real comes FIRST:
-- the original probe of this bug returned NULL and looked like a clean refusal,
-- when in fact the template key did not exist and nothing had been tested at
-- all. A refusal is only evidence when the same call succeeds for a legitimate
-- caller.
-- =============================================================================
do $definer_idor$
declare
  a_school uuid := (select v from public._test_ids where k='a_school');
  b_school uuid := (select v from public._test_ids where k='b_school');
  b_sess   uuid := (select v from public._test_ids where k='b_sess');
  b_class  uuid := (select v from public._test_ids where k='b_class');
  a_owner  uuid := (select v from public._test_ids where k='a_owner');
  v_bfam uuid; v_bkid uuid; v_binv uuid;
  v_afam uuid; v_akid uuid;
  v_queued uuid; v_text text; v_name text; v_phone text;
  failures text := '';
begin
  -- Seeded as the table owner, standing in for the service-role provisioning
  -- path, before any identity is adopted.
  perform set_config('test.uid', '', false);

  -- School B: the victim family, with markers and a real debt.
  insert into public.families (head_name, phone, whatsapp, school_id)
    values ('Haji Abdul Rehman VICTIMHEAD', '0300-9998887', '0300-9998887', b_school)
    returning id into v_bfam;
  insert into public.students (gr_no, full_name, family_id, school_id)
    values ('IDOR-B1', 'Fatima Rehman VICTIMCHILD', v_bfam, b_school)
    returning id into v_bkid;
  insert into public.enrollments (student_id, session_id, class_id, school_id)
    values (v_bkid, b_sess, b_class, b_school);
  insert into public.invoices (student_id, session_id, period_month, due_date, status, school_id)
    values (v_bkid, b_sess, '2026-08-01', '2026-08-10', 'issued', b_school)
    returning id into v_binv;
  insert into public.invoice_lines (invoice_id, description, amount, school_id)
    values (v_binv, 'Tuition Fee', 7777, b_school);

  -- School A: its own family, so the control call below has something honest to
  -- return.
  insert into public.families (head_name, phone, whatsapp, school_id)
    values ('Alpha Parent OWNDATA', '0311-1112222', '0311-1112222', a_school)
    returning id into v_afam;
  insert into public.students (gr_no, full_name, family_id, school_id)
    values ('IDOR-A1', 'Alpha Child OWNDATA', v_afam, a_school)
    returning id into v_akid;

  perform set_config('test.uid', a_owner::text, false);

  -- --- Premise: the call WORKS for a legitimate caller ---------------------
  -- Without this, a NULL from the attack below proves nothing: it could mean
  -- "refused" or it could mean the template key is wrong. That is the mistake
  -- the first investigation of this bug made.
  v_queued := public.fn_queue_message('fee_reminder', v_afam);
  if v_queued is null then
    raise exception
      'PREMISE BROKEN: fn_queue_message refused School A its OWN family, so the '
      'cross-tenant assertion below would pass without testing anything. Check '
      'that the fee_reminder template exists and is enabled.';
  end if;
  select rendered_text into v_text from public.message_outbox where id = v_queued;
  if v_text not like '%OWNDATA%' then
    failures := failures ||
      '  a school cannot message its own family (rendered: ' || coalesce(v_text,'<null>') || ')' || chr(10);
  end if;

  -- --- The attack ----------------------------------------------------------
  v_queued := public.fn_queue_message('fee_reminder', v_bfam);

  if v_queued is not null then
    select to_name, to_phone, rendered_text into v_name, v_phone, v_text
      from public.message_outbox where id = v_queued;
    failures := failures || '  fn_queue_message accepted ANOTHER SCHOOL''S family id' || chr(10);
    if coalesce(v_name, '') like '%VICTIM%' then
      failures := failures || '    leaked the head name: ' || v_name || chr(10);
    end if;
    if coalesce(v_phone, '') = '0300-9998887' then
      failures := failures || '    leaked the phone number: ' || v_phone || chr(10);
    end if;
    if coalesce(v_text, '') like '%VICTIMCHILD%' then
      failures := failures || '    leaked the child''s name' || chr(10);
    end if;
    if coalesce(v_text, '') like '%7,777%' then
      failures := failures || '    leaked the family''s outstanding balance' || chr(10);
    end if;
  end if;

  -- Nothing referencing School B's family may exist in School A's outbox, by any
  -- route. Checked separately from the return value because a future variant
  -- might write the row and return null.
  if exists (select 1 from public.message_outbox o
              where o.family_id = v_bfam or o.rendered_text like '%VICTIM%') then
    failures := failures || '  an outbox row referencing School B''s family exists' || chr(10);
  end if;

  -- --- And the same for the two optional foreign keys ----------------------
  -- p_student_id was written into the row unchecked, so a row native to School A
  -- could point at School B's pupil, and the receipt and portal screens join
  -- through it.
  v_queued := public.fn_queue_message('fee_reminder', v_afam, '{}'::jsonb, null, v_bkid);
  if v_queued is not null
     and (select student_id from public.message_outbox where id = v_queued) = v_bkid then
    failures := failures || '  an outbox row in School A points at School B''s pupil' || chr(10);
  end if;

  -- family_outstanding — the function that produced the leaked figure — is NOT
  -- asserted here, deliberately, and the reason is worth recording.
  --
  -- Its hazard is that it sums students by family_id with no school predicate,
  -- so a pupil in a different school from their family would be counted. 0070
  -- joins families and requires s.school_id = f.school_id to close that. But the
  -- state cannot be reached to test: attempting it raises
  --
  --     ERROR:  A students row cannot be moved between schools
  --
  -- from the guard on students. So the hardening in 0070 defends a state the
  -- schema already forbids, and an assertion here would be theatre. Saying so is
  -- better than a test that passes because its premise is impossible — this
  -- suite has already been burned once by an assertion whose premise had been
  -- broken by an earlier step.
  --
  -- What DOES matter about family_outstanding is that its CALLERS scope the
  -- family id before handing it over, since it runs with RLS off inside a
  -- definer. That is exactly what the attack above tests.

  -- --- The second defect: a cross-tenant WRITE ----------------------------
  -- fn__apply_discount_lines is SECURITY DEFINER and took an invoice id and an
  -- enrolment id straight from the caller. Despite the fn__ prefix, which in
  -- this schema means "revoked from the browser", 0021:286 granted EXECUTE on it
  -- to `authenticated`.
  --
  -- So School A called it with School B's invoice and enrolment and got:
  --     line: Tuition Fee       | amount=5000 | discount=f
  --     line: Discount: sibling | amount=1000 | discount=t | school_id: ATTACKER'S
  --     VICTIM invoice net charge now: 4000.00
  --
  -- A stranger cut what another school charges a parent by Rs 1,000, and the
  -- line they inserted carries THEIR school_id while sitting on the victim's
  -- invoice — so the victim's fee report, the attacker's, and the paper the
  -- parent is holding all disagree. Worse than the read leak above, because a
  -- read leaks and a write corrupts.
  --
  -- Asserted on the MONEY, not on whether the call raised. A future variant that
  -- swallowed the error and wrote the line anyway must still fail here.
  declare
    v_charge_before numeric;
    v_charge_after  numeric;
    v_bkid2 uuid; v_benr2 uuid; v_binv2 uuid;
  begin
    perform set_config('test.uid', '', false);
    insert into public.students (gr_no, full_name, school_id)
      values ('IDOR-B2', 'Discount Victim', b_school) returning id into v_bkid2;
    insert into public.enrollments (student_id, session_id, class_id, school_id)
      values (v_bkid2, b_sess, b_class, b_school) returning id into v_benr2;
    insert into public.invoices (student_id, session_id, period_month, due_date, status, school_id)
      values (v_bkid2, b_sess, '2026-09-01', '2026-09-10', 'issued', b_school)
      returning id into v_binv2;
    insert into public.invoice_lines (invoice_id, description, amount, school_id)
      values (v_binv2, 'Tuition Fee', 5000, b_school);
    -- The victim school's own approved discount, which is what the unscoped read
    -- reached for.
    insert into public.discounts (enrollment_id, type, amount, is_percent, status, school_id)
      values (v_benr2, 'sibling', 1000, false, 'approved', b_school);

    select sum(case when is_discount then -amount else amount end) into v_charge_before
      from public.invoice_lines where invoice_id = v_binv2;

    perform set_config('test.uid', a_owner::text, false);
    begin
      perform public.fn__apply_discount_lines(v_binv2, v_benr2, 5000);
    exception when others then
      null;   -- refused is the correct outcome; the charge check below is the proof
    end;

    select sum(case when is_discount then -amount else amount end) into v_charge_after
      from public.invoice_lines where invoice_id = v_binv2;

    if v_charge_after is distinct from v_charge_before then
      failures := failures
        || '  another school CHANGED this invoice: net charge ' || v_charge_before
        || ' -> ' || v_charge_after || chr(10);
    end if;
    if exists (select 1 from public.invoice_lines
                where invoice_id = v_binv2 and school_id <> b_school) then
      failures := failures
        || '  an invoice_lines row on School B''s invoice carries another school''s school_id'
        || chr(10);
    end if;
  end;

  -- And the convention that made it reachable. In this schema an fn__ prefix
  -- means "internal, revoked from the browser roles"; a grant turns an internal
  -- helper into an unguarded entry point.
  if exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname like 'fn\_\_%'
       and (has_function_privilege('authenticated', p.oid, 'execute')
         or has_function_privilege('anon', p.oid, 'execute'))
  ) then
    failures := failures || '  an internal fn__ function is callable from a browser session: '
      || (select string_agg(p.proname, ', ' order by p.proname)
            from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname like 'fn\_\_%'
             and (has_function_privilege('authenticated', p.oid, 'execute')
               or has_function_privilege('anon', p.oid, 'execute')))
      || chr(10);
  end if;

  if failures <> '' then
    raise exception E'CROSS-TENANT LEAK THROUGH A DEFINER FUNCTION:\n%', failures;
  end if;
  raise notice 'ok: a definer function refuses another school''s family id and invoice';
end $definer_idor$;

-- =============================================================================
-- TEST 7 — A NAME OR A TYPE MEANS ONE IN *THIS* SCHOOL.
--
-- The fn_rollover shape, which this project has now hit three times: a SECURITY
-- DEFINER function resolving a row by NAME or TYPE with no school predicate.
-- fn_rollover chose "the next class up" that way and a school's year-end
-- rollover promoted its children into another school's classroom.
--
-- Neither of the two guards catches this shape. check-definer-queries.py hunts
-- an inequality between two table columns; check-definer-idor.py needs a
-- caller-supplied id. Here the name arrives as text and the type is a literal,
-- so nothing keys on an id at all. Both cases below were found by a third sweep
-- and proven before 0072 was written.
--
-- The fixture deliberately gives School B the LOWER level_order and sort_order,
-- so an unscoped `order by ... limit 1` provably prefers B's row. The shared
-- fixture above gives both schools 'Class 1' at level_order 1, which is a tie
-- and therefore proves nothing either way — a test whose outcome depends on
-- which row the planner happens to return first is not a test.
-- =============================================================================
do $name_lookups$
declare
  a_school uuid := (select v from public._test_ids where k='a_school');
  b_school uuid := (select v from public._test_ids where k='b_school');
  a_sess   uuid := (select v from public._test_ids where k='a_sess');
  a_owner  uuid := (select v from public._test_ids where k='a_owner');
  v_acls uuid; v_bcls uuid; v_bhead uuid;
  v_res jsonb; v_row jsonb;
  v_kid uuid; v_used_head uuid; v_head_school uuid;
  v_landed uuid;
  failures text := '';
begin
  perform set_config('test.uid', '', false);

  -- A class name both schools use, with School B's registered lower so an
  -- unscoped `order by level_order limit 1` picks B's.
  insert into public.classes (name, level_order, active, school_id)
    values ('Class 9 Collide', 1, true, b_school) returning id into v_bcls;
  insert into public.classes (name, level_order, active, school_id)
    values ('Class 9 Collide', 9, true, a_school) returning id into v_acls;
  insert into public.sections (class_id, name, school_id)
    values (v_acls, 'A', a_school);

  -- School B owns the only 'admission' fee head. School A has none, which is
  -- every school's state on its first day.
  insert into public.fee_heads (name, type, is_recurring, sort_order, active, school_id)
    values ('Admission Fee', 'admission', false, 1, true, b_school)
    returning id into v_bhead;

  perform set_config('test.uid', a_owner::text, false);

  -- --- 1. The go-live importer -------------------------------------------
  -- Not a leak: a later assert_own catches the foreign class. Catching it is the
  -- defect. School A HAS a 'Class 9 Collide', and its own row was refused with a
  -- message about another school's data:
  --     {"status":"error","message":"classes not found in this school"}
  -- Every Pakistani school names its classes the same things, so at any real
  -- number of customers this refuses most rows for most schools — and the
  -- importer is how every new school's roster arrives.
  v_res := public.fn_import_students(
    a_sess,
    jsonb_build_array(jsonb_build_object(
      'full_name', 'Collide Import', 'gr_no', 'COL-1', 'class', 'Class 9 Collide')),
    false);
  v_row := v_res->'rows'->0;

  if v_row->>'status' <> 'created' then
    failures := failures
      || '  the importer refused a class this school owns: ' || coalesce(v_row->>'message','?')
      || chr(10);
  else
    select e.class_id into v_landed
      from public.enrollments e join public.students s on s.id = e.student_id
     where s.gr_no = 'COL-1' and s.school_id = a_school;
    if v_landed = v_bcls then
      failures := failures || '  the importer enrolled a child in ANOTHER SCHOOL''S class'
        || chr(10);
    elsif v_landed is distinct from v_acls then
      failures := failures || '  the importer used neither school''s class (' 
        || coalesce(v_landed::text,'null') || ')' || chr(10);
    end if;
  end if;

  -- --- 2. The admission fee head ------------------------------------------
  -- Proven before 0072: the invoice line's own school_id was School A's, while
  -- its fee_head_id pointed at School B's head. Any report joining the two then
  -- shows a head this school does not own, or nothing at all under RLS — so the
  -- admission fee vanishes from head-wise dues.
  v_res := public.fn_admit_student(jsonb_build_object(
    'full_name', 'Collide Admit', 'gr_no', 'COL-2',
    'session_id', a_sess, 'class_id', v_acls,
    'admission_fee', jsonb_build_object('charged', true, 'amount', 5000)));

  select il.fee_head_id, fh.school_id into v_used_head, v_head_school
    from public.invoice_lines il
    join public.fee_heads fh on fh.id = il.fee_head_id
   where il.description = 'Admission Fee' and il.school_id = a_school
   limit 1;

  if v_used_head is null then
    failures := failures || '  no admission-fee line was written, so this proves nothing'
      || chr(10);
  elsif v_used_head = v_bhead or v_head_school = b_school then
    failures := failures
      || '  the admission fee line references ANOTHER SCHOOL''S fee head' || chr(10);
  elsif v_head_school is distinct from a_school then
    failures := failures || '  the admission fee head belongs to neither school' || chr(10);
  end if;

  if failures <> '' then
    raise exception E'A NAME OR TYPE LOOKUP CROSSED SCHOOLS:\n%', failures;
  end if;
  raise notice 'ok: class names and fee-head types resolve within one school';
end $name_lookups$;

-- Did fn_platform_school_detail refuse this caller? A separate function because
-- a dollar-quoted string inside the do-block below would terminate its own tag.
create or replace function pg_temp_refused_detail(p_school uuid) returns boolean
language plpgsql as $helper$
begin
  perform public.fn_platform_school_detail(p_school);
  return false;
exception when others then
  return true;
end;
$helper$;

-- =============================================================================
-- TEST 9 — THE SCHOOL-DETAIL SCREEN MUST NOT BE A BACK DOOR.
--
-- 0075 lets the operator open a school without a support session, which is a
-- deliberate narrow exception to TEST 5. An exception with no assertion is a
-- hole, so the line it draws is asserted here in both directions:
--
--   IT MUST RETURN    counts, dates, and the school's own login list. Without
--                     these the console cannot tell a school that runs on the
--                     software from one that paid and never used it.
--
--   IT MUST NOT LEAK  a child's name, a guardian, a family, or a parent phone
--                     number. Nothing about a person the school SERVES.
--
-- For those there is fn_operator_enter: read-only, logged, and shown to the
-- school. That is the whole distinction — "how many pupils" is business
-- information, "which pupils" is the school's own affair, and wanting the second
-- should cost you a record saying why.
--
-- The check is a substring sweep over the rendered jsonb rather than a field
-- list, because a field list only covers the fields somebody thought of. If a
-- future edit adds a "recent admissions" block for convenience, this fails.
-- =============================================================================
do $detail$
declare
  a_school uuid := (select v from public._test_ids where k='a_school');
  b_school uuid := (select v from public._test_ids where k='b_school');
  a_owner  uuid := (select v from public._test_ids where k='a_owner');
  v_ops    uuid := '00000000-0000-0000-0000-0000000000fe';
  d jsonb; failures text := ''; needle text;
begin
  -- Distinctive values in School A, so a leak cannot be mistaken for anything
  -- else. The pupil already in the fixture is 'Alpha Student'; these are the
  -- people whose names must never appear.
  perform set_config('test.uid', '', false);
  insert into public.families (head_name, phone, whatsapp, school_id)
    values ('DETAILLEAK Family Head', '0300-7654321', '0300-7654321', a_school);
  insert into public.guardians (student_id, name, relation, phone, school_id)
    values ((select v from public._test_ids where k='a_stu'),
            'DETAILLEAK Guardian', 'father', '0300-1234567', a_school);

  perform set_config('test.uid', v_ops::text, false);
  set local role authenticated;
  d := public.fn_platform_school_detail(a_school);
  reset role;

  -- --- it has to be USEFUL ------------------------------------------------
  if d->'readiness' is null or jsonb_array_length(d->'readiness') < 8 then
    failures := failures || '  the readiness checklist is missing or short' || chr(10);
  end if;
  if (d->'counts'->>'students')::int < 1 then
    failures := failures || '  it reports no students for a school that has one' || chr(10);
  end if;
  if d->'people' is null or jsonb_array_length(d->'people') < 1 then
    failures := failures || '  it lists none of the school''s own logins' || chr(10);
  end if;
  -- ever_signed_in is the churn signal, and it comes from auth.users. If the
  -- stub lacks the column the whole block silently becomes null, which would
  -- look like "nobody has ever signed in" for every school forever.
  if not (d->'people'->0 ? 'ever_signed_in') then
    failures := failures || '  the login list carries no ever_signed_in flag' || chr(10);
  end if;
  if d->'activity' is null then
    failures := failures || '  no activity dates, so a dormant school looks live' || chr(10);
  end if;

  -- --- and it must not leak ------------------------------------------------
  foreach needle in array array[
    'Alpha Student',            -- the pupil
    'DETAILLEAK Family Head',  -- the family
    'DETAILLEAK Guardian',     -- the guardian
    '0300-7654321',            -- the family's phone
    '0300-1234567'             -- the guardian's phone
  ] loop
    if position(needle in d::text) > 0 then
      failures := failures
        || '  the detail payload contains "' || needle
        || '" — a person the school SERVES. Counts and dates only; use a support '
        || 'visit for anything about an individual.' || chr(10);
    end if;
  end loop;

  -- --- and it is still one school at a time --------------------------------
  perform set_config('test.uid', v_ops::text, false);
  set local role authenticated;
  d := public.fn_platform_school_detail(b_school);
  reset role;
  if position('DETAILLEAK' in d::text) > 0 then
    failures := failures || '  School B''s detail contains School A''s data' || chr(10);
  end if;

  -- --- a school user cannot call it at all ---------------------------------
  perform set_config('test.uid', a_owner::text, false);
  set local role authenticated;
  if not pg_temp_refused_detail(a_school) then
    failures := failures || '  a school owner could call fn_platform_school_detail' || chr(10);
  end if;
  reset role;

  if failures <> '' then
    raise exception E'THE SCHOOL-DETAIL SCREEN IS A BACK DOOR:\n%', failures;
  end if;
  raise notice 'ok: school detail gives the operator counts and dates, and no pupil, family or guardian';
end $detail$;

drop table if exists public._test_ids;
select 'TENANT ISOLATION: ALL TESTS PASSED' as result;

rollback;

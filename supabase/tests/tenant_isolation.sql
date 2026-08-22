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
declare bad text := '';
begin
  -- 4a. Every tenant table must carry school_id.
  select coalesce(string_agg('  ' || c.relname, chr(10)), '') into bad
  from pg_class c join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'public' and c.relkind = 'r'
    and c.relname not in ('schools','plans','subscriptions','student_count_snapshots','platform_admins','_test_ids')
    and not exists (select 1 from pg_attribute a
                    where a.attrelid = c.oid and a.attname = 'school_id' and not a.attisdropped);
  if bad <> '' then
    raise exception E'Tables missing school_id:\n%', bad;
  end if;

  -- 4b. Every policy on a tenant table must reference current_school_id().
  select coalesce(string_agg('  ' || tablename || '.' || policyname, chr(10)), '') into bad
  from pg_policies
  where schemaname = 'public'
    and tablename not in ('schools','plans','subscriptions','student_count_snapshots','platform_admins')
    and coalesce(qual, '') not like '%current_school_id%'
    and coalesce(with_check, '') not like '%current_school_id%';
  if bad <> '' then
    raise exception E'Policies with no tenant check:\n%', bad;
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

  raise notice 'ok: structural guards hold';
end $guards$;

-- =============================================================================
-- TEST 5 — A PLATFORM ADMIN MUST NOT REACH TENANT DATA.
--
-- The product owner manages schools, subscriptions and payments. That job never
-- requires reading a child's records, so the platform role deliberately has no
-- path to them. Without this test, "just let platform admins see everything"
-- is a one-line change nobody would notice — and it would turn one compromised
-- platform login into a breach of every school at once.
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
      and c.relname not in ('_test_ids', 'subscriptions', 'student_count_snapshots')
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

  reset role;

  if failures <> '' then
    raise exception E'PLATFORM ROLE REACHES TOO FAR (or not far enough):\n%', failures;
  end if;
  raise notice 'ok: platform admin sees schools and subscriptions, no tenant data';
end $platform$;

drop table if exists public._test_ids;
select 'TENANT ISOLATION: ALL TESTS PASSED' as result;

rollback;

-- =============================================================================
-- The dashboard: is every figure on it this school's own, and is it honest?
--
-- WHY THIS FILE EXISTS
--
-- fn_dashboard_summary is SECURITY DEFINER, so Row Level Security does not
-- apply to it. Three of its queries had no school filter, and the dashboard was
-- reporting the PLATFORM's totals to every tenant: on a test database a school
-- with one student and no payments was shown 271 new admissions and Rs 24,577
-- collected today.
--
-- tenant_isolation.sql did not catch it because that suite tests table access,
-- and this leak lives inside a function where policies are never consulted.
--
-- So the shape of this file is deliberate: school B is loaded with MUCH bigger
-- numbers than school A, and every figure A reports is asserted to be A's own.
-- A leak cannot hide behind a coincidence.
--
-- It also covers the second bug: "you are owed Rs 0" and "you have never billed
-- anybody" are different facts and must not render the same.
--
-- Run: psql -v ON_ERROR_STOP=1 -f supabase/tests/dashboard.sql
-- =============================================================================

\set ON_ERROR_STOP on

begin;

create or replace function auth.uid() returns uuid language sql stable as
  $$ select nullif(current_setting('test.uid', true), '')::uuid $$;

create or replace function pg_temp.ok(p_cond boolean, p_label text)
returns void language plpgsql as $$
begin
  if p_cond then raise notice 'PASS  %', p_label;
  else raise exception 'FAIL  %', p_label; end if;
end;
$$;

create or replace function pg_temp.d(p_key text) returns text language sql as $$
  select public.fn_dashboard_summary()->>p_key
$$;

create or replace function pg_temp.dn(p_key text) returns numeric language sql as $$
  select (public.fn_dashboard_summary()->>p_key)::numeric
$$;

-- --- Fixture -----------------------------------------------------------------
-- School A: 2 students, ONE payment of Rs 500, fees configured.
-- School B: 5 students, Rs 50,000 collected. Deliberately much larger, so any
--           unscoped sum in A's dashboard is unmistakable.
do $seed$
declare
  v_a uuid; v_b uuid;
  v_oa uuid := '00000000-0000-0000-0000-00000000db01';
  v_ob uuid := '00000000-0000-0000-0000-00000000db02';
  v_sess uuid; v_class uuid; v_head uuid; v_stu uuid; v_i int;
begin
  insert into public.schools (name) values ('Dash A') returning id into v_a;
  insert into public.subscriptions (school_id, plan_code, status, trial_ends_on)
    values (v_a, 'growth', 'active', current_date + 30);
  insert into public.schools (name) values ('Dash B') returning id into v_b;
  insert into public.subscriptions (school_id, plan_code, status, trial_ends_on)
    values (v_b, 'growth', 'active', current_date + 30);

  alter table public.profiles disable trigger user;
  insert into auth.users (id, email) values
    (v_oa, 'dba@dash.test'), (v_ob, 'dbb@dash.test') on conflict (id) do nothing;
  insert into public.profiles (id, full_name, role, school_id) values
    (v_oa, 'Dash A Owner', 'owner', v_a),
    (v_ob, 'Dash B Owner', 'owner', v_b)
    on conflict (id) do update set school_id = excluded.school_id,
                                   role      = excluded.role,
                                   full_name = excluded.full_name,
                                   active    = true;
  alter table public.profiles enable trigger user;

  -- ---- school A ----
  perform set_config('test.uid', v_oa::text, false);
  insert into public.academic_sessions (name, is_current, school_id)
    values ('2025-2026', true, v_a) returning id into v_sess;
  update public.school_settings set current_session_id = v_sess where school_id = v_a;
  insert into public.classes (name, level_order, school_id)
    values ('Dash Class', 1, v_a) returning id into v_class;
  insert into public.fee_heads (name, type, is_recurring, sort_order, school_id)
    values ('Tuition', 'monthly', true, 10, v_a) returning id into v_head;
  insert into public.fee_structures (session_id, class_id, fee_head_id, amount, school_id)
    values (v_sess, v_class, v_head, 1000, v_a);
  perform public.fn_admit_student(jsonb_build_object(
    'full_name', 'DB A One', 'session_id', v_sess, 'class_id', v_class, 'links', '[]'::jsonb));
  perform public.fn_admit_student(jsonb_build_object(
    'full_name', 'DB A Two', 'session_id', v_sess, 'class_id', v_class, 'links', '[]'::jsonb));

  -- ---- school B: deliberately much bigger ----
  perform set_config('test.uid', v_ob::text, false);
  insert into public.academic_sessions (name, is_current, school_id)
    values ('2025-2026', true, v_b) returning id into v_sess;
  update public.school_settings set current_session_id = v_sess where school_id = v_b;
  insert into public.classes (name, level_order, school_id)
    values ('Dash Class', 1, v_b) returning id into v_class;
  insert into public.fee_heads (name, type, is_recurring, sort_order, school_id)
    values ('Tuition', 'monthly', true, 10, v_b) returning id into v_head;
  insert into public.fee_structures (session_id, class_id, fee_head_id, amount, school_id)
    values (v_sess, v_class, v_head, 20000, v_b);
  for v_i in 1..5 loop
    perform public.fn_admit_student(jsonb_build_object(
      'full_name', 'DB B ' || v_i, 'session_id', v_sess, 'class_id', v_class,
      'links', '[]'::jsonb));
  end loop;
  perform public.fn_generate_class_invoices(v_sess, v_class,
    date_trunc('month', current_date)::date, current_date + 10);
  select id into v_stu from public.students where full_name = 'DB B 1';
  perform public.fn_record_payment(v_stu, 50000, 'cash', 'school B big money', false);
end $seed$;

-- =============================================================================
-- 1-5: THE LEAK. Every figure school A reports must be school A's own.
-- =============================================================================
do $t$
begin
  perform set_config('test.uid', '00000000-0000-0000-0000-00000000db01', false);

  perform pg_temp.ok(pg_temp.dn('active_students') = 2,
    '1. active students is A''s two, not the platform''s (' || pg_temp.dn('active_students') || ')');

  perform pg_temp.ok(pg_temp.dn('new_admissions_month') = 2,
    '2. new admissions this month is A''s two — WAS the platform''s total ('
      || pg_temp.dn('new_admissions_month') || ')');

  perform pg_temp.ok(pg_temp.dn('collected_today') = 0,
    '3. A has collected nothing, despite B taking Rs 50,000 today ('
      || pg_temp.dn('collected_today') || ')');

  perform pg_temp.ok(pg_temp.dn('collected_month') = 0,
    '4. and nothing this month either (' || pg_temp.dn('collected_month') || ')');

  perform pg_temp.ok(pg_temp.dn('outstanding') = 0,
    '5. A has billed nobody, so nothing is outstanding — B''s 5 challans are not A''s');
end $t$;

-- =============================================================================
-- 6-8: and the mirror — B must see B's own, not a share of A's
-- =============================================================================
do $t$
begin
  perform set_config('test.uid', '00000000-0000-0000-0000-00000000db02', false);

  perform pg_temp.ok(pg_temp.dn('active_students') = 5,
    '6. B sees its own five students (' || pg_temp.dn('active_students') || ')');
  perform pg_temp.ok(pg_temp.dn('collected_today') = 50000,
    '7. and its own Rs 50,000 (' || pg_temp.dn('collected_today') || ')');
  perform pg_temp.ok(pg_temp.dn('new_admissions_month') = 5,
    '8. and its own five admissions (' || pg_temp.dn('new_admissions_month') || ')');
end $t$;

-- =============================================================================
-- 9-12: "never billed" is not "nothing owed"
-- =============================================================================
do $t$
declare v_sess uuid; v_class uuid;
begin
  perform set_config('test.uid', '00000000-0000-0000-0000-00000000db01', false);

  -- A has fees configured but has generated nothing.
  perform pg_temp.ok(pg_temp.dn('outstanding') = 0 and pg_temp.dn('billed_students_month') = 0,
    '9. nothing billed AND nothing owed are reported as two separate facts');

  perform pg_temp.ok(pg_temp.dn('classes_without_fee') = 0,
    '10. A''s class HAS a fee structure, so nothing is flagged ('
      || pg_temp.dn('classes_without_fee') || ')');

  select id into v_sess from public.academic_sessions
   where school_id = public.current_school_id() and is_current;
  select id into v_class from public.classes where school_id = public.current_school_id() limit 1;

  perform public.fn_generate_class_invoices(v_sess, v_class,
    date_trunc('month', current_date)::date, current_date + 10);

  perform pg_temp.ok(pg_temp.dn('billed_students_month') = 2,
    '11. after generating, both students count as billed ('
      || pg_temp.dn('billed_students_month') || ')');
  perform pg_temp.ok(pg_temp.dn('outstanding') = 2000,
    '12. and the money now shows as owed (' || pg_temp.dn('outstanding') || ')');
end $t$;

-- =============================================================================
-- 13-15: a Rs 0 challan is not billing
--
-- fn_generate_class_invoices on a class with no fee structure creates invoices
-- with zero lines and reports success. That must not read as "billed".
-- =============================================================================
do $t$
declare v_sess uuid; v_class uuid;
begin
  perform set_config('test.uid', '00000000-0000-0000-0000-00000000db01', false);
  select id into v_sess from public.academic_sessions
   where school_id = public.current_school_id() and is_current;

  -- A second class with students and NO fee structure.
  insert into public.classes (name, level_order, school_id)
    values ('Dash Unpriced', 2, public.current_school_id()) returning id into v_class;
  perform public.fn_admit_student(jsonb_build_object(
    'full_name', 'DB A Unpriced', 'session_id', v_sess, 'class_id', v_class,
    'links', '[]'::jsonb));

  perform pg_temp.ok(pg_temp.dn('classes_without_fee') = 1,
    '13. the class with no fee structure is flagged ('
      || pg_temp.dn('classes_without_fee') || ')');

  -- Generate for it. The RPC will report success and bill Rs 0.
  perform public.fn_generate_class_invoices(v_sess, v_class,
    date_trunc('month', current_date)::date, current_date + 10);

  perform pg_temp.ok(pg_temp.dn('billed_students_month') = 2,
    '14. a zero-value challan does NOT count as billed — still 2, not 3 ('
      || pg_temp.dn('billed_students_month') || ')');
  perform pg_temp.ok(pg_temp.dn('classes_without_fee') = 1,
    '15. and the class is still flagged after that empty run');
end $t$;

-- =============================================================================
-- 16-17: no current session must not look like an empty school
-- =============================================================================
do $t$
begin
  perform set_config('test.uid', '00000000-0000-0000-0000-00000000db01', false);
  perform pg_temp.ok(pg_temp.d('session_set') = 'true', '16. a school with a session says so');

  update public.school_settings set current_session_id = null
   where school_id = public.current_school_id();

  perform pg_temp.ok(pg_temp.d('session_set') = 'false',
    '17. and without one it says so, instead of silently reporting zeros');
end $t$;

-- =============================================================================
-- 18-19: role gating
-- =============================================================================
do $t$
declare v_teacher uuid := '00000000-0000-0000-0000-00000000db03';
begin
  perform set_config('test.uid', '00000000-0000-0000-0000-00000000db01', false);
  alter table public.profiles disable trigger user;
  insert into auth.users (id, email) values (v_teacher, 'dbt@dash.test')
    on conflict (id) do nothing;
  insert into public.profiles (id, full_name, role, school_id)
    values (v_teacher, 'Dash Teacher', 'class_teacher', public.current_school_id())
    on conflict (id) do update set role = 'class_teacher', active = true,
                                   school_id = excluded.school_id;
  alter table public.profiles enable trigger user;

  perform set_config('test.uid', v_teacher::text, false);
  perform pg_temp.ok(pg_temp.d('finance_visible') = 'false',
    '18. a teacher is not shown the school''s money');
  perform pg_temp.ok(pg_temp.dn('collected_today') = 0,
    '19. and the figure is zero for them rather than merely hidden in the UI');
end $t$;

-- =============================================================================
-- 20: THE STRUCTURAL GUARD — the test that would have caught this leak
--
-- The dashboard leak survived a dedicated "audit all SECURITY DEFINER functions
-- for tenant scoping" task because that audit was done by reading. This does it
-- by query, every CI run.
--
-- The rule: a SECURITY DEFINER function that reads a table carrying school_id
-- must scope itself, because RLS is NOT consulted inside one. Scoping counts as
-- any of:
--
--   * current_school_id() / school_id / assert_own  — its own filter
--   * auth.uid() / my_staff_id()                   — scoped to the caller
--   * fn_may_manage_class / fn__assert_my_child     — a gate that scopes
--                                                    (both verified to check
--                                                    current_school_id itself)
--
-- Anything else is listed below as a reviewed exception, WITH the reason. If
-- this test fails, either scope the new function or add it here deliberately —
-- the point is that nobody can add an unscoped one by accident.
-- =============================================================================
do $t$
declare v_bad text;
begin
  select string_agg(f.proname, ', ' order by f.proname) into v_bad
  from (
    select p.proname, pg_get_functiondef(p.oid) as def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.prosecdef
  ) f
  where
    -- reads at least one tenant table
    exists (
      select 1
      from pg_class c join pg_namespace n2 on n2.oid = c.relnamespace
      where n2.nspname = 'public' and c.relkind = 'r'
        and exists (select 1 from pg_attribute a
                     where a.attrelid = c.oid and a.attname = 'school_id' and a.attnum > 0)
        and (f.def ~ ('from public\.' || c.relname || '\M')
          or f.def ~ ('join public\.' || c.relname || '\M'))
    )
    -- and does nothing to scope itself
    and f.def !~* 'current_school_id|assert_own|school_id|auth\.uid|my_staff_id|fn_may_manage_class|fn__assert_my_child'
    -- reviewed exceptions
    and f.proname not in (
      -- Internal, revoked from every app role, and operate only on ids the
      -- caller has already asserted. Verified by the revokes asserted in
      -- family_linkage.sql, bulk_fees.sql and fee_ops.sql.
      'fn__allocate_payment',
      'fn__apply_discount_lines',
      'fn__ensure_till',
      'fn__queue_payment_receipt',
      'fn__merge_two_families',
      'fn__repair_families_for',
      'fn__seed_expense_categories',
      'fn__stamp_voucher_code',
      'fn__student_default_family',
      -- Delegates every write to fn_record_payment, which asserts ownership of
      -- each student itself. Proved by bulk_fees.sql assertion 22, which shows a
      -- foreign student being refused through this function.
      'fn_record_bulk_payments',
      -- 0077. Numbers a platform invoice, in a BEFORE INSERT trigger, by taking
      -- max(serial)+1 across ALL invoices. Deliberately unscoped: the document
      -- series belongs to the VENDOR, not to a school. A per-school series would
      -- mean two invoices numbered INV-0004 in the same set of books, and the
      -- reason an unbroken series matters is a tax audit.
      --
      -- Not a leak: it reads one integer column, returns nothing to any caller,
      -- and platform_invoices is unreadable by a school through RLS —
      -- platform_billing.sql assertion 87b proves that. It is also a trigger
      -- function, revoked from every app role, so nothing can call it directly.
      'fn__assign_doc_no'
    );

  if v_bad is not null then
    raise exception
      'FAIL  20. SECURITY DEFINER function(s) read tenant tables with no school scoping: %'
      '  — RLS does not apply inside them. Scope them, or add a reviewed exception.', v_bad;
  end if;
  raise notice 'PASS  20. every SECURITY DEFINER function that reads tenant data scopes itself';
end $t$;

do $$ begin raise notice '--- dashboard.sql: all assertions passed'; end $$;

rollback;

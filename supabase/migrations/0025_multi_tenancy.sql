-- =============================================================================
-- Multi-tenancy foundation — one Supabase project serves ALL schools.
--
-- This migration supersedes the "one database == one school" assumption stated
-- at the top of 0001_core_schema.sql. From here on:
--
--   * Every tenant table carries `school_id`.
--   * Every RLS policy is (tenant check) AND (role check). Never role alone.
--   * `current_school_id()` resolves the caller's school from their profile,
--     mirroring the existing `has_role()` idiom.
--   * A BEFORE INSERT trigger stamps school_id automatically AND rejects any
--     row addressed to a different school — defence in depth, so a forgotten
--     `.eq('school_id', ...)` in application code cannot write across tenants.
--
-- Platform-level tables (schools / plans / subscriptions) are NOT tenant data.
-- A school may read its own subscription (so the app knows if it is locked) but
-- may never write it. All platform administration happens through Edge
-- Functions using the service-role key — deliberately NOT via a "god mode"
-- bypass inside tenant policies, because such a bypass is a permanent hole.
-- =============================================================================

-- ===========================================================================
-- 1. Platform tables: schools, plans, subscriptions
-- ===========================================================================

create type public.subscription_status as enum (
  'trialing',   -- inside the 14-day free trial
  'active',     -- paid and current
  'grace',      -- period ended, inside the 14-day grace window; app still works
  'locked',     -- past grace; daily operations blocked, export still allowed
  'cancelled'   -- ended deliberately
);

create type public.billing_cycle as enum ('monthly', 'yearly');

create table public.plans (
  code            text primary key,          -- 'starter' | 'growth' | 'institution' | 'custom'
  name            text not null,
  student_limit   integer,                   -- null = no limit (custom contracts)
  price_monthly   numeric(12,2) not null default 0,
  price_yearly    numeric(12,2) not null default 0,
  sort_order      integer not null default 0,
  active          boolean not null default true
);

-- Prices in PKR. Yearly = 10x monthly ("two months free").
insert into public.plans (code, name, student_limit, price_monthly, price_yearly, sort_order) values
  ('starter',     'Starter (up to 200 students)',    200,  3500,  35000, 1),
  ('growth',      'Growth (201-500 students)',       500,  5500,  55000, 2),
  ('institution', 'Institution (501-1500 students)', 1500, 7500,  75000, 3),
  ('custom',      'Custom (1500+ students)',         null,     0,      0, 4);

create table public.schools (
  id            uuid primary key default gen_random_uuid(),
  name          text not null,
  city          text,
  contact_name  text,
  contact_phone text,
  contact_email text,
  notes         text,                                   -- internal, platform-only
  active        boolean not null default true,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);
create trigger trg_schools_updated before update on public.schools
  for each row execute function public.set_updated_at();

-- The margin above a plan's student_limit that is tolerated silently (10%).
-- 200 -> 220, 500 -> 550, 1500 -> 1650. Matches the agreed commercial rule.
create table public.subscriptions (
  school_id            uuid primary key references public.schools(id) on delete cascade,
  plan_code            text not null references public.plans(code),
  status               public.subscription_status not null default 'trialing',
  cycle                public.billing_cycle not null default 'yearly',

  trial_ends_on        date,                  -- set on creation: today + 14
  period_start         date,
  period_end           date,                  -- paid-through date
  grace_ends_on        date,                  -- period_end + 14, computed on expiry

  -- Cached student count, refreshed by fn_refresh_student_count().
  student_count        integer not null default 0,
  counted_at           timestamptz,

  -- Set when the school passes limit + 10%; surfaces in the platform panel.
  over_limit_flagged_at timestamptz,

  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now()
);
create trigger trg_subscriptions_updated before update on public.subscriptions
  for each row execute function public.set_updated_at();

-- Historical record of the student count, so a plan upgrade is never a
-- "trust me" conversation — there is a dated row to point at.
create table public.student_count_snapshots (
  id            bigint generated always as identity primary key,
  school_id     uuid not null references public.schools(id) on delete cascade,
  counted_on    date not null default current_date,
  student_count integer not null,
  plan_code     text not null,
  student_limit integer,
  created_at    timestamptz not null default now(),
  unique (school_id, counted_on)
);

-- ===========================================================================
-- 2. Anchor the tenant on the profile, and the resolver everything hangs off
-- ===========================================================================

alter table public.profiles add column school_id uuid references public.schools(id);

-- The caller's school. SECURITY DEFINER so policies calling it do not recurse
-- through profiles' own RLS — same reasoning as has_role() in 0001.
-- STABLE lets the planner evaluate it once per statement rather than per row.
create or replace function public.current_school_id() returns uuid
language sql stable security definer set search_path = public as $$
  select school_id from public.profiles where id = auth.uid();
$$;

grant execute on function public.current_school_id() to authenticated;

-- A profile's school is immutable once set. Moving a user between schools would
-- silently hand them another tenant's data; it must be a deliberate
-- service-role operation, never something reachable from the app.
create or replace function public.guard_profile_school() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if old.school_id is not null and new.school_id is distinct from old.school_id then
    raise exception 'A user cannot be moved between schools';
  end if;
  return new;
end;
$$;
create trigger trg_profiles_school_guard before update on public.profiles
  for each row execute function public.guard_profile_school();

-- ---------------------------------------------------------------------------
-- assert_own() — the guard every SECURITY DEFINER function needs.
--
-- SECURITY DEFINER functions run as `postgres`, which carries both rolsuper and
-- rolbypassrls, so RLS does NOT apply inside them — not even with FORCE ROW
-- LEVEL SECURITY, which superusers bypass regardless. That means the tenant
-- policies in section 8 protect direct table access only. Any function taking
-- an id parameter must therefore check that id itself, or a user can pass
-- another school's id and the function will act on it happily.
--
-- Every such function calls this on entry. Raises 42501 (insufficient
-- privilege) rather than returning empty, so a caller cannot tell "not yours"
-- apart from "does not exist" — the id space stays unprobeable.
-- ---------------------------------------------------------------------------
create or replace function public.assert_own(p_table text, p_id uuid) returns void
language plpgsql stable security definer set search_path = public as $$
declare
  v_school uuid := public.current_school_id();
  v_ok     boolean;
begin
  if p_id is null then return; end if;          -- optional args stay optional
  if v_school is null then
    raise exception 'No school context for this user' using errcode = '42501';
  end if;
  execute format(
    'select exists (select 1 from public.%I where id = $1 and school_id = $2)', p_table)
    into v_ok using p_id, v_school;
  if not v_ok then
    raise exception '% not found in this school', p_table using errcode = '42501';
  end if;
end;
$$;

grant execute on function public.assert_own(text, uuid) to authenticated;

-- ===========================================================================
-- 3. Stamp every tenant table with school_id
-- ===========================================================================

do $$
declare t text;
begin
  foreach t in array array[
    'school_settings', 'academic_sessions', 'campuses', 'shifts', 'classes',
    'sections', 'subjects', 'staff', 'students', 'guardians', 'enrollments',
    'fee_heads', 'fee_structures', 'student_fee_items', 'discounts',
    'invoices', 'invoice_lines', 'payments', 'payment_allocations',
    'adjustments', 'attendance_daily', 'assessments', 'exam_terms',
    'exam_subjects', 'mark_entries', 'result_cards', 'certificates',
    'audit_log', 'student_links', 'teacher_assignments', 'staff_attendance',
    'staff_checkin_codes'
  ] loop
    execute format(
      'alter table public.%I add column school_id uuid references public.schools(id);', t);
  end loop;
end $$;

-- Development databases are reset for this change (agreed: no data to keep).
-- If any rows survive, attach them to a single bootstrap school so the NOT NULL
-- below succeeds rather than failing the migration halfway.
do $$
declare v_school uuid; t text; v_rows bigint := 0;
begin
  for t in select unnest(array[
    'school_settings', 'academic_sessions', 'campuses', 'shifts', 'classes',
    'sections', 'subjects', 'staff', 'students', 'guardians', 'enrollments',
    'fee_heads', 'fee_structures', 'student_fee_items', 'discounts',
    'invoices', 'invoice_lines', 'payments', 'payment_allocations',
    'adjustments', 'attendance_daily', 'assessments', 'exam_terms',
    'exam_subjects', 'mark_entries', 'result_cards', 'certificates',
    'audit_log', 'student_links', 'teacher_assignments', 'staff_attendance',
    'staff_checkin_codes'])
  loop
    execute format('select count(*) from public.%I', t) into v_rows;
    exit when v_rows > 0;
  end loop;

  if v_rows > 0 or exists (select 1 from public.profiles) then
    insert into public.schools (name, notes)
    values ('Bootstrap School', 'Auto-created by 0025 for pre-existing rows')
    returning id into v_school;

    insert into public.subscriptions (school_id, plan_code, status, trial_ends_on)
    values (v_school, 'starter', 'trialing', current_date + 14);

    update public.profiles set school_id = v_school where school_id is null;

    foreach t in array array[
      'school_settings', 'academic_sessions', 'campuses', 'shifts', 'classes',
      'sections', 'subjects', 'staff', 'students', 'guardians', 'enrollments',
      'fee_heads', 'fee_structures', 'student_fee_items', 'discounts',
      'invoices', 'invoice_lines', 'payments', 'payment_allocations',
      'adjustments', 'attendance_daily', 'assessments', 'exam_terms',
      'exam_subjects', 'mark_entries', 'result_cards', 'certificates',
      'audit_log', 'student_links', 'teacher_assignments', 'staff_attendance',
      'staff_checkin_codes'
    ] loop
      execute format('update public.%I set school_id = $1 where school_id is null;', t)
        using v_school;
    end loop;
  end if;
end $$;

-- Now enforce. Every tenant row must belong to a school, and every tenant table
-- gets a school_id index — RLS filters on it in every single query.
do $$
declare t text;
begin
  foreach t in array array[
    'school_settings', 'academic_sessions', 'campuses', 'shifts', 'classes',
    'sections', 'subjects', 'staff', 'students', 'guardians', 'enrollments',
    'fee_heads', 'fee_structures', 'student_fee_items', 'discounts',
    'invoices', 'invoice_lines', 'payments', 'payment_allocations',
    'adjustments', 'attendance_daily', 'assessments', 'exam_terms',
    'exam_subjects', 'mark_entries', 'result_cards', 'certificates',
    'audit_log', 'student_links', 'teacher_assignments', 'staff_attendance',
    'staff_checkin_codes'
  ] loop
    execute format('alter table public.%I alter column school_id set not null;', t);
    execute format('create index idx_%1$s_school on public.%1$s (school_id);', t);
  end loop;
end $$;

-- ===========================================================================
-- 4. Automatic stamping + cross-tenant write rejection
--
-- Every tenant table gets this BEFORE INSERT/UPDATE trigger. It means:
--   * application code never has to remember to set school_id, and
--   * if application code sets the WRONG school_id, the write is refused.
-- RLS already blocks this via WITH CHECK; the trigger is the second lock, and
-- it also covers SECURITY DEFINER paths where RLS does not apply at all.
-- ===========================================================================

create or replace function public.enforce_school_id() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_school uuid := public.current_school_id();
begin
  if tg_op = 'INSERT' then
    if new.school_id is null then
      new.school_id := v_school;
    elsif v_school is not null and new.school_id <> v_school then
      raise exception 'Cross-tenant write refused on %: row addressed to school %, caller belongs to %',
        tg_table_name, new.school_id, v_school;
    end if;
    if new.school_id is null then
      raise exception 'Cannot write to % : no school context for this user', tg_table_name;
    end if;
  else
    if new.school_id is distinct from old.school_id then
      raise exception 'A % row cannot be moved between schools', tg_table_name;
    end if;
  end if;
  return new;
end;
$$;

do $$
declare t text;
begin
  foreach t in array array[
    'school_settings', 'academic_sessions', 'campuses', 'shifts', 'classes',
    'sections', 'subjects', 'staff', 'students', 'guardians', 'enrollments',
    'fee_heads', 'fee_structures', 'student_fee_items', 'discounts',
    'invoices', 'invoice_lines', 'payments', 'payment_allocations',
    'adjustments', 'attendance_daily', 'assessments', 'exam_terms',
    'exam_subjects', 'mark_entries', 'result_cards', 'certificates',
    'student_links', 'teacher_assignments', 'staff_attendance',
    'staff_checkin_codes'
  ] loop
    execute format(
      'create trigger trg_%1$s_school before insert or update on public.%1$s
         for each row execute function public.enforce_school_id();', t);
  end loop;
end $$;

-- ===========================================================================
-- 5. Per-school counters
--
-- WAS: counters(key text primary key) — a single global pot. Two schools would
-- have shared one receipt number series, destroying the gapless-receipt control
-- that exists to make cash theft visible. Now keyed per school, so every school
-- starts its own series at 1.
--
-- next_counter(text) keeps its signature so all nine existing call sites work
-- unchanged; it resolves the school itself.
-- ===========================================================================

alter table public.counters add column school_id uuid references public.schools(id);

update public.counters c set school_id = (select id from public.schools order by created_at limit 1)
  where c.school_id is null;
delete from public.counters where school_id is null;

alter table public.counters drop constraint counters_pkey;
alter table public.counters alter column school_id set not null;
alter table public.counters add primary key (school_id, key);

create or replace function public.next_counter(p_key text) returns bigint
language plpgsql security definer set search_path = public as $$
declare
  v       bigint;
  v_school uuid := public.current_school_id();
begin
  if v_school is null then
    raise exception 'next_counter(%): no school context for this user', p_key;
  end if;
  insert into public.counters(school_id, key, value) values (v_school, p_key, 1)
  on conflict (school_id, key) do update set value = public.counters.value + 1
  returning value into v;
  return v;
end;
$$;

-- ===========================================================================
-- 6. School settings: singleton -> one row per school
--
-- WAS: id integer primary key default 1 check (id = 1) — the table could
-- physically hold exactly one school's settings.
-- ===========================================================================

alter table public.school_settings drop constraint school_settings_id_check;
alter table public.school_settings drop constraint school_settings_pkey;
alter table public.school_settings alter column id drop default;
alter table public.school_settings add primary key (school_id);
alter table public.school_settings drop column id;

-- Creating a school creates its settings row, so the app never has to handle
-- "settings missing" as a separate state.
create or replace function public.fn_provision_school_settings() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.school_settings (school_id, name)
  values (new.id, new.name)
  on conflict (school_id) do nothing;
  return new;
end;
$$;
create trigger trg_schools_provision after insert on public.schools
  for each row execute function public.fn_provision_school_settings();

-- ===========================================================================
-- 7. Unique constraints that would collide across schools
--
-- Each of these was globally unique. In a shared database that means one
-- school's value silently blocks another school from using it — e.g. School A
-- registering GR number "001" would make "001" un-issuable for every other
-- school in the country.
-- ===========================================================================

-- GR number: lifelong per student, unique WITHIN a school.
alter table public.students drop constraint students_gr_no_key;
alter table public.students add constraint students_gr_no_school_key unique (school_id, gr_no);

-- Certificate serials: the anti-fraud series must restart per school.
alter table public.certificates drop constraint certificates_cert_type_serial_no_key;
alter table public.certificates
  add constraint certificates_school_type_serial_key unique (school_id, cert_type, serial_no);

-- Staff check-in codes: scoped per school, so a code printed at one school can
-- never be redeemed at another.
alter table public.staff_checkin_codes drop constraint staff_checkin_codes_code_key;
alter table public.staff_checkin_codes
  add constraint staff_checkin_codes_school_code_key unique (school_id, code);

-- ===========================================================================
-- 8. Row Level Security — every policy rebuilt as (tenant) AND (role)
--
-- Every policy from 0001/0019/0022/0023/0024 is dropped and recreated. The old
-- ones read `using (true)` for SELECT, which in a shared database means "every
-- logged-in user may read every school's rows".
-- ===========================================================================

do $$
declare r record;
begin
  for r in
    select schemaname, tablename, policyname
    from pg_policies
    where schemaname = 'public'
      and tablename in (
        'profiles', 'school_settings', 'academic_sessions', 'campuses', 'shifts',
        'classes', 'sections', 'subjects', 'staff', 'students', 'guardians',
        'enrollments', 'fee_heads', 'fee_structures', 'student_fee_items',
        'discounts', 'invoices', 'invoice_lines', 'payments',
        'payment_allocations', 'adjustments', 'attendance_daily', 'assessments',
        'exam_terms', 'exam_subjects', 'mark_entries', 'result_cards',
        'certificates', 'audit_log', 'student_links', 'teacher_assignments',
        'staff_attendance', 'staff_checkin_codes')
  loop
    execute format('drop policy %I on public.%I;', r.policyname, r.tablename);
  end loop;
end $$;

-- --- Profiles ---------------------------------------------------------------
-- Staff directory is readable within the school only.
create policy profiles_select on public.profiles for select to authenticated
  using (school_id = public.current_school_id());
create policy profiles_insert on public.profiles for insert to authenticated
  with check (school_id = public.current_school_id() and public.has_role('owner', 'principal'));
create policy profiles_update on public.profiles for update to authenticated
  using (school_id = public.current_school_id()
         and (id = auth.uid() or public.has_role('owner', 'principal')))
  with check (school_id = public.current_school_id()
         and (id = auth.uid() or public.has_role('owner', 'principal')));
create policy profiles_delete on public.profiles for delete to authenticated
  using (school_id = public.current_school_id() and public.has_role('owner', 'principal'));

-- --- School settings --------------------------------------------------------
create policy settings_select on public.school_settings for select to authenticated
  using (school_id = public.current_school_id());
create policy settings_write on public.school_settings for all to authenticated
  using (school_id = public.current_school_id() and public.has_role('owner', 'principal'))
  with check (school_id = public.current_school_id() and public.has_role('owner', 'principal'));

-- --- Reference/config: read within school; write owner/principal/admin_clerk -
do $$
declare t text;
begin
  foreach t in array array[
    'academic_sessions', 'campuses', 'shifts', 'classes', 'sections', 'subjects',
    'fee_heads', 'fee_structures'
  ] loop
    execute format($f$create policy %1$s_select on public.%1$s for select to authenticated
      using (school_id = public.current_school_id());$f$, t);
    execute format($f$create policy %1$s_write on public.%1$s for all to authenticated
      using (school_id = public.current_school_id()
             and public.has_role('owner','principal','admin_clerk'))
      with check (school_id = public.current_school_id()
             and public.has_role('owner','principal','admin_clerk'));$f$, t);
  end loop;
end $$;

-- --- Staff / students / guardians / enrollments ------------------------------
do $$
declare t text;
begin
  foreach t in array array['staff', 'students', 'guardians', 'enrollments'] loop
    execute format($f$create policy %1$s_select on public.%1$s for select to authenticated
      using (school_id = public.current_school_id());$f$, t);
    execute format($f$create policy %1$s_write on public.%1$s for all to authenticated
      using (school_id = public.current_school_id()
             and public.has_role('owner','principal','admin_clerk'))
      with check (school_id = public.current_school_id()
             and public.has_role('owner','principal','admin_clerk'));$f$, t);
  end loop;
end $$;

-- --- Finance: tenant + finance roles ----------------------------------------
do $$
declare t text;
begin
  foreach t in array array[
    'student_fee_items', 'discounts', 'invoices', 'invoice_lines',
    'payment_allocations', 'adjustments'
  ] loop
    execute format($f$create policy %1$s_select on public.%1$s for select to authenticated
      using (school_id = public.current_school_id()
             and public.has_role('owner','principal','admin_clerk','accountant'));$f$, t);
    execute format($f$create policy %1$s_write on public.%1$s for all to authenticated
      using (school_id = public.current_school_id()
             and public.has_role('owner','principal','admin_clerk','accountant'))
      with check (school_id = public.current_school_id()
             and public.has_role('owner','principal','admin_clerk','accountant'));$f$, t);
  end loop;
end $$;

-- --- Payments: still append-only (no update/delete policy) -------------------
create policy payments_select on public.payments for select to authenticated
  using (school_id = public.current_school_id()
         and public.has_role('owner', 'principal', 'admin_clerk', 'accountant'));
create policy payments_insert on public.payments for insert to authenticated
  with check (school_id = public.current_school_id()
         and public.has_role('owner', 'principal', 'admin_clerk', 'accountant'));

-- --- Attendance: still lock-after-finalize ----------------------------------
create policy attendance_select on public.attendance_daily for select to authenticated
  using (school_id = public.current_school_id());
create policy attendance_insert on public.attendance_daily for insert to authenticated
  with check (school_id = public.current_school_id()
         and public.has_role('owner', 'principal', 'admin_clerk', 'class_teacher', 'subject_teacher'));
create policy attendance_update on public.attendance_daily for update to authenticated
  using (school_id = public.current_school_id() and not is_locked
         and public.has_role('owner', 'principal', 'admin_clerk', 'class_teacher', 'subject_teacher'))
  with check (school_id = public.current_school_id()
         and public.has_role('owner', 'principal', 'admin_clerk', 'class_teacher', 'subject_teacher'));

-- --- Assessments & marks ----------------------------------------------------
create policy assessments_select on public.assessments for select to authenticated
  using (school_id = public.current_school_id());
create policy assessments_write on public.assessments for all to authenticated
  using (school_id = public.current_school_id()
         and public.has_role('owner', 'principal', 'admin_clerk', 'class_teacher', 'subject_teacher'))
  with check (school_id = public.current_school_id()
         and public.has_role('owner', 'principal', 'admin_clerk', 'class_teacher', 'subject_teacher'));

create policy marks_select on public.mark_entries for select to authenticated
  using (school_id = public.current_school_id());
create policy marks_insert on public.mark_entries for insert to authenticated
  with check (school_id = public.current_school_id()
         and public.has_role('owner', 'principal', 'admin_clerk', 'class_teacher', 'subject_teacher'));
create policy marks_update on public.mark_entries for update to authenticated
  using (school_id = public.current_school_id() and not is_locked
         and public.has_role('owner', 'principal', 'admin_clerk', 'class_teacher', 'subject_teacher'))
  with check (school_id = public.current_school_id()
         and public.has_role('owner', 'principal', 'admin_clerk', 'class_teacher', 'subject_teacher'));

-- --- Exam setup & result cards ----------------------------------------------
do $$
declare t text;
begin
  foreach t in array array['exam_terms', 'exam_subjects', 'result_cards'] loop
    execute format($f$create policy %1$s_select on public.%1$s for select to authenticated
      using (school_id = public.current_school_id());$f$, t);
    execute format($f$create policy %1$s_write on public.%1$s for all to authenticated
      using (school_id = public.current_school_id()
             and public.has_role('owner','principal','admin_clerk'))
      with check (school_id = public.current_school_id()
             and public.has_role('owner','principal','admin_clerk'));$f$, t);
  end loop;
end $$;

-- --- Certificates: append-only serial ---------------------------------------
create policy certificates_select on public.certificates for select to authenticated
  using (school_id = public.current_school_id()
         and public.has_role('owner', 'principal', 'admin_clerk'));
create policy certificates_insert on public.certificates for insert to authenticated
  with check (school_id = public.current_school_id()
         and public.has_role('owner', 'principal', 'admin_clerk'));

-- --- Audit log: read-only, own school ---------------------------------------
create policy audit_select on public.audit_log for select to authenticated
  using (school_id = public.current_school_id() and public.has_role('owner', 'principal'));

-- --- Family links -----------------------------------------------------------
create policy student_links_select on public.student_links for select to authenticated
  using (school_id = public.current_school_id());
create policy student_links_write on public.student_links for all to authenticated
  using (school_id = public.current_school_id()
         and public.has_role('owner','principal','admin_clerk'))
  with check (school_id = public.current_school_id()
         and public.has_role('owner','principal','admin_clerk'));

-- --- Teacher assignments ----------------------------------------------------
create policy teacher_assign_select on public.teacher_assignments for select to authenticated
  using (school_id = public.current_school_id());
create policy teacher_assign_write on public.teacher_assignments for all to authenticated
  using (school_id = public.current_school_id()
         and public.has_role('owner','principal','admin_clerk'))
  with check (school_id = public.current_school_id()
         and public.has_role('owner','principal','admin_clerk'));

-- --- Check-in codes ---------------------------------------------------------
create policy checkin_codes_select on public.staff_checkin_codes for select to authenticated
  using (school_id = public.current_school_id()
         and public.has_role('owner','principal','admin_clerk'));
create policy checkin_codes_write on public.staff_checkin_codes for all to authenticated
  using (school_id = public.current_school_id()
         and public.has_role('owner','principal','admin_clerk'))
  with check (school_id = public.current_school_id()
         and public.has_role('owner','principal','admin_clerk'));

-- --- Staff attendance: admins see the school; a teacher sees only themselves -
create policy staff_att_select on public.staff_attendance for select to authenticated
  using (school_id = public.current_school_id()
         and (public.has_role('owner','principal','admin_clerk')
              or staff_id = public.my_staff_id()));
create policy staff_att_insert on public.staff_attendance for insert to authenticated
  with check (school_id = public.current_school_id()
         and (public.has_role('owner','principal','admin_clerk')
              or staff_id = public.my_staff_id()));
create policy staff_att_update on public.staff_attendance for update to authenticated
  using (school_id = public.current_school_id()
         and public.has_role('owner','principal','admin_clerk'))
  with check (school_id = public.current_school_id()
         and public.has_role('owner','principal','admin_clerk'));

-- ===========================================================================
-- 9. Platform tables RLS
--
-- A school may read its own subscription and the plan catalogue (the app needs
-- both to render the licence banner). Nobody may write from the app — writes
-- happen only through service-role Edge Functions.
-- ===========================================================================

alter table public.schools                enable row level security;
alter table public.plans                  enable row level security;
alter table public.subscriptions          enable row level security;
alter table public.student_count_snapshots enable row level security;

create policy schools_select_own on public.schools for select to authenticated
  using (id = public.current_school_id());

create policy plans_select on public.plans for select to authenticated
  using (true);   -- public price list; contains no tenant data

create policy subscriptions_select_own on public.subscriptions for select to authenticated
  using (school_id = public.current_school_id());

create policy snapshots_select_own on public.student_count_snapshots for select to authenticated
  using (school_id = public.current_school_id()
         and public.has_role('owner', 'principal'));

-- No insert/update/delete policies on any platform table: service-role only.

-- ===========================================================================
-- 10. Auth provisioning, rewritten for many schools
--
-- The original (0011) had two problems once schools share a database:
--   * it set no school_id at all, so a new login belonged to nobody, and
--   * "first user becomes owner" counted profiles across the WHOLE table, so
--     only the very first user in the entire product got 'owner'. Every school
--     onboarded afterwards would have its owner created as 'readonly' — locked
--     out of their own school, unable even to assign roles.
--
-- The school now comes from the invite metadata that the signup / add-user Edge
-- Function sets, and "first user" is counted WITHIN that school.
-- ===========================================================================

create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_school   uuid := nullif(new.raw_user_meta_data->>'school_id', '')::uuid;
  v_is_first boolean;
begin
  -- No school in the invite metadata: create nothing rather than orphan a row.
  -- The provisioning function attaches the profile explicitly in that case.
  if v_school is null then
    return new;
  end if;

  select count(*) = 0 into v_is_first
  from public.profiles where school_id = v_school;

  insert into public.profiles (id, full_name, role, school_id)
  values (
    new.id,
    coalesce(nullif(new.raw_user_meta_data->>'full_name', ''), split_part(coalesce(new.email, ''), '@', 1)),
    (case when v_is_first then 'owner' else 'readonly' end)::public.user_role,
    v_school
  )
  on conflict (id) do nothing;

  return new;
end;
$$;

-- ===========================================================================
-- 11. Audit trigger: carry school_id onto the audit row
-- ===========================================================================

create or replace function public.audit_trigger() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  v_actor  uuid := auth.uid();
  v_role   public.user_role;
  v_id     text;
  v_school uuid;
begin
  select role into v_role from public.profiles where id = v_actor;
  v_id := coalesce((to_jsonb(new) ->> 'id'), (to_jsonb(old) ->> 'id'));
  -- Take the school from the audited row itself, not from the caller, so the
  -- audit trail stays correct even on service-role paths where the caller has
  -- no school context.
  v_school := coalesce(
    (to_jsonb(new) ->> 'school_id')::uuid,
    (to_jsonb(old) ->> 'school_id')::uuid,
    public.current_school_id()
  );
  insert into public.audit_log(school_id, actor, actor_role, action, entity, entity_id, before, after)
  values (
    v_school, v_actor, v_role, tg_op, tg_table_name, v_id,
    case when tg_op in ('UPDATE', 'DELETE') then to_jsonb(old) end,
    case when tg_op in ('INSERT', 'UPDATE') then to_jsonb(new) end
  );
  return coalesce(new, old);
end;
$$;

-- ===========================================================================
-- 12. Gatekeeper rewritten with a tenant check (supersedes 0022)
--
-- fn_may_manage_class guards fn_section_roster, fn_finalize_attendance,
-- fn_lock_assessment and fn_enter_assessment_marks. Its first clause was
-- has_role('owner','principal','admin_clerk'), which short-circuits to true for
-- ANY class id — so an admin passing another school's ids sailed through all
-- four. The tenant check now comes first and binds every role.
-- ===========================================================================

create or replace function public.fn_may_manage_class(p_session uuid, p_class uuid, p_section uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
      select 1 from public.academic_sessions s
      where s.id = p_session and s.school_id = public.current_school_id())
   and exists (
      select 1 from public.classes c
      where c.id = p_class and c.school_id = public.current_school_id())
   and (p_section is null or exists (
      select 1 from public.sections sec
      where sec.id = p_section and sec.school_id = public.current_school_id()))
   and (
     public.has_role('owner','principal','admin_clerk')
     or exists (
       select 1 from public.teacher_assignments ta
       join public.staff st on st.id = ta.staff_id
       join public.profiles pr on pr.staff_id = st.id
       where pr.id = auth.uid()
         and ta.session_id = p_session
         and ta.class_id = p_class
         and (ta.section_id is not distinct from p_section or ta.section_id is null)
     ));
$$;

-- ===========================================================================
-- 13. Grants
-- ===========================================================================

grant select on public.plans, public.schools, public.subscriptions,
                public.student_count_snapshots to authenticated;

-- 0001 granted table privileges to `authenticated` with a one-off
-- "on all tables in schema public" — which covers only the tables that existed
-- at that moment. Tables added by 0019/0022 were never granted; they work on
-- hosted Supabase purely because of its default-privilege setup. Relying on
-- that implicitly is fragile, so state it. RLS still decides which rows.
grant select, insert, update, delete on
  public.student_links, public.teacher_assignments,
  public.staff_attendance, public.staff_checkin_codes
to authenticated;

-- And make it automatic for anything added later, so this cannot recur.
alter default privileges in schema public
  grant select, insert, update, delete on tables to authenticated;

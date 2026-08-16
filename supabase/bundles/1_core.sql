-- =============================================================================
-- GENERATED FILE — DO NOT EDIT.
-- Built from supabase/migrations/ by supabase/build-bundles.sh
--
-- Paste this whole file into the Supabase SQL Editor and press Run.
-- Run the bundles in order, one at a time, waiting for each to finish.
-- =============================================================================


-- ─────────────────────────────────────────────────────────────────────────
-- 0001_core_schema.sql
-- ─────────────────────────────────────────────────────────────────────────
-- =============================================================================
-- School Manager — core schema (Phase 0 foundation)
--
-- SUPERSEDED BY 0025_multi_tenancy.sql — read that first.
--
-- This file was written when every school ran its own Supabase project, so it
-- has no `school_id` and its Row Level Security enforces ROLE-based access only
-- (separation of duties), not tenant isolation. All schools now share one
-- database: 0025 adds school_id to every table here and replaces every policy
-- below with one that checks the tenant as well as the role. Do not copy the
-- `using (true)` policy style from this file into anything new.
--
-- Design rules (see docs/02-DATA-MODEL.md):
--   * Identity (Student) is separate from year-state (Enrollment).
--   * Academic Session is the spine of all history.
--   * Money / marks / attendance are append-only or lock-after-finalize.
--   * Soft-delete (deleted_at), never physical delete, where history matters.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Enums
-- ---------------------------------------------------------------------------
create type public.user_role as enum (
  'owner', 'principal', 'admin_clerk', 'accountant', 'class_teacher', 'subject_teacher', 'readonly'
);
create type public.gender as enum ('male', 'female', 'other');
create type public.student_status as enum ('active', 'struck_off', 'withdrawn', 'graduated');
create type public.enrollment_status as enum ('active', 'promoted', 'retained', 'left', 'struck_off', 'graduated');
create type public.attendance_status as enum ('present', 'absent', 'leave', 'late', 'half_day');
create type public.fee_head_type as enum ('admission', 'monthly', 'annual', 'exam', 'security_deposit', 'transport', 'misc');
create type public.invoice_status as enum ('draft', 'issued', 'paid', 'partial', 'void');
create type public.payment_method as enum ('cash', 'bank_challan', 'jazzcash', 'easypaisa', 'bank_transfer', 'other');
create type public.discount_type as enum ('sibling', 'merit', 'staff_child', 'hardship', 'scholarship', 'other');
create type public.discount_status as enum ('pending', 'approved', 'rejected', 'revoked');
create type public.term_type as enum ('first', 'mid', 'second', 'final', 'pre_board', 'other');
create type public.certificate_type as enum ('leaving', 'character', 'bonafide', 'id_card', 'other');

-- ---------------------------------------------------------------------------
-- Helper functions (SECURITY DEFINER: owned by postgres → bypass RLS, so no
-- recursive RLS when a policy calls has_role() against profiles).
-- ---------------------------------------------------------------------------
create or replace function public.set_updated_at() returns trigger
language plpgsql as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

-- Gapless sequential counter (receipts, GR numbers, certificate serials).
-- Unlike a sequence, it does not skip on rollback — a gap is a red flag.
create table public.counters (
  key   text primary key,
  value bigint not null default 0
);

create or replace function public.next_counter(p_key text) returns bigint
language plpgsql security definer set search_path = public as $$
declare v bigint;
begin
  insert into public.counters(key, value) values (p_key, 1)
  on conflict (key) do update set value = public.counters.value + 1
  returning value into v;
  return v;
end;
$$;

-- ---------------------------------------------------------------------------
-- Profiles (1:1 with Supabase auth.users) + role
-- ---------------------------------------------------------------------------
create table public.profiles (
  id         uuid primary key references auth.users(id) on delete cascade,
  full_name  text,
  role       public.user_role not null default 'readonly',
  staff_id   uuid,                -- FK added after `staff` exists
  active     boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create trigger trg_profiles_updated before update on public.profiles
  for each row execute function public.set_updated_at();

-- Role helpers (SECURITY DEFINER: owned by postgres → bypass RLS, so a policy
-- calling has_role() against profiles does not recurse). Defined AFTER profiles
-- exists because SQL-language function bodies are validated at creation time.
create or replace function public.has_role(variadic roles public.user_role[]) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.profiles p
    where p.id = auth.uid() and p.role = any(roles)
  );
$$;

create or replace function public.auth_role() returns public.user_role
language sql stable security definer set search_path = public as $$
  select role from public.profiles where id = auth.uid();
$$;

-- Block privilege escalation: only owner/principal may change a role.
create or replace function public.guard_profile_role() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.role is distinct from old.role and not public.has_role('owner', 'principal') then
    raise exception 'Only owner/principal may change a user role';
  end if;
  return new;
end;
$$;
create trigger trg_profiles_role_guard before update on public.profiles
  for each row execute function public.guard_profile_role();

-- ---------------------------------------------------------------------------
-- School settings (singleton), sessions, campuses, shifts
-- ---------------------------------------------------------------------------
create table public.school_settings (
  id                 integer primary key default 1 check (id = 1),
  name               text not null default 'Your School',
  name_short         text,
  logo_url           text,
  address            text,
  phone              text,
  email              text,
  principal_name     text,
  grade_scale        text not null default 'letter',   -- 'letter' | 'gpa10'
  pass_percent       numeric(5,2) not null default 33,
  current_session_id uuid,
  gr_prefix          text default '',
  receipt_prefix     text default '',
  updated_at         timestamptz not null default now()
);
create trigger trg_school_settings_updated before update on public.school_settings
  for each row execute function public.set_updated_at();

create table public.academic_sessions (
  id         uuid primary key default gen_random_uuid(),
  name       text not null,                 -- e.g. "2025-2026"
  starts_on  date,
  ends_on    date,
  is_current boolean not null default false,
  is_closed  boolean not null default false,
  created_at timestamptz not null default now()
);

create table public.campuses (
  id         uuid primary key default gen_random_uuid(),
  name       text not null,
  address    text,
  is_default boolean not null default false,
  created_at timestamptz not null default now()
);

create table public.shifts (
  id         uuid primary key default gen_random_uuid(),
  name       text not null,                 -- e.g. "Morning", "Evening"
  sort_order integer not null default 0
);

-- ---------------------------------------------------------------------------
-- Academic structure: classes, sections, subjects
-- ---------------------------------------------------------------------------
create table public.classes (
  id          uuid primary key default gen_random_uuid(),
  name        text not null,                -- "Play Group", "Nursery", "Class 1"...
  level_order integer not null default 0,   -- orders the ladder; configurable
  campus_id   uuid references public.campuses(id),
  shift_id    uuid references public.shifts(id),
  active      boolean not null default true,
  created_at  timestamptz not null default now()
);

create table public.staff (
  id          uuid primary key default gen_random_uuid(),
  profile_id  uuid references public.profiles(id),
  full_name   text not null,
  designation text,
  employee_no text,
  mobile      text,
  whatsapp    text,
  cnic        text,
  joined_on   date,
  left_on     date,
  status      text not null default 'active',
  deleted_at  timestamptz,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create trigger trg_staff_updated before update on public.staff
  for each row execute function public.set_updated_at();

-- profiles.staff_id → staff (added now that staff exists)
alter table public.profiles
  add constraint profiles_staff_fk foreign key (staff_id) references public.staff(id);

create table public.sections (
  id               uuid primary key default gen_random_uuid(),
  class_id         uuid not null references public.classes(id),
  name             text not null,           -- "A", "B", "Red"...
  class_teacher_id uuid references public.staff(id),
  room             text,
  sort_order       integer not null default 0,
  created_at       timestamptz not null default now(),
  unique (class_id, name)
);

create table public.subjects (
  id           uuid primary key default gen_random_uuid(),
  name         text not null,
  class_id     uuid references public.classes(id),
  stream       text,                         -- Science/Arts/Pre-Med... (9-12)
  is_practical boolean not null default false,
  sort_order   integer not null default 0
);

-- ---------------------------------------------------------------------------
-- Students, guardians, enrollments (identity vs year-state)
-- ---------------------------------------------------------------------------
create table public.students (
  id            uuid primary key default gen_random_uuid(),
  gr_no         text unique,                 -- lifelong General Register number
  admission_no  text,
  full_name     text not null,
  father_name   text,
  mother_name   text,
  b_form        text,                        -- child B-Form (not CNIC)
  dob           date,
  gender        public.gender,
  address       text,
  phone         text,
  whatsapp      text,                        -- click-to-chat number
  photo_url     text,
  status        public.student_status not null default 'active',
  admission_date date,
  notes         text,
  deleted_at    timestamptz,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);
create trigger trg_students_updated before update on public.students
  for each row execute function public.set_updated_at();

create table public.guardians (
  id         uuid primary key default gen_random_uuid(),
  student_id uuid not null references public.students(id) on delete cascade,
  name       text not null,
  relation   text,
  phone      text,
  whatsapp   text,
  is_primary boolean not null default false,
  created_at timestamptz not null default now()
);

create table public.enrollments (
  id            uuid primary key default gen_random_uuid(),
  student_id    uuid not null references public.students(id),
  session_id    uuid not null references public.academic_sessions(id),
  class_id      uuid not null references public.classes(id),
  section_id    uuid references public.sections(id),
  roll_no       text,
  stream        text,
  bise_reg_no   text,
  status        public.enrollment_status not null default 'active',
  promoted_from uuid references public.enrollments(id),
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  unique (student_id, session_id)            -- one enrollment per student per year
);
create trigger trg_enrollments_updated before update on public.enrollments
  for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------------
-- Fees: heads, structures, per-student items, discounts
-- ---------------------------------------------------------------------------
create table public.fee_heads (
  id            uuid primary key default gen_random_uuid(),
  name          text not null,
  type          public.fee_head_type not null default 'misc',
  is_refundable boolean not null default false,   -- e.g. security deposit
  is_recurring  boolean not null default false,   -- monthly tuition
  sort_order    integer not null default 0,
  active        boolean not null default true
);

create table public.fee_structures (
  id           uuid primary key default gen_random_uuid(),
  session_id   uuid not null references public.academic_sessions(id),
  class_id     uuid not null references public.classes(id),
  fee_head_id  uuid not null references public.fee_heads(id),
  amount       numeric(12,2) not null default 0,
  unique (session_id, class_id, fee_head_id)
);

create table public.student_fee_items (
  id          uuid primary key default gen_random_uuid(),
  enrollment_id uuid not null references public.enrollments(id),
  fee_head_id uuid not null references public.fee_heads(id),
  amount      numeric(12,2) not null,
  active      boolean not null default true,
  created_at  timestamptz not null default now()
);

create table public.discounts (
  id            uuid primary key default gen_random_uuid(),
  enrollment_id uuid not null references public.enrollments(id),
  type          public.discount_type not null,
  amount        numeric(12,2) not null,
  is_percent    boolean not null default false,
  reason        text,
  status        public.discount_status not null default 'pending',
  approved_by   uuid references public.profiles(id),
  approved_at   timestamptz,
  created_by    uuid references public.profiles(id),
  created_at    timestamptz not null default now()
);

-- ---------------------------------------------------------------------------
-- Invoices, lines, payments, allocations, adjustments (append-only money)
-- ---------------------------------------------------------------------------
create table public.invoices (
  id                     uuid primary key default gen_random_uuid(),
  student_id             uuid not null references public.students(id),
  enrollment_id          uuid references public.enrollments(id),
  session_id             uuid not null references public.academic_sessions(id),
  period_month           date,                         -- first day of the month
  status                 public.invoice_status not null default 'draft',
  arrears_brought_forward numeric(12,2) not null default 0,
  fine                   numeric(12,2) not null default 0,
  due_date               date,
  notes                  text,
  issued_at              timestamptz,
  created_by             uuid references public.profiles(id),
  created_at             timestamptz not null default now(),
  updated_at             timestamptz not null default now()
);
create trigger trg_invoices_updated before update on public.invoices
  for each row execute function public.set_updated_at();

create table public.invoice_lines (
  id          uuid primary key default gen_random_uuid(),
  invoice_id  uuid not null references public.invoices(id) on delete cascade,
  fee_head_id uuid references public.fee_heads(id),
  description text not null,                            -- snapshot of head name
  amount      numeric(12,2) not null,
  is_discount boolean not null default false
);

create table public.payments (
  id          uuid primary key default gen_random_uuid(),
  student_id  uuid not null references public.students(id),
  amount      numeric(12,2) not null,
  method      public.payment_method not null default 'cash',
  receipt_no  bigint,                                  -- gapless via next_counter
  status      text not null default 'verified',        -- 'pending' for unreconciled bank/wallet
  received_by uuid references public.profiles(id),
  reversal_of uuid references public.payments(id),      -- reversing entry, never edit/delete
  note        text,
  created_at  timestamptz not null default now()
);

create table public.payment_allocations (
  id         uuid primary key default gen_random_uuid(),
  payment_id uuid not null references public.payments(id) on delete cascade,
  invoice_id uuid not null references public.invoices(id),
  amount     numeric(12,2) not null
);

create table public.adjustments (
  id          uuid primary key default gen_random_uuid(),
  invoice_id  uuid not null references public.invoices(id),
  amount      numeric(12,2) not null,
  reason      text not null,
  approved_by uuid references public.profiles(id),
  created_by  uuid references public.profiles(id),
  created_at  timestamptz not null default now()
);

-- ---------------------------------------------------------------------------
-- Attendance (one immutable row per student per day; lock-after-finalize)
-- ---------------------------------------------------------------------------
create table public.attendance_daily (
  id               uuid primary key default gen_random_uuid(),
  enrollment_id    uuid not null references public.enrollments(id),
  attendance_date  date not null,
  status           public.attendance_status not null,
  marked_by        uuid references public.profiles(id),
  is_locked        boolean not null default false,
  corrected_from   public.attendance_status,
  correction_reason text,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  unique (enrollment_id, attendance_date)
);
create trigger trg_attendance_updated before update on public.attendance_daily
  for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------------
-- Assessments (tests), exams, marks, result cards
-- ---------------------------------------------------------------------------
create table public.assessments (
  id              uuid primary key default gen_random_uuid(),
  session_id      uuid not null references public.academic_sessions(id),
  class_id        uuid not null references public.classes(id),
  section_id      uuid references public.sections(id),
  subject_id      uuid references public.subjects(id),
  title           text not null,
  assessment_date date,
  max_marks       numeric(6,2) not null default 0,
  weightage       numeric(6,2) not null default 0,
  is_locked       boolean not null default false,
  created_by      uuid references public.profiles(id),
  created_at      timestamptz not null default now()
);

create table public.exam_terms (
  id                             uuid primary key default gen_random_uuid(),
  session_id                     uuid not null references public.academic_sessions(id),
  name                           text not null,
  term_type                      public.term_type not null default 'other',
  starts_on                      date,
  ends_on                        date,
  result_withheld_for_defaulters boolean not null default true,
  is_locked                      boolean not null default false,
  created_at                     timestamptz not null default now()
);

create table public.exam_subjects (
  id            uuid primary key default gen_random_uuid(),
  exam_term_id  uuid not null references public.exam_terms(id) on delete cascade,
  class_id      uuid not null references public.classes(id),
  subject_id    uuid not null references public.subjects(id),
  max_marks     numeric(6,2) not null default 100,
  pass_marks    numeric(6,2) not null default 33,
  practical_max numeric(6,2) not null default 0,
  exam_date     date,
  unique (exam_term_id, class_id, subject_id)
);

-- One mark row for a test OR an exam subject (exactly one parent set).
create table public.mark_entries (
  id                uuid primary key default gen_random_uuid(),
  assessment_id     uuid references public.assessments(id) on delete cascade,
  exam_subject_id   uuid references public.exam_subjects(id) on delete cascade,
  enrollment_id     uuid not null references public.enrollments(id),
  marks             numeric(6,2),
  max_marks         numeric(6,2) not null,               -- snapshot at entry
  is_absent         boolean not null default false,
  is_locked         boolean not null default false,
  corrected_from    numeric(6,2),
  correction_reason text,
  marked_by         uuid references public.profiles(id),
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  constraint mark_one_parent check ((assessment_id is not null) <> (exam_subject_id is not null))
);
create unique index uq_mark_assessment on public.mark_entries (assessment_id, enrollment_id)
  where assessment_id is not null;
create unique index uq_mark_exam on public.mark_entries (exam_subject_id, enrollment_id)
  where exam_subject_id is not null;
create trigger trg_marks_updated before update on public.mark_entries
  for each row execute function public.set_updated_at();

create table public.result_cards (
  id             uuid primary key default gen_random_uuid(),
  student_id     uuid not null references public.students(id),
  enrollment_id  uuid not null references public.enrollments(id),
  exam_term_id   uuid not null references public.exam_terms(id),
  total_marks    numeric(8,2),
  total_max      numeric(8,2),
  percentage     numeric(5,2),
  grade          text,
  position       integer,
  attendance_pct numeric(5,2),
  version        integer not null default 1,
  frozen         jsonb,                                  -- byte-identical reprint
  generated_by   uuid references public.profiles(id),
  generated_at   timestamptz not null default now(),
  unique (enrollment_id, exam_term_id, version)
);

-- ---------------------------------------------------------------------------
-- Certificates (serial-tracked to prevent duplication/fraud)
-- ---------------------------------------------------------------------------
create table public.certificates (
  id         uuid primary key default gen_random_uuid(),
  cert_type  public.certificate_type not null,
  student_id uuid references public.students(id),
  serial_no  bigint not null,
  issued_on  date not null default current_date,
  issued_by  uuid references public.profiles(id),
  data       jsonb,
  created_at timestamptz not null default now(),
  unique (cert_type, serial_no)
);

-- ---------------------------------------------------------------------------
-- Audit log (append-only; written by SECURITY DEFINER trigger)
-- ---------------------------------------------------------------------------
create table public.audit_log (
  id         bigint generated always as identity primary key,
  actor      uuid,
  actor_role public.user_role,
  action     text not null,        -- INSERT / UPDATE / DELETE
  entity     text not null,        -- table name
  entity_id  text,
  before     jsonb,
  after      jsonb,
  reason     text,
  created_at timestamptz not null default now()
);

create or replace function public.audit_trigger() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  v_actor uuid := auth.uid();
  v_role  public.user_role;
  v_id    text;
begin
  select role into v_role from public.profiles where id = v_actor;
  v_id := coalesce((to_jsonb(new) ->> 'id'), (to_jsonb(old) ->> 'id'));
  insert into public.audit_log(actor, actor_role, action, entity, entity_id, before, after)
  values (
    v_actor, v_role, tg_op, tg_table_name, v_id,
    case when tg_op in ('UPDATE', 'DELETE') then to_jsonb(old) end,
    case when tg_op in ('INSERT', 'UPDATE') then to_jsonb(new) end
  );
  return coalesce(new, old);
end;
$$;

create trigger trg_audit_payments  after insert or update or delete on public.payments
  for each row execute function public.audit_trigger();
create trigger trg_audit_discounts after insert or update or delete on public.discounts
  for each row execute function public.audit_trigger();
create trigger trg_audit_adjust    after insert or update or delete on public.adjustments
  for each row execute function public.audit_trigger();
create trigger trg_audit_marks     after insert or update or delete on public.mark_entries
  for each row execute function public.audit_trigger();
create trigger trg_audit_attend    after insert or update or delete on public.attendance_daily
  for each row execute function public.audit_trigger();
create trigger trg_audit_certs     after insert or update or delete on public.certificates
  for each row execute function public.audit_trigger();

-- ---------------------------------------------------------------------------
-- Helpful indexes
-- ---------------------------------------------------------------------------
create index idx_enrollments_session on public.enrollments (session_id);
create index idx_enrollments_student on public.enrollments (student_id);
create index idx_enrollments_section on public.enrollments (section_id);
create index idx_attendance_date     on public.attendance_daily (attendance_date);
create index idx_attendance_enroll   on public.attendance_daily (enrollment_id);
create index idx_invoices_student    on public.invoices (student_id);
create index idx_invoices_period     on public.invoices (period_month);
create index idx_payments_student    on public.payments (student_id);
create index idx_marks_enroll        on public.mark_entries (enrollment_id);
create index idx_students_name       on public.students (full_name);

-- ===========================================================================
-- Row Level Security
-- ===========================================================================
alter table public.profiles           enable row level security;
alter table public.school_settings     enable row level security;
alter table public.academic_sessions   enable row level security;
alter table public.campuses            enable row level security;
alter table public.shifts              enable row level security;
alter table public.classes             enable row level security;
alter table public.sections            enable row level security;
alter table public.subjects            enable row level security;
alter table public.staff               enable row level security;
alter table public.students            enable row level security;
alter table public.guardians           enable row level security;
alter table public.enrollments         enable row level security;
alter table public.fee_heads           enable row level security;
alter table public.fee_structures      enable row level security;
alter table public.student_fee_items   enable row level security;
alter table public.discounts           enable row level security;
alter table public.invoices            enable row level security;
alter table public.invoice_lines       enable row level security;
alter table public.payments            enable row level security;
alter table public.payment_allocations enable row level security;
alter table public.adjustments         enable row level security;
alter table public.attendance_daily    enable row level security;
alter table public.assessments         enable row level security;
alter table public.exam_terms          enable row level security;
alter table public.exam_subjects       enable row level security;
alter table public.mark_entries        enable row level security;
alter table public.result_cards        enable row level security;
alter table public.certificates        enable row level security;
alter table public.counters            enable row level security;
alter table public.audit_log           enable row level security;

-- Profiles: staff directory readable; self or owner/principal may edit.
create policy profiles_select on public.profiles for select to authenticated using (true);
create policy profiles_insert on public.profiles for insert to authenticated
  with check (public.has_role('owner', 'principal'));
create policy profiles_update on public.profiles for update to authenticated
  using (id = auth.uid() or public.has_role('owner', 'principal'))
  with check (id = auth.uid() or public.has_role('owner', 'principal'));
create policy profiles_delete on public.profiles for delete to authenticated
  using (public.has_role('owner', 'principal'));

-- School settings (singleton): read all; edit owner/principal.
create policy settings_select on public.school_settings for select to authenticated using (true);
create policy settings_write  on public.school_settings for all to authenticated
  using (public.has_role('owner', 'principal'))
  with check (public.has_role('owner', 'principal'));

-- Reference/config tables: read all; write owner/principal/admin_clerk.
do $$
declare t text;
begin
  foreach t in array array[
    'academic_sessions', 'campuses', 'shifts', 'classes', 'sections', 'subjects',
    'fee_heads', 'fee_structures'
  ] loop
    execute format('create policy %1$s_select on public.%1$s for select to authenticated using (true);', t);
    execute format($f$create policy %1$s_write on public.%1$s for all to authenticated
      using (public.has_role('owner','principal','admin_clerk'))
      with check (public.has_role('owner','principal','admin_clerk'));$f$, t);
  end loop;
end $$;

-- Staff & students & enrollments: read all staff; write owner/principal/admin_clerk.
do $$
declare t text;
begin
  foreach t in array array['staff', 'students', 'guardians', 'enrollments'] loop
    execute format('create policy %1$s_select on public.%1$s for select to authenticated using (true);', t);
    execute format($f$create policy %1$s_write on public.%1$s for all to authenticated
      using (public.has_role('owner','principal','admin_clerk'))
      with check (public.has_role('owner','principal','admin_clerk'));$f$, t);
  end loop;
end $$;

-- Finance tables: only finance roles may read or write.
do $$
declare t text;
begin
  foreach t in array array[
    'student_fee_items', 'discounts', 'invoices', 'invoice_lines',
    'payment_allocations', 'adjustments'
  ] loop
    execute format($f$create policy %1$s_select on public.%1$s for select to authenticated
      using (public.has_role('owner','principal','admin_clerk','accountant'));$f$, t);
    execute format($f$create policy %1$s_write on public.%1$s for all to authenticated
      using (public.has_role('owner','principal','admin_clerk','accountant'))
      with check (public.has_role('owner','principal','admin_clerk','accountant'));$f$, t);
  end loop;
end $$;

-- Payments: append-only. Finance roles read + insert; NO update/delete policy.
create policy payments_select on public.payments for select to authenticated
  using (public.has_role('owner', 'principal', 'admin_clerk', 'accountant'));
create policy payments_insert on public.payments for insert to authenticated
  with check (public.has_role('owner', 'principal', 'admin_clerk', 'accountant'));

-- Attendance: everyone signed-in reads; teachers/admin write UNLOCKED rows only.
create policy attendance_select on public.attendance_daily for select to authenticated using (true);
create policy attendance_insert on public.attendance_daily for insert to authenticated
  with check (public.has_role('owner', 'principal', 'admin_clerk', 'class_teacher', 'subject_teacher'));
create policy attendance_update on public.attendance_daily for update to authenticated
  using (not is_locked and public.has_role('owner', 'principal', 'admin_clerk', 'class_teacher', 'subject_teacher'))
  with check (public.has_role('owner', 'principal', 'admin_clerk', 'class_teacher', 'subject_teacher'));

-- Assessments & marks: read all; teachers/admin write UNLOCKED.
create policy assessments_select on public.assessments for select to authenticated using (true);
create policy assessments_write on public.assessments for all to authenticated
  using (public.has_role('owner', 'principal', 'admin_clerk', 'class_teacher', 'subject_teacher'))
  with check (public.has_role('owner', 'principal', 'admin_clerk', 'class_teacher', 'subject_teacher'));

create policy marks_select on public.mark_entries for select to authenticated using (true);
create policy marks_insert on public.mark_entries for insert to authenticated
  with check (public.has_role('owner', 'principal', 'admin_clerk', 'class_teacher', 'subject_teacher'));
create policy marks_update on public.mark_entries for update to authenticated
  using (not is_locked and public.has_role('owner', 'principal', 'admin_clerk', 'class_teacher', 'subject_teacher'))
  with check (public.has_role('owner', 'principal', 'admin_clerk', 'class_teacher', 'subject_teacher'));

-- Exam setup & result cards: read all; write owner/principal/admin_clerk.
do $$
declare t text;
begin
  foreach t in array array['exam_terms', 'exam_subjects', 'result_cards'] loop
    execute format('create policy %1$s_select on public.%1$s for select to authenticated using (true);', t);
    execute format($f$create policy %1$s_write on public.%1$s for all to authenticated
      using (public.has_role('owner','principal','admin_clerk'))
      with check (public.has_role('owner','principal','admin_clerk'));$f$, t);
  end loop;
end $$;

-- Certificates: read + insert by owner/principal/admin_clerk (append-only serial).
create policy certificates_select on public.certificates for select to authenticated
  using (public.has_role('owner', 'principal', 'admin_clerk'));
create policy certificates_insert on public.certificates for insert to authenticated
  with check (public.has_role('owner', 'principal', 'admin_clerk'));

-- Audit log: owner/principal read-only. Inserts happen via SECURITY DEFINER trigger.
create policy audit_select on public.audit_log for select to authenticated
  using (public.has_role('owner', 'principal'));

-- counters: no user policies → all direct access denied; next_counter() bypasses.

-- ===========================================================================
-- Grants (table privileges; RLS still governs which rows)
-- ===========================================================================
grant usage on schema public to anon, authenticated;
grant select, insert, update, delete on all tables in schema public to authenticated;
grant usage, select on all sequences in schema public to authenticated;
grant execute on function public.next_counter(text) to authenticated;
grant execute on function public.has_role(public.user_role[]) to authenticated;
grant execute on function public.auth_role() to authenticated;

-- ─────────────────────────────────────────────────────────────────────────
-- 0002_fees.sql
-- ─────────────────────────────────────────────────────────────────────────
-- =============================================================================
-- Fees module — money logic as Postgres functions (transactional, server-side).
--
-- Balance model = running ledger (see docs/02-DATA-MODEL.md):
--   * An invoice holds a billing period's NEW charges (lines + fine).
--   * A student's balance is DERIVED, never stored:
--       balance = SUM(non-void invoice charges) − SUM(verified payments)
--     where a reversal is a negative-amount payment, so the cash ledger foots.
--   * `arrears_brought_forward` on an invoice is a DISPLAY snapshot of the
--     balance just before that invoice — it is NOT summed into the balance
--     (that would double-count).
-- All mutating functions are SECURITY DEFINER with an explicit role guard.
-- =============================================================================

-- Per-invoice charge/allocated view (security_invoker → caller's RLS applies).
create view public.invoice_balances with (security_invoker = true) as
select
  i.id            as invoice_id,
  i.student_id,
  i.enrollment_id,
  i.session_id,
  i.period_month,
  i.status,
  i.due_date,
  i.arrears_brought_forward,
  i.fine,
  coalesce((
    select sum(case when l.is_discount then -l.amount else l.amount end)
    from public.invoice_lines l where l.invoice_id = i.id
  ), 0) + i.fine as charge,
  coalesce((
    select sum(a.amount) from public.payment_allocations a where a.invoice_id = i.id
  ), 0) as allocated
from public.invoices i
where i.status <> 'void';

-- Derived student balance (SECURITY INVOKER → RLS on underlying tables applies).
create or replace function public.student_balance(p_student_id uuid)
returns numeric language sql stable security invoker set search_path = public as $$
  select
    coalesce((
      select sum(case when l.is_discount then -l.amount else l.amount end)
      from public.invoice_lines l
      join public.invoices i on i.id = l.invoice_id
      where i.student_id = p_student_id and i.status <> 'void'
    ), 0)
    + coalesce((
      select sum(i.fine) from public.invoices i
      where i.student_id = p_student_id and i.status <> 'void'
    ), 0)
    - coalesce((
      select sum(p.amount) from public.payments p
      where p.student_id = p_student_id and p.status = 'verified'
    ), 0);
$$;

-- Generate monthly challans for a class: recurring heads + approved discounts,
-- with the current balance snapshotted as arrears_brought_forward. Idempotent
-- per (enrollment, period_month) — re-running does not duplicate.
create or replace function public.fn_generate_class_invoices(
  p_session_id uuid, p_class_id uuid, p_period_month date, p_due_date date
) returns integer language plpgsql security definer set search_path = public as $$
declare
  v_actor uuid := auth.uid();
  v_enr   record;
  v_drec  record;
  v_inv   uuid;
  v_count integer := 0;
  v_arrears numeric;
  v_tuition numeric;
begin
  if not public.has_role('owner', 'principal', 'admin_clerk', 'accountant') then
    raise exception 'Not permitted to generate invoices';
  end if;

  for v_enr in
    select e.id as enrollment_id, e.student_id
    from public.enrollments e
    where e.session_id = p_session_id and e.class_id = p_class_id and e.status = 'active'
      and not exists (
        select 1 from public.invoices i
        where i.enrollment_id = e.id and i.period_month = p_period_month and i.status <> 'void'
      )
  loop
    v_arrears := public.student_balance(v_enr.student_id);

    insert into public.invoices(
      student_id, enrollment_id, session_id, period_month, status,
      arrears_brought_forward, due_date, issued_at, created_by)
    values (
      v_enr.student_id, v_enr.enrollment_id, p_session_id, p_period_month, 'issued',
      v_arrears, p_due_date, now(), v_actor)
    returning id into v_inv;

    -- recurring fee-head lines (per-student override wins over class structure)
    insert into public.invoice_lines(invoice_id, fee_head_id, description, amount, is_discount)
    select v_inv, fh.id, fh.name, coalesce(sfi.amount, fs.amount), false
    from public.fee_structures fs
    join public.fee_heads fh on fh.id = fs.fee_head_id
    left join public.student_fee_items sfi
      on sfi.enrollment_id = v_enr.enrollment_id and sfi.fee_head_id = fh.id and sfi.active
    where fs.session_id = p_session_id and fs.class_id = p_class_id
      and fh.is_recurring and fh.active;

    select coalesce(sum(amount), 0) into v_tuition
    from public.invoice_lines where invoice_id = v_inv and not is_discount;

    -- approved discounts as negative lines
    for v_drec in
      select * from public.discounts d
      where d.enrollment_id = v_enr.enrollment_id and d.status = 'approved'
    loop
      insert into public.invoice_lines(invoice_id, fee_head_id, description, amount, is_discount)
      values (
        v_inv, null, 'Discount: ' || v_drec.type,
        case when v_drec.is_percent then round(v_tuition * v_drec.amount / 100.0, 2) else v_drec.amount end,
        true);
    end loop;

    v_count := v_count + 1;
  end loop;

  return v_count;
end;
$$;

-- Record a payment: gapless receipt number, then FIFO-allocate to oldest
-- unpaid invoices and update their status. Leftover is left as credit.
create or replace function public.fn_record_payment(
  p_student_id uuid, p_amount numeric, p_method public.payment_method, p_note text default null
) returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_actor    uuid := auth.uid();
  v_receipt  bigint;
  v_pay      uuid;
  v_remaining numeric := p_amount;
  v_alloc    numeric;
  v_rec      record;
begin
  if not public.has_role('owner', 'principal', 'admin_clerk', 'accountant') then
    raise exception 'Not permitted to record payments';
  end if;
  if p_amount is null or p_amount <= 0 then
    raise exception 'Amount must be positive';
  end if;

  v_receipt := public.next_counter('receipt');
  insert into public.payments(student_id, amount, method, receipt_no, status, received_by, note)
  values (p_student_id, p_amount, p_method, v_receipt, 'verified', v_actor, p_note)
  returning id into v_pay;

  for v_rec in
    select invoice_id, (charge - allocated) as outstanding
    from public.invoice_balances
    where student_id = p_student_id and status in ('issued', 'partial') and (charge - allocated) > 0
    order by period_month nulls first, invoice_id
  loop
    exit when v_remaining <= 0;
    v_alloc := least(v_remaining, v_rec.outstanding);
    insert into public.payment_allocations(payment_id, invoice_id, amount)
    values (v_pay, v_rec.invoice_id, v_alloc);
    v_remaining := v_remaining - v_alloc;

    update public.invoices i set status = (case
      when (select allocated from public.invoice_balances b where b.invoice_id = i.id)
           >= (select charge from public.invoice_balances b where b.invoice_id = i.id)
      then 'paid' else 'partial' end)::public.invoice_status
    where i.id = v_rec.invoice_id;
  end loop;

  return jsonb_build_object(
    'payment_id', v_pay, 'receipt_no', v_receipt,
    'allocated', p_amount - v_remaining, 'unallocated', v_remaining);
end;
$$;

-- Reverse a payment by a linked negative entry (never edit/delete the original).
create or replace function public.fn_reverse_payment(p_payment_id uuid, p_reason text)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  v_actor uuid := auth.uid();
  v_orig  record;
  v_a     record;
  v_rev   uuid;
  v_receipt bigint;
begin
  if not public.has_role('owner', 'principal') then
    raise exception 'Only owner/principal may reverse a payment';
  end if;
  select * into v_orig from public.payments where id = p_payment_id;
  if not found then raise exception 'Payment not found'; end if;
  if v_orig.reversal_of is not null then raise exception 'Cannot reverse a reversal'; end if;
  if exists (select 1 from public.payments where reversal_of = p_payment_id) then
    raise exception 'Payment already reversed';
  end if;

  v_receipt := public.next_counter('receipt');
  insert into public.payments(student_id, amount, method, receipt_no, status, received_by, reversal_of, note)
  values (v_orig.student_id, -v_orig.amount, v_orig.method, v_receipt, 'verified', v_actor, p_payment_id,
          coalesce(p_reason, 'reversal'))
  returning id into v_rev;

  for v_a in select * from public.payment_allocations where payment_id = p_payment_id loop
    insert into public.payment_allocations(payment_id, invoice_id, amount)
    values (v_rev, v_a.invoice_id, -v_a.amount);
    update public.invoices i set status = (case
      when (select allocated from public.invoice_balances b where b.invoice_id = i.id) <= 0 then 'issued'
      when (select allocated from public.invoice_balances b where b.invoice_id = i.id)
           >= (select charge from public.invoice_balances b where b.invoice_id = i.id) then 'paid'
      else 'partial' end)::public.invoice_status
    where i.id = v_a.invoice_id;
  end loop;

  return v_rev;
end;
$$;

-- Defaulters for a session: active students with a positive balance, biggest first.
create or replace function public.fn_defaulters(p_session_id uuid)
returns table(
  student_id uuid, gr_no text, full_name text,
  class_name text, section_name text, roll_no text, balance numeric)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.has_role('owner', 'principal', 'admin_clerk', 'accountant') then
    raise exception 'Not permitted';
  end if;
  perform public.assert_own('academic_sessions', p_session_id);
  return query
    select s.id, s.gr_no, s.full_name, c.name, sec.name, e.roll_no, public.student_balance(s.id)
    from public.enrollments e
    join public.students s on s.id = e.student_id
    join public.classes c on c.id = e.class_id
    left join public.sections sec on sec.id = e.section_id
    where e.session_id = p_session_id and e.status = 'active' and public.student_balance(s.id) > 0
    order by public.student_balance(s.id) desc;
end;
$$;

grant select on public.invoice_balances to authenticated;
grant execute on function public.student_balance(uuid) to authenticated;
grant execute on function public.fn_generate_class_invoices(uuid, uuid, date, date) to authenticated;
grant execute on function public.fn_record_payment(uuid, numeric, public.payment_method, text) to authenticated;
grant execute on function public.fn_reverse_payment(uuid, text) to authenticated;
grant execute on function public.fn_defaulters(uuid) to authenticated;

-- ─────────────────────────────────────────────────────────────────────────
-- 0003_attendance.sql
-- ─────────────────────────────────────────────────────────────────────────
-- =============================================================================
-- Attendance module — daily marking, finalize/lock, and per-student summary,
-- as server-side Postgres functions (SECURITY DEFINER + explicit role guards).
--
-- Model (see docs/02-DATA-MODEL.md):
--   * attendance_daily holds ONE row per (enrollment, date) — unique constraint.
--   * Marking is idempotent: re-marking a date UPSERTs the same row.
--   * Finalizing LOCKS the day's rows (is_locked=true); a locked row is immutable
--     to normal users (RLS blocks the UPDATE) and these functions skip it too.
--   * A status change on an unlocked row snapshots the previous value into
--     corrected_from, for the audit trail.
--
-- Enum gotcha: text taken from jsonb (or a CASE) must be cast explicitly to
-- ::public.attendance_status — Postgres will not do it implicitly.
--
-- All four functions are SECURITY DEFINER (they must read across sections and,
-- for finalize, set is_locked which RLS forbids to normal users), so each one
-- carries its own role guard.
-- =============================================================================

-- Roster for one section on one date: every active enrollment with that day's
-- status (null = unmarked) and whether the day is already locked. Passing a null
-- p_section_id matches enrollments that have no section (small/ungrouped classes).
create or replace function public.fn_section_roster(
  p_session_id uuid, p_class_id uuid, p_section_id uuid, p_date date
) returns table(
  enrollment_id uuid, student_id uuid, full_name text, father_name text,
  roll_no text, status public.attendance_status, is_locked boolean
) language plpgsql stable security definer set search_path = public as $$
begin
  if not public.has_role('owner','principal','admin_clerk','class_teacher','subject_teacher') then
    raise exception 'Not permitted to view the attendance roster';
  end if;
  return query
    select e.id, s.id, s.full_name, s.father_name, e.roll_no,
           ad.status, coalesce(ad.is_locked, false)
    from public.enrollments e
    join public.students s on s.id = e.student_id
    left join public.attendance_daily ad
      on ad.enrollment_id = e.id and ad.attendance_date = p_date
    where e.session_id = p_session_id
      and e.class_id = p_class_id
      and e.section_id is not distinct from p_section_id
      and e.status = 'active'
      and s.deleted_at is null
    -- sort by the numeric part of the roll number (so 10 follows 9), then name
    order by coalesce(nullif(regexp_replace(coalesce(e.roll_no, ''), '[^0-9]', '', 'g'), '')::int, 2147483647),
             s.full_name;
end;
$$;

-- Mark (or re-mark) attendance for a set of enrollments on one date. Idempotent
-- per (enrollment, date); LOCKED rows are skipped, never touched. Returns a
-- {marked, skipped, total} tally. p_marks is a jsonb array of objects shaped
-- { "enrollment_id": <uuid>, "status": <attendance_status> }.
create or replace function public.fn_mark_attendance(p_date date, p_marks jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_actor  uuid := auth.uid();
  v_total  integer;
  v_marked integer;
begin
  if not public.has_role('owner','principal','admin_clerk','class_teacher','subject_teacher') then
    raise exception 'Not permitted to mark attendance';
  end if;
  if p_marks is null or jsonb_typeof(p_marks) <> 'array' then
    raise exception 'p_marks must be a JSON array';
  end if;

  select count(distinct (e->>'enrollment_id')) into v_total
  from jsonb_array_elements(p_marks) e;

  with input as (
    -- de-dup defensively: one status per enrollment, even if the client repeats
    select distinct on (enrollment_id) enrollment_id, status
    from (
      select (e->>'enrollment_id')::uuid as enrollment_id,
             (e->>'status')::public.attendance_status as status
      from jsonb_array_elements(p_marks) e
    ) q
    order by enrollment_id
  ),
  upserted as (
    insert into public.attendance_daily as ad (enrollment_id, attendance_date, status, marked_by)
    select enrollment_id, p_date, status, v_actor from input
    on conflict (enrollment_id, attendance_date) do update
      set status = excluded.status,
          marked_by = excluded.marked_by,
          corrected_from = case when ad.status is distinct from excluded.status
                                then ad.status else ad.corrected_from end
      where not ad.is_locked          -- a locked day is immutable → skip it
    returning 1
  )
  select count(*) into v_marked from upserted;

  return jsonb_build_object('marked', v_marked, 'skipped', v_total - v_marked, 'total', v_total);
end;
$$;

-- Finalize a section's day: lock every attendance row so it can no longer be
-- edited. Returns the number of rows locked. Re-finalizing is harmless.
create or replace function public.fn_finalize_attendance(
  p_session_id uuid, p_class_id uuid, p_section_id uuid, p_date date
) returns integer language plpgsql security definer set search_path = public as $$
declare v_count integer;
begin
  if not public.has_role('owner','principal','admin_clerk','class_teacher','subject_teacher') then
    raise exception 'Not permitted to finalize attendance';
  end if;
  update public.attendance_daily ad
    set is_locked = true
    from public.enrollments e
    where ad.enrollment_id = e.id
      and ad.attendance_date = p_date
      and e.session_id = p_session_id
      and e.class_id = p_class_id
      and e.section_id is not distinct from p_section_id;
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

-- Per-student attendance summary over a date window, for the profile page.
-- Working-day % = (present + late + ½·half_day) / marked days. Holidays are
-- simply dates with no row, so the % is over MARKED days only (simple for v1).
create or replace function public.fn_attendance_summary(
  p_enrollment_id uuid, p_from date, p_to date
) returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v jsonb;
begin
  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;
  perform public.assert_own('enrollments', p_enrollment_id);
  select jsonb_build_object(
    'present',     count(*) filter (where status = 'present'),
    'absent',      count(*) filter (where status = 'absent'),
    'leave',       count(*) filter (where status = 'leave'),
    'late',        count(*) filter (where status = 'late'),
    'half_day',    count(*) filter (where status = 'half_day'),
    'marked_days', count(*),
    'present_pct', case when count(*) = 0 then null else
        round(100.0 * (
          count(*) filter (where status in ('present','late'))
          + 0.5 * count(*) filter (where status = 'half_day')
        ) / count(*), 1) end
  ) into v
  from public.attendance_daily
  where enrollment_id = p_enrollment_id
    and attendance_date between p_from and p_to;
  return v;
end;
$$;

grant execute on function public.fn_section_roster(uuid, uuid, uuid, date) to authenticated;
grant execute on function public.fn_mark_attendance(date, jsonb) to authenticated;
grant execute on function public.fn_finalize_attendance(uuid, uuid, uuid, date) to authenticated;
grant execute on function public.fn_attendance_summary(uuid, date, date) to authenticated;

-- ─────────────────────────────────────────────────────────────────────────
-- 0004_admissions.sql
-- ─────────────────────────────────────────────────────────────────────────
-- =============================================================================
-- Admissions module — admit a student and change a student's status, as
-- transactional Postgres functions (SECURITY DEFINER + explicit role guards).
--
-- Identity vs. year-state (see docs/02-DATA-MODEL.md):
--   * A Student is a lifelong identity carrying a gapless GR number.
--   * An Enrollment is that student's state for ONE session (class/section/roll).
--   * fn_admit_student creates both (and an optional guardian) in one txn, so a
--     new admission is immediately visible in the attendance roster and billable
--     in fees.
--
-- Enum gotcha: text from jsonb / a CASE must be cast to its enum type
--   (::public.gender, ::public.student_status, ::public.enrollment_status).
-- Bio-data EDITS and profile READS are done client-side under RLS
-- (students_write = owner/principal/admin_clerk; *_select = all authenticated),
-- so only the multi-table operations live here.
-- =============================================================================

-- Admit a new student: assign a GR number, create the student + this session's
-- enrollment (auto roll number if none given), and an optional primary guardian.
-- p is a jsonb object; recognised keys:
--   full_name (required), father_name, mother_name, b_form, dob, gender,
--   address, phone, whatsapp, admission_no, admission_date, notes,
--   session_id (required), class_id (required), section_id, roll_no,
--   gr_no (caller-supplied overrides the counter),
--   guardian: { name, relation, phone, whatsapp }
create or replace function public.fn_admit_student(p jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_prefix  text;
  v_counter bigint;
  v_gr      text;
  v_student uuid;
  v_enroll  uuid;
  v_session uuid := nullif(p->>'session_id','')::uuid;
  v_class   uuid := nullif(p->>'class_id','')::uuid;
  v_section uuid := nullif(p->>'section_id','')::uuid;
  v_roll    text := nullif(p->>'roll_no','');
  v_gr_in   text := nullif(p->>'gr_no','');
  v_next    int;
  v_g       jsonb := p->'guardian';
begin
  if not public.has_role('owner','principal','admin_clerk') then
    raise exception 'Not permitted to admit students';
  end if;
  if nullif(p->>'full_name','') is null then raise exception 'Student name is required'; end if;
  if v_session is null then raise exception 'Academic session is required'; end if;
  if v_class   is null then raise exception 'Class is required'; end if;

  -- GR number: a caller-supplied value wins; otherwise the gapless counter,
  -- prefixed with school_settings.gr_prefix and zero-padded.
  if v_gr_in is not null then
    v_gr := v_gr_in;
  else
    select gr_prefix into v_prefix from public.school_settings where school_id = public.current_school_id();
    v_counter := public.next_counter('gr');
    v_gr := coalesce(v_prefix, '') || lpad(v_counter::text, 4, '0');
  end if;

  insert into public.students(
    gr_no, admission_no, full_name, father_name, mother_name, b_form, dob, gender,
    address, phone, whatsapp, status, admission_date, notes)
  values (
    v_gr,
    nullif(p->>'admission_no',''),
    p->>'full_name',
    nullif(p->>'father_name',''),
    nullif(p->>'mother_name',''),
    nullif(p->>'b_form',''),
    nullif(p->>'dob','')::date,
    nullif(p->>'gender','')::public.gender,
    nullif(p->>'address',''),
    nullif(p->>'phone',''),
    nullif(p->>'whatsapp',''),
    'active',
    coalesce(nullif(p->>'admission_date','')::date, current_date),
    nullif(p->>'notes',''))
  returning id into v_student;

  -- auto roll number = next numeric roll within the same section/session
  if v_roll is null then
    select coalesce(max(nullif(regexp_replace(coalesce(roll_no,''), '[^0-9]', '', 'g'), '')::int), 0) + 1
    into v_next
    from public.enrollments
    where session_id = v_session and class_id = v_class and section_id is not distinct from v_section;
    v_roll := v_next::text;
  end if;

  insert into public.enrollments(student_id, session_id, class_id, section_id, roll_no, status)
  values (v_student, v_session, v_class, v_section, v_roll, 'active')
  returning id into v_enroll;

  -- optional primary guardian
  if v_g is not null and jsonb_typeof(v_g) = 'object' and nullif(v_g->>'name','') is not null then
    insert into public.guardians(student_id, name, relation, phone, whatsapp, is_primary)
    values (v_student, v_g->>'name', nullif(v_g->>'relation',''), nullif(v_g->>'phone',''),
            nullif(v_g->>'whatsapp',''), true);
  end if;

  return jsonb_build_object(
    'student_id', v_student, 'enrollment_id', v_enroll, 'gr_no', v_gr, 'roll_no', v_roll);
end;
$$;

-- Change a student's status (struck off / withdrawn / graduated / reinstated) and
-- reflect it on the current session's enrollment. Significant action → owner/
-- principal only (separation of duties). Never physically deletes.
create or replace function public.fn_set_student_status(
  p_student_id uuid, p_status public.student_status, p_reason text default null
) returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.has_role('owner','principal') then
    raise exception 'Only owner/principal may change a student''s status';
  end if;
  perform public.assert_own('students', p_student_id);

  update public.students
    set status = p_status,
        notes = case when nullif(p_reason,'') is null then notes
                     else coalesce(notes || E'\n', '') || 'Status → ' || p_status::text || ': ' || p_reason end
    where id = p_student_id;

  -- mirror onto the current-session enrollment (withdrawn maps to 'left')
  if p_status <> 'active' then
    update public.enrollments e
      set status = (case p_status
                      when 'struck_off' then 'struck_off'
                      when 'graduated'  then 'graduated'
                      when 'withdrawn'  then 'left'
                      else 'active' end)::public.enrollment_status
      from public.academic_sessions s
      where e.student_id = p_student_id and e.session_id = s.id and s.is_current;
  else
    update public.enrollments e
      set status = 'active'
      from public.academic_sessions s
      where e.student_id = p_student_id and e.session_id = s.id and s.is_current
        and e.status in ('struck_off', 'left');
  end if;
end;
$$;

grant execute on function public.fn_admit_student(jsonb) to authenticated;
grant execute on function public.fn_set_student_status(uuid, public.student_status, text) to authenticated;

-- ─────────────────────────────────────────────────────────────────────────
-- 0005_exams.sql
-- ─────────────────────────────────────────────────────────────────────────
-- =============================================================================
-- Exams module — marks entry, grading, and result-card generation, as
-- server-side Postgres functions (SECURITY DEFINER + explicit role guards).
--
-- Shape (see docs/02-DATA-MODEL.md):
--   * exam_terms       — a term in a session (First Term, Mid, Final…).
--   * exam_subjects    — which subjects a class sits in that term + their
--                        max/pass marks (unique per term+class+subject).
--   * mark_entries     — one mark per (exam_subject, enrollment); lock-after-
--                        finalize, snapshots corrected_from on a change.
--   * result_cards     — the computed card (totals, %, grade, class position,
--                        attendance %), VERSIONED with a `frozen` jsonb snapshot
--                        so a reprint is byte-identical.
--
-- Exam setup (terms/subjects) and card READS are done client-side under RLS
-- (exam_* + result_cards: read all authenticated, write owner/principal/
-- admin_clerk). Marks + card generation are here because they cross rows.
-- Enum/number-from-text gotcha applies as elsewhere.
-- =============================================================================

-- Percentage → letter grade, honouring school_settings.pass_percent. (A gpa10
-- scale can refine this later; v1 is the common letter scale.)
create or replace function public.fn_grade_for(p_percent numeric)
returns text language plpgsql stable security definer set search_path = public as $$
declare v_pass numeric;
begin
  if p_percent is null then return null; end if;
  select coalesce(pass_percent, 33) into v_pass from public.school_settings where school_id = public.current_school_id();
  v_pass := coalesce(v_pass, 33);
  if p_percent < v_pass then return 'F'; end if;
  return case
    when p_percent >= 90 then 'A+'
    when p_percent >= 80 then 'A'
    when p_percent >= 70 then 'B'
    when p_percent >= 60 then 'C'
    when p_percent >= 50 then 'D'
    else 'E' end;
end;
$$;

-- The marksheet for one exam subject: every active enrollment in the class with
-- its mark (null = unmarked), absent flag, lock state, and the subject max.
create or replace function public.fn_exam_marksheet(p_exam_subject_id uuid)
returns table(
  enrollment_id uuid, student_id uuid, full_name text, roll_no text,
  section_name text, marks numeric, is_absent boolean, is_locked boolean, max_marks numeric
) language plpgsql stable security definer set search_path = public as $$
declare v_session uuid; v_class uuid; v_max numeric;
begin
  if not public.has_role('owner','principal','admin_clerk','class_teacher','subject_teacher') then
    raise exception 'Not permitted to view the marksheet';
  end if;
  perform public.assert_own('exam_subjects', p_exam_subject_id);
  select t.session_id, es.class_id, es.max_marks into v_session, v_class, v_max
  from public.exam_subjects es join public.exam_terms t on t.id = es.exam_term_id
  where es.id = p_exam_subject_id;
  if v_session is null then raise exception 'Exam subject not found'; end if;
  return query
    select e.id, s.id, s.full_name, e.roll_no, sec.name,
           me.marks, coalesce(me.is_absent, false), coalesce(me.is_locked, false), v_max
    from public.enrollments e
    join public.students s on s.id = e.student_id
    left join public.sections sec on sec.id = e.section_id
    left join public.mark_entries me on me.exam_subject_id = p_exam_subject_id and me.enrollment_id = e.id
    where e.session_id = v_session and e.class_id = v_class and e.status = 'active' and s.deleted_at is null
    order by sec.sort_order nulls first,
             coalesce(nullif(regexp_replace(coalesce(e.roll_no, ''), '[^0-9]', '', 'g'), '')::int, 2147483647),
             s.full_name;
end;
$$;

-- Enter/overwrite marks for one exam subject. Idempotent per (subject, student);
-- skips locked rows; snapshots corrected_from on a change. p_marks = jsonb array
-- of { enrollment_id, marks, is_absent }.
create or replace function public.fn_enter_marks(p_exam_subject_id uuid, p_marks jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_actor  uuid := auth.uid();
  v_max    numeric;
  v_total  integer;
  v_marked integer;
begin
  if not public.has_role('owner','principal','admin_clerk','class_teacher','subject_teacher') then
    raise exception 'Not permitted to enter marks';
  end if;
  perform public.assert_own('exam_subjects', p_exam_subject_id);
  if p_marks is null or jsonb_typeof(p_marks) <> 'array' then
    raise exception 'p_marks must be a JSON array';
  end if;
  select max_marks into v_max from public.exam_subjects where id = p_exam_subject_id;
  if v_max is null then raise exception 'Exam subject not found'; end if;

  if exists (
    select 1 from jsonb_array_elements(p_marks) e
    where coalesce((e->>'is_absent')::boolean, false) = false
      and nullif(e->>'marks', '') is not null
      and ((e->>'marks')::numeric < 0 or (e->>'marks')::numeric > v_max)
  ) then
    raise exception 'Marks must be between 0 and %', v_max;
  end if;

  select count(distinct (e->>'enrollment_id')) into v_total from jsonb_array_elements(p_marks) e;

  with input as (
    select distinct on (enrollment_id) enrollment_id, marks, is_absent
    from (
      select (e->>'enrollment_id')::uuid as enrollment_id,
             nullif(e->>'marks', '')::numeric as marks,
             coalesce((e->>'is_absent')::boolean, false) as is_absent
      from jsonb_array_elements(p_marks) e
    ) q
    order by enrollment_id
  ),
  upserted as (
    insert into public.mark_entries as me (exam_subject_id, enrollment_id, marks, max_marks, is_absent, marked_by)
    select p_exam_subject_id, enrollment_id, marks, v_max, is_absent, v_actor from input
    on conflict (exam_subject_id, enrollment_id) where exam_subject_id is not null
    do update set marks = excluded.marks, is_absent = excluded.is_absent, marked_by = excluded.marked_by,
                  corrected_from = case when me.marks is distinct from excluded.marks then me.marks else me.corrected_from end
    where not me.is_locked
    returning 1
  )
  select count(*) into v_marked from upserted;

  return jsonb_build_object('marked', v_marked, 'skipped', v_total - v_marked, 'total', v_total);
end;
$$;

-- Generate result cards for a class in a term: sum marks across the term's exam
-- subjects, compute %, grade, class position (rank), and attendance % over the
-- term window, then write a NEW version with a frozen jsonb snapshot (so any
-- reprint is byte-identical). Results are withheld for fee-defaulters when the
-- term says so. owner/principal/admin_clerk only.
create or replace function public.fn_generate_result_cards(p_exam_term_id uuid, p_class_id uuid)
returns integer language plpgsql security definer set search_path = public as $$
declare
  v_actor   uuid := auth.uid();
  v_session uuid; v_from date; v_to date; v_withhold boolean;
  v_count   integer := 0;
  r         record;
  v_ver     integer; v_att numeric; v_grade text; v_frozen jsonb; v_bal numeric; v_withheld boolean;
begin
  if not public.has_role('owner','principal','admin_clerk') then
    raise exception 'Not permitted to generate result cards';
  end if;
  perform public.assert_own('exam_terms', p_exam_term_id);
  perform public.assert_own('classes', p_class_id);
  select session_id, starts_on, ends_on, result_withheld_for_defaulters
    into v_session, v_from, v_to, v_withhold
  from public.exam_terms where id = p_exam_term_id;
  if v_session is null then raise exception 'Exam term not found'; end if;

  for r in
    with subj as (
      select id, max_marks from public.exam_subjects
      where exam_term_id = p_exam_term_id and class_id = p_class_id
    ),
    tot as (
      select e.id as enrollment_id, e.student_id,
             coalesce(sum(case when me.is_absent then 0 else me.marks end), 0) as total_marks,
             (select coalesce(sum(max_marks), 0) from subj) as total_max
      from public.enrollments e
      left join public.mark_entries me
        on me.enrollment_id = e.id and me.exam_subject_id in (select id from subj)
      where e.session_id = v_session and e.class_id = p_class_id and e.status = 'active'
      group by e.id, e.student_id
    ),
    ranked as (
      select *, case when total_max > 0 then round(total_marks / total_max * 100, 2) else null end as pct
      from tot
    )
    select enrollment_id, student_id, total_marks, total_max, pct,
           rank() over (order by pct desc nulls last) as position
    from ranked
  loop
    select coalesce(max(version), 0) + 1 into v_ver from public.result_cards
      where enrollment_id = r.enrollment_id and exam_term_id = p_exam_term_id;

    select case when count(*) = 0 then null else
      round(100.0 * (count(*) filter (where status in ('present','late')) + 0.5 * count(*) filter (where status = 'half_day')) / count(*), 1) end
      into v_att
    from public.attendance_daily
    where enrollment_id = r.enrollment_id
      and (v_from is null or attendance_date >= v_from)
      and (v_to   is null or attendance_date <= v_to);

    v_grade    := public.fn_grade_for(r.pct);
    v_bal      := public.student_balance(r.student_id);
    v_withheld := coalesce(v_withhold, false) and coalesce(v_bal, 0) > 0;

    select jsonb_build_object(
      'subjects', coalesce(jsonb_agg(jsonb_build_object(
          'subject', sub.name, 'max', es.max_marks, 'pass', es.pass_marks,
          'marks', me.marks, 'is_absent', coalesce(me.is_absent, false),
          'grade', public.fn_grade_for(case when es.max_marks > 0 and not coalesce(me.is_absent, false) and me.marks is not null
                                            then round(me.marks / es.max_marks * 100, 2) else null end)
        ) order by sub.sort_order, sub.name), '[]'::jsonb),
      'total_marks', r.total_marks, 'total_max', r.total_max, 'percentage', r.pct,
      'grade', v_grade, 'position', r.position, 'attendance_pct', v_att,
      'withheld', v_withheld, 'balance', v_bal)
      into v_frozen
    from public.exam_subjects es
    join public.subjects sub on sub.id = es.subject_id
    left join public.mark_entries me on me.exam_subject_id = es.id and me.enrollment_id = r.enrollment_id
    where es.exam_term_id = p_exam_term_id and es.class_id = p_class_id;

    insert into public.result_cards(student_id, enrollment_id, exam_term_id, total_marks, total_max,
      percentage, grade, position, attendance_pct, version, frozen, generated_by)
    values (r.student_id, r.enrollment_id, p_exam_term_id, r.total_marks, r.total_max,
      r.pct, v_grade, r.position, v_att, v_ver, v_frozen, v_actor);
    v_count := v_count + 1;
  end loop;

  return v_count;
end;
$$;

grant execute on function public.fn_grade_for(numeric) to authenticated;
grant execute on function public.fn_exam_marksheet(uuid) to authenticated;
grant execute on function public.fn_enter_marks(uuid, jsonb) to authenticated;
grant execute on function public.fn_generate_result_cards(uuid, uuid) to authenticated;

-- ─────────────────────────────────────────────────────────────────────────
-- 0006_settings.sql
-- ─────────────────────────────────────────────────────────────────────────
-- =============================================================================
-- Settings / school setup — the one operation that must be transactional:
-- switching which academic session is "current". Everything else in Settings
-- (school profile, creating sessions/classes/sections/subjects, editing roles)
-- is plain RLS-guarded client-side CRUD.
-- =============================================================================

-- Make one session current: clear the flag on all others, set it here, and
-- point school_settings.current_session_id at it — in one transaction so there
-- is never more than one "current" session. owner/principal only.
create or replace function public.fn_set_current_session(p_session_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v_school uuid := public.current_school_id();
begin
  if not public.has_role('owner','principal') then
    raise exception 'Only owner/principal may change the current session';
  end if;
  -- Also proves the session belongs to this school, so the UPDATE below can
  -- never be aimed at someone else's row.
  perform public.assert_own('academic_sessions', p_session_id);

  -- The `where school_id` is load-bearing. Without it this statement rewrites
  -- is_current for EVERY school in the database, clearing the current academic
  -- year for all of them — from one school pressing one button.
  update public.academic_sessions
     set is_current = (id = p_session_id)
   where school_id = v_school;

  insert into public.school_settings(school_id, current_session_id)
    values (v_school, p_session_id)
    on conflict (school_id) do update set current_session_id = excluded.current_session_id;
end;
$$;

grant execute on function public.fn_set_current_session(uuid) to authenticated;

-- ─────────────────────────────────────────────────────────────────────────
-- 0007_certificates.sql
-- ─────────────────────────────────────────────────────────────────────────
-- =============================================================================
-- Certificates — issue a leaving / character / bonafide certificate (or ID card)
-- with a gapless per-type serial number. Append-only, like payments: the
-- certificates table has SELECT + INSERT policies only, and this function is the
-- single writer. A reprint reads the frozen `data` snapshot, so it never drifts.
-- =============================================================================

create or replace function public.fn_issue_certificate(
  p_cert_type public.certificate_type, p_student_id uuid, p_data jsonb default '{}'::jsonb
) returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_actor  uuid := auth.uid();
  v_serial bigint;
  v_id     uuid;
  v_snap   jsonb;
begin
  if not public.has_role('owner','principal','admin_clerk') then
    raise exception 'Not permitted to issue certificates';
  end if;
  perform public.assert_own('students', p_student_id);

  -- one gapless serial sequence PER certificate type (unique (cert_type, serial_no))
  v_serial := public.next_counter('certificate_' || p_cert_type::text);

  -- snapshot the student's identity + current enrolment so a reprint is stable
  select jsonb_strip_nulls(jsonb_build_object(
      'student_name', s.full_name, 'father_name', s.father_name, 'gr_no', s.gr_no,
      'dob', s.dob, 'gender', s.gender,
      'class_name', c.name, 'section_name', sec.name, 'roll_no', e.roll_no
    ))
    into v_snap
  from public.students s
  left join public.enrollments e
    on e.student_id = s.id
   and e.session_id = (select current_session_id from public.school_settings where school_id = public.current_school_id())
  left join public.classes c on c.id = e.class_id
  left join public.sections sec on sec.id = e.section_id
  where s.id = p_student_id;

  insert into public.certificates(cert_type, student_id, serial_no, issued_by, data)
  values (p_cert_type, p_student_id, v_serial, v_actor,
          coalesce(v_snap, '{}'::jsonb) || coalesce(p_data, '{}'::jsonb))
  returning id into v_id;

  return jsonb_build_object('id', v_id, 'serial_no', v_serial, 'cert_type', p_cert_type, 'issued_on', current_date);
end;
$$;

grant execute on function public.fn_issue_certificate(public.certificate_type, uuid, jsonb) to authenticated;

-- ─────────────────────────────────────────────────────────────────────────
-- 0008_dashboard.sql
-- ─────────────────────────────────────────────────────────────────────────
-- =============================================================================
-- Dashboard rollup — one round-trip for the home tiles. SECURITY DEFINER so the
-- counts are school-wide regardless of the caller's row visibility, but the
-- finance figures (collected / outstanding / defaulters) are returned only to
-- finance-capable roles; teachers get nulls and the UI hides those tiles.
-- =============================================================================

create or replace function public.fn_dashboard_summary()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_session uuid := (select current_session_id from public.school_settings where school_id = public.current_school_id());
  v_finance boolean := public.has_role('owner','principal','admin_clerk','accountant','readonly');
  v_active  int;
  v_present int; v_absent int; v_leave int; v_late int; v_half int; v_marked int;
  v_today numeric; v_month numeric; v_outstanding numeric; v_defaulters int;
  v_new_admissions int;
begin
  if not public.has_role('owner','principal','admin_clerk','accountant',
                         'class_teacher','subject_teacher','readonly') then
    raise exception 'Not permitted';
  end if;

  select count(*) into v_active
  from public.enrollments e
  where e.session_id = v_session and e.status = 'active';

  select
    count(*) filter (where ad.status = 'present'),
    count(*) filter (where ad.status = 'absent'),
    count(*) filter (where ad.status = 'leave'),
    count(*) filter (where ad.status = 'late'),
    count(*) filter (where ad.status = 'half_day'),
    count(*)
  into v_present, v_absent, v_leave, v_late, v_half, v_marked
  from public.attendance_daily ad
  join public.enrollments e on e.id = ad.enrollment_id
  where ad.attendance_date = current_date and e.session_id = v_session;

  select count(*) into v_new_admissions
  from public.students s
  where date_trunc('month', s.created_at) = date_trunc('month', current_date);

  if v_finance then
    select coalesce(sum(amount), 0) into v_today
    from public.payments where status = 'verified' and created_at::date = current_date;

    select coalesce(sum(amount), 0) into v_month
    from public.payments
    where status = 'verified' and date_trunc('month', created_at) = date_trunc('month', current_date);

    -- one student_balance() call per active student, positive balances only
    select coalesce(sum(b.bal), 0), count(*) into v_outstanding, v_defaulters
    from public.enrollments e
    join lateral (select public.student_balance(e.student_id) as bal) b on true
    where e.session_id = v_session and e.status = 'active' and b.bal > 0;
  end if;

  return jsonb_build_object(
    'active_students', coalesce(v_active, 0),
    'new_admissions_month', coalesce(v_new_admissions, 0),
    'attendance', jsonb_build_object(
      'marked', coalesce(v_marked, 0), 'present', coalesce(v_present, 0),
      'absent', coalesce(v_absent, 0), 'leave', coalesce(v_leave, 0),
      'late', coalesce(v_late, 0), 'half_day', coalesce(v_half, 0)),
    'finance_visible', v_finance,
    'collected_today', v_today,
    'collected_month', v_month,
    'outstanding', v_outstanding,
    'defaulters', v_defaulters
  );
end;
$$;

grant execute on function public.fn_dashboard_summary() to authenticated;

-- ─────────────────────────────────────────────────────────────────────────
-- 0009_assessments.sql
-- ─────────────────────────────────────────────────────────────────────────
-- =============================================================================
-- Assessments (class tests / quizzes) — the lighter cousin of exams. Marks live
-- in the shared mark_entries table under assessment_id. These mirror the exam
-- marks functions: a roster+marks reader and a validated, idempotent upsert that
-- skips locked rows. Creating/listing assessments is plain RLS'd CRUD.
-- =============================================================================

-- Roster for one test with any marks already entered.
create or replace function public.fn_assessment_marksheet(p_assessment_id uuid)
returns table(
  enrollment_id uuid, student_id uuid, full_name text, roll_no text,
  section_name text, marks numeric, is_absent boolean, is_locked boolean, max_marks numeric
) language plpgsql stable security definer set search_path = public as $$
declare v_session uuid; v_class uuid; v_section uuid; v_max numeric;
begin
  if not public.has_role('owner','principal','admin_clerk','class_teacher','subject_teacher') then
    raise exception 'Not permitted to view the marksheet';
  end if;
  select a.session_id, a.class_id, a.section_id, a.max_marks
    into v_session, v_class, v_section, v_max
  from public.assessments a where a.id = p_assessment_id;
  if v_session is null then raise exception 'Assessment not found'; end if;

  return query
    select e.id, s.id, s.full_name, e.roll_no, sec.name,
           me.marks, coalesce(me.is_absent, false), coalesce(me.is_locked, false), v_max
    from public.enrollments e
    join public.students s on s.id = e.student_id
    left join public.sections sec on sec.id = e.section_id
    left join public.mark_entries me on me.assessment_id = p_assessment_id and me.enrollment_id = e.id
    where e.session_id = v_session and e.class_id = v_class and e.status = 'active' and s.deleted_at is null
      and (v_section is null or e.section_id = v_section)
    order by sec.sort_order nulls first,
             coalesce(nullif(regexp_replace(coalesce(e.roll_no, ''), '[^0-9]', '', 'g'), '')::int, 2147483647),
             s.full_name;
end;
$$;

-- Enter/overwrite marks for one test. Idempotent per (assessment, student);
-- skips locked rows; snapshots corrected_from on a change. p_marks = jsonb array
-- of { enrollment_id, marks, is_absent }.
create or replace function public.fn_enter_assessment_marks(p_assessment_id uuid, p_marks jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_actor  uuid := auth.uid();
  v_max    numeric;
  v_locked boolean;
  v_total  integer;
  v_marked integer;
begin
  if not public.has_role('owner','principal','admin_clerk','class_teacher','subject_teacher') then
    raise exception 'Not permitted to enter marks';
  end if;
  if p_marks is null or jsonb_typeof(p_marks) <> 'array' then
    raise exception 'p_marks must be a JSON array';
  end if;
  select max_marks, is_locked into v_max, v_locked from public.assessments where id = p_assessment_id;
  if v_max is null then raise exception 'Assessment not found'; end if;
  if v_locked then raise exception 'This test is locked'; end if;
  if v_max <= 0 then raise exception 'Set the total marks for this test before entering scores'; end if;

  if exists (
    select 1 from jsonb_array_elements(p_marks) e
    where coalesce((e->>'is_absent')::boolean, false) = false
      and nullif(e->>'marks', '') is not null
      and ((e->>'marks')::numeric < 0 or (e->>'marks')::numeric > v_max)
  ) then
    raise exception 'Marks must be between 0 and %', v_max;
  end if;

  select count(distinct (e->>'enrollment_id')) into v_total from jsonb_array_elements(p_marks) e;

  with input as (
    select distinct on (enrollment_id) enrollment_id, marks, is_absent
    from (
      select (e->>'enrollment_id')::uuid as enrollment_id,
             nullif(e->>'marks', '')::numeric as marks,
             coalesce((e->>'is_absent')::boolean, false) as is_absent
      from jsonb_array_elements(p_marks) e
    ) q
    order by enrollment_id
  ),
  upserted as (
    insert into public.mark_entries as me (assessment_id, enrollment_id, marks, max_marks, is_absent, marked_by)
    select p_assessment_id, enrollment_id, marks, v_max, is_absent, v_actor from input
    on conflict (assessment_id, enrollment_id) where assessment_id is not null
    do update set marks = excluded.marks, is_absent = excluded.is_absent, marked_by = excluded.marked_by,
                  corrected_from = case when me.marks is distinct from excluded.marks then me.marks else me.corrected_from end
    where not me.is_locked
    returning 1
  )
  select count(*) into v_marked from upserted;

  return jsonb_build_object('marked', v_marked, 'skipped', v_total - v_marked, 'total', v_total);
end;
$$;

-- Lock a test: freeze the assessment and all its mark rows against further edits.
create or replace function public.fn_lock_assessment(p_assessment_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.has_role('owner','principal','admin_clerk','class_teacher','subject_teacher') then
    raise exception 'Not permitted to lock this test';
  end if;
  if not exists (select 1 from public.assessments where id = p_assessment_id) then
    raise exception 'Assessment not found';
  end if;
  update public.mark_entries set is_locked = true where assessment_id = p_assessment_id;
  update public.assessments set is_locked = true where id = p_assessment_id;
end;
$$;

grant execute on function public.fn_assessment_marksheet(uuid) to authenticated;
grant execute on function public.fn_enter_assessment_marks(uuid, jsonb) to authenticated;
grant execute on function public.fn_lock_assessment(uuid) to authenticated;

-- ─────────────────────────────────────────────────────────────────────────
-- 0010_staff.sql
-- ─────────────────────────────────────────────────────────────────────────
-- =============================================================================
-- Staff <-> login link. A staff record and an auth profile point at each other
-- (staff.profile_id <-> profiles.staff_id) and the mapping is 1:1. Doing this
-- from the client risks a half-linked state, so this one helper sets both sides
-- (and clears any prior link on either side) in a single transaction.
-- Everything else in the Staff module is plain RLS'd CRUD.
-- =============================================================================

create or replace function public.fn_link_staff_profile(p_staff_id uuid, p_profile_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.has_role('owner','principal') then
    raise exception 'Only owner/principal may link staff to a login';
  end if;
  -- Both sides must be ours: linking our staff row to another school's login
  -- would hand that login this school's data.
  perform public.assert_own('staff', p_staff_id);
  perform public.assert_own('profiles', p_profile_id);
  if not exists (select 1 from public.staff where id = p_staff_id) then
    raise exception 'Staff not found';
  end if;

  -- detach this staff from whatever profile currently points at it
  update public.profiles set staff_id = null where staff_id = p_staff_id;

  if p_profile_id is null then
    update public.staff set profile_id = null where id = p_staff_id;
    return;
  end if;

  if not exists (select 1 from public.profiles where id = p_profile_id) then
    raise exception 'Login profile not found';
  end if;

  -- detach the target profile from any OTHER staff row
  update public.staff set profile_id = null where profile_id = p_profile_id and id <> p_staff_id;

  update public.staff set profile_id = p_profile_id where id = p_staff_id;
  update public.profiles set staff_id = p_staff_id where id = p_profile_id;
end;
$$;

grant execute on function public.fn_link_staff_profile(uuid, uuid) to authenticated;

-- ─────────────────────────────────────────────────────────────────────────
-- 0011_auth.sql
-- ─────────────────────────────────────────────────────────────────────────
-- =============================================================================
-- Auth provisioning. A Supabase auth user has no application profile until one
-- is created in public.profiles — and the profiles_insert policy requires an
-- existing owner/principal, so the FIRST user could never get a profile from
-- the client (chicken-and-egg). This trigger closes that gap:
--
--   * every new auth user gets a profiles row automatically, and
--   * the very FIRST user becomes 'owner' (school bootstrap); everyone after
--     starts as 'readonly' for the owner/principal to assign a real role.
--
-- Making the first user owner removes a lockout footgun: if new users defaulted
-- to readonly and the owner skipped the manual SQL elevation, nobody could ever
-- assign roles in-app (readonly can't), and the school would be stuck.
-- =============================================================================

create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_is_first boolean;
begin
  select count(*) = 0 into v_is_first from public.profiles;

  insert into public.profiles (id, full_name, role)
  values (
    new.id,
    coalesce(nullif(new.raw_user_meta_data->>'full_name', ''), split_part(coalesce(new.email, ''), '@', 1)),
    (case when v_is_first then 'owner' else 'readonly' end)::public.user_role
  )
  on conflict (id) do nothing;

  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- ─────────────────────────────────────────────────────────────────────────
-- 0012_import.sql
-- ─────────────────────────────────────────────────────────────────────────
-- =============================================================================
-- Bulk student import — load a paper register (CSV → JSON array) in one call.
--
-- This is the onboarding workhorse: a new school arrives with hundreds of
-- students on paper/Excel. fn_import_students validates every row, resolves
-- class/section BY NAME (so the operator never deals in UUIDs), de-duplicates on
-- GR / Admission No, and admits the good rows — reusing fn_admit_student so GR
-- numbering stays gapless and each student lands on the roster + is billable.
--
-- It is forgiving by design: one bad row never aborts the batch. Each row comes
-- back with a status (created / skipped / error) and a human message, so the
-- operator fixes the few problem rows and re-imports just those.
--
-- p_dry_run = true validates only (no writes) — the UI runs this first so the
-- operator sees exactly what will happen before committing.
--
-- Recognised row keys (all optional except full_name + class):
--   full_name*, father_name, mother_name, b_form, dob (YYYY-MM-DD), gender
--   (male/female/other), address, phone, whatsapp, gr_no, admission_no,
--   admission_date (YYYY-MM-DD), class* (name), section (name), roll_no,
--   guardian_name, guardian_relation, guardian_phone, guardian_whatsapp
-- =============================================================================

create or replace function public.fn_import_students(
  p_session uuid, p_rows jsonb, p_dry_run boolean default false
) returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_row     jsonb;
  v_idx     int := 0;
  v_created int := 0;
  v_skipped int := 0;
  v_errors  int := 0;
  v_results jsonb := '[]'::jsonb;
  v_class   uuid;
  v_section uuid;
  v_gender  text;
  v_gr      text;
  v_admno   text;
  v_name    text;
  v_cls_in  text;
  v_sec_in  text;
  v_status  text;
  v_msg     text;
  v_admit   jsonb;
  v_cnt     int;
  v_dob     text;
  v_adm     text;
begin
  if not public.has_role('owner','principal','admin_clerk') then
    raise exception 'Not permitted to import students';
  end if;
  if p_session is null then
    raise exception 'A target academic session is required';
  end if;
  perform public.assert_own('academic_sessions', p_session);
  if p_rows is null or jsonb_typeof(p_rows) <> 'array' then
    raise exception 'rows must be a JSON array';
  end if;
  if not exists (select 1 from public.academic_sessions where id = p_session) then
    raise exception 'Target session does not exist';
  end if;

  for v_row in select value from jsonb_array_elements(p_rows) as value
  loop
    v_idx    := v_idx + 1;
    v_class  := null;
    v_section:= null;
    v_status := null;
    v_msg    := null;
    v_name   := btrim(coalesce(v_row->>'full_name', ''));
    v_cls_in := btrim(coalesce(v_row->>'class', ''));
    v_sec_in := btrim(coalesce(v_row->>'section', ''));
    v_gender := lower(nullif(btrim(coalesce(v_row->>'gender', '')), ''));
    v_gr     := nullif(btrim(coalesce(v_row->>'gr_no', '')), '');
    v_admno  := nullif(btrim(coalesce(v_row->>'admission_no', '')), '');

    -- 1. required: full name
    if v_name = '' then
      v_status := 'error'; v_msg := 'Full name is required';
    end if;

    -- 2. resolve class by name (case-insensitive, must be active)
    if v_status is null then
      if v_cls_in = '' then
        v_status := 'error'; v_msg := 'Class is required';
      else
        select id into v_class from public.classes
         where active and lower(btrim(name)) = lower(v_cls_in)
         order by level_order limit 1;
        if v_class is null then
          v_status := 'error'; v_msg := 'Unknown class: ' || v_cls_in;
        end if;
      end if;
    end if;

    -- 3. resolve section within the class (only if one was given)
    if v_status is null and v_sec_in <> '' then
      select id into v_section from public.sections
       where class_id = v_class and lower(btrim(name)) = lower(v_sec_in)
       limit 1;
      if v_section is null then
        v_status := 'error';
        v_msg := 'Unknown section "' || v_sec_in || '" for class ' || v_cls_in;
      end if;
    end if;

    -- 4. gender must be a valid enum value if supplied
    if v_status is null and v_gender is not null and v_gender not in ('male','female','other') then
      v_status := 'error'; v_msg := 'Invalid gender (use male/female/other): ' || v_gender;
    end if;

    -- 5. dates must be YYYY-MM-DD if supplied. We insist on ISO rather than just
    --    casting, because Postgres silently mis-parses ambiguous input (e.g.
    --    '12-04-2015' → Dec 4), which would corrupt a date of birth.
    if v_status is null then
      v_dob := nullif(btrim(coalesce(v_row->>'dob', '')), '');
      v_adm := nullif(btrim(coalesce(v_row->>'admission_date', '')), '');
      if (v_dob is not null and v_dob !~ '^\d{4}-\d{2}-\d{2}$')
         or (v_adm is not null and v_adm !~ '^\d{4}-\d{2}-\d{2}$') then
        v_status := 'error'; v_msg := 'Dates must be in YYYY-MM-DD format';
      else
        begin
          perform v_dob::date;
          perform v_adm::date;
        exception when others then
          v_status := 'error'; v_msg := 'Invalid date (use YYYY-MM-DD)';
        end;
      end if;
    end if;

    -- 6. de-duplicate on GR / Admission No so re-running a file is safe
    if v_status is null and v_gr is not null then
      select count(*) into v_cnt from public.students where gr_no = v_gr;
      if v_cnt > 0 then v_status := 'skipped'; v_msg := 'GR ' || v_gr || ' already exists'; end if;
    end if;
    if v_status is null and v_admno is not null then
      select count(*) into v_cnt from public.students where admission_no = v_admno;
      if v_cnt > 0 then v_status := 'skipped'; v_msg := 'Admission No ' || v_admno || ' already exists'; end if;
    end if;

    -- 7. admit (unless this is a dry run or the row already failed/duplicated)
    if v_status is null then
      if p_dry_run then
        v_status := 'ok';
      else
        begin
          v_admit := public.fn_admit_student(
            v_row
            || jsonb_build_object(
                 'session_id', p_session::text,
                 'class_id',   v_class::text,
                 'section_id', v_section::text)
            || case
                 when nullif(btrim(coalesce(v_row->>'guardian_name','')), '') is not null then
                   jsonb_build_object('guardian', jsonb_build_object(
                     'name',     v_row->>'guardian_name',
                     'relation', v_row->>'guardian_relation',
                     'phone',    v_row->>'guardian_phone',
                     'whatsapp', v_row->>'guardian_whatsapp'))
                 else '{}'::jsonb
               end);
          v_status := 'created';
          v_gr := v_admit->>'gr_no';
        exception when others then
          v_status := 'error'; v_msg := SQLERRM;
        end;
      end if;
    end if;

    -- tally (a dry-run 'ok' counts as "would create")
    if    v_status in ('created','ok') then v_created := v_created + 1;
    elsif v_status = 'skipped'         then v_skipped := v_skipped + 1;
    else                                    v_errors  := v_errors  + 1;
    end if;

    v_results := v_results || jsonb_build_object(
      'row', v_idx, 'status', v_status, 'message', v_msg,
      'name', v_name, 'gr_no', v_gr);
  end loop;

  return jsonb_build_object(
    'dry_run', p_dry_run,
    'total',   v_idx,
    'created', v_created,
    'skipped', v_skipped,
    'errors',  v_errors,
    'rows',    v_results);
end;
$$;

grant execute on function public.fn_import_students(uuid, jsonb, boolean) to authenticated;

-- ─────────────────────────────────────────────────────────────────────────
-- 0013_fee_import.sql
-- ─────────────────────────────────────────────────────────────────────────
-- =============================================================================
-- Opening fee-balance import — the second half of onboarding.
--
-- A school going live mid-year doesn't just need its students loaded (see
-- 0012_import.sql); each student already OWES an arrears balance from before the
-- system existed. Without loading it, Fees would start everyone at zero and the
-- defaulter list would be wrong on day one.
--
-- We model an opening balance the same way the rest of the money system already
-- works (see 0002_fees.sql): a single "issued" invoice carrying one line for the
-- outstanding amount, tagged notes = 'opening_balance'. Because the balance is
-- derived (SUM of non-void invoice charges − verified payments), this flows
-- straight into student_balance(), invoice_balances, fn_defaulters and FIFO
-- payment allocation with no special-casing. period_month is left NULL so the
-- opening balance sorts first ("oldest debt") and is settled before new challans.
--
-- Students are matched by GR No (best), else Admission No, else Name(+Father).
-- Idempotent: a student who already has an opening_balance invoice for the
-- session is skipped, so re-running a file is safe.
--
-- Recognised row keys: gr_no | admission_no | full_name (+ father_name) to
-- identify the student, amount (required, currency/commas tolerated), due_date
-- (optional, YYYY-MM-DD).
-- =============================================================================

create or replace function public.fn_import_opening_balances(
  p_session uuid, p_rows jsonb, p_dry_run boolean default false
) returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_row     jsonb;
  v_idx     int := 0;
  v_created int := 0;
  v_skipped int := 0;
  v_errors  int := 0;
  v_results jsonb := '[]'::jsonb;
  v_gr      text;
  v_adm     text;
  v_name    text;
  v_father  text;
  v_amt_raw text;
  v_amt_cln text;
  v_amount  numeric;
  v_due     text;
  v_due_d   date;
  v_student uuid;
  v_enroll  uuid;
  v_status  text;
  v_msg     text;
  v_label   text;
  v_cnt     int;
  v_inv     uuid;
begin
  if not public.has_role('owner','principal','admin_clerk','accountant') then
    raise exception 'Not permitted to import fee balances';
  end if;
  if p_session is null then
    raise exception 'A target academic session is required';
  end if;
  perform public.assert_own('academic_sessions', p_session);
  if p_rows is null or jsonb_typeof(p_rows) <> 'array' then
    raise exception 'rows must be a JSON array';
  end if;
  if not exists (select 1 from public.academic_sessions where id = p_session) then
    raise exception 'Target session does not exist';
  end if;

  for v_row in select value from jsonb_array_elements(p_rows) as value
  loop
    v_idx     := v_idx + 1;
    v_student := null; v_enroll := null; v_status := null; v_msg := null;
    v_amount  := null; v_due_d := null;
    v_gr      := nullif(btrim(coalesce(v_row->>'gr_no', '')), '');
    v_adm     := nullif(btrim(coalesce(v_row->>'admission_no', '')), '');
    v_name    := nullif(btrim(coalesce(v_row->>'full_name', '')), '');
    v_father  := nullif(btrim(coalesce(v_row->>'father_name', '')), '');
    v_amt_raw := btrim(coalesce(v_row->>'amount', ''));
    v_due     := nullif(btrim(coalesce(v_row->>'due_date', '')), '');
    v_label   := coalesce(v_gr, v_adm, v_name, '(row ' || v_idx || ')');

    -- 1. amount (tolerate "Rs 12,000.00" style input)
    if v_amt_raw = '' then
      v_status := 'skipped'; v_msg := 'No amount given';
    else
      v_amt_cln := regexp_replace(v_amt_raw, '[^0-9.\-]', '', 'g');
      begin
        if v_amt_cln in ('', '-', '.', '-.') then raise exception 'empty'; end if;
        v_amount := v_amt_cln::numeric;
      exception when others then
        v_status := 'error'; v_msg := 'Invalid amount: ' || v_amt_raw;
      end;
    end if;
    if v_status is null and v_amount < 0 then
      v_status := 'error'; v_msg := 'Amount cannot be negative (advances aren''t handled here)';
    end if;
    if v_status is null and v_amount = 0 then
      v_status := 'skipped'; v_msg := 'Zero balance';
    end if;

    -- 2. due date (optional)
    if v_status is null and v_due is not null then
      if v_due !~ '^\d{4}-\d{2}-\d{2}$' then
        v_status := 'error'; v_msg := 'Due date must be YYYY-MM-DD';
      else
        begin v_due_d := v_due::date; exception when others then
          v_status := 'error'; v_msg := 'Invalid due date'; end;
      end if;
    end if;

    -- 3. resolve the student (GR → Admission No → Name)
    if v_status is null then
      if v_gr is not null then
        select id into v_student from public.students where gr_no = v_gr and deleted_at is null;
        if v_student is null then v_status := 'error'; v_msg := 'No student with GR ' || v_gr; end if;
      elsif v_adm is not null then
        select count(*) into v_cnt from public.students where admission_no = v_adm and deleted_at is null;
        if v_cnt = 0 then
          v_status := 'error'; v_msg := 'No student with Admission No ' || v_adm;
        elsif v_cnt > 1 then
          v_status := 'error'; v_msg := 'Admission No ' || v_adm || ' matches several students — use GR No';
        else
          select id into v_student from public.students where admission_no = v_adm and deleted_at is null;
        end if;
      elsif v_name is not null then
        select count(*) into v_cnt from public.students
          where lower(full_name) = lower(v_name)
            and (v_father is null or lower(coalesce(father_name, '')) = lower(v_father))
            and deleted_at is null;
        if v_cnt = 0 then
          v_status := 'error'; v_msg := 'No student named ' || v_name;
        elsif v_cnt > 1 then
          v_status := 'error'; v_msg := 'Name ' || v_name || ' matches several students — use GR No';
        else
          select id into v_student from public.students
            where lower(full_name) = lower(v_name)
              and (v_father is null or lower(coalesce(father_name, '')) = lower(v_father))
              and deleted_at is null;
        end if;
      else
        v_status := 'error'; v_msg := 'No identifier — provide GR No, Admission No, or Name';
      end if;
    end if;

    -- friendlier label once we know who this is
    if v_student is not null then
      v_label := coalesce((select full_name from public.students where id = v_student), v_label);
    end if;

    -- 4. the student must be enrolled in the target session (so the balance shows
    --    up on that session's defaulter list)
    if v_status is null then
      select id into v_enroll from public.enrollments
        where student_id = v_student and session_id = p_session;
      if v_enroll is null then
        v_status := 'error'; v_msg := 'Student is not enrolled in the selected session';
      end if;
    end if;

    -- 5. de-duplicate: one opening balance per student per session
    if v_status is null then
      select count(*) into v_cnt from public.invoices
        where student_id = v_student and session_id = p_session
          and notes = 'opening_balance' and status <> 'void';
      if v_cnt > 0 then v_status := 'skipped'; v_msg := 'Opening balance already imported'; end if;
    end if;

    -- 6. create the opening-balance invoice (unless dry run / rejected / duplicate)
    if v_status is null then
      if p_dry_run then
        v_status := 'ok';
      else
        begin
          insert into public.invoices(
            student_id, enrollment_id, session_id, period_month, status,
            arrears_brought_forward, fine, due_date, notes, issued_at, created_by)
          values (
            v_student, v_enroll, p_session, null, 'issued',
            0, 0, v_due_d, 'opening_balance', now(), auth.uid())
          returning id into v_inv;

          insert into public.invoice_lines(invoice_id, fee_head_id, description, amount, is_discount)
          values (v_inv, null, 'Opening balance (arrears brought forward)', v_amount, false);

          v_status := 'created';
        exception when others then
          v_status := 'error'; v_msg := SQLERRM;
        end;
      end if;
    end if;

    if    v_status in ('created','ok') then v_created := v_created + 1;
    elsif v_status = 'skipped'         then v_skipped := v_skipped + 1;
    else                                    v_errors  := v_errors  + 1;
    end if;

    v_results := v_results || jsonb_build_object(
      'row', v_idx, 'status', v_status, 'message', v_msg,
      'name', v_label, 'gr_no', v_gr, 'amount', v_amount);
  end loop;

  return jsonb_build_object(
    'dry_run', p_dry_run, 'total', v_idx,
    'created', v_created, 'skipped', v_skipped, 'errors', v_errors,
    'rows', v_results);
end;
$$;

grant execute on function public.fn_import_opening_balances(uuid, jsonb, boolean) to authenticated;

-- ─────────────────────────────────────────────────────────────────────────
-- 0014_rollover.sql
-- ─────────────────────────────────────────────────────────────────────────
-- =============================================================================
-- Academic-year rollover / promotion.
--
-- The spec flags this as the feature whose absence "breaks the product within
-- 12 months": at year end the whole roster must move to the next session —
-- promoted a class up, detained (retained) in place, or graduated to alumni —
-- with new roll numbers, arrears carried across the boundary, and a way to UNDO
-- a mistake. It is owner/principal only.
--
-- Model (see docs/02-DATA-MODEL.md): identity (Student) is lifelong; a new
-- Enrollment is created for the target session, linked to the source via
-- enrollments.promoted_from, and the source enrollment is stamped
-- promoted/retained/graduated. Arrears need NO copying — student_balance() is
-- global (all non-void invoices − payments), so last year's dues follow the
-- student automatically and surface on the new session's defaulter list as soon
-- as the student has an active enrollment there.
--
--   fn_rollover(from, to, rules, commit) — preview (commit=false, no writes) or
--     apply (commit=true). `rules` is a jsonb array of per-class instructions:
--       [{ "from_class_id": uuid, "action": "promote"|"retain"|"graduate",
--          "to_class_id": uuid|null }]
--     A class with no rule defaults to promote → next class by level_order, or
--     graduate if it is already the top class.
--   fn_rollover_undo(to) — reverse the promotions/retentions of a rollover, but
--     only while the target session has no activity yet (safe undo).
-- =============================================================================

create or replace function public.fn_rollover(
  p_from uuid, p_to uuid, p_rules jsonb default '[]'::jsonb, p_commit boolean default false
) returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_promoted  int := 0;
  v_retained  int := 0;
  v_graduated int := 0;
  v_unmapped  int := 0;
  v_skipped   int := 0;
  v_rows      jsonb;
begin
  if not public.has_role('owner','principal') then
    raise exception 'Only the owner or principal may run a year-end rollover';
  end if;
  if p_from is null or p_to is null then raise exception 'Both sessions are required'; end if;
  perform public.assert_own('academic_sessions', p_from);
  perform public.assert_own('academic_sessions', p_to);
  if p_from = p_to then raise exception 'The target session must differ from the source'; end if;
  if not exists (select 1 from public.academic_sessions where id = p_from) then
    raise exception 'Source session does not exist'; end if;
  if not exists (select 1 from public.academic_sessions where id = p_to) then
    raise exception 'Target session does not exist'; end if;
  if exists (select 1 from public.academic_sessions where id = p_to and is_closed) then
    raise exception 'Target session is closed'; end if;
  if p_rules is null or jsonb_typeof(p_rules) <> 'array' then
    raise exception 'rules must be a JSON array'; end if;

  -- Build the plan for every active enrolment in the source session. A student
  -- who already has an enrolment in the target session is left out (skipped).
  drop table if exists _rollover_plan;
  create temp table _rollover_plan on commit drop as
  with eff as (   -- effective rule per source class (explicit rule, else default)
    select c.id as from_class, c.name as from_class_name,
      coalesce(pr.action, case when nx.id is not null then 'promote' else 'graduate' end) as action,
      case
        when pr.action = 'retain'  then c.id
        when pr.action = 'promote' then pr.to_class_id
        when pr.action = 'graduate' then null
        when pr.action is null and nx.id is not null then nx.id
        else null
      end as to_class
    from public.classes c
    left join lateral (
      select r->>'action' as action, nullif(r->>'to_class_id','')::uuid as to_class_id
      from jsonb_array_elements(p_rules) r
      where (r->>'from_class_id')::uuid = c.id
      limit 1
    ) pr on true
    left join lateral (
      select id from public.classes c2
      where c2.active and c2.level_order > c.level_order
      order by c2.level_order limit 1
    ) nx on true
    where c.active
  ),
  plan as (
    select e.id as from_enr, e.student_id, s.full_name as name, s.gr_no as gr,
           e.class_id as from_class, eff.from_class_name,
           eff.action, eff.to_class, e.section_id as from_section, e.roll_no as old_roll,
           public.student_balance(e.student_id) as balance,
           exists (select 1 from public.enrollments e2
                   where e2.student_id = e.student_id and e2.session_id = p_to) as already
    from public.enrollments e
    join public.students s on s.id = e.student_id
    join eff on eff.from_class = e.class_id
    where e.session_id = p_from and e.status = 'active'
  )
  select
    p.from_enr, p.student_id, p.name, p.gr, p.from_class, p.from_class_name,
    p.action, p.to_class,
    (select tc.name from public.classes tc where tc.id = p.to_class) as to_class_name,
    p.from_section,
    -- carry the section by NAME into the target class, if such a section exists
    (select sec2.id from public.sections sec2
       join public.sections sec1 on sec1.id = p.from_section
      where sec2.class_id = p.to_class and lower(sec2.name) = lower(sec1.name)
      limit 1) as to_section,
    p.old_roll, p.balance, p.already,
    null::text as proposed_roll
  from plan p;

  -- Assign roll numbers per target (class, section), continuing from any existing
  -- rolls already in the target session.
  with r as (
    select pl.from_enr,
      (seed.maxroll + row_number() over (
         partition by pl.to_class, pl.to_section
         order by nullif(regexp_replace(coalesce(pl.old_roll,''),'[^0-9]','','g'),'')::int nulls last, pl.name
       ))::text as roll
    from _rollover_plan pl
    join lateral (
      select coalesce(max(nullif(regexp_replace(coalesce(e.roll_no,''),'[^0-9]','','g'),'')::int), 0) as maxroll
      from public.enrollments e
      where e.session_id = p_to and e.class_id = pl.to_class
        and e.section_id is not distinct from pl.to_section
    ) seed on true
    where not pl.already and pl.action in ('promote','retain') and pl.to_class is not null
  )
  update _rollover_plan pl set proposed_roll = r.roll from r where r.from_enr = pl.from_enr;

  -- Tally
  select
    count(*) filter (where not already and action = 'promote'  and to_class is not null),
    count(*) filter (where not already and action = 'retain'),
    count(*) filter (where not already and action = 'graduate'),
    count(*) filter (where not already and action = 'promote'  and to_class is null),
    count(*) filter (where already)
  into v_promoted, v_retained, v_graduated, v_unmapped, v_skipped
  from _rollover_plan;

  if p_commit then
    -- 1. create the new enrolments (promote + retain)
    insert into public.enrollments(student_id, session_id, class_id, section_id, roll_no, status, promoted_from)
    select student_id, p_to, to_class, to_section, proposed_roll, 'active', from_enr
    from _rollover_plan
    where not already and action in ('promote','retain') and to_class is not null;

    -- 2. stamp the source enrolments
    update public.enrollments e set status = 'promoted'
      from _rollover_plan pl where pl.from_enr = e.id
        and not pl.already and pl.action = 'promote' and pl.to_class is not null;
    update public.enrollments e set status = 'retained'
      from _rollover_plan pl where pl.from_enr = e.id
        and not pl.already and pl.action = 'retain';
    update public.enrollments e set status = 'graduated'
      from _rollover_plan pl where pl.from_enr = e.id
        and not pl.already and pl.action = 'graduate';

    -- 3. graduates become alumni at the identity level
    update public.students s set status = 'graduated'
      from _rollover_plan pl where pl.student_id = s.id
        and not pl.already and pl.action = 'graduate';
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
    'student_id', student_id, 'name', name, 'gr_no', gr,
    'from_class', from_class_name, 'to_class', to_class_name,
    'action', case when already then 'skipped'
                   when action = 'promote' and to_class is null then 'unmapped'
                   else action end,
    'roll_no', proposed_roll, 'balance', balance,
    'message', case when already then 'Already enrolled in the target session'
                    when action = 'promote' and to_class is null then 'No target class chosen'
                    else null end
  ) order by from_class_name, name), '[]'::jsonb)
  into v_rows from _rollover_plan;

  return jsonb_build_object(
    'commit', p_commit, 'from_session', p_from, 'to_session', p_to,
    'promoted', v_promoted, 'retained', v_retained, 'graduated', v_graduated,
    'unmapped', v_unmapped, 'skipped', v_skipped,
    'total', v_promoted + v_retained + v_graduated + v_unmapped + v_skipped,
    'rows', v_rows);
end;
$$;

-- Undo the promotions/retentions of a rollover into p_to — but only while nothing
-- has happened in the target session yet, so the reversal is always safe. Graduated
-- (alumni) students are left as-is and reported, to avoid reactivating a student who
-- was graduated deliberately; reinstate those individually from the profile.
create or replace function public.fn_rollover_undo(p_to uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_undone   int := 0;
  v_grads    int;
begin
  if not public.has_role('owner','principal') then
    raise exception 'Only the owner or principal may undo a rollover';
  end if;
  if p_to is null then raise exception 'Target session is required'; end if;
  perform public.assert_own('academic_sessions', p_to);

  -- Guard: refuse if any real work already exists in the target session.
  if exists (select 1 from public.invoices where session_id = p_to)
     or exists (select 1 from public.assessments where session_id = p_to)
     or exists (select 1 from public.exam_terms where session_id = p_to)
     or exists (select 1 from public.attendance_daily ad
                join public.enrollments e on e.id = ad.enrollment_id
                where e.session_id = p_to)
  then
    raise exception 'Cannot undo: attendance, fees or exams already recorded in the target session';
  end if;

  -- Reactivate the source enrolments, then remove the rollover-created ones.
  update public.enrollments old set status = 'active'
    from public.enrollments new
    where new.session_id = p_to and new.promoted_from is not null
      and old.id = new.promoted_from and old.status in ('promoted','retained');

  select count(*) into v_undone from public.enrollments
    where session_id = p_to and promoted_from is not null;
  delete from public.enrollments
    where session_id = p_to and promoted_from is not null;

  select count(*) into v_grads from public.students where status = 'graduated';

  return jsonb_build_object(
    'undone', v_undone,
    'note', 'Promotions and retentions reversed. Graduated (alumni) students, if any, were left as-is — reinstate individually from the student profile.',
    'graduated_total', v_grads);
end;
$$;

grant execute on function public.fn_rollover(uuid, uuid, jsonb, boolean) to authenticated;
grant execute on function public.fn_rollover_undo(uuid) to authenticated;

-- ─────────────────────────────────────────────────────────────────────────
-- 0015_exam_papers.sql
-- ─────────────────────────────────────────────────────────────────────────
-- =============================================================================
-- Exam papers: add a time-of-day to each paper so the date sheet and admit cards
-- can show when each exam sits. The paper's date already exists on
-- exam_subjects.exam_date (0001); this just adds the optional time (kept as free
-- text like "09:00 AM" so schools can write it however they like).
-- =============================================================================

alter table public.exam_subjects add column paper_time text;

-- ─────────────────────────────────────────────────────────────────────────
-- 0016_staff_import.sql
-- ─────────────────────────────────────────────────────────────────────────
-- =============================================================================
-- Bulk staff import — the staff-side counterpart of the student importer
-- (0012). A school onboarding types (or exports) its staff list once; this loads
-- it in one call, validated, forgiving one bad row, and de-duplicated on
-- Employee No / CNIC so re-running a file is safe.
--
-- Recognised row keys (only full_name required): full_name, designation,
-- employee_no, mobile, whatsapp, cnic, joined_on (YYYY-MM-DD).
-- =============================================================================

create or replace function public.fn_import_staff(
  p_rows jsonb, p_dry_run boolean default false
) returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_row     jsonb;
  v_idx     int := 0;
  v_created int := 0;
  v_skipped int := 0;
  v_errors  int := 0;
  v_results jsonb := '[]'::jsonb;
  v_name    text;
  v_emp     text;
  v_cnic    text;
  v_joined  text;
  v_status  text;
  v_msg     text;
begin
  if not public.has_role('owner','principal','admin_clerk') then
    raise exception 'Not permitted to import staff';
  end if;
  if p_rows is null or jsonb_typeof(p_rows) <> 'array' then
    raise exception 'rows must be a JSON array';
  end if;

  for v_row in select value from jsonb_array_elements(p_rows) as value
  loop
    v_idx := v_idx + 1;
    v_status := null; v_msg := null;
    v_name   := btrim(coalesce(v_row->>'full_name', ''));
    v_emp    := nullif(btrim(coalesce(v_row->>'employee_no', '')), '');
    v_cnic   := nullif(btrim(coalesce(v_row->>'cnic', '')), '');
    v_joined := nullif(btrim(coalesce(v_row->>'joined_on', '')), '');

    if v_name = '' then
      v_status := 'error'; v_msg := 'Full name is required';
    end if;

    if v_status is null and v_joined is not null then
      if v_joined !~ '^\d{4}-\d{2}-\d{2}$' then
        v_status := 'error'; v_msg := 'Joining date must be YYYY-MM-DD';
      else
        begin perform v_joined::date; exception when others then
          v_status := 'error'; v_msg := 'Invalid joining date'; end;
      end if;
    end if;

    if v_status is null and v_emp is not null
       and exists (select 1 from public.staff where employee_no = v_emp and deleted_at is null) then
      v_status := 'skipped'; v_msg := 'Employee No ' || v_emp || ' already exists';
    end if;
    if v_status is null and v_cnic is not null
       and exists (select 1 from public.staff where cnic = v_cnic and deleted_at is null) then
      v_status := 'skipped'; v_msg := 'CNIC already exists';
    end if;

    if v_status is null then
      if p_dry_run then
        v_status := 'ok';
      else
        begin
          insert into public.staff(full_name, designation, employee_no, mobile, whatsapp, cnic, joined_on)
          values (
            v_name,
            nullif(btrim(coalesce(v_row->>'designation','')), ''),
            v_emp,
            nullif(btrim(coalesce(v_row->>'mobile','')), ''),
            nullif(btrim(coalesce(v_row->>'whatsapp','')), ''),
            v_cnic,
            v_joined::date);
          v_status := 'created';
        exception when others then
          v_status := 'error'; v_msg := SQLERRM;
        end;
      end if;
    end if;

    if    v_status in ('created','ok') then v_created := v_created + 1;
    elsif v_status = 'skipped'         then v_skipped := v_skipped + 1;
    else                                    v_errors  := v_errors  + 1;
    end if;

    v_results := v_results || jsonb_build_object(
      'row', v_idx, 'status', v_status, 'message', v_msg, 'name', v_name);
  end loop;

  return jsonb_build_object(
    'dry_run', p_dry_run, 'total', v_idx,
    'created', v_created, 'skipped', v_skipped, 'errors', v_errors, 'rows', v_results);
end;
$$;

grant execute on function public.fn_import_staff(jsonb, boolean) to authenticated;

-- ─────────────────────────────────────────────────────────────────────────
-- 0017_fee_ops.sql
-- ─────────────────────────────────────────────────────────────────────────
-- =============================================================================
-- Fee engine depth — the money controls the plan (03-FEATURES) calls essential
-- that had tables but no operations/UI yet:
--   * Discounts as approvable, reasoned, audited records (separation of duties:
--     anyone with fee access proposes; only owner/principal approves).
--   * Fines / late fees, waivable with a reason.
--   * Adjustments (corrections / waivers / refunds) that actually move the
--     balance — the adjustments table existed but student_balance ignored it.
--
-- The discounts + adjustments tables already have audit triggers (0001), so
-- every change here is tamper-evident.
-- =============================================================================

-- Adjustments were invoice-scoped and not counted anywhere. Make them
-- student-scoped (an invoice link is now optional) so a correction/refund/waiver
-- can stand on its own, and fold them into the derived balance.
alter table public.adjustments add column if not exists student_id uuid references public.students(id);
alter table public.adjustments alter column invoice_id drop not null;

-- Backfill student_id for any pre-existing invoice-scoped adjustments.
update public.adjustments a
   set student_id = i.student_id
  from public.invoices i
 where a.invoice_id = i.id and a.student_id is null;

-- Balance = invoice charges (lines net of discounts) + fines + signed adjustments
-- − verified payments. (Adjustments: positive = extra charge, negative = credit.)
create or replace function public.student_balance(p_student_id uuid)
returns numeric language sql stable security invoker set search_path = public as $$
  select
    coalesce((
      select sum(case when l.is_discount then -l.amount else l.amount end)
      from public.invoice_lines l
      join public.invoices i on i.id = l.invoice_id
      where i.student_id = p_student_id and i.status <> 'void'
    ), 0)
    + coalesce((
      select sum(i.fine) from public.invoices i
      where i.student_id = p_student_id and i.status <> 'void'
    ), 0)
    + coalesce((
      select sum(a.amount) from public.adjustments a
      where a.student_id = p_student_id
    ), 0)
    - coalesce((
      select sum(p.amount) from public.payments p
      where p.student_id = p_student_id and p.status = 'verified'
    ), 0);
$$;

-- --- Discounts -------------------------------------------------------------
-- Propose a discount on an enrolment (starts 'pending'). Any fee role may
-- propose; it only bites once approved (fn_generate_class_invoices reads
-- approved discounts).
create or replace function public.fn_add_discount(
  p_enrollment_id uuid, p_type public.discount_type, p_amount numeric,
  p_is_percent boolean, p_reason text
) returns uuid language plpgsql security definer set search_path = public as $$
declare v_id uuid;
begin
  if not public.has_role('owner','principal','admin_clerk','accountant') then
    raise exception 'Not permitted to propose discounts';
  end if;
  perform public.assert_own('enrollments', p_enrollment_id);
  if p_amount is null or p_amount <= 0 then raise exception 'Discount amount must be positive'; end if;
  if p_is_percent and p_amount > 100 then raise exception 'A percentage discount cannot exceed 100%%'; end if;
  if not exists (select 1 from public.enrollments where id = p_enrollment_id) then
    raise exception 'Enrolment not found';
  end if;
  insert into public.discounts(enrollment_id, type, amount, is_percent, reason, status, created_by)
  values (p_enrollment_id, p_type, p_amount, coalesce(p_is_percent,false), nullif(btrim(p_reason),''), 'pending', auth.uid())
  returning id into v_id;
  return v_id;
end;
$$;

-- Approve / reject / revoke a discount — owner/principal only (separation of duties).
create or replace function public.fn_set_discount_status(
  p_discount_id uuid, p_status public.discount_status
) returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.has_role('owner','principal') then
    raise exception 'Only the owner or principal may approve or reject discounts';
  end if;
  perform public.assert_own('discounts', p_discount_id);
  update public.discounts
     set status = p_status,
         approved_by = case when p_status = 'approved' then auth.uid() else approved_by end,
         approved_at = case when p_status = 'approved' then now() else approved_at end
   where id = p_discount_id;
  if not found then raise exception 'Discount not found'; end if;
end;
$$;

-- --- Fines -----------------------------------------------------------------
-- Add a late fee / fine onto an invoice (increments its fine). A charge, so a
-- clerk/accountant may apply it; the reason is appended to the invoice note.
create or replace function public.fn_apply_fine(
  p_invoice_id uuid, p_amount numeric, p_reason text
) returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.has_role('owner','principal','admin_clerk','accountant') then
    raise exception 'Not permitted to apply fines';
  end if;
  perform public.assert_own('invoices', p_invoice_id);
  if p_amount is null or p_amount <= 0 then raise exception 'Fine amount must be positive'; end if;
  update public.invoices
     set fine = fine + p_amount,
         notes = coalesce(notes || E'\n', '') || 'Fine +' || p_amount::text
                 || case when nullif(btrim(p_reason),'') is null then '' else ': ' || p_reason end
   where id = p_invoice_id and status <> 'void';
  if not found then raise exception 'Invoice not found or is void'; end if;
end;
$$;

-- Waive (zero) an invoice's fine — owner/principal only (like a discount/void).
create or replace function public.fn_waive_fine(
  p_invoice_id uuid, p_reason text
) returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.has_role('owner','principal') then
    raise exception 'Only the owner or principal may waive a fine';
  end if;
  perform public.assert_own('invoices', p_invoice_id);
  update public.invoices
     set fine = 0,
         notes = coalesce(notes || E'\n', '') || 'Fine waived'
                 || case when nullif(btrim(p_reason),'') is null then '' else ': ' || p_reason end
   where id = p_invoice_id and status <> 'void';
  if not found then raise exception 'Invoice not found or is void'; end if;
end;
$$;

-- --- Adjustments (corrections / waivers / refunds) -------------------------
-- A signed change to a student's balance with a mandatory reason. Positive adds
-- a charge; negative gives a credit (waiver / refund of a credit balance).
-- Owner/principal only — it directly changes what a family owes.
create or replace function public.fn_add_adjustment(
  p_student_id uuid, p_amount numeric, p_reason text
) returns uuid language plpgsql security definer set search_path = public as $$
declare v_id uuid;
begin
  if not public.has_role('owner','principal') then
    raise exception 'Only the owner or principal may adjust a balance';
  end if;
  perform public.assert_own('students', p_student_id);
  if p_amount is null or p_amount = 0 then raise exception 'Adjustment amount cannot be zero'; end if;
  if nullif(btrim(p_reason),'') is null then raise exception 'A reason is required'; end if;
  if not exists (select 1 from public.students where id = p_student_id) then
    raise exception 'Student not found';
  end if;
  insert into public.adjustments(student_id, amount, reason, approved_by, created_by)
  values (p_student_id, p_amount, btrim(p_reason), auth.uid(), auth.uid())
  returning id into v_id;
  return v_id;
end;
$$;

grant execute on function public.fn_add_discount(uuid, public.discount_type, numeric, boolean, text) to authenticated;
grant execute on function public.fn_set_discount_status(uuid, public.discount_status) to authenticated;
grant execute on function public.fn_apply_fine(uuid, numeric, text) to authenticated;
grant execute on function public.fn_waive_fine(uuid, text) to authenticated;
grant execute on function public.fn_add_adjustment(uuid, numeric, text) to authenticated;

-- ─────────────────────────────────────────────────────────────────────────
-- 0018_fee_reconciliation.sql
-- ─────────────────────────────────────────────────────────────────────────
-- =============================================================================
-- Fee reconciliation — the plan's headline anti-fraud control (03-FEATURES):
-- "expected-vs-collected + ghost-student check", which catches cash that was
-- never recorded at all (gapless receipts only catch under-recording of payments
-- that WERE entered).
--
--   expected  = everything billed this session (non-void invoice charges + fines)
--   collected = payments actually allocated to those invoices
--   outstanding = expected − collected
--
-- Plus two watch-lists:
--   * uninvoiced   — active students with NO invoice this session (a billing gap;
--                    also how a student could be quietly kept off the books).
--   * ghost_suspects — active students with no invoice AND no attendance ever
--                    (a name on the roll that may not be a real, present child).
-- Finance roles only.
-- =============================================================================

create or replace function public.fn_fee_reconciliation(p_session_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_expected  numeric;
  v_collected numeric;
  v_by_class  jsonb;
  v_uninv     jsonb;
  v_ghost     jsonb;
begin
  if not public.has_role('owner','principal','admin_clerk','accountant') then
    raise exception 'Not permitted to view fee reconciliation';
  end if;
  perform public.assert_own('academic_sessions', p_session_id);

  select coalesce(sum(charge), 0), coalesce(sum(allocated), 0)
    into v_expected, v_collected
  from public.invoice_balances where session_id = p_session_id;

  select coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb) into v_by_class
  from (
    select c.name as class_name,
           coalesce(sum(b.charge), 0) as expected,
           coalesce(sum(b.allocated), 0) as collected,
           coalesce(sum(b.charge - b.allocated), 0) as outstanding
    from public.invoice_balances b
    join public.enrollments e on e.id = b.enrollment_id
    join public.classes c on c.id = e.class_id
    where b.session_id = p_session_id
    group by c.name, c.level_order
    order by c.level_order
  ) t;

  select coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb) into v_uninv
  from (
    select s.gr_no, s.full_name, c.name as class_name
    from public.enrollments e
    join public.students s on s.id = e.student_id
    join public.classes c on c.id = e.class_id
    where e.session_id = p_session_id and e.status = 'active'
      and not exists (select 1 from public.invoices i
                      where i.enrollment_id = e.id and i.status <> 'void')
    order by c.level_order, s.full_name
  ) t;

  select coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb) into v_ghost
  from (
    select s.gr_no, s.full_name, c.name as class_name
    from public.enrollments e
    join public.students s on s.id = e.student_id
    join public.classes c on c.id = e.class_id
    where e.session_id = p_session_id and e.status = 'active'
      and not exists (select 1 from public.invoices i
                      where i.enrollment_id = e.id and i.status <> 'void')
      and not exists (select 1 from public.attendance_daily ad where ad.enrollment_id = e.id)
    order by c.level_order, s.full_name
  ) t;

  return jsonb_build_object(
    'expected', v_expected,
    'collected', v_collected,
    'outstanding', v_expected - v_collected,
    'by_class', v_by_class,
    'uninvoiced', v_uninv,
    'ghost_suspects', v_ghost);
end;
$$;

grant execute on function public.fn_fee_reconciliation(uuid) to authenticated;

-- ─────────────────────────────────────────────────────────────────────────
-- 0019_student_links_and_admission_fee.sql
-- ─────────────────────────────────────────────────────────────────────────
-- =============================================================================
-- Admissions depth (testing round 1):
--   * Explicit family links (sibling / relative) — replaces the fragile
--     "same father name" heuristic and makes the Sibling discount mean something.
--   * Admission fee captured at admission as a REAL invoice + receipt, so the
--     cash hits the day-book and expected-vs-collected reconciliation. An
--     admission fee that were only a profile flag would be money nobody can
--     reconcile — the exact leak the fee-integrity controls exist to stop.
--
-- fn_admit_student is re-created here (supersedes 0004) with two new optional
-- inputs in its jsonb payload:
--   links:          [ { related_student_id, relation } ]
--   admission_fee:  { charged: bool, amount: numeric|null }
-- =============================================================================

-- --- Family links ----------------------------------------------------------
create table if not exists public.student_links (
  id                 uuid primary key default gen_random_uuid(),
  student_id         uuid not null references public.students(id) on delete cascade,
  related_student_id uuid not null references public.students(id) on delete cascade,
  relation           text,                    -- 'Brother','Sister','Cousin', free text
  created_by         uuid references public.profiles(id),
  created_at         timestamptz not null default now(),
  constraint student_links_distinct check (student_id <> related_student_id),
  unique (student_id, related_student_id)
);
create index if not exists idx_student_links_student on public.student_links (student_id);
create index if not exists idx_student_links_related on public.student_links (related_student_id);

alter table public.student_links enable row level security;
create policy student_links_select on public.student_links for select to authenticated using (true);
create policy student_links_write on public.student_links for all to authenticated
  using (public.has_role('owner','principal','admin_clerk'))
  with check (public.has_role('owner','principal','admin_clerk'));

create trigger trg_audit_student_links after insert or update or delete on public.student_links
  for each row execute function public.audit_trigger();

-- Link two students (idempotent per unordered-ish pair; one row, queried both
-- directions). Any admin role may link; it is not a money action.
create or replace function public.fn_link_students(p_a uuid, p_b uuid, p_relation text)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_id uuid;
begin
  if not public.has_role('owner','principal','admin_clerk') then
    raise exception 'Not permitted to link students';
  end if;
  if p_a is null or p_b is null then raise exception 'Both students are required'; end if;
  if p_a = p_b then raise exception 'Cannot link a student to themselves'; end if;
  -- Both sides, or a sibling discount could be justified by a student who
  -- belongs to a different school entirely.
  perform public.assert_own('students', p_a);
  perform public.assert_own('students', p_b);
  insert into public.student_links(student_id, related_student_id, relation, created_by)
  values (p_a, p_b, nullif(btrim(p_relation),''), auth.uid())
  on conflict (student_id, related_student_id) do update set relation = excluded.relation
  returning id into v_id;
  return v_id;
end;
$$;

-- --- Admit student (supersedes 0004): + family links + admission fee --------
create or replace function public.fn_admit_student(p jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_actor   uuid := auth.uid();
  v_prefix  text;
  v_counter bigint;
  v_gr      text;
  v_student uuid;
  v_enroll  uuid;
  v_session uuid := nullif(p->>'session_id','')::uuid;
  v_class   uuid := nullif(p->>'class_id','')::uuid;
  v_section uuid := nullif(p->>'section_id','')::uuid;
  v_roll    text := nullif(p->>'roll_no','');
  v_gr_in   text := nullif(p->>'gr_no','');
  v_next    int;
  v_g       jsonb := p->'guardian';
  v_link    jsonb;
  v_af      jsonb := p->'admission_fee';
  v_af_amt  numeric := 0;
  v_af_head uuid;
  v_af_inv  uuid;
  v_af_pay  uuid;
  v_receipt bigint;
  v_af_receipt bigint := null;
  v_af_recorded numeric := null;
begin
  if not public.has_role('owner','principal','admin_clerk') then
    raise exception 'Not permitted to admit students';
  end if;
  if nullif(p->>'full_name','') is null then raise exception 'Student name is required'; end if;
  if v_session is null then raise exception 'Academic session is required'; end if;
  if v_class   is null then raise exception 'Class is required'; end if;

  -- The ids arrive inside the jsonb payload, so they need checking just like a
  -- named uuid parameter would.
  perform public.assert_own('academic_sessions', v_session);
  perform public.assert_own('classes', v_class);
  perform public.assert_own('sections', v_section);

  if v_gr_in is not null then
    v_gr := v_gr_in;
  else
    select gr_prefix into v_prefix from public.school_settings where school_id = public.current_school_id();
    v_counter := public.next_counter('gr');
    v_gr := coalesce(v_prefix, '') || lpad(v_counter::text, 4, '0');
  end if;

  insert into public.students(
    gr_no, admission_no, full_name, father_name, mother_name, b_form, dob, gender,
    address, phone, whatsapp, status, admission_date, notes)
  values (
    v_gr,
    nullif(p->>'admission_no',''),
    p->>'full_name',
    nullif(p->>'father_name',''),
    nullif(p->>'mother_name',''),
    nullif(p->>'b_form',''),
    nullif(p->>'dob','')::date,
    nullif(p->>'gender','')::public.gender,
    nullif(p->>'address',''),
    nullif(p->>'phone',''),
    nullif(p->>'whatsapp',''),
    'active',
    coalesce(nullif(p->>'admission_date','')::date, current_date),
    nullif(p->>'notes',''))
  returning id into v_student;

  if v_roll is null then
    select coalesce(max(nullif(regexp_replace(coalesce(roll_no,''), '[^0-9]', '', 'g'), '')::int), 0) + 1
    into v_next
    from public.enrollments
    where session_id = v_session and class_id = v_class and section_id is not distinct from v_section;
    v_roll := v_next::text;
  end if;

  insert into public.enrollments(student_id, session_id, class_id, section_id, roll_no, status)
  values (v_student, v_session, v_class, v_section, v_roll, 'active')
  returning id into v_enroll;

  -- optional primary guardian (kept for callers that still send one; the web
  -- admission form now relies on father/mother + the student contact number)
  if v_g is not null and jsonb_typeof(v_g) = 'object' and nullif(v_g->>'name','') is not null then
    insert into public.guardians(student_id, name, relation, phone, whatsapp, is_primary)
    values (v_student, v_g->>'name', nullif(v_g->>'relation',''), nullif(v_g->>'phone',''),
            nullif(v_g->>'whatsapp',''), true);
  end if;

  -- optional family links (sibling / relative already in the school)
  if p->'links' is not null and jsonb_typeof(p->'links') = 'array' then
    for v_link in select * from jsonb_array_elements(p->'links') loop
      if nullif(v_link->>'related_student_id','') is not null
         and nullif(v_link->>'related_student_id','')::uuid <> v_student then
        insert into public.student_links(student_id, related_student_id, relation, created_by)
        values (v_student, nullif(v_link->>'related_student_id','')::uuid,
                nullif(v_link->>'relation',''), v_actor)
        on conflict (student_id, related_student_id) do nothing;
      end if;
    end loop;
  end if;

  -- optional admission fee → a real one-off invoice (+ receipt when an amount
  -- is given). period_month is null so it never appears in the monthly list.
  if v_af is not null and jsonb_typeof(v_af) = 'object' and (v_af->>'charged')::boolean is true then
    v_af_amt := coalesce(nullif(v_af->>'amount','')::numeric, 0);
    if v_af_amt < 0 then raise exception 'Admission fee cannot be negative'; end if;

    select id into v_af_head from public.fee_heads where type = 'admission' and active
      order by sort_order limit 1;
    if v_af_head is null then
      insert into public.fee_heads(name, type, is_recurring, sort_order)
      values ('Admission Fee', 'admission', false, 20) returning id into v_af_head;
    end if;

    insert into public.invoices(student_id, enrollment_id, session_id, period_month, status,
        arrears_brought_forward, due_date, issued_at, created_by, notes)
    values (v_student, v_enroll, v_session, null, 'issued', 0, current_date, now(), v_actor, 'Admission fee')
    returning id into v_af_inv;

    insert into public.invoice_lines(invoice_id, fee_head_id, description, amount, is_discount)
    values (v_af_inv, v_af_head, 'Admission Fee', v_af_amt, false);

    if v_af_amt > 0 then
      v_af_receipt := public.next_counter('receipt');
      insert into public.payments(student_id, amount, method, receipt_no, status, received_by, note)
      values (v_student, v_af_amt, 'cash', v_af_receipt, 'verified', v_actor, 'Admission fee')
      returning id into v_af_pay;
      insert into public.payment_allocations(payment_id, invoice_id, amount)
      values (v_af_pay, v_af_inv, v_af_amt);
      v_af_recorded := v_af_amt;
    end if;
    -- either way, nothing is left owing for the admission fee line
    update public.invoices set status = 'paid' where id = v_af_inv;
  end if;

  return jsonb_build_object(
    'student_id', v_student, 'enrollment_id', v_enroll, 'gr_no', v_gr, 'roll_no', v_roll,
    'admission_fee_amount', v_af_recorded, 'admission_receipt_no', v_af_receipt);
end;
$$;

grant execute on function public.fn_link_students(uuid, uuid, text) to authenticated;
grant execute on function public.fn_admit_student(jsonb) to authenticated;

-- ─────────────────────────────────────────────────────────────────────────
-- 0020_fee_month_ops.sql
-- ─────────────────────────────────────────────────────────────────────────
-- =============================================================================
-- Fee month-ops (testing round 1) — everything the student-profile "Fees" tab
-- needs to behave like a simple month-by-month list while staying on the same
-- append-only, reconcilable ledger:
--   * fn_bill_student_month  — bill ONE student for ONE month on demand, so
--     "Mark paid" on an un-billed month never hits a dead end (safe: arrears is
--     a display snapshot, balance is derived — no double counting).
--   * Deferral ("Delay") as invoice metadata (deferred_until + reason). The
--     family STILL owes it; the reminder is paused, the reason is logged.
--   * Pending vs verified payments (bank challan "not yet cleared"): record as
--     pending (receipt logged, NOT counted, NOT allocated) → verify to count.
--   * fn_student_monthly_fee — the class default fee net of approved discount.
--   * fn_student_month_tests — this student's class tests in a month, with the
--     class average and pass/fail (pass = school pass_percent of the max).
-- =============================================================================

-- --- Deferral metadata + view refresh --------------------------------------
alter table public.invoices add column if not exists deferred_until date;
alter table public.invoices add column if not exists defer_reason text;

-- Re-create the balance view with the deferral columns appended (existing
-- columns unchanged/in order, so create-or-replace is allowed).
create or replace view public.invoice_balances with (security_invoker = true) as
select
  i.id            as invoice_id,
  i.student_id,
  i.enrollment_id,
  i.session_id,
  i.period_month,
  i.status,
  i.due_date,
  i.arrears_brought_forward,
  i.fine,
  coalesce((
    select sum(case when l.is_discount then -l.amount else l.amount end)
    from public.invoice_lines l where l.invoice_id = i.id
  ), 0) + i.fine as charge,
  coalesce((
    select sum(a.amount) from public.payment_allocations a where a.invoice_id = i.id
  ), 0) as allocated,
  i.deferred_until,
  i.defer_reason
from public.invoices i
where i.status <> 'void';

grant select on public.invoice_balances to authenticated;

-- --- Bill one student for one month ----------------------------------------
create or replace function public.fn_bill_student_month(
  p_enrollment_id uuid, p_period_month date, p_due_date date
) returns uuid language plpgsql security definer set search_path = public as $$
declare
  v_actor   uuid := auth.uid();
  v_enr     record;
  v_inv     uuid;
  v_arrears numeric;
  v_tuition numeric;
  v_drec    record;
begin
  if not public.has_role('owner','principal','admin_clerk','accountant') then
    raise exception 'Not permitted to generate invoices';
  end if;
  select e.id, e.student_id, e.session_id, e.class_id into v_enr
  from public.enrollments e where e.id = p_enrollment_id;
  if not found then raise exception 'Enrolment not found'; end if;

  select id into v_inv from public.invoices
   where enrollment_id = p_enrollment_id and period_month = p_period_month and status <> 'void'
   limit 1;
  if found then return v_inv; end if;

  v_arrears := public.student_balance(v_enr.student_id);
  insert into public.invoices(student_id, enrollment_id, session_id, period_month, status,
      arrears_brought_forward, due_date, issued_at, created_by)
  values (v_enr.student_id, v_enr.id, v_enr.session_id, p_period_month, 'issued',
      v_arrears, p_due_date, now(), v_actor)
  returning id into v_inv;

  insert into public.invoice_lines(invoice_id, fee_head_id, description, amount, is_discount)
  select v_inv, fh.id, fh.name, coalesce(sfi.amount, fs.amount), false
  from public.fee_structures fs
  join public.fee_heads fh on fh.id = fs.fee_head_id
  left join public.student_fee_items sfi
    on sfi.enrollment_id = v_enr.id and sfi.fee_head_id = fh.id and sfi.active
  where fs.session_id = v_enr.session_id and fs.class_id = v_enr.class_id
    and fh.is_recurring and fh.active;

  select coalesce(sum(amount), 0) into v_tuition
  from public.invoice_lines where invoice_id = v_inv and not is_discount;

  for v_drec in
    select * from public.discounts d
    where d.enrollment_id = v_enr.id and d.status = 'approved'
  loop
    insert into public.invoice_lines(invoice_id, fee_head_id, description, amount, is_discount)
    values (
      v_inv, null, 'Discount: ' || v_drec.type,
      case when v_drec.is_percent then round(v_tuition * v_drec.amount / 100.0, 2) else v_drec.amount end,
      true);
  end loop;

  return v_inv;
end;
$$;

-- --- Payments: pending support (re-create with p_pending) ------------------
drop function if exists public.fn_record_payment(uuid, numeric, public.payment_method, text);
create or replace function public.fn_record_payment(
  p_student_id uuid, p_amount numeric, p_method public.payment_method,
  p_note text default null, p_pending boolean default false
) returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_actor     uuid := auth.uid();
  v_receipt   bigint;
  v_pay       uuid;
  v_remaining numeric := p_amount;
  v_alloc     numeric;
  v_rec       record;
begin
  if not public.has_role('owner','principal','admin_clerk','accountant') then
    raise exception 'Not permitted to record payments';
  end if;
  if p_amount is null or p_amount <= 0 then raise exception 'Amount must be positive'; end if;
  perform public.assert_own('students', p_student_id);

  v_receipt := public.next_counter('receipt');
  insert into public.payments(student_id, amount, method, receipt_no, status, received_by, note)
  values (p_student_id, p_amount, p_method, v_receipt,
          case when p_pending then 'pending' else 'verified' end, v_actor, p_note)
  returning id into v_pay;

  -- A pending payment (e.g. a bank challan not yet cleared) is logged with a
  -- receipt number but is NOT counted or allocated until it is verified.
  if p_pending then
    return jsonb_build_object('payment_id', v_pay, 'receipt_no', v_receipt,
      'allocated', 0, 'unallocated', p_amount, 'pending', true);
  end if;

  for v_rec in
    select invoice_id, (charge - allocated) as outstanding
    from public.invoice_balances
    where student_id = p_student_id and status in ('issued', 'partial') and (charge - allocated) > 0
    order by period_month nulls first, invoice_id
  loop
    exit when v_remaining <= 0;
    v_alloc := least(v_remaining, v_rec.outstanding);
    insert into public.payment_allocations(payment_id, invoice_id, amount)
    values (v_pay, v_rec.invoice_id, v_alloc);
    v_remaining := v_remaining - v_alloc;

    update public.invoices i set status = (case
      when (select allocated from public.invoice_balances b where b.invoice_id = i.id)
           >= (select charge from public.invoice_balances b where b.invoice_id = i.id)
      then 'paid' else 'partial' end)::public.invoice_status
    where i.id = v_rec.invoice_id;
  end loop;

  return jsonb_build_object(
    'payment_id', v_pay, 'receipt_no', v_receipt,
    'allocated', p_amount - v_remaining, 'unallocated', v_remaining, 'pending', false);
end;
$$;

-- Verify a pending payment → it now counts, and allocates FIFO to open months.
create or replace function public.fn_verify_payment(p_payment_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_pay       record;
  v_remaining numeric;
  v_alloc     numeric;
  v_rec       record;
begin
  if not public.has_role('owner','principal','admin_clerk','accountant') then
    raise exception 'Not permitted to verify payments';
  end if;
  select * into v_pay from public.payments where id = p_payment_id;
  if not found then raise exception 'Payment not found'; end if;
  if v_pay.status <> 'pending' then raise exception 'Only a pending payment can be verified'; end if;

  update public.payments set status = 'verified' where id = p_payment_id;

  v_remaining := v_pay.amount;
  for v_rec in
    select invoice_id, (charge - allocated) as outstanding
    from public.invoice_balances
    where student_id = v_pay.student_id and status in ('issued', 'partial') and (charge - allocated) > 0
    order by period_month nulls first, invoice_id
  loop
    exit when v_remaining <= 0;
    v_alloc := least(v_remaining, v_rec.outstanding);
    insert into public.payment_allocations(payment_id, invoice_id, amount)
    values (p_payment_id, v_rec.invoice_id, v_alloc);
    v_remaining := v_remaining - v_alloc;
    update public.invoices i set status = (case
      when (select allocated from public.invoice_balances b where b.invoice_id = i.id)
           >= (select charge from public.invoice_balances b where b.invoice_id = i.id)
      then 'paid' else 'partial' end)::public.invoice_status
    where i.id = v_rec.invoice_id;
  end loop;

  return jsonb_build_object('payment_id', p_payment_id,
    'allocated', v_pay.amount - v_remaining, 'unallocated', v_remaining);
end;
$$;

-- Cancel a pending payment that never cleared (bounced challan). It never
-- counted, so no reversing entry is needed — just mark it cancelled.
create or replace function public.fn_cancel_pending_payment(p_payment_id uuid, p_reason text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.has_role('owner','principal','admin_clerk','accountant') then
    raise exception 'Not permitted';
  end if;
  perform public.assert_own('payments', p_payment_id);
  update public.payments
     set status = 'cancelled',
         note = coalesce(note || ' · ', '') || 'Cancelled: '
                || coalesce(nullif(btrim(p_reason),''), 'no reason')
   where id = p_payment_id and status = 'pending';
  if not found then raise exception 'No pending payment to cancel'; end if;
end;
$$;

-- --- Deferral ("Delay") ----------------------------------------------------
create or replace function public.fn_defer_invoice(p_invoice_id uuid, p_until date, p_reason text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.has_role('owner','principal','admin_clerk','accountant') then
    raise exception 'Not permitted';
  end if;
  perform public.assert_own('invoices', p_invoice_id);
  update public.invoices
     set deferred_until = p_until,
         defer_reason = nullif(btrim(p_reason),''),
         notes = coalesce(notes || E'\n','') || 'Deferred'
                 || coalesce(' until ' || p_until::text, '')
                 || coalesce(': ' || nullif(btrim(p_reason),''), '')
   where id = p_invoice_id and status in ('issued','partial');
  if not found then raise exception 'Invoice not found, already settled, or void'; end if;
end;
$$;

create or replace function public.fn_undo_defer(p_invoice_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.has_role('owner','principal','admin_clerk','accountant') then
    raise exception 'Not permitted';
  end if;
  perform public.assert_own('invoices', p_invoice_id);
  update public.invoices set deferred_until = null, defer_reason = null where id = p_invoice_id;
  if not found then raise exception 'Invoice not found'; end if;
end;
$$;

-- --- Monthly fee for a student (class default net of approved discount) -----
create or replace function public.fn_student_monthly_fee(p_enrollment_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_enr   record;
  v_gross numeric := 0;
  v_disc  numeric := 0;
  v_drec  record;
begin
  if not public.has_role('owner','principal','admin_clerk','accountant') then
    raise exception 'Not permitted';
  end if;
  perform public.assert_own('enrollments', p_enrollment_id);
  select e.id, e.session_id, e.class_id into v_enr from public.enrollments e where e.id = p_enrollment_id;
  if not found then return jsonb_build_object('gross',0,'discount',0,'net',0); end if;

  select coalesce(sum(coalesce(sfi.amount, fs.amount)), 0) into v_gross
  from public.fee_structures fs
  join public.fee_heads fh on fh.id = fs.fee_head_id
  left join public.student_fee_items sfi
    on sfi.enrollment_id = v_enr.id and sfi.fee_head_id = fh.id and sfi.active
  where fs.session_id = v_enr.session_id and fs.class_id = v_enr.class_id
    and fh.is_recurring and fh.active;

  for v_drec in select * from public.discounts d
    where d.enrollment_id = v_enr.id and d.status = 'approved'
  loop
    v_disc := v_disc + case when v_drec.is_percent then round(v_gross * v_drec.amount / 100.0, 2) else v_drec.amount end;
  end loop;
  if v_disc > v_gross then v_disc := v_gross; end if;

  return jsonb_build_object('gross', v_gross, 'discount', v_disc, 'net', v_gross - v_disc);
end;
$$;

-- --- This student's class tests in a month ---------------------------------
create or replace function public.fn_student_month_tests(p_enrollment_id uuid, p_month date)
returns table(
  assessment_id uuid, title text, subject_name text, assessment_date date,
  max_marks numeric, marks numeric, is_absent boolean,
  class_avg numeric, class_count integer, pass_mark numeric, passed boolean
) language plpgsql stable security definer set search_path = public as $$
declare
  v_first date := date_trunc('month', p_month)::date;
  v_last  date := (date_trunc('month', p_month) + interval '1 month - 1 day')::date;
  v_pass  numeric;
begin
  select pass_percent into v_pass from public.school_settings where school_id = public.current_school_id();
  v_pass := coalesce(v_pass, 33);

  return query
  select a.id, a.title, subj.name, a.assessment_date, a.max_marks,
         me.marks, coalesce(me.is_absent, false),
         (select round(avg(m2.marks), 1) from public.mark_entries m2
            where m2.assessment_id = a.id and not m2.is_absent and m2.marks is not null),
         (select count(*)::int from public.mark_entries m3
            where m3.assessment_id = a.id and not m3.is_absent and m3.marks is not null),
         round(a.max_marks * v_pass / 100.0, 2),
         case when coalesce(me.is_absent, false) or me.marks is null then false
              else me.marks >= a.max_marks * v_pass / 100.0 end
  from public.assessments a
  left join public.subjects subj on subj.id = a.subject_id
  join public.enrollments e on e.id = p_enrollment_id
  left join public.mark_entries me on me.assessment_id = a.id and me.enrollment_id = p_enrollment_id
  where a.session_id = e.session_id and a.class_id = e.class_id
    and a.assessment_date between v_first and v_last
    and (a.section_id is null or a.section_id = e.section_id)
  order by a.assessment_date nulls last, a.title;
end;
$$;

grant execute on function public.fn_bill_student_month(uuid, date, date) to authenticated;
grant execute on function public.fn_record_payment(uuid, numeric, public.payment_method, text, boolean) to authenticated;
grant execute on function public.fn_verify_payment(uuid) to authenticated;
grant execute on function public.fn_cancel_pending_payment(uuid, text) to authenticated;
grant execute on function public.fn_defer_invoice(uuid, date, text) to authenticated;
grant execute on function public.fn_undo_defer(uuid) to authenticated;
grant execute on function public.fn_student_monthly_fee(uuid) to authenticated;
grant execute on function public.fn_student_month_tests(uuid, date) to authenticated;

-- ─────────────────────────────────────────────────────────────────────────
-- 0021_fee_fixes.sql
-- ─────────────────────────────────────────────────────────────────────────
-- =============================================================================
-- Fixes from the adversarial review of the fee/attendance redesign:
--   1. fn_reverse_payment must reject non-verified payments — reversing a pending
--      or cancelled challan would mint a verified negative entry (phantom credit,
--      fake day-book row) since the original never counted.
--   2. Billing must cap cumulative discount at tuition, exactly like the display
--      (fn_student_monthly_fee). An over-discount / stacked "Make free" otherwise
--      bills a NEGATIVE invoice = a hidden credit.
--   3. fn_verify_payment: lock the row (FOR UPDATE) so concurrent verifies can't
--      double-allocate.
--   4. Enforce one invoice per (enrollment, month) at the DB level; make the
--      on-demand and batch billing tolerate the race.
--   5. fn_student_month_tests → SECURITY INVOKER (reads only RLS-public tables).
-- =============================================================================

-- 1. Reversal is for VERIFIED payments only. --------------------------------
create or replace function public.fn_reverse_payment(p_payment_id uuid, p_reason text)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  v_actor uuid := auth.uid();
  v_orig  record;
  v_a     record;
  v_rev   uuid;
  v_receipt bigint;
begin
  if not public.has_role('owner', 'principal') then
    raise exception 'Only owner/principal may reverse a payment';
  end if;
  perform public.assert_own('payments', p_payment_id);
  select * into v_orig from public.payments where id = p_payment_id;
  if not found then raise exception 'Payment not found'; end if;
  if v_orig.status <> 'verified' then
    raise exception 'Only a verified payment can be reversed (pending/cancelled payments are handled in the Pending tab)';
  end if;
  if v_orig.reversal_of is not null then raise exception 'Cannot reverse a reversal'; end if;
  if exists (select 1 from public.payments where reversal_of = p_payment_id) then
    raise exception 'Payment already reversed';
  end if;

  v_receipt := public.next_counter('receipt');
  insert into public.payments(student_id, amount, method, receipt_no, status, received_by, reversal_of, note)
  values (v_orig.student_id, -v_orig.amount, v_orig.method, v_receipt, 'verified', v_actor, p_payment_id,
          coalesce(p_reason, 'reversal'))
  returning id into v_rev;

  for v_a in select * from public.payment_allocations where payment_id = p_payment_id loop
    insert into public.payment_allocations(payment_id, invoice_id, amount)
    values (v_rev, v_a.invoice_id, -v_a.amount);
    update public.invoices i set status = (case
      when (select allocated from public.invoice_balances b where b.invoice_id = i.id) <= 0 then 'issued'
      when (select allocated from public.invoice_balances b where b.invoice_id = i.id)
           >= (select charge from public.invoice_balances b where b.invoice_id = i.id) then 'paid'
      else 'partial' end)::public.invoice_status
    where i.id = v_a.invoice_id;
  end loop;

  return v_rev;
end;
$$;

-- 2 + 4. One invoice per (enrollment, month); billing caps discount at tuition.
create unique index if not exists uq_invoice_enroll_month
  on public.invoices (enrollment_id, period_month)
  where status <> 'void' and period_month is not null;

-- Shared helper: insert approved-discount lines for an invoice, capping the
-- cumulative discount at the tuition so an invoice can never go negative.
create or replace function public.fn__apply_discount_lines(
  p_invoice_id uuid, p_enrollment_id uuid, p_tuition numeric
) returns void language plpgsql security definer set search_path = public as $$
declare
  v_drec record;
  v_room numeric := p_tuition;
  v_amt  numeric;
begin
  for v_drec in
    select * from public.discounts d
    where d.enrollment_id = p_enrollment_id and d.status = 'approved'
    order by d.created_at
  loop
    exit when v_room <= 0;
    v_amt := case when v_drec.is_percent then round(p_tuition * v_drec.amount / 100.0, 2) else v_drec.amount end;
    v_amt := least(v_amt, v_room);
    if v_amt > 0 then
      insert into public.invoice_lines(invoice_id, fee_head_id, description, amount, is_discount)
      values (p_invoice_id, null, 'Discount: ' || v_drec.type, v_amt, true);
      v_room := v_room - v_amt;
    end if;
  end loop;
end;
$$;

create or replace function public.fn_bill_student_month(
  p_enrollment_id uuid, p_period_month date, p_due_date date
) returns uuid language plpgsql security definer set search_path = public as $$
declare
  v_actor   uuid := auth.uid();
  v_enr     record;
  v_inv     uuid;
  v_arrears numeric;
  v_tuition numeric;
begin
  if not public.has_role('owner','principal','admin_clerk','accountant') then
    raise exception 'Not permitted to generate invoices';
  end if;
  perform public.assert_own('enrollments', p_enrollment_id);
  select e.id, e.student_id, e.session_id, e.class_id into v_enr
  from public.enrollments e where e.id = p_enrollment_id;
  if not found then raise exception 'Enrolment not found'; end if;

  select id into v_inv from public.invoices
   where enrollment_id = p_enrollment_id and period_month = p_period_month and status <> 'void'
   limit 1;
  if found then return v_inv; end if;

  v_arrears := public.student_balance(v_enr.student_id);
  begin
    insert into public.invoices(student_id, enrollment_id, session_id, period_month, status,
        arrears_brought_forward, due_date, issued_at, created_by)
    values (v_enr.student_id, v_enr.id, v_enr.session_id, p_period_month, 'issued',
        v_arrears, p_due_date, now(), v_actor)
    returning id into v_inv;
  exception when unique_violation then
    -- lost a race with a concurrent bill for the same (enrolment, month)
    select id into v_inv from public.invoices
     where enrollment_id = p_enrollment_id and period_month = p_period_month and status <> 'void' limit 1;
    return v_inv;
  end;

  insert into public.invoice_lines(invoice_id, fee_head_id, description, amount, is_discount)
  select v_inv, fh.id, fh.name, coalesce(sfi.amount, fs.amount), false
  from public.fee_structures fs
  join public.fee_heads fh on fh.id = fs.fee_head_id
  left join public.student_fee_items sfi
    on sfi.enrollment_id = v_enr.id and sfi.fee_head_id = fh.id and sfi.active
  where fs.session_id = v_enr.session_id and fs.class_id = v_enr.class_id
    and fh.is_recurring and fh.active;

  select coalesce(sum(amount), 0) into v_tuition
  from public.invoice_lines where invoice_id = v_inv and not is_discount;

  perform public.fn__apply_discount_lines(v_inv, v_enr.id, v_tuition);
  return v_inv;
end;
$$;

create or replace function public.fn_generate_class_invoices(
  p_session_id uuid, p_class_id uuid, p_period_month date, p_due_date date
) returns integer language plpgsql security definer set search_path = public as $$
declare
  v_actor uuid := auth.uid();
  v_enr   record;
  v_inv   uuid;
  v_count integer := 0;
  v_arrears numeric;
  v_tuition numeric;
begin
  if not public.has_role('owner', 'principal', 'admin_clerk', 'accountant') then
    raise exception 'Not permitted to generate invoices';
  end if;
  perform public.assert_own('academic_sessions', p_session_id);
  perform public.assert_own('classes', p_class_id);

  for v_enr in
    select e.id as enrollment_id, e.student_id
    from public.enrollments e
    where e.session_id = p_session_id and e.class_id = p_class_id and e.status = 'active'
      and not exists (
        select 1 from public.invoices i
        where i.enrollment_id = e.id and i.period_month = p_period_month and i.status <> 'void'
      )
  loop
    v_arrears := public.student_balance(v_enr.student_id);
    begin
      insert into public.invoices(
        student_id, enrollment_id, session_id, period_month, status,
        arrears_brought_forward, due_date, issued_at, created_by)
      values (
        v_enr.student_id, v_enr.enrollment_id, p_session_id, p_period_month, 'issued',
        v_arrears, p_due_date, now(), v_actor)
      returning id into v_inv;
    exception when unique_violation then
      -- another run billed this (enrolment, month) concurrently — skip it
      continue;
    end;

    insert into public.invoice_lines(invoice_id, fee_head_id, description, amount, is_discount)
    select v_inv, fh.id, fh.name, coalesce(sfi.amount, fs.amount), false
    from public.fee_structures fs
    join public.fee_heads fh on fh.id = fs.fee_head_id
    left join public.student_fee_items sfi
      on sfi.enrollment_id = v_enr.enrollment_id and sfi.fee_head_id = fh.id and sfi.active
    where fs.session_id = p_session_id and fs.class_id = p_class_id
      and fh.is_recurring and fh.active;

    select coalesce(sum(amount), 0) into v_tuition
    from public.invoice_lines where invoice_id = v_inv and not is_discount;

    perform public.fn__apply_discount_lines(v_inv, v_enr.enrollment_id, v_tuition);
    v_count := v_count + 1;
  end loop;

  return v_count;
end;
$$;

-- 3. Lock the pending row before verifying to serialize concurrent verifies.
create or replace function public.fn_verify_payment(p_payment_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_pay       record;
  v_remaining numeric;
  v_alloc     numeric;
  v_rec       record;
begin
  if not public.has_role('owner','principal','admin_clerk','accountant') then
    raise exception 'Not permitted to verify payments';
  end if;
  perform public.assert_own('payments', p_payment_id);
  select * into v_pay from public.payments where id = p_payment_id for update;
  if not found then raise exception 'Payment not found'; end if;
  if v_pay.status <> 'pending' then raise exception 'Only a pending payment can be verified'; end if;

  update public.payments set status = 'verified' where id = p_payment_id;

  v_remaining := v_pay.amount;
  for v_rec in
    select invoice_id, (charge - allocated) as outstanding
    from public.invoice_balances
    where student_id = v_pay.student_id and status in ('issued', 'partial') and (charge - allocated) > 0
    order by period_month nulls first, invoice_id
  loop
    exit when v_remaining <= 0;
    v_alloc := least(v_remaining, v_rec.outstanding);
    insert into public.payment_allocations(payment_id, invoice_id, amount)
    values (p_payment_id, v_rec.invoice_id, v_alloc);
    v_remaining := v_remaining - v_alloc;
    update public.invoices i set status = (case
      when (select allocated from public.invoice_balances b where b.invoice_id = i.id)
           >= (select charge from public.invoice_balances b where b.invoice_id = i.id)
      then 'paid' else 'partial' end)::public.invoice_status
    where i.id = v_rec.invoice_id;
  end loop;

  return jsonb_build_object('payment_id', p_payment_id,
    'allocated', v_pay.amount - v_remaining, 'unallocated', v_remaining);
end;
$$;

-- 5. Month-tests reads only RLS-public academic tables → SECURITY INVOKER.
create or replace function public.fn_student_month_tests(p_enrollment_id uuid, p_month date)
returns table(
  assessment_id uuid, title text, subject_name text, assessment_date date,
  max_marks numeric, marks numeric, is_absent boolean,
  class_avg numeric, class_count integer, pass_mark numeric, passed boolean
) language plpgsql stable security invoker set search_path = public as $$
declare
  v_first date := date_trunc('month', p_month)::date;
  v_last  date := (date_trunc('month', p_month) + interval '1 month - 1 day')::date;
  v_pass  numeric;
begin
  select pass_percent into v_pass from public.school_settings where school_id = public.current_school_id();
  v_pass := coalesce(v_pass, 33);

  return query
  select a.id, a.title, subj.name, a.assessment_date, a.max_marks,
         me.marks, coalesce(me.is_absent, false),
         (select round(avg(m2.marks), 1) from public.mark_entries m2
            where m2.assessment_id = a.id and not m2.is_absent and m2.marks is not null),
         (select count(*)::int from public.mark_entries m3
            where m3.assessment_id = a.id and not m3.is_absent and m3.marks is not null),
         round(a.max_marks * v_pass / 100.0, 2),
         case when coalesce(me.is_absent, false) or me.marks is null then false
              else me.marks >= a.max_marks * v_pass / 100.0 end
  from public.assessments a
  left join public.subjects subj on subj.id = a.subject_id
  join public.enrollments e on e.id = p_enrollment_id
  left join public.mark_entries me on me.assessment_id = a.id and me.enrollment_id = p_enrollment_id
  where a.session_id = e.session_id and a.class_id = e.class_id
    and a.assessment_date between v_first and v_last
    and (a.section_id is null or a.section_id = e.section_id)
  order by a.assessment_date nulls last, a.title;
end;
$$;

grant execute on function public.fn__apply_discount_lines(uuid, uuid, numeric) to authenticated;

-- ─────────────────────────────────────────────────────────────────────────
-- 0022_teacher_portal.sql
-- ─────────────────────────────────────────────────────────────────────────
-- =============================================================================
-- Teacher portal (same codebase, teacher-role view):
--   * teacher_assignments — WHICH class/section a teacher owns this session. The
--     scoping backbone: a teacher may only mark attendance / enter test marks for
--     a class they are assigned to. Supports section-level and whole-class
--     (section_id null) assignment.
--   * staff_attendance — the teacher's OWN daily attendance (append-only, one row
--     per staff per day, audited), recorded by scanning the school QR after login.
--   * staff_checkin_codes — rotatable codes the principal prints as a QR. The QR
--     is a deep-link the phone camera opens; integrity = login + SERVER clock +
--     an optional GPS geofence. A photographed code still needs a valid login and
--     (if the geofence is on) being physically at school.
-- =============================================================================

-- --- Teacher assignments ----------------------------------------------------
create table if not exists public.teacher_assignments (
  id         uuid primary key default gen_random_uuid(),
  staff_id   uuid not null references public.staff(id) on delete cascade,
  session_id uuid not null references public.academic_sessions(id),
  class_id   uuid not null references public.classes(id),
  section_id uuid references public.sections(id),      -- null = whole class
  created_by uuid references public.profiles(id),
  created_at timestamptz not null default now(),
  unique (staff_id, session_id, class_id, section_id)
);
create index if not exists idx_teacher_assign_staff on public.teacher_assignments (staff_id, session_id);
create index if not exists idx_teacher_assign_class on public.teacher_assignments (session_id, class_id, section_id);

alter table public.teacher_assignments enable row level security;
create policy teacher_assign_select on public.teacher_assignments for select to authenticated using (true);
create policy teacher_assign_write on public.teacher_assignments for all to authenticated
  using (public.has_role('owner','principal','admin_clerk'))
  with check (public.has_role('owner','principal','admin_clerk'));
create trigger trg_audit_teacher_assign after insert or update or delete on public.teacher_assignments
  for each row execute function public.audit_trigger();

-- helper: the staff row for the current login (null if unlinked)
create or replace function public.my_staff_id() returns uuid
language sql stable security definer set search_path = public as $$
  select staff_id from public.profiles where id = auth.uid();
$$;

-- --- Check-in codes (created before staff_attendance, which FKs to it) ------
create table if not exists public.staff_checkin_codes (
  id         uuid primary key default gen_random_uuid(),
  code       text not null unique,
  label      text,
  valid_from date,
  valid_to   date,
  active     boolean not null default true,
  created_by uuid references public.profiles(id),
  created_at timestamptz not null default now()
);
alter table public.staff_checkin_codes enable row level security;
create policy checkin_codes_select on public.staff_checkin_codes for select to authenticated
  using (public.has_role('owner','principal','admin_clerk'));
create policy checkin_codes_write on public.staff_checkin_codes for all to authenticated
  using (public.has_role('owner','principal','admin_clerk'))
  with check (public.has_role('owner','principal','admin_clerk'));

-- --- Staff self-attendance --------------------------------------------------
create table if not exists public.staff_attendance (
  id              uuid primary key default gen_random_uuid(),
  staff_id        uuid not null references public.staff(id) on delete cascade,
  attendance_date date not null,
  status          public.attendance_status not null default 'present',
  checked_at      timestamptz,                 -- server timestamp of the scan
  code_id         uuid references public.staff_checkin_codes(id),
  source          text not null default 'qr',  -- 'qr' | 'manual'
  device          text,
  reason          text,
  marked_by       uuid references public.profiles(id),
  created_at      timestamptz not null default now(),
  unique (staff_id, attendance_date)
);
create index if not exists idx_staff_att_staff on public.staff_attendance (staff_id, attendance_date);

alter table public.staff_attendance enable row level security;
-- read: admins see all; a teacher sees only their own
create policy staff_att_select on public.staff_attendance for select to authenticated
  using (public.has_role('owner','principal','admin_clerk') or staff_id = public.my_staff_id());
-- no direct insert/update policy → all writes go through the SECURITY DEFINER
-- functions below (append-only, like payments).
create trigger trg_audit_staff_att after insert or update or delete on public.staff_attendance
  for each row execute function public.audit_trigger();

-- --- Geofence settings (optional integrity control) -------------------------
alter table public.school_settings add column if not exists geofence_enabled boolean not null default false;
alter table public.school_settings add column if not exists geo_lat double precision;
alter table public.school_settings add column if not exists geo_lng double precision;
alter table public.school_settings add column if not exists geo_radius_m integer not null default 200;

-- --- Scoping helper ---------------------------------------------------------
-- May the caller manage (roster/mark) this class/section? Admin roles always;
-- teachers only where they hold an assignment (a whole-class assignment, i.e.
-- section_id null, covers every section of that class).
-- NOTE: superseded in 0025_multi_tenancy.sql, which adds the tenant check.
-- It cannot be added here: this is a SQL-language function, so its body is
-- validated at creation time and school_id does not exist yet at 0022.
create or replace function public.fn_may_manage_class(p_session uuid, p_class uuid, p_section uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select public.has_role('owner','principal','admin_clerk')
    or exists (
      select 1 from public.teacher_assignments ta
      join public.staff st on st.id = ta.staff_id
      join public.profiles pr on pr.staff_id = st.id
      where pr.id = auth.uid()
        and ta.session_id = p_session
        and ta.class_id = p_class
        and (ta.section_id is not distinct from p_section or ta.section_id is null)
    );
$$;

-- The caller's assignments for the current session (drives the "My Class" home).
create or replace function public.fn_my_assignments()
returns table(class_id uuid, class_name text, level_order integer, section_id uuid, section_name text)
language sql stable security definer set search_path = public as $$
  select ta.class_id, c.name, c.level_order, ta.section_id, sec.name
  from public.teacher_assignments ta
  join public.academic_sessions s on s.id = ta.session_id and s.is_current
  join public.classes c on c.id = ta.class_id
  left join public.sections sec on sec.id = ta.section_id
  where ta.staff_id = public.my_staff_id()
  order by c.level_order, sec.name nulls first;
$$;

-- --- Attendance functions: add teacher scope --------------------------------
create or replace function public.fn_section_roster(
  p_session_id uuid, p_class_id uuid, p_section_id uuid, p_date date
) returns table(
  enrollment_id uuid, student_id uuid, full_name text, father_name text,
  roll_no text, status public.attendance_status, is_locked boolean
) language plpgsql stable security definer set search_path = public as $$
begin
  if not public.has_role('owner','principal','admin_clerk','class_teacher','subject_teacher') then
    raise exception 'Not permitted to view the attendance roster';
  end if;
  if not public.fn_may_manage_class(p_session_id, p_class_id, p_section_id) then
    raise exception 'You can only view your assigned class';
  end if;
  return query
    select e.id, s.id, s.full_name, s.father_name, e.roll_no,
           ad.status, coalesce(ad.is_locked, false)
    from public.enrollments e
    join public.students s on s.id = e.student_id
    left join public.attendance_daily ad
      on ad.enrollment_id = e.id and ad.attendance_date = p_date
    where e.session_id = p_session_id
      and e.class_id = p_class_id
      and e.section_id is not distinct from p_section_id
      and e.status = 'active'
      and s.deleted_at is null
    order by coalesce(nullif(regexp_replace(coalesce(e.roll_no, ''), '[^0-9]', '', 'g'), '')::int, 2147483647),
             s.full_name;
end;
$$;

create or replace function public.fn_mark_attendance(p_date date, p_marks jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_actor  uuid := auth.uid();
  v_total  integer;
  v_marked integer;
begin
  if not public.has_role('owner','principal','admin_clerk','class_teacher','subject_teacher') then
    raise exception 'Not permitted to mark attendance';
  end if;
  if p_marks is null or jsonb_typeof(p_marks) <> 'array' then
    raise exception 'p_marks must be a JSON array';
  end if;

  -- tenant scope: every enrolment must be in THIS school. Checked for all roles,
  -- because the teacher-scope check below is skipped for admins — leaving them
  -- able to mark attendance against another school's enrolment ids.
  if exists (
    select 1 from jsonb_array_elements(p_marks) e
    where not exists (
      select 1 from public.enrollments en
      where en.id = (e->>'enrollment_id')::uuid
        and en.school_id = public.current_school_id()
    )
  ) then
    raise exception 'Unknown enrolment in this school' using errcode = '42501';
  end if;

  -- teacher scope: every enrolment must be in a class the caller is assigned to
  if not public.has_role('owner','principal','admin_clerk') then
    if exists (
      select 1 from jsonb_array_elements(p_marks) e
      join public.enrollments en on en.id = (e->>'enrollment_id')::uuid
      where not public.fn_may_manage_class(en.session_id, en.class_id, en.section_id)
    ) then
      raise exception 'You can only mark attendance for your assigned class';
    end if;
  end if;

  select count(distinct (e->>'enrollment_id')) into v_total
  from jsonb_array_elements(p_marks) e;

  with input as (
    select distinct on (enrollment_id) enrollment_id, status
    from (
      select (e->>'enrollment_id')::uuid as enrollment_id,
             (e->>'status')::public.attendance_status as status
      from jsonb_array_elements(p_marks) e
    ) q
    order by enrollment_id
  ),
  upserted as (
    insert into public.attendance_daily as ad (enrollment_id, attendance_date, status, marked_by)
    select enrollment_id, p_date, status, v_actor from input
    on conflict (enrollment_id, attendance_date) do update
      set status = excluded.status,
          marked_by = excluded.marked_by,
          corrected_from = case when ad.status is distinct from excluded.status
                                then ad.status else ad.corrected_from end
      where not ad.is_locked
    returning 1
  )
  select count(*) into v_marked from upserted;

  return jsonb_build_object('marked', v_marked, 'skipped', v_total - v_marked, 'total', v_total);
end;
$$;

create or replace function public.fn_finalize_attendance(
  p_session_id uuid, p_class_id uuid, p_section_id uuid, p_date date
) returns integer language plpgsql security definer set search_path = public as $$
declare v_count integer;
begin
  if not public.has_role('owner','principal','admin_clerk','class_teacher','subject_teacher') then
    raise exception 'Not permitted to finalize attendance';
  end if;
  if not public.fn_may_manage_class(p_session_id, p_class_id, p_section_id) then
    raise exception 'You can only finalize your assigned class';
  end if;
  update public.attendance_daily ad
    set is_locked = true
    from public.enrollments e
    where ad.enrollment_id = e.id
      and ad.attendance_date = p_date
      and e.session_id = p_session_id
      and e.class_id = p_class_id
      and e.section_id is not distinct from p_section_id;
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

-- --- Check-in code generation + scan ---------------------------------------
create or replace function public.fn_generate_checkin_code(
  p_label text, p_valid_from date, p_valid_to date, p_deactivate_others boolean default true
) returns jsonb language plpgsql security definer set search_path = public as $$
declare v_code text; v_id uuid;
begin
  if not public.has_role('owner','principal','admin_clerk') then
    raise exception 'Not permitted to generate a check-in code';
  end if;
  if p_deactivate_others then
    -- Without `where school_id`, rotating one school's QR would deactivate the
    -- check-in code of every school in the database at once.
    update public.staff_checkin_codes set active = false
     where active and school_id = public.current_school_id();
  end if;
  v_code := replace(gen_random_uuid()::text, '-', '');
  insert into public.staff_checkin_codes(code, label, valid_from, valid_to, active, created_by)
  values (v_code, nullif(btrim(p_label),''), p_valid_from, p_valid_to, true, auth.uid())
  returning id into v_id;
  return jsonb_build_object('id', v_id, 'code', v_code);
end;
$$;

-- Record the caller's own attendance for today by scanning the school QR.
-- Idempotent per (staff, day). Server clock only; optional geofence.
create or replace function public.fn_staff_check_in(
  p_code text, p_lat double precision default null, p_lng double precision default null, p_device text default null
) returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_staff  uuid := public.my_staff_id();
  v_code   record;
  v_today  date := current_date;
  v_exist  record;
  v_geo_on boolean; v_lat double precision; v_lng double precision; v_radius integer; v_dist double precision;
begin
  if auth.uid() is null then raise exception 'Not authenticated'; end if;
  if v_staff is null then
    raise exception 'Your login is not linked to a staff record — ask the principal to link it in Staff.';
  end if;

  select * into v_code from public.staff_checkin_codes where code = p_code and active limit 1;
  if not found then raise exception 'Invalid or inactive check-in code'; end if;
  if v_code.valid_from is not null and v_today < v_code.valid_from then raise exception 'This check-in code is not active yet'; end if;
  if v_code.valid_to  is not null and v_today > v_code.valid_to  then raise exception 'This check-in code has expired'; end if;

  select geofence_enabled, geo_lat, geo_lng, geo_radius_m
    into v_geo_on, v_lat, v_lng, v_radius from public.school_settings where school_id = public.current_school_id();
  if coalesce(v_geo_on, false) then
    if p_lat is null or p_lng is null then raise exception 'Location is required to check in — enable location and try again.'; end if;
    if v_lat is null or v_lng is null then raise exception 'School location is not set — ask the principal to set it in Settings.'; end if;
    v_dist := 2 * 6371000 * asin(least(1, sqrt(
      power(sin(radians((p_lat - v_lat) / 2)), 2)
      + cos(radians(v_lat)) * cos(radians(p_lat)) * power(sin(radians((p_lng - v_lng) / 2)), 2))));
    if v_dist > coalesce(v_radius, 200) then
      raise exception 'You are too far from the school to check in (about % m away).', round(v_dist);
    end if;
  end if;

  select * into v_exist from public.staff_attendance where staff_id = v_staff and attendance_date = v_today;
  if found then
    return jsonb_build_object('status', 'already', 'checked_at', v_exist.checked_at, 'attendance_status', v_exist.status);
  end if;
  insert into public.staff_attendance(staff_id, attendance_date, status, checked_at, code_id, source, device)
  values (v_staff, v_today, 'present', now(), v_code.id, 'qr', nullif(btrim(p_device),''));
  return jsonb_build_object('status', 'ok', 'checked_at', now());
end;
$$;

-- Admin: manually set/correct a staff member's attendance for a day (leave, absent,
-- or fixing a missed scan). Append/replace one row; audited.
create or replace function public.fn_set_staff_attendance(
  p_staff_id uuid, p_date date, p_status public.attendance_status, p_reason text
) returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.has_role('owner','principal','admin_clerk') then
    raise exception 'Not permitted to set staff attendance';
  end if;
  perform public.assert_own('staff', p_staff_id);
  insert into public.staff_attendance(staff_id, attendance_date, status, source, reason, marked_by, checked_at)
  values (p_staff_id, p_date, p_status, 'manual', nullif(btrim(p_reason),''), auth.uid(), now())
  on conflict (staff_id, attendance_date) do update
    set status = excluded.status, source = 'manual', reason = excluded.reason,
        marked_by = excluded.marked_by;
end;
$$;

-- Staff attendance summary over a window (same shape as the student summary).
create or replace function public.fn_staff_attendance_summary(
  p_staff_id uuid, p_from date, p_to date
) returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v jsonb;
begin
  if not (public.has_role('owner','principal','admin_clerk') or p_staff_id = public.my_staff_id()) then
    raise exception 'Not permitted';
  end if;
  perform public.assert_own('staff', p_staff_id);
  select jsonb_build_object(
    'present',     count(*) filter (where status = 'present'),
    'absent',      count(*) filter (where status = 'absent'),
    'leave',       count(*) filter (where status = 'leave'),
    'late',        count(*) filter (where status = 'late'),
    'half_day',    count(*) filter (where status = 'half_day'),
    'marked_days', count(*),
    'present_pct', case when count(*) = 0 then null else
        round(100.0 * (count(*) filter (where status in ('present','late'))
              + 0.5 * count(*) filter (where status = 'half_day')) / count(*), 1) end
  ) into v
  from public.staff_attendance
  where staff_id = p_staff_id and attendance_date between p_from and p_to;
  return v;
end;
$$;

grant execute on function public.my_staff_id() to authenticated;
grant execute on function public.fn_may_manage_class(uuid, uuid, uuid) to authenticated;
grant execute on function public.fn_my_assignments() to authenticated;
grant execute on function public.fn_generate_checkin_code(text, date, date, boolean) to authenticated;
grant execute on function public.fn_staff_check_in(text, double precision, double precision, text) to authenticated;
grant execute on function public.fn_set_staff_attendance(uuid, date, public.attendance_status, text) to authenticated;
grant execute on function public.fn_staff_attendance_summary(uuid, date, date) to authenticated;

-- ─────────────────────────────────────────────────────────────────────────
-- 0023_test_scoping.sql
-- ─────────────────────────────────────────────────────────────────────────
-- =============================================================================
-- Scope class TESTS (assessments) to a teacher's assigned class — the same fence
-- 0022 put on attendance. Admins keep full access; a teacher may only create,
-- mark, and lock tests for a class/section they are assigned to.
-- (Formal term-exam marks entry by teachers is a separate, later slice — the
-- exam term + date sheet + result cards stay centrally managed.)
-- =============================================================================

-- Creation / edit of a test row: admin, or the teacher assigned to that class.
drop policy if exists assessments_write on public.assessments;
create policy assessments_write on public.assessments for all to authenticated
  using (
    public.has_role('owner','principal','admin_clerk')
    or public.fn_may_manage_class(session_id, class_id, section_id)
  )
  with check (
    public.has_role('owner','principal','admin_clerk')
    or public.fn_may_manage_class(session_id, class_id, section_id)
  );

create or replace function public.fn_assessment_marksheet(p_assessment_id uuid)
returns table(
  enrollment_id uuid, student_id uuid, full_name text, roll_no text,
  section_name text, marks numeric, is_absent boolean, is_locked boolean, max_marks numeric
) language plpgsql stable security definer set search_path = public as $$
declare v_session uuid; v_class uuid; v_section uuid; v_max numeric;
begin
  if not public.has_role('owner','principal','admin_clerk','class_teacher','subject_teacher') then
    raise exception 'Not permitted to view the marksheet';
  end if;
  perform public.assert_own('assessments', p_assessment_id);
  select a.session_id, a.class_id, a.section_id, a.max_marks
    into v_session, v_class, v_section, v_max
  from public.assessments a where a.id = p_assessment_id;
  if v_session is null then raise exception 'Assessment not found'; end if;
  if not public.fn_may_manage_class(v_session, v_class, v_section) then
    raise exception 'You can only view tests for your assigned class';
  end if;

  return query
    select e.id, s.id, s.full_name, e.roll_no, sec.name,
           me.marks, coalesce(me.is_absent, false), coalesce(me.is_locked, false), v_max
    from public.enrollments e
    join public.students s on s.id = e.student_id
    left join public.sections sec on sec.id = e.section_id
    left join public.mark_entries me on me.assessment_id = p_assessment_id and me.enrollment_id = e.id
    where e.session_id = v_session and e.class_id = v_class and e.status = 'active' and s.deleted_at is null
      and (v_section is null or e.section_id = v_section)
    order by sec.sort_order nulls first,
             coalesce(nullif(regexp_replace(coalesce(e.roll_no, ''), '[^0-9]', '', 'g'), '')::int, 2147483647),
             s.full_name;
end;
$$;

create or replace function public.fn_enter_assessment_marks(p_assessment_id uuid, p_marks jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_actor  uuid := auth.uid();
  v_max    numeric;
  v_locked boolean;
  v_session uuid; v_class uuid; v_section uuid;
  v_total  integer;
  v_marked integer;
begin
  if not public.has_role('owner','principal','admin_clerk','class_teacher','subject_teacher') then
    raise exception 'Not permitted to enter marks';
  end if;
  if p_marks is null or jsonb_typeof(p_marks) <> 'array' then
    raise exception 'p_marks must be a JSON array';
  end if;
  select max_marks, is_locked, session_id, class_id, section_id
    into v_max, v_locked, v_session, v_class, v_section
  from public.assessments where id = p_assessment_id;
  if v_max is null then raise exception 'Assessment not found'; end if;
  if not public.fn_may_manage_class(v_session, v_class, v_section) then
    raise exception 'You can only enter marks for your assigned class';
  end if;
  if v_locked then raise exception 'This test is locked'; end if;
  if v_max <= 0 then raise exception 'Set the total marks for this test before entering scores'; end if;

  if exists (
    select 1 from jsonb_array_elements(p_marks) e
    where coalesce((e->>'is_absent')::boolean, false) = false
      and nullif(e->>'marks', '') is not null
      and ((e->>'marks')::numeric < 0 or (e->>'marks')::numeric > v_max)
  ) then
    raise exception 'Marks must be between 0 and %', v_max;
  end if;

  select count(distinct (e->>'enrollment_id')) into v_total from jsonb_array_elements(p_marks) e;

  with input as (
    select distinct on (enrollment_id) enrollment_id, marks, is_absent
    from (
      select (e->>'enrollment_id')::uuid as enrollment_id,
             nullif(e->>'marks', '')::numeric as marks,
             coalesce((e->>'is_absent')::boolean, false) as is_absent
      from jsonb_array_elements(p_marks) e
    ) q
    order by enrollment_id
  ),
  upserted as (
    insert into public.mark_entries as me (assessment_id, enrollment_id, marks, max_marks, is_absent, marked_by)
    select p_assessment_id, enrollment_id, marks, v_max, is_absent, v_actor from input
    on conflict (assessment_id, enrollment_id) where assessment_id is not null
    do update set marks = excluded.marks, is_absent = excluded.is_absent, marked_by = excluded.marked_by,
                  corrected_from = case when me.marks is distinct from excluded.marks then me.marks else me.corrected_from end
    where not me.is_locked
    returning 1
  )
  select count(*) into v_marked from upserted;

  return jsonb_build_object('marked', v_marked, 'skipped', v_total - v_marked, 'total', v_total);
end;
$$;

create or replace function public.fn_lock_assessment(p_assessment_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v_session uuid; v_class uuid; v_section uuid;
begin
  if not public.has_role('owner','principal','admin_clerk','class_teacher','subject_teacher') then
    raise exception 'Not permitted to lock this test';
  end if;
  perform public.assert_own('assessments', p_assessment_id);
  select session_id, class_id, section_id into v_session, v_class, v_section
  from public.assessments where id = p_assessment_id;
  if v_session is null then raise exception 'Assessment not found'; end if;
  if not public.fn_may_manage_class(v_session, v_class, v_section) then
    raise exception 'You can only lock tests for your assigned class';
  end if;
  update public.mark_entries set is_locked = true where assessment_id = p_assessment_id;
  update public.assessments set is_locked = true where id = p_assessment_id;
end;
$$;

-- ─────────────────────────────────────────────────────────────────────────
-- 0024_teacher_portal_hardening.sql
-- ─────────────────────────────────────────────────────────────────────────
-- =============================================================================
-- Hardening from the adversarial review of the teacher portal (0022/0023):
--   1. Scoping was only enforced inside the RPCs — but the blanket table grant
--      (0001) + role-only RLS let a teacher write attendance_daily / mark_entries
--      DIRECTLY via PostgREST, bypassing fn_may_manage_class. Revoke direct DML
--      so writes MUST go through the scoped SECURITY DEFINER functions.
--   2. profiles.staff_id became authorization-critical (my_staff_id → scope +
--      check-in identity), but guard_profile_role only protected `role`. A
--      teacher could repoint their own staff_id and inherit another teacher's
--      class + attendance identity. Guard staff_id too.
--   3. Test marks-entry now also validates every enrolment is in the test's class.
--   4. Check-in: use Pakistan time for "today" and make it race-safe.
--   5. Atomic class-teacher assignment (assignment row + class_teacher_id in one
--      transaction) and a backfill of existing class_teacher_id → assignments.
--   6. teacher_assignments is no longer world-readable.
-- =============================================================================

-- 1. Direct DML on the marked tables is revoked; the definer RPCs still work
--    (they run as the function owner and bypass grants + RLS).
revoke insert, update, delete on public.attendance_daily from authenticated;
revoke insert, update, delete on public.mark_entries    from authenticated;

-- 2. Guard staff_id like role — only owner/principal may change either.
create or replace function public.guard_profile_role() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.role is distinct from old.role and not public.has_role('owner', 'principal') then
    raise exception 'Only owner/principal may change a user role';
  end if;
  if new.staff_id is distinct from old.staff_id and not public.has_role('owner', 'principal') then
    raise exception 'Only owner/principal may relink a login to a staff record';
  end if;
  return new;
end;
$$;

-- 3. Test marks: reject/ignore any enrolment outside the test's class.
create or replace function public.fn_enter_assessment_marks(p_assessment_id uuid, p_marks jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_actor  uuid := auth.uid();
  v_max    numeric;
  v_locked boolean;
  v_session uuid; v_class uuid; v_section uuid;
  v_total  integer;
  v_marked integer;
begin
  if not public.has_role('owner','principal','admin_clerk','class_teacher','subject_teacher') then
    raise exception 'Not permitted to enter marks';
  end if;
  perform public.assert_own('assessments', p_assessment_id);
  if p_marks is null or jsonb_typeof(p_marks) <> 'array' then
    raise exception 'p_marks must be a JSON array';
  end if;
  select max_marks, is_locked, session_id, class_id, section_id
    into v_max, v_locked, v_session, v_class, v_section
  from public.assessments where id = p_assessment_id;
  if v_max is null then raise exception 'Assessment not found'; end if;
  if not public.fn_may_manage_class(v_session, v_class, v_section) then
    raise exception 'You can only enter marks for your assigned class';
  end if;
  if v_locked then raise exception 'This test is locked'; end if;
  if v_max <= 0 then raise exception 'Set the total marks for this test before entering scores'; end if;

  if exists (
    select 1 from jsonb_array_elements(p_marks) e
    where coalesce((e->>'is_absent')::boolean, false) = false
      and nullif(e->>'marks', '') is not null
      and ((e->>'marks')::numeric < 0 or (e->>'marks')::numeric > v_max)
  ) then
    raise exception 'Marks must be between 0 and %', v_max;
  end if;

  with input as (
    select distinct on (q.enrollment_id) q.enrollment_id, q.marks, q.is_absent
    from (
      select (e->>'enrollment_id')::uuid as enrollment_id,
             nullif(e->>'marks', '')::numeric as marks,
             coalesce((e->>'is_absent')::boolean, false) as is_absent
      from jsonb_array_elements(p_marks) e
    ) q
    -- only enrolments that actually belong to this test's class/section
    join public.enrollments en on en.id = q.enrollment_id
      and en.session_id = v_session and en.class_id = v_class
      and (v_section is null or en.section_id = v_section)
    order by q.enrollment_id
  ),
  upserted as (
    insert into public.mark_entries as me (assessment_id, enrollment_id, marks, max_marks, is_absent, marked_by)
    select p_assessment_id, enrollment_id, marks, v_max, is_absent, v_actor from input
    on conflict (assessment_id, enrollment_id) where assessment_id is not null
    do update set marks = excluded.marks, is_absent = excluded.is_absent, marked_by = excluded.marked_by,
                  corrected_from = case when me.marks is distinct from excluded.marks then me.marks else me.corrected_from end
    where not me.is_locked
    returning 1
  )
  select count(*) into v_marked from upserted;

  select count(distinct (e->>'enrollment_id')) into v_total from jsonb_array_elements(p_marks) e;
  return jsonb_build_object('marked', v_marked, 'skipped', v_total - v_marked, 'total', v_total);
end;
$$;

-- 4. Check-in: Pakistan-time "today" + race-safe insert.
create or replace function public.fn_staff_check_in(
  p_code text, p_lat double precision default null, p_lng double precision default null, p_device text default null
) returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_staff  uuid := public.my_staff_id();
  v_code   record;
  v_today  date := (now() at time zone 'Asia/Karachi')::date;
  v_exist  record;
  v_geo_on boolean; v_lat double precision; v_lng double precision; v_radius integer; v_dist double precision;
  v_new    uuid;
begin
  if auth.uid() is null then raise exception 'Not authenticated'; end if;
  if v_staff is null then
    raise exception 'Your login is not linked to a staff record — ask the principal to link it in Staff.';
  end if;

  -- Scope the lookup to the caller's school. Codes are only unique per school
  -- now, so without this a teacher could check in against another school's code
  -- — and `limit 1` would pick between duplicates arbitrarily.
  select * into v_code from public.staff_checkin_codes
   where code = p_code and active and school_id = public.current_school_id()
   limit 1;
  if not found then raise exception 'Invalid or inactive check-in code'; end if;
  if v_code.valid_from is not null and v_today < v_code.valid_from then raise exception 'This check-in code is not active yet'; end if;
  if v_code.valid_to  is not null and v_today > v_code.valid_to  then raise exception 'This check-in code has expired'; end if;

  select geofence_enabled, geo_lat, geo_lng, geo_radius_m
    into v_geo_on, v_lat, v_lng, v_radius from public.school_settings where school_id = public.current_school_id();
  if coalesce(v_geo_on, false) then
    if p_lat is null or p_lng is null then raise exception 'Location is required to check in — enable location and try again.'; end if;
    if v_lat is null or v_lng is null then raise exception 'School location is not set — ask the principal to set it in Settings.'; end if;
    v_dist := 2 * 6371000 * asin(least(1, sqrt(
      power(sin(radians((p_lat - v_lat) / 2)), 2)
      + cos(radians(v_lat)) * cos(radians(p_lat)) * power(sin(radians((p_lng - v_lng) / 2)), 2))));
    if v_dist > coalesce(v_radius, 200) then
      raise exception 'You are too far from the school to check in (about % m away).', round(v_dist);
    end if;
  end if;

  insert into public.staff_attendance(staff_id, attendance_date, status, checked_at, code_id, source, device)
  values (v_staff, v_today, 'present', now(), v_code.id, 'qr', nullif(btrim(p_device),''))
  on conflict (staff_id, attendance_date) do nothing
  returning id into v_new;

  if v_new is null then
    select * into v_exist from public.staff_attendance where staff_id = v_staff and attendance_date = v_today;
    return jsonb_build_object('status', 'already', 'checked_at', v_exist.checked_at, 'attendance_status', v_exist.status);
  end if;
  return jsonb_build_object('status', 'ok', 'checked_at', now());
end;
$$;

-- 5a. Atomic class-teacher assignment: assignment row + class_teacher_id mirror.
create or replace function public.fn_set_class_teacher(
  p_staff_id uuid, p_session_id uuid, p_class_id uuid, p_section_id uuid
) returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.has_role('owner','principal','admin_clerk') then
    raise exception 'Not permitted to assign class teachers';
  end if;
  -- Guard every id: the DELETE below is scoped only by session/class, so
  -- another school's ids would wipe their teacher assignments.
  perform public.assert_own('staff', p_staff_id);
  perform public.assert_own('academic_sessions', p_session_id);
  perform public.assert_own('classes', p_class_id);
  perform public.assert_own('sections', p_section_id);

  delete from public.teacher_assignments
   where session_id = p_session_id and class_id = p_class_id
     and section_id is not distinct from p_section_id;
  if p_section_id is not null then
    update public.sections set class_teacher_id = p_staff_id where id = p_section_id;
  end if;
  if p_staff_id is not null then
    insert into public.teacher_assignments(staff_id, session_id, class_id, section_id, created_by)
    values (p_staff_id, p_session_id, p_class_id, p_section_id, auth.uid())
    on conflict (staff_id, session_id, class_id, section_id) do nothing;
  end if;
end;
$$;

-- 5b. Backfill existing section class-teachers into assignments (current session),
--     so teachers assigned the old way keep working after this deploy.
insert into public.teacher_assignments(staff_id, session_id, class_id, section_id)
select sec.class_teacher_id, s.id, sec.class_id, sec.id
from public.sections sec
join public.academic_sessions s on s.is_current
where sec.class_teacher_id is not null
on conflict (staff_id, session_id, class_id, section_id) do nothing;

-- 6. teacher_assignments: admins see all; a teacher sees only their own.
drop policy if exists teacher_assign_select on public.teacher_assignments;
create policy teacher_assign_select on public.teacher_assignments for select to authenticated
  using (public.has_role('owner','principal','admin_clerk') or staff_id = public.my_staff_id());

grant execute on function public.fn_set_class_teacher(uuid, uuid, uuid, uuid) to authenticated;

-- ─────────────────────────────────────────────────────────────────────────
-- 0025_multi_tenancy.sql
-- ─────────────────────────────────────────────────────────────────────────
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

-- ─────────────────────────────────────────────────────────────────────────
-- 0026_subscriptions.sql
-- ─────────────────────────────────────────────────────────────────────────
-- =============================================================================
-- Subscriptions, trial, grace and the student-limit rule.
--
-- The commercial rules this encodes (agreed with the owner):
--
--   Plan          Students      Monthly    Yearly (2 months free)
--   starter       up to 200     Rs 3,500   Rs 35,000
--   growth        201-500       Rs 5,500   Rs 55,000
--   institution   501-1500      Rs 7,500   Rs 75,000
--   custom        1500+         negotiated
--
--   * 14-day free trial on every plan.
--   * When a period ends, the school gets a 14-day GRACE window in which the
--     app keeps working. This is not generosity — activation is manual after a
--     bank transfer, so without a grace window every renewal would take the
--     school offline between paying and being switched back on.
--   * After grace: LOCKED. Daily operations stop. Reads and export keep
--     working, always, so a school can never be held away from its own records.
--   * Going over the student limit NEVER blocks anything — see fn_my_licence.
-- =============================================================================

-- The margin tolerated above a plan's limit before the school is flagged.
-- 10%: 200 -> 220, 500 -> 550, 1500 -> 1650. (The owner's instinct was a
-- 20-student margin on the 200 plan, which is exactly 10% — this is that rule
-- generalised so it scales to every plan.)
create or replace function public.plan_margin_limit(p_limit integer) returns integer
language sql immutable as $$
  select case when p_limit is null then null else p_limit + ceil(p_limit * 0.10)::integer end;
$$;

-- Grace window after a period ends, in days.
create or replace function public.grace_days() returns integer
language sql immutable as $$ select 14 $$;

-- ---------------------------------------------------------------------------
-- Effective status
--
-- Stored status is what the platform last set; effective status is what the
-- calendar says now. Deriving it means a school does not silently stay 'active'
-- because a nightly job failed to run.
-- ---------------------------------------------------------------------------
create or replace function public.fn_effective_status(p_school_id uuid)
returns public.subscription_status
language sql stable security definer set search_path = public as $$
  select case
    when s.status = 'cancelled' then 'cancelled'::public.subscription_status
    -- Trial: live until it ends, then straight to locked (no grace on a trial —
    -- nothing has been paid, so there is no payment in flight to wait for).
    when s.status = 'trialing' then
      case when current_date <= coalesce(s.trial_ends_on, current_date)
           then 'trialing'::public.subscription_status
           else 'locked'::public.subscription_status end
    -- Paid: live to period_end, then grace, then locked.
    when s.period_end is null then s.status
    when current_date <= s.period_end then 'active'::public.subscription_status
    when current_date <= s.period_end + public.grace_days()
      then 'grace'::public.subscription_status
    else 'locked'::public.subscription_status
  end
  from public.subscriptions s
  where s.school_id = p_school_id;
$$;

-- ---------------------------------------------------------------------------
-- Student count
--
-- "Counted student" = an active enrolment in the school's current session.
-- Struck-off, withdrawn, graduated and soft-deleted students do not count.
-- This is deliberately the same number a principal would say out loud if asked
-- how many students they have, so a plan upgrade is never an argument about
-- whose definition applies.
-- ---------------------------------------------------------------------------
create or replace function public.fn_count_students(p_school_id uuid)
returns integer language sql stable security definer set search_path = public as $$
  select count(*)::integer
  from public.enrollments e
  join public.students s on s.id = e.student_id
  join public.academic_sessions ses on ses.id = e.session_id
  where e.school_id = p_school_id
    and ses.is_current
    and e.status = 'active'
    and s.status = 'active'
    and s.deleted_at is null;
$$;

-- Refresh the cached count and record a dated snapshot. Called nightly by the
-- platform (service role) and on demand. One snapshot per school per day.
create or replace function public.fn_refresh_student_count(p_school_id uuid)
returns integer language plpgsql security definer set search_path = public as $$
declare
  v_count  integer;
  v_plan   text;
  v_limit  integer;
  v_margin integer;
begin
  v_count := public.fn_count_students(p_school_id);

  select sub.plan_code, p.student_limit into v_plan, v_limit
  from public.subscriptions sub
  join public.plans p on p.code = sub.plan_code
  where sub.school_id = p_school_id;

  if v_plan is null then
    raise exception 'No subscription for school %', p_school_id;
  end if;

  v_margin := public.plan_margin_limit(v_limit);

  update public.subscriptions
     set student_count = v_count,
         counted_at    = now(),
         -- Flag on first crossing only, so the platform panel shows since when.
         over_limit_flagged_at = case
           when v_margin is not null and v_count > v_margin
             then coalesce(over_limit_flagged_at, now())
           else null
         end
   where school_id = p_school_id;

  insert into public.student_count_snapshots
    (school_id, counted_on, student_count, plan_code, student_limit)
  values (p_school_id, current_date, v_count, v_plan, v_limit)
  on conflict (school_id, counted_on) do update
    set student_count = excluded.student_count,
        plan_code     = excluded.plan_code,
        student_limit = excluded.student_limit;

  return v_count;
end;
$$;

-- Every school at once — the nightly job.
create or replace function public.fn_refresh_all_student_counts()
returns integer language plpgsql security definer set search_path = public as $$
declare r record; n integer := 0;
begin
  for r in select school_id from public.subscriptions loop
    perform public.fn_refresh_student_count(r.school_id);
    n := n + 1;
  end loop;
  return n;
end;
$$;

-- ---------------------------------------------------------------------------
-- The one call the app makes on startup.
--
-- Returns everything the UI needs to decide what to show: whether to run at
-- all, how long is left, and whether to show a limit notice. Note limit_state
-- is advisory ONLY — nothing in this file blocks adding a student. Admission is
-- when a school earns money; putting a locked door there would make us the
-- reason a parent walked out, which is not a position to negotiate a renewal
-- from.
-- ---------------------------------------------------------------------------
create or replace function public.fn_my_licence()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_school uuid := public.current_school_id();
  v_sub    record;
  v_plan   record;
  v_status public.subscription_status;
  v_margin integer;
  v_state  text;
  v_expiry date;
  v_days   integer;
begin
  if v_school is null then
    return jsonb_build_object('ok', false, 'reason', 'no_school');
  end if;

  select * into v_sub from public.subscriptions where school_id = v_school;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'no_subscription');
  end if;

  select * into v_plan from public.plans where code = v_sub.plan_code;
  v_status := public.fn_effective_status(v_school);
  v_margin := public.plan_margin_limit(v_plan.student_limit);

  -- Days remaining against whichever clock is running.
  v_expiry := case
    when v_status = 'trialing' then v_sub.trial_ends_on
    when v_status = 'active'   then v_sub.period_end
    when v_status = 'grace'    then v_sub.period_end + public.grace_days()
    else null end;
  v_days := case when v_expiry is null then null else (v_expiry - current_date) end;

  v_state := case
    when v_plan.student_limit is null then 'ok'          -- custom: no limit
    when v_sub.student_count <= v_plan.student_limit then 'ok'
    when v_sub.student_count <= v_margin then 'within_margin'
    else 'over' end;

  return jsonb_build_object(
    'ok',             true,
    'school_id',      v_school,
    'status',         v_status,
    'locked',         v_status = 'locked',
    -- Reading and exporting are never withdrawn, in any state.
    'can_read',       true,
    'can_export',     true,
    'can_operate',    v_status in ('trialing', 'active', 'grace'),
    'plan_code',      v_plan.code,
    'plan_name',      v_plan.name,
    'cycle',          v_sub.cycle,
    'price_monthly',  v_plan.price_monthly,
    'price_yearly',   v_plan.price_yearly,
    'expires_on',     v_expiry,
    'days_left',      v_days,
    'student_count',  v_sub.student_count,
    'student_limit',  v_plan.student_limit,
    'margin_limit',   v_margin,
    'limit_state',    v_state,
    -- Advisory only. The UI shows this to owner/principal, not to the clerk
    -- doing admissions, who can do nothing about it.
    'limit_notice',   case v_state
      when 'within_margin' then
        format('You have %s students. Your plan covers %s. You are still inside the allowance — nothing to do today.',
               v_sub.student_count, v_plan.student_limit)
      when 'over' then
        format('You have %s students, above the %s your plan covers. We will move you to the right plan at your next renewal — nothing stops working.',
               v_sub.student_count, v_plan.student_limit)
      else null end
  );
end;
$$;

grant execute on function public.fn_my_licence() to authenticated;
grant execute on function public.fn_effective_status(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- Enforcement
--
-- Locking is enforced in enforce_school_id(), which already runs BEFORE INSERT
-- OR UPDATE on every tenant table — so there is exactly one place where "is
-- this school allowed to write?" is decided, and no table can be forgotten.
--
-- What a locked school can still do: read everything, and export everything.
-- Those are SELECTs and never reach this trigger.
-- ---------------------------------------------------------------------------
create or replace function public.enforce_school_id() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  v_school uuid := public.current_school_id();
  v_status public.subscription_status;
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

  -- Subscription gate. Only applies to writes made by a signed-in user: the
  -- platform's own service-role paths have no school context and must keep
  -- working (that is how a school gets REACTIVATED after paying).
  if v_school is not null then
    v_status := public.fn_effective_status(new.school_id);
    if v_status in ('locked', 'cancelled') then
      raise exception
        'This school''s subscription has ended. Your records are safe and can still be viewed and exported — renew to start entering data again.'
        using errcode = '42501';
    end if;
  end if;

  return new;
end;
$$;

-- ---------------------------------------------------------------------------
-- Provisioning (service role only — no grant to authenticated).
-- Creates the school, its subscription and its 14-day trial in one step.
-- ---------------------------------------------------------------------------
create or replace function public.fn_provision_school(
  p_name text, p_plan_code text default 'starter', p_city text default null,
  p_contact_name text default null, p_contact_phone text default null,
  p_contact_email text default null
) returns jsonb language plpgsql security definer set search_path = public as $$
declare v_id uuid;
begin
  if nullif(btrim(p_name), '') is null then
    raise exception 'School name is required';
  end if;
  if not exists (select 1 from public.plans where code = p_plan_code) then
    raise exception 'Unknown plan %', p_plan_code;
  end if;

  insert into public.schools (name, city, contact_name, contact_phone, contact_email)
  values (btrim(p_name), p_city, p_contact_name, p_contact_phone, p_contact_email)
  returning id into v_id;

  insert into public.subscriptions (school_id, plan_code, status, trial_ends_on)
  values (v_id, p_plan_code, 'trialing', current_date + 14);

  return jsonb_build_object('school_id', v_id, 'trial_ends_on', current_date + 14);
end;
$$;

-- Activate or renew after a bank transfer clears. p_months: 1 or 12.
create or replace function public.fn_activate_subscription(
  p_school_id uuid, p_plan_code text, p_months integer default 12
) returns jsonb language plpgsql security definer set search_path = public as $$
declare v_start date; v_end date;
begin
  if not exists (select 1 from public.plans where code = p_plan_code) then
    raise exception 'Unknown plan %', p_plan_code;
  end if;
  if p_months is null or p_months < 1 then
    raise exception 'Months must be at least 1';
  end if;

  -- Renewing early extends from the existing end date rather than from today,
  -- so a school that pays a week ahead does not lose that week.
  select case
    when period_end is not null and period_end >= current_date
      then period_end + 1 else current_date end
  into v_start
  from public.subscriptions where school_id = p_school_id;

  if v_start is null then
    raise exception 'No subscription for school %', p_school_id;
  end if;
  v_end := (v_start + (p_months || ' months')::interval)::date - 1;

  update public.subscriptions
     set plan_code     = p_plan_code,
         status        = 'active',
         cycle         = case when p_months >= 12 then 'yearly' else 'monthly' end::public.billing_cycle,
         period_start  = v_start,
         period_end    = v_end,
         grace_ends_on = v_end + public.grace_days()
   where school_id = p_school_id;

  perform public.fn_refresh_student_count(p_school_id);

  return jsonb_build_object(
    'school_id', p_school_id, 'plan_code', p_plan_code,
    'period_start', v_start, 'period_end', v_end,
    'grace_ends_on', v_end + public.grace_days());
end;
$$;

-- The platform panel's worklist: who is expiring, who is over their limit, and
-- what plan each school should be on at renewal given its real student count.
create or replace function public.fn_platform_schools()
returns table(
  school_id uuid, school_name text, city text, contact_phone text,
  plan_code text, status public.subscription_status, expires_on date,
  days_left integer, student_count integer, student_limit integer,
  limit_state text, suggested_plan text
) language sql stable security definer set search_path = public as $$
  select
    s.id, s.name, s.city, s.contact_phone,
    sub.plan_code,
    public.fn_effective_status(s.id),
    case
      when sub.status = 'trialing' then sub.trial_ends_on
      else sub.period_end end,
    case
      when sub.status = 'trialing' then sub.trial_ends_on - current_date
      else sub.period_end - current_date end,
    sub.student_count,
    p.student_limit,
    case
      when p.student_limit is null then 'ok'
      when sub.student_count <= p.student_limit then 'ok'
      when sub.student_count <= public.plan_margin_limit(p.student_limit) then 'within_margin'
      else 'over' end,
    (select p2.code from public.plans p2
      where p2.active and (p2.student_limit is null or p2.student_limit >= sub.student_count)
      order by p2.sort_order limit 1)
  from public.schools s
  join public.subscriptions sub on sub.school_id = s.id
  join public.plans p on p.code = sub.plan_code
  order by s.name;
$$;

-- ─────────────────────────────────────────────────────────────────────────
-- 0027_platform_admin.sql
-- ─────────────────────────────────────────────────────────────────────────
-- =============================================================================
-- Platform administration — the product owner's side of the system.
--
-- A platform admin manages SCHOOLS (who exists, who has paid, who is over their
-- limit). They deliberately get NO access to tenant data: no student records,
-- no fee ledgers, no marks. Running the business does not require reading a
-- child's records, and a "god mode" that could is a permanent hole — one
-- compromised platform login would otherwise expose every school at once.
--
-- So the policies added here are on PLATFORM tables only. Nothing in this file
-- widens access to a tenant table, and tenant_isolation.sql fails the build if
-- anything ever does.
-- =============================================================================

create table public.platform_admins (
  user_id    uuid primary key references auth.users(id) on delete cascade,
  email      text,
  note       text,
  created_at timestamptz not null default now()
);

alter table public.platform_admins enable row level security;

-- SECURITY DEFINER so a policy calling it does not recurse through this table's
-- own RLS — same reasoning as has_role() and current_school_id().
create or replace function public.is_platform_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.platform_admins where user_id = auth.uid());
$$;

grant execute on function public.is_platform_admin() to authenticated;
grant select on public.platform_admins to authenticated;

-- An admin may see that they are one. Membership is granted only by service
-- role — there is no way to make yourself a platform admin from the app.
create policy platform_admins_self on public.platform_admins for select to authenticated
  using (user_id = auth.uid());

-- ---------------------------------------------------------------------------
-- Platform reach over the platform tables (not tenant tables)
-- ---------------------------------------------------------------------------
create policy schools_select_platform on public.schools for select to authenticated
  using (public.is_platform_admin());
create policy schools_update_platform on public.schools for update to authenticated
  using (public.is_platform_admin()) with check (public.is_platform_admin());

create policy subscriptions_select_platform on public.subscriptions for select to authenticated
  using (public.is_platform_admin());

create policy snapshots_select_platform on public.student_count_snapshots for select to authenticated
  using (public.is_platform_admin());

-- ---------------------------------------------------------------------------
-- Guard the platform functions, then expose them.
--
-- These were service-role only. Gating each on is_platform_admin() lets the
-- admin panel call them directly with the caller's own JWT, so the service_role
-- key stays out of anything a browser can reach. Only user CREATION still needs
-- an Edge Function, because minting an auth user requires the service key.
-- ---------------------------------------------------------------------------

create or replace function public.fn_provision_school(
  p_name text, p_plan_code text default 'starter', p_city text default null,
  p_contact_name text default null, p_contact_phone text default null,
  p_contact_email text default null
) returns jsonb language plpgsql security definer set search_path = public as $$
declare v_id uuid;
begin
  if not public.is_platform_admin() then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  if nullif(btrim(p_name), '') is null then
    raise exception 'School name is required';
  end if;
  if not exists (select 1 from public.plans where code = p_plan_code) then
    raise exception 'Unknown plan %', p_plan_code;
  end if;

  insert into public.schools (name, city, contact_name, contact_phone, contact_email)
  values (btrim(p_name), p_city, p_contact_name, p_contact_phone, p_contact_email)
  returning id into v_id;

  insert into public.subscriptions (school_id, plan_code, status, trial_ends_on)
  values (v_id, p_plan_code, 'trialing', current_date + 14);

  return jsonb_build_object('school_id', v_id, 'trial_ends_on', current_date + 14);
end;
$$;

create or replace function public.fn_activate_subscription(
  p_school_id uuid, p_plan_code text, p_months integer default 12
) returns jsonb language plpgsql security definer set search_path = public as $$
declare v_start date; v_end date;
begin
  if not public.is_platform_admin() then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  if not exists (select 1 from public.plans where code = p_plan_code) then
    raise exception 'Unknown plan %', p_plan_code;
  end if;
  if p_months is null or p_months < 1 then
    raise exception 'Months must be at least 1';
  end if;

  -- Renewing early extends from the existing end date rather than from today,
  -- so a school that pays a week ahead does not lose that week.
  select case
    when period_end is not null and period_end >= current_date
      then period_end + 1 else current_date end
  into v_start
  from public.subscriptions where school_id = p_school_id;

  if v_start is null then
    raise exception 'No subscription for school %', p_school_id;
  end if;
  v_end := (v_start + (p_months || ' months')::interval)::date - 1;

  update public.subscriptions
     set plan_code     = p_plan_code,
         status        = 'active',
         cycle         = case when p_months >= 12 then 'yearly' else 'monthly' end::public.billing_cycle,
         period_start  = v_start,
         period_end    = v_end,
         grace_ends_on = v_end + public.grace_days()
   where school_id = p_school_id;

  perform public.fn_refresh_student_count(p_school_id);

  return jsonb_build_object(
    'school_id', p_school_id, 'plan_code', p_plan_code,
    'period_start', v_start, 'period_end', v_end,
    'grace_ends_on', v_end + public.grace_days());
end;
$$;

-- Give a school that is genuinely mid-setup more trial. Deliberately capped:
-- an unbounded "extend" button turns into a free tier by accident.
create or replace function public.fn_extend_trial(p_school_id uuid, p_days integer default 14)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_new date;
begin
  if not public.is_platform_admin() then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  if p_days is null or p_days < 1 or p_days > 30 then
    raise exception 'Extension must be between 1 and 30 days';
  end if;

  update public.subscriptions
     set trial_ends_on = greatest(coalesce(trial_ends_on, current_date), current_date) + p_days,
         status = 'trialing'
   where school_id = p_school_id
     and status in ('trialing', 'locked')
  returning trial_ends_on into v_new;

  if v_new is null then
    raise exception 'Only a school still on trial can have its trial extended';
  end if;
  return jsonb_build_object('school_id', p_school_id, 'trial_ends_on', v_new);
end;
$$;

-- Dropped first: 0026's version returned a different column set, and Postgres
-- will not replace a set-returning function whose OUT parameters changed.
drop function if exists public.fn_platform_schools();

create or replace function public.fn_platform_schools()
returns table(
  school_id uuid, school_name text, city text, contact_name text, contact_phone text,
  plan_code text, status public.subscription_status, expires_on date,
  days_left integer, student_count integer, student_limit integer,
  limit_state text, suggested_plan text, needs_upgrade boolean
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
      sug.code is distinct from sub.plan_code
    from public.schools s
    join public.subscriptions sub on sub.school_id = s.id
    join public.plans p on p.code = sub.plan_code
    cross join lateral (
      select p2.code from public.plans p2
       where p2.active and (p2.student_limit is null or p2.student_limit >= sub.student_count)
       order by p2.sort_order limit 1
    ) sug
    order by s.name;
end;
$$;

-- ---------------------------------------------------------------------------
-- Public signup path.
--
-- The unguarded twin of fn_provision_school, for the signup-school Edge
-- Function. It is NEVER granted to anon or authenticated — only the service
-- role can reach it — so a school can be created by the signup flow but not by
-- anything a browser can call directly.
-- ---------------------------------------------------------------------------
create or replace function public.fn_signup_school(
  p_name text, p_city text default null, p_contact_name text default null,
  p_contact_phone text default null, p_contact_email text default null
) returns jsonb language plpgsql security definer set search_path = public as $$
declare v_id uuid;
begin
  if nullif(btrim(p_name), '') is null then
    raise exception 'School name is required';
  end if;

  insert into public.schools (name, city, contact_name, contact_phone, contact_email)
  values (btrim(p_name), p_city, p_contact_name, p_contact_phone, p_contact_email)
  returning id into v_id;

  insert into public.subscriptions (school_id, plan_code, status, trial_ends_on)
  values (v_id, 'starter', 'trialing', current_date + 14);

  return jsonb_build_object('school_id', v_id, 'trial_ends_on', current_date + 14);
end;
$$;

revoke execute on function public.fn_signup_school(text, text, text, text, text) from public, anon, authenticated;

-- Recount every school on demand (the panel's refresh button). Deliberately a
-- separate guarded entry point rather than granting fn_refresh_student_count
-- itself: that one takes a school_id and returns a count, so exposing it would
-- let any signed-in user probe for valid school ids and read their sizes.
create or replace function public.fn_platform_refresh_counts()
returns integer language plpgsql security definer set search_path = public as $$
begin
  if not public.is_platform_admin() then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  return public.fn_refresh_all_student_counts();
end;
$$;

grant execute on function public.fn_provision_school(text, text, text, text, text, text) to authenticated;
grant execute on function public.fn_activate_subscription(uuid, text, integer) to authenticated;
grant execute on function public.fn_extend_trial(uuid, integer) to authenticated;
grant execute on function public.fn_platform_schools() to authenticated;
grant execute on function public.fn_platform_refresh_counts() to authenticated;

-- ─────────────────────────────────────────────────────────────────────────
-- 0028_pricing.sql
-- ─────────────────────────────────────────────────────────────────────────
-- =============================================================================
-- Repricing to the published Pakistani market rates.
--
-- The original tiers (Rs 3,500 for 200 students) put us at the most expensive
-- entry point in the market while demoing fewer features than the incumbents.
-- These are the rates we go to market with:
--
--   Starter      up to   100 students   Rs   950 / month
--   Growth       up to   300 students   Rs 2,000 / month
--   Institution  up to 1,000 students   Rs 3,500 / month
--   Custom       above 1,000 students   quoted, contact us
--
-- Yearly stays at 10x monthly ("two months free"), matching how schools
-- actually budget — one payment at session start out of admission income.
--
-- There is deliberately NO free tier. A free plan would have to be enforced,
-- supported and migrated off, and it attracts schools that never convert. The
-- 14-day trial already removes the risk of buying blind.
--
-- Plan CODES are unchanged on purpose: subscriptions.plan_code references
-- plans(code), so renaming would orphan every existing school. Only the
-- student_limit, prices and display names move.
-- =============================================================================

update public.plans set
  name          = 'Starter (up to 100 students)',
  student_limit = 100,
  price_monthly = 950,
  price_yearly  = 9500
where code = 'starter';

update public.plans set
  name          = 'Growth (101-300 students)',
  student_limit = 300,
  price_monthly = 2000,
  price_yearly  = 20000
where code = 'growth';

update public.plans set
  name          = 'Institution (301-1000 students)',
  student_limit = 1000,
  price_monthly = 3500,
  price_yearly  = 35000
where code = 'institution';

update public.plans set
  name          = 'Custom (1000+ students - contact us)',
  student_limit = null,
  price_monthly = 0,
  price_yearly  = 0
where code = 'custom';

-- Schools already on a plan whose limit just shrank are NOT downgraded, moved,
-- or blocked. The soft-limit rule stands: going over the limit flags the school
-- on the operator console and never blocks an admission. Re-flag them so the
-- console shows the truth on the next refresh rather than after their next
-- admission.
--
-- fn_platform_refresh_counts() is the guarded entry point and would raise here
-- (a migration has no platform-admin identity), so call the internal directly.
select public.fn_refresh_all_student_counts();

-- ─────────────────────────────────────────────────────────────────────────
-- 0029_families.sql
-- ─────────────────────────────────────────────────────────────────────────
-- =============================================================================
-- Family billing — the student keeps the ledger, the family holds the wallet.
--
-- Design and rationale: docs/10-MONEY-ENGINE-V2.md
--
-- A father with three children in the school hands over one bundle of cash.
-- Until now that was three transactions, three receipt numbers and three
-- pieces of paper, because fn_record_payment took a single student_id.
--
-- What changes:
--   * `families` is the payer. Every student belongs to exactly one.
--   * A payment belongs to a FAMILY and is allocated across whichever
--     children's invoices it clears — oldest month first, across siblings.
--   * Money that clears no invoice is FAMILY CREDIT: explicit, queryable and
--     reportable, instead of an unexplained negative student balance.
--
-- What deliberately does NOT change:
--   * Invoices stay per student. Charges, discounts, fines, adjustments and
--     arrears are untouched, so every existing report keeps working.
--   * `guardians` stays as-is. It holds the contact people (father, mother,
--     the uncle who does pickup). `families` is the BILLING entity. Conflating
--     the two would be a mistake — the person who pays and the people you ring
--     are different sets.
--
-- THE ONE BEHAVIOUR CHANGE, stated loudly because it is deliberate:
--
--   student_balance() used to subtract `sum(payments where student_id = X)`.
--   Once a payment can span three children that is simply wrong — the money
--   belongs to the invoices it cleared, not to any one child. It now subtracts
--   the ALLOCATIONS against that student's invoices.
--
--   For a fully-allocated single-student payment the two are identical, and
--   the test suite proves it. They differ for an OVERPAYMENT: the old rule
--   drove the student's balance negative, the new rule takes the student to
--   zero and parks the remainder as family credit. That is the fix, not a
--   regression — "how much advance is this parent holding?" was previously
--   unanswerable.
--
--   Conservation still holds:
--     family_outstanding = sum(student_balance of members) - family_credit
-- =============================================================================

-- ===========================================================================
-- 1. The payer
-- ===========================================================================

create table public.families (
  id            uuid primary key default gen_random_uuid(),
  school_id     uuid not null references public.schools(id) on delete cascade,
  head_name     text not null,                 -- "Muhammad Aslam"
  head_cnic     text,                          -- the natural key at the counter
  phone         text,
  whatsapp      text,
  address       text,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);

create trigger trg_families_updated before update on public.families
  for each row execute function public.set_updated_at();

-- CNIC is unique per school when present. Nullable because plenty of schools
-- never collect it, and a NOT NULL here would block admission.
create unique index uq_families_school_cnic
  on public.families (school_id, head_cnic) where head_cnic is not null;
create index idx_families_school on public.families (school_id);
create index idx_families_phone  on public.families (school_id, phone);

alter table public.students add column family_id uuid references public.families(id);
create index idx_students_family on public.students (family_id);

-- ===========================================================================
-- 2. Backfill: one family per existing student, from the primary guardian
--
-- Deliberately NOT merged on a name match. Merging two families is
-- destructive — it moves money between ledgers — so existing schools get
-- one family per student and fn_link_students (which already detects
-- siblings) proposes merges a human confirms.
-- ===========================================================================

do $$
declare v_s record; v_f uuid;
begin
  for v_s in
    select s.id, s.school_id, s.full_name,
           (select g.name from public.guardians g
            where g.student_id = s.id order by g.is_primary desc, g.created_at limit 1) as g_name,
           (select g.phone from public.guardians g
            where g.student_id = s.id order by g.is_primary desc, g.created_at limit 1) as g_phone,
           (select g.whatsapp from public.guardians g
            where g.student_id = s.id order by g.is_primary desc, g.created_at limit 1) as g_wa
    from public.students s
    where s.family_id is null
  loop
    insert into public.families (school_id, head_name, phone, whatsapp)
    values (v_s.school_id,
            coalesce(nullif(btrim(coalesce(v_s.g_name, '')), ''), v_s.full_name || ' (family)'),
            v_s.g_phone, v_s.g_wa)
    returning id into v_f;

    update public.students set family_id = v_f where id = v_s.id;
  end loop;
end $$;

-- ===========================================================================
-- 3. Payments belong to a family
-- ===========================================================================

alter table public.payments add column family_id uuid references public.families(id);

update public.payments p
   set family_id = s.family_id
  from public.students s
 where s.id = p.student_id and p.family_id is null;

-- student_id stays, now nullable: it is set for a single-student payment (so a
-- receipt can still say "this was for Ahmed") and null for a family payment,
-- where the children are derived from the allocations.
alter table public.payments alter column student_id drop not null;
alter table public.payments
  add constraint payments_has_payer check (family_id is not null or student_id is not null);
create index idx_payments_family on public.payments (family_id);

-- ===========================================================================
-- 4. Tenant plumbing for the new table
-- ===========================================================================

create trigger trg_families_school before insert or update on public.families
  for each row execute function public.enforce_school_id();

create trigger trg_audit_families after insert or update or delete on public.families
  for each row execute function public.audit_trigger();

alter table public.families enable row level security;

-- Readable by any signed-in member of the school (the family shows on a
-- student profile). Writable by the roles that admit students and take money.
create policy families_select on public.families for select to authenticated
  using (school_id = public.current_school_id());
create policy families_insert on public.families for insert to authenticated
  with check (school_id = public.current_school_id()
              and public.has_role('owner', 'principal', 'admin_clerk', 'accountant'));
create policy families_update on public.families for update to authenticated
  using (school_id = public.current_school_id()
         and public.has_role('owner', 'principal', 'admin_clerk', 'accountant'))
  with check (school_id = public.current_school_id());

-- ===========================================================================
-- 5. The shared allocator
--
-- One implementation, used by every path that puts money against invoices:
-- single-student payment, family payment, verifying a pending payment, and
-- applying credit. Having three copies of a FIFO loop was how the old code
-- drifted; there is now exactly one.
--
-- Order is oldest period first, then student, then invoice — deterministic, so
-- the same payment always lands the same way and a test can assert it.
-- ===========================================================================

create or replace function public.fn__allocate_payment(
  p_payment_id uuid, p_student_ids uuid[], p_amount numeric
) returns numeric language plpgsql security definer set search_path = public as $$
declare
  v_remaining numeric := p_amount;
  v_alloc     numeric;
  v_rec       record;
begin
  for v_rec in
    select b.invoice_id, (b.charge - b.allocated) as outstanding
    from public.invoice_balances b
    join public.invoices i on i.id = b.invoice_id
    where b.student_id = any(p_student_ids)
      and b.status in ('issued', 'partial')
      and (b.charge - b.allocated) > 0
    order by i.period_month nulls first, b.student_id, b.invoice_id
  loop
    exit when v_remaining <= 0;
    v_alloc := least(v_remaining, v_rec.outstanding);

    insert into public.payment_allocations(payment_id, invoice_id, amount)
    values (p_payment_id, v_rec.invoice_id, v_alloc);
    v_remaining := v_remaining - v_alloc;

    update public.invoices i set status = (case
      when (select allocated from public.invoice_balances b2 where b2.invoice_id = i.id)
           >= (select charge from public.invoice_balances b2 where b2.invoice_id = i.id)
      then 'paid' else 'partial' end)::public.invoice_status
    where i.id = v_rec.invoice_id;
  end loop;

  return v_remaining;   -- what stayed unallocated; the family keeps it as credit
end;
$$;

-- ===========================================================================
-- 6. Balances
-- ===========================================================================

-- Payments now come from ALLOCATIONS. See the header for why, and for the one
-- behaviour change (overpayment no longer drives a student negative).
create or replace function public.student_balance(p_student_id uuid)
returns numeric language sql stable security invoker set search_path = public as $$
  select
    coalesce((
      select sum(case when l.is_discount then -l.amount else l.amount end)
      from public.invoice_lines l
      join public.invoices i on i.id = l.invoice_id
      where i.student_id = p_student_id and i.status <> 'void'
    ), 0)
    + coalesce((
      select sum(i.fine) from public.invoices i
      where i.student_id = p_student_id and i.status <> 'void'
    ), 0)
    + coalesce((
      select sum(a.amount) from public.adjustments a
      where a.student_id = p_student_id
    ), 0)
    - coalesce((
      select sum(al.amount)
      from public.payment_allocations al
      join public.invoices i2 on i2.id = al.invoice_id
      join public.payments p on p.id = al.payment_id
      where i2.student_id = p_student_id and p.status = 'verified'
    ), 0);
$$;

-- Money received from this family that has not been applied to any invoice.
-- Reversals carry negative amounts and negative allocations, so they net out.
create or replace function public.family_credit(p_family_id uuid)
returns numeric language sql stable security invoker set search_path = public as $$
  select greatest(coalesce((
    select sum(p.amount - coalesce(a.alloc, 0))
    from public.payments p
    left join lateral (
      select sum(al.amount) as alloc
      from public.payment_allocations al
      where al.payment_id = p.id
    ) a on true
    where p.family_id = p_family_id and p.status = 'verified'
  ), 0), 0);
$$;

-- What the family actually owes, net of anything they are holding on account.
create or replace function public.family_outstanding(p_family_id uuid)
returns numeric language sql stable security invoker set search_path = public as $$
  select coalesce((
    select sum(public.student_balance(s.id))
    from public.students s where s.family_id = p_family_id
  ), 0) - public.family_credit(p_family_id);
$$;

-- ===========================================================================
-- 7. Finding the payer at the counter
--
-- One search box resolving CNIC / phone / head name / student name / GR to a
-- family. Fifteen seconds is the target for the whole interaction; making the
-- clerk pick the right search mode first is how you lose ten of them.
-- ===========================================================================

create or replace function public.fn_find_family(p_query text)
returns table (
  family_id uuid, head_name text, head_cnic text, phone text,
  children integer, outstanding numeric, credit numeric
) language sql stable security invoker set search_path = public as $$
  with q as (select trim(coalesce(p_query, '')) as t)
  select f.id, f.head_name, f.head_cnic, f.phone,
         (select count(*)::integer from public.students s where s.family_id = f.id),
         public.family_outstanding(f.id),
         public.family_credit(f.id)
  from public.families f, q
  where q.t <> ''
    -- Explicit tenant filter, NOT just RLS. This function is SECURITY INVOKER
    -- so RLS does cover it today, but a search that leaks every school's
    -- parents is too dangerous to leave resting on one mechanism — and if
    -- anyone ever marks it SECURITY DEFINER, RLS stops applying silently.
    and f.school_id = public.current_school_id()
    and (
      f.head_cnic = q.t
      or replace(coalesce(f.head_cnic, ''), '-', '') = replace(q.t, '-', '')
      or f.phone like '%' || q.t || '%'
      or f.head_name ilike '%' || q.t || '%'
      or exists (
        select 1 from public.students s
        where s.family_id = f.id
          and (s.full_name ilike '%' || q.t || '%' or s.gr_no = q.t)
      )
    )
  order by f.head_name
  limit 25;
$$;

-- The family sheet: every child, what each owes, and what the family holds.
create or replace function public.fn_family_sheet(p_family_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_out jsonb;
begin
  if not public.has_role('owner','principal','admin_clerk','accountant','readonly') then
    raise exception 'Not permitted to view fee records';
  end if;
  perform public.assert_own('families', p_family_id);

  select jsonb_build_object(
    'family', to_jsonb(f) - 'school_id',
    'credit', public.family_credit(f.id),
    'outstanding', public.family_outstanding(f.id),
    'children', coalesce((
      select jsonb_agg(jsonb_build_object(
        'student_id', s.id,
        'full_name',  s.full_name,
        'gr_no',      s.gr_no,
        'status',     s.status,
        'balance',    public.student_balance(s.id),
        'invoices',   coalesce((
          select jsonb_agg(jsonb_build_object(
            'invoice_id',   b.invoice_id,
            'period_month', i.period_month,
            'due_date',     i.due_date,
            'charge',       b.charge,
            'allocated',    b.allocated,
            'outstanding',  b.charge - b.allocated,
            'status',       b.status
          ) order by i.period_month nulls first)
          from public.invoice_balances b
          join public.invoices i on i.id = b.invoice_id
          where b.student_id = s.id and b.status in ('issued', 'partial')
            and b.charge - b.allocated > 0
        ), '[]'::jsonb)
      ) order by s.full_name)
      from public.students s where s.family_id = f.id
    ), '[]'::jsonb)
  ) into v_out
  from public.families f where f.id = p_family_id;

  if v_out is null then raise exception 'Family not found'; end if;
  return v_out;
end;
$$;

-- ===========================================================================
-- 8. Taking the money
-- ===========================================================================

-- One payment, one gapless receipt, allocated across every child in the family.
create or replace function public.fn_record_family_payment(
  p_family_id uuid, p_amount numeric, p_method public.payment_method,
  p_note text default null, p_pending boolean default false
) returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_actor    uuid := auth.uid();
  v_receipt  bigint;
  v_pay      uuid;
  v_students uuid[];
  v_left     numeric;
begin
  if not public.has_role('owner','principal','admin_clerk','accountant') then
    raise exception 'Not permitted to record payments';
  end if;
  if p_amount is null or p_amount <= 0 then raise exception 'Amount must be positive'; end if;
  perform public.assert_own('families', p_family_id);

  select array_agg(id) into v_students from public.students where family_id = p_family_id;
  if v_students is null then raise exception 'This family has no students'; end if;

  v_receipt := public.next_counter('receipt');
  insert into public.payments(family_id, student_id, amount, method, receipt_no,
                              status, received_by, note)
  values (p_family_id, null, p_amount, p_method, v_receipt,
          case when p_pending then 'pending' else 'verified' end, v_actor, p_note)
  returning id into v_pay;

  -- A pending payment (a bank challan not yet cleared) holds a receipt number
  -- but is not counted and not allocated until it is verified.
  if p_pending then
    return jsonb_build_object('payment_id', v_pay, 'receipt_no', v_receipt,
      'allocated', 0, 'credit', 0, 'pending', true);
  end if;

  v_left := public.fn__allocate_payment(v_pay, v_students, p_amount);

  return jsonb_build_object(
    'payment_id', v_pay, 'receipt_no', v_receipt,
    'allocated', p_amount - v_left,
    'credit', v_left,                       -- stays with the family, on account
    'family_outstanding', public.family_outstanding(p_family_id),
    'pending', false);
end;
$$;

-- The single-student path, rewritten onto the shared allocator. Semantics are
-- unchanged: it allocates only to THAT student's invoices, never a sibling's.
create or replace function public.fn_record_payment(
  p_student_id uuid, p_amount numeric, p_method public.payment_method,
  p_note text default null, p_pending boolean default false
) returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_actor   uuid := auth.uid();
  v_receipt bigint;
  v_pay     uuid;
  v_family  uuid;
  v_left    numeric;
begin
  if not public.has_role('owner','principal','admin_clerk','accountant') then
    raise exception 'Not permitted to record payments';
  end if;
  if p_amount is null or p_amount <= 0 then raise exception 'Amount must be positive'; end if;
  perform public.assert_own('students', p_student_id);

  select family_id into v_family from public.students where id = p_student_id;

  v_receipt := public.next_counter('receipt');
  insert into public.payments(student_id, family_id, amount, method, receipt_no,
                              status, received_by, note)
  values (p_student_id, v_family, p_amount, p_method, v_receipt,
          case when p_pending then 'pending' else 'verified' end, v_actor, p_note)
  returning id into v_pay;

  if p_pending then
    return jsonb_build_object('payment_id', v_pay, 'receipt_no', v_receipt,
      'allocated', 0, 'unallocated', p_amount, 'pending', true);
  end if;

  v_left := public.fn__allocate_payment(v_pay, array[p_student_id], p_amount);

  return jsonb_build_object(
    'payment_id', v_pay, 'receipt_no', v_receipt,
    'allocated', p_amount - v_left, 'unallocated', v_left, 'pending', false);
end;
$$;

-- Verifying a cleared challan allocates the same way the original would have,
-- across the family when it was a family payment.
create or replace function public.fn_verify_payment(p_payment_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_pay      record;
  v_students uuid[];
  v_left     numeric;
begin
  if not public.has_role('owner','principal','admin_clerk','accountant') then
    raise exception 'Not permitted to verify payments';
  end if;
  perform public.assert_own('payments', p_payment_id);
  select * into v_pay from public.payments where id = p_payment_id for update;
  if not found then raise exception 'Payment not found'; end if;
  if v_pay.status <> 'pending' then raise exception 'Only a pending payment can be verified'; end if;

  update public.payments set status = 'verified' where id = p_payment_id;

  if v_pay.student_id is not null then
    v_students := array[v_pay.student_id];
  else
    select array_agg(id) into v_students from public.students where family_id = v_pay.family_id;
  end if;

  v_left := public.fn__allocate_payment(p_payment_id, coalesce(v_students, '{}'::uuid[]), v_pay.amount);

  return jsonb_build_object('payment_id', p_payment_id,
    'allocated', v_pay.amount - v_left, 'unallocated', v_left);
end;
$$;

-- Reversal must carry the family across, or the reversing entry would not
-- cancel out of family_credit and the wallet would drift.
create or replace function public.fn_reverse_payment(p_payment_id uuid, p_reason text)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  v_actor   uuid := auth.uid();
  v_orig    record;
  v_a       record;
  v_rev     uuid;
  v_receipt bigint;
begin
  if not public.has_role('owner', 'principal') then
    raise exception 'Only owner/principal may reverse a payment';
  end if;
  perform public.assert_own('payments', p_payment_id);
  select * into v_orig from public.payments where id = p_payment_id;
  if not found then raise exception 'Payment not found'; end if;
  if v_orig.status <> 'verified' then
    raise exception 'Only a verified payment can be reversed (pending/cancelled payments are handled in the Pending tab)';
  end if;
  if v_orig.reversal_of is not null then raise exception 'Cannot reverse a reversal'; end if;
  if exists (select 1 from public.payments where reversal_of = p_payment_id) then
    raise exception 'Payment already reversed';
  end if;

  v_receipt := public.next_counter('receipt');
  insert into public.payments(student_id, family_id, amount, method, receipt_no,
                              status, received_by, reversal_of, note)
  values (v_orig.student_id, v_orig.family_id, -v_orig.amount, v_orig.method, v_receipt,
          'verified', v_actor, p_payment_id, coalesce(p_reason, 'reversal'))
  returning id into v_rev;

  for v_a in select * from public.payment_allocations where payment_id = p_payment_id loop
    insert into public.payment_allocations(payment_id, invoice_id, amount)
    values (v_rev, v_a.invoice_id, -v_a.amount);
    update public.invoices i set status = (case
      when (select allocated from public.invoice_balances b where b.invoice_id = i.id) <= 0 then 'issued'
      when (select allocated from public.invoice_balances b where b.invoice_id = i.id)
           >= (select charge from public.invoice_balances b where b.invoice_id = i.id) then 'paid'
      else 'partial' end)::public.invoice_status
    where i.id = v_a.invoice_id;
  end loop;

  return v_rev;
end;
$$;

-- ===========================================================================
-- 9. Credit meets the next challan
--
-- A family holding credit must not appear on the defaulter list. Left
-- unapplied, the list shows families who have already paid, and a list nobody
-- trusts is a list nobody reads. So generation applies credit immediately.
-- ===========================================================================

create or replace function public.fn_apply_family_credit(p_family_id uuid)
returns numeric language plpgsql security definer set search_path = public as $$
declare
  v_students uuid[];
  v_pay      record;
  v_left     numeric;
  v_applied  numeric := 0;
begin
  select array_agg(id) into v_students from public.students where family_id = p_family_id;
  if v_students is null then return 0; end if;

  -- Walk the family's payments oldest first, topping up each one's allocations
  -- until its own unallocated remainder is spent. Allocation rows stay tied to
  -- the payment that actually brought the money in, so a receipt reprint and a
  -- reversal both still reconcile.
  for v_pay in
    select p.id, p.amount - coalesce((
             select sum(al.amount) from public.payment_allocations al
             where al.payment_id = p.id), 0) as unallocated
    from public.payments p
    where p.family_id = p_family_id and p.status = 'verified'
    order by p.created_at, p.id
  loop
    if v_pay.unallocated > 0 then
      v_left := public.fn__allocate_payment(v_pay.id, v_students, v_pay.unallocated);
      v_applied := v_applied + (v_pay.unallocated - v_left);
    end if;
  end loop;

  return v_applied;
end;
$$;

-- Generation now settles credit for every family it billed.
create or replace function public.fn_generate_class_invoices(
  p_session_id uuid, p_class_id uuid, p_period_month date, p_due_date date
) returns integer language plpgsql security definer set search_path = public as $$
declare
  v_actor    uuid := auth.uid();
  v_enr      record;
  v_inv      uuid;
  v_count    integer := 0;
  v_arrears  numeric;
  v_tuition  numeric;
  v_families uuid[] := '{}';
  v_fam      uuid;
begin
  if not public.has_role('owner', 'principal', 'admin_clerk', 'accountant') then
    raise exception 'Not permitted to generate invoices';
  end if;
  perform public.assert_own('academic_sessions', p_session_id);
  perform public.assert_own('classes', p_class_id);

  for v_enr in
    select e.id as enrollment_id, e.student_id
    from public.enrollments e
    where e.session_id = p_session_id and e.class_id = p_class_id and e.status = 'active'
      and not exists (
        select 1 from public.invoices i
        where i.enrollment_id = e.id and i.period_month = p_period_month and i.status <> 'void'
      )
  loop
    v_arrears := public.student_balance(v_enr.student_id);
    begin
      insert into public.invoices(
        student_id, enrollment_id, session_id, period_month, status,
        arrears_brought_forward, due_date, issued_at, created_by)
      values (
        v_enr.student_id, v_enr.enrollment_id, p_session_id, p_period_month, 'issued',
        v_arrears, p_due_date, now(), v_actor)
      returning id into v_inv;
    exception when unique_violation then
      continue;
    end;

    insert into public.invoice_lines(invoice_id, fee_head_id, description, amount, is_discount)
    select v_inv, fh.id, fh.name, coalesce(sfi.amount, fs.amount), false
    from public.fee_structures fs
    join public.fee_heads fh on fh.id = fs.fee_head_id
    left join public.student_fee_items sfi
      on sfi.enrollment_id = v_enr.enrollment_id and sfi.fee_head_id = fh.id and sfi.active
    where fs.session_id = p_session_id and fs.class_id = p_class_id
      and fh.is_recurring and fh.active;

    select coalesce(sum(amount), 0) into v_tuition
    from public.invoice_lines where invoice_id = v_inv and not is_discount;

    perform public.fn__apply_discount_lines(v_inv, v_enr.enrollment_id, v_tuition);
    v_count := v_count + 1;

    select family_id into v_fam from public.students where id = v_enr.student_id;
    if v_fam is not null and not (v_fam = any(v_families)) then
      v_families := v_families || v_fam;
    end if;
  end loop;

  foreach v_fam in array v_families loop
    perform public.fn_apply_family_credit(v_fam);
  end loop;

  return v_count;
end;
$$;

-- ===========================================================================
-- 10. Admission attaches the family
-- ===========================================================================

-- Match on the father's CNIC when given, otherwise start a new family. Never
-- match on name alone: two unrelated Muhammad Aslams in one school is not a
-- corner case in Pakistan, and a wrong match merges two families' money.
create or replace function public.fn_family_for(
  p_head_name text, p_head_cnic text default null,
  p_phone text default null, p_whatsapp text default null
) returns uuid language plpgsql security definer set search_path = public as $$
declare v_id uuid; v_school uuid := public.current_school_id();
begin
  if p_head_cnic is not null and btrim(p_head_cnic) <> '' then
    select id into v_id from public.families
    where school_id = v_school and head_cnic = btrim(p_head_cnic);
    if found then
      update public.families set
        phone    = coalesce(nullif(btrim(coalesce(p_phone, '')), ''), phone),
        whatsapp = coalesce(nullif(btrim(coalesce(p_whatsapp, '')), ''), whatsapp)
      where id = v_id;
      return v_id;
    end if;
  end if;

  insert into public.families (head_name, head_cnic, phone, whatsapp)
  values (coalesce(nullif(btrim(coalesce(p_head_name, '')), ''), 'Family'),
          nullif(btrim(coalesce(p_head_cnic, '')), ''),
          nullif(btrim(coalesce(p_phone, '')), ''),
          nullif(btrim(coalesce(p_whatsapp, '')), ''))
  returning id into v_id;
  return v_id;
end;
$$;

-- Any student created without a family gets a single-child one, so no code
-- path can produce a student who cannot be billed.
create or replace function public.fn_student_default_family() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.family_id is null then
    -- school_id is left to the families stamping trigger rather than copied
    -- from new.school_id, so this is correct even if trigger order ever moves.
    insert into public.families (school_id, head_name)
    values (coalesce(new.school_id, public.current_school_id()),
            new.full_name || ' (family)')
    returning id into new.family_id;
  end if;
  return new;
end;
$$;

-- THE NAME MATTERS. Postgres fires BEFORE ROW triggers in alphabetical order,
-- and 0025 created `trg_students_school` to stamp school_id. This trigger must
-- run AFTER that one, or new.school_id is still null when it reads it — so the
-- name is chosen to sort later. Do not rename it earlier in the alphabet.
create trigger trg_students_zz_family before insert on public.students
  for each row execute function public.fn_student_default_family();

alter table public.students alter column family_id set not null;

-- ===========================================================================
-- 11. Grants
-- ===========================================================================

grant execute on function public.family_credit(uuid)              to authenticated;
grant execute on function public.family_outstanding(uuid)         to authenticated;
grant execute on function public.fn_find_family(text)             to authenticated;
grant execute on function public.fn_family_sheet(uuid)            to authenticated;
grant execute on function public.fn_family_for(text, text, text, text) to authenticated;
grant execute on function public.fn_record_family_payment(uuid, numeric, public.payment_method, text, boolean)
  to authenticated;
grant execute on function public.fn_apply_family_credit(uuid)     to authenticated;

-- fn__allocate_payment is INTERNAL. It writes allocation rows against any
-- invoice id handed to it, so exposing it would let a signed-in user mark
-- invoices paid without a payment. Callers reach it only through the guarded
-- functions above.
revoke all on function public.fn__allocate_payment(uuid, uuid[], numeric) from public, anon, authenticated;

-- ─────────────────────────────────────────────────────────────────────────
-- 0030_expenses.sql
-- ─────────────────────────────────────────────────────────────────────────
-- =============================================================================
-- Expenses, other income, and the profit figure.
--
-- Until now the system tracked money coming IN and nothing going OUT, so it
-- could not answer the first question a school owner asks: "did we make money
-- this month?" An owner-focused product that cannot show profit is a
-- contradiction, so this closes it.
--
-- THE RULE THAT MAKES THIS TRUSTWORTHY:
--
--   Fee income is DERIVED from verified payments and can never be typed in.
--
-- There is deliberately no "add fee income" function. The only way fee income
-- exists is that a receipt was issued against a real invoice, which means the
-- income line on a profit report cannot be inflated by anyone — including the
-- owner. `other_income` exists for genuinely non-fee money (canteen rent, a
-- van hire, a book sale) and is reported on its own line, never merged into
-- fee income, so the two can always be told apart.
--
-- Salaries are an expense CATEGORY, not a payroll module. That gives an honest
-- profit number — salaries are 60-70% of a school's costs — without building
-- payroll, which is out of scope.
--
-- Append-only, like payments: nothing is edited or deleted. A mistake is
-- corrected by a reversal that writes a compensating row with a reason. The
-- competitor's product has a "Deleted Fees" screen and a recycle bin; a
-- deletable financial record is a hole in an accounting system and we are not
-- copying it.
-- =============================================================================

-- ===========================================================================
-- 1. Categories
-- ===========================================================================

create table public.expense_categories (
  id         uuid primary key default gen_random_uuid(),
  school_id  uuid not null references public.schools(id) on delete cascade,
  name       text not null,
  sort_order integer not null default 0,
  active     boolean not null default true,
  created_at timestamptz not null default now()
);
create unique index uq_expense_cat_school_name on public.expense_categories (school_id, lower(name));
create index idx_expense_cat_school on public.expense_categories (school_id);

-- ===========================================================================
-- 2. The ledgers
-- ===========================================================================

create table public.expenses (
  id          uuid primary key default gen_random_uuid(),
  school_id   uuid not null references public.schools(id) on delete cascade,
  spent_on    date not null default current_date,
  category_id uuid references public.expense_categories(id),
  amount      numeric(12,2) not null,
  payee       text,
  method      public.payment_method not null default 'cash',
  note        text,
  voucher_no  bigint,                                    -- gapless, per school
  recorded_by uuid references public.profiles(id),
  reversal_of uuid references public.expenses(id),
  created_at  timestamptz not null default now()
);
create index idx_expenses_school_date on public.expenses (school_id, spent_on);
create index idx_expenses_category on public.expenses (category_id);

create table public.other_income (
  id          uuid primary key default gen_random_uuid(),
  school_id   uuid not null references public.schools(id) on delete cascade,
  received_on date not null default current_date,
  source      text not null,
  amount      numeric(12,2) not null,
  method      public.payment_method not null default 'cash',
  note        text,
  voucher_no  bigint,
  recorded_by uuid references public.profiles(id),
  reversal_of uuid references public.other_income(id),
  created_at  timestamptz not null default now()
);
create index idx_other_income_school_date on public.other_income (school_id, received_on);

-- ===========================================================================
-- 3. Tenant plumbing
-- ===========================================================================

do $$
declare t text;
begin
  foreach t in array array['expense_categories', 'expenses', 'other_income'] loop
    execute format(
      'create trigger trg_%1$s_school before insert or update on public.%1$s
         for each row execute function public.enforce_school_id();', t);
    execute format(
      'create trigger trg_audit_%1$s after insert or update or delete on public.%1$s
         for each row execute function public.audit_trigger();', t);
    execute format('alter table public.%I enable row level security;', t);
  end loop;
end $$;

-- Money out is finance-only to read and owner/principal/accountant to write.
-- Teachers have no business seeing the school's cost base.
create policy expense_cat_select on public.expense_categories for select to authenticated
  using (school_id = public.current_school_id()
         and public.has_role('owner', 'principal', 'accountant', 'admin_clerk'));
create policy expense_cat_write on public.expense_categories for all to authenticated
  using (school_id = public.current_school_id() and public.has_role('owner', 'principal'))
  with check (school_id = public.current_school_id() and public.has_role('owner', 'principal'));

create policy expenses_select on public.expenses for select to authenticated
  using (school_id = public.current_school_id()
         and public.has_role('owner', 'principal', 'accountant'));
-- No INSERT/UPDATE/DELETE policy at all: writes go exclusively through the
-- SECURITY DEFINER functions below, so every row gets a gapless voucher number
-- and an audit trail. A direct insert would bypass both.

create policy other_income_select on public.other_income for select to authenticated
  using (school_id = public.current_school_id()
         and public.has_role('owner', 'principal', 'accountant'));

-- ===========================================================================
-- 4. Default categories for every school, existing and future
-- ===========================================================================

create or replace function public.fn__seed_expense_categories(p_school uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  insert into public.expense_categories (school_id, name, sort_order)
  values
    (p_school, 'Salaries',       1),
    (p_school, 'Rent',           2),
    (p_school, 'Utilities',      3),
    (p_school, 'Maintenance',    4),
    (p_school, 'Stationery',     5),
    (p_school, 'Examination',    6),
    (p_school, 'Marketing',      7),
    (p_school, 'Other',          99)
  on conflict do nothing;
end;
$$;

do $$
declare s record;
begin
  for s in select id from public.schools loop
    perform public.fn__seed_expense_categories(s.id);
  end loop;
end $$;

-- New schools get them at provisioning time.
create or replace function public.fn_provision_expense_categories() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  perform public.fn__seed_expense_categories(new.id);
  return new;
end;
$$;

create trigger trg_schools_expense_cats after insert on public.schools
  for each row execute function public.fn_provision_expense_categories();

-- ===========================================================================
-- 5. Recording money out / non-fee money in
-- ===========================================================================

create or replace function public.fn_record_expense(
  p_amount numeric, p_category_id uuid, p_spent_on date default current_date,
  p_payee text default null, p_method public.payment_method default 'cash',
  p_note text default null
) returns jsonb language plpgsql security definer set search_path = public as $$
declare v_id uuid; v_no bigint;
begin
  if not public.has_role('owner', 'principal', 'accountant') then
    raise exception 'Not permitted to record expenses';
  end if;
  if p_amount is null or p_amount <= 0 then
    raise exception 'Expense amount must be positive (use a reversal to correct a mistake)';
  end if;
  if p_category_id is not null then
    perform public.assert_own('expense_categories', p_category_id);
  end if;

  v_no := public.next_counter('expense_voucher');
  insert into public.expenses (spent_on, category_id, amount, payee, method, note,
                               voucher_no, recorded_by)
  values (coalesce(p_spent_on, current_date), p_category_id, p_amount, p_payee,
          coalesce(p_method, 'cash'), p_note, v_no, auth.uid())
  returning id into v_id;

  return jsonb_build_object('expense_id', v_id, 'voucher_no', v_no);
end;
$$;

create or replace function public.fn_reverse_expense(p_expense_id uuid, p_reason text)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_orig record; v_id uuid; v_no bigint;
begin
  if not public.has_role('owner', 'principal') then
    raise exception 'Only owner/principal may reverse an expense';
  end if;
  perform public.assert_own('expenses', p_expense_id);
  select * into v_orig from public.expenses where id = p_expense_id;
  if not found then raise exception 'Expense not found'; end if;
  if v_orig.reversal_of is not null then raise exception 'Cannot reverse a reversal'; end if;
  if exists (select 1 from public.expenses where reversal_of = p_expense_id) then
    raise exception 'Expense already reversed';
  end if;
  if p_reason is null or btrim(p_reason) = '' then
    raise exception 'A reversal needs a reason';
  end if;

  v_no := public.next_counter('expense_voucher');
  insert into public.expenses (spent_on, category_id, amount, payee, method, note,
                               voucher_no, recorded_by, reversal_of)
  values (current_date, v_orig.category_id, -v_orig.amount, v_orig.payee, v_orig.method,
          p_reason, v_no, auth.uid(), p_expense_id)
  returning id into v_id;
  return v_id;
end;
$$;

create or replace function public.fn_record_other_income(
  p_amount numeric, p_source text, p_received_on date default current_date,
  p_method public.payment_method default 'cash', p_note text default null
) returns jsonb language plpgsql security definer set search_path = public as $$
declare v_id uuid; v_no bigint;
begin
  if not public.has_role('owner', 'principal', 'accountant') then
    raise exception 'Not permitted to record income';
  end if;
  if p_amount is null or p_amount <= 0 then
    raise exception 'Income amount must be positive';
  end if;
  if p_source is null or btrim(p_source) = '' then
    raise exception 'Non-fee income needs a source (this is not fee collection)';
  end if;

  v_no := public.next_counter('income_voucher');
  insert into public.other_income (received_on, source, amount, method, note,
                                   voucher_no, recorded_by)
  values (coalesce(p_received_on, current_date), btrim(p_source), p_amount,
          coalesce(p_method, 'cash'), p_note, v_no, auth.uid())
  returning id into v_id;

  return jsonb_build_object('income_id', v_id, 'voucher_no', v_no);
end;
$$;

create or replace function public.fn_reverse_other_income(p_income_id uuid, p_reason text)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_orig record; v_id uuid; v_no bigint;
begin
  if not public.has_role('owner', 'principal') then
    raise exception 'Only owner/principal may reverse income';
  end if;
  perform public.assert_own('other_income', p_income_id);
  select * into v_orig from public.other_income where id = p_income_id;
  if not found then raise exception 'Income entry not found'; end if;
  if v_orig.reversal_of is not null then raise exception 'Cannot reverse a reversal'; end if;
  if exists (select 1 from public.other_income where reversal_of = p_income_id) then
    raise exception 'Income entry already reversed';
  end if;
  if p_reason is null or btrim(p_reason) = '' then
    raise exception 'A reversal needs a reason';
  end if;

  v_no := public.next_counter('income_voucher');
  insert into public.other_income (received_on, source, amount, method, note,
                                   voucher_no, recorded_by, reversal_of)
  values (current_date, v_orig.source, -v_orig.amount, v_orig.method, p_reason,
          v_no, auth.uid(), p_income_id)
  returning id into v_id;
  return v_id;
end;
$$;

-- ===========================================================================
-- 6. The profit picture
--
-- Cash basis, which is what a school owner means. "Income today" is money that
-- physically arrived today, not fees that were billed today — a challan issued
-- is not money.
-- ===========================================================================

create or replace function public.fn_finance_summary(p_from date, p_to date)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_fee     numeric;
  v_other   numeric;
  v_exp     numeric;
  v_by_cat  jsonb;
  v_school  uuid := public.current_school_id();
begin
  if not public.has_role('owner', 'principal', 'accountant') then
    raise exception 'Not permitted to view finances';
  end if;

  -- Fee income: verified payments in the window. Reversals carry a negative
  -- amount, so a reversed payment removes itself from income automatically.
  select coalesce(sum(p.amount), 0) into v_fee
  from public.payments p
  where p.school_id = v_school and p.status = 'verified'
    and p.created_at::date between p_from and p_to;

  select coalesce(sum(o.amount), 0) into v_other
  from public.other_income o
  where o.school_id = v_school and o.received_on between p_from and p_to;

  select coalesce(sum(e.amount), 0) into v_exp
  from public.expenses e
  where e.school_id = v_school and e.spent_on between p_from and p_to;

  select coalesce(jsonb_agg(x order by x.total desc), '[]'::jsonb) into v_by_cat
  from (
    select coalesce(c.name, 'Uncategorised') as category,
           sum(e.amount) as total
    from public.expenses e
    left join public.expense_categories c on c.id = e.category_id
    where e.school_id = v_school and e.spent_on between p_from and p_to
    group by 1
    having sum(e.amount) <> 0
  ) x;

  return jsonb_build_object(
    'from', p_from, 'to', p_to,
    'fee_income', v_fee,
    'other_income', v_other,
    'total_income', v_fee + v_other,
    'expenses', v_exp,
    'profit', v_fee + v_other - v_exp,
    'by_category', v_by_cat);
end;
$$;

-- The three figures a dashboard shows without asking for a date range.
create or replace function public.fn_profit_snapshot()
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_today jsonb; v_month jsonb; v_year jsonb;
begin
  if not public.has_role('owner', 'principal', 'accountant') then
    raise exception 'Not permitted to view finances';
  end if;
  v_today := public.fn_finance_summary(current_date, current_date);
  v_month := public.fn_finance_summary(date_trunc('month', current_date)::date, current_date);
  v_year  := public.fn_finance_summary(date_trunc('year', current_date)::date, current_date);
  return jsonb_build_object('today', v_today, 'month', v_month, 'year', v_year);
end;
$$;

-- ===========================================================================
-- 7. Grants
-- ===========================================================================

grant execute on function public.fn_record_expense(numeric, uuid, date, text, public.payment_method, text) to authenticated;
grant execute on function public.fn_reverse_expense(uuid, text) to authenticated;
grant execute on function public.fn_record_other_income(numeric, text, date, public.payment_method, text) to authenticated;
grant execute on function public.fn_reverse_other_income(uuid, text) to authenticated;
grant execute on function public.fn_finance_summary(date, date) to authenticated;
grant execute on function public.fn_profit_snapshot() to authenticated;

-- Seeding is internal: it takes a school_id and writes rows into it.
revoke all on function public.fn__seed_expense_categories(uuid) from public, anon, authenticated;

-- ─────────────────────────────────────────────────────────────────────────
-- 0031_till.sql
-- ─────────────────────────────────────────────────────────────────────────
-- =============================================================================
-- Till sessions — per-collector cash control and end-of-day settlement.
--
-- The Day Book answers "what did the SCHOOL collect today". That is the weaker
-- question. This answers "what did YOU collect today, and does the cash in
-- your drawer match it" — which is how physical cash is actually controlled in
-- a school office, and it makes each clerk personally accountable for a number
-- at 4pm rather than accountable to a report nobody runs.
--
-- DESIGN RULE: taking money is NEVER blocked.
--
-- The obvious design is "a cash payment requires an open till". That is wrong
-- here: it means a clerk who forgot the morning ritual cannot accept a fee,
-- and a parent standing at the counter gets turned away by our software. So a
-- till is opened automatically, with a zero float, on the first cash payment
-- of the day. The discipline lives at CLOSING time, where it belongs — count
-- the drawer, explain any difference.
--
-- The variance is STORED, not recomputed. If it were derived, a later
-- correction to the day's payments would silently change history and a
-- shortfall that was explained on Tuesday could quietly disappear on Friday.
-- =============================================================================

create table public.till_sessions (
  id              uuid primary key default gen_random_uuid(),
  school_id       uuid not null references public.schools(id) on delete cascade,
  opened_by       uuid not null references public.profiles(id),
  opened_at       timestamptz not null default now(),
  opening_float   numeric(12,2) not null default 0,

  closed_at       timestamptz,
  counted_cash    numeric(12,2),          -- what was physically counted
  expected_cash   numeric(12,2),          -- float + cash taken in this session
  variance        numeric(12,2),          -- counted - expected, frozen at close
  variance_reason text,

  approved_by     uuid references public.profiles(id),
  approved_at     timestamptz,

  status          text not null default 'open'
                  check (status in ('open', 'closed', 'approved')),
  created_at      timestamptz not null default now()
);

create index idx_till_school_opened on public.till_sessions (school_id, opened_at desc);
-- One open till per person. Not per person per day: a session spans whatever
-- period the clerk works, and two open drawers for one human is meaningless.
create unique index uq_till_one_open_per_user
  on public.till_sessions (opened_by) where status = 'open';

alter table public.payments
  add column till_session_id uuid references public.till_sessions(id);
create index idx_payments_till on public.payments (till_session_id);

create trigger trg_till_sessions_school before insert or update on public.till_sessions
  for each row execute function public.enforce_school_id();
create trigger trg_audit_till after insert or update or delete on public.till_sessions
  for each row execute function public.audit_trigger();

alter table public.till_sessions enable row level security;

-- A clerk sees their own drawer; owner/principal see every drawer.
create policy till_select on public.till_sessions for select to authenticated
  using (school_id = public.current_school_id()
         and (opened_by = auth.uid() or public.has_role('owner', 'principal')));
-- Writes go through the functions below only, so status transitions and the
-- frozen variance cannot be sidestepped.

-- ===========================================================================
-- Opening, and the automatic open that keeps the counter moving
-- ===========================================================================

create or replace function public.fn_open_till(p_opening_float numeric default 0)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_id uuid;
begin
  if not public.has_role('owner','principal','admin_clerk','accountant') then
    raise exception 'Not permitted to open a till';
  end if;
  if coalesce(p_opening_float, 0) < 0 then
    raise exception 'Opening float cannot be negative';
  end if;

  select id into v_id from public.till_sessions
  where opened_by = auth.uid() and status = 'open';
  if found then return v_id; end if;

  insert into public.till_sessions (opened_by, opening_float)
  values (auth.uid(), coalesce(p_opening_float, 0))
  returning id into v_id;
  return v_id;
end;
$$;

-- Internal: returns the caller's open till, creating a zero-float one if there
-- is none. Called from the payment path, which must never fail for this.
create or replace function public.fn__ensure_till()
returns uuid language plpgsql security definer set search_path = public as $$
declare v_id uuid;
begin
  if auth.uid() is null then return null; end if;
  select id into v_id from public.till_sessions
  where opened_by = auth.uid() and status = 'open';
  if found then return v_id; end if;

  insert into public.till_sessions (opened_by, opening_float)
  values (auth.uid(), 0)
  returning id into v_id;
  return v_id;
exception when others then
  -- Never let till bookkeeping stop a payment being recorded.
  return null;
end;
$$;

create or replace function public.fn_current_till()
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_t record; v_cash numeric; v_all numeric; v_n integer;
begin
  select * into v_t from public.till_sessions
  where opened_by = auth.uid() and status = 'open';
  if not found then return null; end if;

  select coalesce(sum(p.amount), 0), count(*)
    into v_cash, v_n
  from public.payments p
  where p.till_session_id = v_t.id and p.status = 'verified' and p.method = 'cash';

  select coalesce(sum(p.amount), 0) into v_all
  from public.payments p
  where p.till_session_id = v_t.id and p.status = 'verified';

  return jsonb_build_object(
    'till_id', v_t.id,
    'opened_at', v_t.opened_at,
    'opening_float', v_t.opening_float,
    'cash_taken', v_cash,
    'all_taken', v_all,
    'receipts', v_n,
    'expected_cash', v_t.opening_float + v_cash);
end;
$$;

-- ===========================================================================
-- Closing: count the drawer, explain the difference
-- ===========================================================================

create or replace function public.fn_close_till(
  p_counted_cash numeric, p_reason text default null
) returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_t record; v_cash numeric; v_expected numeric; v_var numeric;
begin
  select * into v_t from public.till_sessions
  where opened_by = auth.uid() and status = 'open'
  for update;
  if not found then raise exception 'You have no open till'; end if;
  if p_counted_cash is null or p_counted_cash < 0 then
    raise exception 'Count the drawer before closing it';
  end if;

  select coalesce(sum(p.amount), 0) into v_cash
  from public.payments p
  where p.till_session_id = v_t.id and p.status = 'verified' and p.method = 'cash';

  v_expected := v_t.opening_float + v_cash;
  v_var := p_counted_cash - v_expected;

  -- A difference in either direction needs an explanation. Extra cash in the
  -- drawer is as much a red flag as missing cash — it usually means a receipt
  -- was never written.
  if v_var <> 0 and (p_reason is null or btrim(p_reason) = '') then
    raise exception 'The drawer is off by %. A reason is required to close it.', v_var;
  end if;

  update public.till_sessions set
    closed_at = now(), counted_cash = p_counted_cash,
    expected_cash = v_expected, variance = v_var,
    variance_reason = nullif(btrim(coalesce(p_reason, '')), ''),
    status = 'closed'
  where id = v_t.id;

  return jsonb_build_object(
    'till_id', v_t.id, 'expected_cash', v_expected,
    'counted_cash', p_counted_cash, 'variance', v_var);
end;
$$;

create or replace function public.fn_approve_till(p_till_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v_t record;
begin
  if not public.has_role('owner', 'principal') then
    raise exception 'Only owner/principal may sign off a till';
  end if;
  perform public.assert_own('till_sessions', p_till_id);
  select * into v_t from public.till_sessions where id = p_till_id;
  if not found then raise exception 'Till not found'; end if;
  if v_t.status <> 'closed' then
    raise exception 'Only a closed till can be signed off';
  end if;
  update public.till_sessions
     set status = 'approved', approved_by = auth.uid(), approved_at = now()
   where id = p_till_id;
end;
$$;

-- The owner's settlement view: who collected what, and whose drawer was off.
create or replace function public.fn_till_report(p_from date, p_to date)
returns table (
  till_id uuid, collector text, opened_at timestamptz, closed_at timestamptz,
  opening_float numeric, cash_taken numeric, all_taken numeric,
  expected_cash numeric, counted_cash numeric, variance numeric,
  variance_reason text, status text
) language sql stable security definer set search_path = public as $$
  select t.id,
         coalesce(pr.full_name, 'Unknown'),
         t.opened_at, t.closed_at, t.opening_float,
         coalesce((select sum(p.amount) from public.payments p
                   where p.till_session_id = t.id and p.status = 'verified'
                     and p.method = 'cash'), 0),
         coalesce((select sum(p.amount) from public.payments p
                   where p.till_session_id = t.id and p.status = 'verified'), 0),
         t.expected_cash, t.counted_cash, t.variance, t.variance_reason, t.status
  from public.till_sessions t
  left join public.profiles pr on pr.id = t.opened_by
  where t.school_id = public.current_school_id()
    and public.has_role('owner', 'principal', 'accountant')
    and t.opened_at::date between p_from and p_to
  order by t.opened_at desc;
$$;

-- ===========================================================================
-- Attach cash payments to the collector's drawer
--
-- Both payment entry points are re-created with one added line. Everything
-- else about them is unchanged from 0029.
-- ===========================================================================

create or replace function public.fn_record_family_payment(
  p_family_id uuid, p_amount numeric, p_method public.payment_method,
  p_note text default null, p_pending boolean default false
) returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_actor    uuid := auth.uid();
  v_receipt  bigint;
  v_pay      uuid;
  v_students uuid[];
  v_left     numeric;
  v_till     uuid;
begin
  if not public.has_role('owner','principal','admin_clerk','accountant') then
    raise exception 'Not permitted to record payments';
  end if;
  if p_amount is null or p_amount <= 0 then raise exception 'Amount must be positive'; end if;
  perform public.assert_own('families', p_family_id);

  select array_agg(id) into v_students from public.students where family_id = p_family_id;
  if v_students is null then raise exception 'This family has no students'; end if;

  if p_method = 'cash' and not p_pending then v_till := public.fn__ensure_till(); end if;

  v_receipt := public.next_counter('receipt');
  insert into public.payments(family_id, student_id, amount, method, receipt_no,
                              status, received_by, note, till_session_id)
  values (p_family_id, null, p_amount, p_method, v_receipt,
          case when p_pending then 'pending' else 'verified' end, v_actor, p_note, v_till)
  returning id into v_pay;

  if p_pending then
    return jsonb_build_object('payment_id', v_pay, 'receipt_no', v_receipt,
      'allocated', 0, 'credit', 0, 'pending', true);
  end if;

  v_left := public.fn__allocate_payment(v_pay, v_students, p_amount);

  return jsonb_build_object(
    'payment_id', v_pay, 'receipt_no', v_receipt,
    'allocated', p_amount - v_left,
    'credit', v_left,
    'family_outstanding', public.family_outstanding(p_family_id),
    'pending', false);
end;
$$;

create or replace function public.fn_record_payment(
  p_student_id uuid, p_amount numeric, p_method public.payment_method,
  p_note text default null, p_pending boolean default false
) returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_actor   uuid := auth.uid();
  v_receipt bigint;
  v_pay     uuid;
  v_family  uuid;
  v_left    numeric;
  v_till    uuid;
begin
  if not public.has_role('owner','principal','admin_clerk','accountant') then
    raise exception 'Not permitted to record payments';
  end if;
  if p_amount is null or p_amount <= 0 then raise exception 'Amount must be positive'; end if;
  perform public.assert_own('students', p_student_id);

  select family_id into v_family from public.students where id = p_student_id;

  if p_method = 'cash' and not p_pending then v_till := public.fn__ensure_till(); end if;

  v_receipt := public.next_counter('receipt');
  insert into public.payments(student_id, family_id, amount, method, receipt_no,
                              status, received_by, note, till_session_id)
  values (p_student_id, v_family, p_amount, p_method, v_receipt,
          case when p_pending then 'pending' else 'verified' end, v_actor, p_note, v_till)
  returning id into v_pay;

  if p_pending then
    return jsonb_build_object('payment_id', v_pay, 'receipt_no', v_receipt,
      'allocated', 0, 'unallocated', p_amount, 'pending', true);
  end if;

  v_left := public.fn__allocate_payment(v_pay, array[p_student_id], p_amount);

  return jsonb_build_object(
    'payment_id', v_pay, 'receipt_no', v_receipt,
    'allocated', p_amount - v_left, 'unallocated', v_left, 'pending', false);
end;
$$;

grant execute on function public.fn_open_till(numeric)              to authenticated;
grant execute on function public.fn_current_till()                  to authenticated;
grant execute on function public.fn_close_till(numeric, text)       to authenticated;
grant execute on function public.fn_approve_till(uuid)              to authenticated;
grant execute on function public.fn_till_report(date, date)         to authenticated;

-- Internal: it creates a till row for whoever calls it.
revoke all on function public.fn__ensure_till() from public, anon, authenticated;

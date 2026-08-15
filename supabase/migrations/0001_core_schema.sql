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

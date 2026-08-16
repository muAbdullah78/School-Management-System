-- =============================================================================
-- GENERATED FILE — DO NOT EDIT.
-- Built from supabase/migrations/ by supabase/build-bundles.sh
--
-- Paste this whole file into the Supabase SQL Editor and press Run.
-- Run the bundles in order, one at a time, waiting for each to finish.
-- =============================================================================


-- ─────────────────────────────────────────────────────────────────────────
-- 0033_portal.sql
-- ─────────────────────────────────────────────────────────────────────────
-- =============================================================================
-- The portal — one login, role decides everything.
--
-- Parents and teachers sign in at the same place. A teacher gets their classes;
-- a parent gets their own children and nothing else.
--
-- ==========================  THE DANGER  ====================================
--
-- Twenty-five tables carried a policy of the form
--
--     using (school_id = public.current_school_id())
--
-- with NO role check — students, enrollments, attendance, marks, result cards,
-- guardians, families, staff, and more. Those were written when every account
-- in a school belonged to a member of staff, and under that assumption they
-- were correct.
--
-- Adding a 'parent' role to that world would have handed every parent the
-- entire school: every child's name, every mark, every attendance record, and
-- the contact details of every other family. Not through a bug — through the
-- policies working exactly as written.
--
-- So this migration does two independent things, and either one alone would
-- be enough to be nervous about:
--
--   1. Every one of those policies is rewritten to require public.is_staff().
--      A parent account has NO table-level read access anywhere. If a portal
--      function is buggy tomorrow, the tables are still shut.
--
--   2. The portal is served exclusively by SECURITY DEFINER functions that
--      filter to the caller's own family. Parents never touch a table.
--
-- The test suite proves both halves: that a parent cannot read the tables
-- directly, AND that they cannot reach another family through the functions.
-- =============================================================================

-- ===========================================================================
-- 1. The role
--
-- 'parent' is added by 0032_parent_role.sql, deliberately in a file of its
-- own: Postgres refuses to let a new enum value be USED in the transaction
-- that added it, and the Supabase SQL Editor runs each file as one
-- transaction. Everything below compares against 'parent', so the value must
-- already be committed by the time this file runs.
-- ===========================================================================

-- Which family a parent account speaks for. Null for every member of staff.
alter table public.profiles add column family_id uuid references public.families(id);
create index idx_profiles_family on public.profiles (family_id);

-- ===========================================================================
-- 2. The helper every policy now leans on
-- ===========================================================================

-- SECURITY DEFINER for the same reason as has_role(): policies call it, so it
-- must not recurse through profiles' own RLS. STABLE so the planner evaluates
-- it once per statement rather than once per row.
create or replace function public.is_staff() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select role from public.profiles where id = auth.uid()) <> 'parent', false);
$$;

create or replace function public.is_parent() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select role from public.profiles where id = auth.uid()) = 'parent', false);
$$;

-- The family this caller speaks for. Null unless they are a parent account.
create or replace function public.my_family_id() returns uuid
language sql stable security definer set search_path = public as $$
  select family_id from public.profiles
  where id = auth.uid()
    and role = 'parent';
$$;

grant execute on function public.is_staff()     to authenticated;
grant execute on function public.is_parent()    to authenticated;
grant execute on function public.my_family_id() to authenticated;

-- ===========================================================================
-- 3. Shut every table to parent accounts
--
-- Generated from an explicit list rather than swept from the catalogue: a
-- sweep would silently "fix" a policy someone deliberately wrote differently,
-- and a security change should be readable in the diff.
-- ===========================================================================

-- DROP BY CATALOGUE, NOT BY GUESSED NAME.
--
-- RLS policies are permissive and OR together, so adding a restrictive policy
-- beside an existing one restricts nothing. The first version of this block
-- dropped `<table>_select` and created `<table>_select` — but 0025 had named
-- three of them `attendance_select`, `marks_select` and `teacher_assign_select`.
-- The drop matched nothing, the create added a SECOND policy, and parents could
-- still read attendance and marks through the surviving one.
--
-- So every SELECT policy on each table is enumerated from pg_policies and
-- dropped by its real name before the single correct policy is created. Naming
-- conventions are not a security boundary.
do $$
declare t text; p record;
begin
  foreach t in array array[
    'academic_sessions', 'assessments', 'attendance_daily', 'campuses',
    'classes', 'enrollments', 'exam_subjects', 'exam_terms', 'families',
    'fee_heads', 'fee_structures', 'guardians', 'mark_entries',
    'result_cards', 'sections', 'shifts', 'staff', 'student_links',
    'students', 'subjects', 'teacher_assignments'
  ] loop
    for p in
      select policyname from pg_policies
      where schemaname = 'public' and tablename = t and cmd = 'SELECT'
    loop
      execute format('drop policy %I on public.%I;', p.policyname, t);
    end loop;

    execute format($f$create policy %1$s_select on public.%1$s for select to authenticated
      using (school_id = public.current_school_id() and public.is_staff());$f$, t);
  end loop;
end $$;

-- school_settings: staff read it directly; the portal gets the school name
-- through fn_portal_me() instead, so parents need no table access here.
drop policy if exists settings_select on public.school_settings;
create policy settings_select on public.school_settings for select to authenticated
  using (school_id = public.current_school_id() and public.is_staff());

-- profiles: a parent may read exactly one row — their own. AuthProvider needs
-- it to know who is signed in.
drop policy if exists profiles_select on public.profiles;
create policy profiles_select on public.profiles for select to authenticated
  using (school_id = public.current_school_id()
         and (public.is_staff() or id = auth.uid()));

-- schools / subscriptions: licence state is a staff concern. A parent has no
-- business seeing what the school pays us, and the portal must keep working
-- for a family whether or not the school has paid this month.
drop policy if exists schools_select_own on public.schools;
create policy schools_select_own on public.schools for select to authenticated
  using (id = public.current_school_id() and public.is_staff());

drop policy if exists subscriptions_select_own on public.subscriptions;
create policy subscriptions_select_own on public.subscriptions for select to authenticated
  using (school_id = public.current_school_id() and public.is_staff());

-- ===========================================================================
-- 4. Guards
-- ===========================================================================

-- Raises unless this student is genuinely one of the caller's children.
-- Every portal function that takes a student_id goes through this first.
create or replace function public.fn__assert_my_child(p_student_id uuid)
returns void language plpgsql stable security definer set search_path = public as $$
declare v_fam uuid;
begin
  v_fam := public.my_family_id();
  if v_fam is null then
    raise exception 'Not a parent account' using errcode = '42501';
  end if;
  if not exists (
    select 1 from public.students s
    where s.id = p_student_id
      and s.family_id = v_fam
      and s.school_id = public.current_school_id()
  ) then
    -- Deliberately the same message whether the student does not exist or
    -- belongs to someone else: a distinguishable error is an enumeration
    -- oracle for guessing other families' student ids.
    raise exception 'Not your child' using errcode = '42501';
  end if;
end;
$$;

-- Linking a parent account to a family is an owner/principal act. It is the
-- single most sensitive write in the portal: point it at the wrong family and
-- a stranger sees a child's records.
create or replace function public.fn_link_parent(p_profile_id uuid, p_family_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.has_role('owner', 'principal') then
    raise exception 'Only owner/principal may link a parent account';
  end if;
  perform public.assert_own('families', p_family_id);
  perform public.assert_own('profiles', p_profile_id);
  if (select role from public.profiles where id = p_profile_id) <> 'parent' then
    raise exception 'That account is not a parent account';
  end if;
  update public.profiles set family_id = p_family_id where id = p_profile_id;
end;
$$;

grant execute on function public.fn_link_parent(uuid, uuid) to authenticated;
revoke all on function public.fn__assert_my_child(uuid) from public, anon;

-- ===========================================================================
-- 5. The portal API
--
-- Everything a parent sees comes through these. They are SECURITY DEFINER, so
-- they carry the whole burden of scoping — which is why each one starts by
-- resolving my_family_id() rather than trusting an id from the client.
-- ===========================================================================

-- Who am I, and what am I allowed to look at.
create or replace function public.fn_portal_me()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_p record; v_school text; v_children jsonb; v_classes jsonb;
begin
  select p.*, s.name as school_name into v_p
  from public.profiles p
  left join public.schools s on s.id = p.school_id
  where p.id = auth.uid();
  if not found then raise exception 'Not signed in' using errcode = '42501'; end if;

  v_school := coalesce(
    (select ss.name from public.school_settings ss where ss.school_id = v_p.school_id),
    v_p.school_name);

  if v_p.role = 'parent' then
    select coalesce(jsonb_agg(jsonb_build_object(
             'student_id', s.id, 'full_name', s.full_name, 'gr_no', s.gr_no,
             'class_name', c.name, 'section_name', sec.name, 'status', s.status
           ) order by s.full_name), '[]'::jsonb)
      into v_children
    from public.students s
    left join public.enrollments e on e.student_id = s.id and e.status = 'active'
    left join public.classes c on c.id = e.class_id
    left join public.sections sec on sec.id = e.section_id
    where s.family_id = v_p.family_id and s.deleted_at is null;
  else
    v_children := '[]'::jsonb;
  end if;

  if v_p.role in ('class_teacher', 'subject_teacher') then
    select coalesce(jsonb_agg(to_jsonb(a)), '[]'::jsonb) into v_classes
    from public.fn_my_assignments() a;
  else
    v_classes := '[]'::jsonb;
  end if;

  return jsonb_build_object(
    'profile_id', v_p.id,
    'full_name', v_p.full_name,
    'role', v_p.role,
    'school_name', v_school,
    'children', v_children,
    'classes', v_classes);
end;
$$;

-- A child's fee position: what is owed, and every receipt the family holds.
create or replace function public.fn_portal_child_fees(p_student_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_fam uuid; v_out jsonb;
begin
  perform public.fn__assert_my_child(p_student_id);
  v_fam := public.my_family_id();

  select jsonb_build_object(
    'student_id', p_student_id,
    'balance', public.student_balance(p_student_id),
    'family_outstanding', public.family_outstanding(v_fam),
    'family_credit', public.family_credit(v_fam),
    'invoices', coalesce((
      select jsonb_agg(jsonb_build_object(
        'period_month', i.period_month, 'due_date', i.due_date,
        'charge', b.charge, 'paid', b.allocated,
        'outstanding', b.charge - b.allocated, 'status', b.status
      ) order by i.period_month desc nulls last)
      from public.invoice_balances b
      join public.invoices i on i.id = b.invoice_id
      where b.student_id = p_student_id
    ), '[]'::jsonb),
    'receipts', coalesce((
      select jsonb_agg(jsonb_build_object(
        'receipt_no', p.receipt_no, 'amount', p.amount,
        'method', p.method, 'paid_on', p.created_at,
        'received_by', pr.full_name
      ) order by p.created_at desc)
      from public.payments p
      left join public.profiles pr on pr.id = p.received_by
      where p.family_id = v_fam and p.status = 'verified'
    ), '[]'::jsonb)
  ) into v_out;

  return v_out;
end;
$$;

create or replace function public.fn_portal_child_attendance(
  p_student_id uuid, p_from date, p_to date
) returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_out jsonb; v_present integer; v_total integer;
begin
  perform public.fn__assert_my_child(p_student_id);

  select count(*) filter (where a.status in ('present', 'late', 'half_day')),
         count(*)
    into v_present, v_total
  from public.attendance_daily a
  join public.enrollments e on e.id = a.enrollment_id
  where e.student_id = p_student_id
    and a.attendance_date between p_from and p_to;

  select jsonb_build_object(
    'from', p_from, 'to', p_to,
    'present', coalesce(v_present, 0),
    'marked', coalesce(v_total, 0),
    'percent', case when coalesce(v_total, 0) = 0 then null
                    else round((v_present::numeric / v_total) * 100) end,
    'days', coalesce((
      select jsonb_agg(jsonb_build_object('date', a.attendance_date, 'status', a.status)
             order by a.attendance_date desc)
      from public.attendance_daily a
      join public.enrollments e on e.id = a.enrollment_id
      where e.student_id = p_student_id
        and a.attendance_date between p_from and p_to
    ), '[]'::jsonb)
  ) into v_out;
  return v_out;
end;
$$;

-- ---------------------------------------------------------------------------
-- Results need a release switch, which did not exist before the portal.
--
-- `result_cards.frozen` is a jsonb reprint snapshot, not a publish flag — it
-- is written on every generation. So the moment a clerk generated cards to
-- check them, every parent would have seen the marks. Schools release results
-- deliberately, often at a parent meeting, and a mark a parent saw and then
-- saw change turns every correction into an accusation.
--
-- Generation also VERSIONS: regenerating writes version 2, 3, ... and leaves
-- the old rows. The portal must show only the newest version per term, or a
-- parent sees a superseded result sitting next to the real one.
-- ---------------------------------------------------------------------------

alter table public.result_cards add column published_at timestamptz;
create index idx_result_cards_published on public.result_cards (student_id, published_at);

create or replace function public.fn_publish_results(p_exam_term_id uuid, p_class_id uuid)
returns integer language plpgsql security definer set search_path = public as $$
declare v_n integer;
begin
  if not public.has_role('owner', 'principal') then
    raise exception 'Only owner/principal may release results to parents';
  end if;
  perform public.assert_own('exam_terms', p_exam_term_id);
  perform public.assert_own('classes', p_class_id);

  with latest as (
    select distinct on (rc.enrollment_id) rc.id
    from public.result_cards rc
    join public.enrollments e on e.id = rc.enrollment_id
    where rc.exam_term_id = p_exam_term_id and e.class_id = p_class_id
    order by rc.enrollment_id, rc.version desc
  )
  update public.result_cards rc
     set published_at = now()
    from latest l
   where rc.id = l.id and rc.published_at is null;

  get diagnostics v_n = row_count;
  return v_n;
end;
$$;

-- Pulling a result back is a real need — a mistake spotted an hour later.
create or replace function public.fn_unpublish_results(p_exam_term_id uuid, p_class_id uuid)
returns integer language plpgsql security definer set search_path = public as $$
declare v_n integer;
begin
  if not public.has_role('owner', 'principal') then
    raise exception 'Only owner/principal may withdraw results';
  end if;
  perform public.assert_own('exam_terms', p_exam_term_id);
  perform public.assert_own('classes', p_class_id);

  update public.result_cards rc
     set published_at = null
    from public.enrollments e
   where e.id = rc.enrollment_id
     and rc.exam_term_id = p_exam_term_id and e.class_id = p_class_id
     and rc.published_at is not null;

  get diagnostics v_n = row_count;
  return v_n;
end;
$$;

-- Results the parent may see: published, newest version per term, and honouring
-- the term's withhold-from-defaulters setting. A withheld card still appears —
-- silently hiding it looks like the school lost the result — but it carries the
-- reason instead of the marks.
create or replace function public.fn_portal_child_results(p_student_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_out jsonb;
begin
  perform public.fn__assert_my_child(p_student_id);

  select coalesce(jsonb_agg(
           case when x.withheld then
             jsonb_build_object(
               'result_card_id', x.id, 'term', x.term, 'withheld', true,
               'message', 'Result withheld until outstanding fees are cleared.',
               'issued_at', x.issued_at)
           else
             jsonb_build_object(
               'result_card_id', x.id, 'term', x.term, 'withheld', false,
               'obtained_marks', x.total_marks, 'total_marks', x.total_max,
               'percentage', x.percentage, 'grade', x.grade,
               'position', x.position, 'attendance_pct', x.attendance_pct,
               'subjects', coalesce(x.frozen->'subjects', '[]'::jsonb),
               'issued_at', x.issued_at)
           end
           order by x.issued_at desc), '[]'::jsonb)
    into v_out
  from (
    select distinct on (rc.exam_term_id)
           rc.id, et.name as term, rc.total_marks, rc.total_max, rc.percentage,
           rc.grade, rc.position, rc.attendance_pct, rc.frozen,
           rc.published_at as issued_at,
           coalesce((rc.frozen->>'withheld')::boolean, false) as withheld
    from public.result_cards rc
    join public.exam_terms et on et.id = rc.exam_term_id
    where rc.student_id = p_student_id
      and rc.published_at is not null
    order by rc.exam_term_id, rc.version desc
  ) x;

  return coalesce(v_out, '[]'::jsonb);
end;
$$;

grant execute on function public.fn_publish_results(uuid, uuid)   to authenticated;
grant execute on function public.fn_unpublish_results(uuid, uuid) to authenticated;

grant execute on function public.fn_portal_me()                                to authenticated;
grant execute on function public.fn_portal_child_fees(uuid)                    to authenticated;
grant execute on function public.fn_portal_child_attendance(uuid, date, date)  to authenticated;
grant execute on function public.fn_portal_child_results(uuid)                 to authenticated;

-- ─────────────────────────────────────────────────────────────────────────
-- 0034_outbox.sql
-- ─────────────────────────────────────────────────────────────────────────
-- =============================================================================
-- The message outbox — WhatsApp click-to-chat, and the record of what was sent.
--
-- The owner's decision: no paid WhatsApp API, no SMS credits. A button opens
-- WhatsApp with the message pre-filled and the clerk presses send. That is
-- free, it works today, and it is the channel Pakistani parents actually read.
--
-- WHY AN OUTBOX AT ALL, IF SENDING IS MANUAL:
--
-- Because the record is worth more than the delivery. A parent who is told
-- "you always get a WhatsApp receipt" and does not get one goes back to the
-- office and asks why. That turns the parent into an independent witness at
-- the moment cash changes hands — which is a stronger control than any
-- month-end report, because it works the same day and cannot be quietly
-- skipped.
--
-- So every payment writes an outbox row whether or not anyone presses send,
-- and fn_unsent_receipts() surfaces the gap: forty payments recorded, twelve
-- receipts sent. That number is the point of this table.
--
-- Channel-agnostic on purpose. If a paid API is ever switched on, nothing
-- upstream changes — a worker drains the same queue.
-- =============================================================================

create type public.message_status as enum ('queued', 'sent', 'skipped', 'failed');

create table public.message_outbox (
  id            uuid primary key default gen_random_uuid(),
  school_id     uuid not null references public.schools(id) on delete cascade,

  template_key  text not null,          -- 'payment_received' | 'fee_reminder' | ...
  to_name       text,
  to_phone      text,
  family_id     uuid references public.families(id),
  student_id    uuid references public.students(id),
  payment_id    uuid references public.payments(id),

  rendered_text text not null,
  channel       text,                   -- 'whatsapp' once actually sent
  status        public.message_status not null default 'queued',
  sent_by       uuid references public.profiles(id),
  sent_at       timestamptz,
  note          text,

  created_at    timestamptz not null default now()
);

create index idx_outbox_school_created on public.message_outbox (school_id, created_at desc);
create index idx_outbox_status on public.message_outbox (school_id, status);
create index idx_outbox_payment on public.message_outbox (payment_id);

create trigger trg_message_outbox_school before insert or update on public.message_outbox
  for each row execute function public.enforce_school_id();

alter table public.message_outbox enable row level security;

create policy outbox_select on public.message_outbox for select to authenticated
  using (school_id = public.current_school_id()
         and public.has_role('owner', 'principal', 'admin_clerk', 'accountant'));

-- ===========================================================================
-- Templates
--
-- Deliberately five, not twenty-five. A parent who gets a birthday greeting,
-- a staff-late notice and a leave approval from the school stops reading the
-- school's messages, and then the fee reminder does not land either.
-- ===========================================================================

create table public.message_templates (
  school_id    uuid not null references public.schools(id) on delete cascade,
  template_key text not null,
  label        text not null,
  body         text not null,
  enabled      boolean not null default true,
  primary key (school_id, template_key)
);

create trigger trg_message_templates_school before insert or update on public.message_templates
  for each row execute function public.enforce_school_id();
alter table public.message_templates enable row level security;

create policy templates_select on public.message_templates for select to authenticated
  using (school_id = public.current_school_id() and public.is_staff());
create policy templates_write on public.message_templates for all to authenticated
  using (school_id = public.current_school_id() and public.has_role('owner', 'principal'))
  with check (school_id = public.current_school_id() and public.has_role('owner', 'principal'));

create or replace function public.fn__seed_message_templates(p_school uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  insert into public.message_templates (school_id, template_key, label, body) values
    (p_school, 'payment_received', 'Payment received',
     'Assalam-o-Alaikum {parent}. We have received Rs {amount} for {children} on {date}. '
     || 'Receipt #{receipt}. Remaining balance: Rs {balance}. Received by {received_by}. '
     || 'Thank you — {school}.'),
    (p_school, 'fee_reminder', 'Fee reminder',
     'Assalam-o-Alaikum {parent}. A balance of Rs {balance} is outstanding for {children}. '
     || 'Kindly clear it at the school office at your convenience. Thank you — {school}.'),
    (p_school, 'fee_reminder_final', 'Fee reminder (final)',
     'Assalam-o-Alaikum {parent}. Rs {balance} remains outstanding for {children} despite '
     || 'earlier reminders. Please visit the school office this week so we can sort it out '
     || 'together. Thank you — {school}.'),
    (p_school, 'absent_today', 'Absent today',
     'Assalam-o-Alaikum {parent}. {children} was marked absent today, {date}. '
     || 'If this is a mistake please contact the office. — {school}.'),
    (p_school, 'result_published', 'Result published',
     'Assalam-o-Alaikum {parent}. The result for {children} has been published and can be '
     || 'viewed in the parent portal. — {school}.')
  on conflict (school_id, template_key) do nothing;
end;
$$;

do $$
declare s record;
begin
  for s in select id from public.schools loop
    perform public.fn__seed_message_templates(s.id);
  end loop;
end $$;

create or replace function public.fn_provision_message_templates() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  perform public.fn__seed_message_templates(new.id);
  return new;
end;
$$;

create trigger trg_schools_message_templates after insert on public.schools
  for each row execute function public.fn_provision_message_templates();

-- ===========================================================================
-- Rendering
-- ===========================================================================

create or replace function public.fn__render_template(p_body text, p_vars jsonb)
returns text language plpgsql immutable set search_path = public as $$
declare v_out text := p_body; k text;
begin
  for k in select jsonb_object_keys(p_vars) loop
    v_out := replace(v_out, '{' || k || '}', coalesce(p_vars ->> k, ''));
  end loop;
  return v_out;
end;
$$;

-- Queue a message for a family. Returns the outbox row id, or null when the
-- template is switched off or the family has no phone number — a school that
-- does not collect phone numbers must not have its payments start failing.
create or replace function public.fn_queue_message(
  p_template_key text, p_family_id uuid, p_vars jsonb default '{}'::jsonb,
  p_payment_id uuid default null, p_student_id uuid default null
) returns uuid language plpgsql security definer set search_path = public as $$
declare
  v_t record; v_f record; v_id uuid; v_vars jsonb; v_kids text;
begin
  select * into v_t from public.message_templates
  where school_id = public.current_school_id() and template_key = p_template_key;
  if not found or not v_t.enabled then return null; end if;

  select * into v_f from public.families where id = p_family_id;
  if not found then return null; end if;

  select string_agg(s.full_name, ', ' order by s.full_name) into v_kids
  from public.students s where s.family_id = p_family_id and s.deleted_at is null;

  v_vars := jsonb_build_object(
    'parent',   coalesce(v_f.head_name, 'Parent'),
    'children', coalesce(v_kids, 'your child'),
    'school',   coalesce((select name from public.school_settings
                          where school_id = public.current_school_id()), 'the school'),
    'date',     to_char(current_date, 'DD Mon YYYY'),
    'balance',  trim(to_char(public.family_outstanding(p_family_id), 'FM999,999,990'))
  ) || coalesce(p_vars, '{}'::jsonb);

  insert into public.message_outbox (
    template_key, to_name, to_phone, family_id, student_id, payment_id, rendered_text)
  values (
    p_template_key, v_f.head_name,
    coalesce(nullif(btrim(coalesce(v_f.whatsapp, '')), ''), v_f.phone),
    p_family_id, p_student_id, p_payment_id,
    public.fn__render_template(v_t.body, v_vars))
  returning id into v_id;

  return v_id;
end;
$$;

-- Mark one as actually sent, once the clerk has pressed send in WhatsApp.
create or replace function public.fn_mark_message_sent(p_id uuid, p_channel text default 'whatsapp')
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.has_role('owner', 'principal', 'admin_clerk', 'accountant') then
    raise exception 'Not permitted';
  end if;
  perform public.assert_own('message_outbox', p_id);
  update public.message_outbox
     set status = 'sent', channel = p_channel, sent_by = auth.uid(), sent_at = now()
   where id = p_id and status = 'queued';
end;
$$;

create or replace function public.fn_skip_message(p_id uuid, p_reason text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.has_role('owner', 'principal', 'admin_clerk', 'accountant') then
    raise exception 'Not permitted';
  end if;
  perform public.assert_own('message_outbox', p_id);
  update public.message_outbox
     set status = 'skipped', note = p_reason, sent_by = auth.uid(), sent_at = now()
   where id = p_id and status = 'queued';
end;
$$;

-- ===========================================================================
-- THE NUMBER THIS TABLE EXISTS FOR
--
-- Payments taken versus receipts actually sent to the parent. A clerk who
-- records forty payments and sends twelve receipts is not necessarily stealing
-- — but it is the first thing an owner should be able to see, and until now
-- nothing in the system could show it.
-- ===========================================================================

create or replace function public.fn_unsent_receipts(p_from date, p_to date)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_payments integer; v_queued integer; v_sent integer;
begin
  if not public.has_role('owner', 'principal') then
    raise exception 'Not permitted to view this report';
  end if;

  select count(*) into v_payments
  from public.payments p
  where p.school_id = public.current_school_id()
    and p.status = 'verified' and p.amount > 0
    and p.created_at::date between p_from and p_to;

  select count(*) filter (where o.status = 'queued'),
         count(*) filter (where o.status = 'sent')
    into v_queued, v_sent
  from public.message_outbox o
  where o.school_id = public.current_school_id()
    and o.template_key = 'payment_received'
    and o.created_at::date between p_from and p_to;

  return jsonb_build_object(
    'from', p_from, 'to', p_to,
    'payments', coalesce(v_payments, 0),
    'receipts_sent', coalesce(v_sent, 0),
    'receipts_unsent', coalesce(v_queued, 0));
end;
$$;

-- ===========================================================================
-- Payments queue a receipt automatically
--
-- A trigger rather than a call inside each payment function: there are three
-- ways a verified payment comes into existence (family payment, single-student
-- payment, verifying a pending challan) and a fourth will be added one day.
-- Hanging it off the row means none of them can forget.
-- ===========================================================================

create or replace function public.fn__queue_payment_receipt() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  -- Only real, verified, positive money. Reversals and pending challans do not
  -- get a "thank you for your payment" message.
  if new.status <> 'verified' or new.amount <= 0 or new.reversal_of is not null then
    return new;
  end if;
  if new.family_id is null then return new; end if;

  perform public.fn_queue_message(
    'payment_received', new.family_id,
    jsonb_build_object(
      'amount',      trim(to_char(new.amount, 'FM999,999,990')),
      'receipt',     coalesce(new.receipt_no::text, '-'),
      'received_by', coalesce((select full_name from public.profiles
                               where id = new.received_by), 'the office')),
    new.id, new.student_id);
  return new;
exception when others then
  -- A messaging failure must never roll back a payment. The money is the
  -- record that matters; the message is a courtesy on top of it.
  return new;
end;
$$;

-- DEFERRED, and that matters.
--
-- The message quotes the family's remaining balance, and the balance is only
-- correct once fn__allocate_payment has run — which happens AFTER the insert,
-- inside the same function. A plain AFTER INSERT trigger fires too early and
-- would tell every parent the balance they had BEFORE they paid, which is
-- worse than sending nothing.
--
-- A deferred constraint trigger fires at commit, by which time the allocation
-- rows exist and family_outstanding() is true.
create constraint trigger trg_payments_queue_receipt
  after insert on public.payments
  deferrable initially deferred
  for each row execute function public.fn__queue_payment_receipt();

grant execute on function public.fn_queue_message(text, uuid, jsonb, uuid, uuid) to authenticated;
grant execute on function public.fn_mark_message_sent(uuid, text)                to authenticated;
grant execute on function public.fn_skip_message(uuid, text)                      to authenticated;
grant execute on function public.fn_unsent_receipts(date, date)                   to authenticated;

revoke all on function public.fn__seed_message_templates(uuid) from public, anon, authenticated;
revoke all on function public.fn__queue_payment_receipt()      from public, anon, authenticated;

-- ─────────────────────────────────────────────────────────────────────────
-- 0035_fee_ops.sql
-- ─────────────────────────────────────────────────────────────────────────
-- =============================================================================
-- Fee operations: the annual raise, and a scannable challan.
--
-- 1. EFFECTIVE-DATED FEE STRUCTURES
--
-- fee_structures was unique on (session, class, head) — one amount, forever.
-- Every Pakistani school raises fees at least once a year, and doing that here
-- meant editing every class and every head by hand. That afternoon is exactly
-- when a school decides the software is a burden.
--
-- Amounts now carry effective_from, and billing picks the row in force for the
-- month being billed. Nothing is ever updated in place, so a raise leaves the
-- old amount visible beside the new one and last year's invoices still explain
-- themselves. (Past invoices were already safe — invoice_lines snapshots the
-- amount — but the STRUCTURE had no memory, so "what did Class 5 pay in
-- March?" was unanswerable.)
--
-- 2. SCANNABLE CHALLANS
--
-- A short code on the printed challan that the clerk scans at the counter.
-- Beyond speed, it removes the wrong-student posting error, which is the
-- mistake that is indistinguishable from theft when it surfaces months later.
-- =============================================================================

-- ===========================================================================
-- 1. Effective dating
-- ===========================================================================

alter table public.fee_structures
  add column effective_from date not null default date '1900-01-01';

alter table public.fee_structures
  drop constraint fee_structures_session_id_class_id_fee_head_id_key;

alter table public.fee_structures
  add constraint fee_structures_effective_key
  unique (session_id, class_id, fee_head_id, effective_from);

create index idx_fee_structures_lookup
  on public.fee_structures (session_id, class_id, fee_head_id, effective_from desc);

-- The amount in force for a given month. One definition, used by billing and
-- by the preview, so a preview can never disagree with what generation does.
create or replace function public.fn_fee_amount(
  p_session_id uuid, p_class_id uuid, p_fee_head_id uuid, p_on date
) returns numeric language sql stable security definer set search_path = public as $$
  select fs.amount
  from public.fee_structures fs
  where fs.session_id = p_session_id
    and fs.class_id = p_class_id
    and fs.fee_head_id = p_fee_head_id
    and fs.effective_from <= coalesce(p_on, current_date)
  order by fs.effective_from desc
  limit 1;
$$;

-- Billing now reads the effective amount instead of the single row.
-- Everything else about this function is unchanged from 0029.
create or replace function public.fn_generate_class_invoices(
  p_session_id uuid, p_class_id uuid, p_period_month date, p_due_date date
) returns integer language plpgsql security definer set search_path = public as $$
declare
  v_actor    uuid := auth.uid();
  v_school   uuid := public.current_school_id();
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

    -- A per-student override (student_fee_items) still wins over the class
    -- amount; the class amount is now the one in force for the billed month.
    insert into public.invoice_lines(invoice_id, fee_head_id, description, amount, is_discount)
    select v_inv, fh.id, fh.name, coalesce(sfi.amount, amt.amount), false
    from public.fee_heads fh
    join lateral (
      select fs.amount
      from public.fee_structures fs
      where fs.session_id = p_session_id
        and fs.class_id = p_class_id
        and fs.fee_head_id = fh.id
        and fs.effective_from <= coalesce(p_period_month, current_date)
      order by fs.effective_from desc
      limit 1
    ) amt on true
    left join public.student_fee_items sfi
      on sfi.enrollment_id = v_enr.enrollment_id and sfi.fee_head_id = fh.id and sfi.active
    where fh.school_id = v_school and fh.is_recurring and fh.active;

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
-- 2. The annual raise
--
-- Preview → commit, the same shape as fn_rollover, because a fee raise applied
-- to the wrong classes is discovered by four hundred angry parents.
-- ===========================================================================

create or replace function public.fn_fee_increment(
  p_session_id     uuid,
  p_class_ids      uuid[],          -- null = every class in the session
  p_fee_head_ids   uuid[],          -- null = every recurring head
  p_percent        numeric,         -- either a percent...
  p_amount         numeric,         -- ...or a flat rupee amount. Not both.
  p_effective_from date,
  p_commit         boolean default false
) returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_school uuid := public.current_school_id();
  r        record;
  v_new    numeric;
  v_rows   jsonb := '[]'::jsonb;
  v_n      integer := 0;
begin
  if not public.has_role('owner', 'principal') then
    raise exception 'Only owner/principal may change fees';
  end if;
  perform public.assert_own('academic_sessions', p_session_id);

  if (p_percent is null) = (p_amount is null) then
    raise exception 'Give either a percentage or a flat amount, not both and not neither';
  end if;
  if coalesce(p_percent, 0) < 0 or coalesce(p_amount, 0) < 0 then
    raise exception 'Use a positive figure. To reduce a fee, set the new amount directly.';
  end if;
  if p_effective_from is null then
    raise exception 'A fee change needs a date it takes effect from';
  end if;

  for r in
    select fs.class_id, c.name as class_name,
           fs.fee_head_id, fh.name as head_name,
           public.fn_fee_amount(p_session_id, fs.class_id, fs.fee_head_id,
                                p_effective_from) as current_amount
    from public.fee_structures fs
    join public.classes c on c.id = fs.class_id
    join public.fee_heads fh on fh.id = fs.fee_head_id
    where fs.session_id = p_session_id
      and fs.school_id = v_school
      and (p_class_ids is null or fs.class_id = any(p_class_ids))
      and (p_fee_head_ids is null or fs.fee_head_id = any(p_fee_head_ids))
    group by fs.class_id, c.name, fs.fee_head_id, fh.name
    order by c.name, fh.name
  loop
    v_new := round(
      case when p_percent is not null
           then coalesce(r.current_amount, 0) * (1 + p_percent / 100.0)
           else coalesce(r.current_amount, 0) + p_amount
      end, 0);

    v_rows := v_rows || jsonb_build_object(
      'class', r.class_name, 'fee_head', r.head_name,
      'from', r.current_amount, 'to', v_new);
    v_n := v_n + 1;

    if p_commit then
      insert into public.fee_structures
        (session_id, class_id, fee_head_id, amount, effective_from, school_id)
      values (p_session_id, r.class_id, r.fee_head_id, v_new, p_effective_from, v_school)
      on conflict (session_id, class_id, fee_head_id, effective_from)
      do update set amount = excluded.amount;
    end if;
  end loop;

  return jsonb_build_object(
    'committed', p_commit,
    'effective_from', p_effective_from,
    'changes', v_n,
    'rows', v_rows);
end;
$$;

-- ===========================================================================
-- 3. Scannable challans
-- ===========================================================================

alter table public.invoices add column voucher_code text;

-- Short, unambiguous, printable as Code128 and typeable when the scanner dies.
-- Characters that look alike (0/O, 1/I) are excluded from the alphabet.
create or replace function public.fn__voucher_code() returns text
language plpgsql volatile set search_path = public as $$
declare
  v_alpha text := '23456789ABCDEFGHJKLMNPQRSTUVWXYZ';
  v_out   text := '';
  i integer;
begin
  for i in 1..8 loop
    v_out := v_out || substr(v_alpha, 1 + floor(random() * length(v_alpha))::int, 1);
  end loop;
  return v_out;
end;
$$;

create or replace function public.fn__stamp_voucher_code() returns trigger
language plpgsql security definer set search_path = public as $$
declare i integer := 0;
begin
  if new.voucher_code is not null then return new; end if;
  loop
    new.voucher_code := public.fn__voucher_code();
    exit when not exists (
      select 1 from public.invoices
      where school_id = new.school_id and voucher_code = new.voucher_code);
    i := i + 1;
    if i > 20 then
      -- Never block a challan over a code collision.
      new.voucher_code := null;
      exit;
    end if;
  end loop;
  return new;
end;
$$;

-- Sorts after trg_invoices_school so school_id is already stamped.
create trigger trg_invoices_zz_voucher before insert on public.invoices
  for each row execute function public.fn__stamp_voucher_code();

create unique index uq_invoices_voucher
  on public.invoices (school_id, voucher_code) where voucher_code is not null;

-- Backfill existing invoices so every challan in the system can be scanned.
do $$
declare r record; v_code text; i integer;
begin
  for r in select id, school_id from public.invoices where voucher_code is null loop
    i := 0;
    loop
      v_code := public.fn__voucher_code();
      exit when not exists (
        select 1 from public.invoices
        where school_id = r.school_id and voucher_code = v_code);
      i := i + 1;
      exit when i > 20;
    end loop;
    update public.invoices set voucher_code = v_code where id = r.id;
  end loop;
end $$;

-- Scan at the counter: resolve a code to the FAMILY, because that is what the
-- collection screen works in. Scanning one child's challan brings up the whole
-- family, which is what the parent is standing there to pay.
create or replace function public.fn_find_by_voucher(p_code text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_inv record;
begin
  if not public.has_role('owner','principal','admin_clerk','accountant') then
    raise exception 'Not permitted';
  end if;

  select i.id, i.student_id, i.period_month, s.full_name, s.family_id
    into v_inv
  from public.invoices i
  join public.students s on s.id = i.student_id
  where i.school_id = public.current_school_id()
    and i.voucher_code = upper(btrim(coalesce(p_code, '')))
    and i.status <> 'void';

  if not found then return null; end if;

  return jsonb_build_object(
    'invoice_id', v_inv.id,
    'student_id', v_inv.student_id,
    'student_name', v_inv.full_name,
    'family_id', v_inv.family_id,
    'period_month', v_inv.period_month);
end;
$$;

-- ===========================================================================
-- 4. Head-wise dues
--
-- Which fee head is unpaid across the school. Allocations are invoice-level,
-- not line-level, so collections are apportioned across heads IN PROPORTION to
-- their share of each invoice. That rule is stated on the report itself: a
-- number whose derivation is hidden is one an owner cannot defend.
-- ===========================================================================

create or replace function public.fn_head_wise_dues(p_session_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_rows jsonb;
begin
  if not public.has_role('owner', 'principal', 'accountant') then
    raise exception 'Not permitted to view fee reports';
  end if;
  perform public.assert_own('academic_sessions', p_session_id);

  select coalesce(jsonb_agg(x order by x.charged desc), '[]'::jsonb) into v_rows
  from (
    select coalesce(l.description, 'Other') as fee_head,
           sum(case when l.is_discount then -l.amount else l.amount end) as charged,
           sum(
             case when b.charge > 0
                  then (case when l.is_discount then -l.amount else l.amount end)
                       * (b.allocated / b.charge)
                  else 0 end
           ) as collected
    from public.invoice_lines l
    join public.invoices i on i.id = l.invoice_id
    join public.invoice_balances b on b.invoice_id = i.id
    where i.session_id = p_session_id
      and i.school_id = public.current_school_id()
      and i.status <> 'void'
    group by 1
  ) x;

  return jsonb_build_object(
    'session_id', p_session_id,
    'basis', 'Collections are apportioned across fee heads in proportion to '
             || 'their share of each invoice.',
    'heads', v_rows);
end;
$$;

grant execute on function public.fn_fee_amount(uuid, uuid, uuid, date) to authenticated;
grant execute on function public.fn_fee_increment(uuid, uuid[], uuid[], numeric, numeric, date, boolean) to authenticated;
grant execute on function public.fn_find_by_voucher(text)              to authenticated;
grant execute on function public.fn_head_wise_dues(uuid)               to authenticated;

revoke all on function public.fn__stamp_voucher_code() from public, anon, authenticated;

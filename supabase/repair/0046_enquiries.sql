-- =============================================================================
-- REPAIR: migration 0046_enquiries, on its own.
--
-- Run supabase/repair/detect.sql FIRST. Run only the files it marks MISSING,
-- in ascending order. Then re-run 5_search.sql, then verify.sql.
--
-- WHY 5_search AFTERWARDS IS NOT OPTIONAL: migrations 0050-0056 replace some of
-- the functions these files define with newer versions. Applying an older file
-- now puts the OLD version back until bundle 5 restores it. Concretely: 0038
-- defines fn_recent_payments and 0052 fixes its ordering, so applying 0038
-- without re-running bundle 5 reintroduces a payment list that reshuffles
-- itself between page loads.
--
-- One file per migration, because a single concatenated repair CANNOT work:
-- different schools stopped at different points inside bundle 3, so any fixed
-- starting migration is already applied for somebody and fails on its first
-- statement. That is exactly what happened with the first version of this.
-- =============================================================================

-- =============================================================================
-- 0046 — Admission enquiries. Their "Admission Inquiries", which is how a
--        Pakistani private school actually wins the admission season.
--
-- WHAT THIS IS FOR
--
-- A parent walks in during February and asks whether there is space in Class 3.
-- They are not admitting a child today. If nobody writes that down, and nobody
-- rings them back in a week, they go to the school down the road. Every school
-- of this size loses admissions this way and does not know it, because the loss
-- leaves no record anywhere.
--
-- So this is not a CRM. It is four things:
--
--   1. Write the enquiry down in fifteen seconds, with only a name and a phone
--      number required — a clerk taking a call cannot stop to fill a form.
--   2. Say who to ring TODAY. A lead list nobody calls is a list nobody reads,
--      the same way a defaulter list full of families who have already paid is
--      a list nobody reads.
--   3. Keep the follow-up history append-only, so "we called twice and they
--      said the fee was too high" survives the clerk who leaves.
--   4. Convert to a real admission in one action, WITHOUT retyping anything,
--      and keep the enquiry afterwards — the conversion record is the only
--      marketing data a school of this size will ever have.
--
-- TWO THINGS THIS DELIBERATELY DOES NOT DO
--
-- It does not delete. A lost enquiry becomes status 'lost' with a reason,
-- because "why did we not get these thirty children" is the whole value of the
-- table and a DELETE throws it away.
--
-- It does not reimplement admission. fn_enquiry_admit delegates to
-- fn_admit_student, so the GR number, the family linkage from 0036, the
-- admission fee and the subscription student limit all behave identically
-- whether a child arrives through an enquiry or straight off the street. A
-- second admission path that drifts from the first is a bug factory.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. Vocabulary
--
-- `source` exists so a school can answer "where do our admissions come from" at
-- the end of a season. A banner on the main road costs real money; knowing that
-- it produced four enquiries and one admission is worth having.
-- ---------------------------------------------------------------------------
do $$ begin
  if not exists (select 1 from pg_type where typname = 'enquiry_status') then
    create type public.enquiry_status as enum
      ('new', 'contacted', 'visited', 'admitted', 'lost');
  end if;
  if not exists (select 1 from pg_type where typname = 'enquiry_source') then
    create type public.enquiry_source as enum
      ('walk_in', 'phone', 'referral', 'banner', 'social_media', 'other');
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 2. The enquiry
--
-- Only child_name and phone are required. Everything else is optional on
-- purpose: a clerk on the phone gets a name and a number, and being forced to
-- invent a date of birth is how a record ends up not being made at all.
--
-- class_id is nullable and NOT a foreign-key requirement of the workflow — a
-- parent asking "what classes do you have" has not chosen one yet.
-- ---------------------------------------------------------------------------
create table if not exists public.admission_enquiries (
  id            uuid primary key default gen_random_uuid(),
  school_id     uuid not null references public.schools(id) on delete cascade,
  -- Per-school and gapless, like the GR number, so a school can say "enquiry
  -- 47" on the phone and both sides find the same row.
  enquiry_no    bigint not null,
  child_name    text not null,
  father_name   text,
  father_cnic   text,
  phone         text not null,
  whatsapp      text,
  address       text,
  dob           date,
  gender        text,
  -- What they asked about. Kept as ids where known so conversion can prefill,
  -- and as free text where not.
  session_id    uuid references public.academic_sessions(id),
  class_id      uuid references public.classes(id),
  class_wanted  text,
  source        public.enquiry_source not null default 'walk_in',
  source_note   text,
  status        public.enquiry_status not null default 'new',
  -- The single most important column in the table: who do I ring today.
  follow_up_on  date,
  notes         text,
  -- Set only when status = 'lost'. Not free-form-optional: the whole point of
  -- recording a loss is knowing why.
  lost_reason   text,
  -- Set by fn_enquiry_admit. The enquiry is never deleted on conversion.
  admitted_student_id uuid references public.students(id),
  admitted_at   timestamptz,
  created_by    uuid references public.profiles(id),
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  constraint uq_enquiry_no unique (school_id, enquiry_no),
  -- A lost enquiry must say why, and an open one must not claim a student.
  constraint ck_enquiry_lost_reason
    check (status <> 'lost' or nullif(btrim(coalesce(lost_reason, '')), '') is not null),
  constraint ck_enquiry_admitted
    check ((status = 'admitted') = (admitted_student_id is not null))
);

create index if not exists idx_enquiries_school_followup
  on public.admission_enquiries (school_id, follow_up_on)
  where status in ('new', 'contacted', 'visited');
create index if not exists idx_enquiries_school_status
  on public.admission_enquiries (school_id, status, created_at desc);
create index if not exists idx_enquiries_school_phone
  on public.admission_enquiries (school_id, phone);

-- ---------------------------------------------------------------------------
-- 3. The follow-up log — append only
--
-- Overwriting a `notes` column loses the history, and the history is the
-- product: "rang 3 Feb, no answer; rang 6 Feb, wants to see the science lab;
-- visited 9 Feb" is what lets whoever is on duty pick up the thread. Same
-- reasoning as payments: never edit, always append.
-- ---------------------------------------------------------------------------
create table if not exists public.enquiry_contacts (
  id          uuid primary key default gen_random_uuid(),
  school_id   uuid not null references public.schools(id) on delete cascade,
  enquiry_id  uuid not null references public.admission_enquiries(id) on delete cascade,
  contacted_at timestamptz not null default now(),
  -- What happened, in the school's words. Free text on purpose: a fixed
  -- outcome list would be guessing at how these conversations go.
  outcome     text not null,
  note        text,
  contacted_by uuid references public.profiles(id),
  created_at  timestamptz not null default now()
);

create index if not exists idx_enquiry_contacts_enquiry
  on public.enquiry_contacts (enquiry_id, contacted_at desc);

-- ---------------------------------------------------------------------------
-- 4. Tenant plumbing — the same shape every other tenant table uses
-- ---------------------------------------------------------------------------
do $$
declare t text;
begin
  foreach t in array array['admission_enquiries', 'enquiry_contacts'] loop
    if not exists (select 1 from pg_trigger
                   where tgname = format('trg_%s_school', t)
                     and tgrelid = format('public.%I', t)::regclass) then
      execute format(
        'create trigger trg_%1$s_school before insert or update on public.%1$s
           for each row execute function public.enforce_school_id();', t);
    end if;
    if not exists (select 1 from pg_trigger
                   where tgname = format('trg_audit_%s', t)
                     and tgrelid = format('public.%I', t)::regclass) then
      execute format(
        'create trigger trg_audit_%1$s after insert or update or delete on public.%1$s
           for each row execute function public.audit_trigger();', t);
    end if;
    execute format('alter table public.%I enable row level security;', t);
  end loop;
end $$;

-- Front-office data. A clerk on reception is exactly who takes these calls, so
-- admin_clerk reads and writes; teachers have no business in the enquiry book.
drop policy if exists enquiries_select on public.admission_enquiries;
create policy enquiries_select on public.admission_enquiries for select to authenticated
  using (school_id = public.current_school_id()
         and public.has_role('owner', 'principal', 'admin_clerk'));

drop policy if exists enquiry_contacts_select on public.enquiry_contacts;
create policy enquiry_contacts_select on public.enquiry_contacts for select to authenticated
  using (school_id = public.current_school_id()
         and public.has_role('owner', 'principal', 'admin_clerk'));

-- No INSERT/UPDATE/DELETE policy on either table. Every write goes through the
-- SECURITY DEFINER functions below so that the enquiry number stays gapless,
-- the status transitions stay legal, and a conversion cannot happen twice. A
-- direct insert would bypass all three.

-- ---------------------------------------------------------------------------
-- 5. Two more message templates
--
-- Their SMS list has "Inquiry Add" and "Inquiry Admit". Same triggers, same
-- merge tags, WhatsApp instead of SMS — the rule recorded in docs/PARITY.md.
--
-- These two are the first templates addressed to somebody who is NOT a family:
-- an enquiry has no family and no student yet, just a name and a phone number.
-- So {children} and {balance} would never resolve and are deliberately absent
-- from their tag lists; {child} and {enquiry_no} take their place.
-- ---------------------------------------------------------------------------
create or replace function public.fn__default_message_templates()
returns table (template_key text, label text, body text, tags text[])
language sql immutable set search_path = public as $$
  values
    ('payment_received', 'Payment received',
     'Assalam-o-Alaikum {parent}. We have received Rs {amount} for {children} on {date}. '
     || 'Receipt #{receipt}. Remaining balance: Rs {balance}. Received by {received_by}. '
     || 'Thank you — {school}.',
     array['parent','children','school','date','balance','amount','receipt','received_by']),

    ('fee_reminder', 'Fee reminder',
     'Assalam-o-Alaikum {parent}. A balance of Rs {balance} is outstanding for {children}. '
     || 'Kindly clear it at the school office at your convenience. Thank you — {school}.',
     array['parent','children','school','date','balance','amount']),

    ('fee_reminder_final', 'Fee reminder (final)',
     'Assalam-o-Alaikum {parent}. Rs {balance} remains outstanding for {children} despite '
     || 'earlier reminders. Please visit the school office this week so we can sort it out '
     || 'together. Thank you — {school}.',
     array['parent','children','school','date','balance','amount']),

    ('absent_today', 'Absent today',
     'Assalam-o-Alaikum {parent}. {children} was marked absent today, {date}. '
     || 'If this is a mistake please contact the office. — {school}.',
     array['parent','children','school','date','balance']),

    ('result_published', 'Result published',
     'Assalam-o-Alaikum {parent}. The result for {children} has been published and can be '
     || 'viewed in the parent portal. — {school}.',
     array['parent','children','school','date','balance']),

    ('enquiry_received', 'Admission enquiry received',
     'Assalam-o-Alaikum {parent}. Thank you for your interest in {school} for {child}. '
     || 'Your enquiry number is {enquiry_no}. We will contact you shortly. '
     || 'For anything urgent please call the school office.',
     array['parent','child','school','date','enquiry_no','class_wanted']),

    ('enquiry_admitted', 'Enquiry admitted',
     'Assalam-o-Alaikum {parent}. We are pleased to confirm the admission of {child} '
     || 'at {school}. GR number {gr_no}. Please visit the office to complete the '
     || 'remaining formalities. — {school}.',
     array['parent','child','school','date','enquiry_no','gr_no','class_wanted'])
$$;

-- ---------------------------------------------------------------------------
-- 5b. message_outbox needs to point at an enquiry
--
-- The table already links a queued message to a family, a student or a payment.
-- An enquiry message could link to none of them, so a clerk looking at the
-- WhatsApp queue would see "Thank you for your interest in..." with no way to
-- open the enquiry it came from, and nothing could report which enquiries had
-- actually been acknowledged.
-- ---------------------------------------------------------------------------
alter table public.message_outbox
  add column if not exists enquiry_id uuid references public.admission_enquiries(id)
    on delete set null;

create index if not exists idx_outbox_enquiry
  on public.message_outbox (enquiry_id) where enquiry_id is not null;

-- ---------------------------------------------------------------------------
-- 6. Queue a message to an enquiry rather than a family
--
-- Mirrors fn_queue_message, including the `enabled` check that makes the
-- Automation Settings toggle mean something, but resolves the recipient from
-- the enquiry. It cannot reuse fn_queue_message because that function looks up
-- a family and returns null when it does not find one — which is every enquiry.
-- ---------------------------------------------------------------------------
create or replace function public.fn_queue_enquiry_message(
  p_template_key text, p_enquiry_id uuid, p_vars jsonb default '{}'::jsonb)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  v_t      record;
  v_e      record;
  v_id     uuid;
  v_vars   jsonb;
  v_school uuid := public.current_school_id();
begin
  select * into v_t from public.message_templates
  where school_id = v_school and template_key = p_template_key;
  -- Not an error. A school that has switched this message off gets no message,
  -- and the action that triggered it still succeeds.
  if not found or not v_t.enabled then return null; end if;

  select * into v_e from public.admission_enquiries
  where id = p_enquiry_id and school_id = v_school;
  if not found then return null; end if;

  -- No phone, no message — and emphatically not an error. Losing an enquiry
  -- because a parent did not leave a number would be absurd.
  if nullif(btrim(coalesce(v_e.phone, '')), '') is null
     and nullif(btrim(coalesce(v_e.whatsapp, '')), '') is null then
    return null;
  end if;

  v_vars := jsonb_build_object(
    'parent',       coalesce(nullif(btrim(coalesce(v_e.father_name, '')), ''), 'Parent'),
    'child',        v_e.child_name,
    'school',       coalesce((select name from public.school_settings
                              where school_id = v_school), 'the school'),
    'date',         to_char(current_date, 'DD Mon YYYY'),
    'enquiry_no',   v_e.enquiry_no::text,
    'class_wanted', coalesce(
                      (select c.name from public.classes c
                        where c.id = v_e.class_id and c.school_id = v_school),
                      nullif(btrim(coalesce(v_e.class_wanted, '')), ''),
                      'the class you asked about')
  ) || coalesce(p_vars, '{}'::jsonb);

  insert into public.message_outbox (
    template_key, to_name, to_phone, enquiry_id, rendered_text)
  values (
    p_template_key,
    coalesce(nullif(btrim(coalesce(v_e.father_name, '')), ''), v_e.child_name),
    -- WhatsApp number wins over the landline, the same precedence
    -- fn_queue_message uses for a family.
    coalesce(nullif(btrim(coalesce(v_e.whatsapp, '')), ''), v_e.phone),
    p_enquiry_id,
    public.fn__render_template(v_t.body, v_vars))
  returning id into v_id;

  return v_id;
end;
$$;

-- ---------------------------------------------------------------------------
-- 7. Record an enquiry
--
-- Returns the new row plus a `possible_duplicate` hint. It WARNS rather than
-- blocks: the same phone number enquiring twice is usually a second child, and
-- refusing the second one would be wrong. But a clerk who has just taken the
-- same call twice should be told.
-- ---------------------------------------------------------------------------
create or replace function public.fn_add_enquiry(p jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_school uuid := public.current_school_id();
  v_actor  uuid := auth.uid();
  v_no     bigint;
  v_id     uuid;
  v_phone  text := nullif(btrim(coalesce(p->>'phone', '')), '');
  v_child  text := nullif(btrim(coalesce(p->>'child_name', '')), '');
  v_dup    jsonb := 'null'::jsonb;
  v_msg    uuid;
begin
  if not public.has_role('owner', 'principal', 'admin_clerk') then
    raise exception 'Not permitted to record an enquiry' using errcode = '42501';
  end if;
  if v_child is null then
    raise exception 'The child''s name is required';
  end if;
  if v_phone is null then
    raise exception 'A phone number is required — an enquiry nobody can ring is not an enquiry';
  end if;

  -- The warning, computed before the insert so the new row cannot match itself.
  select jsonb_build_object('id', e.id, 'enquiry_no', e.enquiry_no,
                            'child_name', e.child_name, 'status', e.status,
                            'created_at', e.created_at)
    into v_dup
  from public.admission_enquiries e
  where e.school_id = v_school
    and e.phone = v_phone
    and lower(btrim(e.child_name)) = lower(v_child)
  order by e.created_at desc
  limit 1;

  v_no := public.next_counter('enquiry');

  insert into public.admission_enquiries (
    school_id, enquiry_no, child_name, father_name, father_cnic, phone, whatsapp,
    address, dob, gender, session_id, class_id, class_wanted, source, source_note,
    follow_up_on, notes, created_by)
  values (
    v_school, v_no, v_child,
    nullif(btrim(coalesce(p->>'father_name', '')), ''),
    nullif(btrim(coalesce(p->>'father_cnic', '')), ''),
    v_phone,
    nullif(btrim(coalesce(p->>'whatsapp', '')), ''),
    nullif(btrim(coalesce(p->>'address', '')), ''),
    nullif(p->>'dob', '')::date,
    nullif(btrim(coalesce(p->>'gender', '')), ''),
    nullif(p->>'session_id', '')::uuid,
    nullif(p->>'class_id', '')::uuid,
    nullif(btrim(coalesce(p->>'class_wanted', '')), ''),
    coalesce(nullif(p->>'source', '')::public.enquiry_source, 'walk_in'),
    nullif(btrim(coalesce(p->>'source_note', '')), ''),
    -- Default the follow-up to three days out rather than leaving it null. An
    -- enquiry with no follow-up date never appears on anybody's list, which is
    -- the exact failure this table exists to prevent.
    coalesce(nullif(p->>'follow_up_on', '')::date, current_date + 3),
    nullif(btrim(coalesce(p->>'notes', '')), ''),
    v_actor)
  returning id into v_id;

  v_msg := public.fn_queue_enquiry_message('enquiry_received', v_id);

  return jsonb_build_object(
    'enquiry_id',        v_id,
    'enquiry_no',        v_no,
    'message_queued',    v_msg is not null,
    'possible_duplicate', v_dup);
end;
$$;

-- ---------------------------------------------------------------------------
-- 8. Log a follow-up
--
-- Appends to the history AND moves the next follow-up date, in one call,
-- because doing one without the other is how an enquiry falls off the list.
-- Advancing 'new' to 'contacted' here too: a clerk who has just rung somebody
-- should not also have to remember to change a dropdown.
-- ---------------------------------------------------------------------------
create or replace function public.fn_log_enquiry_contact(
  p_enquiry_id uuid, p_outcome text, p_note text default null,
  p_next_follow_up date default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_school uuid := public.current_school_id();
  v_e      record;
  v_id     uuid;
begin
  if not public.has_role('owner', 'principal', 'admin_clerk') then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  if nullif(btrim(coalesce(p_outcome, '')), '') is null then
    raise exception 'Say what happened — an empty follow-up tells the next person nothing';
  end if;

  select * into v_e from public.admission_enquiries
  where id = p_enquiry_id and school_id = v_school;
  if not found then raise exception 'Enquiry not found'; end if;
  if v_e.status in ('admitted', 'lost') then
    raise exception 'Enquiry % is already closed as %', v_e.enquiry_no, v_e.status;
  end if;

  insert into public.enquiry_contacts (school_id, enquiry_id, outcome, note, contacted_by)
  values (v_school, p_enquiry_id, btrim(p_outcome),
          nullif(btrim(coalesce(p_note, '')), ''), auth.uid())
  returning id into v_id;

  update public.admission_enquiries
     set status       = case when status = 'new' then 'contacted' else status end,
         follow_up_on = coalesce(p_next_follow_up, follow_up_on),
         updated_at   = now()
   where id = p_enquiry_id and school_id = v_school;

  return jsonb_build_object('contact_id', v_id);
end;
$$;

-- ---------------------------------------------------------------------------
-- 9. Change status by hand
--
-- 'visited' when they come and see the school; 'lost' when they do not come.
-- Admission goes through fn_enquiry_admit, never through here — otherwise an
-- enquiry could be marked admitted with no student behind it, which the
-- ck_enquiry_admitted constraint refuses anyway.
-- ---------------------------------------------------------------------------
create or replace function public.fn_set_enquiry_status(
  p_enquiry_id uuid, p_status text, p_lost_reason text default null,
  p_next_follow_up date default null)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_school uuid := public.current_school_id();
  v_new    public.enquiry_status := p_status::public.enquiry_status;
  v_e      record;
begin
  if not public.has_role('owner', 'principal', 'admin_clerk') then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  if v_new = 'admitted' then
    raise exception 'Use fn_enquiry_admit to admit — it creates the student record too';
  end if;
  if v_new = 'lost' and nullif(btrim(coalesce(p_lost_reason, '')), '') is null then
    -- RAISE takes a format literal, not an expression, so this cannot be a
    -- concatenation however long the sentence gets.
    raise exception 'Say why it was lost. "Why did we not get these children" is the only question this table exists to answer';
  end if;

  select * into v_e from public.admission_enquiries
  where id = p_enquiry_id and school_id = v_school;
  if not found then raise exception 'Enquiry not found'; end if;
  if v_e.status = 'admitted' then
    raise exception 'Enquiry % is already admitted; reopening it would orphan the student',
      v_e.enquiry_no;
  end if;

  update public.admission_enquiries
     set status      = v_new,
         lost_reason = case when v_new = 'lost' then btrim(p_lost_reason) else null end,
         -- A closed enquiry drops off the follow-up list; a reopened one needs
         -- a date or it silently vanishes from every screen.
         follow_up_on = case when v_new = 'lost' then null
                            else coalesce(p_next_follow_up, follow_up_on,
                                          current_date + 3) end,
         updated_at  = now()
   where id = p_enquiry_id and school_id = v_school;
end;
$$;

-- ---------------------------------------------------------------------------
-- 10. Convert an enquiry into a student
--
-- Delegates to fn_admit_student so there is exactly one admission path. The
-- enquiry's own details prefill anything the caller does not override, so the
-- clerk retypes nothing — that is the whole reason to convert rather than
-- admit fresh.
-- ---------------------------------------------------------------------------
create or replace function public.fn_enquiry_admit(
  p_enquiry_id uuid, p_overrides jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_school  uuid := public.current_school_id();
  v_e       record;
  v_payload jsonb;
  v_res     jsonb;
  v_student uuid;
  v_msg     uuid;
begin
  if not public.has_role('owner', 'principal', 'admin_clerk') then
    raise exception 'Not permitted' using errcode = '42501';
  end if;

  select * into v_e from public.admission_enquiries
  where id = p_enquiry_id and school_id = v_school;
  if not found then raise exception 'Enquiry not found'; end if;
  -- The guard that matters. Without it a double-click admits the same child
  -- twice, burning a GR number and creating a duplicate the school then has to
  -- find and unpick.
  if v_e.admitted_student_id is not null then
    raise exception 'Enquiry % was already admitted', v_e.enquiry_no;
  end if;
  if v_e.status = 'lost' then
    raise exception 'Enquiry % is marked lost. Reopen it first, so the record shows what happened', v_e.enquiry_no;
  end if;

  -- Enquiry details first, caller's overrides second, so the override wins.
  -- Nulls are stripped: a null in the payload would otherwise beat a real value
  -- from the enquiry.
  v_payload := jsonb_strip_nulls(jsonb_build_object(
    'full_name',   v_e.child_name,
    'father_name', v_e.father_name,
    'father_cnic', v_e.father_cnic,
    'phone',       v_e.phone,
    'whatsapp',    v_e.whatsapp,
    'address',     v_e.address,
    'dob',         v_e.dob,
    'gender',      v_e.gender,
    -- Fall back to the school's CURRENT session when the enquiry never named
    -- one. Most enquiries do not: a parent asking in February about "next year"
    -- has not picked a session, and the clerk taking the call should not have to
    -- either. Without this fallback conversion failed with fn_admit_student's
    -- bare "Academic session is required", which tells a clerk nothing about
    -- what to do next.
    'session_id',  coalesce(v_e.session_id,
                     (select ss.current_session_id from public.school_settings ss
                       where ss.school_id = v_school)),
    'class_id',    v_e.class_id
  )) || jsonb_strip_nulls(coalesce(p_overrides, '{}'::jsonb));

  -- Check what is still missing HERE, naming the thing the clerk has to supply.
  -- fn_admit_student's own guards are correct but speak about a payload the
  -- clerk never saw.
  if nullif(v_payload->>'session_id', '') is null then
    raise exception 'This school has no current academic session set, so there is nothing to admit into. Set one in Settings first, or pass a session explicitly';
  end if;
  if nullif(v_payload->>'class_id', '') is null then
    raise exception 'Enquiry % does not say which class. Choose one when admitting', v_e.enquiry_no;
  end if;

  -- One admission path. The GR number, the family linkage from 0036, the
  -- admission fee and the subscription student limit all apply here exactly as
  -- they do for a walk-in.
  v_res := public.fn_admit_student(v_payload);
  v_student := nullif(v_res->>'student_id', '')::uuid;
  if v_student is null then
    raise exception 'Admission did not return a student for enquiry %', v_e.enquiry_no;
  end if;

  update public.admission_enquiries
     set status              = 'admitted',
         admitted_student_id = v_student,
         admitted_at         = now(),
         lost_reason         = null,
         follow_up_on        = null,
         updated_at          = now()
   where id = p_enquiry_id and school_id = v_school;

  v_msg := public.fn_queue_enquiry_message('enquiry_admitted', p_enquiry_id,
    jsonb_build_object('gr_no', coalesce(v_res->>'gr_no', '')));

  return v_res || jsonb_build_object(
    'enquiry_id',     p_enquiry_id,
    'enquiry_no',     v_e.enquiry_no,
    'message_queued', v_msg is not null);
end;
$$;

-- ---------------------------------------------------------------------------
-- 11. The list
--
-- Ordered by how overdue the follow-up is, not by when the enquiry arrived. A
-- list sorted newest-first buries the parent who has been waiting nine days
-- under the one who called this morning, which is backwards.
-- ---------------------------------------------------------------------------
create or replace function public.fn_enquiry_list(
  p_status text default null,
  p_from   date default null,
  p_to     date default null,
  p_search text default null,
  p_due_only boolean default false,
  p_limit  int  default 200,
  p_offset int  default 0)
returns table (
  id uuid, enquiry_no bigint, child_name text, father_name text, phone text,
  whatsapp text, class_name text, class_wanted text, session_name text,
  source text, status text, follow_up_on date, days_overdue int,
  contacts int, last_contact_at timestamptz, last_outcome text,
  lost_reason text, notes text, created_at timestamptz, created_by_name text,
  admitted_student_id uuid, admitted_gr_no text, total_count bigint)
language plpgsql stable security definer set search_path = public as $$
declare
  v_school uuid := public.current_school_id();
  v_term   text := nullif(btrim(coalesce(p_search, '')), '');
  v_like   text;
  v_status public.enquiry_status := nullif(p_status, '')::public.enquiry_status;
begin
  if not public.has_role('owner', 'principal', 'admin_clerk') then
    raise exception 'Not permitted' using errcode = '42501';
  end if;

  -- Backslash FIRST, then the wildcards. Doing it the other way round escapes
  -- the escapes. Getting this wrong once meant searching "%" returned the whole
  -- school; see 0041.
  v_like := case when v_term is null then null
                 else '%' || replace(replace(replace(v_term, '\', '\\'),
                                             '%', '\%'), '_', '\_') || '%' end;

  return query
  with base as (
    select e.*
    from public.admission_enquiries e
    where e.school_id = v_school
      and (v_status is null or e.status = v_status)
      and (p_from is null or e.created_at::date >= p_from)
      and (p_to   is null or e.created_at::date <= p_to)
      and (v_like is null
           or e.child_name  ilike v_like
           or coalesce(e.father_name, '') ilike v_like
           or e.phone       ilike v_like
           or coalesce(e.whatsapp, '')    ilike v_like
           or e.enquiry_no::text = v_term)
      -- "Due" means today or earlier, and only for an OPEN enquiry: a closed
      -- one has no follow-up to be late for.
      and (not p_due_only
           or (e.status in ('new', 'contacted', 'visited')
               and e.follow_up_on is not null
               and e.follow_up_on <= current_date))
  ),
  counted as (select count(*) as n from base)
  select b.id, b.enquiry_no, b.child_name, b.father_name, b.phone, b.whatsapp,
         c.name, b.class_wanted, s.name,
         b.source::text, b.status::text, b.follow_up_on,
         case when b.status in ('new', 'contacted', 'visited')
                   and b.follow_up_on is not null
                   and b.follow_up_on < current_date
              then (current_date - b.follow_up_on)::int else 0 end,
         coalesce(k.n, 0)::int, k.last_at, k.last_outcome,
         b.lost_reason, b.notes, b.created_at,
         coalesce(p.full_name, '—'),
         b.admitted_student_id, st.gr_no,
         counted.n
  from base b
  cross join counted
  left join public.classes c
         on c.id = b.class_id and c.school_id = v_school
  left join public.academic_sessions s
         on s.id = b.session_id and s.school_id = v_school
  left join public.profiles p on p.id = b.created_by
  left join public.students st
         on st.id = b.admitted_student_id and st.school_id = v_school
  left join lateral (
    select count(*) as n,
           max(ec.contacted_at) as last_at,
           (array_agg(ec.outcome order by ec.contacted_at desc))[1] as last_outcome
    from public.enquiry_contacts ec
    where ec.enquiry_id = b.id and ec.school_id = v_school
  ) k on true
  order by
    -- Open and overdue first, longest wait at the top. Then open and due
    -- later. Then everything closed.
    case when b.status in ('new', 'contacted', 'visited') then 0 else 1 end,
    b.follow_up_on asc nulls last,
    b.created_at desc
  limit greatest(coalesce(p_limit, 200), 1)
  offset greatest(coalesce(p_offset, 0), 0);
end;
$$;

-- The follow-up history for one enquiry.
create or replace function public.fn_enquiry_contacts(p_enquiry_id uuid)
returns table (id uuid, contacted_at timestamptz, outcome text, note text, by_name text)
language plpgsql stable security definer set search_path = public as $$
declare v_school uuid := public.current_school_id();
begin
  if not public.has_role('owner', 'principal', 'admin_clerk') then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  perform public.assert_own('admission_enquiries', p_enquiry_id);

  return query
  select ec.id, ec.contacted_at, ec.outcome, ec.note, coalesce(p.full_name, '—')
  from public.enquiry_contacts ec
  left join public.profiles p on p.id = ec.contacted_by
  where ec.enquiry_id = p_enquiry_id and ec.school_id = v_school
  order by ec.contacted_at desc;
end;
$$;

-- ---------------------------------------------------------------------------
-- 12. The summary
--
-- The conversion rate is the figure a school owner actually wants, and it is
-- the easiest one to state dishonestly. An enquiry taken this morning is not a
-- failure — it has no outcome yet. So the rate counts only DECIDED enquiries:
-- admitted / (admitted + lost). Dividing by all enquiries would make a school
-- in the middle of a busy admission week look like it is failing.
-- ---------------------------------------------------------------------------
create or replace function public.fn_enquiry_summary()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_school   uuid := public.current_school_id();
  v_open     int;
  v_due      int;
  v_overdue  int;
  v_no_date  int;
  v_month    int;
  v_admitted int;
  v_lost     int;
  v_decided  int;
begin
  if not public.has_role('owner', 'principal', 'admin_clerk') then
    raise exception 'Not permitted' using errcode = '42501';
  end if;

  select
    count(*) filter (where status in ('new', 'contacted', 'visited')),
    count(*) filter (where status in ('new', 'contacted', 'visited')
                       and follow_up_on = current_date),
    count(*) filter (where status in ('new', 'contacted', 'visited')
                       and follow_up_on < current_date),
    -- An open enquiry with no follow-up date is invisible on every list. It
    -- should be impossible — fn_add_enquiry defaults the date — but if one
    -- exists the school needs to be told, not have it quietly hidden.
    count(*) filter (where status in ('new', 'contacted', 'visited')
                       and follow_up_on is null),
    count(*) filter (where created_at >= date_trunc('month', current_date)),
    count(*) filter (where status = 'admitted'),
    count(*) filter (where status = 'lost')
    into v_open, v_due, v_overdue, v_no_date, v_month, v_admitted, v_lost
  from public.admission_enquiries
  where school_id = v_school;

  v_decided := v_admitted + v_lost;

  return jsonb_build_object(
    'open',            v_open,
    'due_today',       v_due,
    'overdue',         v_overdue,
    'open_no_date',    v_no_date,
    'this_month',      v_month,
    'admitted',        v_admitted,
    'lost',            v_lost,
    'decided',         v_decided,
    -- Null, not zero, when nothing has been decided yet. A "0%" conversion
    -- rate on a school's first day is a lie; "—" is the truth.
    'conversion_rate', case when v_decided = 0 then null
                            else round(v_admitted::numeric * 100 / v_decided, 1) end);
end;
$$;

-- Where the enquiries came from, and which sources actually convert. A banner
-- costs money; four enquiries and one admission from it is worth knowing.
create or replace function public.fn_enquiry_sources(
  p_from date default null, p_to date default null)
returns table (source text, enquiries bigint, admitted bigint, lost bigint,
               open bigint, conversion_rate numeric)
language plpgsql stable security definer set search_path = public as $$
declare v_school uuid := public.current_school_id();
begin
  if not public.has_role('owner', 'principal', 'admin_clerk') then
    raise exception 'Not permitted' using errcode = '42501';
  end if;

  return query
  select e.source::text,
         count(*),
         count(*) filter (where e.status = 'admitted'),
         count(*) filter (where e.status = 'lost'),
         count(*) filter (where e.status in ('new', 'contacted', 'visited')),
         case when count(*) filter (where e.status in ('admitted', 'lost')) = 0
              then null
              else round(count(*) filter (where e.status = 'admitted')::numeric * 100
                         / count(*) filter (where e.status in ('admitted', 'lost')), 1)
         end
  from public.admission_enquiries e
  where e.school_id = v_school
    and (p_from is null or e.created_at::date >= p_from)
    and (p_to   is null or e.created_at::date <= p_to)
  group by e.source
  order by count(*) desc;
end;
$$;

-- ---------------------------------------------------------------------------
-- 13. Grants
-- ---------------------------------------------------------------------------
grant execute on function public.fn_add_enquiry(jsonb) to authenticated;
grant execute on function public.fn_log_enquiry_contact(uuid, text, text, date) to authenticated;
grant execute on function public.fn_set_enquiry_status(uuid, text, text, date) to authenticated;
grant execute on function public.fn_enquiry_admit(uuid, jsonb) to authenticated;
grant execute on function public.fn_enquiry_list(text, date, date, text, boolean, int, int) to authenticated;
grant execute on function public.fn_enquiry_contacts(uuid) to authenticated;
grant execute on function public.fn_enquiry_summary() to authenticated;
grant execute on function public.fn_enquiry_sources(date, date) to authenticated;

revoke all on function public.fn_add_enquiry(jsonb) from anon;
revoke all on function public.fn_log_enquiry_contact(uuid, text, text, date) from anon;
revoke all on function public.fn_set_enquiry_status(uuid, text, text, date) from anon;
revoke all on function public.fn_enquiry_admit(uuid, jsonb) from anon;
revoke all on function public.fn_enquiry_list(text, date, date, text, boolean, int, int) from anon;
revoke all on function public.fn_enquiry_contacts(uuid) from anon;
revoke all on function public.fn_enquiry_summary() from anon;
revoke all on function public.fn_enquiry_sources(date, date) from anon;

-- Internal: only ever called by the functions above.
revoke all on function public.fn_queue_enquiry_message(text, uuid, jsonb) from public;
revoke all on function public.fn_queue_enquiry_message(text, uuid, jsonb) from anon;
revoke all on function public.fn_queue_enquiry_message(text, uuid, jsonb) from authenticated;

-- Give every existing school the two new templates. on-conflict-do-nothing, so
-- a school that has edited its wording keeps it.
do $$
declare s uuid;
begin
  for s in select id from public.schools loop
    perform public.fn__seed_message_templates(s);
  end loop;
end $$;

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

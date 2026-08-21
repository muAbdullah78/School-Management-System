-- =============================================================================
-- 0040 — Collecting from a class, not one family at a time.
--
-- WHY
--
-- A Pakistani school takes 100–400 fee payments in the first ten days of a
-- month. Until now every one of them meant a separate search: type a name or a
-- CNIC, wait, pick the family, enter an amount, submit, start again. Four
-- hundred searches.
--
-- And the screen that already knew who owed money — Fees > Defaulters — was a
-- read-only dead end. It rendered bare table rows with no Collect action, no
-- reminder, and no link to the student. The fee_reminder and fee_reminder_final
-- templates have existed since 0034 and nothing has ever sent one.
--
-- Their product calls this "Bulk Fee Payment" and "SMS To Fee Defaulters". This
-- migration is the data layer for both, adapted to WhatsApp.
--
-- WHAT THIS DELIBERATELY DOES NOT DO
--
-- It does not reimplement allocation. fn_record_bulk_payments loops and calls
-- fn_record_payment, which is the one function that knows how money is applied
-- to invoices. A second allocator that drifted from the first would be the
-- worst bug this system could have, and "it was faster in a loop" is not worth
-- that risk.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. The worklist: everyone in a class and what they owe.
--
-- This is the screen a clerk works down with a cash box, so it returns the
-- whole class — not just the defaulters. A clerk needs to see "Ahmed: paid" to
-- know they have not skipped him, and a list that hides the paid students makes
-- that impossible.
--
-- month_due is what THIS month's challan still needs; total_due is everything
-- the student owes. Both, because a parent hands over money for one month while
-- the clerk needs to know the real position.
-- ---------------------------------------------------------------------------
create or replace function public.fn_class_dues(
  p_session_id   uuid,
  p_class_id     uuid,
  p_section_id   uuid,
  p_period_month date
) returns table (
  student_id   uuid,
  full_name    text,
  gr_no        text,
  roll_no      text,
  father_name  text,
  phone        text,
  family_id    uuid,
  family_head  text,
  invoice_id   uuid,
  voucher_code text,
  month_charge numeric,
  month_paid   numeric,
  month_due    numeric,
  total_due    numeric,
  last_paid_at timestamptz
) language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_staff() then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  perform public.assert_own('academic_sessions', p_session_id);
  perform public.assert_own('classes', p_class_id);
  perform public.assert_own('sections', p_section_id);

  return query
  select
    s.id,
    s.full_name,
    s.gr_no,
    e.roll_no,
    s.father_name,
    coalesce(nullif(s.whatsapp, ''), nullif(s.phone, ''), f.whatsapp, f.phone),
    s.family_id,
    f.head_name,
    i.id,
    i.voucher_code,
    coalesce(ch.charge, 0),
    coalesce(pd.paid, 0),
    coalesce(ch.charge, 0) - coalesce(pd.paid, 0),
    public.student_balance(s.id),
    lp.last_at
  from public.enrollments e
  join public.students s on s.id = e.student_id
  left join public.families f on f.id = s.family_id
  -- The challan for the month being collected, if one was generated.
  left join public.invoices i
    on i.enrollment_id = e.id
   and i.period_month = p_period_month
   and i.status <> 'void'
  left join lateral (
    select coalesce(sum(case when l.is_discount then -l.amount else l.amount end), 0)
             + coalesce(i.fine, 0) as charge
      from public.invoice_lines l where l.invoice_id = i.id
  ) ch on true
  left join lateral (
    select coalesce(sum(al.amount), 0) as paid
      from public.payment_allocations al
      join public.payments p on p.id = al.payment_id
     where al.invoice_id = i.id and p.status = 'verified'
  ) pd on true
  -- When this student last paid anything. A clerk uses it to spot the family
  -- that has not been seen for three months, which a balance alone hides.
  left join lateral (
    select max(p2.created_at) as last_at
      from public.payments p2
     where p2.status = 'verified'
       and (p2.student_id = s.id
            or exists (select 1
                         from public.payment_allocations al2
                         join public.invoices i2 on i2.id = al2.invoice_id
                        where al2.payment_id = p2.id and i2.student_id = s.id))
  ) lp on true
  where e.session_id = p_session_id
    and e.class_id = p_class_id
    and (p_section_id is null or e.section_id = p_section_id)
    and e.status = 'active'
    and s.deleted_at is null
    and s.school_id = public.current_school_id()
  order by coalesce(nullif(regexp_replace(coalesce(e.roll_no, ''), '[^0-9]', '', 'g'), '')::int, 999999),
           s.full_name;
end;
$$;

-- ---------------------------------------------------------------------------
-- 2. Take many payments in one go.
--
-- p_items is [{"student_id": "...", "amount": 1200}, ...].
--
-- ONE TRANSACTION on purpose. If the eleventh row is bad the whole batch rolls
-- back, so a clerk never ends up with ten receipts issued and no idea which of
-- the forty rows they typed went through. Refusing the batch and showing the
-- bad row is recoverable; a half-applied batch is not.
--
-- Every payment goes through fn_record_payment, so allocation, receipt
-- numbering, the till, and the WhatsApp receipt trigger all behave exactly as
-- they do for a single payment at the counter.
-- ---------------------------------------------------------------------------
create or replace function public.fn_record_bulk_payments(
  p_items  jsonb,
  p_method public.payment_method default 'cash',
  p_note   text default null,
  p_pending boolean default false
) returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_item    jsonb;
  v_student uuid;
  v_amount  numeric;
  v_res     jsonb;
  v_out     jsonb := '[]'::jsonb;
  v_total   numeric := 0;
  v_count   int := 0;
begin
  if not public.has_role('owner', 'principal', 'admin_clerk', 'accountant') then
    raise exception 'Not permitted to take payments';
  end if;
  if p_items is null or jsonb_typeof(p_items) <> 'array' then
    raise exception 'Nothing to record';
  end if;
  if jsonb_array_length(p_items) = 0 then
    raise exception 'Nothing to record — no students were ticked';
  end if;
  -- A guard against a runaway client, not a real limit: the largest class in a
  -- Pakistani school is nowhere near this.
  if jsonb_array_length(p_items) > 500 then
    raise exception 'Too many rows in one batch (%). Split it by section.',
      jsonb_array_length(p_items);
  end if;

  for v_item in select * from jsonb_array_elements(p_items) loop
    v_student := nullif(v_item->>'student_id', '')::uuid;
    v_amount  := nullif(v_item->>'amount', '')::numeric;

    if v_student is null then
      raise exception 'A row has no student';
    end if;
    -- Named in the error so the clerk can find the row, rather than being told
    -- "invalid amount" about a batch of forty.
    if v_amount is null or v_amount <= 0 then
      raise exception 'Amount for % must be more than zero',
        coalesce((select full_name from public.students where id = v_student), 'a student');
    end if;

    -- fn_record_payment asserts ownership of the student itself, which is what
    -- stops a crafted payload writing a receipt into another school.
    v_res := public.fn_record_payment(v_student, v_amount, p_method, p_note, p_pending);

    v_out := v_out || jsonb_build_array(jsonb_build_object(
      'student_id', v_student,
      'amount',     v_amount,
      'receipt_no', v_res->'receipt_no'));
    v_total := v_total + v_amount;
    v_count := v_count + 1;
  end loop;

  return jsonb_build_object('count', v_count, 'total', v_total, 'receipts', v_out);
end;
$$;

-- ---------------------------------------------------------------------------
-- 3. Queue a fee reminder for every family in a class that owes money.
--
-- Their product sends three escalating reminders — polite, firmer, then a
-- warning that the child will not be allowed to attend. That escalation is the
-- part worth copying: one identical message sent three times gets ignored.
--
-- The escalation level is derived from how many reminders this family has
-- ALREADY been sent for the current month, so a clerk pressing the button twice
-- in an afternoon does not jump a family straight to the final warning.
--
-- One message per FAMILY, not per child. A father with three children owing
-- fees gets one WhatsApp, which is the difference between a reminder and
-- spam — and the reason he will still read the next one.
-- ---------------------------------------------------------------------------
create or replace function public.fn_queue_class_reminders(
  p_session_id uuid,
  p_class_id   uuid,
  p_section_id uuid
) returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_fam    record;
  v_sent   int;
  v_key    text;
  v_queued int := 0;
  v_skipped int := 0;
begin
  if not public.has_role('owner', 'principal', 'admin_clerk', 'accountant') then
    raise exception 'Not permitted to send reminders';
  end if;
  perform public.assert_own('academic_sessions', p_session_id);
  perform public.assert_own('classes', p_class_id);
  perform public.assert_own('sections', p_section_id);

  for v_fam in
    select s.family_id,
           max(f.head_name)                            as head_name,
           string_agg(distinct s.full_name, ', ')       as children,
           sum(public.student_balance(s.id))            as owed
    from public.enrollments e
    join public.students s on s.id = e.student_id
    left join public.families f on f.id = s.family_id
    where e.session_id = p_session_id
      and e.class_id = p_class_id
      and (p_section_id is null or e.section_id = p_section_id)
      and e.status = 'active'
      and s.deleted_at is null
      and s.school_id = public.current_school_id()
      and s.family_id is not null
    group by s.family_id
    having sum(public.student_balance(s.id)) > 0
  loop
    -- How many reminders have already gone out to this family this month.
    select count(*) into v_sent
    from public.message_outbox m
    where m.family_id = v_fam.family_id
      and m.template_key in ('fee_reminder', 'fee_reminder_final')
      and m.created_at >= date_trunc('month', now());

    v_key := case when v_sent >= 2 then 'fee_reminder_final' else 'fee_reminder' end;

    -- fn_queue_message respects message_templates.enabled, so a school that has
    -- switched reminders off is not overridden by a bulk action.
    begin
      perform public.fn_queue_message(
        v_key,
        v_fam.family_id,
        jsonb_build_object(
          'parent',   coalesce(v_fam.head_name, 'Parent'),
          'children', v_fam.children,
          'amount',   to_char(v_fam.owed, 'FM999999990')),
        null,
        null);
      v_queued := v_queued + 1;
    exception when others then
      -- One family with no phone number must not abandon the other thirty-nine.
      v_skipped := v_skipped + 1;
    end;
  end loop;

  return jsonb_build_object('queued', v_queued, 'skipped', v_skipped);
end;
$$;

-- ---------------------------------------------------------------------------
-- 4. Grants.
-- ---------------------------------------------------------------------------
grant execute on function public.fn_class_dues(uuid, uuid, uuid, date)                        to authenticated;
grant execute on function public.fn_record_bulk_payments(jsonb, public.payment_method, text, boolean) to authenticated;
grant execute on function public.fn_queue_class_reminders(uuid, uuid, uuid)                   to authenticated;

revoke all on function public.fn_class_dues(uuid, uuid, uuid, date)                        from anon;
revoke all on function public.fn_record_bulk_payments(jsonb, public.payment_method, text, boolean) from anon;
revoke all on function public.fn_queue_class_reminders(uuid, uuid, uuid)                   from anon;

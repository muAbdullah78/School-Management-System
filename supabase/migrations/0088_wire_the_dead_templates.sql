-- =============================================================================
-- 0088 — Two WhatsApp messages a school could switch on that nothing would send
--
-- WHAT WAS THERE
--
-- `fn__default_message_templates` seeds five templates into every school, and
-- Settings → Messages lets the school edit the wording, see the merge tags it
-- may use, preview it with sample values and switch it on or off. The screen is
-- good. Two of its five entries were decorative:
--
--     select proname from pg_proc
--      where prosrc like '%absent_today%' or prosrc like '%result_published%';
--     → fn__default_message_templates
--
-- The function that DEFINES them was the only function that mentioned them. No
-- trigger, no policy, no screen, nothing in web/src. A school would find
-- "Absent today" in its settings, write the wording it wanted, switch it on, and
-- no parent would ever receive one. No error, no empty state, nothing to
-- notice — the message simply did not exist.
--
-- 0043's own header states the principle this broke: "The tag list is a FACT
-- ABOUT THE CALL SITE, not decoration ... Showing a school a tag that will never
-- resolve means they put it in a message and a parent receives the literal
-- {receipt}." Two of the five entries had no call site at all.
--
-- The WhatsApp screen was already finished for both: `listOutbox` reads the
-- table without filtering by template, and MessagesPage already carries the
-- labels "Absent today" and "Result published". So this migration is the whole
-- feature — nothing in the app changes.
--
-- THREE THINGS THE OBVIOUS WIRING WOULD HAVE GOT WRONG
--
--   1. {children} IS THE WHOLE FAMILY. fn_queue_message fills it with every
--      child in the family, which is right for a fee reminder to a payer and
--      wrong for an absence: a family of three would be told "Ali, Fatima and
--      Hassan was marked absent today". Both new callers override it with the
--      one child concerned.
--
--   2. {date} IS TODAY. A register finalised on Monday morning for Friday would
--      have told the parent their child was absent today. The absence caller
--      passes the ATTENDANCE date.
--
--   3. A WITHHELD RESULT MUST NOT BE ANNOUNCED. fn_generate_result_cards
--      freezes `withheld: true` on a card when the family owes fees, and the
--      portal shows "Result withheld until outstanding fees are cleared." A
--      message saying the result "can be viewed in the parent portal" would be
--      false for exactly the families most likely to check.
--
-- IDEMPOTENCE, STRUCTURALLY
--
-- Finalising a register twice, or unpublishing and republishing a term, must not
-- message a family twice. Doing that with a heuristic — "was anything sent to
-- this student today" — breaks on a register finalised three days late, so
-- `message_outbox` gains a `ref` column and a unique index. The caller says what
-- the message is ABOUT ('absent:2026-08-27', 'result:<term_id>') and the
-- database refuses the second one. Any future template gets it for nothing.
--
-- A DELIBERATE DECISION ON REPUBLISHING: a corrected result is not announced
-- again. One message per child per term, ever. A parent who has already been
-- told to look, and then gets a second identical message, has been given a
-- reason to think something is wrong; a correction is a conversation the school
-- should have, and the office can still send a message by hand.
--
-- Re-runnable.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. What a queued message is ABOUT
--
-- Nullable, so every existing row and every existing caller is unaffected: a
-- fee receipt has no natural idempotency key and does not need one, because it
-- is queued by a trigger on the payment that is itself the unique event.
-- ---------------------------------------------------------------------------
alter table public.message_outbox add column if not exists ref text;

-- Partial, so the fee receipts and reminders that carry no ref are not forced
-- to be unique against each other.
create unique index if not exists uq_outbox_ref
  on public.message_outbox (school_id, template_key, student_id, ref)
  where ref is not null;

-- ---------------------------------------------------------------------------
-- 2. fn_queue_message learns the key
--
-- DROP then CREATE rather than `create or replace`, because adding a parameter
-- with a default makes a NEW function rather than replacing the old one — and
-- then every five-argument call becomes ambiguous and fails with "function is
-- not unique". Checked first: nothing in web/src or supabase/functions calls
-- this over RPC, and its three in-database callers are plpgsql, which resolves
-- the name at run time.
-- ---------------------------------------------------------------------------
drop function if exists public.fn_queue_message(text, uuid, jsonb, uuid, uuid);

create or replace function public.fn_queue_message(
  p_template_key text,
  p_family_id    uuid,
  p_vars         jsonb default '{}'::jsonb,
  p_payment_id   uuid  default null,
  p_student_id   uuid  default null,
  p_ref          text  default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  v_t record; v_f record; v_id uuid; v_vars jsonb; v_kids text;
  v_school uuid := public.current_school_id();
begin
  -- No school context, no message. Reached when a service-role job calls this
  -- with no session; queuing a message to a family we cannot attribute is worse
  -- than queuing none.
  if v_school is null then return null; end if;

  select * into v_t from public.message_templates
  where school_id = v_school and template_key = p_template_key;
  -- Not an error. A school that has switched this message off gets no message,
  -- and the action that triggered it still succeeds.
  if not found or not v_t.enabled then return null; end if;

  -- THE LEAK (0079). Was `where id = p_family_id` with no school filter, inside
  -- a SECURITY DEFINER function where RLS does not apply — so any signed-in
  -- user at any school could name any family in the database.
  select * into v_f from public.families
  where id = p_family_id and school_id = v_school;
  if not found then return null; end if;

  -- Same fix, same reason: this is where the victim child's NAME came from.
  select string_agg(s.full_name, ', ' order by s.full_name) into v_kids
  from public.students s
  where s.family_id = p_family_id and s.school_id = v_school
    and s.deleted_at is null;

  -- The two optional foreign keys were written into the outbox row without ever
  -- being checked. enforce_school_id stamps the ROW's school_id, so the row
  -- looked native to the caller's school while pointing at another school's
  -- payment or pupil — and the portal and receipt screens join through them.
  -- Silently dropped rather than raised, for the same reason as above: a
  -- mis-supplied reference must not fail the payment that triggered the message.
  if p_payment_id is not null and not exists (
       select 1 from public.payments where id = p_payment_id and school_id = v_school) then
    p_payment_id := null;
  end if;
  if p_student_id is not null and not exists (
       select 1 from public.students where id = p_student_id and school_id = v_school) then
    p_student_id := null;
  end if;

  v_vars := jsonb_build_object(
    'parent',   coalesce(v_f.head_name, 'Parent'),
    'children', coalesce(v_kids, 'your child'),
    'school',   coalesce((select name from public.school_settings
                          where school_id = v_school), 'the school'),
    'date',     to_char(current_date, 'DD Mon YYYY'),
    'balance',  trim(to_char(public.family_outstanding(p_family_id), 'FM999,999,990'))
  ) || coalesce(p_vars, '{}'::jsonb);

  -- 0088. `ref` is the idempotency key, enforced by uq_outbox_ref. A caller
  -- that supplies one is saying "there is at most one of these" and gets null
  -- back on the second attempt rather than an error, because the ACTION that
  -- triggered the message — finalising a register, publishing a term — must
  -- still succeed on a re-run.
  begin
    insert into public.message_outbox (
      template_key, to_name, to_phone, family_id, student_id, payment_id,
      rendered_text, ref)
    values (
      p_template_key, v_f.head_name,
      coalesce(nullif(btrim(coalesce(v_f.whatsapp, '')), ''), v_f.phone),
      p_family_id, p_student_id, p_payment_id,
      public.fn__render_template(v_t.body, v_vars), p_ref)
    returning id into v_id;
  exception when unique_violation then
    return null;
  end;

  return v_id;
end;
$$;

grant  execute on function public.fn_queue_message(text, uuid, jsonb, uuid, uuid, text) to authenticated;
revoke execute on function public.fn_queue_message(text, uuid, jsonb, uuid, uuid, text) from public, anon;

-- ---------------------------------------------------------------------------
-- 3. Absence
--
-- Exposed as its own function as well as being called on finalise, because a
-- register gets corrected: a child marked absent who turns out to have been on
-- leave is fixed, the register is finalised again, and the office can re-run
-- this to catch the ones it missed the first time. The ref stops the ones
-- already messaged going out twice.
--
-- `leave` and `half_day` are NOT messaged. A parent who told the school their
-- child would be away does not need telling back, and half a day present is not
-- an absence. Only `absent`.
-- ---------------------------------------------------------------------------
create or replace function public.fn_queue_absent_today(
  p_session_id uuid, p_class_id uuid, p_section_id uuid, p_date date)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_school uuid := public.current_school_id();
  v_row    record;
  v_id     uuid;
  v_queued int := 0;
  v_already int := 0;
  v_nophone int := 0;
begin
  if not public.has_role('owner','principal','admin_clerk','class_teacher','subject_teacher') then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  if not public.fn_may_manage_class(p_session_id, p_class_id, p_section_id) then
    raise exception 'You can only message your assigned class';
  end if;
  if p_date is null then raise exception 'A date is required'; end if;

  for v_row in
    select s.id as student_id, s.family_id, s.full_name
    from public.attendance_daily ad
    join public.enrollments e on e.id = ad.enrollment_id
    join public.students s    on s.id = e.student_id
    where ad.school_id = v_school
      and ad.attendance_date = p_date
      and ad.status = 'absent'
      and e.session_id = p_session_id
      and e.class_id = p_class_id
      and (p_section_id is null or e.section_id = p_section_id)
      and e.status = 'active'
      and s.deleted_at is null
      and s.family_id is not null
    order by s.full_name
  loop
    -- `children` is the ONE child, not the family. `date` is the attendance
    -- date, not today. Both are the point of this function.
    v_id := public.fn_queue_message(
      'absent_today',
      v_row.family_id,
      jsonb_build_object(
        'children', v_row.full_name,
        'date',     to_char(p_date, 'DD Mon YYYY')),
      null,
      v_row.student_id,
      'absent:' || p_date::text);

    if v_id is null then v_already := v_already + 1;
    else v_queued := v_queued + 1;
    end if;
  end loop;

  -- Counted separately and reported, because "we queued 18 of 20" is actionable
  -- and "we queued 18" is not: the two families with no number on file are the
  -- ones the office has to phone.
  select count(*) into v_nophone
  from public.attendance_daily ad
  join public.enrollments e on e.id = ad.enrollment_id
  join public.students s    on s.id = e.student_id
  left join public.families f on f.id = s.family_id
  where ad.school_id = v_school
    and ad.attendance_date = p_date
    and ad.status = 'absent'
    and e.session_id = p_session_id
    and e.class_id = p_class_id
    and (p_section_id is null or e.section_id = p_section_id)
    and e.status = 'active'
    and s.deleted_at is null
    and (s.family_id is null
         or coalesce(nullif(btrim(coalesce(f.whatsapp, '')), ''), f.phone) is null);

  return jsonb_build_object(
    'queued', v_queued,
    'already_queued', v_already,
    'no_number', v_nophone);
end;
$$;

grant  execute on function public.fn_queue_absent_today(uuid, uuid, uuid, date) to authenticated;
revoke execute on function public.fn_queue_absent_today(uuid, uuid, uuid, date) from public, anon;

-- Finalising the register is the moment the school commits to who was absent,
-- so it is the moment the messages belong. Restated in full rather than
-- rewritten programmatically because the body is eleven lines.
--
-- Wrapped, and deliberately so: a failure in the messaging must never roll back
-- the lock. A register that would not finalise because one family's row was
-- odd would be a far worse defect than a message that did not go out, and the
-- office can re-run fn_queue_absent_today for the day.
create or replace function public.fn_finalize_attendance(
  p_session_id uuid, p_class_id uuid, p_section_id uuid, p_date date)
returns integer language plpgsql security definer set search_path = public as $$
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

  begin
    perform public.fn_queue_absent_today(p_session_id, p_class_id, p_section_id, p_date);
  exception when others then
    raise notice 'attendance finalised; absence messages could not be queued: %', sqlerrm;
  end;

  return v_count;
end;
$$;

-- ---------------------------------------------------------------------------
-- 4. Results published
-- ---------------------------------------------------------------------------
create or replace function public.fn_queue_result_published(
  p_exam_term_id uuid, p_class_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_school uuid := public.current_school_id();
  v_row    record;
  v_id     uuid;
  v_queued int := 0;
  v_already int := 0;
  v_withheld int := 0;
begin
  if not public.has_role('owner', 'principal') then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  perform public.assert_own('exam_terms', p_exam_term_id);
  perform public.assert_own('classes', p_class_id);

  for v_row in
    select distinct on (rc.enrollment_id)
           s.id as student_id, s.family_id, s.full_name,
           coalesce((rc.frozen->>'withheld')::boolean, false) as withheld
    from public.result_cards rc
    join public.enrollments e on e.id = rc.enrollment_id
    join public.students s    on s.id = rc.student_id
    where rc.school_id = v_school
      and rc.exam_term_id = p_exam_term_id
      and e.class_id = p_class_id
      and rc.published_at is not null
      and s.deleted_at is null
      and s.family_id is not null
    order by rc.enrollment_id, rc.version desc
  loop
    -- A withheld card shows the parent "Result withheld until outstanding fees
    -- are cleared", so telling them the result can be viewed would be false for
    -- exactly the families most likely to go and look.
    if v_row.withheld then
      v_withheld := v_withheld + 1;
      continue;
    end if;

    v_id := public.fn_queue_message(
      'result_published',
      v_row.family_id,
      jsonb_build_object('children', v_row.full_name),
      null,
      v_row.student_id,
      'result:' || p_exam_term_id::text);

    if v_id is null then v_already := v_already + 1;
    else v_queued := v_queued + 1;
    end if;
  end loop;

  return jsonb_build_object(
    'queued', v_queued,
    'already_queued', v_already,
    'withheld', v_withheld);
end;
$$;

grant  execute on function public.fn_queue_result_published(uuid, uuid) to authenticated;
revoke execute on function public.fn_queue_result_published(uuid, uuid) from public, anon;

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

  -- Same reasoning as the attendance hook: the release must not fail because a
  -- message could not be built.
  begin
    perform public.fn_queue_result_published(p_exam_term_id, p_class_id);
  exception when others then
    raise notice 'results published; parent messages could not be queued: %', sqlerrm;
  end;

  return v_n;
end;
$$;

-- ---------------------------------------------------------------------------
-- 5. The end state, asserted
--
-- The assertion that matters is not "do the functions exist" but "does every
-- template a school can switch on have something that sends it". Written as a
-- sweep over the template list rather than as two named checks, so a SIXTH
-- template added later without a caller fails here instead of shipping
-- decorative.
-- ---------------------------------------------------------------------------
do $assert$
declare
  v_key   text;
  v_dead  text[] := '{}';
  v_n     int;
begin
  for v_key in select template_key from public.fn__default_message_templates() loop
    select count(*) into v_n
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname <> 'fn__default_message_templates'
      and p.prosrc like '%' || v_key || '%';
    if v_n = 0 then
      v_dead := v_dead || v_key;
    end if;
  end loop;

  if array_length(v_dead, 1) is not null then
    raise exception
      '0088: these templates are seeded into every school, editable in Settings '
      '→ Messages and switched on by a toggle, and NOTHING queues them: %. A '
      'school will write the wording, enable it, and no parent will ever '
      'receive one.', array_to_string(v_dead, ', ');
  end if;
end $assert$;

do $assert$
declare v_src text;
begin
  if not exists (select 1 from pg_indexes
                  where schemaname = 'public' and indexname = 'uq_outbox_ref') then
    raise exception '0088: uq_outbox_ref is missing, so a re-finalise would message twice';
  end if;

  -- fn_queue_message must be exactly ONE function. Two overloads would make
  -- every five-argument call ambiguous at run time, which is a failure the
  -- migration would not show.
  if (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'public' and p.proname = 'fn_queue_message') <> 1 then
    raise exception
      '0088: there is more than one fn_queue_message. Adding a defaulted '
      'parameter creates an overload rather than replacing the function, and '
      'the old five-argument calls then fail with "function is not unique".';
  end if;

  select pg_get_functiondef(p.oid) into v_src
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname = 'fn_finalize_attendance';
  if position('fn_queue_absent_today' in v_src) = 0 then
    raise exception '0088: finalising a register no longer queues the absences';
  end if;

  select pg_get_functiondef(p.oid) into v_src
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname = 'fn_publish_results';
  if position('fn_queue_result_published' in v_src) = 0 then
    raise exception '0088: publishing results no longer tells the parents';
  end if;
end $assert$;

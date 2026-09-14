-- =============================================================================
-- 0136  The cash drawer and the WhatsApp outbox come out
--
-- -----------------------------------------------------------------------------
-- WHAT IS BEING REMOVED AND WHY
--
-- Two modules the vendor judged to have no real use, removed at their request
-- while no school is live. There is no data to preserve and none is preserved.
--
-- THE CASH DRAWER was a second bookkeeping layer on top of the one that
-- matters. A payment is already a row in `payments` with an amount, a method, a
-- receipt number and the person who took it; the till added an opening float, a
-- closing count, a variance and a sign-off on top of that. For a school whose
-- whole office is one person, the count at the end of the day IS the list of
-- receipts, and asking them to reconcile one against the other is asking them
-- to check their own arithmetic against itself.
--
-- It also concentrated the only remaining separation-of-duties problem in this
-- product. 0133 merged the office into one role and recorded, in its own header
-- and in supabase/tests/finance.sql, that fn_approve_till therefore let the
-- person who took the money sign off their own drawer. That control is not
-- weakened by this migration: the thing it was meant to protect no longer
-- exists.
--
-- THE WHATSAPP OUTBOX queued messages that nothing ever sent. Read the flow
-- honestly and it is a to-do list: fn_queue_absent_today and its siblings wrote
-- rows into message_outbox, a screen listed them, and a human pressed a
-- click-to-chat link one at a time and then pressed "mark as sent". The queue
-- was bookkeeping about work a person still had to do by hand, and its state
-- was only as true as their diligence in coming back to tick it.
--
-- -----------------------------------------------------------------------------
-- WHAT IS DELIBERATELY KEPT, AND THIS IS THE IMPORTANT HALF
--
-- CLICK-TO-CHAT STAYS. The "Send a WhatsApp" buttons on Birthdays, on the
-- defaulters list, on a student's profile and on the staff list are not the
-- outbox. They open WhatsApp with the message already typed, cost nothing,
-- store nothing and queue nothing. They are the fastest way a Pakistani school
-- office contacts a parent and removing them would take away the useful half of
-- the idea along with the useless half.
--
-- THE WHATSAPP NUMBER STAYS on students, guardians, families, staff and
-- enquiries. It is a phone number the office typed.
--
-- EVERY PAYMENT PATH IS UNCHANGED in what it records. Taking a fee, printing a
-- receipt, reversing a payment, the defaulters list, the ledger, the balance
-- sheet and every fee report carry on exactly as before. What stops being
-- written is payments.till_session_id, a column whose only reader was the till
-- report; it is blanked rather than dropped, for the reason below.
--
-- -----------------------------------------------------------------------------
-- WHY NOTHING IS DROPPED, WHICH IS THE ONE DECISION IN THIS FILE WORTH ARGUING
--
-- The first two drafts of this migration DROPPED the three tables and every
-- function. Both were thrown away, and not on a hunch: five bundles refused to
-- apply afterwards, and CI's upgrade job stopped dead on the third of them.
--
-- A bundle is ONE transaction, and supabase/bundles/MANIFEST freezes every
-- bundle that has shipped, because the file a school already pasted must not
-- change underneath them. Bundles 4, 7, 8, 24 and 28 are frozen AND name this
-- feature in plain DDL: an `alter table message_outbox`, two `create index` on
-- it, a `revoke` on fn__default_message_templates by name, an assertion that
-- reads fn_queue_message's body, and an update over message_templates rows.
-- Take any of it away and each of those files raises and rolls back whole.
--
-- That is not an error in a log. verify.sql says "re-run bundle 7" to a school
-- with a problem. supabase/repair/detect.sql tells a school stuck part-way to
-- apply what it lacks and then paste the bundles again from 5 upward. The CI
-- job that exists because an upgrade path once broke and cost a real school
-- fifteen migrations does exactly that. All three would hand the school a red
-- ERROR and stop before reaching the bundle that fixes anything, permanently,
-- because the five files cannot be edited.
--
-- So this migration SEALS instead. Section 4 sets out what that means in full;
-- in short, every row is deleted, every policy is dropped, RLS is FORCED so the
-- seal binds the table owner as well, and every till and outbox function is
-- revoked from anon, authenticated and service_role. Nothing on the screen,
-- nothing in the API, nothing in the data. What is left is schema that cannot
-- be reached from anywhere and that five shipped installer files require to
-- exist.
--
-- -----------------------------------------------------------------------------
-- WHY THE CALLERS ARE REPRODUCED WHOLE
--
-- Twelve functions referred to a till or the outbox, and each is rewritten here
-- in full rather than patched by text. This repository has been bitten by both
-- techniques, so the choice is stated:
--
--   * a TEXT PATCH goes stale. 0135 removed the name 0085 anchors on and took
--     bundle 7 down, which is the immediate precedent.
--   * RETYPING FROM AN OLD VERSION silently reverts every later fix, which this
--     repository has recorded happening twice.
--
-- The bodies below are neither. They were taken from pg_get_functiondef on a
-- database with all 135 migrations applied, so they carry every fix up to this
-- point, and the only edits are the removal of the till and outbox lines. That
-- is what a text patch does, done once at authoring time where it can be read.
--
-- -----------------------------------------------------------------------------
-- TWO RETURN VALUES CHANGE SHAPE, and the screens that read them change with
-- this bundle:
--
--   fn_add_enquiry    no longer returns 'message_queued'
--   fn_enquiry_admit  no longer returns 'message_queued'
--
-- Both were booleans meaning "a row was written to the outbox". With no outbox
-- there is nothing true to say, and a key that is always false is worse than an
-- absent one.
-- =============================================================================

-- ============================================ 1. the callers, without them ===
CREATE OR REPLACE FUNCTION public.fn_record_payment(p_student_id uuid, p_amount numeric, p_method payment_method, p_note text DEFAULT NULL::text, p_pending boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
    'allocated', p_amount - v_left, 'unallocated', v_left, 'pending', false,
    'applied', public.fn__payment_applied(v_pay));
end;
$function$;

CREATE OR REPLACE FUNCTION public.fn_record_family_payment(p_family_id uuid, p_amount numeric, p_method payment_method, p_note text DEFAULT NULL::text, p_pending boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
    'applied', public.fn__payment_applied(v_pay),
    'pending', false);
end;
$function$;

CREATE OR REPLACE FUNCTION public.fn_reverse_payment(p_payment_id uuid, p_reason text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
$function$;

CREATE OR REPLACE FUNCTION public.fn_admit_student(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
  -- family resolution
  v_father_cnic text := nullif(btrim(coalesce(p->>'father_cnic','')), '');
  v_sibling  uuid;
  v_family   uuid;
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

  -- THE PLAN'S LIMIT (0128). After the tenant checks so a crafted
  -- payload cannot use this as an oracle, and before the first write so a
  -- refusal leaves nothing behind. This is the only function in the schema
  -- that inserts a pupil: fn_enquiry_admit and fn_import_students both
  -- come through here, which is why the gate is here and not in three
  -- places.
  perform public.fn__assert_room_for_students(public.current_school_id(), 1);

  -- ---- family: (a) an explicit sibling link ----
  -- Take the first link that names a student we own. assert_own is what stops a
  -- crafted payload reaching into another school's family through this path.
  if p->'links' is not null and jsonb_typeof(p->'links') = 'array' then
    for v_link in select * from jsonb_array_elements(p->'links') loop
      if v_sibling is null and nullif(v_link->>'related_student_id','') is not null then
        v_sibling := nullif(v_link->>'related_student_id','')::uuid;
        perform public.assert_own('students', v_sibling);
        select family_id into v_family from public.students where id = v_sibling;
      end if;
    end loop;
  end if;

  if v_family is not null and v_father_cnic is not null then
    -- Stamp the CNIC on the sibling's family so the NEXT admission finds it by
    -- CNIC without needing the checkbox. Left as a no-op if that CNIC is
    -- already on another family — the unique index would reject it, and a
    -- conflict here means the data needs a human, not a failed admission.
    update public.families set head_cnic = v_father_cnic
    where id = v_family
      and head_cnic is null
      and not exists (
        select 1 from public.families f2
        where f2.school_id = public.current_school_id()
          and f2.head_cnic = v_father_cnic
      );
  end if;

  -- ---- family: (b) the father's CNIC ----
  if v_family is null and v_father_cnic is not null then
    v_family := public.fn_family_for(
      nullif(p->>'father_name',''), v_father_cnic,
      nullif(p->>'phone',''), nullif(p->>'whatsapp',''));
  end if;

  -- ---- (c) v_family stays null → the trigger makes a private one ----

  if v_gr_in is not null then
    v_gr := v_gr_in;
  else
    select gr_prefix into v_prefix from public.school_settings where school_id = public.current_school_id();
    v_counter := public.next_counter('gr');
    v_gr := coalesce(v_prefix, '') || lpad(v_counter::text, 4, '0');
  end if;

  insert into public.students(
    gr_no, admission_no, full_name, father_name, mother_name, b_form, dob, gender,
    address, phone, whatsapp, status, admission_date, notes, family_id)
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
    nullif(p->>'notes',''),
    v_family)
  returning id into v_student;

  -- Whatever the family ended up being — resolved above or created by the
  -- trigger — read it back so the admission-fee payment can be stamped with it.
  select family_id into v_family from public.students where id = v_student;

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

    select id into v_af_head from public.fee_heads where type = 'admission' and active and school_id = public.current_school_id()
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
      -- family_id stamped so the admission fee shows on the family sheet like
      -- any other payment. Before 0036 this was left null.
      insert into public.payments(student_id, family_id, amount, method, receipt_no, status, received_by, note)
      values (v_student, v_family, v_af_amt, 'cash', v_af_receipt, 'verified', v_actor, 'Admission fee')
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
    'family_id', v_family,
    'admission_fee_amount', v_af_recorded, 'admission_receipt_no', v_af_receipt);
end;
$function$;

CREATE OR REPLACE FUNCTION public.fn_finalize_attendance(p_session_id uuid, p_class_id uuid, p_section_id uuid, p_date date)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_count integer;
begin
  if not public.fn_may_write_register() then
    raise exception 'A register is finalised by the teacher who marked it.'
      using errcode = '42501';
  end if;
  if not public.fn_may_manage_class(p_session_id, p_class_id, p_section_id) then
    raise exception 'You can only finalize your assigned class';
  end if;
  -- `and not ad.is_locked`, from 0126: without it the statement rewrites every
  -- row of the section-day whether it was open or not, so the number it
  -- returns is "pupils in this section-day" while the screen prints it as
  -- "Finalized & locked 34 rows".
  update public.attendance_daily ad
    set is_locked = true
    from public.enrollments e
    where ad.enrollment_id = e.id
      and ad.attendance_date = p_date
      and e.session_id = p_session_id
      and e.class_id = p_class_id
      and e.section_id is not distinct from p_section_id
      and not ad.is_locked;
  get diagnostics v_count = row_count;

  if v_count > 0 then
    insert into public.audit_log (
      school_id, actor, actor_role, action, entity, entity_id, before, after)
    values (
      public.current_school_id(), auth.uid(),
      (select role from public.profiles where id = auth.uid()),
      'ATTENDANCE_FINALIZE', 'attendance_daily', p_date::text,
      jsonb_build_object('locked', false),
      jsonb_build_object('locked', true, 'rows', v_count,
                         'session_id', p_session_id, 'class_id', p_class_id,
                         'section_id', p_section_id));
  end if;

  return v_count;
end;
$function$;

CREATE OR REPLACE FUNCTION public.fn_publish_results(p_exam_term_id uuid, p_class_id uuid)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
$function$;

CREATE OR REPLACE FUNCTION public.fn_add_enquiry(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_school uuid := public.current_school_id();
  v_actor  uuid := auth.uid();
  v_no     bigint;
  v_id     uuid;
  v_phone  text := nullif(btrim(coalesce(p->>'phone', '')), '');
  v_child  text := nullif(btrim(coalesce(p->>'child_name', '')), '');
  v_dup    jsonb := 'null'::jsonb;
begin
  if not public.has_role('owner', 'principal', 'admin_clerk') then
    raise exception 'Not permitted to record an enquiry' using errcode = '42501';
  end if;
  if v_child is null then
    raise exception 'The child''s name is required';
  end if;
  if v_phone is null then
    raise exception 'A phone number is required: an enquiry nobody can ring is not an enquiry';
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

  return jsonb_build_object(
    'enquiry_id',        v_id,
    'enquiry_no',        v_no,
    'possible_duplicate', v_dup);
end;
$function$;

CREATE OR REPLACE FUNCTION public.fn_enquiry_admit(p_enquiry_id uuid, p_overrides jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_school  uuid := public.current_school_id();
  v_e       record;
  v_payload jsonb;
  v_res     jsonb;
  v_student uuid;
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

  return v_res || jsonb_build_object(
    'enquiry_id',     p_enquiry_id,
    'enquiry_no',     v_e.enquiry_no);
end;
$function$;

CREATE OR REPLACE FUNCTION public.fn_merge_families(p_keep uuid, p_absorb uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_moved int;
begin
  if not public.has_role('owner', 'principal', 'admin_clerk') then
    raise exception 'Not permitted to merge families';
  end if;
  if p_keep is null or p_absorb is null then
    raise exception 'Both families are required';
  end if;
  if p_keep = p_absorb then
    return p_keep;
  end if;

  -- Both must be ours. assert_own raises on a family belonging to another
  -- school, which is what stops this being a cross-tenant write primitive.
  perform public.assert_own('families', p_keep);
  perform public.assert_own('families', p_absorb);

  -- Carry across anything the surviving family is missing. The absorbed row is
  -- about to disappear, so a CNIC or phone recorded only there would be lost.
  update public.families k set
    head_cnic = coalesce(k.head_cnic, a.head_cnic),
    phone     = coalesce(k.phone,     a.phone),
    whatsapp  = coalesce(k.whatsapp,  a.whatsapp),
    address   = coalesce(k.address,   a.address)
  from public.families a
  where k.id = p_keep and a.id = p_absorb;

  update public.students      set family_id = p_keep where family_id = p_absorb;
  get diagnostics v_moved = row_count;
  update public.payments      set family_id = p_keep where family_id = p_absorb;
  update public.profiles      set family_id = p_keep where family_id = p_absorb;

  delete from public.families where id = p_absorb;

  return p_keep;
end;
$function$;

CREATE OR REPLACE FUNCTION public.fn__merge_two_families(p_keep uuid, p_absorb uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if p_keep = p_absorb then return; end if;

  if not exists (
    select 1 from public.families a join public.families b on a.school_id = b.school_id
    where a.id = p_keep and b.id = p_absorb
  ) then
    raise exception 'refusing to merge families across schools (% into %)', p_absorb, p_keep;
  end if;

  update public.families k set
    head_cnic = coalesce(k.head_cnic, a.head_cnic),
    phone     = coalesce(k.phone,     a.phone),
    whatsapp  = coalesce(k.whatsapp,  a.whatsapp),
    address   = coalesce(k.address,   a.address)
  from public.families a
  where k.id = p_keep and a.id = p_absorb;

  update public.students       set family_id = p_keep where family_id = p_absorb;
  update public.payments       set family_id = p_keep where family_id = p_absorb;
  update public.profiles       set family_id = p_keep where family_id = p_absorb;
  delete from public.families where id = p_absorb;
end;
$function$;

CREATE OR REPLACE FUNCTION public.fn_student_delete_blockers(p_student_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_school uuid := public.current_school_id();
  v_out jsonb := '[]'::jsonb;
  v_n bigint;
begin
  if not public.has_role('owner', 'principal') then
    raise exception 'Only the owner or principal may delete a student';
  end if;
  if not exists (select 1 from public.students
                 where id = p_student_id and school_id = v_school) then
    raise exception 'No such student in this school';
  end if;

  -- Money first: it is the reason this function exists.
  select count(*) into v_n from public.payments
   where student_id = p_student_id and school_id = v_school;
  if v_n > 0 then v_out := v_out || jsonb_build_object(
    'what', case when v_n = 1 then 'a payment received' else 'payments received' end,
    'count', v_n); end if;

  select count(*) into v_n from public.invoices
   where student_id = p_student_id and school_id = v_school;
  if v_n > 0 then v_out := v_out || jsonb_build_object(
    'what', case when v_n = 1 then 'a fee challan' else 'fee challans' end,
    'count', v_n); end if;

  select count(*) into v_n from public.adjustments
   where student_id = p_student_id and school_id = v_school;
  if v_n > 0 then v_out := v_out || jsonb_build_object(
    'what', case when v_n = 1 then 'a fine or discount' else 'fines or discounts' end,
    'count', v_n); end if;

  select count(*) into v_n from public.discounts d
    join public.enrollments e on e.id = d.enrollment_id
   where e.student_id = p_student_id and d.school_id = v_school;
  if v_n > 0 then v_out := v_out || jsonb_build_object('what', 'discounts', 'count', v_n); end if;

  -- Then the record of what happened to the child.
  select count(*) into v_n from public.attendance_daily a
    join public.enrollments e on e.id = a.enrollment_id
   where e.student_id = p_student_id and a.school_id = v_school;
  if v_n > 0 then v_out := v_out || jsonb_build_object(
    'what', case when v_n = 1 then 'a day of attendance' else 'days of attendance' end,
    'count', v_n); end if;

  select count(*) into v_n from public.mark_entries m
    join public.enrollments e on e.id = m.enrollment_id
   where e.student_id = p_student_id and m.school_id = v_school;
  if v_n > 0 then v_out := v_out || jsonb_build_object(
    'what', case when v_n = 1 then 'an exam mark' else 'exam marks' end,
    'count', v_n); end if;

  select count(*) into v_n from public.result_cards
   where student_id = p_student_id and school_id = v_school;
  if v_n > 0 then v_out := v_out || jsonb_build_object('what', 'result cards', 'count', v_n); end if;

  -- Then anything that left the building with the school's name on it.
  select count(*) into v_n from public.certificates
   where student_id = p_student_id and school_id = v_school;
  if v_n > 0 then v_out := v_out || jsonb_build_object(
    'what', case when v_n = 1 then 'a certificate issued' else 'certificates issued' end,
    'count', v_n); end if;

  select count(*) into v_n from public.admission_enquiries
   where admitted_student_id = p_student_id and school_id = v_school;
  if v_n > 0 then v_out := v_out || jsonb_build_object('what', 'an admission enquiry', 'count', v_n); end if;

  return v_out;
end;
$function$;

CREATE OR REPLACE FUNCTION public.fn_platform_school_detail(p_school_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_school   record;
  v_settings record;
  v_sub      record;
  v_plan     record;
  v_status   public.subscription_status;
  v_expiry   date;
  v_margin   integer;
  v_sess     uuid;
  v_n_classes    integer; v_n_sections integer; v_n_heads integer;
  v_n_priced     integer; v_n_students integer; v_n_staff integer;
  v_n_families   integer; v_n_parents  integer;
  v_billed       boolean; v_last_pay date; v_invoiced numeric; v_paid numeric;
  v_ready jsonb := '[]'::jsonb;
begin
  if not public.is_platform_admin() then
    raise exception 'Not permitted' using errcode = '42501';
  end if;

  select * into v_school from public.schools where id = p_school_id;
  if not found then
    raise exception 'School not found';
  end if;

  select * into v_settings from public.school_settings where school_id = p_school_id;
  select * into v_sub      from public.subscriptions  where school_id = p_school_id;
  if v_sub.plan_code is not null then
    select * into v_plan from public.plans where code = v_sub.plan_code;
    v_status := public.fn_effective_status(p_school_id);
    v_margin := public.plan_margin_limit(
                  public.fn__student_limit(p_school_id));
    v_expiry := case
      when v_status = 'trialing' then v_sub.trial_ends_on
      when v_status = 'active'   then v_sub.period_end
      when v_status = 'grace'    then v_sub.period_end + public.grace_days()
      else null end;
  end if;

  -- --- the numbers behind the checklist -----------------------------------
  select id into v_sess from public.academic_sessions
   where school_id = p_school_id and is_current limit 1;

  select count(*) into v_n_classes  from public.classes  where school_id = p_school_id and active;
  select count(*) into v_n_sections from public.sections where school_id = p_school_id;
  select count(*) into v_n_heads    from public.fee_heads where school_id = p_school_id and active;

  -- Classes with at least one fee amount on record, not rows in fee_structures:
  -- one head priced for one class is not a priced school, and the operator needs
  -- to see "3 of 11 classes priced" rather than "yes, fees are set".
  select count(distinct class_id) into v_n_priced
    from public.fee_structures where school_id = p_school_id;

  select count(*) into v_n_students from public.students
   where school_id = p_school_id and deleted_at is null and status = 'active';
  select count(*) into v_n_staff from public.staff
   where school_id = p_school_id and deleted_at is null and left_on is null;
  select count(*) into v_n_families from public.families where school_id = p_school_id;
  select count(*) into v_n_parents  from public.profiles
   where school_id = p_school_id and role = 'parent' and active;

  select exists (select 1 from public.invoices
                  where school_id = p_school_id and period_month is not null)
    into v_billed;
  select max(created_at)::date into v_last_pay from public.payments
   where school_id = p_school_id and status = 'verified';

  v_invoiced := public.fn__platform_billed(p_school_id);
  v_paid := public.fn__platform_settled(p_school_id);

  -- --- the checklist, in the order a school has to do it -------------------
  -- Ordered deliberately: you cannot price a class that does not exist, or put
  -- an amount against a fee head that has not been created. The UI shows the
  -- first unfinished row as the next thing to talk to them about.
  v_ready :=
    jsonb_build_array(
      jsonb_build_object('key','session','label','An academic year is set',
        'done', v_sess is not null,
        'detail', case when v_sess is null then 'Settings → Sessions' else '' end),
      jsonb_build_object('key','classes','label','Classes created',
        'done', v_n_classes > 0, 'detail', v_n_classes || ' class(es)'),
      jsonb_build_object('key','sections','label','Sections created',
        'done', v_n_sections > 0, 'detail', v_n_sections || ' section(s)'),
      jsonb_build_object('key','feeheads','label','Fee heads created',
        'done', v_n_heads > 0,
        'detail', case when v_n_heads = 0
                       then 'Nothing to charge for yet: Settings → Fee Heads'
                       else v_n_heads || ' active' end),
      jsonb_build_object('key','prices','label','Fee amounts set per class',
        'done', v_n_priced > 0,
        'detail', v_n_priced || ' of ' || v_n_classes || ' class(es) priced'),
      jsonb_build_object('key','students','label','Students admitted',
        'done', v_n_students > 0, 'detail', v_n_students || ' on roll'),
      jsonb_build_object('key','staff','label','Staff added',
        'done', v_n_staff > 0, 'detail', v_n_staff || ' on the books'),
      jsonb_build_object('key','billed','label','A month has been billed',
        'done', v_billed,
        'detail', case when v_billed then '' else 'Fees → Generate challans' end),
      jsonb_build_object('key','collected','label','A payment has been taken',
        'done', v_last_pay is not null,
        'detail', case when v_last_pay is null then ''
                       else 'last on ' || v_last_pay::text end)
    );

  return jsonb_build_object(
    'school', jsonb_build_object(
      'id', v_school.id, 'name', v_school.name, 'city', v_school.city,
      'contact_name', v_school.contact_name, 'contact_phone', v_school.contact_phone,
      'contact_email', v_school.contact_email, 'notes', v_school.notes,
      'active', v_school.active, 'created_at', v_school.created_at,
      -- From school_settings, which is what the school itself maintains — so a
      -- mismatch with the signup details above is itself informative.
      'display_name', v_settings.name, 'address', v_settings.address,
      'phone', v_settings.phone, 'principal_name', v_settings.principal_name,
      'has_logo', v_settings.logo_path is not null),

    'licence', case when v_sub.plan_code is null then 'null'::jsonb else
      jsonb_build_object(
        'plan_code', v_sub.plan_code, 'plan_name', v_plan.name,
        'status', v_status, 'cycle', v_sub.cycle,
        'expires_on', v_expiry,
        'days_left', case when v_expiry is null then null else v_expiry - current_date end,
        'student_count', v_sub.student_count,
        -- 0128: WHAT THEY ARE ALLOWED, not what the price list says. An
        -- allowance an operator granted is the whole point of this
        -- migration, and a console showing the plan's number instead
        -- would have the operator grant it twice.
        'student_limit', public.fn__student_limit(p_school_id),
        'plan_student_limit', v_plan.student_limit,
        'limit_override', v_sub.student_limit_override,
        'limit_override_reason', v_sub.student_limit_override_reason,
        'limit_override_at', v_sub.student_limit_override_at,
        -- Who granted it, by name, because "who agreed to this?" is the
        -- first question asked about an exception six months later.
        'limit_override_by', (select pr.full_name from public.profiles pr
                               where pr.id = v_sub.student_limit_override_by),
        -- The request waiting, if there is one. An operator granting from
        -- this page instead of the queue is otherwise granting blind.
        'limit_request', (select jsonb_build_object(
                                   'id', r.id, 'requested_limit', r.requested_limit,
                                   'reason', r.reason, 'wants', r.wants,
                                   'requested_at', r.requested_at)
                            from public.student_limit_requests r
                           where r.school_id = p_school_id
                             and r.status = 'pending'),
        'margin_limit', v_margin,
        'counted_at', v_sub.counted_at,
        'over_limit_since', v_sub.over_limit_flagged_at,
        'limit_state', case          when public.fn__student_limit(p_school_id) is null then 'ok'
          when v_sub.student_count
                 <= public.fn__student_limit(p_school_id) then 'ok'
          when v_sub.student_count <= v_margin then 'within_margin'
          else 'over' end,
        'suggested_plan', (select p2.code from public.plans p2
                            where p2.active
                              and (p2.student_limit is null
                                or p2.student_limit >= v_sub.student_count)
                            order by p2.sort_order limit 1)) end,

    'money', jsonb_build_object(
      'invoiced', v_invoiced, 'paid', v_paid, 'outstanding', v_invoiced - v_paid,
      'last_paid_on', (select max(paid_on) from public.platform_payments
                        where school_id = p_school_id),
      'invoice_count', (select count(*) from public.platform_invoices
                         where school_id = p_school_id
                           and kind = 'invoice' and voided_at is null)),

    -- The school's own logins. NOT the children — see the header.
    --
    -- ever_signed_in is the churn signal that nothing in this product could see
    -- before: a school with one login that has not been used in three weeks is
    -- leaving, and an accountant who was invited and never signed in is a seat
    -- somebody is not using and probably does not know about.
    'people', coalesce((
      select jsonb_agg(jsonb_build_object(
               'name', pr.full_name, 'role', pr.role, 'active', pr.active,
               'added_on', pr.created_at,
               'ever_signed_in', u.last_sign_in_at is not null,
               'last_sign_in', u.last_sign_in_at)
             order by pr.role, pr.full_name)
        from public.profiles pr
        left join auth.users u on u.id = pr.id
       where pr.school_id = p_school_id and pr.role <> 'parent'), '[]'::jsonb),

    'counts', jsonb_build_object(
      'classes', v_n_classes, 'sections', v_n_sections, 'fee_heads', v_n_heads,
      'classes_priced', v_n_priced, 'students', v_n_students, 'staff', v_n_staff,
      'families', v_n_families, 'parents_linked', v_n_parents),

    'readiness', v_ready,

    -- Is anybody actually using it? Dates only, one per module. A school whose
    -- last attendance was in April is not using attendance, whatever the roll
    -- says.
    'activity', jsonb_build_object(
      'last_payment',     (select max(created_at) from public.payments
                            where school_id = p_school_id and status = 'verified'),
      'last_invoice',     (select max(created_at) from public.invoices
                            where school_id = p_school_id),
      'last_attendance',  (select max(attendance_date) from public.attendance_daily
                            where school_id = p_school_id),
      'last_mark',        (select max(created_at) from public.mark_entries
                            where school_id = p_school_id),
      'last_certificate', (select max(issued_on) from public.certificates
                            where school_id = p_school_id)),

    -- Stated rather than silently absent. "Has a challan been printed" is the
    -- one readiness question this schema cannot answer: printing happens in the
    -- browser and nothing records it. Saying so beats a checklist row that is
    -- quietly always false, which would send the operator chasing a step the
    -- school had already done.
    'not_recorded', jsonb_build_array(
      'whether a challan was ever printed: printing is a browser action and '
      || 'nothing records it')
  );
end;
$function$;

-- ============================== 2. the column stays, and stays empty ========
-- payments.till_session_id had exactly one reader, the till report, and one
-- writer, fn__ensure_till. Both are gone from every caller above, so from here
-- on it is null on every payment ever recorded, and this backfills the ones
-- that already had a value so the column holds nothing at all.
--
-- It is NOT dropped, for the reason section 4 sets out at length: bundle 1
-- creates it, bundle 12 patches function bodies that name it, and those files
-- are frozen. A dropped column turns a re-paste into an error, and a re-paste
-- is what verify.sql and supabase/repair/detect.sql tell a school to do.
update public.payments set till_session_id = null where till_session_id is not null;
comment on column public.payments.till_session_id is
  'RETIRED in 0136 with the cash drawer. Always null. Kept only because bundle '
  '1 and bundle 12 are frozen and name it. Nothing reads or writes it.';

-- ============================================ 3. the two triggers first =====
-- A function a trigger points at cannot be dropped while the trigger exists,
-- and the error names the trigger rather than the feature, which is how a
-- removal like this ends up half done. Both of these are the outbox reaching
-- into tables that survive it: one seeded a new school's message templates, the
-- other queued a receipt every time a payment was recorded.
drop trigger if exists trg_schools_message_templates on public.schools;
drop trigger if exists trg_payments_queue_receipt on public.payments;

-- ============================================== 4. the till, and the queue ===
--
-- NOTHING HERE IS DROPPED, AND THAT IS NOT CAUTION. It is the only shape that
-- keeps the paste model working, and it was arrived at by trying the other one
-- first and watching five bundles refuse.
--
-- A bundle is ONE transaction: one raise inside it rolls the whole file back.
-- Five bundles that have already shipped, and which supabase/bundles/MANIFEST
-- therefore freezes, depend on this feature still being present:
--
--   bundle 4   alter table public.message_outbox add column enquiry_id ...
--              create index idx_outbox_enquiry on public.message_outbox ...
--   bundle 7   revoke all on function public.fn__default_message_templates()
--              0069 reads till_sessions to tell a half-applied schema apart
--              0088 walks every seeded template key and RAISES unless some
--              other function's body mentions it, which is what makes
--              fn_queue_class_reminders and fn_queue_enquiry_message
--              load-bearing rather than merely present
--   bundle 8   0090 refuses to finish unless fn_queue_message's body still
--              carries the school scope 0070 put in it
--   bundle 24  create index idx_message_outbox_student / _family
--   bundle 28  0122 rewrites the em dash out of message_templates rows
--
-- Drop any of it and those five raise. That is not a cosmetic error in a log.
-- verify.sql tells a school with a problem to "re-run bundle 7"; the
-- supabase/repair/detect.sql path tells a school stuck part-way to apply the
-- migrations it lacks and then paste the bundles again from 5 upward; the CI
-- job that exists precisely because an upgrade path broke once and cost a real
-- school fifteen migrations does the same. Every one of those instructions
-- would hand the school a red ERROR and stop before reaching the bundle that
-- fixes anything, and the five files cannot be edited to prevent it: they are
-- generated from migrations that have already been applied in the field.
--
-- So the FEATURE is removed and the SCHEMA is sealed. What that means here,
-- and it is a complete removal from every direction a person or a request can
-- come from:
--
--   no screen          the sidebar entry, the Messages screen, the templates
--                      screen and the till screen are deleted (see web/)
--   no API             every one of these functions is revoked from anon,
--                      authenticated AND service_role, so a hand-written
--                      PostgREST call fails on permission, not on a 404
--   no rows            every message, every template and every till session is
--                      deleted, and payments.till_session_id is blanked
--   no reads or writes every policy on the three tables is dropped and RLS is
--                      FORCED, which binds the table owner too, so even a
--                      SECURITY DEFINER function reads and writes nothing
--   no writers         both triggers are dropped (section 3) and all twelve
--                      callers are rewritten (section 1)
--
-- What is left is inert: tables nothing can open and functions nothing can
-- call. A re-paste of bundle 4, 7, 8, 24 or 28 re-grants some of these, which
-- is harmless and self-correcting, because bundles are pasted in ASCENDING
-- order and bundle 39 always runs last and closes them again.
-- supabase/tests/removed_features.sql asserts the sealed state rather than
-- absence, because sealed is what can actually be guaranteed.
--
-- Scoped to exact names rather than to anything matching "message", because
-- fn_platform_renewal_message belongs to the OPERATOR CONSOLE and stays: it is
-- the vendor's renewal reminder to a school, not a school's message to a
-- parent. Every overload is closed, not one signature, because 0034, 0070 and
-- 0088 each shipped a different argument list for fn_queue_message and a
-- school can be carrying any of them.
do $shut$
declare
  r record;
  v_n int := 0;
begin
  for r in
    select p.oid::regprocedure as sig
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and (p.proname ~ 'till'
            or p.proname in ('fn_queue_message','fn_queue_absent_today',
                             'fn_queue_class_reminders','fn_queue_enquiry_message',
                             'fn_queue_result_published','fn__queue_payment_receipt',
                             'fn_mark_message_sent','fn_skip_message',
                             'fn_message_settings','fn_reset_message_template',
                             'fn_provision_message_templates',
                             'fn__seed_message_templates','fn__default_message_templates',
                             'fn_unsent_receipts','fn__render_template'))
  loop
    execute format('revoke all on function %s from public, anon, authenticated, service_role', r.sig);
    v_n := v_n + 1;
  end loop;
  raise notice '0136: closed % till and outbox function(s) to every caller', v_n;
end
$shut$;

-- THE TEMPLATE LIST ITSELF, EMPTIED. This one is not housekeeping, it is what
-- makes bundle 7 re-pasteable, and the first two attempts at this migration
-- both failed here.
--
-- 0088 ends bundle 7 with a sweep: for every key fn__default_message_templates
-- returns, SOME other function's body must mention that key, or it raises and
-- takes the bundle with it. The check is a good one. It exists because four
-- templates shipped that a school could write and switch on and that nothing
-- ever sent. But its premise is a feature that is now gone: there is no
-- Settings then Messages screen to edit a template on, no toggle to switch one
-- on, and message_templates is emptied and sealed below.
--
-- The temptation is to leave the four key names sitting in a comment inside
-- some surviving function, because prosrc includes comments and the LIKE would
-- be satisfied. That is a lie told to a guard, and this project has already
-- been bitten once by a text patch matching its own explanatory comment.
--
-- The truthful fix is that there are no default templates any more, so the
-- sweep has nothing to walk. Same signature and same return type, because
-- bundle 7 REVOKES this function by name and `create or replace` cannot change
-- a return type. Emptying it also means fn__seed_message_templates and
-- fn_provision_message_templates, which read from it, now insert nothing: a
-- school created after this migration gets no templates even if a re-paste
-- briefly puts their trigger back.
create or replace function public.fn__default_message_templates()
 returns table(template_key text, label text, body text, tags text[])
 language sql
 immutable
 set search_path to 'public'
as $function$
  -- No rows. The outbox was removed in 0136; nothing sends a template, so
  -- nothing should offer one. Typed explicitly because an empty VALUES list is
  -- not valid SQL and the column types have to come from somewhere.
  select null::text, null::text, null::text, null::text[] where false
$function$;

-- The rows. This is the wipe: no message a parent might still receive, no till
-- session anybody can reopen, nothing left to export.
delete from public.message_outbox;
delete from public.message_templates;
delete from public.till_sessions;

-- And the doors. Every policy on the three tables is dropped and RLS is FORCED,
-- which applies to the table owner too, so even a SECURITY DEFINER function
-- that somehow named one of these would read nothing and write nothing. The
-- grants go with them, service_role included: the Edge Functions have no
-- business here either.
do $seal$
declare
  r record;
  t text;
begin
  foreach t in array array['message_outbox', 'message_templates', 'till_sessions']
  loop
    if to_regclass('public.' || t) is null then
      continue;
    end if;
    for r in select policyname from pg_policies
              where schemaname = 'public' and tablename = t
    loop
      execute format('drop policy if exists %I on public.%I', r.policyname, t);
    end loop;
    execute format('revoke all on table public.%I from public, anon, authenticated, service_role', t);
    execute format('alter table public.%I enable row level security', t);
    execute format('alter table public.%I force row level security', t);
    execute format(
      'comment on table public.%I is %L', t,
      'RETIRED in 0136. The WhatsApp outbox and the cash drawer were removed '
      'from the software. This table is kept EMPTY and SEALED only because '
      'bundles 4, 7, 8, 24 and 28 are frozen and name it in DDL, so dropping '
      'it would make those bundles refuse to re-apply and break the repair '
      'path. Nothing reads it and nothing writes it. Do not build on it.');
  end loop;
end
$seal$;

-- The message_status enum stays with the column that has that type.


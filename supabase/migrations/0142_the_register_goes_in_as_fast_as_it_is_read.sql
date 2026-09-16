-- =============================================================================
-- 0142  The register goes in as fast as it is read
--
-- A SCHOOL SIGNING UP HAS FOUR HUNDRED CHILDREN ALREADY, IN A PAPER REGISTER,
-- and this product gave them two ways in, both of which lose the trial:
--
--   * the admission form, which is correct and thorough and takes minutes per
--     child. Four hundred children is a fortnight of evenings.
--   * the CSV importer, which asks a head teacher in Sialkot to produce a
--     column-mapped spreadsheet and then read validation errors. That is not a
--     data-entry problem, it is a software-literacy problem, and it is the one
--     the product exists to remove.
--
-- The importer is untouched. What is added here is the third way: typing
-- straight down a class list, the way the register is already read aloud.
--
-- FIVE THINGS THIS HAD TO GET RIGHT, and the reasons are all "otherwise a real
-- school loses real data":
--
-- 1. ONE BAD ROW MUST NOT LOSE NINETY-NINE GOOD ONES. Entering a class is one
--    call with a hundred rows in it. A duplicate GR number on row 57 cannot be
--    allowed to roll the transaction back: the clerk typed for twenty minutes.
--    Every row runs inside its own PL/pgSQL exception block, which is an
--    implicit savepoint, so row 57 comes back with a message and the other
--    ninety-nine are committed.
--
-- 2. GR NUMBERS UNDER CONCURRENCY. next_counter is atomic, so two clerks adding
--    at the same moment cannot take the same number. That was never the hole.
--    The hole is a school that typed GR 0001 to 0400 BY HAND and then leaves the
--    box blank: the counter is still at zero, hands back 0001, and the insert
--    fails on students_gr_no_school_key. So a manual GR now raises the counter's
--    high-water mark past itself, and the automatic path retries past anything
--    already taken instead of failing. Both are needed: the high-water mark
--    keeps the common case at one round trip, the retry covers the GR numbers
--    that were already in the table before this migration existed.
--
-- 3. AN INCOMPLETE PROFILE IS STILL A CHILD. students.is_draft is a LABEL AND
--    NOTHING ELSE. It gates no register, no challan, no result card and no
--    report. A child entered as a name and a roll number is on tomorrow's
--    attendance sheet and on this month's challan run exactly like any other.
--    The only thing the flag does is put a count on the dashboard so the
--    principal is reminded to finish the record. A flag that quietly excluded
--    children from billing would be worse than no flag: the school would find
--    out in a month, by being short.
--
-- 4. A SIBLING LINK IS A BILLING DECISION. 0036 already resolves a family at
--    admission and 0103 already bills a family as one. What was missing is the
--    path from "this child is Bilal's brother" to "one challan arrives at that
--    house", when the sibling was typed on the row above and has no CNIC on
--    file. Passing the sibling through fn_admit_student's links array does it:
--    the new child joins that family, and every fee screen in the product is
--    already family-shaped.
--
-- 5. ARREARS BELONG TO A MONTH, not to a lump. fn_import_opening_balances
--    writes one invoice with period_month NULL, which is right for a balance
--    brought forward from a previous YEAR. It is wrong for a school onboarding
--    in September whose families owe for June, July and August of the year in
--    progress: those are months, they belong on the arrears list by name, and
--    0140's fn_arrears reads period_month. So each month named gets its own
--    invoice at the amount the school states. That also stops the automatic
--    biller raising a second challan for the same month, because
--    uq_invoice_enroll_month already forbids it.
-- =============================================================================

-- ================================================== 1. the draft label ========
alter table public.students
  add column if not exists is_draft boolean not null default false;

comment on column public.students.is_draft is
  'A REMINDER, NEVER A GATE. Set when a child was entered with only part of '
  'their record so the dashboard can prompt somebody to finish it. Nothing in '
  'this schema reads it to decide whether a child is billed, marked present, '
  'examined or reported. Excluding a draft child from billing would make the '
  'school short by a month before anybody noticed.';

-- Partial, because the interesting set is small and shrinking: it is the list a
-- school works through once and then never sees again.
create index if not exists ix_students_draft
  on public.students (school_id)
  where is_draft and deleted_at is null;

-- ============================================ 2. a GR number nobody else has ==
-- THE HIGH-WATER MARK. Called after a manual GR is accepted so the automatic
-- path never walks back into a range a human has already used.
--
-- Only the digits are read, and only when the whole tail is digits: a school
-- using "2024-A-17" gets no bump rather than a wrong one, and falls through to
-- the retry loop below, which is correct if slower.
create or replace function public.fn__gr_high_water(p_gr text)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_school uuid := public.current_school_id();
  v_prefix text;
  v_tail   text;
  v_num    bigint;
begin
  if p_gr is null or v_school is null then return; end if;
  select gr_prefix into v_prefix from public.school_settings where school_id = v_school;
  v_tail := p_gr;
  if coalesce(v_prefix, '') <> '' and left(v_tail, length(v_prefix)) = v_prefix then
    v_tail := substr(v_tail, length(v_prefix) + 1);
  end if;
  if v_tail !~ '^[0-9]+$' then return; end if;
  -- Longer than a bigint, or absurd: leave the counter alone rather than
  -- raising inside an admission that is otherwise fine.
  if length(v_tail) > 15 then return; end if;
  v_num := v_tail::bigint;

  insert into public.counters(school_id, key, value) values (v_school, 'gr', v_num)
  on conflict (school_id, key) do update
    set value = greatest(public.counters.value, excluded.value);
end;
$$;
revoke all on function public.fn__gr_high_water(text) from public, anon, authenticated;

-- THE AUTOMATIC PATH, and it RETRIES. The high-water mark above only helps
-- from the moment it is first called; a database that already holds hand-typed
-- GR numbers from before this migration needs the counter to be able to walk
-- past them. Bounded, because an unbounded loop inside a bulk insert is how one
-- bad row hangs a hundred good ones.
create or replace function public.fn__next_gr()
returns text language plpgsql security definer set search_path = public as $$
declare
  v_school  uuid := public.current_school_id();
  v_prefix  text;
  v_gr      text;
  v_tries   int := 0;
begin
  select gr_prefix into v_prefix from public.school_settings where school_id = v_school;
  loop
    v_tries := v_tries + 1;
    v_gr := coalesce(v_prefix, '') || lpad(public.next_counter('gr')::text, 4, '0');
    exit when not exists (
      select 1 from public.students
       where school_id = v_school and gr_no = v_gr);
    if v_tries >= 200 then
      raise exception 'Could not find a free GR number after 200 tries. The '
        'numbers in use do not line up with the counter: set the next GR number '
        'under Settings.' using errcode = '55000';
    end if;
  end loop;
  return v_gr;
end;
$$;
revoke all on function public.fn__next_gr() from public, anon, authenticated;

-- ======================================== 3. admission, told about both ======
-- fn_admit_student REPRODUCED FROM THE LIVE FUNCTION, not retyped from the
-- migration that first wrote it, and that distinction cost a round. The first
-- draft of this file copied 0036's body, which is the version from before 0072
-- scoped the admission-fee head to the school and before 0128 added the plan's
-- student limit. Both fixes were silently dropped, and both matter here more
-- than anywhere: a school with no admission fee head of its own would have
-- picked up ANOTHER SCHOOL'S, and a school on a hundred-pupil plan could have
-- typed four hundred children straight past its licence through the very screen
-- this migration adds. supabase/repair/detect.sql reported both within a minute
-- of the migration applying, which is what that file is for.
--
-- The changes on top of the live body are four: the GR block calls the two
-- helpers above, every text field is trimmed, is_draft is read back from the
-- row, and the return carries the draft flag.
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
  v_gr_in   text := nullif(btrim(coalesce(p->>'gr_no','')), '');
  v_draft   boolean := false;
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

  -- ---- the GR number (0142) ----
  -- next_counter has always been atomic, so two clerks adding at the same moment
  -- could never take the same number. That was not the hole. The hole is a
  -- school that typed GR 0001 to 0400 BY HAND and then leaves the box blank: the
  -- counter is still at zero, hands back 0001, and the insert dies on
  -- students_gr_no_school_key with a Postgres constraint name on the screen.
  if v_gr_in is not null then
    v_gr := v_gr_in;
    if exists (select 1 from public.students
                where school_id = public.current_school_id() and gr_no = v_gr) then
      raise exception 'GR number % is already used by another student in this '
        'school. Leave it blank to have one allotted.', v_gr
        using errcode = '23505';
    end if;
    -- The counter must never hand this number back later.
    perform public.fn__gr_high_water(v_gr);
  else
    v_gr := public.fn__next_gr();
  end if;

  insert into public.students(
    gr_no, admission_no, full_name, father_name, mother_name, b_form, dob, gender,
    address, phone, whatsapp, status, admission_date, notes, family_id)
  values (
    v_gr,
    -- btrim on every text field (0142). A name typed off a register arrives
    -- with a trailing space often enough to matter, and " Bilal" sorts before
    -- every other name on the roster and is not found by a search for "Bilal".
    nullif(btrim(coalesce(p->>'admission_no','')), ''),
    btrim(p->>'full_name'),
    nullif(btrim(coalesce(p->>'father_name','')), ''),
    nullif(btrim(coalesce(p->>'mother_name','')), ''),
    nullif(btrim(coalesce(p->>'b_form','')), ''),
    nullif(p->>'dob','')::date,
    nullif(p->>'gender','')::public.gender,
    nullif(btrim(coalesce(p->>'address','')), ''),
    nullif(btrim(coalesce(p->>'phone','')), ''),
    nullif(btrim(coalesce(p->>'whatsapp','')), ''),
    'active',
    coalesce(nullif(p->>'admission_date','')::date, current_date),
    nullif(btrim(coalesce(p->>'notes','')), ''),
    v_family)
  returning id into v_student;

  -- Whatever the family ended up being — resolved above or created by the
  -- trigger — read it back so the admission-fee payment can be stamped with it.
  -- is_draft comes back with it (0142): trg_students_draft decides that from
  -- the record as it actually landed, and returning the value that went IN would
  -- tell the caller a name-and-roll-only child is a complete record, which is
  -- the one thing the flag exists to say.
  select family_id, is_draft into v_family, v_draft
    from public.students where id = v_student;

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
    'family_id', v_family, 'is_draft', v_draft,
    'admission_fee_amount', v_af_recorded, 'admission_receipt_no', v_af_receipt);
end;
$function$;

revoke all on function public.fn_admit_student(jsonb) from public, anon;
grant execute on function public.fn_admit_student(jsonb) to authenticated;

-- ============================== 4. what makes a record incomplete, in one place
-- A TRIGGER, NOT A FLAG THE SCREEN SETS. If the screen owned this, the reminder
-- would still be on the dashboard after somebody finished the record, because
-- nothing would have told it. Maintained here, filling the gaps clears the
-- reminder by itself, from any screen, including the importer and the API.
--
-- WHAT COUNTS AS MISSING is the set a school cannot work without:
--   father's name   every register, every challan and every certificate prints it
--   gender          the register is split by it and the result card prints it
--   date of birth   the leaving certificate and the board form both require it
--   a number        no phone and no WhatsApp means the school cannot reach them
--
-- B-Form is NOT in the list on purpose. Half these children do not have one at
-- admission, and a reminder that can never be cleared is a reminder a principal
-- learns to ignore.
create or replace function public.fn__students_mark_draft()
returns trigger language plpgsql set search_path = public as $$
begin
  new.is_draft := (
    nullif(btrim(coalesce(new.father_name, '')), '') is null
    or new.gender is null
    or new.dob is null
    or (nullif(btrim(coalesce(new.phone, '')), '') is null
        and nullif(btrim(coalesce(new.whatsapp, '')), '') is null)
  );
  return new;
end;
$$;

-- REVOKED FROM EVERYBODY, INCLUDING authenticated. A trigger function needs no
-- grant at all: it runs as the table owner whatever the caller holds. Left with
-- Supabase's default privileges it is an fn__ helper executable from a browser,
-- which is precisely what 0125 exists to stop and what detect.sql reported the
-- moment this was first written.
revoke all on function public.fn__students_mark_draft() from public, anon, authenticated;

drop trigger if exists trg_students_draft on public.students;
create trigger trg_students_draft
  before insert or update of father_name, gender, dob, phone, whatsapp
  on public.students
  for each row execute function public.fn__students_mark_draft();

-- Bring the existing roster into line in one pass, so the dashboard count is
-- true on the morning this is applied rather than only for children added after.
update public.students s
   set is_draft = (
     nullif(btrim(coalesce(s.father_name, '')), '') is null
     or s.gender is null
     or s.dob is null
     or (nullif(btrim(coalesce(s.phone, '')), '') is null
         and nullif(btrim(coalesce(s.whatsapp, '')), '') is null))
 where s.deleted_at is null
   and s.is_draft is distinct from (
     nullif(btrim(coalesce(s.father_name, '')), '') is null
     or s.gender is null
     or s.dob is null
     or (nullif(btrim(coalesce(s.phone, '')), '') is null
         and nullif(btrim(coalesce(s.whatsapp, '')), '') is null));

-- ================================================= 5. the arrears of a month ==
-- ONE INVOICE PER MONTH NAMED, at the amount the school states, which is not
-- what fn_import_opening_balances does and should not be. That writes a single
-- invoice with period_month NULL, which is the right shape for a balance
-- brought forward from a previous YEAR and the wrong shape for the case this
-- exists for: a school onboarding in September whose families owe for June,
-- July and August of the year in progress. Those are months. 0140's fn_arrears
-- counts months, the family sheet lists them by name, and a parent at the
-- window asks about August rather than about a total.
--
-- The side effect is deliberate as well: uq_invoice_enroll_month means the
-- automatic biller cannot raise a SECOND challan for a month entered this way.
-- Without it a school that typed "August: Rs 3,000 owing" would find August
-- billed twice the moment fn_ensure_billing_current next ran.
create or replace function public.fn__rde_arrears(
  p_enrollment_id uuid, p_months jsonb
) returns integer language plpgsql security definer set search_path = public as $$
declare
  v_enr   record;
  v_row   jsonb;
  v_month date;
  v_amt   numeric;
  v_inv   uuid;
  v_n     integer := 0;
  v_start date;
  v_today date := (now() at time zone 'Asia/Karachi')::date;
begin
  if p_months is null or jsonb_typeof(p_months) <> 'array' then return 0; end if;

  select e.id, e.student_id, e.session_id, s.starts_on
    into v_enr
    from public.enrollments e
    join public.academic_sessions s on s.id = e.session_id
   where e.id = p_enrollment_id;
  if not found then raise exception 'Enrolment not found'; end if;
  v_start := date_trunc('month', v_enr.starts_on)::date;

  for v_row in select * from jsonb_array_elements(p_months) loop
    v_month := date_trunc('month', nullif(v_row->>'month','')::date)::date;
    v_amt   := coalesce(nullif(v_row->>'amount','')::numeric, 0);
    continue when v_month is null or v_amt <= 0;

    -- BOUNDED at both ends. 0130 exists because an unbounded date parameter is
    -- how attendance was marked in 2099, and this one takes dates from a
    -- browser. Before the school year is not arrears, it is a different year's
    -- business; this month or later is not arrears either, it is the bill.
    if v_month < v_start then
      raise exception 'Arrears for % are before this school year began (%). '
        'Use Settings, Import opening balances for money owed from a previous '
        'year.', to_char(v_month, 'Mon YYYY'), to_char(v_start, 'Mon YYYY')
        using errcode = '22008';
    end if;
    if v_month >= date_trunc('month', v_today)::date then
      raise exception 'Arrears must be for a month that has already finished. '
        '% has not.', to_char(v_month, 'Mon YYYY') using errcode = '22008';
    end if;

    -- Already billed or already entered: leave it alone rather than raise. A
    -- clerk who saves the same row twice must not get an error, and must not
    -- get two challans for August either.
    continue when exists (
      select 1 from public.invoices
       where enrollment_id = p_enrollment_id
         and period_month = v_month and status <> 'void');

    insert into public.invoices(student_id, enrollment_id, session_id, period_month,
        status, arrears_brought_forward, fine, due_date, notes, issued_at, created_by)
    values (v_enr.student_id, p_enrollment_id, v_enr.session_id, v_month,
        'issued', 0, 0, (v_month + interval '1 month' - interval '1 day')::date,
        'rde_arrears', now(), auth.uid())
    returning id into v_inv;

    insert into public.invoice_lines(invoice_id, fee_head_id, description, amount, is_discount)
    values (v_inv, null,
            'Fee for ' || to_char(v_month, 'Mon YYYY') || ' (entered at onboarding)',
            v_amt, false);
    v_n := v_n + 1;
  end loop;
  return v_n;
end;
$$;
revoke all on function public.fn__rde_arrears(uuid, jsonb) from public, anon, authenticated;

-- ========================================== 6. a class, typed straight down ===
-- ONE CALL, N ROWS, AND EVERY ROW ITS OWN SAVEPOINT.
--
-- This is the whole reason the function exists rather than the screen looping
-- over fn_admit_student. A hundred separate round trips over a Pakistani
-- broadband connection is a minute of spinner; worse, it has no transaction, so
-- a browser closed half way leaves half a class entered and nobody knows which
-- half. One call fixes the timing. A single transaction on its own would then
-- create a worse problem: a duplicate GR number on row 57 rolls back the
-- twenty minutes of typing that came before it.
--
-- A PL/pgSQL exception block is an implicit savepoint, so each row is its own
-- unit: row 57 comes back with a message, rows 1 to 56 and 58 to 100 are
-- committed, and the grid can show the clerk exactly which line to fix instead
-- of asking them to start again.
--
-- THE FEE STEPS HAVE THEIR OWN BLOCKS INSIDE THAT, and the reason is the same
-- one level down: a child must never be lost over a fee detail. If the month
-- cannot be billed because the class has no fee structure yet, the child is
-- still admitted and the row comes back with a warning. Getting the register in
-- is the job; the money can be corrected on a screen built for it.
create or replace function public.fn_rde_add_students(p jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_session uuid := nullif(p->>'session_id','')::uuid;
  v_class   uuid := nullif(p->>'class_id','')::uuid;
  v_section uuid := nullif(p->>'section_id','')::uuid;
  v_rows    jsonb := coalesce(p->'rows', '[]'::jsonb);
  v_row     jsonb;
  v_idx     int := 0;
  v_res     jsonb;
  v_out     jsonb := '[]'::jsonb;
  v_created int := 0;
  v_failed  int := 0;
  v_drafts  int := 0;
  v_student uuid;
  v_enroll  uuid;
  v_sib     uuid;
  v_payload jsonb;
  v_warn    text;
  v_disc    jsonb;
  v_disc_id uuid;
  v_month   date := public.fn__karachi_month();
  v_due     integer;
  v_inv     uuid;
  v_owed    numeric;
  v_arrears int;
begin
  if not public.has_role('owner','principal','admin_clerk') then
    raise exception 'Not permitted to admit students' using errcode = '42501';
  end if;
  if v_session is null then raise exception 'Pick a school year first.'; end if;
  if v_class   is null then raise exception 'Pick a class first.'; end if;
  if jsonb_typeof(v_rows) <> 'array' then raise exception 'rows must be a list'; end if;
  -- A CEILING, because this runs in one transaction and one browser must not be
  -- able to hold a write lock on the roster for a minute. The grid pages itself
  -- at this size; a class list longer than this is two saves, which is fine.
  if jsonb_array_length(v_rows) > 200 then
    raise exception 'Save at most 200 rows at a time. The grid does this for you.'
      using errcode = '54000';
  end if;
  perform public.assert_own('academic_sessions', v_session);
  perform public.assert_own('classes', v_class);
  perform public.assert_own('sections', v_section);

  select due_day into v_due from public.school_settings
   where school_id = public.current_school_id();

  for v_row in select * from jsonb_array_elements(v_rows) loop
    v_idx := v_idx + 1;
    v_warn := null;

    -- A blank line in the middle of a grid is not an error. A clerk who tabs
    -- past a row they meant to skip should not be told off for it.
    continue when nullif(btrim(coalesce(v_row->>'full_name','')), '') is null;

    begin  -- ---- the savepoint that protects every other row ----------------
      v_sib := nullif(v_row->>'sibling_student_id','')::uuid;

      v_payload := jsonb_build_object(
        'session_id',  v_session,
        'class_id',    v_class,
        'section_id',  v_section,
        'full_name',   v_row->>'full_name',
        'roll_no',     v_row->>'roll_no',
        'gr_no',       v_row->>'gr_no',
        'father_name', v_row->>'father_name',
        'mother_name', v_row->>'mother_name',
        'gender',      v_row->>'gender',
        'b_form',      v_row->>'b_form',
        'dob',         v_row->>'dob',
        'phone',       v_row->>'phone',
        'whatsapp',    v_row->>'whatsapp',
        'father_cnic', v_row->>'father_cnic',
        'admission_date', v_row->>'admission_date')
        -- THE SIBLING, AND THIS IS THE BILLING MERGE. fn_admit_student reads
        -- links[0] and puts the new child into that child's family, so from the
        -- next challan run the house receives ONE bill for both. Nothing else
        -- has to be done: every fee screen has been family-shaped since 0103.
        || case when v_sib is null then '{}'::jsonb
                else jsonb_build_object('links',
                       jsonb_build_array(jsonb_build_object(
                         'related_student_id', v_sib, 'relation', 'sibling')))
           end;

      v_res := public.fn_admit_student(v_payload);
      v_student := (v_res->>'student_id')::uuid;
      v_enroll  := (v_res->>'enrollment_id')::uuid;
      if (v_res->>'is_draft')::boolean then v_drafts := v_drafts + 1; end if;

      -- ---- the concession -------------------------------------------------
      v_disc := v_row->'discount';
      if v_disc is not null and jsonb_typeof(v_disc) = 'object'
         and coalesce(nullif(v_disc->>'amount','')::numeric, 0) > 0 then
        begin
          v_disc_id := public.fn_add_discount(
            v_student,
            coalesce(nullif(v_disc->>'type',''), 'sibling')::public.discount_type,
            (v_disc->>'amount')::numeric,
            coalesce((v_disc->>'is_percent')::boolean, false),
            nullif(v_disc->>'reason',''),
            v_month, null);
          perform public.fn_set_discount_status(v_disc_id, 'approved');
        exception when others then
          v_warn := coalesce(v_warn || ' ', '') || 'Discount not applied: ' || SQLERRM;
        end;
      end if;

      -- ---- months already owed -------------------------------------------
      begin
        v_arrears := public.fn__rde_arrears(v_enroll, v_row->'arrears');
      exception when others then
        v_arrears := 0;
        v_warn := coalesce(v_warn || ' ', '') || 'Arrears not recorded: ' || SQLERRM;
      end;

      -- ---- this month, and whether it has been paid ------------------------
      -- Billed either way. A child entered today is on this month's challan run
      -- like everybody else; the toggle only says whether the money is already
      -- in. Raising the challan here rather than waiting for the nightly pass
      -- is what lets the clerk take the fee at the counter the same morning.
      if coalesce((v_row->>'bill_this_month')::boolean, true) then
        begin
          v_inv := public.fn_bill_student_month(
                     v_enroll, v_month,
                     public.fn__day_in_month(v_month, coalesce(v_due, 10)));
          if coalesce((v_row->>'paid_this_month')::boolean, false) then
            select greatest(
                     coalesce((select sum(case when l.is_discount then -l.amount else l.amount end)
                                 from public.invoice_lines l where l.invoice_id = v_inv), 0)
                     - coalesce((select sum(a.amount) from public.payment_allocations a
                                  join public.payments pm on pm.id = a.payment_id
                                                         and pm.status = 'verified'
                                 where a.invoice_id = v_inv), 0), 0)
              into v_owed;
            if v_owed > 0 then
              perform public.fn_record_payment(v_student, v_owed, 'cash',
                'Fee for ' || to_char(v_month, 'Mon YYYY')
                || ' (already collected, entered at onboarding)', false);
            end if;
          end if;
        exception when others then
          v_warn := coalesce(v_warn || ' ', '') || 'This month not billed: ' || SQLERRM;
        end;
      end if;

      v_created := v_created + 1;
      v_out := v_out || jsonb_build_array(jsonb_build_object(
        'row', v_idx, 'status', case when v_warn is null then 'created' else 'partial' end,
        'student_id', v_student, 'gr_no', v_res->>'gr_no', 'roll_no', v_res->>'roll_no',
        'full_name', v_row->>'full_name', 'is_draft', (v_res->>'is_draft')::boolean,
        'arrears_months', coalesce(v_arrears, 0), 'message', v_warn));

    exception when others then
      -- The row is rolled back to the savepoint. Everything before it stands.
      v_failed := v_failed + 1;
      v_out := v_out || jsonb_build_array(jsonb_build_object(
        'row', v_idx, 'status', 'error', 'full_name', v_row->>'full_name',
        'message', SQLERRM));
    end;
  end loop;

  return jsonb_build_object(
    'created', v_created, 'failed', v_failed, 'drafts', v_drafts, 'results', v_out);
end;
$$;
revoke all on function public.fn_rde_add_students(jsonb) from public, anon;
grant execute on function public.fn_rde_add_students(jsonb) to authenticated;

-- ============================================ 7. the reminder, and what it is =
-- Counted, and broken down by what is actually missing, because "48 incomplete
-- records" is a nag and "48 with no date of birth" is a task somebody can
-- finish in one sitting with the register open.
create or replace function public.fn_draft_students(p_limit integer default 25)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_school uuid := public.current_school_id();
  v_n int; v_father int; v_gender int; v_dob int; v_contact int;
  v_rows jsonb;
begin
  if not public.may_view('owner','principal','class_teacher','subject_teacher','readonly') then
    raise exception 'Not permitted' using errcode = '42501';
  end if;

  select count(*),
         count(*) filter (where nullif(btrim(coalesce(s.father_name,'')),'') is null),
         count(*) filter (where s.gender is null),
         count(*) filter (where s.dob is null),
         count(*) filter (where nullif(btrim(coalesce(s.phone,'')),'') is null
                            and nullif(btrim(coalesce(s.whatsapp,'')),'') is null)
    into v_n, v_father, v_gender, v_dob, v_contact
    from public.students s
   where s.school_id = v_school and s.is_draft
     and s.deleted_at is null and s.status = 'active';

  -- p_limit 0 means "the counts only", which is what the dashboard banner wants.
  -- Without it that banner pays for a student row it never renders on every
  -- page load.
  if coalesce(p_limit, 25) <= 0 then
    return jsonb_build_object(
      'count', coalesce(v_n, 0),
      'missing_father', coalesce(v_father, 0),
      'missing_gender', coalesce(v_gender, 0),
      'missing_dob', coalesce(v_dob, 0),
      'missing_contact', coalesce(v_contact, 0),
      'students', '[]'::jsonb);
  end if;

  select coalesce(jsonb_agg(x order by x->>'full_name'), '[]'::jsonb) into v_rows
    from (
      select jsonb_build_object(
               'student_id', s.id, 'full_name', s.full_name, 'gr_no', s.gr_no,
               'class_name', c.name, 'section_name', sec.name,
               'missing', (case when nullif(btrim(coalesce(s.father_name,'')),'') is null
                                then jsonb_build_array('father''s name') else '[]'::jsonb end)
                       || (case when s.gender is null
                                then jsonb_build_array('gender') else '[]'::jsonb end)
                       || (case when s.dob is null
                                then jsonb_build_array('date of birth') else '[]'::jsonb end)
                       || (case when nullif(btrim(coalesce(s.phone,'')),'') is null
                                 and nullif(btrim(coalesce(s.whatsapp,'')),'') is null
                                then jsonb_build_array('a phone number') else '[]'::jsonb end)
             ) as x
        from public.students s
        left join public.enrollments e
          on e.student_id = s.id and e.status = 'active'
         and e.session_id = (select ss.current_session_id from public.school_settings ss
                              where ss.school_id = v_school)
        left join public.classes c on c.id = e.class_id
        left join public.sections sec on sec.id = e.section_id
       where s.school_id = v_school and s.is_draft
         and s.deleted_at is null and s.status = 'active'
       order by s.full_name
       limit coalesce(p_limit, 25)
    ) q;

  return jsonb_build_object(
    'count', coalesce(v_n, 0),
    'missing_father', coalesce(v_father, 0),
    'missing_gender', coalesce(v_gender, 0),
    'missing_dob', coalesce(v_dob, 0),
    'missing_contact', coalesce(v_contact, 0),
    'students', v_rows);
end;
$$;
revoke all on function public.fn_draft_students(integer) from public, anon;
grant execute on function public.fn_draft_students(integer) to authenticated;

-- ======================================== 8. the tag on the roster ============
-- A SEPARATE FUNCTION RATHER THAN A COLUMN ON fn_student_list, and the reason is
-- the one 0141 learned the hard way. fn_student_list returns a table, adding a
-- column to it needs a drop, and 0041 defines it inside bundle 4, which is
-- frozen and which verify.sql tells schools to re-run. Once a database carried
-- the wider shape, bundle 4 could never be applied again: `create or replace`
-- refuses a changed return type, a bundle is one transaction, and the whole
-- file would roll back.
--
-- So the roster asks for the ids separately and tags its own rows. On the
-- school this is built for that is a few hundred uuids on a screen somebody
-- opens to fix them, and it costs one index scan.
create or replace function public.fn_draft_student_ids()
returns setof uuid language sql stable security definer set search_path = public as $$
  select s.id from public.students s
   where s.school_id = public.current_school_id()
     and s.is_draft and s.deleted_at is null and s.status = 'active'
     and public.may_view('owner','principal','class_teacher','subject_teacher','readonly')
$$;
revoke all on function public.fn_draft_student_ids() from public, anon;
grant execute on function public.fn_draft_student_ids() to authenticated;

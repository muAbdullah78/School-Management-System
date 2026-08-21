-- =============================================================================
-- 0036 — Make families actually contain families.
--
-- THE BUG THIS FIXES
--
-- Migration 0029 built family-wide fee collection: one payment from a father
-- covers all his children, oldest invoice first, leftover held as family
-- credit. Every part of that worked in isolation and none of it worked in
-- production, because nothing ever put two children in the same family.
--
--   * fn_admit_student never set family_id.
--   * So trg_students_zz_family fired for every admission and created a
--     private, single-child family named "<Student Name> (family)".
--   * fn_family_for — the one function whose entire job is finding an EXISTING
--     family by the father's CNIC and reusing it — had zero callers. Not in the
--     app, not in SQL, not in the tests.
--   * The admission form collected no father CNIC at all, so even the search at
--     the fee counter (fn_find_family, which keys on families.head_cnic) had
--     nothing to match on.
--
-- The failure was invisible because the sibling relationship WAS being stored —
-- in student_links, which drives the "Siblings / family" panel on the student
-- profile. So the screen said the boys were brothers while the billing engine
-- had them in separate families. The admission form's own help text claimed the
-- checkbox "powers the family view and the sibling discount". It powered the
-- view only.
--
-- WHAT THIS MIGRATION DOES
--
--   1. Stops the bleeding: fn_admit_student now resolves a family before the
--      insert, so new admissions land in the right one.
--   2. Repairs history: existing students are merged into shared families using
--      the two signals already in the data — explicit sibling links first
--      (the school asserted these are siblings), then father name + phone.
--   3. Gives the counter a way out: fn_student_join_family lets a clerk fix a
--      wrongly-separated pair from the student profile, because no automatic
--      rule catches everything.
--
-- Merging is the safe direction. Two children wrongly in one family shows up
-- immediately at the counter — the clerk sees a child who is not theirs on the
-- family sheet. Two siblings wrongly apart is silent, which is why it survived
-- this long.
--
-- KNOWN LIMITATION, stated rather than discovered later: a family holds ONE
-- CNIC. Real families have more than one adult, and a school that records the
-- mother's CNIC for one child and the father's for another will get two
-- families. The first CNIC recorded wins and is never silently overwritten,
-- because the counter has been searching on it. The sibling checkbox at
-- admission and fn_student_join_family afterwards both cover the case; a proper
-- fix is a family_identifiers table, which is not worth the migration until a
-- real school hits it.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. One family per father, per school.
--
-- Without this, two clerks admitting two brothers on the same afternoon each
-- create a family with the same CNIC and we are back where we started. Partial
-- so that families with no CNIC recorded (the pre-0036 rows, and any admission
-- where the parent did not have their card on them) are unconstrained.
-- ---------------------------------------------------------------------------
create unique index if not exists uq_families_school_cnic
  on public.families (school_id, head_cnic)
  where head_cnic is not null;

-- ---------------------------------------------------------------------------
-- 2. Merge two families into one.
--
-- Four tables point at families and every one of them has to move, or the
-- delete at the end fails on a foreign key and the whole merge rolls back:
-- students, payments, profiles (a linked parent login) and message_outbox.
-- ---------------------------------------------------------------------------
create or replace function public.fn_merge_families(p_keep uuid, p_absorb uuid)
returns uuid language plpgsql security definer set search_path = public as $$
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
  update public.message_outbox set family_id = p_keep where family_id = p_absorb;

  delete from public.families where id = p_absorb;

  return p_keep;
end;
$$;

-- ---------------------------------------------------------------------------
-- 3. fn_family_for, hardened.
--
-- Two changes. The bare `select id into v_id` could match more than one row
-- once duplicates existed and would then pick an arbitrary one; it is now
-- ordered and limited. And a family created by the default trigger carries the
-- useless head_name "<Student> (family)" — when a real parent name arrives we
-- take it, so the fee counter shows "Muhammad Aslam" instead.
-- ---------------------------------------------------------------------------
create or replace function public.fn_family_for(
  p_head_name text, p_head_cnic text default null,
  p_phone text default null, p_whatsapp text default null
) returns uuid language plpgsql security definer set search_path = public as $$
declare
  v_id     uuid;
  v_school uuid := public.current_school_id();
  v_cnic   text := nullif(btrim(coalesce(p_head_cnic, '')), '');
  v_name   text := nullif(btrim(coalesce(p_head_name, '')), '');
begin
  if v_cnic is not null then
    select id into v_id from public.families
    where school_id = v_school and head_cnic = v_cnic
    order by created_at
    limit 1;

    if v_id is not null then
      update public.families set
        head_name = case
                      when v_name is not null and head_name like '% (family)' then v_name
                      else head_name
                    end,
        phone     = coalesce(nullif(btrim(coalesce(p_phone, '')), ''), phone),
        whatsapp  = coalesce(nullif(btrim(coalesce(p_whatsapp, '')), ''), whatsapp)
      where id = v_id;
      return v_id;
    end if;
  end if;

  insert into public.families (head_name, head_cnic, phone, whatsapp)
  values (coalesce(v_name, 'Family'),
          v_cnic,
          nullif(btrim(coalesce(p_phone, '')), ''),
          nullif(btrim(coalesce(p_whatsapp, '')), ''))
  returning id into v_id;
  return v_id;
end;
$$;

-- ---------------------------------------------------------------------------
-- 4. Admission resolves a family before it inserts the student.
--
-- Precedence, strongest signal first:
--
--   a. An explicit sibling link. The clerk ticked "has a sibling already in the
--      school" and picked the child by name — that is a human assertion and it
--      beats any string match. The new student joins that child's family.
--   b. The father's CNIC, via fn_family_for.
--   c. Nothing — fall through to trg_students_zz_family and get a private
--      family, exactly as before. A walk-in with no CNIC and no sibling is a
--      real case and must not be blocked at the counter.
--
-- When (a) and (b) both apply, (a) wins and the CNIC is stamped onto the
-- sibling's existing family so the next admission finds it by CNIC too.
-- ---------------------------------------------------------------------------
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
$$;

-- ---------------------------------------------------------------------------
-- 5. The repair path.
--
-- No automatic rule catches every case: a father with two phone numbers, a
-- stepfather, a name spelled two ways, an admission taken before this
-- migration existed. Without a way to fix it from the app the clerk's only
-- recourse is the SQL editor, which they do not have.
--
-- Returns the surviving family id so the caller can navigate to it.
-- ---------------------------------------------------------------------------
create or replace function public.fn_student_join_family(
  p_student_id uuid, p_sibling_student_id uuid
) returns uuid language plpgsql security definer set search_path = public as $$
declare v_mine uuid; v_theirs uuid;
begin
  if not public.has_role('owner', 'principal', 'admin_clerk') then
    raise exception 'Not permitted to change families';
  end if;
  if p_student_id is null or p_sibling_student_id is null then
    raise exception 'Both students are required';
  end if;
  if p_student_id = p_sibling_student_id then
    raise exception 'A student cannot join their own family';
  end if;

  perform public.assert_own('students', p_student_id);
  perform public.assert_own('students', p_sibling_student_id);

  select family_id into v_mine   from public.students where id = p_student_id;
  select family_id into v_theirs from public.students where id = p_sibling_student_id;

  if v_mine = v_theirs then
    return v_mine;                      -- already together, nothing to do
  end if;

  -- The sibling's family survives. It is the one whose head_name and CNIC the
  -- counter already recognises, and the one any linked parent login points at.
  return public.fn_merge_families(v_theirs, v_mine);
end;
$$;

-- ---------------------------------------------------------------------------
-- 6. Repair separated families.
--
-- This is a permanent, re-runnable function rather than a one-shot DO block,
-- for three reasons:
--
--   * CSV import recreates the problem. Bulk import goes through
--     fn_admit_student, but a spreadsheet from a paper register will not have a
--     father CNIC column, so imported siblings land apart exactly as before.
--   * A one-shot block cannot be tested. The bug this migration fixes survived
--     because supabase/tests/family_money.sql built its families by hand
--     instead of admitting students, so the real path was never exercised.
--   * Schools will want to run it after a bulk import, from Settings.
--
-- Split in two: the inner function does one school and is revoked from
-- everyone, the outer one is the guarded entry point scoped to the caller's own
-- school. That split matters — a single function keyed off
-- `current_school_id() is null` would hand a platform operator, whose school_id
-- IS null, a cross-tenant merge primitive.
-- ---------------------------------------------------------------------------
create or replace function public.fn__repair_families_for(p_school_id uuid)
returns integer language plpgsql security definer set search_path = public as $$
declare
  r        record;
  v_rounds int := 0;
  v_pass   int;
  v_merged int := 0;
begin
  if p_school_id is null then
    raise exception 'a school is required';
  end if;

  -- ---- pass A: explicit sibling links ----
  -- The school ticked a box and named the child. That is a human assertion, so
  -- it is applied unconditionally. Transitive by nature (A-B and B-C means all
  -- three are one family), so it loops until a pass changes nothing. Each round
  -- strictly reduces the number of distinct families, so it cannot spin; the
  -- 50-round bound is a backstop against a pathological chain, not a limit
  -- any real school will reach.
  loop
    v_rounds := v_rounds + 1;
    v_pass := 0;

    for r in
      select sa.family_id as keep, sb.family_id as absorb
      from public.student_links l
      join public.students sa on sa.id = l.related_student_id
      join public.students sb on sb.id = l.student_id
      where sa.family_id <> sb.family_id
        and sa.school_id = p_school_id
        and sb.school_id = p_school_id
    loop
      -- Re-read: an earlier merge in this same round may already have moved one
      -- of these two, leaving a stale id pointing at a deleted row.
      if r.keep <> r.absorb
         and exists (select 1 from public.families where id = r.keep)
         and exists (select 1 from public.families where id = r.absorb) then
        perform public.fn__merge_two_families(r.keep, r.absorb);
        v_pass := v_pass + 1;
      end if;
    end loop;

    v_merged := v_merged + v_pass;
    exit when v_pass = 0 or v_rounds >= 50;
  end loop;

  -- ---- pass B: same father name AND same phone ----
  -- Both are required. Father name alone is far too weak in Pakistan —
  -- "Muhammad Aslam" collides across unrelated families in any school of size.
  -- Together with a normalised phone number of at least seven digits it is a
  -- strong signal, and a false positive (one family sheet showing a child who
  -- is not theirs) is visible at the counter on the first collection, unlike
  -- the silent failure this migration exists to fix.
  for r in
    with keyed as (
      select s.id, s.family_id,
             lower(btrim(s.father_name)) as fname,
             regexp_replace(coalesce(nullif(s.phone, ''), s.whatsapp, ''), '[^0-9]', '', 'g') as digits
      from public.students s
      where s.school_id = p_school_id
        and s.deleted_at is null
        and nullif(btrim(coalesce(s.father_name, '')), '') is not null
    ),
    grouped as (
      select fname, digits,
             (array_agg(family_id order by id))[1] as keep,
             array_agg(distinct family_id)         as fams
      from keyed
      where length(digits) >= 7
      group by fname, digits
      having count(distinct family_id) > 1
    )
    select keep, unnest(fams) as absorb from grouped
  loop
    if r.keep <> r.absorb
       and exists (select 1 from public.families where id = r.keep)
       and exists (select 1 from public.families where id = r.absorb) then
      perform public.fn__merge_two_families(r.keep, r.absorb);
      v_merged := v_merged + 1;
    end if;
  end loop;

  -- ---- tidy: a family with several children is named after the parent ----
  -- Both passes leave the keeper's auto-generated "<Child> (family)" name in
  -- place, which reads wrong on a sheet listing three children.
  update public.families f
  set head_name = x.father_name
  from (
    select s.family_id, min(btrim(s.father_name)) as father_name
    from public.students s
    where s.school_id = p_school_id
      and s.deleted_at is null
      and nullif(btrim(coalesce(s.father_name, '')), '') is not null
    group by s.family_id
    having count(*) > 1
  ) x
  where f.id = x.family_id
    and f.head_name like '% (family)';

  return v_merged;
end;
$$;

-- The row-moving half, shared by the repair passes. Separate from
-- fn_merge_families because that one is a guarded, user-facing entry point and
-- this one has to run inside the migration where current_school_id() is null.
-- The same-school check is restated as a plain join for exactly that reason.
create or replace function public.fn__merge_two_families(p_keep uuid, p_absorb uuid)
returns void language plpgsql security definer set search_path = public as $$
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
  update public.message_outbox set family_id = p_keep where family_id = p_absorb;
  delete from public.families where id = p_absorb;
end;
$$;

-- The guarded entry point a school actually calls.
create or replace function public.fn_repair_families()
returns integer language plpgsql security definer set search_path = public as $$
begin
  if not public.has_role('owner', 'principal') then
    raise exception 'Only the owner or principal can repair families';
  end if;
  return public.fn__repair_families_for(public.current_school_id());
end;
$$;

-- Repair whatever is already in the database, school by school.
do $$
declare s uuid;
begin
  for s in select id from public.schools loop
    perform public.fn__repair_families_for(s);
  end loop;
end $$;

-- ---------------------------------------------------------------------------
-- 7. Grants.
--
-- fn_family_for gets a grant it already had; repeated here because 0036
-- replaced the body and the intent should be readable in one place.
-- ---------------------------------------------------------------------------
grant execute on function public.fn_merge_families(uuid, uuid)      to authenticated;
grant execute on function public.fn_student_join_family(uuid, uuid) to authenticated;
grant execute on function public.fn_repair_families()               to authenticated;
grant execute on function public.fn_family_for(text, text, text, text) to authenticated;

revoke all on function public.fn_merge_families(uuid, uuid)      from anon;
revoke all on function public.fn_student_join_family(uuid, uuid) from anon;
revoke all on function public.fn_repair_families()               from anon;

-- The two internals stay unreachable. fn__merge_two_families moves rows between
-- families with only a same-school check and no role check, and
-- fn__repair_families_for takes an arbitrary school id — either one exposed to a
-- signed-in user is a cross-tenant write. 0001 grants EXECUTE on new functions
-- to authenticated by default privileges, so these revokes are load-bearing,
-- not decoration.
revoke all on function public.fn__merge_two_families(uuid, uuid)  from public, anon, authenticated;
revoke all on function public.fn__repair_families_for(uuid)       from public, anon, authenticated;

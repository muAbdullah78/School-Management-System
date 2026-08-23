-- =============================================================================
-- REPAIR — migrations 0035 to 0049.
--
-- FOR: a school that installed before those migrations existed, whose bundle 3
-- was a two-file bundle at the time. Run it ONCE.
--
-- WHY IT IS NEEDED. Bundle 3's glob was 003[3-9]*. When it first shipped it
-- matched {0033, 0034}. Migrations 0035-0039 were written later and the same
-- glob swallowed them, so the file already pasted changed underneath the school.
-- Re-running it fails on 0033's "column family_id already exists" and — because
-- the SQL Editor runs a paste as ONE transaction — rolls back entirely, so
-- 0035-0039 never arrive. Bundle 4 cannot apply either: it needs
-- fee_structures.effective_from, which 0035 adds.
--
-- WHY IT LIVES HERE AND NOT IN supabase/bundles/. build-bundles.sh begins with
-- `rm -f supabase/bundles/*.sql` to clear stale generated files, and it deleted
-- the first version of this file between verifying it and committing it. A
-- hand-written artefact must not sit in a directory something else empties.
--
-- AFTER THIS, RE-RUN 5_search.sql. Not optional: migrations 0050-0056 replace
-- some of the functions below with newer versions, so applying 0035-0049 now
-- puts the OLD versions back until bundle 5 restores them. Then run verify.sql.
--
-- Safe with live data: tested against a database holding a school and pupils
-- created through fn_admit_student on the 0034-era schema.
-- =============================================================================


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

-- ─────────────────────────────────────────────────────────────────────────
-- 0036_family_linkage.sql
-- ─────────────────────────────────────────────────────────────────────────
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

-- ─────────────────────────────────────────────────────────────────────────
-- 0037_parent_access.sql
-- ─────────────────────────────────────────────────────────────────────────
-- =============================================================================
-- 0037 — Make the parent portal reachable.
--
-- THE BUG THIS FIXES
--
-- Migration 0033 built the whole parent portal: fn_portal_me, child fee
-- history, attendance, results, an enumeration-proof child guard, and a
-- published_at gate on result cards. Fourteen tests cover it. Not one line of
-- it could ever run, because there was no way to tell the system which family a
-- parent belongs to.
--
--   * fn_link_parent is the ONLY code in the repo that writes
--     profiles.family_id — and it had zero callers. No wrapper in the app, no
--     screen, no other SQL function.
--   * handle_new_user writes id, full_name, role and school_id. Not family_id.
--   * So my_family_id() returned null for every parent account, which made
--     fn__assert_my_child raise 'Not a parent account', which made
--     fn_portal_child_fees / _attendance / _results all throw. fn_portal_me
--     returned an empty child list.
--
-- A parent login created through the app landed in a portal that was either
-- empty or erroring, every time, with no way to fix it from inside the product.
--
-- Worse, the login could not be created in the first place: the create-teacher
-- Edge Function validates the requested role against an allow-list that did not
-- include 'parent', so asking for one came back "Invalid role".
--
-- WHAT THIS ADDS
--
--   1. fn_family_parents  — who can already see this family's portal. Needed
--      before creating anything, or a school ends up with four logins for one
--      father and no idea which one he actually uses.
--   2. fn_unlink_parent   — revoke access. A guardian changes, a couple
--      separates, a phone is lost. Without this, granting access is
--      irreversible, which makes it something a school is right to be afraid
--      of.
--
--   3. Enforcement of profiles.active, which nothing read — so the
--      "Deactivate" button in Settings was decorative and a dismissed clerk
--      kept every permission. Found while writing the revoke above.
--   4. A guard so enforcing that cannot let a school lock itself out by
--      deactivating its last owner.
--
-- fn_link_parent itself is unchanged and was always correct. The gap was
-- everything around it.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. Who can see this family's portal?
--
-- The email lives in auth.users, which the app cannot read directly — so this
-- is SECURITY DEFINER and joins on the caller's behalf. That makes the guards
-- load-bearing rather than decorative:
--
--   * is_staff() — a parent must never be able to enumerate other logins,
--     including the other logins on their own family.
--   * assert_own('families') — without it, passing an arbitrary family id would
--     read another school's parent emails out of auth.users. This function is
--     the only place in the schema that reads auth.users on request, so it is
--     the one place that check absolutely cannot be skipped.
-- ---------------------------------------------------------------------------
create or replace function public.fn_family_parents(p_family_id uuid)
returns table (profile_id uuid, full_name text, email text, active boolean)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_staff() then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  perform public.assert_own('families', p_family_id);

  return query
  select p.id, p.full_name, u.email::text, p.active
  from public.profiles p
  join auth.users u on u.id = p.id
  where p.family_id = p_family_id
    and p.role = 'parent'
    and p.school_id = public.current_school_id()
  order by p.full_name;
end;
$$;

-- ---------------------------------------------------------------------------
-- 2. Revoke a parent's access.
--
-- Deliberately NOT a delete. Deleting the auth user needs the service key and
-- would also erase the record that this person once had access, which is
-- exactly the thing a school wants to be able to show later. Detaching the
-- family is what cuts the data off: my_family_id() goes null and every portal
-- read refuses.
--
-- active=false is set as well, and section 3 below is what makes that mean
-- anything — until this migration it did not.
-- ---------------------------------------------------------------------------
create or replace function public.fn_unlink_parent(p_profile_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.has_role('owner', 'principal') then
    raise exception 'Only the owner or principal may remove portal access';
  end if;
  perform public.assert_own('profiles', p_profile_id);

  if (select role from public.profiles where id = p_profile_id) <> 'parent' then
    raise exception 'That account is not a parent account';
  end if;

  update public.profiles
     set family_id = null, active = false
   where id = p_profile_id;
end;
$$;

-- ---------------------------------------------------------------------------
-- 3. Make "Deactivate" actually deactivate.
--
-- A SEPARATE BUG, found while writing the revoke above.
--
-- profiles.active is written by Settings -> Users & Roles ("Deactivate") and is
-- read by NOTHING. Not by current_school_id(), not by has_role(), not by
-- is_staff(), not by a single RLS policy. The button has always been
-- decorative: a school that dismisses a clerk, clicks Deactivate and believes
-- access is cut is wrong — that clerk keeps every permission they had,
-- including the fee counter, until the login is deleted in Supabase by hand.
--
-- Fixed at the two chokepoints every other check already flows through, so
-- nothing else has to be touched:
--
--   * current_school_id() returns NULL for an inactive profile. Every RLS
--     policy in the schema is `school_id = public.current_school_id()`, and
--     assert_own() is built on it, so a null there closes all of them at once.
--   * has_role() and is_staff() return false. Belt and braces: these are the
--     role guards inside the SECURITY DEFINER functions, which do not all go
--     through RLS.
--
-- Enforcing this creates a new way to break a school: an owner deactivating
-- themselves, or the last owner, would lock everyone out of the school with no
-- route back in except the SQL editor. Section 4 refuses that.
-- ---------------------------------------------------------------------------
create or replace function public.current_school_id() returns uuid
language sql stable security definer set search_path = public as $$
  select school_id from public.profiles where id = auth.uid() and active;
$$;

create or replace function public.has_role(variadic roles public.user_role[]) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.profiles p
    where p.id = auth.uid() and p.active and p.role = any(roles)
  );
$$;

create or replace function public.is_staff() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(
    (select p.active and p.role <> 'parent' from public.profiles p where p.id = auth.uid()),
    false);
$$;

-- ---------------------------------------------------------------------------
-- 4. Do not let a school lock itself out.
--
-- With section 3 live, deactivating the last active owner would leave nobody
-- who can reactivate anyone — has_role('owner') would be false for everybody.
-- A BEFORE UPDATE trigger is the right place: it catches the Settings screen,
-- a stray SQL update, and anything added later, rather than trusting each
-- caller to remember.
-- ---------------------------------------------------------------------------
create or replace function public.guard_last_owner_active() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if old.active and not new.active and old.role = 'owner' then
    if not exists (
      select 1 from public.profiles p
      where p.school_id = old.school_id
        and p.role = 'owner'
        and p.active
        and p.id <> old.id
    ) then
      raise exception 'This is the school''s only active owner — make someone else an owner first';
    end if;
  end if;

  -- Changing the last active owner's ROLE has exactly the same effect.
  if old.active and new.active and old.role = 'owner' and new.role <> 'owner' then
    if not exists (
      select 1 from public.profiles p
      where p.school_id = old.school_id
        and p.role = 'owner'
        and p.active
        and p.id <> old.id
    ) then
      raise exception 'This is the school''s only active owner — make someone else an owner first';
    end if;
  end if;

  return new;
end;
$$;

drop trigger if exists trg_profiles_last_owner on public.profiles;
create trigger trg_profiles_last_owner
  before update on public.profiles
  for each row execute function public.guard_last_owner_active();

-- ---------------------------------------------------------------------------
-- 5. Grants.
--
-- fn_family_parents is granted to authenticated but gated on is_staff()
-- INSIDE the function, so a signed-in parent calling it directly gets 42501.
-- ---------------------------------------------------------------------------
grant execute on function public.fn_family_parents(uuid) to authenticated;
grant execute on function public.fn_unlink_parent(uuid)  to authenticated;

revoke all on function public.fn_family_parents(uuid) from anon;
revoke all on function public.fn_unlink_parent(uuid)  from anon;

-- ─────────────────────────────────────────────────────────────────────────
-- 0038_counter.sql
-- ─────────────────────────────────────────────────────────────────────────
-- =============================================================================
-- 0038 — The fee counter: open on today's work, not on an empty box.
--
-- WHY
--
-- OurSchoolSoftware's Fee Payment screen — their busiest, the one a clerk sits
-- on all morning during the first ten days of a month — opens showing:
--
--   * four figures: unpaid invoices, income today, expense today, balance today
--   * TWO search boxes side by side: by student name/code (or by scanning the
--     fee slip), and by the father's CNIC to pull up every connected child
--   * the day's payments, already listed, without searching for anything
--
-- Ours opens as a single empty text input. Nothing is on screen until the clerk
-- types, and there is no way to see what has been collected today without
-- leaving for a report. That is the difference between a counter and a lookup
-- form, and it is the single most-used screen in the product.
--
-- This migration adds the two reads that screen needs. No new tables: every
-- figure is derived, so none of it can drift from the ledger.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. The four tiles.
--
-- Deliberately one round trip rather than four. The clerk reloads this screen
-- constantly and each figure is a cheap aggregate; four separate calls would
-- mean four sets of latency to Mumbai for numbers that must agree with each
-- other anyway.
--
-- "Unpaid invoices" counts CHALLANS still owing, not students — that is the
-- figure their screen shows and it is the one a clerk is asked for ("how many
-- challans are still out?"). It is not the same as the defaulter count, and
-- conflating them is how a dashboard ends up lying.
-- ---------------------------------------------------------------------------
create or replace function public.fn_counter_summary()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_school   uuid := public.current_school_id();
  v_unpaid   integer;
  v_income   numeric;
  v_expense  numeric;
  v_pending  integer;
  v_pending_amt numeric;
begin
  if not public.is_staff() then
    raise exception 'Not permitted' using errcode = '42501';
  end if;

  -- An invoice is "unpaid" when what it charges exceeds what has been allocated
  -- to it from VERIFIED payments. Derived rather than read off invoices.status,
  -- because status is a label and this is the money.
  select count(*) into v_unpaid
  from public.invoices i
  where i.school_id = v_school
    and i.status <> 'void'
    and (
      coalesce((select sum(case when l.is_discount then -l.amount else l.amount end)
                  from public.invoice_lines l where l.invoice_id = i.id), 0)
      + coalesce(i.fine, 0)
      - coalesce((select sum(al.amount)
                    from public.payment_allocations al
                    join public.payments p on p.id = al.payment_id
                   where al.invoice_id = i.id and p.status = 'verified'), 0)
    ) > 0;

  select coalesce(sum(p.amount), 0) into v_income
  from public.payments p
  where p.school_id = v_school
    and p.status = 'verified'
    and p.created_at >= date_trunc('day', now())
    and p.created_at <  date_trunc('day', now()) + interval '1 day';

  select coalesce(sum(e.amount), 0) into v_expense
  from public.expenses e
  where e.school_id = v_school
    and e.spent_on = current_date
    and e.reversal_of is null;

  -- Money taken but not yet cleared. Shown next to the day's income because a
  -- clerk who has accepted three bank transfers needs to know they are not in
  -- that income figure — otherwise the drawer looks short at closing.
  select count(*), coalesce(sum(p.amount), 0) into v_pending, v_pending_amt
  from public.payments p
  where p.school_id = v_school and p.status = 'pending';

  return jsonb_build_object(
    'unpaid_invoices', v_unpaid,
    'income_today',    v_income,
    'expense_today',   v_expense,
    'balance_today',   v_income - v_expense,
    'pending_count',   v_pending,
    'pending_amount',  v_pending_amt);
end;
$$;

-- ---------------------------------------------------------------------------
-- 2. Latest payments — the list that makes the screen useful on open.
--
-- Columns chosen to match theirs: student, parent, class, what it paid for,
-- amount, late fee, discount, note, and WHO took the money. That last one is
-- what makes the list a control rather than a convenience — a clerk can see
-- their own receipts, and an owner can see whose counter the cash came over.
--
-- A caveat that belongs in the schema rather than only in the UI: late_fee and
-- discount are the totals on the CHALLANS this receipt was allocated to, not a
-- share apportioned to this payment. Two part-payments against one challan will
-- each report that challan's full fine. The alternative — apportioning — would
-- invent a number that appears nowhere in the ledger, which is worse. The
-- column names and the UI heading both say "on the challans this paid".
-- ---------------------------------------------------------------------------
create or replace function public.fn_recent_payments(p_limit integer default 25)
returns table (
  payment_id     uuid,
  receipt_no     bigint,
  paid_at        timestamptz,
  student_id     uuid,
  student_name   text,
  gr_no          text,
  family_id      uuid,
  parent_name    text,
  class_name     text,
  section_name   text,
  paid_for       text,
  amount         numeric,
  method         public.payment_method,
  late_fee       numeric,
  discount       numeric,
  note           text,
  status         text,
  received_by    text,
  is_reversal    boolean
) language plpgsql stable security definer set search_path = public as $$
declare v_school uuid := public.current_school_id();
begin
  if not public.is_staff() then
    raise exception 'Not permitted' using errcode = '42501';
  end if;

  return query
  select
    p.id,
    p.receipt_no,
    p.created_at,
    eff.sid,
    -- A family payment has NO payments.student_id: the money came from the
    -- father, not from a child. Falling back to the allocations is what makes
    -- this column non-empty for exactly the payments the family feature
    -- creates, and it names every child the receipt actually covered — which is
    -- what the clerk needs to say out loud at the window.
    coalesce(s.full_name, alloc.names, '—'),
    s.gr_no,
    p.family_id,
    f.head_name,
    c.name,
    sec.name,
    (select string_agg(distinct
              coalesce(to_char(i.period_month, 'Mon YYYY'), coalesce(i.notes, 'Other')),
              ', ' order by coalesce(to_char(i.period_month, 'Mon YYYY'), coalesce(i.notes, 'Other')))
       from public.payment_allocations al
       join public.invoices i on i.id = al.invoice_id
      where al.payment_id = p.id),
    p.amount,
    p.method,
    coalesce((select sum(d.fine)
                from (select distinct i2.id, i2.fine
                        from public.payment_allocations al2
                        join public.invoices i2 on i2.id = al2.invoice_id
                       where al2.payment_id = p.id) d), 0),
    coalesce((select sum(l.amount)
                from public.payment_allocations al3
                join public.invoice_lines l on l.invoice_id = al3.invoice_id
               where al3.payment_id = p.id and l.is_discount), 0),
    p.note,
    p.status::text,
    coalesce(pr.full_name, '—'),
    p.reversal_of is not null
  from public.payments p
  -- Which children this receipt settled anything for.
  left join lateral (
    select string_agg(distinct s2.full_name, ', ' order by s2.full_name) as names,
           count(distinct s2.id)                                        as n,
           (array_agg(distinct s2.id))[1]                               as only_id
      from public.payment_allocations al4
      join public.invoices i4  on i4.id = al4.invoice_id
      join public.students s2  on s2.id = i4.student_id
     where al4.payment_id = p.id
  ) alloc on true
  -- The one student this payment is ABOUT, if there is exactly one. A family
  -- payment spread across three siblings has no single class, and showing one
  -- of the three would be worse than showing none.
  left join lateral (
    select coalesce(p.student_id,
                    case when alloc.n = 1 then alloc.only_id end) as sid
  ) eff on true
  left join public.students   s   on s.id = eff.sid
  left join public.families    f  on f.id = p.family_id
  left join public.enrollments e  on e.student_id = eff.sid and e.status = 'active'
  left join public.classes     c  on c.id = e.class_id
  left join public.sections    sec on sec.id = e.section_id
  left join public.profiles    pr on pr.id = p.received_by
  where p.school_id = v_school
  order by p.created_at desc
  limit greatest(1, least(coalesce(p_limit, 25), 200));
end;
$$;

-- ---------------------------------------------------------------------------
-- 3. Grants.
--
-- Both are staff-gated inside the function bodies, so a signed-in parent
-- calling either directly gets 42501 rather than a school's cash position.
-- ---------------------------------------------------------------------------
grant execute on function public.fn_counter_summary()          to authenticated;
grant execute on function public.fn_recent_payments(integer)   to authenticated;

revoke all on function public.fn_counter_summary()        from anon;
revoke all on function public.fn_recent_payments(integer) from anon;

-- ─────────────────────────────────────────────────────────────────────────
-- 0039_challan.sql
-- ─────────────────────────────────────────────────────────────────────────
-- =============================================================================
-- 0039 — The printed fee challan.
--
-- WHY THIS DID NOT EXIST, AND WHY THAT WAS THE WORST GAP IN THE PRODUCT
--
-- In a Pakistani school the challan IS the product. The parent is handed a
-- slip, takes it to the bank, the bank stamps it, one copy comes back to the
-- school. Everything else the software does hangs off that piece of paper.
--
-- We shipped none of it:
--
--   * fn_generate_class_invoices bulk-bills a class and returns a COUNT. It
--     returns no invoice ids and links to no print view.
--   * No function anywhere lists a class's invoices for a month, so there was
--     nothing to print even if a screen had existed.
--   * invoices.voucher_code is stamped by a trigger on every insert and is
--     never selected or rendered anywhere — so the scannable code existed in
--     the database and on no piece of paper.
--   * docs/03-FEATURES.md line 25 promises "monthly challan generation in
--     bank-payable 3-part format". Grep for 3-part, counterfoil, bank copy:
--     nothing. And docs/STATUS.md's "Known gaps, stated plainly" did not
--     mention it, so the documentation claimed a feature AND hid its absence.
--
-- The only fee printable in the whole product was a single-student receipt,
-- issued after payment — the opposite end of the transaction.
--
-- WHAT THE NUMBERS ON THE SLIP MEAN
--
-- invoices.arrears_brought_forward is a DISPLAY SNAPSHOT of the student's
-- balance at the moment the challan was generated (0002 says so explicitly). It
-- is deliberately NOT part of the ledger — student_balance() ignores it,
-- because the earlier unpaid invoices already carry that money.
--
-- Printing that snapshot would be wrong: a parent who paid last month's dues
-- on the 3rd would still be handed a slip demanding them on the 5th. So this
-- computes previous dues LIVE:
--
--      this_month     = this invoice's lines + its fine
--      already_paid   = verified allocations against this invoice
--      this_month_due = this_month - already_paid
--      total_payable  = student_balance(student)        -- live, everything
--      previous_dues  = total_payable - this_month_due
--
-- which makes total_payable exactly what the parent owes today, and makes the
-- two halves add up to it. The snapshot is returned as well, under a name that
-- says what it is, so a reprint can be compared against the original.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. One challan.
--
-- Returns everything the paper needs in a single object so the print view does
-- no arithmetic. Print views that compute totals are how a slip ends up
-- disagreeing with the ledger.
-- ---------------------------------------------------------------------------
create or replace function public.fn_challan(p_invoice_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_inv     record;
  v_lines   jsonb;
  v_charge  numeric;
  v_paid    numeric;
  v_this    numeric;
  v_total   numeric;
begin
  if not public.is_staff() then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  perform public.assert_own('invoices', p_invoice_id);

  select i.id, i.student_id, i.period_month, i.due_date, i.fine, i.voucher_code,
         i.arrears_brought_forward, i.status, i.notes,
         s.full_name, s.gr_no, s.father_name, s.phone, s.whatsapp,
         f.head_name as family_head, f.head_cnic as family_cnic,
         c.name as class_name, sec.name as section_name, e.roll_no
    into v_inv
  from public.invoices i
  join public.students s   on s.id = i.student_id
  left join public.families f on f.id = s.family_id
  left join public.enrollments e on e.id = i.enrollment_id
  left join public.classes c   on c.id = e.class_id
  left join public.sections sec on sec.id = e.section_id
  where i.id = p_invoice_id;

  if not found then
    raise exception 'No such challan' using errcode = '42704';
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'description', l.description,
           'amount',      l.amount,
           'is_discount', l.is_discount) order by l.is_discount, l.description), '[]'::jsonb)
    into v_lines
  from public.invoice_lines l where l.invoice_id = p_invoice_id;

  select coalesce(sum(case when l.is_discount then -l.amount else l.amount end), 0)
    into v_charge
  from public.invoice_lines l where l.invoice_id = p_invoice_id;
  v_charge := v_charge + coalesce(v_inv.fine, 0);

  select coalesce(sum(al.amount), 0) into v_paid
  from public.payment_allocations al
  join public.payments p on p.id = al.payment_id
  where al.invoice_id = p_invoice_id and p.status = 'verified';

  v_this  := v_charge - v_paid;
  v_total := public.student_balance(v_inv.student_id);

  return jsonb_build_object(
    'invoice_id',     v_inv.id,
    'voucher_code',   v_inv.voucher_code,
    'status',         v_inv.status,
    'period_month',   v_inv.period_month,
    'period_label',   coalesce(to_char(v_inv.period_month, 'FMMonth YYYY'),
                               coalesce(v_inv.notes, 'One-off charge')),
    'due_date',       v_inv.due_date,
    'student_id',     v_inv.student_id,
    'student_name',   v_inv.full_name,
    'gr_no',          v_inv.gr_no,
    'roll_no',        v_inv.roll_no,
    'father_name',    v_inv.father_name,
    'family_head',    v_inv.family_head,
    'family_cnic',    v_inv.family_cnic,
    'phone',          coalesce(v_inv.whatsapp, v_inv.phone),
    'class_name',     v_inv.class_name,
    'section_name',   v_inv.section_name,
    'lines',          v_lines,
    'fine',           coalesce(v_inv.fine, 0),
    'this_month',     v_charge,
    'already_paid',   v_paid,
    'this_month_due', v_this,
    -- Live, so a parent who has paid since generation is not asked twice.
    'previous_dues',  v_total - v_this,
    'total_payable',  v_total,
    -- The stale figure, named as such, for comparing a reprint with the original.
    'arrears_snapshot_at_generation', v_inv.arrears_brought_forward);
end;
$$;

-- ---------------------------------------------------------------------------
-- 2. A whole class's challans, for the batch print.
--
-- p_section_id null means every section of the class — the common case, since a
-- clerk prints "Class 5" and hands the stack to the class teacher to give out.
--
-- Voided invoices are excluded: a challan that was cancelled must not come out
-- of the printer, and a clerk who is handed one will collect against it.
--
-- Ordered by roll number the way a class register is, so the printed stack can
-- be handed out down the row without sorting. Roll numbers are text in this
-- schema and "10" sorts before "2" as text, so it is cast for the sort only.
-- ---------------------------------------------------------------------------
create or replace function public.fn_challans_for_class(
  p_session_id uuid,
  p_class_id   uuid,
  p_section_id uuid,
  p_period_month date
) returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_out jsonb;
begin
  if not public.is_staff() then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  perform public.assert_own('academic_sessions', p_session_id);
  perform public.assert_own('classes', p_class_id);
  perform public.assert_own('sections', p_section_id);

  select coalesce(jsonb_agg(public.fn_challan(x.id) order by x.sort_roll, x.full_name), '[]'::jsonb)
    into v_out
  from (
    select i.id,
           s.full_name,
           coalesce(nullif(regexp_replace(coalesce(e.roll_no, ''), '[^0-9]', '', 'g'), '')::int, 999999)
             as sort_roll
    from public.invoices i
    join public.enrollments e on e.id = i.enrollment_id
    join public.students s    on s.id = i.student_id
    where i.school_id = public.current_school_id()
      and i.session_id = p_session_id
      and e.class_id = p_class_id
      and (p_section_id is null or e.section_id = p_section_id)
      and i.period_month = p_period_month
      and i.status <> 'void'
      and s.deleted_at is null
  ) x;

  return v_out;
end;
$$;

-- ---------------------------------------------------------------------------
-- 3. Which months have challans, so the print screen can offer real choices.
--
-- Without this the clerk picks a month from a date input and finds out whether
-- anything was generated for it only after pressing Print. Offering the months
-- that exist, with a count, is the difference between a screen that works and
-- one that guesses.
-- ---------------------------------------------------------------------------
create or replace function public.fn_challan_months(p_session_id uuid, p_class_id uuid)
returns table (period_month date, challans integer, unpaid integer)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_staff() then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  perform public.assert_own('academic_sessions', p_session_id);
  perform public.assert_own('classes', p_class_id);

  return query
  select i.period_month,
         count(*)::int,
         count(*) filter (where (
           coalesce((select sum(case when l.is_discount then -l.amount else l.amount end)
                       from public.invoice_lines l where l.invoice_id = i.id), 0)
           + coalesce(i.fine, 0)
           - coalesce((select sum(al.amount)
                         from public.payment_allocations al
                         join public.payments p on p.id = al.payment_id
                        where al.invoice_id = i.id and p.status = 'verified'), 0)
         ) > 0)::int
  from public.invoices i
  join public.enrollments e on e.id = i.enrollment_id
  where i.school_id = public.current_school_id()
    and i.session_id = p_session_id
    and e.class_id = p_class_id
    and i.period_month is not null
    and i.status <> 'void'
  group by i.period_month
  order by i.period_month desc;
end;
$$;

-- ---------------------------------------------------------------------------
-- 4. Grants. All three are staff-gated in the body, so a parent calling them
-- directly gets 42501 rather than a class's fee data.
-- ---------------------------------------------------------------------------
grant execute on function public.fn_challan(uuid)                             to authenticated;
grant execute on function public.fn_challans_for_class(uuid, uuid, uuid, date) to authenticated;
grant execute on function public.fn_challan_months(uuid, uuid)                to authenticated;

revoke all on function public.fn_challan(uuid)                             from anon;
revoke all on function public.fn_challans_for_class(uuid, uuid, uuid, date) from anon;
revoke all on function public.fn_challan_months(uuid, uuid)                from anon;

-- ─────────────────────────────────────────────────────────────────────────
-- 0040_bulk_fees.sql
-- ─────────────────────────────────────────────────────────────────────────
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

-- ─────────────────────────────────────────────────────────────────────────
-- 0041_student_list.sql
-- ─────────────────────────────────────────────────────────────────────────
-- =============================================================================
-- 0041 — A student list that can hold a real school.
--
-- WHAT WAS WRONG
--
-- listStudents() hard-coded `.limit(50)` with no count and no "showing 50 of
-- N". An 800-student school saw the first fifty names alphabetically and was
-- never told the other 750 existed. Silent truncation on the flagship list of
-- the product.
--
-- It was not even a table: a <ul> of buttons showing name, father's name and GR
-- number. No class, no section, no roll number, and no BALANCE — on a product
-- whose entire purpose is students and money.
--
-- WHY THIS IS SQL AND NOT A BIGGER LIMIT
--
-- Adding a balance column is what forces this into the database. Calling
-- student_balance() once per row from the client would be 800 round trips, and
-- calling it 800 times inside one query is 800 correlated subqueries. This
-- computes charges and payments set-based, aggregated once, then joins — so the
-- cost is the same whether the class has 20 students or 2,000.
--
-- The exact total comes back with the page, because "showing 50 of 812" is the
-- difference between a list a school trusts and one that quietly lies.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. One page of students, with everything a school actually looks for.
--
-- Filters are all optional and compose: a text term (name, GR, admission no,
-- father's name), a class, a section, and whether to include struck-off
-- students. That last one matters — a struck-off child still has a balance and
-- a school still needs to find them, but they must not clutter the daily list.
-- ---------------------------------------------------------------------------
create or replace function public.fn_student_list(
  p_term      text default null,
  p_class_id  uuid default null,
  p_section_id uuid default null,
  p_include_inactive boolean default false,
  p_limit     integer default 50,
  p_offset    integer default 0
) returns table (
  student_id   uuid,
  full_name    text,
  gr_no        text,
  admission_no text,
  father_name  text,
  gender       text,
  phone        text,
  status       text,
  class_name   text,
  section_name text,
  roll_no      text,
  family_id    uuid,
  balance      numeric,
  total_count  bigint
) language plpgsql stable security definer set search_path = public as $$
declare
  v_school uuid := public.current_school_id();
  v_term   text := nullif(btrim(coalesce(p_term, '')), '');
  v_like   text;
  v_limit  int  := greatest(1, least(coalesce(p_limit, 50), 500));
  v_offset int  := greatest(0, coalesce(p_offset, 0));
begin
  if not public.is_staff() then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  perform public.assert_own('classes', p_class_id);
  perform public.assert_own('sections', p_section_id);

  -- ESCAPE the LIKE metacharacters rather than stripping them.
  --
  -- A first version replaced %, _ and backslash with a SPACE, which quietly
  -- widened every search: typing a single "%" became the pattern '% %', which
  -- matches any name containing a space — i.e. the entire school. Escaping
  -- makes them match literally, so "%" finds the students whose name actually
  -- contains a percent sign, which is none of them.
  --
  -- Backslash first, or the escapes added afterwards get escaped in turn.
  v_like := case when v_term is null then null
                 else '%' ||
                      replace(replace(replace(v_term, '\\', '\\\\'), '%', '\\%'), '_', '\\_')
                      || '%' end;

  return query
  with base as (
    select s.id, s.full_name, s.gr_no, s.admission_no, s.father_name,
           s.gender::text as gender,
           coalesce(nullif(s.whatsapp, ''), s.phone) as phone,
           s.status::text as status, s.family_id,
           c.name as class_name, sec.name as section_name, e.roll_no
    from public.students s
    left join public.enrollments e
      on e.student_id = s.id and e.status = 'active'
    left join public.classes c   on c.id = e.class_id
    left join public.sections sec on sec.id = e.section_id
    where s.school_id = v_school
      and s.deleted_at is null
      and (p_include_inactive or s.status = 'active')
      and (p_class_id is null or e.class_id = p_class_id)
      and (p_section_id is null or e.section_id = p_section_id)
      and (v_like is null
           or s.full_name    ilike v_like
           or s.gr_no        ilike v_like
           or s.admission_no ilike v_like
           or s.father_name  ilike v_like)
  ),
  -- Charges and payments aggregated ONCE over the whole filtered set, rather
  -- than student_balance() called per row. Same arithmetic as student_balance:
  -- lines (discounts negative) + fines + adjustments − verified allocations.
  charges as (
    select i.student_id,
           sum(case when l.is_discount then -l.amount else l.amount end) as amt
    from public.invoices i
    join public.invoice_lines l on l.invoice_id = i.id
    where i.student_id in (select id from base) and i.status <> 'void'
    group by i.student_id
  ),
  fines as (
    select i.student_id, sum(coalesce(i.fine, 0)) as amt
    from public.invoices i
    where i.student_id in (select id from base) and i.status <> 'void'
    group by i.student_id
  ),
  adjust as (
    select a.student_id, sum(a.amount) as amt
    from public.adjustments a
    where a.student_id in (select id from base)
    group by a.student_id
  ),
  paid as (
    select i.student_id, sum(al.amount) as amt
    from public.payment_allocations al
    join public.invoices i on i.id = al.invoice_id
    join public.payments p on p.id = al.payment_id
    where i.student_id in (select id from base) and p.status = 'verified'
    group by i.student_id
  ),
  counted as (select count(*) as n from base)
  select
    b.id, b.full_name, b.gr_no, b.admission_no, b.father_name, b.gender,
    b.phone, b.status, b.class_name, b.section_name, b.roll_no, b.family_id,
    coalesce(ch.amt, 0) + coalesce(fi.amt, 0) + coalesce(ad.amt, 0) - coalesce(pa.amt, 0),
    counted.n
  from base b
  cross join counted
  left join charges ch on ch.student_id = b.id
  left join fines   fi on fi.student_id = b.id
  left join adjust  ad on ad.student_id = b.id
  left join paid    pa on pa.student_id = b.id
  order by b.full_name, b.id
  limit v_limit offset v_offset;
end;
$$;

-- ---------------------------------------------------------------------------
-- 2. Index support.
--
-- The list filters by school and sorts by name on every page, and the previous
-- implementation never had to because it only ever fetched fifty rows. At 2,000
-- students across 40 pages that ordering is the whole cost.
-- ---------------------------------------------------------------------------
create index if not exists ix_students_school_name
  on public.students (school_id, full_name)
  where deleted_at is null;

-- ---------------------------------------------------------------------------
-- 3. Grants.
-- ---------------------------------------------------------------------------
grant execute on function public.fn_student_list(text, uuid, uuid, boolean, integer, integer)
  to authenticated;
revoke all on function public.fn_student_list(text, uuid, uuid, boolean, integer, integer)
  from anon;

-- ─────────────────────────────────────────────────────────────────────────
-- 0042_dashboard_truth.sql
-- ─────────────────────────────────────────────────────────────────────────
-- =============================================================================
-- 0042 — The dashboard was leaking other schools' money, and lying about dues.
--
-- ── BUG 1: A CROSS-TENANT LEAK ──────────────────────────────────────────────
--
-- fn_dashboard_summary is SECURITY DEFINER, so it runs as the function owner
-- and Row Level Security does not apply to it. Most of its queries were safe by
-- accident, because they join enrollments and filter on the caller's current
-- session id. Three were not, and had no school filter at all:
--
--     select count(*) from public.students
--      where date_trunc('month', s.created_at) = date_trunc('month', current_date);
--
--     select coalesce(sum(amount), 0) from public.payments
--      where status = 'verified' and created_at::date = current_date;
--
--     ...and the same for the month.
--
-- So "New this month", "Collected today" and "Collected this month" were
-- computed across EVERY SCHOOL IN THE DATABASE. Measured on a test database: a
-- school with one student and no payments was shown 271 new admissions and
-- Rs 24,577 collected today — the platform's totals, on the first three numbers
-- an owner reads every morning.
--
-- This is a tenant reading another tenant's financial position. The existing
-- tenant_isolation suite did not catch it because it tests table access, and
-- this leak is inside a SECURITY DEFINER function where RLS is not consulted.
-- supabase/tests/dashboard.sql now asserts every figure this function returns.
--
-- The lesson worth writing down: in a SECURITY DEFINER function, "the policy
-- will handle it" is never true. Every query needs its own school_id filter.
--
-- ── BUG 2: "NOTHING OWED" WHEN NOTHING WAS BILLED ───────────────────────────
--
-- Outstanding and the defaulter count derive only from invoice rows, so a
-- school that has never generated a challan is told it is owed Rs 0 by 0
-- students — rendered as good news, in green, while the attendance tile beside
-- it correctly shows "not marked yet today".
--
-- Worse, fn_generate_class_invoices on a class with no fee_structures rows
-- creates invoices with ZERO lines and status 'issued'. So a school can press
-- "Generate monthly challans", be told it succeeded, bill every student Rs 0,
-- and still see Outstanding Rs 0.
--
-- Numbers are not enough to fix this: Rs 0 owed and Rs 0 billed look identical.
-- So the function now also returns HOW MANY students were billed this month and
-- how many classes have no fee structure at all, and the UI leads with that
-- when there is nothing billed.
-- =============================================================================

create or replace function public.fn_dashboard_summary()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_school  uuid := public.current_school_id();
  v_session uuid := (select current_session_id from public.school_settings
                      where school_id = v_school);
  v_finance boolean := public.has_role('owner','principal','admin_clerk','accountant','readonly');
  v_active  int;
  v_present int; v_absent int; v_leave int; v_late int; v_half int; v_marked int;
  v_today numeric; v_month numeric; v_outstanding numeric; v_defaulters int;
  v_new_admissions int;
  v_billed_month int;
  v_classes_no_fee int;
  v_month_start date := date_trunc('month', current_date)::date;
begin
  if not public.has_role('owner','principal','admin_clerk','accountant',
                         'class_teacher','subject_teacher','readonly') then
    raise exception 'Not permitted';
  end if;

  select count(*) into v_active
  from public.enrollments e
  where e.school_id = v_school and e.session_id = v_session and e.status = 'active';

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
  where ad.school_id = v_school
    and ad.attendance_date = current_date
    and e.session_id = v_session;

  -- WAS THE LEAK. Now scoped to this school, and soft-deleted students are
  -- excluded — a record removed in error was still inflating the admissions
  -- figure it had been counted in.
  select count(*) into v_new_admissions
  from public.students s
  where s.school_id = v_school
    and s.deleted_at is null
    and s.created_at >= v_month_start
    and s.created_at < (v_month_start + interval '1 month');

  if v_finance then
    -- WAS THE LEAK. Both of these summed every school's payments.
    select coalesce(sum(p.amount), 0) into v_today
    from public.payments p
    where p.school_id = v_school
      and p.status = 'verified'
      and p.created_at >= date_trunc('day', now())
      and p.created_at <  date_trunc('day', now()) + interval '1 day';

    select coalesce(sum(p.amount), 0) into v_month
    from public.payments p
    where p.school_id = v_school
      and p.status = 'verified'
      and p.created_at >= v_month_start
      and p.created_at <  (v_month_start + interval '1 month');

    select coalesce(sum(b.bal), 0), count(*) into v_outstanding, v_defaulters
    from public.enrollments e
    join lateral (select public.student_balance(e.student_id) as bal) b on true
    where e.school_id = v_school
      and e.session_id = v_session
      and e.status = 'active'
      and b.bal > 0;

    -- The two figures that let the UI tell "paid up" from "never billed".
    --
    -- A challan with no lines is NOT billing: fn_generate_class_invoices on a
    -- class with no fee structure produces exactly that, reports success, and
    -- leaves Outstanding at zero. So a student counts as billed only if their
    -- challan actually charges something.
    select count(distinct i.student_id) into v_billed_month
    from public.invoices i
    where i.school_id = v_school
      and i.period_month = v_month_start
      and i.status <> 'void'
      and coalesce((select sum(case when l.is_discount then -l.amount else l.amount end)
                      from public.invoice_lines l where l.invoice_id = i.id), 0) > 0;

    -- Classes with active students and no fee structure for this session. This
    -- is the root cause behind a Rs 0 challan, so it is worth naming rather
    -- than leaving the school to work out why the numbers look wrong.
    select count(*) into v_classes_no_fee
    from public.classes c
    where c.school_id = v_school
      and exists (select 1 from public.enrollments e
                   where e.class_id = c.id and e.session_id = v_session and e.status = 'active')
      and not exists (select 1 from public.fee_structures fs
                       where fs.class_id = c.id and fs.session_id = v_session and fs.amount > 0);
  end if;

  return jsonb_build_object(
    'active_students', coalesce(v_active, 0),
    'new_admissions_month', coalesce(v_new_admissions, 0),
    'attendance', jsonb_build_object(
      'marked', coalesce(v_marked, 0), 'present', coalesce(v_present, 0),
      'absent', coalesce(v_absent, 0), 'leave', coalesce(v_leave, 0),
      'late', coalesce(v_late, 0), 'half_day', coalesce(v_half, 0)),
    'finance_visible', v_finance,
    'collected_today', coalesce(v_today, 0),
    'collected_month', coalesce(v_month, 0),
    'outstanding', coalesce(v_outstanding, 0),
    'defaulters', coalesce(v_defaulters, 0),
    -- New. The UI leads with these when they say nothing has been billed,
    -- instead of showing a green Rs 0.
    'billed_students_month', coalesce(v_billed_month, 0),
    'classes_without_fee', coalesce(v_classes_no_fee, 0),
    -- A null current session made every session-scoped figure silently zero.
    -- Saying so lets the UI show a setup prompt rather than a school that looks
    -- empty.
    'session_set', v_session is not null);
end;
$$;

-- ---------------------------------------------------------------------------
-- 3. One more of the same kind, found by sweeping for it.
--
-- Having established that a SECURITY DEFINER function without its own school
-- filter is a cross-tenant read, I swept every such function in the schema for
-- the pattern. Almost all were safe — they scope by auth.uid(), or delegate to
-- a gate that scopes (fn_may_manage_class checks the session, class AND section
-- all belong to current_school_id(); fn__assert_my_child does the equivalent
-- for the portal) — but fn_fee_amount had no scoping whatsoever:
--
--     select fs.amount from public.fee_structures fs
--      where fs.session_id = p_session_id and fs.class_id = p_class_id ...
--
-- Three uuids and you read another school's fee schedule. Far less serious than
-- the dashboard — a fee amount, and you would have to know the ids — but it is
-- the same hole and it costs one line to close.
-- ---------------------------------------------------------------------------
create or replace function public.fn_fee_amount(
  p_session_id uuid, p_class_id uuid, p_fee_head_id uuid, p_on date
) returns numeric language sql stable security definer set search_path = public as $$
  select fs.amount
  from public.fee_structures fs
  where fs.school_id = public.current_school_id()
    and fs.session_id = p_session_id
    and fs.class_id = p_class_id
    and fs.fee_head_id = p_fee_head_id
    and fs.effective_from <= coalesce(p_on, current_date)
  order by fs.effective_from desc
  limit 1;
$$;

-- ---------------------------------------------------------------------------
-- 4. fn_apply_family_credit — an unscoped cross-tenant WRITE.
--
-- The same sweep found this, and it is the worst of the set because it mutates.
-- It took any family_id, had NO role check and NO assert_own, and was granted to
-- `authenticated` — so any signed-in user, a parent included, could pass another
-- school's family id and have that family's payments reallocated across their
-- children's invoices.
--
-- It has no callers in the app (migration 0029 granted it speculatively), so
-- nothing is broken by locking it down now.
-- ---------------------------------------------------------------------------
create or replace function public.fn_apply_family_credit(p_family_id uuid)
returns numeric language plpgsql security definer set search_path = public as $$
declare
  v_students uuid[];
  v_pay      record;
  v_left     numeric;
  v_applied  numeric := 0;
begin
  if not public.has_role('owner', 'principal', 'admin_clerk', 'accountant') then
    raise exception 'Not permitted to apply family credit';
  end if;
  perform public.assert_own('families', p_family_id);

  select array_agg(id) into v_students
  from public.students
  where family_id = p_family_id and school_id = public.current_school_id();
  if v_students is null then return 0; end if;

  for v_pay in
    select p.id, p.amount - coalesce((
             select sum(al.amount) from public.payment_allocations al
             where al.payment_id = p.id), 0) as unallocated
    from public.payments p
    where p.family_id = p_family_id
      and p.school_id = public.current_school_id()
      and p.status = 'verified'
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

-- ---------------------------------------------------------------------------
-- 5. fn_import_staff — duplicate checks that spanned every school.
--
-- Also from the sweep:
--
--     exists (select 1 from public.staff where employee_no = v_emp ...)
--     exists (select 1 from public.staff where cnic = v_cnic ...)
--
-- No school filter, so importing staff rejected rows as duplicates because
-- ANOTHER school already used that employee number — and a teacher who works at
-- two schools on the platform could never be added to the second, because their
-- CNIC was "taken". It also told the importing school, by implication, that
-- some other school holds that number.
--
-- Only the two exists() clauses change; the rest of the function is untouched.
-- ---------------------------------------------------------------------------
do $$
declare v_def text;
begin
  select pg_get_functiondef(p.oid) into v_def
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname = 'fn_import_staff';

  v_def := replace(v_def,
    'from public.staff where employee_no = v_emp and deleted_at is null',
    'from public.staff where employee_no = v_emp and deleted_at is null'
      || ' and school_id = public.current_school_id()');
  v_def := replace(v_def,
    'from public.staff where cnic = v_cnic and deleted_at is null',
    'from public.staff where cnic = v_cnic and deleted_at is null'
      || ' and school_id = public.current_school_id()');

  execute v_def;
end $$;

-- ─────────────────────────────────────────────────────────────────────────
-- 0043_message_settings.sql
-- ─────────────────────────────────────────────────────────────────────────
-- =============================================================================
-- 0043 — Let a school edit and switch off what its parents receive.
--
-- WHY
--
-- message_templates has existed since 0034 with a `body` and an `enabled` flag,
-- seeded per school, and NOTHING in the app has ever read or written it. So the
-- wording a school sends to three hundred parents was fixed by a migration, and
-- a school that wanted to stop one of the five message types had no way to.
--
-- The RLS policy on the table already permits owner/principal to write, so the
-- app can edit these directly — no RPC is needed for that half. What is missing
-- is a way BACK: a school that deletes half a template and sends it out needs to
-- restore the original, and the originals live here in SQL.
--
-- This mirrors OurSchoolSoftware's "Automation Settings", where every event has
-- an editable body, a visible list of supported merge tags, and an Enabled
-- toggle so a school can silence any single one. Theirs is SMS; ours is
-- WhatsApp click-to-chat, so the same workflow costs nothing to run.
--
-- WHAT THIS AVOIDS
--
-- The default bodies were written out once inside fn__seed_message_templates.
-- Adding a reset would have meant a second copy of the same five paragraphs,
-- which would drift. They are extracted here into one function that both the
-- seed and the reset call, so there is exactly one place the wording lives.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. The defaults, in one place, with the merge tags each one may use.
--
-- The tag list is a FACT ABOUT THE CALL SITE, not decoration: {receipt} only
-- resolves for payment_received because fn__queue_payment_receipt is the only
-- caller that passes it. Showing a school a tag that will never resolve means
-- they put it in a message and a parent receives the literal "{receipt}".
--
-- Universal tags, filled in by fn_queue_message for every template:
--   {parent} {children} {school} {date} {balance}
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
     array['parent','children','school','date','balance'])
$$;

-- ---------------------------------------------------------------------------
-- 2. Seeding, now reading from the single source above.
--
-- Same behaviour as before — on conflict do nothing, so an existing school's
-- edited wording is never overwritten by a re-run.
-- ---------------------------------------------------------------------------
create or replace function public.fn__seed_message_templates(p_school uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  insert into public.message_templates (school_id, template_key, label, body)
  select p_school, d.template_key, d.label, d.body
  from public.fn__default_message_templates() d
  on conflict (school_id, template_key) do nothing;
end;
$$;

-- Any school created before this migration is missing nothing, but a school
-- created between 0034 and here could be missing a template if the list ever
-- grew. Cheap to make certain.
do $$
declare s record;
begin
  for s in select id from public.schools loop
    perform public.fn__seed_message_templates(s.id);
  end loop;
end $$;

-- ---------------------------------------------------------------------------
-- 3. What the settings screen reads.
--
-- Returns the school's current wording alongside the tags each template may
-- use, so the editor can show them without the client holding its own copy of
-- facts that live at the call sites.
--
-- is_staff() rather than owner/principal: a clerk should be able to SEE what
-- goes out over their name. The table's own policy still stops them editing.
-- ---------------------------------------------------------------------------
create or replace function public.fn_message_settings()
returns table (
  template_key text,
  label        text,
  body         text,
  enabled      boolean,
  tags         text[],
  is_default   boolean
) language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_staff() then
    raise exception 'Not permitted' using errcode = '42501';
  end if;

  return query
  select t.template_key, t.label, t.body, t.enabled,
         coalesce(d.tags, array['parent','children','school','date','balance']),
         -- So the editor can offer "Restore default" only where it would do
         -- something, rather than on every row.
         t.body = d.body
  from public.message_templates t
  left join public.fn__default_message_templates() d on d.template_key = t.template_key
  where t.school_id = public.current_school_id()
  order by t.label;
end;
$$;

-- ---------------------------------------------------------------------------
-- 4. Restore one template's original wording.
--
-- owner/principal only, matching the table's write policy — this changes what
-- every parent receives.
-- ---------------------------------------------------------------------------
create or replace function public.fn_reset_message_template(p_template_key text)
returns text language plpgsql security definer set search_path = public as $$
declare v_body text;
begin
  if not public.has_role('owner', 'principal') then
    raise exception 'Only the owner or principal can change message wording';
  end if;

  select d.body into v_body
  from public.fn__default_message_templates() d
  where d.template_key = p_template_key;

  if v_body is null then
    raise exception 'No such message template: %', p_template_key;
  end if;

  update public.message_templates
     set body = v_body
   where school_id = public.current_school_id()
     and template_key = p_template_key;

  return v_body;
end;
$$;

-- ---------------------------------------------------------------------------
-- 5. Grants.
-- ---------------------------------------------------------------------------
grant execute on function public.fn_message_settings()             to authenticated;
grant execute on function public.fn_reset_message_template(text)   to authenticated;
grant execute on function public.fn__default_message_templates()   to authenticated;

revoke all on function public.fn_message_settings()           from anon;
revoke all on function public.fn_reset_message_template(text) from anon;

-- ─────────────────────────────────────────────────────────────────────────
-- 0044_reports.sql
-- ─────────────────────────────────────────────────────────────────────────
-- =============================================================================
-- 0044 — The reporting area a head teacher actually reads.
--
-- OurSchoolSoftware's Reporting Area lists thirteen reports. We had five:
-- class-wise basics, defaulters, income & expense, day book, reconciliation.
-- Missing were the eight that answer questions an owner asks at month end —
-- debit & credit statement, list of unpaid invoices, fee discount report,
-- accounts summary, detailed income, detailed expense, balance sheet, admission
-- date report — plus head-wise dues, which existed in SQL with no screen.
--
-- WHY FOUR FUNCTIONS AND NOT EIGHT
--
-- Six of those eight are the same data asked different ways. A detailed income
-- report is the ledger filtered to income; a detailed expense report is the
-- ledger filtered to expenses; a debit & credit statement is both, in date
-- order, with a running balance; an accounts summary is that grouped. Writing
-- them as separate functions would mean six places to fix when the definition
-- of "income" changes — and it will, because fee income must always derive from
-- receipts and never be hand-entered.
--
-- So: one ledger function with a filter, plus three genuinely different reports.
--
-- WHAT EVERY ONE OF THESE HAS IN COMMON
--
-- All are SECURITY DEFINER, so RLS does not apply and each carries its own
-- school_id filter — the lesson from 0042, where three unscoped queries in the
-- dashboard were reporting the platform's totals to every tenant. The
-- structural guard in supabase/tests/dashboard.sql enforces it.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. The ledger: every rupee in and out, in date order, with a running balance.
--
-- Serves three of their reports at once (Debit & Credit Statement, Detailed
-- Income, Detailed Expense) via p_kind.
--
-- Income is fee receipts plus recorded other-income. Fee receipts are read from
-- payments and CANNOT be typed in anywhere, which is the property that makes
-- this statement worth trusting: a school cannot inflate its collections
-- without a receipt existing.
--
-- Reversals appear as their own negative rows rather than being netted away.
-- A statement that silently hides a reversed receipt is exactly what a
-- dishonest clerk would want.
-- ---------------------------------------------------------------------------
create or replace function public.fn_report_ledger(
  p_from date,
  p_to   date,
  p_kind text default 'all'          -- 'all' | 'income' | 'expense'
) returns table (
  entry_date   date,
  kind         text,                 -- 'income' | 'expense'
  category     text,                 -- fee head group, or expense category
  particulars  text,
  reference    text,                 -- receipt or voucher number
  party        text,                 -- who paid, or who was paid
  method       text,
  debit        numeric,              -- money in
  credit       numeric,              -- money out
  recorded_by  text,
  is_reversal  boolean
) language plpgsql stable security definer set search_path = public as $$
declare v_school uuid := public.current_school_id();
begin
  -- Matches fn_finance_summary's boundary (owner / principal / accountant)
  -- rather than inventing a third one. Note a PRE-EXISTING inconsistency this
  -- deliberately does not paper over: fn_dashboard_summary shows the money
  -- tiles to `readonly` too, while fn_finance_summary refuses it. A full
  -- debit-and-credit statement naming every payer and payee is more sensitive
  -- than a tile, so it follows the stricter of the two. Whether `readonly`
  -- should see money at all is a decision for the school to make, not one to
  -- settle silently here.
  if not public.has_role('owner', 'principal', 'accountant') then
    raise exception 'Not permitted to read the accounts' using errcode = '42501';
  end if;
  if p_from is null or p_to is null then
    raise exception 'A date range is required';
  end if;
  if p_to < p_from then
    raise exception 'The end date is before the start date';
  end if;

  return query
  with rows_in as (
    -- Fee receipts. Verified only: a pending bank transfer is not income yet.
    select p.created_at::date               as entry_date,
           'income'::text                   as kind,
           'Fee collection'::text           as category,
           coalesce(
             (select string_agg(distinct
                       coalesce(to_char(i.period_month, 'Mon YYYY'), 'Other'), ', ')
                from public.payment_allocations al
                join public.invoices i on i.id = al.invoice_id
               where al.payment_id = p.id),
             'On account')                  as particulars,
           coalesce('#' || p.receipt_no::text, '—') as reference,
           coalesce(f.head_name, s.full_name, '—')  as party,
           p.method::text                   as method,
           -- A reversal is stored as a payment with a NEGATIVE amount. Putting
           -- it straight into `debit` gave a "money in" column containing
           -- -300, and made the two sides net out so a reversed receipt looked
           -- like it had never happened. A contra entry belongs on the opposite
           -- side as a positive figure, which is how a ledger is read and how
           -- the totals stay meaningful.
           case when p.amount >= 0 then p.amount else 0 end   as debit,
           case when p.amount <  0 then -p.amount else 0 end  as credit,
           coalesce(pr.full_name, '—')      as recorded_by,
           p.reversal_of is not null        as is_reversal
    from public.payments p
    left join public.families f on f.id = p.family_id
    left join public.students s on s.id = p.student_id
    left join public.profiles pr on pr.id = p.received_by
    where p.school_id = v_school
      and p.status = 'verified'
      and p.created_at::date between p_from and p_to

    union all

    -- Non-fee income: hall rent, a van hire, a book sale.
    select oi.received_on, 'income', 'Other income',
           oi.source, '—', '—', oi.method::text,
           oi.amount, 0::numeric,
           coalesce(pr.full_name, '—'),
           false
    from public.other_income oi
    left join public.profiles pr on pr.id = oi.recorded_by
    where oi.school_id = v_school
      and oi.received_on between p_from and p_to

    union all

    select e.spent_on, 'expense', coalesce(ec.name, 'Uncategorised'),
           coalesce(e.note, coalesce(ec.name, 'Expense')),
           coalesce('V' || e.voucher_no::text, '—'),
           coalesce(e.payee, '—'), e.method::text,
           0::numeric, e.amount,
           coalesce(pr.full_name, '—'),
           e.reversal_of is not null
    from public.expenses e
    left join public.expense_categories ec on ec.id = e.category_id
    left join public.profiles pr on pr.id = e.recorded_by
    where e.school_id = v_school
      and e.spent_on between p_from and p_to
  )
  select r.entry_date, r.kind, r.category, r.particulars, r.reference,
         r.party, r.method, r.debit, r.credit, r.recorded_by, r.is_reversal
  from rows_in r
  where p_kind = 'all' or r.kind = p_kind
  order by r.entry_date, r.kind desc, r.reference;
end;
$$;

-- ---------------------------------------------------------------------------
-- 2. List of unpaid invoices.
--
-- Per CHALLAN, not per student — which is the point, and why the defaulter
-- report does not answer it. "Ahmed owes Rs 3,600" does not tell a clerk which
-- three months are outstanding or which slip to reprint; this does.
--
-- Age in days is included because a challan two weeks past due and one eight
-- months past due need different conversations.
-- ---------------------------------------------------------------------------
create or replace function public.fn_report_unpaid_invoices(p_session_id uuid)
returns table (
  invoice_id   uuid,
  voucher_code text,
  period_label text,
  due_date     date,
  days_overdue integer,
  student_id   uuid,
  student_name text,
  gr_no        text,
  class_name   text,
  section_name text,
  father_name  text,
  charge       numeric,
  paid         numeric,
  due          numeric
) language plpgsql stable security definer set search_path = public as $$
declare v_school uuid := public.current_school_id();
begin
  if not public.is_staff() then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  perform public.assert_own('academic_sessions', p_session_id);

  return query
  select i.id, i.voucher_code,
         coalesce(to_char(i.period_month, 'Mon YYYY'), coalesce(i.notes, 'One-off')),
         i.due_date,
         case when i.due_date is null or i.due_date >= current_date then 0
              else (current_date - i.due_date) end::int,
         s.id, s.full_name, s.gr_no, c.name, sec.name, s.father_name,
         ch.charge, coalesce(pd.paid, 0), ch.charge - coalesce(pd.paid, 0)
  from public.invoices i
  join public.students s on s.id = i.student_id
  left join public.enrollments e on e.id = i.enrollment_id
  left join public.classes c   on c.id = e.class_id
  left join public.sections sec on sec.id = e.section_id
  cross join lateral (
    select coalesce((select sum(case when l.is_discount then -l.amount else l.amount end)
                       from public.invoice_lines l where l.invoice_id = i.id), 0)
           + coalesce(i.fine, 0) as charge
  ) ch
  left join lateral (
    select sum(al.amount) as paid
      from public.payment_allocations al
      join public.payments p on p.id = al.payment_id
     where al.invoice_id = i.id and p.status = 'verified'
  ) pd on true
  where i.school_id = v_school
    and i.session_id = p_session_id
    and i.status <> 'void'
    and s.deleted_at is null
    and ch.charge - coalesce(pd.paid, 0) > 0
  order by i.due_date nulls last, s.full_name;
end;
$$;

-- ---------------------------------------------------------------------------
-- 3. Fee discount report.
--
-- The most audit-relevant report in the set, and the reason it is worth having
-- separately: a discount is money the school chose not to collect. Who granted
-- it, who approved it, and why are the columns that matter — a discount register
-- without an approver is just a list of holes in the income.
-- ---------------------------------------------------------------------------
create or replace function public.fn_report_discounts(p_from date, p_to date)
returns table (
  granted_on   date,
  student_id   uuid,
  student_name text,
  gr_no        text,
  class_name   text,
  reason_type  text,      -- sibling / merit / staff_child / hardship / ...
  is_percent   boolean,
  amount       numeric,
  reason       text,
  status       text,
  proposed_by  text,
  approved_by  text,
  approved_at  timestamptz
) language plpgsql stable security definer set search_path = public as $$
declare v_school uuid := public.current_school_id();
begin
  if not public.has_role('owner', 'principal', 'accountant') then
    raise exception 'Not permitted to read discounts' using errcode = '42501';
  end if;

  -- discounts key on ENROLMENT, not student, so the join goes through
  -- enrollments. That also means a discount is scoped to one session, which is
  -- correct — last year's hardship waiver should not silently continue.
  return query
  select d.created_at::date, s.id, s.full_name, s.gr_no, c.name,
         d.type::text, d.is_percent, d.amount, d.reason, d.status::text,
         coalesce(pb.full_name, '—'), coalesce(ab.full_name, '—'), d.approved_at
  from public.discounts d
  join public.enrollments e on e.id = d.enrollment_id
  join public.students s    on s.id = e.student_id
  left join public.classes c on c.id = e.class_id
  left join public.profiles pb on pb.id = d.created_by
  left join public.profiles ab on ab.id = d.approved_by
  where d.school_id = v_school
    and s.deleted_at is null
    and (p_from is null or d.created_at::date >= p_from)
    and (p_to   is null or d.created_at::date <= p_to)
  order by d.created_at desc;
end;
$$;

-- ---------------------------------------------------------------------------
-- 4. Admission date report.
--
-- Who joined, when, and whether they are still here. The last column is what
-- makes it useful beyond a headcount: a month with twelve admissions and nine
-- of them already struck off is a different fact from a month with twelve that
-- stayed.
-- ---------------------------------------------------------------------------
create or replace function public.fn_report_admissions(p_from date, p_to date)
returns table (
  admitted_on  date,
  student_id   uuid,
  student_name text,
  gr_no        text,
  admission_no text,
  father_name  text,
  gender       text,
  class_name   text,
  section_name text,
  status       text,
  admitted_by  text
) language plpgsql stable security definer set search_path = public as $$
declare v_school uuid := public.current_school_id();
begin
  if not public.is_staff() then
    raise exception 'Not permitted' using errcode = '42501';
  end if;

  return query
  select coalesce(s.admission_date, s.created_at::date),
         s.id, s.full_name, s.gr_no, s.admission_no, s.father_name,
         s.gender::text, c.name, sec.name, s.status::text,
         '—'::text          -- students carries no created_by; see note below
  from public.students s
  left join public.enrollments e on e.student_id = s.id and e.status = 'active'
  left join public.classes c   on c.id = e.class_id
  left join public.sections sec on sec.id = e.section_id
  where s.school_id = v_school
    and s.deleted_at is null
    and coalesce(s.admission_date, s.created_at::date)
        between coalesce(p_from, '1900-01-01'::date) and coalesce(p_to, '2999-12-31'::date)
  order by coalesce(s.admission_date, s.created_at::date) desc, s.full_name;
end;
$$;

-- A limitation stated rather than faked: public.students has no created_by
-- column, so "admitted by" cannot be filled without a schema change plus a
-- backfill that would be guesswork for existing rows. The column is returned as
-- '—' so the report's shape is stable if that is added later. The audit_log does
-- record the actor for every student insert, which is where the answer lives
-- today.

-- ---------------------------------------------------------------------------
-- 5. Grants.
-- ---------------------------------------------------------------------------
grant execute on function public.fn_report_ledger(date, date, text)   to authenticated;
grant execute on function public.fn_report_unpaid_invoices(uuid)      to authenticated;
grant execute on function public.fn_report_discounts(date, date)      to authenticated;
grant execute on function public.fn_report_admissions(date, date)     to authenticated;

revoke all on function public.fn_report_ledger(date, date, text)  from anon;
revoke all on function public.fn_report_unpaid_invoices(uuid)     from anon;
revoke all on function public.fn_report_discounts(date, date)     from anon;
revoke all on function public.fn_report_admissions(date, date)    from anon;

-- ─────────────────────────────────────────────────────────────────────────
-- 0045_balance_sheet.sql
-- ─────────────────────────────────────────────────────────────────────────
-- =============================================================================
-- 0045 — The balance sheet, as at a date.
--
-- The last of their eight missing money reports, and the only one that could
-- not be served by filtering the ledger — because it is not a RANGE, it is a
-- position AS AT one day. "What did the school stand at on 30 June?" is a
-- different question from "what happened in June?", and answering it with a
-- range is how a year-end figure ends up wrong.
--
-- WHY THIS IS HARDER THAN IT LOOKS
--
-- student_balance() gives the CURRENT balance. It cannot answer "what was owed
-- on 30 June?", because it counts every charge and every payment regardless of
-- date. So this reconstructs the position from the dated rows:
--
--   receivable  = charges on invoices ISSUED on or before the date
--                 + fines on those
--                 + adjustments made on or before the date
--                 − allocations from payments TAKEN on or before the date
--
--   advance     = verified payments taken on or before the date
--                 − everything those payments have been allocated to,
--                 counting only allocations against invoices issued by then
--
--   cash moved  = verified receipts + other income − expenses, all up to the
--                 date, from the beginning
--
-- The awkward term is `advance`. A payment can be allocated to an invoice
-- issued AFTER the as-at date — a parent paying August's fee in July. On 31
-- July that money is an advance the school is holding, not income against a
-- charge that does not exist yet, so the allocation is excluded by the
-- invoice's issue date rather than the payment's. Getting that wrong makes a
-- school with advance fees look like it has no liability.
--
-- WHAT THIS IS NOT
--
-- Not double-entry bookkeeping. There is no chart of accounts, no bank
-- reconciliation and no fixed assets, because none of that exists in this
-- schema and inventing it would be worse than omitting it. It is the four
-- figures a Pakistani school principal actually asks for: what we are owed,
-- what we are holding for parents, what has come in, what has gone out.
-- =============================================================================

create or replace function public.fn_report_balance_sheet(p_as_at date)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_school     uuid := public.current_school_id();
  v_as_at      date := coalesce(p_as_at, current_date);
  v_charges    numeric;
  v_fines      numeric;
  v_adjust     numeric;
  v_allocated  numeric;
  v_receivable numeric;
  v_from_off   numeric;
  v_receipts   numeric;
  v_other_in   numeric;
  v_expenses   numeric;
  v_advance    numeric;
  v_students   int;
  v_owing      int;
begin
  if not public.has_role('owner', 'principal', 'accountant') then
    raise exception 'Not permitted to read the accounts' using errcode = '42501';
  end if;

  -- ---- the position, reconstructed one student at a time ----
  --
  -- Done PER STUDENT rather than as four school-wide sums, for one reason: the
  -- headcount of who owes money and the total owed must come out of the same
  -- arithmetic. The first cut of this function summed the money as-at but took
  -- the headcount from student_balance(), which is a CURRENT figure — so a
  -- balance sheet as at a date before the school billed anything reported
  -- "receivable 0, students owing 1". A statement that contradicts itself in
  -- two adjacent numbers is worse than no statement.
  --
  -- Grouping allocations by the INVOICE's student, not the payment's, is also
  -- what makes family payments land on the right child: a payment row for a
  -- family has no student_id at all.
  with inv as (
    -- issued_at, not created_at: a challan prepared on the 28th and issued on
    -- the 1st is not a receivable on the 30th.
    select i.id, i.student_id, i.status, coalesce(i.fine, 0) as fine
    from public.invoices i
    where i.school_id = v_school
      and coalesce(i.issued_at::date, i.created_at::date) <= v_as_at
  ),
  charge as (
    select v.student_id,
           sum(case when l.is_discount then -l.amount else l.amount end) as amt
    from inv v
    join public.invoice_lines l on l.invoice_id = v.id
    where v.status <> 'void'
    group by 1
  ),
  fine as (
    select v.student_id, sum(v.fine) as amt
    from inv v where v.status <> 'void' group by 1
  ),
  adj as (
    select a.student_id, sum(a.amount) as amt
    from public.adjustments a
    where a.school_id = v_school and a.created_at::date <= v_as_at
    group by 1
  ),
  alloc as (
    -- `inv` is already filtered to invoices ISSUED by the as-at date, and that
    -- is the subtle part of the whole report: an allocation against an invoice
    -- issued AFTER the date is a parent paying next month early. On this date
    -- that money is an advance the school is holding, not a settled charge.
    --
    -- Note there is deliberately no `status <> 'void'` here, even though the
    -- charge sums have it. student_balance() omits it too, and the two must
    -- agree — a clerk checking this against a student ledger has to see the
    -- same money. Nothing in this schema ever sets an invoice to 'void' today
    -- (there is no void function), so the case is unreachable; aligning now is
    -- what stops the two screens diverging if one is ever added.
    select v.student_id, sum(al.amount) as amt
    from public.payment_allocations al
    join inv v on v.id = al.invoice_id
    join public.payments p on p.id = al.payment_id
    where p.school_id = v_school
      and p.status = 'verified'
      and p.created_at::date <= v_as_at
    group by 1
  ),
  per_student as (
    -- Every student the school has ever had, not just those on the roll: a
    -- withdrawn child's unpaid arrears are still money owed to the school, and
    -- dropping them would quietly shrink the receivable.
    select s.id,
           coalesce(c.amt, 0)  as charges,
           coalesce(f.amt, 0)  as fines,
           coalesce(j.amt, 0)  as adjust,
           coalesce(al.amt, 0) as allocated,
           coalesce(c.amt, 0) + coalesce(f.amt, 0) + coalesce(j.amt, 0)
             - coalesce(al.amt, 0) as bal,
           -- On the roll AS AT the date. admission_date is a real date, so
           -- "had they joined yet" is answerable; `status` however has no
           -- history, so a child who has since left is counted as off-roll
           -- even for a date when they were present. Stated in `basis`.
           (coalesce(s.admission_date, s.created_at::date) <= v_as_at
            and (s.deleted_at is null or s.deleted_at::date > v_as_at)
            and s.status = 'active') as on_roll
    from public.students s
    left join charge c  on c.student_id  = s.id
    left join fine   f  on f.student_id  = s.id
    left join adj    j  on j.student_id  = s.id
    left join alloc  al on al.student_id = s.id
    where s.school_id = v_school
  )
  select coalesce(sum(charges), 0),
         coalesce(sum(fines), 0),
         coalesce(sum(adjust), 0),
         coalesce(sum(allocated), 0),
         coalesce(sum(bal), 0),
         coalesce(sum(bal) filter (where bal > 0 and not on_roll), 0),
         count(*) filter (where on_roll),
         count(*) filter (where bal > 0 and on_roll)
    into v_charges, v_fines, v_adjust, v_allocated,
         v_receivable, v_from_off, v_students, v_owing
  from per_student;

  -- ---- cash movement from the beginning up to the date ----
  select coalesce(sum(p.amount), 0) into v_receipts
  from public.payments p
  where p.school_id = v_school
    and p.status = 'verified'
    and p.created_at::date <= v_as_at;

  select coalesce(sum(oi.amount), 0) into v_other_in
  from public.other_income oi
  where oi.school_id = v_school and oi.received_on <= v_as_at;

  select coalesce(sum(e.amount), 0) into v_expenses
  from public.expenses e
  where e.school_id = v_school and e.spent_on <= v_as_at;

  -- ---- money held that is not against a charge yet ----
  v_advance := v_receipts - v_allocated;
  -- Cannot be negative: if allocations somehow exceed receipts the honest thing
  -- is to show zero advance and let the receivable carry the difference, rather
  -- than print a negative liability nobody can interpret.
  if v_advance < 0 then v_advance := 0; end if;

  return jsonb_build_object(
    'as_at',              v_as_at,
    -- Assets side
    'receivable',         v_receivable,
    'cash_in',            v_receipts + v_other_in,
    'cash_out',           v_expenses,
    'cash_position',      v_receipts + v_other_in - v_expenses,
    -- Liability side
    'advance_held',       v_advance,
    -- Context, so the figures can be sanity-checked at a glance
    'fee_receipts',       v_receipts,
    'other_income',       v_other_in,
    'charges_raised',     v_charges + v_fines + v_adjust,
    'allocated',          v_allocated,
    -- Named separately rather than hidden inside `receivable`, because the
    -- headcount below excludes these children and a principal comparing the
    -- two would otherwise be looking at an unexplained gap. Schools here do
    -- chase leavers' arrears, so it is a figure they want, not a footnote.
    'receivable_off_roll', v_from_off,
    'students_on_roll',   v_students,
    'students_owing',     v_owing,
    -- Stated in the payload rather than only in a comment, because a reader of
    -- the raw JSON deserves to know what it does not include.
    'basis',             'Cumulative from the first record up to the as-at date. '
                      || 'Receivable counts charges on invoices ISSUED by that date, less '
                      || 'payments taken by that date against those invoices, for every '
                      || 'student the school has ever had. Money paid early for a later '
                      || 'month is shown as advance held, not as income. Roll counts use '
                      || 'the student''s CURRENT status, which is not kept historically, '
                      || 'so a child who has since left is counted off-roll even for a '
                      || 'date when they were present; their arrears still appear in '
                      || 'receivable. Not double-entry: no chart of accounts, no bank '
                      || 'reconciliation, no fixed assets.');
end;
$$;

grant execute on function public.fn_report_balance_sheet(date) to authenticated;
revoke all on function public.fn_report_balance_sheet(date) from anon;

-- ─────────────────────────────────────────────────────────────────────────
-- 0046_enquiries.sql
-- ─────────────────────────────────────────────────────────────────────────
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

-- ─────────────────────────────────────────────────────────────────────────
-- 0047_reachability.sql
-- ─────────────────────────────────────────────────────────────────────────
-- =============================================================================
-- 0047 — Close the "declared but unreachable" class of bug.
--
-- WHY THIS MIGRATION EXISTS
--
-- The single most common defect in this codebase has not been wrong logic. It
-- has been CORRECT logic that nothing could reach. Every one of these shipped,
-- passed CI, and did nothing:
--
--   * fn_link_parent          — the only writer of profiles.family_id, no callers,
--                               so the whole parent portal threw for every parent
--   * profiles.active         — written by the Settings screen, read by nothing,
--                               so "Deactivate" left a dismissed clerk full access
--   * fn_family_for           — no callers, so siblings never shared a family and
--                               family billing had never worked in production
--   * fn_find_by_voucher      — no callers, so a printed challan could not be scanned
--   * message_templates.enabled — no writer, so the WhatsApp toggle was decorative
--   * result_cards.published_at — never selected, so no result could reach a parent
--   * students.photo_url      — still dead
--   * supabase/bundles/       — stopped at migration 0039, so seven migrations
--                               never reached any real school at all
--
-- Each was found by hand, late, one at a time. supabase/check-reachable.sh now
-- finds them by query on every CI run. This migration fixes what that check
-- turned up on its first run.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. THE BUG: other income could be recorded but never reversed
--
-- 0030 built expenses and other income as mirror images, both append-only:
-- never edit, never delete, correct with a reversing entry. fn_reverse_expense
-- got a db.ts wrapper and a button on the Accounts screen. Its twin,
-- fn_reverse_other_income, got neither — so a clerk who typed Rs 50,000 of hall
-- rent instead of Rs 5,000 had NO way to correct it, ever. The error sat in the
-- income figure, the profit figure, the day book and the balance sheet
-- permanently.
--
-- The function itself was correct all along. Only the wiring was missing, which
-- is exactly the pattern above. Nothing to change here — the fix is the db.ts
-- wrapper and the Accounts screen button in this same commit. This comment
-- records WHY a function that already existed suddenly appears in a changelog,
-- so nobody later "cleans up" the apparently-redundant reversal path.
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- 2. Two genuinely dead helpers, dropped
--
-- Both were confirmed unreferenced by querying the live catalogue, not by
-- reading: no function body, no trigger, no RLS policy (USING or WITH CHECK),
-- no column default, no check constraint, no index expression, no view — and no
-- mention anywhere in web/src or supabase/functions.
--
--   auth_role()  — from 0001. Superseded by has_role()/is_staff(), which every
--                  policy and guard actually uses.
--   is_parent()  — from 0033. The portal gates on my_family_id() and
--                  fn__assert_my_child() instead.
--
-- Dropped rather than left in place, because a dead function that `authenticated`
-- may EXECUTE is attack surface for no benefit, and because a reviewed-exceptions
-- list should hold deliberate exceptions rather than things nobody got round to.
-- If either is ever wanted again it is four lines of git history away.
-- ---------------------------------------------------------------------------
drop function if exists public.auth_role();
drop function if exists public.is_parent();

-- ─────────────────────────────────────────────────────────────────────────
-- 0048_corrections.sql
-- ─────────────────────────────────────────────────────────────────────────
-- =============================================================================
-- 0048 — Make the mark and attendance audit trail visible.
--
-- WHAT WAS WRONG
--
-- mark_entries and attendance_daily both carry `corrected_from` and
-- `correction_reason`. The three entry functions diligently write
-- `corrected_from` — the previous mark, the previous attendance status —
-- whenever a value actually changes.
--
-- Nothing has ever READ either column. Not one function, not one screen. And
-- `correction_reason` was never written at all.
--
-- So the system quietly records that a teacher changed a mark from 45 to 40 the
-- night before results, and no principal can see it, no parent disputing that
-- mark can be answered, and nobody was ever asked why. An audit trail nobody
-- can read is not an audit trail; it is a database column that makes the
-- software look trustworthy without being trustworthy.
--
-- Found by supabase/check-columns-used.sh, which now fails CI for any new
-- column nothing reads or writes.
--
-- WHAT THIS DOES
--
--   1. The three entry functions take an optional reason, and record it ONLY on
--      the rows whose value actually changed. A reason attached to an unchanged
--      mark would be noise in the very report this exists to make readable.
--   2. Two read paths — fn_mark_corrections and fn_attendance_corrections —
--      gated on owner/principal, because this is an oversight tool. A subject
--      teacher auditing colleagues is not what it is for, and the person most
--      likely to want it hidden is the person who changed the mark.
--
-- WHY THE SIGNATURES ARE DROPPED AND RECREATED
--
-- `create or replace` cannot add a parameter: it creates an OVERLOAD instead,
-- and then a two-argument call matches both the old function and the new one's
-- default, which Postgres rejects as ambiguous. So the two-argument forms are
-- dropped first. Existing two-argument callers — the app included — keep
-- working through the new default.
-- =============================================================================

drop function if exists public.fn_enter_marks(uuid, jsonb);
drop function if exists public.fn_enter_assessment_marks(uuid, jsonb);
drop function if exists public.fn_mark_attendance(date, jsonb);

-- ---------------------------------------------------------------------------
-- 1. Exam marks
-- ---------------------------------------------------------------------------
create or replace function public.fn_enter_marks(
  p_exam_subject_id uuid, p_marks jsonb, p_reason text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_actor  uuid := auth.uid();
  v_max    numeric;
  v_total  integer;
  v_marked integer;
  v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
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
    insert into public.mark_entries as me
      (exam_subject_id, enrollment_id, marks, max_marks, is_absent, marked_by)
    select p_exam_subject_id, enrollment_id, marks, v_max, is_absent, v_actor from input
    on conflict (exam_subject_id, enrollment_id) where exam_subject_id is not null
    do update set marks = excluded.marks, is_absent = excluded.is_absent,
                  marked_by = excluded.marked_by,
                  corrected_from = case when me.marks is distinct from excluded.marks
                                        then me.marks else me.corrected_from end,
                  -- Only on the rows that actually CHANGED. Stamping the reason
                  -- on an unchanged mark would fill the corrections report with
                  -- rows where nothing happened, which is how a report stops
                  -- being read.
                  correction_reason = case when me.marks is distinct from excluded.marks
                                           then v_reason else me.correction_reason end
    where not me.is_locked
    returning 1
  )
  select count(*) into v_marked from upserted;

  return jsonb_build_object('marked', v_marked, 'skipped', v_total - v_marked, 'total', v_total);
end;
$$;

-- ---------------------------------------------------------------------------
-- 2. Assessment (class test) marks
-- ---------------------------------------------------------------------------
create or replace function public.fn_enter_assessment_marks(
  p_assessment_id uuid, p_marks jsonb, p_reason text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_actor  uuid := auth.uid();
  v_a      record;
  v_total  integer;
  v_marked integer;
  v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
begin
  if not public.has_role('owner','principal','admin_clerk','class_teacher','subject_teacher') then
    raise exception 'Not permitted to enter marks';
  end if;
  perform public.assert_own('assessments', p_assessment_id);
  if p_marks is null or jsonb_typeof(p_marks) <> 'array' then
    raise exception 'p_marks must be a JSON array';
  end if;

  select * into v_a from public.assessments
  where id = p_assessment_id and school_id = public.current_school_id();
  if not found then raise exception 'Assessment not found'; end if;
  if v_a.is_locked then raise exception 'This assessment is locked'; end if;

  -- Teacher scope, as before: a subject teacher may only mark their own class.
  if not public.has_role('owner','principal','admin_clerk') then
    if not public.fn_may_manage_class(v_a.session_id, v_a.class_id, v_a.section_id) then
      raise exception 'You can only enter marks for your assigned class';
    end if;
  end if;

  if exists (
    select 1 from jsonb_array_elements(p_marks) e
    where coalesce((e->>'is_absent')::boolean, false) = false
      and nullif(e->>'marks', '') is not null
      and ((e->>'marks')::numeric < 0 or (e->>'marks')::numeric > v_a.max_marks)
  ) then
    raise exception 'Marks must be between 0 and %', v_a.max_marks;
  end if;

  -- Every enrolment must be in this school.
  if exists (
    select 1 from jsonb_array_elements(p_marks) e
    where not exists (
      select 1 from public.enrollments en
      where en.id = (e->>'enrollment_id')::uuid
        and en.school_id = public.current_school_id())
  ) then
    raise exception 'Unknown enrolment in this school' using errcode = '42501';
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
    insert into public.mark_entries as me
      (assessment_id, enrollment_id, marks, max_marks, is_absent, marked_by)
    select p_assessment_id, enrollment_id, marks, v_a.max_marks, is_absent, v_actor from input
    on conflict (assessment_id, enrollment_id) where assessment_id is not null
    do update set marks = excluded.marks, is_absent = excluded.is_absent,
                  marked_by = excluded.marked_by,
                  corrected_from = case when me.marks is distinct from excluded.marks
                                        then me.marks else me.corrected_from end,
                  correction_reason = case when me.marks is distinct from excluded.marks
                                           then v_reason else me.correction_reason end
    where not me.is_locked
    returning 1
  )
  select count(*) into v_marked from upserted;

  return jsonb_build_object('marked', v_marked, 'skipped', v_total - v_marked, 'total', v_total);
end;
$$;

-- ---------------------------------------------------------------------------
-- 3. Attendance
-- ---------------------------------------------------------------------------
create or replace function public.fn_mark_attendance(
  p_date date, p_marks jsonb, p_reason text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_actor  uuid := auth.uid();
  v_total  integer;
  v_marked integer;
  v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
begin
  if not public.has_role('owner','principal','admin_clerk','class_teacher','subject_teacher') then
    raise exception 'Not permitted to mark attendance';
  end if;
  if p_marks is null or jsonb_typeof(p_marks) <> 'array' then
    raise exception 'p_marks must be a JSON array';
  end if;

  -- Tenant scope: every enrolment must be in THIS school. Checked for all
  -- roles, because the teacher-scope check below is skipped for admins —
  -- leaving them able to mark attendance against another school's enrolment ids.
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
    insert into public.attendance_daily as ad
      (enrollment_id, attendance_date, status, marked_by)
    select enrollment_id, p_date, status, v_actor from input
    on conflict (enrollment_id, attendance_date) do update
      set status = excluded.status,
          marked_by = excluded.marked_by,
          corrected_from = case when ad.status is distinct from excluded.status
                                then ad.status else ad.corrected_from end,
          correction_reason = case when ad.status is distinct from excluded.status
                                   then v_reason else ad.correction_reason end
      where not ad.is_locked
    returning 1
  )
  select count(*) into v_marked from upserted;

  return jsonb_build_object('marked', v_marked, 'skipped', v_total - v_marked, 'total', v_total);
end;
$$;

-- ---------------------------------------------------------------------------
-- 4. The read path that did not exist
--
-- Every mark that has been changed since it was first entered, across exams and
-- class tests, with what it was, what it is, who changed it and why. This is
-- the answer to "my son got 45, you have written 40", and it is the report a
-- head teacher wants the week before results go out.
--
-- Owner and principal only. This is an oversight tool, and the person most
-- likely to want it hidden is the person who changed the mark.
-- ---------------------------------------------------------------------------
create or replace function public.fn_mark_corrections(
  p_from date default null, p_to date default null)
returns table (
  changed_at timestamptz, kind text, student_name text, gr_no text,
  class_name text, section_name text, subject_name text, paper text,
  was numeric, now_is numeric, max_marks numeric, is_absent boolean,
  reason text, changed_by text, is_locked boolean)
language plpgsql stable security definer set search_path = public as $$
declare v_school uuid := public.current_school_id();
begin
  if not public.has_role('owner', 'principal') then
    raise exception 'Only the owner or principal may review mark corrections'
      using errcode = '42501';
  end if;

  return query
  select
    me.updated_at,
    case when me.exam_subject_id is not null then 'Exam' else 'Class test' end,
    s.full_name, s.gr_no, c.name, sec.name,
    coalesce(subj_x.name, subj_a.name),
    coalesce(et.name, a.title),
    me.corrected_from, me.marks, me.max_marks, me.is_absent,
    me.correction_reason,
    coalesce(p.full_name, '—'),
    me.is_locked
  from public.mark_entries me
  join public.enrollments en on en.id = me.enrollment_id and en.school_id = v_school
  join public.students s on s.id = en.student_id and s.school_id = v_school
  left join public.classes c on c.id = en.class_id and c.school_id = v_school
  left join public.sections sec on sec.id = en.section_id and sec.school_id = v_school
  left join public.exam_subjects es on es.id = me.exam_subject_id and es.school_id = v_school
  left join public.exam_terms et on et.id = es.exam_term_id and et.school_id = v_school
  left join public.subjects subj_x on subj_x.id = es.subject_id and subj_x.school_id = v_school
  left join public.assessments a on a.id = me.assessment_id and a.school_id = v_school
  left join public.subjects subj_a on subj_a.id = a.subject_id and subj_a.school_id = v_school
  left join public.profiles p on p.id = me.marked_by
  where me.school_id = v_school
    -- corrected_from is only set when a mark actually changed, so its presence
    -- IS the definition of a correction.
    and me.corrected_from is not null
    and (p_from is null or me.updated_at::date >= p_from)
    and (p_to   is null or me.updated_at::date <= p_to)
  order by me.updated_at desc;
end;
$$;

-- Attendance changes. Lower stakes than marks, but the same principle: an
-- attendance record altered after the fact, with no reason, is how a disputed
-- absence becomes unanswerable.
create or replace function public.fn_attendance_corrections(
  p_from date default null, p_to date default null)
returns table (
  changed_at timestamptz, attendance_date date, student_name text, gr_no text,
  class_name text, section_name text, was text, now_is text,
  reason text, changed_by text)
language plpgsql stable security definer set search_path = public as $$
declare v_school uuid := public.current_school_id();
begin
  if not public.has_role('owner', 'principal') then
    raise exception 'Only the owner or principal may review attendance corrections'
      using errcode = '42501';
  end if;

  return query
  select
    ad.updated_at, ad.attendance_date, s.full_name, s.gr_no, c.name, sec.name,
    ad.corrected_from::text, ad.status::text,
    ad.correction_reason, coalesce(p.full_name, '—')
  from public.attendance_daily ad
  join public.enrollments en on en.id = ad.enrollment_id and en.school_id = v_school
  join public.students s on s.id = en.student_id and s.school_id = v_school
  left join public.classes c on c.id = en.class_id and c.school_id = v_school
  left join public.sections sec on sec.id = en.section_id and sec.school_id = v_school
  left join public.profiles p on p.id = ad.marked_by
  where ad.school_id = v_school
    and ad.corrected_from is not null
    and (p_from is null or ad.updated_at::date >= p_from)
    and (p_to   is null or ad.updated_at::date <= p_to)
  order by ad.updated_at desc;
end;
$$;

-- ---------------------------------------------------------------------------
-- 5. Grants. The three entry functions were granted under their old
--    two-argument signatures, which no longer exist.
-- ---------------------------------------------------------------------------
grant execute on function public.fn_enter_marks(uuid, jsonb, text) to authenticated;
grant execute on function public.fn_enter_assessment_marks(uuid, jsonb, text) to authenticated;
grant execute on function public.fn_mark_attendance(date, jsonb, text) to authenticated;
grant execute on function public.fn_mark_corrections(date, date) to authenticated;
grant execute on function public.fn_attendance_corrections(date, date) to authenticated;

revoke all on function public.fn_enter_marks(uuid, jsonb, text) from anon;
revoke all on function public.fn_enter_assessment_marks(uuid, jsonb, text) from anon;
revoke all on function public.fn_mark_attendance(date, jsonb, text) from anon;
revoke all on function public.fn_mark_corrections(date, date) from anon;
revoke all on function public.fn_attendance_corrections(date, date) from anon;

-- ─────────────────────────────────────────────────────────────────────────
-- 0049_remarks_and_positions.sql
-- ─────────────────────────────────────────────────────────────────────────
-- =============================================================================
-- 0049 — Teacher remarks, and a position-holders screen.
--
-- Item 7 of the build order in docs/PARITY.md. Two things their software has and
-- ours did not:
--
--   Teacher Remarks   `missing` — nothing in the schema stored one at all.
--   Position Holders  `partial` — position is computed and printed on the result
--                     card and the tabulation sheet, but there was no "top three
--                     in each class" view, which is what a prize distribution
--                     and the notice board actually need.
--
-- WHY REMARKS ARE NOT A COLUMN ON result_cards
--
-- The obvious place for a remark is result_cards.teacher_remark. That would be a
-- trap. fn_generate_result_cards does not update rows — it INSERTS a new one
-- with version + 1 every time it runs. So a remark written on version 1 would
-- silently vanish from the printed card the moment anybody regenerated the
-- class, and the teacher would have no idea it had gone.
--
-- Keying the remark on (exam_term_id, student_id) instead makes it immune:
-- regeneration cannot touch it, however many versions are produced, and nothing
-- in fn_generate_result_cards needs changing.
--
-- POSITION AND TIES
--
-- fn_generate_result_cards already uses rank(), not row_number(), so two
-- children on the same percentage genuinely SHARE a position and the next one
-- down is third. That is the right behaviour for a prize-giving, and the
-- position-holders view preserves it: if three children tie for first, all
-- three are listed as first.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. The remark
--
-- One per student per exam term, not per result card version. `remark_by` and
-- `updated_at` matter: a remark is a signed opinion that goes home to a parent,
-- and "who wrote this" is the first question when one is disputed.
-- ---------------------------------------------------------------------------
create table if not exists public.exam_remarks (
  id            uuid primary key default gen_random_uuid(),
  school_id     uuid not null references public.schools(id) on delete cascade,
  exam_term_id  uuid not null references public.exam_terms(id) on delete cascade,
  student_id    uuid not null references public.students(id) on delete cascade,
  remark        text not null,
  remark_by     uuid references public.profiles(id),
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  constraint uq_exam_remark unique (school_id, exam_term_id, student_id)
);

create index if not exists idx_exam_remarks_term
  on public.exam_remarks (school_id, exam_term_id);

do $$
begin
  if not exists (select 1 from pg_trigger
                 where tgname = 'trg_exam_remarks_school'
                   and tgrelid = 'public.exam_remarks'::regclass) then
    create trigger trg_exam_remarks_school before insert or update
      on public.exam_remarks for each row execute function public.enforce_school_id();
  end if;
  if not exists (select 1 from pg_trigger
                 where tgname = 'trg_audit_exam_remarks'
                   and tgrelid = 'public.exam_remarks'::regclass) then
    create trigger trg_audit_exam_remarks after insert or update or delete
      on public.exam_remarks for each row execute function public.audit_trigger();
  end if;
end $$;

alter table public.exam_remarks enable row level security;

-- Staff may read remarks for their own school. Writes go through the function
-- below so the class-teacher scope is enforced in one place.
drop policy if exists exam_remarks_select on public.exam_remarks;
create policy exam_remarks_select on public.exam_remarks for select to authenticated
  using (school_id = public.current_school_id() and public.is_staff());

-- ---------------------------------------------------------------------------
-- 2. Write a remark
--
-- A class teacher may write one for their own class, which is the whole point —
-- the remark is theirs. Owner, principal and clerk may write any. A SUBJECT
-- teacher may not: they see one subject, and the remark on a report card is a
-- judgement about the whole child.
-- ---------------------------------------------------------------------------
create or replace function public.fn_set_exam_remark(
  p_exam_term_id uuid, p_student_id uuid, p_remark text)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_school uuid := public.current_school_id();
  v_term   record;
  v_enr    record;
  v_text   text := nullif(btrim(coalesce(p_remark, '')), '');
begin
  if not public.is_staff() then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  perform public.assert_own('exam_terms', p_exam_term_id);
  perform public.assert_own('students', p_student_id);

  select * into v_term from public.exam_terms
  where id = p_exam_term_id and school_id = v_school;
  if not found then raise exception 'Exam term not found'; end if;
  -- A locked term is a published result. Editing the remark afterwards changes
  -- what a parent was already shown.
  if v_term.is_locked then
    raise exception 'This exam term is locked; the remark can no longer be changed';
  end if;

  select e.* into v_enr from public.enrollments e
  where e.student_id = p_student_id and e.session_id = v_term.session_id
    and e.school_id = v_school and e.status = 'active'
  limit 1;
  if not found then
    raise exception 'That student is not enrolled in this exam term''s session';
  end if;

  if not public.has_role('owner', 'principal', 'admin_clerk') then
    if not public.fn_may_manage_class(v_enr.session_id, v_enr.class_id, v_enr.section_id) then
      raise exception 'You can only write remarks for your own class'
        using errcode = '42501';
    end if;
    -- fn_may_manage_class is true for a subject teacher assigned to the class,
    -- so the role itself has to be excluded: a remark is a judgement about the
    -- whole child, and a subject teacher sees one subject.
    if public.has_role('subject_teacher') and not public.has_role('class_teacher') then
      raise exception 'Only the class teacher writes the report-card remark'
        using errcode = '42501';
    end if;
  end if;

  -- Blank means "remove it", rather than storing an empty string that prints as
  -- a mysterious gap on the card.
  if v_text is null then
    delete from public.exam_remarks
    where school_id = v_school and exam_term_id = p_exam_term_id
      and student_id = p_student_id;
    return;
  end if;

  insert into public.exam_remarks (school_id, exam_term_id, student_id, remark, remark_by)
  values (v_school, p_exam_term_id, p_student_id, v_text, auth.uid())
  on conflict (school_id, exam_term_id, student_id) do update
    set remark = excluded.remark,
        remark_by = excluded.remark_by,
        updated_at = now();
end;
$$;

-- ---------------------------------------------------------------------------
-- 3. The class list a teacher fills in
--
-- Every student in the class, with the remark if there is one — not only the
-- ones already written. A screen that shows only existing remarks gives a
-- teacher no way to find the children they have not done yet.
-- ---------------------------------------------------------------------------
create or replace function public.fn_exam_remarks(p_exam_term_id uuid, p_class_id uuid)
-- `class_position`, not `position`: the latter is a reserved word in a
-- `returns table` list (Postgres reads it as the position(x in y) function), and
-- the longer name says what it actually means anyway.
returns table (
  student_id uuid, student_name text, gr_no text, roll_no text,
  section_name text, remark text, remark_by_name text, updated_at timestamptz,
  percentage numeric, grade text, class_position int)
language plpgsql stable security definer set search_path = public as $$
declare
  v_school  uuid := public.current_school_id();
  v_session uuid;
begin
  if not public.is_staff() then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  perform public.assert_own('exam_terms', p_exam_term_id);
  perform public.assert_own('classes', p_class_id);

  select session_id into v_session from public.exam_terms
  where id = p_exam_term_id and school_id = v_school;
  if v_session is null then raise exception 'Exam term not found'; end if;

  return query
  select s.id, s.full_name, s.gr_no, e.roll_no, sec.name,
         r.remark, coalesce(p.full_name, '—'), r.updated_at,
         -- The teacher's own marks, alongside, because a remark written without
         -- seeing the result is a remark about nothing.
         rc.percentage, rc.grade, rc.position
  from public.enrollments e
  join public.students s on s.id = e.student_id and s.school_id = v_school
  left join public.sections sec on sec.id = e.section_id and sec.school_id = v_school
  left join public.exam_remarks r
         on r.exam_term_id = p_exam_term_id and r.student_id = s.id
        and r.school_id = v_school
  left join public.profiles p on p.id = r.remark_by
  -- The LATEST version only. Older versions are superseded and showing them
  -- beside a remark would put two different percentages on one row.
  left join lateral (
    select c.percentage, c.grade, c.position
    from public.result_cards c
    where c.enrollment_id = e.id and c.exam_term_id = p_exam_term_id
      and c.school_id = v_school
    order by c.version desc
    limit 1
  ) rc on true
  where e.school_id = v_school and e.session_id = v_session
    and e.class_id = p_class_id and e.status = 'active'
  order by e.roll_no nulls last, s.full_name;
end;
$$;

-- ---------------------------------------------------------------------------
-- 4. Position holders
--
-- Top N in every class for one exam term, which is what a prize distribution
-- and the notice board need. Ties are preserved: three children tied for first
-- are all first, and the next is fourth — rank() semantics, matching what is
-- already printed on the result cards so the two can never disagree.
--
-- `withheld` is carried through deliberately. A school about to announce a
-- position holder whose fees are unpaid, and whose result is therefore withheld,
-- needs to know BEFORE the announcement rather than after.
-- ---------------------------------------------------------------------------
create or replace function public.fn_position_holders(
  p_exam_term_id uuid, p_top int default 3)
returns table (
  class_id uuid, class_name text, level_order int,
  class_position int, student_id uuid, student_name text, gr_no text,
  roll_no text, section_name text,
  total_marks numeric, total_max numeric, percentage numeric, grade text,
  withheld boolean, remark text, tied_with int)
language plpgsql stable security definer set search_path = public as $$
declare
  v_school  uuid := public.current_school_id();
  v_session uuid;
  v_top     int := greatest(coalesce(p_top, 3), 1);
begin
  if not public.is_staff() then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  perform public.assert_own('exam_terms', p_exam_term_id);

  select session_id into v_session from public.exam_terms
  where id = p_exam_term_id and school_id = v_school;
  if v_session is null then raise exception 'Exam term not found'; end if;

  return query
  with latest as (
    -- One row per student: the newest result-card version for this term.
    -- Mixing versions would rank a student's old total against another's new
    -- one, which is the sort of thing nobody notices until prize day.
    select distinct on (rc.enrollment_id)
           rc.enrollment_id, rc.student_id, rc.total_marks, rc.total_max,
           rc.percentage, rc.grade, rc.position, rc.frozen
    from public.result_cards rc
    where rc.exam_term_id = p_exam_term_id and rc.school_id = v_school
    order by rc.enrollment_id, rc.version desc
  ),
  with_class as (
    select l.*, e.class_id, e.section_id, e.roll_no
    from latest l
    join public.enrollments e on e.id = l.enrollment_id and e.school_id = v_school
    where e.session_id = v_session and e.status = 'active'
  ),
  counted as (
    -- How many share this position in this class. A "1" that is really a
    -- three-way tie should say so on the notice.
    select w.*, count(*) over (partition by w.class_id, w.position) as tied
    from with_class w
  )
  select c.class_id, cl.name, cl.level_order,
         c.position, c.student_id, s.full_name, s.gr_no,
         c.roll_no, sec.name,
         c.total_marks, c.total_max, c.percentage, c.grade,
         coalesce((c.frozen->>'withheld')::boolean, false),
         r.remark,
         c.tied::int
  from counted c
  join public.students s on s.id = c.student_id and s.school_id = v_school
  join public.classes cl on cl.id = c.class_id and cl.school_id = v_school
  left join public.sections sec on sec.id = c.section_id and sec.school_id = v_school
  left join public.exam_remarks r
         on r.exam_term_id = p_exam_term_id and r.student_id = c.student_id
        and r.school_id = v_school
  where c.position is not null
    and c.position <= v_top
    -- A child who was never marked at all must not be a position holder, and
    -- `percentage` cannot tell you: fn_generate_result_cards coalesces the mark
    -- sum to 0, so "never entered" and "sat and scored nothing" both come out as
    -- 0.00. In a small class — and senior classes here can be tiny — that would
    -- put a child with no marks to their name inside the top three.
    --
    -- So the distinction is drawn where it actually exists: does the child have
    -- ANY mark row for this term? A child who sat and scored zero does have one,
    -- and stays in the ranking, because they are genuinely part of the order.
    and exists (
      select 1
      from public.mark_entries me
      join public.exam_subjects es2 on es2.id = me.exam_subject_id
      where me.enrollment_id = c.enrollment_id
        and me.school_id = v_school
        and es2.exam_term_id = p_exam_term_id
    )
  order by cl.level_order, cl.name, c.position, s.full_name;
end;
$$;

-- ---------------------------------------------------------------------------
-- 5. Grants
-- ---------------------------------------------------------------------------
grant execute on function public.fn_set_exam_remark(uuid, uuid, text) to authenticated;
grant execute on function public.fn_exam_remarks(uuid, uuid) to authenticated;
grant execute on function public.fn_position_holders(uuid, int) to authenticated;

revoke all on function public.fn_set_exam_remark(uuid, uuid, text) from anon;
revoke all on function public.fn_exam_remarks(uuid, uuid) from anon;
revoke all on function public.fn_position_holders(uuid, int) from anon;

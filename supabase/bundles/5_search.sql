-- =============================================================================
-- GENERATED FILE — DO NOT EDIT.
-- Built from supabase/migrations/ by supabase/build-bundles.sh
--
-- Paste this whole file into the Supabase SQL Editor and press Run.
-- Run the bundles in order, one at a time, waiting for each to finish.
-- =============================================================================


-- ─────────────────────────────────────────────────────────────────────────
-- 0050_search_and_birthdays.sql
-- ─────────────────────────────────────────────────────────────────────────
-- =============================================================================
-- 0050 — Global search, and birthdays.
--
-- Item 11 of the build order, minus the photo half, which needs Supabase
-- Storage and cannot be tested from here.
--
-- WHY SEARCH MATTERS MORE THAN IT SOUNDS
--
-- The complaint that started this rebuild was that screens "open as empty search
-- boxes" — that finding anything meant knowing which of twenty modules held it
-- first. Their header has one box, "Search Student / Teacher / Parent here…",
-- reachable from anywhere. A clerk with a parent on the phone saying "I am
-- Bilal's father" should not have to decide whether that is a Students
-- question, a Families question or a Fee question.
--
-- So this searches ACROSS entities in one call and says where each hit lives.
--
-- ROLE-AWARE RATHER THAN ALL-OR-NOTHING
--
-- A class teacher should be able to find a pupil. They have no business in the
-- family ledger or the receipt book. Refusing the whole search to a teacher
-- would be as wrong as showing them everything, so each branch below carries
-- its own role test and a teacher simply gets fewer kinds of result.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. Staff need a date of birth before staff birthdays can exist
--
-- students.dob has always been there. staff had joined_on and left_on and no
-- date of birth at all, so "wish the teachers a happy birthday" — a screen
-- their software has — was not expressible.
--
-- Added and wired in the same commit, in the staff form and the CSV importer,
-- so it does not become another column nothing writes. That is precisely what
-- supabase/check-columns-used.sh now fails the build for.
-- ---------------------------------------------------------------------------
alter table public.staff add column if not exists dob date;

-- ---------------------------------------------------------------------------
-- 2. Global search
--
-- One term, several kinds of record, ordered so that an exact identifier match
-- comes first. `route` is returned so the UI can navigate without a lookup
-- table of its own that would drift from this list.
-- ---------------------------------------------------------------------------
create or replace function public.fn_global_search(
  p_term text, p_limit int default 20)
returns table (
  kind text, id uuid, title text, subtitle text, detail text,
  route text, exact boolean)
language plpgsql stable security definer set search_path = public as $$
declare
  v_school uuid := public.current_school_id();
  v_term   text := nullif(btrim(coalesce(p_term, '')), '');
  v_like   text;
  v_lim    int  := least(greatest(coalesce(p_limit, 20), 1), 100);
  v_digits text;
  v_fuzzy  boolean;
begin
  if not public.is_staff() then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  if v_term is null then return; end if;

  -- Backslash FIRST, then the wildcards, or the escapes get escaped. Getting
  -- this wrong in 0041 meant searching "%" returned the whole school.
  -- ONE backslash per escape, not two. standard_conforming_strings is ON in
  -- Postgres, so '\\' in SQL source is TWO backslash characters — which turns
  -- the pattern for "%" into "contains a literal backslash". That returns
  -- nothing, which LOOKS right, but it is right for the wrong reason: a name
  -- genuinely containing "%" is then unfindable, and a GR number like GR_001
  -- cannot be searched for either. Verified empirically, not by reading.
  v_like := '%' || replace(replace(replace(v_term, '\', '\\'),
                                   '%', '\%'), '_', '\_') || '%';
  -- Phone numbers get typed with dashes and spaces in every combination, so a
  -- digits-only comparison is the only one that reliably matches.
  v_digits := nullif(regexp_replace(v_term, '[^0-9]', '', 'g'), '');

  -- Two characters is the floor for the FUZZY branches: a single character
  -- matches most of the school and makes the box feel broken rather than fast.
  --
  -- Exact numeric lookups are exempt, and deliberately so — a receipt or
  -- enquiry numbered 1 to 9 would otherwise be permanently unfindable, which is
  -- every receipt a school writes on its first day.
  v_fuzzy := length(v_term) >= 2;
  if not v_fuzzy and v_digits is null then return; end if;

  -- The union is wrapped so the ordering can use an expression: a UNION's own
  -- ORDER BY accepts only output column names, not a CASE.
  return query
  with hits as (
  -- ---- students: everybody who can see the school may find a pupil ----
  select 'student'::text as kind, s.id, s.full_name as title,
         coalesce(c.name, 'Not enrolled')
           || case when e.roll_no is not null then ' · Roll ' || e.roll_no else '' end
           as subtitle,
         'GR ' || coalesce(s.gr_no, '—')
           || case when s.father_name is not null then ' · ' || s.father_name else '' end
           as detail,
         '/students'::text as route,
         -- coalesce is load-bearing: b_form is often NULL, so `false or NULL`
         -- is NULL, and `order by exact desc` puts NULLs FIRST in Postgres —
         -- which would sort a real GR-number match BEHIND the fuzzy ones and
         -- defeat the whole point of the ordering.
         coalesce(s.gr_no = v_term or s.b_form = v_term, false) as exact
  from public.students s
  left join public.enrollments e
         on e.student_id = s.id and e.status = 'active' and e.school_id = v_school
  left join public.classes c on c.id = e.class_id and c.school_id = v_school
  where s.school_id = v_school and s.deleted_at is null
    and ((v_fuzzy and (s.full_name ilike v_like
      or coalesce(s.gr_no, '') ilike v_like
      or coalesce(s.father_name, '') ilike v_like
      or coalesce(s.b_form, '') ilike v_like))
      or (v_digits is not null and length(v_digits) >= 4
          and regexp_replace(coalesce(s.phone, ''), '[^0-9]', '', 'g') like '%' || v_digits || '%'))

  union all
  -- ---- staff ----
  select 'staff', st.id, st.full_name,
         coalesce(st.designation, 'Staff'),
         case when st.employee_no is not null then '#' || st.employee_no else '' end
           || case when st.mobile is not null then ' · ' || st.mobile else '' end,
         '/staff', coalesce(st.employee_no = v_term or st.cnic = v_term, false)
  from public.staff st
  where st.school_id = v_school and st.deleted_at is null
    and public.has_role('owner', 'principal', 'admin_clerk', 'accountant')
    and ((v_fuzzy and (st.full_name ilike v_like
      or coalesce(st.employee_no, '') ilike v_like
      or coalesce(st.cnic, '') ilike v_like))
      or (v_digits is not null and length(v_digits) >= 4
          and regexp_replace(coalesce(st.mobile, ''), '[^0-9]', '', 'g') like '%' || v_digits || '%'))

  union all
  -- ---- families: the "I am Bilal's father" case ----
  -- Money-adjacent, so office and finance only. A teacher has no business in
  -- the family ledger.
  select 'family', f.id, coalesce(f.head_name, 'Family'),
         coalesce(nullif((select string_agg(s2.full_name, ', ' order by s2.full_name)
                          from public.students s2
                          where s2.family_id = f.id and s2.deleted_at is null), ''),
                  'No children linked'),
         coalesce(f.head_cnic, '') || case when f.phone is not null then ' · ' || f.phone else '' end,
         '/families', coalesce(f.head_cnic = v_term, false)
  from public.families f
  where f.school_id = v_school
    and public.has_role('owner', 'principal', 'admin_clerk', 'accountant')
    and ((v_fuzzy and (coalesce(f.head_name, '') ilike v_like
      or coalesce(f.head_cnic, '') ilike v_like))
      or (v_digits is not null and length(v_digits) >= 4
          and regexp_replace(coalesce(f.phone, ''), '[^0-9]', '', 'g') like '%' || v_digits || '%'))

  union all
  -- ---- a printed challan, by its voucher code ----
  -- The code on the slip a parent hands over. Exact only: a partial voucher
  -- match is meaningless and would bury the real answers.
  select 'challan', i.id,
         'Challan ' || i.voucher_code,
         coalesce(s.full_name, 'Unknown student')
           || ' · ' || to_char(i.period_month, 'Mon YYYY'),
         initcap(i.status::text)
           || case when i.due_date is not null
                   then ' · due ' || to_char(i.due_date, 'DD Mon') else '' end,
         '/fees', true
  from public.invoices i
  left join public.students s on s.id = i.student_id and s.school_id = v_school
  where i.school_id = v_school
    and public.has_role('owner', 'principal', 'admin_clerk', 'accountant')
    and i.voucher_code is not null
    and upper(i.voucher_code) = upper(v_term)

  union all
  -- ---- a receipt, by its number ----
  select 'receipt', p.id,
         'Receipt #' || p.receipt_no,
         coalesce(s.full_name, fam.head_name, 'Unknown payer'),
         trim(to_char(p.amount, 'FM999,999,990')) || ' · ' || to_char(p.created_at, 'DD Mon YYYY'),
         '/fees', true
  from public.payments p
  left join public.students s on s.id = p.student_id and s.school_id = v_school
  left join public.families fam on fam.id = p.family_id and fam.school_id = v_school
  where p.school_id = v_school
    and public.has_role('owner', 'principal', 'admin_clerk', 'accountant')
    and v_digits is not null and p.receipt_no::text = v_digits

  union all
  -- ---- an admission enquiry ----
  select 'enquiry', en.id, en.child_name,
         'Enquiry #' || en.enquiry_no || ' · ' || en.status::text,
         coalesce(en.father_name, '') || case when en.phone is not null
                                              then ' · ' || en.phone else '' end,
         '/enquiries', coalesce(en.enquiry_no::text = v_digits, false)
  from public.admission_enquiries en
  where en.school_id = v_school
    and public.has_role('owner', 'principal', 'admin_clerk')
    and ((v_fuzzy and (en.child_name ilike v_like
      or coalesce(en.father_name, '') ilike v_like))
      or en.enquiry_no::text = v_digits
      or (v_digits is not null and length(v_digits) >= 4
          and regexp_replace(coalesce(en.phone, ''), '[^0-9]', '', 'g') like '%' || v_digits || '%'))

  )
  -- An exact identifier match is almost always what was typed, so it goes
  -- first. After that, students before everything else: they are what a school
  -- looks up all day.
  select h.kind, h.id, h.title, h.subtitle, h.detail, h.route, h.exact
  from hits h
  order by h.exact desc,
           case h.kind when 'student' then 0 when 'family' then 1 when 'challan' then 2
                       when 'receipt' then 3 when 'staff' then 4 else 5 end,
           h.title
  limit v_lim;
end;
$$;

-- ---------------------------------------------------------------------------
-- 3. Birthdays
--
-- Students and staff together, because the school wishes both. Matched on month
-- and day so the year is irrelevant, and `turning` is computed so a card can say
-- "turning 12" rather than making somebody do the arithmetic.
--
-- `days_away` lets one call serve "today", "this week" and "this month" without
-- three functions that could disagree.
-- ---------------------------------------------------------------------------
create or replace function public.fn_birthdays(p_within_days int default 0)
returns table (
  kind text, id uuid, full_name text, dob date, turning int,
  birthday date, days_away int, class_name text, detail text, phone text)
language plpgsql stable security definer set search_path = public as $$
declare
  v_school uuid := public.current_school_id();
  v_within int := least(greatest(coalesce(p_within_days, 0), 0), 366);
begin
  if not public.is_staff() then
    raise exception 'Not permitted' using errcode = '42501';
  end if;

  return query
  with people as (
    select 'student'::text as kind, s.id, s.full_name, s.dob,
           coalesce(c.name, 'Not enrolled') as class_name,
           coalesce(s.father_name, '') as detail,
           coalesce(nullif(s.whatsapp, ''), s.phone) as phone
    from public.students s
    left join public.enrollments e
           on e.student_id = s.id and e.status = 'active' and e.school_id = v_school
    left join public.classes c on c.id = e.class_id and c.school_id = v_school
    where s.school_id = v_school and s.deleted_at is null
      and s.status = 'active' and s.dob is not null

    union all

    select 'staff', st.id, st.full_name, st.dob,
           coalesce(st.designation, 'Staff'),
           coalesce(st.employee_no, ''),
           coalesce(nullif(st.whatsapp, ''), st.mobile)
    from public.staff st
    where st.school_id = v_school and st.deleted_at is null
      and st.status = 'active' and st.dob is not null
      -- Staff records are personnel data; the office sees them, teachers do not.
      and public.has_role('owner', 'principal', 'admin_clerk')
  ),
  dated as (
    select p.*,
           -- This year's occurrence, rolled forward if it has already gone.
           -- 29 February in a non-leap year has no make_date, so it is nudged
           -- to the 28th rather than throwing.
           case
             when extract(month from p.dob) = 2 and extract(day from p.dob) = 29
                  and not (
                    (extract(year from current_date)::int % 4 = 0
                     and extract(year from current_date)::int % 100 <> 0)
                    or extract(year from current_date)::int % 400 = 0)
             then make_date(extract(year from current_date)::int, 2, 28)
             else make_date(extract(year from current_date)::int,
                            extract(month from p.dob)::int,
                            extract(day from p.dob)::int)
           end as this_year
    from people p
  ),
  rolled as (
    select d.*,
           case when d.this_year >= current_date
                then d.this_year
                else (d.this_year + interval '1 year')::date end as next_bd
    from dated d
  )
  select r.kind, r.id, r.full_name, r.dob,
         -- Age they are turning ON that birthday.
         (extract(year from r.next_bd) - extract(year from r.dob))::int,
         r.next_bd,
         (r.next_bd - current_date)::int,
         r.class_name, r.detail, r.phone
  from rolled r
  where (r.next_bd - current_date)::int <= v_within
  order by r.next_bd, r.full_name;
end;
$$;

-- ---------------------------------------------------------------------------
-- 4. Grants
-- ---------------------------------------------------------------------------
grant execute on function public.fn_global_search(text, int) to authenticated;
grant execute on function public.fn_birthdays(int) to authenticated;

revoke all on function public.fn_global_search(text, int) from anon;
revoke all on function public.fn_birthdays(int) from anon;

-- ─────────────────────────────────────────────────────────────────────────
-- 0051_like_escaping.sql
-- ─────────────────────────────────────────────────────────────────────────
-- =============================================================================
-- 0051 — fn_student_list could not find an underscore or a percent sign.
--
-- WHAT WAS WRONG
--
-- 0041 escapes the search term before using it in a LIKE, written as
--
--     replace(replace(replace(v_term, '\\', '\\\\'), '%', '\\%'), '_', '\\_')
--
-- Postgres runs with standard_conforming_strings = on, so a backslash inside a
-- string literal is NOT an escape character: '\\' is TWO backslash characters,
-- not one. So the pattern built for a term containing "_" comes out demanding a
-- LITERAL BACKSLASH before the underscore, which no real value has.
--
-- Demonstrated on identical data, same term:
--
--     fn_student_list('Under_Score')   ->  0 rows
--     fn_global_search('Under_Score')  ->  1 row
--
-- So a pupil whose name or roll number contains an underscore — "A_1" is an
-- ordinary roll number, and imported CSVs transliterate names with them —
-- simply could not be found in the student roster. Same for a percent sign, and
-- for a backslash.
--
-- WHY THE TEST DID NOT CATCH IT
--
-- student_list.sql asserts that searching "%" must not return the whole school,
-- and it does not — but for the wrong reason. Over-escaped, the pattern demands
-- a backslash and matches nothing, which looks identical to correct escaping
-- from the outside. The assertion was true and useless. student_list.sql now
-- also admits a child whose roll number contains an underscore and requires
-- that searching for it FINDS them, which the old code fails.
--
-- This is the opposite of a wildcard-injection hole: the term was over-escaped,
-- never under-escaped, so nothing was ever exposed. It is a search that silently
-- failed on a class of legitimate input.
--
-- WHY A FORWARD MIGRATION RATHER THAN EDITING 0041
--
-- Editing 0041 in place fixes a fresh install and does nothing for a database
-- that has already applied it. Bundle 4 is being installed right now, so this is
-- the only version that fixes both.
--
-- 0046's fn_enquiry_list was checked and is already correct — it was written
-- with single backslashes. Only this one function was affected.
--
-- The body below is the LIVE definition with only the escaping expression
-- changed, so nothing else about the function can drift in the copying.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.fn_student_list(p_term text DEFAULT NULL::text, p_class_id uuid DEFAULT NULL::uuid, p_section_id uuid DEFAULT NULL::uuid, p_include_inactive boolean DEFAULT false, p_limit integer DEFAULT 50, p_offset integer DEFAULT 0)
 RETURNS TABLE(student_id uuid, full_name text, gr_no text, admission_no text, father_name text, gender text, phone text, status text, class_name text, section_name text, roll_no text, family_id uuid, balance numeric, total_count bigint)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
                      replace(replace(replace(v_term, '\', '\\'), '%', '\%'), '_', '\_')
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
$function$;

-- The semicolon matters. pg_get_functiondef() — which this body was copied from,
-- so that nothing could drift — emits NO trailing terminator. On its own the file
-- still applies, because psql flushes whatever is left in the buffer at EOF. But
-- supabase/bundles/ CONCATENATES the migrations, so without it this
-- function's closing $function$ ran straight into the next migration's CREATE
-- and bundle 5 died with "syntax error at or near CREATE".
--
-- Caught by CI's "bundles apply as single transactions" step, which exists for
-- exactly this: a migration can be perfectly valid alone and invalid in the
-- artefact a school actually pastes.

-- ─────────────────────────────────────────────────────────────────────────
-- 0052_recent_payments_order.sql
-- ─────────────────────────────────────────────────────────────────────────
-- =============================================================================
-- 0052 — Give the fee counter's "Latest payments" list a stable order.
--
-- WHAT WAS WRONG
--
-- fn_recent_payments ended `order by p.created_at desc` with no tie-break. In
-- Postgres now() is TRANSACTION-stable: every payment taken inside one
-- transaction shares a created_at to the microsecond. Two receipts written in
-- the same transaction — which is exactly what fn_record_bulk_payments does for
-- a whole class — therefore had no defined order between them, and the list
-- could reshuffle between one page load and the next.
--
-- For a clerk sitting on this screen all morning during the first ten days of a
-- month, a list that reorders itself is a list they stop trusting. And it is
-- worse than cosmetic: "the top row is the payment I just took" is the
-- assumption the screen invites, and without a tie-break that assumption is
-- sometimes wrong.
--
-- HOW IT SURFACED
--
-- counter.sql asserted `class_name = 'Class 1'` on `limit 1` — the first row. It
-- passed in the forward run and failed in the reverse one, because with equal
-- timestamps the row returned first depends on physical heap order, which
-- differs according to what ran before. The reverse-order CI pass exists
-- precisely to find this, and it did — on merged main.
--
-- Two fixes, because there were two faults: the function now has a deterministic
-- order (here), and the test no longer leans on the order at all (counter.sql
-- assertions 14-16c).
--
-- The body below is the LIVE definition with ONLY the ORDER BY changed, so
-- nothing else about the function can drift in the copying. Written by hand the
-- first time, the return type was invented and Postgres rejected it outright —
-- "cannot change return type of existing function" — which is a good reason to
-- copy rather than retype a 19-column signature.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.fn_recent_payments(p_limit integer DEFAULT 25)
 RETURNS TABLE(payment_id uuid, receipt_no bigint, paid_at timestamp with time zone, student_id uuid, student_name text, gr_no text, family_id uuid, parent_name text, class_name text, section_name text, paid_for text, amount numeric, method payment_method, late_fee numeric, discount numeric, note text, status text, received_by text, is_reversal boolean)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
  -- receipt_no is the tie-break, and it has to be here: now() is
  -- transaction-stable, so every payment taken in ONE transaction shares a
  -- created_at to the microsecond and the order between them was undefined.
  -- The receipt number is gapless, rises with time, and is the number printed on
  -- the slip in the parent's hand.
  order by p.created_at desc, p.receipt_no desc
  limit greatest(1, least(coalesce(p_limit, 25), 200));
end;
$function$;

-- The semicolon matters. pg_get_functiondef() — which this body was copied from,
-- so that nothing could drift — emits NO trailing terminator. On its own the file
-- still applies, because psql flushes whatever is left in the buffer at EOF. But
-- supabase/bundles/ CONCATENATES the migrations, so without it this
-- function's closing $function$ ran straight into the next migration's CREATE
-- and bundle 5 died with "syntax error at or near CREATE".
--
-- Caught by CI's "bundles apply as single transactions" step, which exists for
-- exactly this: a migration can be perfectly valid alone and invalid in the
-- artefact a school actually pastes.

-- ─────────────────────────────────────────────────────────────────────────
-- 0053_staff_leaving.sql
-- ─────────────────────────────────────────────────────────────────────────
-- =============================================================================
-- 0053 — When a member of staff leaves.
--
-- WHAT WAS WRONG
--
-- The staff screen had one button, "Deactivate", wired to a bare
-- `update staff set status = 'inactive'`. Three things followed from that, and
-- all three are the kind of thing a school discovers at the worst moment.
--
-- 1. IT DID NOT REVOKE THE LOGIN. Access in this system is gated on
--    profiles.active — current_school_id(), has_role() and is_staff() all read
--    it, and NOTHING anywhere reads staff.status. So a teacher who resigned,
--    was "deactivated" on the staff screen, and still had the app on their
--    phone could log in the next morning and mark attendance, enter marks and
--    read every child's record in their class. The button that looked like it
--    closed the door only greyed out a row.
--
--    Two switches existed: an obvious one that did nothing about access, and an
--    effective one (Settings → Users) that nobody would think to look for after
--    pressing the obvious one. That is worse than having only the hidden one.
--
-- 2. THE CLASS TEACHERS SCREEN THEN LIED. sections.class_teacher_id was left
--    pointing at the departed teacher — and it is what result cards print. The
--    Class Teachers screen builds its dropdown from ACTIVE staff only, so the
--    stored id matched no <option> and the select rendered "— unassigned —".
--    The screen therefore said the section had no class teacher while the
--    database still had one and the result card still printed their name. A
--    principal reading that screen has no way to find out.
--
-- 3. left_on WAS NEVER WRITTEN. The column has existed since 0001. Nothing set
--    it, so the school had no record of when anyone left — not on the screen,
--    not in a report, not in the audit log.
--
-- WHAT THIS DOES
--
-- Four functions, so that "this person has gone" is ONE action with a visible,
-- complete and reversible result:
--
--   fn_staff_leave            — record the leaving date, revoke the login,
--                               vacate the class-teacher slots, drop the
--                               current and future teaching assignments, and
--                               return a summary of exactly what it changed.
--   fn_staff_rejoin           — the undo, and the re-hire.
--   fn_staff_set_login_active — the access switch on its own, for suspension
--                               without leaving, and to clean up the legacy
--                               rows described below.
--   fn_staff_roster           — a read that can SEE the login state, which the
--                               screen previously could not: it selected from
--                               `staff` and never looked at `profiles`.
--
-- ABOUT THE LEGACY ROWS
--
-- Any staff row already marked 'inactive' by the old button is renamed to
-- 'left' here — same meaning, one spelling. Their logins are deliberately NOT
-- touched. Deactivating somebody's access from inside a migration is exactly
-- the sort of silent change that locks out a person who is still working, and
-- this migration cannot tell "resigned in March" from "clicked by mistake".
-- Instead fn_staff_roster reports login_active for people who have left, and
-- the screen shows it as a warning with a Revoke button. The school sees the
-- list and decides. left_on is left null for them, because inventing a date
-- would be a lie in a field a school may later rely on.
-- =============================================================================

-- --- One spelling for "not here any more" ------------------------------------
update public.staff set status = 'left' where status = 'inactive';

alter table public.staff drop constraint if exists staff_status_chk;
alter table public.staff add constraint staff_status_chk
  check (status in ('active', 'left'));

-- left_on only means anything for somebody who has left, and somebody who has
-- left with no date is a legacy row rather than a new mistake. The constraint
-- catches the other direction: an ACTIVE member of staff with a leaving date is
-- always a bug, and until now nothing would have said so.
alter table public.staff drop constraint if exists staff_left_on_chk;
alter table public.staff add constraint staff_left_on_chk
  check (status = 'left' or left_on is null);

comment on column public.staff.left_on is
  'Last working day. Written only by fn_staff_leave; cleared by fn_staff_rejoin.';

-- ---------------------------------------------------------------------------
-- fn_staff_roster — staff, WITH their login state and what they still hold.
--
-- The old screen read the staff table directly, which is why it could not show
-- whether a "deactivated" person could still log in: that fact lives in
-- profiles, and PostgREST cannot embed it unambiguously because staff and
-- profiles reference each other twice (staff.profile_id and profiles.staff_id).
-- ---------------------------------------------------------------------------
create or replace function public.fn_staff_roster()
returns table (
  id            uuid,
  full_name     text,
  designation   text,
  employee_no   text,
  mobile        text,
  whatsapp      text,
  cnic          text,
  joined_on     date,
  dob           date,
  left_on       date,
  status        text,
  profile_id    uuid,
  login_active  boolean,
  login_role    text,
  class_teacher_of text,
  assignments   integer
)
language plpgsql stable security definer set search_path = public as $$
declare v_school uuid := public.current_school_id();
begin
  if not public.has_role('owner', 'principal', 'admin_clerk') then
    raise exception 'Not permitted' using errcode = '42501';
  end if;

  return query
  select
    st.id, st.full_name, st.designation, st.employee_no, st.mobile, st.whatsapp,
    st.cnic, st.joined_on, st.dob, st.left_on, st.status,
    st.profile_id,
    -- NULL, not false, when there is no login at all: "no account" and "account
    -- switched off" are different facts and the screen says different things
    -- about them. Collapsing them to false would make every teacher without a
    -- login look like a revoked one.
    pr.active,
    pr.role::text,
    -- The sections this person is still class teacher of, named. A count would
    -- not be actionable; "1-A, 2-B" tells the principal what to reassign.
    (select string_agg(c.name || coalesce('-' || sec.name, ''), ', '
                       order by c.level_order, sec.sort_order, sec.name)
       from public.sections sec
       join public.classes c on c.id = sec.class_id and c.school_id = v_school
      where sec.school_id = v_school and sec.class_teacher_id = st.id),
    (select count(*)::integer
       from public.teacher_assignments ta
       join public.academic_sessions ses
         on ses.id = ta.session_id and ses.school_id = v_school and ses.is_current
      where ta.school_id = v_school and ta.staff_id = st.id)
  from public.staff st
  left join public.profiles pr
         on pr.id = st.profile_id and pr.school_id = v_school
  where st.school_id = v_school and st.deleted_at is null
  order by (st.status = 'active') desc, st.full_name;
end;
$$;

-- ---------------------------------------------------------------------------
-- fn_staff_leave — the whole exit, in one transaction.
--
-- Owner and principal only. A clerk may edit a staff record (the staff_write
-- policy lets them) but revoking somebody's access to every child's record is
-- not a clerical act.
-- ---------------------------------------------------------------------------
create or replace function public.fn_staff_leave(
  p_staff_id uuid,
  p_left_on  date default current_date,
  p_reason   text default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_school   uuid := public.current_school_id();
  v_staff    public.staff;
  v_sections text;
  v_vacated  integer := 0;
  v_dropped  integer := 0;
  v_revoked  boolean := false;
  v_on       date    := coalesce(p_left_on, current_date);
begin
  if not public.has_role('owner', 'principal') then
    raise exception 'Only an owner or principal may record a member of staff leaving'
      using errcode = '42501';
  end if;
  perform public.assert_own('staff', p_staff_id);

  select * into v_staff from public.staff
   where id = p_staff_id and school_id = v_school and deleted_at is null;
  if not found then
    raise exception 'Staff record not found';
  end if;
  if v_staff.status <> 'active' then
    raise exception '% is already recorded as having left', v_staff.full_name;
  end if;

  -- A future leaving date would be a record saying they were employed on a day
  -- the system had already locked them out — the login is cut below, now, not
  -- on the date. A school processing an exit after the fact (the normal case)
  -- passes a past date, which is fine.
  if v_on > current_date then
    raise exception 'The last working day cannot be in the future — the login is closed straight away';
  end if;
  if v_staff.joined_on is not null and v_on < v_staff.joined_on then
    raise exception 'Last working day (%) is before the joining date (%)', v_on, v_staff.joined_on;
  end if;

  update public.staff
     set status = 'left', left_on = v_on
   where id = p_staff_id and school_id = v_school;

  -- Vacate the class-teacher slots BEFORE reporting them, and name them, so the
  -- caller can tell the principal which classes now need somebody.
  select string_agg(c.name || coalesce('-' || sec.name, ''), ', '
                    order by c.level_order, sec.sort_order, sec.name),
         count(*)
    into v_sections, v_vacated
    from public.sections sec
    join public.classes c on c.id = sec.class_id and c.school_id = v_school
   where sec.school_id = v_school and sec.class_teacher_id = p_staff_id;

  update public.sections
     set class_teacher_id = null
   where school_id = v_school and class_teacher_id = p_staff_id;

  -- Teaching assignments for any session that had not already ended by their
  -- last day. Past sessions are history and stay: "who taught 1-A in 2023-24"
  -- must still be answerable after the teacher has gone.
  with gone as (
    delete from public.teacher_assignments ta
     where ta.school_id = v_school
       and ta.staff_id = p_staff_id
       and ta.session_id in (
         select ses.id from public.academic_sessions ses
          where ses.school_id = v_school
            and coalesce(ses.ends_on, 'infinity'::date) >= v_on)
    returning 1)
  select count(*) into v_dropped from gone;

  -- The point of the whole exercise. If this person is the school's only active
  -- owner the profiles trigger refuses, the transaction aborts, and nothing
  -- above is written — which is right: a school must not be able to lock itself
  -- out by processing its own exit.
  if v_staff.profile_id is not null then
    update public.profiles
       set active = false
     where id = v_staff.profile_id and school_id = v_school and active;
    v_revoked := found;
  end if;

  insert into public.audit_log (
    school_id, actor, actor_role, action, entity, entity_id, before, after, reason)
  values (
    v_school, auth.uid(),
    (select role from public.profiles where id = auth.uid()),
    'STAFF_LEAVE', 'staff', p_staff_id::text,
    to_jsonb(v_staff),
    jsonb_build_object('left_on', v_on, 'login_revoked', v_revoked,
                       'sections_vacated', coalesce(v_sections, ''),
                       'assignments_removed', v_dropped),
    p_reason);

  return jsonb_build_object(
    'staff_name',          v_staff.full_name,
    'left_on',             v_on,
    'login_revoked',       v_revoked,
    'had_login',           v_staff.profile_id is not null,
    'sections_vacated',    coalesce(v_sections, ''),
    'sections_count',      coalesce(v_vacated, 0),
    'assignments_removed', v_dropped);
end;
$$;

-- ---------------------------------------------------------------------------
-- fn_staff_rejoin — the undo, and the re-hire.
--
-- It does NOT put back the class-teacher slots or the assignments. Restoring
-- them silently would be worse than making somebody choose: the slots may have
-- been filled by a replacement in the meantime, and quietly overwriting that is
-- how two teachers end up on one result card.
-- ---------------------------------------------------------------------------
create or replace function public.fn_staff_rejoin(
  p_staff_id uuid,
  p_reason   text default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_school  uuid := public.current_school_id();
  v_staff   public.staff;
  v_restored boolean := false;
begin
  if not public.has_role('owner', 'principal') then
    raise exception 'Only an owner or principal may bring a member of staff back'
      using errcode = '42501';
  end if;
  perform public.assert_own('staff', p_staff_id);

  select * into v_staff from public.staff
   where id = p_staff_id and school_id = v_school and deleted_at is null;
  if not found then
    raise exception 'Staff record not found';
  end if;
  if v_staff.status = 'active' then
    raise exception '% is already active', v_staff.full_name;
  end if;

  update public.staff
     set status = 'active', left_on = null
   where id = p_staff_id and school_id = v_school;

  if v_staff.profile_id is not null then
    update public.profiles
       set active = true
     where id = v_staff.profile_id and school_id = v_school and not active;
    v_restored := found;
  end if;

  insert into public.audit_log (
    school_id, actor, actor_role, action, entity, entity_id, before, after, reason)
  values (
    v_school, auth.uid(),
    (select role from public.profiles where id = auth.uid()),
    'STAFF_REJOIN', 'staff', p_staff_id::text,
    to_jsonb(v_staff),
    jsonb_build_object('login_restored', v_restored),
    p_reason);

  return jsonb_build_object(
    'staff_name',     v_staff.full_name,
    'login_restored', v_restored,
    'had_login',      v_staff.profile_id is not null);
end;
$$;

-- ---------------------------------------------------------------------------
-- fn_staff_set_login_active — the access switch on its own.
--
-- Two jobs. Suspending somebody who has not left (long leave, an investigation)
-- without falsifying their employment record; and closing the logins of the
-- people the OLD button left open, which is the one thing this migration
-- refuses to do silently on the school's behalf.
-- ---------------------------------------------------------------------------
create or replace function public.fn_staff_set_login_active(
  p_staff_id uuid,
  p_active   boolean,
  p_reason   text default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_school uuid := public.current_school_id();
  v_staff  public.staff;
  v_before boolean;
  v_changed boolean := false;
begin
  if not public.has_role('owner', 'principal') then
    raise exception 'Only an owner or principal may change who can log in'
      using errcode = '42501';
  end if;
  perform public.assert_own('staff', p_staff_id);

  select * into v_staff from public.staff
   where id = p_staff_id and school_id = v_school and deleted_at is null;
  if not found then
    raise exception 'Staff record not found';
  end if;
  if v_staff.profile_id is null then
    raise exception '% has no login to change', v_staff.full_name;
  end if;

  select active into v_before from public.profiles
   where id = v_staff.profile_id and school_id = v_school;
  if v_before is null then
    raise exception '% has no login to change', v_staff.full_name;
  end if;

  -- Restoring access to somebody recorded as having left would leave the two
  -- facts contradicting each other, and the roster would show a departed member
  -- of staff with a working account. Bring them back properly instead.
  if p_active and v_staff.status <> 'active' then
    raise exception '% is recorded as having left on %. Use Rejoined first.',
      v_staff.full_name, coalesce(v_staff.left_on::text, 'an unrecorded date');
  end if;

  update public.profiles
     set active = p_active
   where id = v_staff.profile_id and school_id = v_school
     and active is distinct from p_active;
  v_changed := found;

  if v_changed then
    insert into public.audit_log (
      school_id, actor, actor_role, action, entity, entity_id, before, after, reason)
    values (
      v_school, auth.uid(),
      (select role from public.profiles where id = auth.uid()),
      case when p_active then 'STAFF_LOGIN_RESTORE' else 'STAFF_LOGIN_REVOKE' end,
      'profiles', v_staff.profile_id::text,
      jsonb_build_object('active', v_before),
      jsonb_build_object('active', p_active, 'staff_id', p_staff_id),
      p_reason);
  end if;

  return jsonb_build_object(
    'staff_name', v_staff.full_name,
    'login_active', p_active,
    'changed', v_changed);
end;
$$;

revoke all on function public.fn_staff_roster() from public;
revoke all on function public.fn_staff_leave(uuid, date, text) from public;
revoke all on function public.fn_staff_rejoin(uuid, text) from public;
revoke all on function public.fn_staff_set_login_active(uuid, boolean, text) from public;

grant execute on function public.fn_staff_roster() to authenticated;
grant execute on function public.fn_staff_leave(uuid, date, text) to authenticated;
grant execute on function public.fn_staff_rejoin(uuid, text) to authenticated;
grant execute on function public.fn_staff_set_login_active(uuid, boolean, text) to authenticated;

-- ─────────────────────────────────────────────────────────────────────────
-- 0054_student_leaving.sql
-- ─────────────────────────────────────────────────────────────────────────
-- =============================================================================
-- 0054 — When a child leaves.
--
-- The staff side of this was 0053. Pulling the same thread on the student side
-- found four things, three of them defects.
--
-- 1. THE ONLY BUTTON WAS "STRIKE OFF". student_status has four values —
--    active, struck_off, withdrawn, graduated — and the student profile offered
--    exactly one action. 'graduated' is set by the year-end rollover, which is
--    right. 'withdrawn' was UNREACHABLE. So a child whose family moves to
--    Karachi was *struck off*, which in Pakistan means removed for
--    non-payment or misconduct. It is what goes in the register and what a
--    parent would read on a leaving certificate. The most ordinary reason a
--    child leaves a school could not be recorded correctly.
--
-- 2. REINSTATING A GRADUATED CHILD LEFT THE TWO FACTS CONTRADICTING. The old
--    function reactivated enrollments only where status was 'struck_off' or
--    'left'. Set a graduated child back to active and you got
--    students.status = 'active' with enrollment status still 'graduated' —
--    proven by running it, not by reading it:
--
--        GRADUATED:       student=graduated enrollment=graduated
--        REINSTATED GRAD: student=active    enrollment=graduated
--
--    That child then shows as a current pupil on every student screen while
--    being in no class, billed nothing, and counted against no plan limit
--    (fn_count_students requires BOTH statuses active). Nothing on any screen
--    could reveal it.
--
-- 3. THERE WAS NO DATE. The only trace of a leaving was free text appended to
--    students.notes — "Status → withdrawn: Family moved to Karachi". No date, a
--    reason only if the clerk happened to type one, and both buried in a blob
--    that also holds every other note. A school could not answer "when did
--    Bilal leave" or "how many children left this term", and the date of
--    leaving is exactly what a government return and a leaving certificate ask
--    for.
--
-- 4. What DOES work, and is now pinned by tests because one careless
--    `create or replace` would silently break it: withdrawing a child stops
--    next month's invoice (fn_generate_class_invoices filters
--    enrollments.status) and stops them counting toward the plan limit.
-- =============================================================================

-- --- The two facts a register needs ------------------------------------------
alter table public.students add column if not exists left_on date;
alter table public.students add column if not exists leaving_reason text;

comment on column public.students.left_on is
  'Last day at the school. Written by fn_set_student_status, cleared on reinstatement.';
comment on column public.students.leaving_reason is
  'Why they left, as a field rather than buried in notes.';

-- An ACTIVE child with a leaving date is always a bug, and until now nothing
-- would have said so. The other direction is deliberately allowed: rows that
-- left before this migration have no date, and inventing one would be a lie.
alter table public.students drop constraint if exists students_left_on_chk;
alter table public.students add constraint students_left_on_chk
  check (status <> 'active' or (left_on is null and leaving_reason is null));

-- ---------------------------------------------------------------------------
-- fn_set_student_status — same name and same first three arguments, so every
-- existing caller keeps working; p_left_on is new and defaults to today.
--
-- Not `create or replace`: adding a parameter to a replaced function creates a
-- second overload rather than changing the first, and `fn_set_student_status(a,
-- b, c)` would then be ambiguous. The old signature has to go first.
-- ---------------------------------------------------------------------------
drop function if exists public.fn_set_student_status(uuid, public.student_status, text);

create or replace function public.fn_set_student_status(
  p_student_id uuid,
  p_status     public.student_status,
  p_reason     text default null,
  p_left_on    date default current_date
) returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_school  uuid := public.current_school_id();
  v_before  public.students;
  v_on      date;
  v_active  integer;
  v_sess    uuid;
  v_cls     text;
begin
  if not public.has_role('owner', 'principal') then
    raise exception 'Only an owner or principal may change a student''s status'
      using errcode = '42501';
  end if;
  perform public.assert_own('students', p_student_id);

  select * into v_before from public.students
   where id = p_student_id and school_id = v_school and deleted_at is null;
  if not found then
    raise exception 'Student record not found';
  end if;
  if v_before.status = p_status then
    raise exception '% is already %', v_before.full_name, p_status::text;
  end if;

  select id into v_sess from public.academic_sessions
   where school_id = v_school and is_current;

  -- ---------------------------------------------------------------- leaving --
  if p_status <> 'active' then
    v_on := coalesce(p_left_on, current_date);

    -- A future last day would be a record saying the child was on the roll on a
    -- day the school had already stopped billing them.
    if v_on > current_date then
      raise exception 'The last day cannot be in the future';
    end if;
    if v_before.admission_date is not null and v_on < v_before.admission_date then
      raise exception 'Last day (%) is before the admission date (%)',
        v_on, v_before.admission_date;
    end if;

    update public.students
       set status         = p_status,
           left_on        = v_on,
           leaving_reason = nullif(p_reason, ''),
           -- The notes append is kept: it is the human narrative shown on the
           -- profile, and removing it would erase the only history older rows
           -- have. The columns above are for everything that needs to READ it.
           notes = case when nullif(p_reason, '') is null then notes
                        else coalesce(notes || E'\n', '')
                             || 'Status → ' || p_status::text || ' on '
                             || v_on::text || ': ' || p_reason end
     where id = p_student_id and school_id = v_school;

    update public.enrollments e
       set status = (case p_status
                       when 'struck_off' then 'struck_off'
                       when 'graduated'  then 'graduated'
                       when 'withdrawn'  then 'left'
                       else 'active' end)::public.enrollment_status
     where e.school_id = v_school
       and e.student_id = p_student_id
       and e.session_id = v_sess;

  -- ------------------------------------------------------------ coming back --
  else
    update public.students
       set status         = 'active',
           left_on        = null,
           leaving_reason = null,
           notes = case when nullif(p_reason, '') is null then notes
                        else coalesce(notes || E'\n', '')
                             || 'Reinstated on ' || current_date::text || ': ' || p_reason end
     where id = p_student_id and school_id = v_school;

    update public.enrollments e
       set status = 'active'
     where e.school_id = v_school
       and e.student_id = p_student_id
       and e.session_id = v_sess
       and e.status in ('struck_off', 'left');

    -- The check that was missing. A child marked active with no active
    -- enrollment in the current session is a child who reads as a current pupil
    -- everywhere and is in no class, billed nothing, and counted against no
    -- plan limit. Written as "is there an active enrollment" rather than as a
    -- list of enum values, so a new enrollment status cannot slip past it.
    select count(*) into v_active
      from public.enrollments e
     where e.school_id = v_school and e.student_id = p_student_id
       and e.session_id = v_sess and e.status = 'active';

    if v_active = 0 then
      raise exception
        '% cannot simply be made active again: they have no place in the current '
        'session (their last enrollment is %). Admit them into a class for this '
        'session instead.',
        v_before.full_name,
        coalesce((select e.status::text from public.enrollments e
                   where e.school_id = v_school and e.student_id = p_student_id
                   order by e.created_at desc, e.id desc limit 1), 'missing');
    end if;
  end if;

  select c.name || coalesce('-' || sec.name, '') into v_cls
    from public.enrollments e
    join public.classes c on c.id = e.class_id and c.school_id = v_school
    left join public.sections sec on sec.id = e.section_id
   where e.school_id = v_school and e.student_id = p_student_id
     and e.session_id = v_sess;

  insert into public.audit_log (
    school_id, actor, actor_role, action, entity, entity_id, before, after, reason)
  values (
    v_school, auth.uid(),
    (select role from public.profiles where id = auth.uid()),
    'STUDENT_STATUS', 'students', p_student_id::text,
    jsonb_build_object('status', v_before.status, 'left_on', v_before.left_on),
    jsonb_build_object('status', p_status, 'left_on',
                       case when p_status = 'active' then null else v_on end),
    p_reason);

  return jsonb_build_object(
    'student_name', v_before.full_name,
    'status',       p_status,
    'left_on',      case when p_status = 'active' then null else v_on end,
    'class_name',   coalesce(v_cls, '—'));
end;
$$;

-- ---------------------------------------------------------------------------
-- fn_students_left — the read, without which left_on would be one more column
-- written and never shown. That is the bug class this project keeps producing,
-- and it is documented in 0047.
-- ---------------------------------------------------------------------------
create or replace function public.fn_students_left(p_from date, p_to date)
returns table (
  left_on      date,
  student_id   uuid,
  student_name text,
  gr_no        text,
  father_name  text,
  phone        text,
  class_name   text,
  section_name text,
  status       text,
  reason       text,
  admitted_on  date,
  months_here  integer,
  balance      numeric
)
language plpgsql stable security definer set search_path = public as $$
declare v_school uuid := public.current_school_id();
begin
  -- An office report, not is_staff(). It carries what each child left OWING,
  -- and a class teacher has no business with arrears — the balance sheet and
  -- the finance summary draw the line in the same place. Widening it to every
  -- member of staff to save a role check would put the fee ledger in front of
  -- subject teachers by the side door.
  if not public.has_role('owner', 'principal', 'admin_clerk', 'accountant') then
    raise exception 'Not permitted' using errcode = '42501';
  end if;

  return query
  select
    s.left_on, s.id, s.full_name, s.gr_no, s.father_name, s.phone,
    c.name, sec.name, s.status::text, s.leaving_reason,
    s.admission_date,
    case when s.admission_date is not null and s.left_on is not null
         then (extract(year  from s.left_on) * 12 + extract(month from s.left_on)
             - extract(year  from s.admission_date) * 12 - extract(month from s.admission_date))::integer
    end,
    -- What they left owing. A school chasing arrears after a child has gone
    -- needs this on the same row as the phone number, not two screens away.
    public.student_balance(s.id)
  from public.students s
  -- The enrollment they held when they left, whatever its status is now, so the
  -- report can say WHICH class rather than leaving the column blank for exactly
  -- the children it is about.
  left join public.enrollments e
         on e.student_id = s.id and e.school_id = v_school
        and e.session_id = (select id from public.academic_sessions
                             where school_id = v_school and is_current)
  left join public.classes  c   on c.id = e.class_id   and c.school_id = v_school
  left join public.sections sec on sec.id = e.section_id and sec.school_id = v_school
  where s.school_id = v_school
    and s.deleted_at is null
    and s.status <> 'active'
    -- No `left_on is not null` here: BETWEEN already excludes it, because
    -- `null between x and y` is null rather than true. Writing it as well would
    -- be a line no test could defend — removing it changed no assertion, which
    -- is how it was found. What DOES defend the behaviour is the test's
    -- pre-0054 fixture row (a status with no date), which any null-tolerant
    -- rewrite of this range check would wrongly let through.
    and s.left_on between coalesce(p_from, '1900-01-01'::date)
                      and coalesce(p_to,   '2999-12-31'::date)
  order by s.left_on desc, s.full_name;
end;
$$;

-- ---------------------------------------------------------------------------
-- Hardening, not a bug fix. Say so plainly.
--
-- fn_generate_class_invoices decides who to bill from enrollments.status alone.
-- fn_count_students — which decides who counts toward the paid plan — requires
-- students.status = 'active' AND enrollments.status = 'active' AND
-- students.deleted_at is null. Two functions answering "who is a current pupil"
-- with different conditions is a disagreement waiting for a reason.
--
-- Today it cannot bite: fn_set_student_status keeps both statuses in step, and
-- NOTHING in the entire codebase writes students.deleted_at, so that column is
-- read everywhere and written nowhere. This is therefore defence in depth, and
-- claiming otherwise would be overclaiming.
--
-- It is still worth having, because the failure mode is billing a child who has
-- left, and the change is one-directional: adding these conditions can only
-- ever bill FEWER children, and only ones whose own record says they are not
-- here. It cannot skip a child who is.
--
-- The body below is the LIVE definition with only the WHERE clause extended,
-- copied from pg_get_functiondef() so nothing else can drift in the copying.
CREATE OR REPLACE FUNCTION public.fn_generate_class_invoices(p_session_id uuid, p_class_id uuid, p_period_month date, p_due_date date)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
    -- The join added in 0054. See the note above: the student's own record must
    -- agree that they are here, not just the enrollment. This is the ONLY change
    -- to this function; everything else is pg_get_functiondef() output verbatim.
    join public.students s
      on s.id = e.student_id
     and s.school_id = v_school
     and s.status = 'active'
     and s.deleted_at is null
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
$function$;

revoke all on function public.fn_set_student_status(uuid, public.student_status, text, date) from public;
revoke all on function public.fn_students_left(date, date) from public;

grant execute on function public.fn_set_student_status(uuid, public.student_status, text, date) to authenticated;
grant execute on function public.fn_students_left(date, date) to authenticated;

-- ─────────────────────────────────────────────────────────────────────────
-- 0055_rollover_scoping.sql
-- ─────────────────────────────────────────────────────────────────────────
-- =============================================================================
-- 0055 — The year-end rollover promoted children into OTHER SCHOOLS' classrooms.
--
-- This is the most serious defect found in this project.
--
-- WHAT HAPPENED
--
-- fn_rollover decides where each class promotes to. With no explicit rule it
-- takes "the next class up", which it found like this:
--
--     select id from public.classes c2
--     where c2.active and c2.level_order > c.level_order
--     order by c2.level_order limit 1
--
-- There is no school in that query, and the function is SECURITY DEFINER, so
-- RLS never applies. It therefore searched the classes of EVERY SCHOOL on the
-- platform and returned the globally-lowest class above the current level.
--
-- It is not an edge case. Proven by running it:
--
--   * School A tops out at Class 10 and has no class above it, so its leavers
--     should GRADUATE. School B has a Class 11. A's rollover reported
--     "promoted: 1" and enrolled A's child in
--     "B ELEVEN — SHOULD NEVER BE REACHED FROM SCHOOL A".
--
--   * Worse, the ORDINARY case. School A has Class 5 and Class 6; school B also
--     has a Class 6. Both sixes carry level_order 6, so the `order by
--     c2.level_order limit 1` tie is settled by whichever row the heap hands
--     back first — school B's. Five consecutive runs put A's child in B's
--     classroom every time.
--
-- So on a live deployment with more than one school, a school's year-end
-- rollover — the one operation that touches every child, once a year — scatters
-- its pupils into other schools' classes. The enrolment carries school A's
-- school_id while pointing at school B's class, which means A's own screens
-- print another school's class names, no fee structure exists for that class so
-- the child is billed nothing, and a child who should be an alumnus is not.
--
-- WHY THE EXISTING GUARD MISSED IT
--
-- dashboard.sql assertion 20 checks that every SECURITY DEFINER function
-- reading a tenant table mentions current_school_id / assert_own / school_id
-- somewhere in its body. fn_rollover calls assert_own on both session ids, so
-- the whole function was treated as scoped and its individual queries were
-- never examined. One correct check exempted eight incorrect ones. That
-- coarseness is recorded here rather than quietly fixed: a per-query analysis
-- is not something to bolt on in a hurry, and the honest statement is that the
-- guard proves a function was CONSIDERED, not that every query in it is scoped.
--
-- WHAT IS FIXED
--
-- Every query in both functions is now scoped to the caller's school:
-- the class ladder, the class list, the "already enrolled" probe, the source
-- enrolments, the displayed target name, the section carry-over, the roll-number
-- seed, and all four writes. Rule-supplied class ids go through assert_own, so
-- naming another school's class is refused outright instead of honoured.
--
-- Two further changes, each with its own reason:
--
--   * A tie-break on the class ladder (order by level_order, id). Two classes at
--     the same level_order inside ONE school were still undefined, which could
--     make a dry run disagree with the commit — the worst possible property for
--     a screen whose whole purpose is "check this before you commit".
--
--   * The rollover now stamps students.left_on and leaving_reason when it
--     graduates a year group, because 0054 made those the fields a leaving is
--     recorded in. Without it the largest leaving event in the school year —
--     an entire final-year class — would be missing from the leavers report.
--
-- fn_rollover_undo had its own unscoped query: it counted graduated children
-- across every tenant and returned the total to this school's principal.
--
-- Both bodies below are pg_get_functiondef() output with only these changes
-- applied, then diffed against the originals. 0052 and 0054 both say why:
-- copy, never retype.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.fn_rollover(p_from uuid, p_to uuid, p_rules jsonb DEFAULT '[]'::jsonb, p_commit boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_school    uuid := public.current_school_id();
  v_promoted  int := 0;
  v_retained  int := 0;
  v_graduated int := 0;
  v_unmapped  int := 0;
  v_skipped   int := 0;
  v_rows      jsonb;
begin
  if not public.has_role('owner','principal') then
    raise exception 'Only the owner or principal may run a year-end rollover';
  end if;
  if p_from is null or p_to is null then raise exception 'Both sessions are required'; end if;
  perform public.assert_own('academic_sessions', p_from);
  perform public.assert_own('academic_sessions', p_to);
  if p_from = p_to then raise exception 'The target session must differ from the source'; end if;
  if not exists (select 1 from public.academic_sessions where id = p_from) then
    raise exception 'Source session does not exist'; end if;
  if not exists (select 1 from public.academic_sessions where id = p_to) then
    raise exception 'Target session does not exist'; end if;
  if exists (select 1 from public.academic_sessions where id = p_to and is_closed) then
    raise exception 'Target session is closed'; end if;
  if p_rules is null or jsonb_typeof(p_rules) <> 'array' then
    raise exception 'rules must be a JSON array'; end if;
  -- Every class id a RULE names is caller input and must be checked. Without
  -- this, passing another school's class id put this school's children in it.
  perform public.assert_own('classes', nullif(r->>'from_class_id','')::uuid)
     from jsonb_array_elements(p_rules) r;
  perform public.assert_own('classes', nullif(r->>'to_class_id','')::uuid)
     from jsonb_array_elements(p_rules) r;

  -- Build the plan for every active enrolment in the source session. A student
  -- who already has an enrolment in the target session is left out (skipped).
  drop table if exists _rollover_plan;
  create temp table _rollover_plan on commit drop as
  with eff as (   -- effective rule per source class (explicit rule, else default)
    select c.id as from_class, c.name as from_class_name,
      -- 'promote' with a null to_class is what the tally already reports as
      -- `unmapped`, message "No target class chosen" — so an ambiguous rung
      -- surfaces on the dry run and asks the school for a rule, instead of
      -- either guessing a classroom or graduating a whole middle year.
      coalesce(pr.action,
               case when nx.id is not null then 'promote'
                    when nx.has_level_above then 'promote'
                    else 'graduate' end) as action,
      case
        when pr.action = 'retain'  then c.id
        when pr.action = 'promote' then pr.to_class_id
        when pr.action = 'graduate' then null
        when pr.action is null and nx.id is not null then nx.id
        else null
      end as to_class
    from public.classes c
    left join lateral (
      select r->>'action' as action, nullif(r->>'to_class_id','')::uuid as to_class_id
      from jsonb_array_elements(p_rules) r
      where (r->>'from_class_id')::uuid = c.id
      limit 1
    ) pr on true
    left join lateral (
      -- THE BUG. This picked the next class up ACROSS EVERY SCHOOL, so on a
      -- live multi-tenant deployment a school's year-end rollover promoted its
      -- children into another school's classroom. Not an edge case: with two
      -- schools sharing a normal ladder the level_order values tie and the
      -- winner is whichever row the heap returns first.
      -- Only when the next level up holds EXACTLY ONE class. An id or name
      -- tie-break was the first attempt and it is the wrong answer: a school
      -- with "Class 8" and "Class 8 Science" would have its children silently
      -- funnelled into whichever the sort happened to favour, and nothing on
      -- screen would say a choice had been made on their behalf.
      --
      -- Returning null instead makes the class come out as `unmapped` — a state
      -- the plan already has, with the message "No target class chosen" — so the
      -- dry run shows the school the ambiguity and asks for a rule. It also
      -- removes the last source of nondeterminism between a dry run and its
      -- commit.
      -- Returns the resolved class AND whether a level above exists at all.
      -- Those are different facts and the old code could not tell them apart:
      -- `nx.id is null` meant both "this is the top class, graduate them" and
      -- "the next level is ambiguous". Collapsing the two would mark a Class 7
      -- with two Class 8s above it as having FINISHED SCHOOL.
      select
        -- Aggregated on purpose: `having count(*) = 1` makes the subquery
        -- return NO ROW (hence null) unless exactly one class sits at that
        -- level, and an aggregate is the only shape where a bare column and a
        -- HAVING can coexist.
        (select (array_agg(c2.id))[1] from public.classes c2
          where c2.school_id = v_school and c2.active
            and c2.level_order = lv.next_level
          having count(*) = 1) as id,
        lv.next_level is not null as has_level_above
      from (select min(c3.level_order) as next_level
              from public.classes c3
             where c3.school_id = v_school and c3.active
               and c3.level_order > c.level_order) lv
    ) nx on true
    where c.school_id = v_school and c.active
  ),
  plan as (
    select e.id as from_enr, e.student_id, s.full_name as name, s.gr_no as gr,
           e.class_id as from_class, eff.from_class_name,
           eff.action, eff.to_class, e.section_id as from_section, e.roll_no as old_roll,
           public.student_balance(e.student_id) as balance,
           exists (select 1 from public.enrollments e2
                   where e2.school_id = v_school
                     and e2.student_id = e.student_id and e2.session_id = p_to) as already
    from public.enrollments e
    join public.students s on s.id = e.student_id and s.school_id = v_school
    join eff on eff.from_class = e.class_id
    where e.school_id = v_school and e.session_id = p_from and e.status = 'active'
  )
  select
    p.from_enr, p.student_id, p.name, p.gr, p.from_class, p.from_class_name,
    p.action, p.to_class,
    (select tc.name from public.classes tc
      where tc.id = p.to_class and tc.school_id = v_school) as to_class_name,
    p.from_section,
    -- carry the section by NAME into the target class, if such a section exists
    (select sec2.id from public.sections sec2
       join public.sections sec1 on sec1.id = p.from_section
                                and sec1.school_id = v_school
      where sec2.school_id = v_school
        and sec2.class_id = p.to_class and lower(sec2.name) = lower(sec1.name)
      order by sec2.id
      limit 1) as to_section,
    p.old_roll, p.balance, p.already,
    null::text as proposed_roll
  from plan p;

  -- Assign roll numbers per target (class, section), continuing from any existing
  -- rolls already in the target session.
  with r as (
    select pl.from_enr,
      (seed.maxroll + row_number() over (
         partition by pl.to_class, pl.to_section
         order by nullif(regexp_replace(coalesce(pl.old_roll,''),'[^0-9]','','g'),'')::int nulls last, pl.name
       ))::text as roll
    from _rollover_plan pl
    join lateral (
      select coalesce(max(nullif(regexp_replace(coalesce(e.roll_no,''),'[^0-9]','','g'),'')::int), 0) as maxroll
      from public.enrollments e
      where e.school_id = v_school
        and e.session_id = p_to and e.class_id = pl.to_class
        and e.section_id is not distinct from pl.to_section
    ) seed on true
    where not pl.already and pl.action in ('promote','retain') and pl.to_class is not null
  )
  update _rollover_plan pl set proposed_roll = r.roll from r where r.from_enr = pl.from_enr;

  -- Tally
  select
    count(*) filter (where not already and action = 'promote'  and to_class is not null),
    count(*) filter (where not already and action = 'retain'),
    count(*) filter (where not already and action = 'graduate'),
    count(*) filter (where not already and action = 'promote'  and to_class is null),
    count(*) filter (where already)
  into v_promoted, v_retained, v_graduated, v_unmapped, v_skipped
  from _rollover_plan;

  if p_commit then
    -- 1. create the new enrolments (promote + retain)
    insert into public.enrollments(student_id, session_id, class_id, section_id, roll_no, status, promoted_from)
    select student_id, p_to, to_class, to_section, proposed_roll, 'active', from_enr
    from _rollover_plan
    where not already and action in ('promote','retain') and to_class is not null;

    -- 2. stamp the source enrolments
    update public.enrollments e set status = 'promoted'
      from _rollover_plan pl where pl.from_enr = e.id and e.school_id = v_school
        and not pl.already and pl.action = 'promote' and pl.to_class is not null;
    update public.enrollments e set status = 'retained'
      from _rollover_plan pl where pl.from_enr = e.id and e.school_id = v_school
        and not pl.already and pl.action = 'retain';
    update public.enrollments e set status = 'graduated'
      from _rollover_plan pl where pl.from_enr = e.id and e.school_id = v_school
        and not pl.already and pl.action = 'graduate';

    -- 3. graduates become alumni at the identity level. left_on is stamped
    --    because 0054 made it the field a leaving is recorded in, and a
    --    graduation reached through the rollover is still a leaving — without
    --    it, a whole year group would be absent from the leavers report.
    update public.students s
       set status = 'graduated',
           -- least(): a rollover run BEFORE the session officially ends would
           -- otherwise stamp a leaving date in the future, which
           -- fn_set_student_status refuses outright and which a direct UPDATE
           -- here would sneak past. A child cannot have left tomorrow.
           left_on = coalesce(s.left_on,
                              least((select ses.ends_on from public.academic_sessions ses
                                      where ses.id = p_from and ses.school_id = v_school),
                                    current_date),
                              current_date),
           leaving_reason = coalesce(s.leaving_reason, 'Graduated at the end of the session')
      from _rollover_plan pl where pl.student_id = s.id and s.school_id = v_school
        and not pl.already and pl.action = 'graduate';
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
    'student_id', student_id, 'name', name, 'gr_no', gr,
    'from_class', from_class_name, 'to_class', to_class_name,
    'action', case when already then 'skipped'
                   when action = 'promote' and to_class is null then 'unmapped'
                   else action end,
    'roll_no', proposed_roll, 'balance', balance,
    'message', case when already then 'Already enrolled in the target session'
                    when action = 'promote' and to_class is null then 'No target class chosen'
                    else null end
  ) order by from_class_name, name), '[]'::jsonb)
  into v_rows from _rollover_plan;

  return jsonb_build_object(
    'commit', p_commit, 'from_session', p_from, 'to_session', p_to,
    'promoted', v_promoted, 'retained', v_retained, 'graduated', v_graduated,
    'unmapped', v_unmapped, 'skipped', v_skipped,
    'total', v_promoted + v_retained + v_graduated + v_unmapped + v_skipped,
    'rows', v_rows);
end;
$function$;

CREATE OR REPLACE FUNCTION public.fn_rollover_undo(p_to uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_school   uuid := public.current_school_id();
  v_undone   int := 0;
  v_grads    int;
begin
  if not public.has_role('owner','principal') then
    raise exception 'Only the owner or principal may undo a rollover';
  end if;
  if p_to is null then raise exception 'Target session is required'; end if;
  perform public.assert_own('academic_sessions', p_to);

  -- Guard: refuse if any real work already exists in the target session.
  if exists (select 1 from public.invoices
              where school_id = v_school and session_id = p_to)
     or exists (select 1 from public.assessments
                 where school_id = v_school and session_id = p_to)
     or exists (select 1 from public.exam_terms
                 where school_id = v_school and session_id = p_to)
     or exists (select 1 from public.attendance_daily ad
                join public.enrollments e on e.id = ad.enrollment_id
                where ad.school_id = v_school
                  and e.school_id = v_school and e.session_id = p_to)
  then
    raise exception 'Cannot undo: attendance, fees or exams already recorded in the target session';
  end if;

  -- Reactivate the source enrolments, then remove the rollover-created ones.
  update public.enrollments old set status = 'active'
    from public.enrollments new
    where new.school_id = v_school
      and new.session_id = p_to and new.promoted_from is not null
      and old.school_id = v_school
      and old.id = new.promoted_from and old.status in ('promoted','retained');

  select count(*) into v_undone from public.enrollments
    where school_id = v_school and session_id = p_to and promoted_from is not null;
  delete from public.enrollments
    where school_id = v_school and session_id = p_to and promoted_from is not null;

  -- Was `from public.students where status = 'graduated'` with NO school
  -- filter, inside a SECURITY DEFINER function: it counted graduated children
  -- across every tenant on the platform and returned the total to this school's
  -- principal. A count is a small leak, and it is still a leak.
  select count(*) into v_grads from public.students
   where school_id = v_school and status = 'graduated';

  return jsonb_build_object(
    'undone', v_undone,
    'note', 'Promotions and retentions reversed. Graduated (alumni) students, if any, were left as-is — reinstate individually from the student profile.',
    'graduated_total', v_grads);
end;
$function$;

-- ─────────────────────────────────────────────────────────────────────────
-- 0056_importer_scoping.sql
-- ─────────────────────────────────────────────────────────────────────────
-- =============================================================================
-- 0056 — The go-live importers looked up children across every school.
--
-- WHAT WAS WRONG
--
-- gr_no, admission_no and roll_no are PER-SCHOOL counters. Every school on the
-- platform has a GR 0001. Both bulk importers — the two tools a school uses on
-- its very first day — resolved and de-duplicated on those keys with no school
-- filter, inside SECURITY DEFINER functions where RLS never applies.
--
-- fn_import_students, de-duplicating:
--
--     select count(*) into v_cnt from public.students where gr_no = v_gr;
--     if v_cnt > 0 then ... 'GR ' || v_gr || ' already exists'
--
-- So a school importing its register was told "GR 0001 already exists" because
-- ANOTHER school already had a GR 0001. A school could not complete its first
-- bulk import, and the rejection rate grows with every school that joins.
--
-- fn_import_opening_balances, resolving who a row belongs to:
--
--     select id into v_student from public.students where gr_no = v_gr ...
--
-- plpgsql SELECT INTO takes the first row and raises nothing, so this could
-- resolve to another school's child. Step 4 then checks enrolment in the target
-- session, the foreign child has none, and the row fails with
--
--     "Student is not enrolled in the selected session"
--
-- about a pupil who is enrolled. Proven by running it: two schools, both with
-- GR 0001, import by GR fails with exactly that message. The name lookup has
-- the same fault in a more visible form — "Name Muhammad Ali matches several
-- students — use GR No" for a school holding exactly one Muhammad Ali, with the
-- advice pointing at the GR path that is also broken.
--
-- And the result row carries `name`, filled from the resolved student, so the
-- import report could print ANOTHER SCHOOL'S PUPIL'S NAME back to the importer.
--
-- WHY THIS IS THE THIRD TIME
--
-- Migration 0042 already found and fixed exactly this, for staff:
--
--     "No school filter, so importing staff rejected rows as duplicates because
--      ANOTHER school already used that employee number"
--
-- The diagnosis was right and it was applied to one of the three importers. The
-- student importer and the opening-balance importer were never revisited. This
-- migration finishes the job, and check-import-keys.py now fails the build on
-- any lookup of a per-school business key that has no school filter, so a
-- fourth importer cannot repeat it.
--
-- HOW
--
-- Same technique as 0042: fetch the live definition, replace only the offending
-- fragments, and execute it. Nothing is retyped — 0054 nearly reverted five
-- migrations' worth of billing logic by hand-copying a function body.
--
-- Unlike 0042, every replacement is CHECKED — but on its END STATE, not on
-- whether it matched. A replace() that matches nothing is a silent no-op: the
-- migration applies perfectly cleanly and the bug is still there. That is the
-- one failure mode this technique has and it needs a guard.
--
-- The first version of this file asserted "the replacement changed something",
-- and that was wrong: run it twice and the second run raises, because the
-- unscoped text is legitimately gone. Asserting the end state instead — the
-- unscoped form is absent AND the scoped form is present — is idempotent and
-- still fails loudly if the function has been rewritten under us and neither
-- form is there. Found by re-running it, not by reading it.
-- =============================================================================

do $mig$
declare
  v_def   text;
  v_fn    text;
  v_pair  text[];
  v_pairs text[][];
begin
  foreach v_fn in array array['fn_import_students', 'fn_import_opening_balances']
  loop
    select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = v_fn;
    if v_def is null then raise exception '0056: % not found', v_fn; end if;

    -- {unscoped, scoped}. Both forms are named so the end state can be checked
    -- either way round: after this runs the unscoped text must be gone and the
    -- scoped text must be there.
    if v_fn = 'fn_import_students' then
      v_pairs := array[
        array['from public.students where gr_no = v_gr',
              'from public.students where school_id = public.current_school_id() and gr_no = v_gr'],
        array['from public.students where admission_no = v_admno',
              'from public.students where school_id = public.current_school_id() and admission_no = v_admno']
      ];
    else
      v_pairs := array[
        -- The GR lookup that could resolve to another school's child.
        array['from public.students where gr_no = v_gr and deleted_at is null',
              'from public.students where school_id = public.current_school_id() and gr_no = v_gr and deleted_at is null'],
        -- Twice: the count and the select. replace() rewrites both.
        array['from public.students where admission_no = v_adm and deleted_at is null',
              'from public.students where school_id = public.current_school_id() and admission_no = v_adm and deleted_at is null'],
        -- The name lookup, also twice. Keyed on the father-name clause because
        -- the two copies are indented differently and share no other text.
        array['lower(coalesce(father_name, '''')) = lower(v_father))',
              'lower(coalesce(father_name, '''')) = lower(v_father)) and school_id = public.current_school_id()'],
        -- The label. By id, so already this school's child once the lookups
        -- above are fixed — scoped anyway, because it is what the import report
        -- prints back and a name is the most visible thing to leak.
        array['(select full_name from public.students where id = v_student)',
              '(select full_name from public.students where id = v_student and school_id = public.current_school_id())']
      ];
    end if;

    foreach v_pair slice 1 in array v_pairs
    loop
      if position(v_pair[2] in v_def) = 0 then
        -- Not yet scoped. It must be present in the unscoped form, or the
        -- function is neither what we found nor what we intend to leave.
        if position(v_pair[1] in v_def) = 0 then
          raise exception
            '0056: %s matches neither the unscoped nor the scoped form of "%" — '
            'the function has been rewritten and this migration must be updated, '
            'not skipped', v_fn, left(v_pair[1], 60);
        end if;
        v_def := replace(v_def, v_pair[1], v_pair[2]);
      end if;
      -- End state, asserted either way round.
      if position(v_pair[2] in v_def) = 0 then
        raise exception '0056: failed to scope "%" in %', left(v_pair[1], 60), v_fn;
      end if;
    end loop;

    execute v_def;
  end loop;
end
$mig$;

-- Belt and braces against the stored bodies, not against local variables: prove
-- no unscoped lookup on a per-school counter survives in either importer. If
-- this fails the whole migration rolls back.
do $check$
declare v_bad text;
begin
  select string_agg(p.proname, ', ') into v_bad
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public'
    and p.proname in ('fn_import_students', 'fn_import_opening_balances')
    and (   p.prosrc ~ 'from public\.students where gr_no'
         or p.prosrc ~ 'from public\.students where admission_no'
         or p.prosrc ~ 'lower\(v_father\)\)\s*$');
  if v_bad is not null then
    raise exception '0056 did not take effect in: %', v_bad;
  end if;
end
$check$;

-- ─────────────────────────────────────────────────────────────────────────
-- Record what this bundle applied (no-op before 0069 creates the ledger)
-- ─────────────────────────────────────────────────────────────────────────
do $ledger$
begin
  if to_regprocedure('public.fn_record_migration(text,text,text)') is null then
    raise notice 'migration ledger not present yet — nothing recorded';
    return;
  end if;
  perform public.fn_record_migration('0050_search_and_birthdays.sql', '5_search.sql');
  perform public.fn_record_migration('0051_like_escaping.sql', '5_search.sql');
  perform public.fn_record_migration('0052_recent_payments_order.sql', '5_search.sql');
  perform public.fn_record_migration('0053_staff_leaving.sql', '5_search.sql');
  perform public.fn_record_migration('0054_student_leaving.sql', '5_search.sql');
  perform public.fn_record_migration('0055_rollover_scoping.sql', '5_search.sql');
  perform public.fn_record_migration('0056_importer_scoping.sql', '5_search.sql');
end $ledger$;

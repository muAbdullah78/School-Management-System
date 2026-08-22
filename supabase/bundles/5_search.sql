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
$function$



-- =============================================================================
-- REPAIR: migration 0041_student_list, on its own.
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

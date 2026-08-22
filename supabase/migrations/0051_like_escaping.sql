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



-- =============================================================================
-- 0072 — Two lookups that searched every school, not this one
--
-- Both found by sweeping for the shape that has already cost this project twice,
-- and both proven on a live two-school fixture before this file was written.
--
-- THE SHAPE
--
-- A SECURITY DEFINER function — where RLS does not apply — resolving a row by
-- NAME or TYPE with no school predicate. It is the fn_rollover bug: "the next
-- class up" was chosen without a school filter and a school's year-end rollover
-- promoted its children into another school's classroom, five runs out of five.
--
-- supabase/check-definer-queries.py exists because of that, and it does not
-- catch these two, because it hunts an inequality between two table columns and
-- these are plain equality on a name. supabase/check-definer-idor.py does not
-- catch them either, because neither lookup keys on a caller-supplied ID — the
-- name arrives as text and the type is a literal. So a third sweep was needed:
-- reads over a tenant table with NO school predicate and NO caller parameter at
-- all, 26 candidates out of 276 statements, of which 24 turned out to be
-- anchored on auth.uid() or on a local already derived from a scoped row.
--
-- DEFECT 1 — fn_admit_student attached another school's fee head
--
--     select id into v_af_head from public.fee_heads
--      where type = 'admission' and active
--      order by sort_order limit 1;
--
-- Whichever school's Admission Fee head sorted first, platform-wide. Then:
--
--     insert into public.invoice_lines(invoice_id, fee_head_id, ...)
--     values (v_af_inv, v_af_head, 'Admission Fee', v_af_amt, false);
--
-- Proven: an admission at School B produced an invoice line whose own school_id
-- was School B's (enforce_school_id stamps that) while fee_head_id pointed at
-- School A's fee head.
--
--     ADMIT -> invoice line uses the VICTIM school's fee head? t
--             (line.school_id says attacker: t)
--
-- Two consequences. Any report joining invoice_lines to fee_heads shows a head
-- the school does not own — or nothing, once RLS is in play — so the admission
-- fee silently disappears from head-wise dues. And the "create one if missing"
-- branch immediately below could never run for a new school, because some other
-- school always had one: the very first admission at every new school was
-- affected, which is every school's first day.
--
-- DEFECT 2 — fn_import_students resolved a class by name across all schools
--
--     select id into v_class from public.classes
--      where active and lower(btrim(name)) = lower(v_cls_in)
--      order by level_order limit 1;
--
-- This one does not leak, and that is worth being precise about: a later
-- assert_own('classes', v_class) catches it. But catching it is the problem.
-- Proven with two schools both having a 'Class 5', the other school's at a lower
-- level_order:
--
--     {"row": 1, "gr_no": "IMP-1", "status": "error",
--      "message": "classes not found in this school"}
--
-- The importing school HAS a Class 5. Its own row was refused, with a message
-- about somebody else's data. Every Pakistani school calls its classes the same
-- things — Class 5, Nursery, Prep, Matric — so at any real number of schools the
-- name collides for nearly all of them, and whichever school registered its
-- ladder first wins the sort. The go-live importer, which is how every new
-- school's roster arrives, would refuse most rows for most schools.
--
-- Not a leak. A go-live blocker that only appears once there is more than one
-- customer, which is exactly the kind of defect a single-tenant test never sees.
--
-- WHY A PROGRAMMATIC REWRITE
--
-- Both functions are long and neither is owned by this migration — fn_admit_student
-- dates from 0004 and has been rewritten by 0019, 0029 and 0036; fn_import_students
-- from 0012 and rewritten by 0056. Retyping either would silently revert whatever
-- the most recent author did. So each block reads the LIVE definition, replaces
-- exactly the one predicate, and asserts the end state — the same technique 0066
-- used on the two billers.
--
-- Re-runnable: each block checks whether the fix is already present first.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. fn_admit_student — the admission fee head must be this school's
-- ---------------------------------------------------------------------------
do $fix_admit$
declare
  src text;
  before_txt text := 'where type = ''admission'' and active';
  after_txt  text := 'where type = ''admission'' and active'
                  || ' and school_id = public.current_school_id()';
begin
  select pg_get_functiondef(p.oid) into src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'fn_admit_student' and p.prokind = 'f';
  if src is null then
    raise exception '0072: fn_admit_student not found — apply the earlier migrations first';
  end if;

  if position(after_txt in src) > 0 then
    raise notice '0072: fn_admit_student already scopes the admission fee head';
    return;
  end if;
  if position(before_txt in src) = 0 then
    raise exception '0072: could not find the admission fee head lookup in '
      'fn_admit_student. It has been rewritten; re-check the predicate by hand '
      'rather than letting this migration silently do nothing.';
  end if;

  src := replace(src, before_txt, after_txt);
  execute src;

  -- Assert the END STATE, not the fact that a replace ran. A threshold or a
  -- "did something change" check passes over a partial rewrite, which on this
  -- project is a mistake that has been made four times.
  if not exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = 'fn_admit_student'
       and p.prosrc like '%' || after_txt || '%')
  then
    raise exception '0072: the rewrite of fn_admit_student did not take';
  end if;
  raise notice '0072: fn_admit_student now takes the admission fee head from this school only';
end $fix_admit$;

-- ---------------------------------------------------------------------------
-- 2. fn_import_students — a class name means a class in THIS school
--
-- The section lookup below it needs no change: it is already scoped through
-- `class_id = v_class`, so it inherits the fix.
-- ---------------------------------------------------------------------------
do $fix_import$
declare
  src text;
  before_txt text := 'where active and lower(btrim(name)) = lower(v_cls_in)';
  after_txt  text := 'where active and school_id = public.current_school_id()'
                  || ' and lower(btrim(name)) = lower(v_cls_in)';
begin
  select pg_get_functiondef(p.oid) into src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'fn_import_students' and p.prokind = 'f';
  if src is null then
    raise exception '0072: fn_import_students not found — apply the earlier migrations first';
  end if;

  if position(after_txt in src) > 0 then
    raise notice '0072: fn_import_students already scopes the class lookup';
    return;
  end if;
  if position(before_txt in src) = 0 then
    raise exception '0072: could not find the class-by-name lookup in '
      'fn_import_students. It has been rewritten; re-check the predicate by hand.';
  end if;

  src := replace(src, before_txt, after_txt);
  execute src;

  if not exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = 'fn_import_students'
       and p.prosrc like '%' || after_txt || '%')
  then
    raise exception '0072: the rewrite of fn_import_students did not take';
  end if;
  raise notice '0072: fn_import_students now resolves a class name within this school only';
end $fix_import$;

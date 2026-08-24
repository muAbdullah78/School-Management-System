-- =============================================================================
-- 0063 — Nobody could admit a student
--
-- Found while writing the check-in suite, which was the first test in this
-- project to write `students` as the `authenticated` role rather than as the
-- table owner. The most ordinary operation in the whole system:
--
--   set local role authenticated;
--   insert into public.students (school_id, full_name, father_name, status)
--     values (current_school_id(), 'Test Child', 'Test Father', 'active');
--
--   ERROR:  permission denied for function fn_photo_path_ok
--
-- 0057 put a CHECK constraint on `students.photo_path`, `staff.photo_path` and
-- `school_settings.logo_path` calling `fn_photo_path_ok`, and then — in the same
-- block that revoked the internal photo setters — did
--
--   revoke all on function public.fn_photo_path_ok(text, text, uuid) from public;
--
-- without granting it back to `authenticated`. **A CHECK constraint's function
-- runs with the privileges of whoever is writing the row.** Postgres grants
-- EXECUTE to PUBLIC on a new function by default, which is the only reason any
-- of this ever worked; revoking that grant and not replacing it made all three
-- tables unwritable by every signed-in user.
--
-- Admitting a child. Adding a teacher. Saving the school's own name and address.
--
-- Why nothing caught it: **every existing suite writes those tables as the table
-- owner**, and the owner bypasses both RLS and function-privilege checks. The
-- constraint was tested — photos.sql proves it rejects another school's path —
-- but tested from a position where the privilege question cannot arise. A test
-- that runs as postgres is not testing what a school experiences.
--
-- The remedy is one grant. The guard that stops it recurring is
-- supabase/check-constraint-functions.sh, which asserts that every function
-- named by a CHECK constraint in `public` is executable by `authenticated` —
-- because this is a whole class of defect, not one line.
--
-- Re-runnable.
-- =============================================================================

-- The function is a pure predicate over its own arguments: it composes the
-- expected path and compares. It reveals nothing, reads nothing, and writes
-- nothing, so `authenticated` executing it costs the school no privacy. What it
-- must NOT be is unexecutable, because then the row it guards cannot be written
-- at all.
grant execute on function public.fn_photo_path_ok(text, text, uuid) to authenticated;

-- Belt and braces for a self-hosted install where the default PUBLIC grant was
-- stripped project-wide: name every role that writes these tables. anon is
-- deliberately absent — it writes nothing.
--
-- Conditional because `service_role` is a Supabase role. CI and the local
-- harness run on plain Postgres 16 with only anon and authenticated, and a
-- migration that fails there fails the build for a grant that is belt to an
-- existing brace.
do $$
begin
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    grant execute on function public.fn_photo_path_ok(text, text, uuid) to service_role;
  end if;
end $$;

do $$
declare v_missing text;
begin
  -- Assert the END STATE rather than trusting the grants above to be the whole
  -- list. If a later migration adds another constraint function and forgets the
  -- grant, this fires on the next apply instead of on a school's first
  -- admission.
  select string_agg(distinct f.proname, ', ') into v_missing
    from pg_constraint con
    join pg_class rel on rel.oid = con.conrelid
    join pg_namespace n on n.oid = rel.relnamespace
    join pg_proc f on f.pronamespace = 'public'::regnamespace
    join pg_namespace fn on fn.oid = f.pronamespace
   where n.nspname = 'public' and con.contype = 'c'
     and pg_get_constraintdef(con.oid) like '%' || f.proname || '(%'
     and not has_function_privilege('authenticated', f.oid, 'EXECUTE');

  if v_missing is not null then
    raise exception
      'CHECK constraints call %, which `authenticated` cannot execute — every table using them is unwritable by a signed-in user',
      v_missing;
  end if;
end $$;

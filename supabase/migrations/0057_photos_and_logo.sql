-- =============================================================================
-- 0057 — Photographs of children, staff photographs, and the school logo.
--
-- students.photo_url and school_settings.logo_url have existed since 0001 and
-- 0006 and were never written or read by anything. This makes them real.
--
-- The full reasoning, with the argument against each decision, is in
-- docs/PHOTOS-DESIGN.md. The short version:
--
--   * ONE private bucket, `school-files`, with the school id as the SECOND path
--     segment of every object. Always second, with no exceptions, so the policy
--     is one comparison with no branches — including the logo, which is stored
--     at logos/<school>/logo.png rather than logos/<school>.png purely so that
--     it needs no special case.
--   * PRIVATE, never public. A public bucket means anyone holding the URL sees a
--     child's photograph, forever, with no login, including after they leave.
--   * The database column holds a PATH, never a URL. A signed URL expires; one
--     persisted in a column called photo_url works in testing and becomes a
--     broken image days later, which is indistinguishable from data loss.
--   * Office uploads, all staff view, PARENTS GET NOTHING — not even their own
--     child. Scoping a parent to their own children means deriving a student id
--     from a file path inside a security policy, and the cheap version would
--     show a parent every child in the school.
--
-- WHAT THIS MIGRATION DOES AND DOES NOT DO
--
-- It creates the bucket row and the policies IF the storage schema exists. On a
-- real Supabase project it does. In CI and in local testing there is no storage
-- schema, so the whole block is skipped — and the test suite builds a faithful
-- stub instead and exercises these same policy bodies against it. See
-- supabase/tests/photos.sql.
--
-- That conditional is deliberate and it is the honest shape for this: the
-- migration must not fail on a database without Supabase's storage extension,
-- and the policy logic must still be tested rather than assumed.
-- =============================================================================

-- --- The columns hold paths, so name them for what they hold ------------------
-- Both are unused, so the rename is free and prevents a whole class of mistake.
do $$
begin
  if exists (select 1 from information_schema.columns
              where table_schema='public' and table_name='students'
                and column_name='photo_url') then
    alter table public.students rename column photo_url to photo_path;
  end if;
  if exists (select 1 from information_schema.columns
              where table_schema='public' and table_name='school_settings'
                and column_name='logo_url') then
    alter table public.school_settings rename column logo_url to logo_path;
  end if;
end $$;

-- Staff photographs, for the ID card that already exists in the app.
alter table public.staff add column if not exists photo_path text;

comment on column public.students.photo_path is
  'Object path inside the school-files bucket. NEVER a URL — signed URLs expire.';
comment on column public.school_settings.logo_path is
  'Object path inside the school-files bucket. NEVER a URL.';
comment on column public.staff.photo_path is
  'Object path inside the school-files bucket. NEVER a URL.';

-- A path must be inside this school's folder. The app builds these paths, but
-- the app is not the only thing that can write the column, and a path pointing
-- at another school's folder would hand that school's photograph to this one.
-- Checked as a CONSTRAINT so it holds regardless of which code path writes it.
create or replace function public.fn_photo_path_ok(p_path text, p_kind text, p_school uuid)
returns boolean language sql immutable as $$
  select p_path is null
      or p_path = p_kind || '/' || p_school::text || '/' ||
         substring(p_path from '[^/]+$')
     and substring(p_path from '[^/]+$') <> ''
     and p_path not like '%..%';
$$;

alter table public.students drop constraint if exists students_photo_path_chk;
alter table public.students add constraint students_photo_path_chk
  check (public.fn_photo_path_ok(photo_path, 'students', school_id));

alter table public.staff drop constraint if exists staff_photo_path_chk;
alter table public.staff add constraint staff_photo_path_chk
  check (public.fn_photo_path_ok(photo_path, 'staff', school_id));

alter table public.school_settings drop constraint if exists school_settings_logo_path_chk;
alter table public.school_settings add constraint school_settings_logo_path_chk
  check (public.fn_photo_path_ok(logo_path, 'logos', school_id));

-- ---------------------------------------------------------------------------
-- Who may set a photo path
--
-- Not a plain table UPDATE: students_write lets a clerk change any student
-- column, and these three need the same office-only rule in one place plus a
-- path this school is allowed to use.
-- ---------------------------------------------------------------------------
create or replace function public.fn_set_student_photo(p_student_id uuid, p_path text)
returns text language plpgsql security definer set search_path = public as $$
declare v_school uuid := public.current_school_id(); v_expect text;
begin
  if not public.has_role('owner', 'principal', 'admin_clerk') then
    raise exception 'Only the office may change a pupil''s photograph'
      using errcode = '42501';
  end if;
  perform public.assert_own('students', p_student_id);

  -- The path is DERIVED here, never accepted from the caller. A caller-supplied
  -- path is a caller-supplied school folder.
  v_expect := case when p_path is null then null
                   else 'students/' || v_school::text || '/' || p_student_id::text
                        || '.' || lower(coalesce(nullif(substring(p_path from '\.([A-Za-z0-9]+)$'), ''), 'jpg'))
              end;

  update public.students set photo_path = v_expect
   where id = p_student_id and school_id = v_school;
  return v_expect;
end;
$$;

create or replace function public.fn_set_staff_photo(p_staff_id uuid, p_path text)
returns text language plpgsql security definer set search_path = public as $$
declare v_school uuid := public.current_school_id(); v_expect text;
begin
  if not public.has_role('owner', 'principal', 'admin_clerk') then
    raise exception 'Only the office may change a staff photograph'
      using errcode = '42501';
  end if;
  perform public.assert_own('staff', p_staff_id);
  v_expect := case when p_path is null then null
                   else 'staff/' || v_school::text || '/' || p_staff_id::text
                        || '.' || lower(coalesce(nullif(substring(p_path from '\.([A-Za-z0-9]+)$'), ''), 'jpg'))
              end;
  update public.staff set photo_path = v_expect
   where id = p_staff_id and school_id = v_school;
  return v_expect;
end;
$$;

create or replace function public.fn_set_school_logo(p_path text)
returns text language plpgsql security definer set search_path = public as $$
declare v_school uuid := public.current_school_id(); v_expect text;
begin
  -- The logo is the school's identity on every printed challan and result card.
  -- A clerk should not be able to change it.
  if not public.has_role('owner', 'principal') then
    raise exception 'Only an owner or principal may change the school logo'
      using errcode = '42501';
  end if;
  if v_school is null then
    raise exception 'No school context' using errcode = '42501';
  end if;
  v_expect := case when p_path is null then null
                   else 'logos/' || v_school::text || '/logo.'
                        || lower(coalesce(nullif(substring(p_path from '\.([A-Za-z0-9]+)$'), ''), 'png'))
              end;
  update public.school_settings set logo_path = v_expect where school_id = v_school;
  return v_expect;
end;
$$;

-- ---------------------------------------------------------------------------
-- Reading the paths back
--
-- One call returns every path a class list needs, so the app can sign a whole
-- class in ONE createSignedUrls request rather than forty.
-- ---------------------------------------------------------------------------
create or replace function public.fn_class_photo_paths(p_class_id uuid, p_section_id uuid default null)
returns table (student_id uuid, full_name text, roll_no text, photo_path text)
language plpgsql stable security definer set search_path = public as $$
declare v_school uuid := public.current_school_id();
begin
  if not public.is_staff() then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  perform public.assert_own('classes', p_class_id);
  perform public.assert_own('sections', p_section_id);

  return query
  select s.id, s.full_name, e.roll_no, s.photo_path
  from public.enrollments e
  join public.students s on s.id = e.student_id and s.school_id = v_school
  join public.academic_sessions ses
    on ses.id = e.session_id and ses.school_id = v_school and ses.is_current
  where e.school_id = v_school
    and e.class_id = p_class_id
    and (p_section_id is null or e.section_id = p_section_id)
    and e.status = 'active'
    and s.deleted_at is null
  order by coalesce(nullif(regexp_replace(coalesce(e.roll_no,''),'[^0-9]','','g'),'')::int,
                    2147483647),
           s.full_name;
end;
$$;

revoke all on function public.fn_set_student_photo(uuid, text) from public;
revoke all on function public.fn_set_staff_photo(uuid, text) from public;
revoke all on function public.fn_set_school_logo(text) from public;
revoke all on function public.fn_class_photo_paths(uuid, uuid) from public;
revoke all on function public.fn_photo_path_ok(text, text, uuid) from public;

grant execute on function public.fn_set_student_photo(uuid, text) to authenticated;
grant execute on function public.fn_set_staff_photo(uuid, text) to authenticated;
grant execute on function public.fn_set_school_logo(text) to authenticated;
grant execute on function public.fn_class_photo_paths(uuid, uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- The bucket and its policies — only where a storage schema exists.
--
-- On a real Supabase project this runs. In CI and locally there is no storage
-- schema, so it is skipped and supabase/tests/photos.sql exercises the SAME
-- policy expressions against a faithful stub instead.
--
-- The policy expression is kept in ONE function so that the live policy and the
-- tested logic cannot drift apart. That is the whole trick: a policy that calls
-- fn_may_touch_school_file() is a policy whose logic is ordinary, testable SQL.
-- ---------------------------------------------------------------------------
create or replace function public.fn_may_read_school_file(p_name text)
returns boolean language sql stable security definer set search_path = public as $$
  -- The school is ALWAYS the second path segment. No branches, no special cases.
  select public.is_staff()
     and (string_to_array(p_name, '/'))[2] = public.current_school_id()::text
     and (string_to_array(p_name, '/'))[1] in ('students', 'staff', 'logos');
$$;

create or replace function public.fn_may_write_school_file(p_name text)
returns boolean language sql stable security definer set search_path = public as $$
  select public.has_role('owner', 'principal', 'admin_clerk')
     and (string_to_array(p_name, '/'))[2] = public.current_school_id()::text
     and (string_to_array(p_name, '/'))[1] in ('students', 'staff', 'logos')
     -- No traversal, and a real filename.
     and p_name not like '%..%'
     and coalesce(substring(p_name from '[^/]+$'), '') <> '';
$$;

revoke all on function public.fn_may_read_school_file(text) from public;
revoke all on function public.fn_may_write_school_file(text) from public;
grant execute on function public.fn_may_read_school_file(text) to authenticated;
grant execute on function public.fn_may_write_school_file(text) to authenticated;

do $storage$
begin
  if not exists (select 1 from information_schema.schemata where schema_name = 'storage') then
    raise notice '0057: no storage schema here — bucket and policies skipped. '
                 'This is expected in CI and locally; see supabase/tests/photos.sql, '
                 'which tests the same policy functions against a stub.';
    return;
  end if;

  -- The bucket. Private, with the size and type limits that are the ACTUAL
  -- enforcement — the browser downscale is a courtesy a crafted request skips.
  insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
  values ('school-files', 'school-files', false, 2097152,
          array['image/jpeg', 'image/png', 'image/webp'])
  on conflict (id) do update
     set public = false,
         file_size_limit = 2097152,
         allowed_mime_types = array['image/jpeg', 'image/png', 'image/webp'];

  execute $p$drop policy if exists school_files_read on storage.objects$p$;
  execute $p$drop policy if exists school_files_insert on storage.objects$p$;
  execute $p$drop policy if exists school_files_update on storage.objects$p$;
  execute $p$drop policy if exists school_files_delete on storage.objects$p$;

  execute $p$
    create policy school_files_read on storage.objects for select to authenticated
    using (bucket_id = 'school-files' and public.fn_may_read_school_file(name))$p$;
  execute $p$
    create policy school_files_insert on storage.objects for insert to authenticated
    with check (bucket_id = 'school-files' and public.fn_may_write_school_file(name))$p$;
  execute $p$
    create policy school_files_update on storage.objects for update to authenticated
    using (bucket_id = 'school-files' and public.fn_may_write_school_file(name))
    with check (bucket_id = 'school-files' and public.fn_may_write_school_file(name))$p$;
  execute $p$
    create policy school_files_delete on storage.objects for delete to authenticated
    using (bucket_id = 'school-files' and public.fn_may_write_school_file(name))$p$;

  raise notice '0057: school-files bucket and its four policies are in place.';
end
$storage$;

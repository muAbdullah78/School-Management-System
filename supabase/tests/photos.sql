-- =============================================================================
-- Photographs of children, staff photographs, and the school logo.
--
-- A photograph of a child is the most sensitive thing this system holds, and the
-- failure mode is one school fetching another school's pupils' photographs.
--
-- THE POINT OF THIS FILE. Supabase storage policies are often treated as
-- untestable because the storage schema only exists on a real project. They are
-- not untestable: a policy is ordinary SQL. This file builds a FAITHFUL STUB of
-- storage.objects — same shape, RLS enabled, the same policy bodies migration
-- 0057 installs — and then exercises it as `authenticated` from two schools in
-- both directions.
--
-- The policies in 0057 call fn_may_read_school_file / fn_may_write_school_file
-- precisely so the live policy and the tested logic cannot drift: there is one
-- copy of the rule and this suite runs it.
--
-- The rules this file defends:
--
--  1. THE SCHOOL SEGMENT IS THE WHOLE GUARD. A path is readable only when its
--     second segment is the caller's school. Asserted in both directions.
--  2. A CALLER CANNOT CHOOSE THE PATH. fn_set_student_photo DERIVES the path
--     from the school and the student id and ignores whatever it was handed, so
--     "put this photo in another school's folder" is not expressible.
--  3. THE COLUMN CANNOT HOLD A FOREIGN PATH even via a direct UPDATE, because
--     the check constraint does not care which code path wrote it.
--  4. PARENTS GET NOTHING. Not even their own child, deliberately — see
--     docs/PHOTOS-DESIGN.md section 5.
--  5. TEACHERS READ, THE OFFICE WRITES.
--  6. NO PATH TRAVERSAL, no empty filename, no nested directories.
--
-- Run: psql -v ON_ERROR_STOP=1 -f supabase/tests/photos.sql
-- =============================================================================

\set ON_ERROR_STOP on

begin;

create or replace function auth.uid() returns uuid language sql stable as
  $$ select nullif(current_setting('test.uid', true), '')::uuid $$;

create or replace function pg_temp.ok(p_cond boolean, p_label text)
returns void language plpgsql as $$
begin
  if p_cond then raise notice 'PASS  %', p_label;
  else raise exception 'FAIL  %', p_label; end if;
end;
$$;

create or replace function pg_temp.be(p_name text) returns void language sql as $$
  select set_config('test.uid',
    (select id::text from public.profiles where full_name = p_name), false);
$$;

create or replace function pg_temp.refuses(p_sql text, p_label text, p_expect text default null)
returns void language plpgsql as $$
begin
  begin
    execute p_sql;
  exception when others then
    if sqlerrm like 'FAIL%' then raise; end if;
    if p_expect is not null and sqlerrm not like p_expect then
      raise exception 'FAIL  % — refused, but with the wrong message: %', p_label, sqlerrm;
    end if;
    raise notice 'PASS  % (%)', p_label, sqlerrm;
    return;
  end;
  raise exception 'FAIL  % — it was ALLOWED', p_label;
end;
$$;

create or replace function pg_temp.stu(p_name text) returns uuid language sql as $$
  select id from public.students where full_name = p_name and deleted_at is null
$$;
create or replace function pg_temp.sch(p_name text) returns uuid language sql as $$
  select id from public.schools where name = p_name
$$;

-- --- A FAITHFUL STUB of Supabase storage -------------------------------------
-- Same table shape and same RLS behaviour. The policies below are the ones
-- migration 0057 installs on a real project, character for character in the
-- part that matters: they delegate to the two functions 0057 defines.
create schema if not exists storage;
drop table if exists storage.objects;
create table storage.objects (
  id        uuid primary key default gen_random_uuid(),
  bucket_id text not null,
  name      text not null,
  owner     uuid,
  unique (bucket_id, name)
);
alter table storage.objects enable row level security;
-- Supabase grants USAGE on the storage schema to authenticated; the stub must
-- too, or every assertion below fails with "permission denied for schema" and
-- proves nothing about the policies.
grant usage on schema storage to authenticated;
grant select, insert, update, delete on storage.objects to authenticated;

create policy school_files_read on storage.objects for select to authenticated
  using (bucket_id = 'school-files' and public.fn_may_read_school_file(name));
create policy school_files_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'school-files' and public.fn_may_write_school_file(name));
create policy school_files_update on storage.objects for update to authenticated
  using (bucket_id = 'school-files' and public.fn_may_write_school_file(name))
  with check (bucket_id = 'school-files' and public.fn_may_write_school_file(name));
create policy school_files_delete on storage.objects for delete to authenticated
  using (bucket_id = 'school-files' and public.fn_may_write_school_file(name));

-- --- Fixture -----------------------------------------------------------------
do $seed$
declare
  v_a uuid; v_b uuid;
  v_oa uuid := '00000000-0000-0000-0000-0000000f0a01';
  v_pa uuid := '00000000-0000-0000-0000-0000000f0a02';
  v_ca uuid := '00000000-0000-0000-0000-0000000f0a03';
  v_ta uuid := '00000000-0000-0000-0000-0000000f0a04';
  v_pr uuid := '00000000-0000-0000-0000-0000000f0a05';
  v_ob uuid := '00000000-0000-0000-0000-0000000f0a06';
  v_sa uuid; v_sb uuid; v_cla uuid; v_seca uuid; v_clb uuid;
begin
  insert into public.schools (name) values ('Photo A') returning id into v_a;
  insert into public.subscriptions (school_id, plan_code, status, trial_ends_on)
    values (v_a, 'growth', 'active', current_date + 30);
  insert into public.schools (name) values ('Photo B') returning id into v_b;
  insert into public.subscriptions (school_id, plan_code, status, trial_ends_on)
    values (v_b, 'growth', 'active', current_date + 30);

  alter table public.profiles disable trigger user;
  insert into auth.users (id, email) values
    (v_oa,'pa@ph.test'), (v_pa,'pp@ph.test'), (v_ca,'pc@ph.test'),
    (v_ta,'pt@ph.test'), (v_pr,'ppar@ph.test'), (v_ob,'pb@ph.test')
  on conflict (id) do nothing;
  insert into public.profiles (id, full_name, role, school_id) values
    (v_oa, 'Ph Owner',     'owner',         v_a),
    (v_pa, 'Ph Principal', 'principal',     v_a),
    (v_ca, 'Ph Clerk',     'admin_clerk',   v_a),
    (v_ta, 'Ph Teacher',   'class_teacher', v_a),
    (v_pr, 'Ph Parent',    'parent',        v_a),
    (v_ob, 'Ph Owner B',   'owner',         v_b)
  on conflict (id) do update set school_id = excluded.school_id,
                                 role = excluded.role, full_name = excluded.full_name,
                                 active = true;
  alter table public.profiles enable trigger user;

  perform set_config('test.uid', v_oa::text, false);
  insert into public.academic_sessions (name, is_current, school_id)
    values ('2025-2026', true, v_a) returning id into v_sa;
  update public.school_settings set current_session_id = v_sa where school_id = v_a;
  insert into public.classes (name, level_order, school_id)
    values ('Ph One', 1, v_a) returning id into v_cla;
  insert into public.sections (class_id, name, sort_order, school_id)
    values (v_cla, 'A', 1, v_a) returning id into v_seca;
  perform public.fn_admit_student(jsonb_build_object(
    'full_name','Photo Child','father_name','PC Father','father_cnic','35201-7700001-1',
    'session_id',v_sa,'class_id',v_cla,'section_id',v_seca,'roll_no','1','links','[]'::jsonb));
  perform public.fn_admit_student(jsonb_build_object(
    'full_name','Photo Second','father_name','PS Father','father_cnic','35201-7700002-2',
    'session_id',v_sa,'class_id',v_cla,'section_id',v_seca,'roll_no','2','links','[]'::jsonb));
  insert into public.staff (full_name, joined_on, school_id)
    values ('Ph Staffer', current_date - 100, v_a);

  perform set_config('test.uid', v_ob::text, false);
  insert into public.academic_sessions (name, is_current, school_id)
    values ('2025-2026', true, v_b) returning id into v_sb;
  update public.school_settings set current_session_id = v_sb where school_id = v_b;
  insert into public.classes (name, level_order, school_id)
    values ('Ph B One', 1, v_b) returning id into v_clb;
  perform public.fn_admit_student(jsonb_build_object(
    'full_name','B Photo Child','father_name','BPC','father_cnic','35201-7800001-1',
    'session_id',v_sb,'class_id',v_clb,'roll_no','1','links','[]'::jsonb));

  perform set_config('test.uid', v_oa::text, false);
end;
$seed$;

-- =============================================================================
-- 1. A caller cannot choose the path
-- =============================================================================
do $$
declare v_c uuid := pg_temp.stu('Photo Child'); v_a uuid := pg_temp.sch('Photo A');
        v_b uuid := pg_temp.sch('Photo B'); p text;
begin
  perform pg_temp.be('Ph Clerk');

  -- Hand it another school's folder and a traversal, and see what it stores.
  p := public.fn_set_student_photo(v_c, 'students/' || v_b::text || '/../evil.jpg');
  perform pg_temp.ok(p = 'students/' || v_a::text || '/' || v_c::text || '.jpg',
    '1. the path is DERIVED from the school and the pupil, never taken from the '
    'caller — "put it in school B''s folder" is not expressible (got ' || p || ')');

  perform pg_temp.ok(
    (select photo_path from public.students where id = v_c) = p,
    '2. and that is what the column holds');

  -- The extension is carried across, lower-cased, and nothing else is.
  p := public.fn_set_student_photo(v_c, 'anything/at/all/PHOTO.PNG');
  perform pg_temp.ok(p like '%.png',
    '3. the file extension survives, lower-cased (got ' || p || ')');

  p := public.fn_set_student_photo(v_c, 'no-extension-at-all');
  perform pg_temp.ok(p like '%.jpg',
    '4. a path with no extension falls back to .jpg rather than producing a '
    'file with no type (got ' || p || ')');

  perform pg_temp.ok(public.fn_set_student_photo(v_c, null) is null,
    '5. null clears the photo');
  perform pg_temp.ok(
    (select photo_path from public.students where id = v_c) is null,
    '6. and the column is cleared, so the avatar falls back to initials');
end;
$$;

-- =============================================================================
-- 2. Who may write
-- =============================================================================
do $$
declare v_c uuid := pg_temp.stu('Photo Child');
        v_st uuid := (select id from public.staff where full_name = 'Ph Staffer');
begin
  perform pg_temp.be('Ph Teacher');
  perform pg_temp.refuses(
    format('select public.fn_set_student_photo(%L::uuid, ''x.jpg'')', v_c),
    '7. a class teacher cannot replace a pupil''s photograph — a records change, '
    'not a classroom action', '%Only the office%');
  perform pg_temp.be('Ph Parent');
  perform pg_temp.refuses(
    format('select public.fn_set_student_photo(%L::uuid, ''x.jpg'')', v_c),
    '8. nor a parent', '%Only the office%');

  perform pg_temp.be('Ph Clerk');
  perform pg_temp.ok(public.fn_set_staff_photo(v_st, 'a.jpg') like 'staff/%',
    '9. a clerk may set a staff photograph, for the ID card');
  perform pg_temp.refuses('select public.fn_set_school_logo(''logo.png'')',
    '10. but NOT the school logo — it is the school''s identity on every printed '
    'challan and result card', '%owner or principal%');

  perform pg_temp.be('Ph Principal');
  perform pg_temp.ok(public.fn_set_school_logo('LOGO.PNG') like 'logos/%/logo.png',
    '11. a principal may set the logo');
end;
$$;

-- =============================================================================
-- 3. The column cannot hold a foreign path, whatever wrote it
-- =============================================================================
do $$
declare v_c uuid := pg_temp.stu('Photo Child'); v_b uuid := pg_temp.sch('Photo B');
begin
  perform pg_temp.refuses(
    format('update public.students set photo_path = %L where id = %L::uuid',
           'students/' || v_b::text || '/' || v_c::text || '.jpg', v_c),
    '12. a DIRECT UPDATE cannot point the column at another school''s folder — '
    'the constraint does not care which code path wrote it',
    '%students_photo_path_chk%');
  perform pg_temp.refuses(
    format('update public.students set photo_path = ''students/../../etc/passwd'' where id = %L::uuid', v_c),
    '13. nor at a traversal', '%students_photo_path_chk%');
  perform pg_temp.refuses(
    format('update public.students set photo_path = ''photos/x/y.jpg'' where id = %L::uuid', v_c),
    '14. nor at a folder that is not one of the three kinds',
    '%students_photo_path_chk%');
end;
$$;

-- =============================================================================
-- 4. THE ISOLATION GUARANTEE — the storage policies, run as authenticated
-- =============================================================================
do $$
declare
  v_a uuid := pg_temp.sch('Photo A'); v_b uuid := pg_temp.sch('Photo B');
  n integer;
begin
  -- Seed one object per school, as the table owner (RLS does not apply to the
  -- owner, which is why every assertion below switches role explicitly).
  insert into storage.objects (bucket_id, name) values
    ('school-files', 'students/' || v_a::text || '/a-child.jpg'),
    ('school-files', 'students/' || v_b::text || '/b-child.jpg'),
    ('school-files', 'logos/'    || v_a::text || '/logo.png'),
    ('school-files', 'logos/'    || v_b::text || '/logo.png');

  perform pg_temp.be('Ph Owner');
  set local role authenticated;
  select count(*) into n from storage.objects;
  perform pg_temp.ok(n = 2,
    '15. school A sees exactly its OWN two objects, not school B''s (got '
      || n || ' of 4)');
  select count(*) into n from storage.objects where name like '%b-child%';
  perform pg_temp.ok(n = 0,
    '16. and school B''s pupil photograph is invisible — THE guarantee this '
    'whole feature turns on');
  reset role;

  perform pg_temp.be('Ph Owner B');
  set local role authenticated;
  select count(*) into n from storage.objects;
  perform pg_temp.ok(n = 2, '17. and the boundary holds in the other direction');
  select count(*) into n from storage.objects where name like '%a-child%';
  perform pg_temp.ok(n = 0, '18. school A''s pupil is invisible to school B');
  reset role;
end;
$$;

-- =============================================================================
-- 5. Who the storage policies let read and write
-- =============================================================================
do $$
declare v_a uuid := pg_temp.sch('Photo A'); v_b uuid := pg_temp.sch('Photo B'); n integer;
begin
  perform pg_temp.be('Ph Teacher');
  set local role authenticated;
  select count(*) into n from storage.objects;
  perform pg_temp.ok(n = 2,
    '19. a class teacher CAN see their school''s photographs — identifying the '
    'children in front of you is the point of the feature');
  reset role;

  perform pg_temp.be('Ph Parent');
  set local role authenticated;
  select count(*) into n from storage.objects;
  perform pg_temp.ok(n = 0,
    '20. a parent sees NOTHING, not even their own child — scoping that '
    'correctly needs a student id parsed out of a path inside a policy, and the '
    'cheap version shows them every child in the school');
  reset role;

  -- Writes.
  perform pg_temp.be('Ph Clerk');
  set local role authenticated;
  insert into storage.objects (bucket_id, name)
    values ('school-files', 'students/' || v_a::text || '/new.jpg');
  perform pg_temp.ok(true, '21. a clerk may upload into their own school''s folder');
  reset role;

  perform pg_temp.be('Ph Teacher');
  set local role authenticated;
  begin
    insert into storage.objects (bucket_id, name)
      values ('school-files', 'students/' || v_a::text || '/teacher-tried.jpg');
    reset role;
    raise exception 'FAIL  22. a teacher was allowed to UPLOAD';
  exception when insufficient_privilege or check_violation then
    reset role;
    raise notice 'PASS  22. a teacher may read but not upload';
  end;

  perform pg_temp.be('Ph Clerk');
  set local role authenticated;
  begin
    insert into storage.objects (bucket_id, name)
      values ('school-files', 'students/' || v_b::text || '/stolen.jpg');
    reset role;
    raise exception 'FAIL  23. a clerk wrote into ANOTHER school''s folder';
  exception when insufficient_privilege or check_violation then
    reset role;
    raise notice 'PASS  23. a clerk cannot write into another school''s folder';
  end;

  perform pg_temp.be('Ph Clerk');
  set local role authenticated;
  begin
    insert into storage.objects (bucket_id, name)
      values ('school-files', 'students/' || v_a::text || '/../escape.jpg');
    reset role;
    raise exception 'FAIL  24. a traversal was accepted';
  exception when insufficient_privilege or check_violation then
    reset role;
    raise notice 'PASS  24. a path containing .. is refused';
  end;

  -- Deleting another school's object must affect NOTHING. A policy-less DELETE
  -- silently touches zero rows rather than raising, so the row count is the
  -- assertion — checking for an exception here would pass while deleting.
  perform pg_temp.be('Ph Clerk');
  set local role authenticated;
  with gone as (delete from storage.objects
                 where name like 'students/' || v_b::text || '%' returning 1)
  select count(*) into n from gone;
  reset role;
  perform pg_temp.ok(n = 0,
    '25. deleting another school''s photograph affects ZERO rows — asserted by '
    'count, because a DELETE with no matching policy silently does nothing '
    'rather than raising');
  select count(*) into n from storage.objects where name like 'students/' || v_b::text || '%';
  perform pg_temp.ok(n = 1, '26. and school B''s object is still there');
end;
$$;

-- =============================================================================
-- 6. The class photo list — one call so a class can be signed in one request
-- =============================================================================
do $$
declare v_cl uuid; v_c uuid := pg_temp.stu('Photo Child'); n integer; r record;
begin
  perform pg_temp.be('Ph Clerk');
  select id into v_cl from public.classes where name = 'Ph One';
  perform public.fn_set_student_photo(v_c, 'x.jpg');

  select count(*) into n from public.fn_class_photo_paths(v_cl, null);
  perform pg_temp.ok(n = 2, '27. the whole class comes back in one call');

  select * into r from public.fn_class_photo_paths(v_cl, null)
   where student_id = v_c;
  perform pg_temp.ok(r.photo_path is not null, '28. with the path for the one who has a photo');
  select * into r from public.fn_class_photo_paths(v_cl, null)
   where full_name = 'Photo Second';
  perform pg_temp.ok(r.photo_path is null,
    '29. and null for the one who has none — a missing photograph is a normal '
    'state, not an error');

  perform pg_temp.ok(
    (select full_name from public.fn_class_photo_paths(v_cl, null) limit 1) = 'Photo Child',
    '30. in roll-number order, so it matches the register');

  perform pg_temp.be('Ph Teacher');
  perform pg_temp.ok((select count(*) from public.fn_class_photo_paths(v_cl, null)) = 2,
    '31. a teacher may read it');
  perform pg_temp.be('Ph Parent');
  perform pg_temp.refuses(format('select count(*) from public.fn_class_photo_paths(%L::uuid, null)', v_cl),
    '32. a parent may not', '%Not permitted%');

  perform pg_temp.be('Ph Owner B');
  perform pg_temp.refuses(format('select count(*) from public.fn_class_photo_paths(%L::uuid, null)', v_cl),
    '33. and another school cannot read my class list',
    '%classes not found in this school%');
end;
$$;

-- =============================================================================
-- 7. Cross-school writes through the setter functions
-- =============================================================================
do $$
declare v_c uuid := pg_temp.stu('Photo Child');
begin
  perform pg_temp.be('Ph Owner B');
  perform pg_temp.refuses(
    format('select public.fn_set_student_photo(%L::uuid, ''x.jpg'')', v_c),
    '34. another school''s owner cannot set my pupil''s photograph',
    '%students not found in this school%');
end;
$$;

rollback;

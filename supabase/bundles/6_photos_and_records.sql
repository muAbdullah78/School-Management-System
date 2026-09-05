-- =============================================================================
-- GENERATED FILE — DO NOT EDIT.
-- Built from supabase/migrations/ by supabase/build-bundles.sh
--
-- Paste this whole file into the Supabase SQL Editor and press Run.
-- Run the bundles in order, one at a time, waiting for each to finish.
-- =============================================================================


-- ─────────────────────────────────────────────────────────────────────────
-- 0057_photos_and_logo.sql
-- ─────────────────────────────────────────────────────────────────────────
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

-- ─────────────────────────────────────────────────────────────────────────
-- 0058_exam_computation.sql
-- ─────────────────────────────────────────────────────────────────────────
-- =============================================================================
-- 0058 — The result card was wrong, and confidently wrong.
--
-- Demonstrated on a live database before anything here was written. One class of
-- three in class 9, English for everybody, Physics for Science, Civics for Arts,
-- everyone who sat a paper doing well:
--
--   Arts Child     card said 180/275 = 65.45%  grade C  position 1
--                  truth    180/200 = 90.00%  grade A+
--   Science Child  card said 160/275 = 58.18%  grade D  position 2
--                  truth    160/175 = 91.43%  grade A+
--   Unmarked Child card said   0/275 =  0.00%  grade F  position 3
--                  truth    nobody had entered their marks yet
--
-- Three defects, each sufficient on its own to lose a school:
--
--  1. STREAMS WERE IGNORED. total_max summed every paper in the class, so a
--     Science pupil was marked out of the Arts syllabus too and a zero was
--     silently supplied for a paper they were never meant to sit. Two A+ pupils
--     became a C and a D. subjects.stream and enrollments.stream had existed
--     since the schema was written and nothing read either.
--
--  2. IT INVERTED THE RANKING. On the true figures the Science pupil comes
--     first. The card had them second, because the wrong denominator punished
--     them harder — Physics is out of 75, so a missing Civics 100 costs more.
--     Prize day would have gone to the wrong child.
--
--  3. A PUPIL NOBODY HAD MARKED WAS PRINTED AS HAVING FAILED. Not blank, not
--     pending: 0.00%, grade F, ranked. One coalesce(sum(...), 0) made "no mark
--     exists" and "a mark of zero" the same thing.
--
-- And two dead features that are the same bug in slower motion:
--
--  4. exam_subjects.practical_max reached nothing — mark_entries had a single
--     marks column, so a school could set Physics theory 75 + practical 25 and
--     had nowhere to enter the practical.
--  5. exam_subjects.pass_marks was frozen onto every card and never used. No
--     card said Pass or Fail. Pakistani result cards say Pass or Fail.
--
-- The design, with the argument against each decision, is in
-- docs/EXAM-COMPUTATION-DESIGN.md. The assertions are in
-- supabase/tests/exam_computation.sql.
--
-- THE RULE THAT SHAPES ALL OF IT: a refusal is recoverable, a plausible wrong
-- card is not. Where this migration cannot know the answer it raises and names
-- what is missing, rather than supplying a zero.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. Practical marks get somewhere to live
-- ---------------------------------------------------------------------------
alter table public.mark_entries
  add column if not exists practical_marks numeric;

comment on column public.mark_entries.practical_marks is
  'The practical half of a subject mark, against exam_subjects.practical_max. '
  'NULL when the subject has no practical component. Kept separate from marks '
  'because a result card shows theory and practical in their own columns.';

-- ---------------------------------------------------------------------------
-- 2. Class assessments can contribute to a term, if the term says so
--
-- Zero is the default and zero is exactly today's behaviour. An engine that
-- silently started reweighting a school's result cards mid-session would be
-- indefensible however correct its arithmetic.
-- ---------------------------------------------------------------------------
alter table public.exam_terms
  add column if not exists assessment_weight_pct numeric not null default 0;

alter table public.exam_terms drop constraint if exists exam_terms_assessment_weight_chk;
alter table public.exam_terms add constraint exam_terms_assessment_weight_chk
  check (assessment_weight_pct >= 0 and assessment_weight_pct <= 100);

comment on column public.exam_terms.assessment_weight_pct is
  'Share of the term result carried by class assessments rather than the term '
  'papers. 0 (the default) means the papers carry all of it, which is what every '
  'term did before 0058.';

-- ---------------------------------------------------------------------------
-- 3. Does this pupil take this subject?
--
-- The single rule the whole stream fix rests on, in one place so it cannot drift
-- between the marksheet, the generator and the tabulation sheet.
--
-- Compared case-insensitively and trimmed: a school that types 'science' in one
-- place and 'Science' in another would otherwise silently exclude every pupil
-- from every streamed paper, which looks exactly like defect 1 and would be
-- blamed on the software, correctly.
-- ---------------------------------------------------------------------------
create or replace function public.fn_takes_subject(
  p_subject_stream text, p_enrollment_stream text
) returns boolean language sql immutable as $$
  select case
    -- No stream on the subject: everybody in the class takes it.
    when nullif(btrim(coalesce(p_subject_stream, '')), '') is null then true
    -- A streamed subject and a pupil with no stream: NOT taken. Generation
    -- refuses in this case rather than relying on this answer (see
    -- fn_generate_result_cards), because a pupil quietly missing half their
    -- subjects is the same silent wrongness in a new place.
    when nullif(btrim(coalesce(p_enrollment_stream, '')), '') is null then false
    else lower(btrim(p_subject_stream)) = lower(btrim(p_enrollment_stream))
  end;
$$;

comment on function public.fn_takes_subject(text, text) is
  'Whether a pupil in a given stream sits a given subject. The one place the '
  'stream rule lives, so the marksheet and the result card cannot disagree.';

-- ---------------------------------------------------------------------------
-- 4. The marksheet stops listing pupils who never sat the paper
--
-- Previously the Physics marksheet listed the Arts pupils too. A teacher either
-- leaves them blank — which used to produce a zero on the card — or types
-- something, and typing something is worse.
--
-- Gains a practical column, and reports whether the subject has one, so the
-- screen can show the right number of boxes.
-- ---------------------------------------------------------------------------
drop function if exists public.fn_exam_marksheet(uuid);
create or replace function public.fn_exam_marksheet(p_exam_subject_id uuid)
returns table (
  enrollment_id uuid, student_id uuid, full_name text, roll_no text,
  section_name text, marks numeric, practical_marks numeric,
  is_absent boolean, is_locked boolean, max_marks numeric, practical_max numeric
)
language plpgsql stable security definer set search_path = public as $$
declare
  v_school  uuid := public.current_school_id();
  v_session uuid; v_class uuid; v_max numeric; v_pmax numeric; v_stream text;
begin
  if not public.has_role('owner','principal','admin_clerk','class_teacher','subject_teacher') then
    raise exception 'Not permitted to view the marksheet';
  end if;
  perform public.assert_own('exam_subjects', p_exam_subject_id);

  select t.session_id, es.class_id, es.max_marks, es.practical_max, sub.stream
    into v_session, v_class, v_max, v_pmax, v_stream
  from public.exam_subjects es
  join public.exam_terms t on t.id = es.exam_term_id and t.school_id = v_school
  join public.subjects sub on sub.id = es.subject_id and sub.school_id = v_school
  where es.id = p_exam_subject_id and es.school_id = v_school;
  if v_session is null then raise exception 'Exam subject not found'; end if;

  return query
    select e.id, s.id, s.full_name, e.roll_no, sec.name,
           me.marks, me.practical_marks,
           coalesce(me.is_absent, false), coalesce(me.is_locked, false),
           v_max, coalesce(v_pmax, 0)
    from public.enrollments e
    join public.students s on s.id = e.student_id and s.school_id = v_school
    left join public.sections sec on sec.id = e.section_id and sec.school_id = v_school
    left join public.mark_entries me
      on me.exam_subject_id = p_exam_subject_id and me.enrollment_id = e.id
    where e.school_id = v_school
      and e.session_id = v_session and e.class_id = v_class
      and e.status = 'active' and s.deleted_at is null
      -- The fix for defect 5.
      and public.fn_takes_subject(v_stream, e.stream)
    order by sec.sort_order nulls first,
             coalesce(nullif(regexp_replace(coalesce(e.roll_no, ''), '[^0-9]', '', 'g'), '')::int, 2147483647),
             s.full_name;
end;
$$;

-- ---------------------------------------------------------------------------
-- 5. Mark entry accepts a practical mark, and validates it
-- ---------------------------------------------------------------------------
create or replace function public.fn_enter_marks(
  p_exam_subject_id uuid, p_marks jsonb, p_reason text default null
) returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_school uuid := public.current_school_id();
  v_actor  uuid := auth.uid();
  v_max    numeric;
  v_pmax   numeric;
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
  select max_marks, coalesce(practical_max, 0) into v_max, v_pmax
    from public.exam_subjects where id = p_exam_subject_id and school_id = v_school;
  if v_max is null then raise exception 'Exam subject not found'; end if;

  if exists (
    select 1 from jsonb_array_elements(p_marks) e
    where coalesce((e->>'is_absent')::boolean, false) = false
      and nullif(e->>'marks', '') is not null
      and ((e->>'marks')::numeric < 0 or (e->>'marks')::numeric > v_max)
  ) then
    raise exception 'Marks must be between 0 and %', v_max;
  end if;

  -- The practical is validated against its OWN maximum. Checking it against
  -- max_marks would let a 25-mark practical be entered as 70 whenever the theory
  -- paper happened to be out of 75.
  if exists (
    select 1 from jsonb_array_elements(p_marks) e
    where coalesce((e->>'is_absent')::boolean, false) = false
      and nullif(e->>'practical_marks', '') is not null
      and ((e->>'practical_marks')::numeric < 0
        or (e->>'practical_marks')::numeric > v_pmax)
  ) then
    if v_pmax = 0 then
      raise exception 'This subject has no practical component, so a practical mark cannot be entered';
    end if;
    raise exception 'Practical marks must be between 0 and %', v_pmax;
  end if;

  select count(distinct (e->>'enrollment_id')) into v_total from jsonb_array_elements(p_marks) e;

  with input as (
    select distinct on (enrollment_id) enrollment_id, marks, practical_marks, is_absent
    from (
      select (e->>'enrollment_id')::uuid as enrollment_id,
             nullif(e->>'marks', '')::numeric as marks,
             nullif(e->>'practical_marks', '')::numeric as practical_marks,
             coalesce((e->>'is_absent')::boolean, false) as is_absent
      from jsonb_array_elements(p_marks) e
    ) q
    order by enrollment_id
  ),
  upserted as (
    insert into public.mark_entries as me
      (exam_subject_id, enrollment_id, marks, practical_marks, max_marks, is_absent, marked_by)
    select p_exam_subject_id, enrollment_id, marks, practical_marks, v_max, is_absent, v_actor
      from input
    on conflict (exam_subject_id, enrollment_id) where exam_subject_id is not null
    do update set marks = excluded.marks,
                  practical_marks = excluded.practical_marks,
                  is_absent = excluded.is_absent,
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
-- 6. Setting up a paper, with the practical rule enforced
--
-- Replaces a direct upsert from the client. practical_max > 0 is refused unless
-- subjects.is_practical is set, because two columns that can disagree are how a
-- practical mark ends up somewhere nobody looks.
-- ---------------------------------------------------------------------------
create or replace function public.fn_upsert_exam_subject(
  p_exam_term_id uuid, p_class_id uuid, p_subject_id uuid,
  p_max_marks numeric, p_pass_marks numeric,
  p_practical_max numeric default 0,
  p_exam_date date default null, p_paper_time text default null
) returns uuid language plpgsql security definer set search_path = public as $$
declare
  v_school uuid := public.current_school_id();
  v_id uuid; v_is_practical boolean; v_locked boolean;
begin
  if not public.has_role('owner','principal','admin_clerk') then
    raise exception 'Not permitted to set up exam papers' using errcode = '42501';
  end if;
  perform public.assert_own('exam_terms', p_exam_term_id);
  perform public.assert_own('classes', p_class_id);
  perform public.assert_own('subjects', p_subject_id);

  select is_locked into v_locked from public.exam_terms
   where id = p_exam_term_id and school_id = v_school;
  if coalesce(v_locked, false) then
    raise exception 'This exam term is locked. Unlock it before changing papers.';
  end if;

  if coalesce(p_max_marks, 0) <= 0 then
    raise exception 'A paper must be out of more than zero marks';
  end if;
  if coalesce(p_pass_marks, 0) < 0
     or coalesce(p_pass_marks, 0) > coalesce(p_max_marks, 0) + coalesce(p_practical_max, 0) then
    raise exception 'The pass mark cannot be more than the total the paper is out of';
  end if;

  select is_practical into v_is_practical from public.subjects
   where id = p_subject_id and school_id = v_school;
  if coalesce(p_practical_max, 0) > 0 and not coalesce(v_is_practical, false) then
    raise exception 'Mark this subject as having a practical before giving it practical marks';
  end if;

  insert into public.exam_subjects
    (school_id, exam_term_id, class_id, subject_id, max_marks, pass_marks,
     practical_max, exam_date, paper_time)
  values (v_school, p_exam_term_id, p_class_id, p_subject_id, p_max_marks, p_pass_marks,
          coalesce(p_practical_max, 0), p_exam_date, nullif(btrim(coalesce(p_paper_time,'')), ''))
  on conflict (exam_term_id, class_id, subject_id)
  do update set max_marks = excluded.max_marks, pass_marks = excluded.pass_marks,
                practical_max = excluded.practical_max,
                exam_date = excluded.exam_date, paper_time = excluded.paper_time
  returning id into v_id;
  return v_id;
end;
$$;

-- ---------------------------------------------------------------------------
-- 7. What is stopping this class's result cards?
--
-- Called before generation so a screen can show the problem rather than an
-- exception, and called again INSIDE generation so the rule cannot be bypassed
-- by calling the generator directly.
--
-- Returns one row per problem, empty when there is none.
-- ---------------------------------------------------------------------------
create or replace function public.fn_result_readiness(p_exam_term_id uuid, p_class_id uuid)
returns table (problem text, detail text, affected integer)
language plpgsql stable security definer set search_path = public as $$
declare v_school uuid := public.current_school_id(); v_session uuid; v_streamed integer;
begin
  if not public.has_role('owner','principal','admin_clerk','class_teacher') then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  perform public.assert_own('exam_terms', p_exam_term_id);
  perform public.assert_own('classes', p_class_id);

  select session_id into v_session from public.exam_terms
   where id = p_exam_term_id and school_id = v_school;
  if v_session is null then raise exception 'Exam term not found'; end if;

  select count(*) into v_streamed
    from public.exam_subjects es
    join public.subjects sub on sub.id = es.subject_id and sub.school_id = v_school
   where es.school_id = v_school and es.exam_term_id = p_exam_term_id
     and es.class_id = p_class_id
     and nullif(btrim(coalesce(sub.stream, '')), '') is not null;

  -- No papers at all. Worth its own row: without it the "no marks" row below
  -- would be empty too and the screen would say everything is fine.
  return query
  select 'no papers',
         'This class has no papers set up for this term. Add them under Exam Setup.',
         0
  where not exists (
    select 1 from public.exam_subjects
     where school_id = v_school and exam_term_id = p_exam_term_id and class_id = p_class_id);

  -- A streamed class with pupils who have no stream. These pupils would
  -- otherwise get a card carrying only the common subjects, which is the same
  -- silent wrongness this migration exists to remove.
  return query
  select 'pupils without a stream',
         'This class has stream subjects, but these pupils have no stream set: '
           || string_agg(s.full_name || coalesce(' (roll ' || e.roll_no || ')', ''), ', '
                         order by s.full_name),
         count(*)::integer
    from public.enrollments e
    join public.students s on s.id = e.student_id and s.school_id = v_school
   where v_streamed > 0
     and e.school_id = v_school and e.session_id = v_session
     and e.class_id = p_class_id and e.status = 'active' and s.deleted_at is null
     and nullif(btrim(coalesce(e.stream, '')), '') is null
  having count(*) > 0;

  -- Marks not entered. Absent is NOT missing: a pupil marked absent has a fact
  -- recorded about them and scores zero. Only a row that does not exist counts.
  return query
  select 'marks not entered',
         sub.name || ' — ' || count(*)::text || ' pupil'
           || case when count(*) = 1 then '' else 's' end,
         count(*)::integer
    from public.exam_subjects es
    join public.subjects sub on sub.id = es.subject_id and sub.school_id = v_school
    join public.enrollments e
      on e.school_id = v_school and e.session_id = v_session
     and e.class_id = p_class_id and e.status = 'active'
     and public.fn_takes_subject(sub.stream, e.stream)
    join public.students s on s.id = e.student_id and s.school_id = v_school
                          and s.deleted_at is null
    left join public.mark_entries me
      on me.exam_subject_id = es.id and me.enrollment_id = e.id
   where es.school_id = v_school and es.exam_term_id = p_exam_term_id
     and es.class_id = p_class_id
     and me.id is null
   group by sub.name, sub.sort_order
   order by sub.sort_order, sub.name;
end;
$$;

-- ---------------------------------------------------------------------------
-- 8. The generator, rewritten
--
-- Every change from the previous version is a defect from the header. What has
-- NOT changed: it still INSERTS a new version rather than updating, so a remark
-- in exam_remarks survives regeneration, and the frozen snapshot is still the
-- only thing a reprint reads.
-- ---------------------------------------------------------------------------
create or replace function public.fn_generate_result_cards(
  p_exam_term_id uuid, p_class_id uuid, p_allow_incomplete boolean default false
) returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_school  uuid := public.current_school_id();
  v_actor   uuid := auth.uid();
  v_session uuid; v_from date; v_to date; v_withhold boolean; v_aw numeric;
  v_pass_pct numeric;
  v_count   integer := 0;
  v_blockers text;
  v_incomplete integer := 0;
  r         record;
  v_ver integer; v_att numeric; v_grade text; v_frozen jsonb;
  v_bal numeric; v_withheld boolean;
begin
  if not public.has_role('owner','principal','admin_clerk') then
    raise exception 'Not permitted to generate result cards';
  end if;
  perform public.assert_own('exam_terms', p_exam_term_id);
  perform public.assert_own('classes', p_class_id);

  select session_id, starts_on, ends_on, result_withheld_for_defaulters,
         coalesce(assessment_weight_pct, 0)
    into v_session, v_from, v_to, v_withhold, v_aw
  from public.exam_terms where id = p_exam_term_id and school_id = v_school;
  if v_session is null then raise exception 'Exam term not found'; end if;

  select coalesce(pass_percent, 33) into v_pass_pct
    from public.school_settings where school_id = v_school;
  v_pass_pct := coalesce(v_pass_pct, 33);

  -- ---- The refusal ---------------------------------------------------------
  -- "No papers" and "pupils without a stream" are ALWAYS fatal: neither can be
  -- rescued by treating the card as provisional, and both produce a card that
  -- is wrong rather than incomplete.
  select string_agg(detail, '; ')
    into v_blockers
    from public.fn_result_readiness(p_exam_term_id, p_class_id)
   where problem in ('no papers', 'pupils without a stream');
  if v_blockers is not null then
    raise exception '%', v_blockers;
  end if;

  select coalesce(sum(affected), 0) into v_incomplete
    from public.fn_result_readiness(p_exam_term_id, p_class_id)
   where problem = 'marks not entered';

  if v_incomplete > 0 and not coalesce(p_allow_incomplete, false) then
    select string_agg(detail, '; ' order by detail)
      into v_blockers
      from public.fn_result_readiness(p_exam_term_id, p_class_id)
     where problem = 'marks not entered';
    -- Named, not counted. "Chemistry is missing for 12 pupils" tells the
    -- principal who to chase; the zero this used to produce told them nothing
    -- and printed those pupils as having failed.
    raise exception 'Marks are missing: %. Enter them, or generate provisional cards on purpose.',
      v_blockers;
  end if;

  for r in
    -- Per pupil, over ONLY the subjects that pupil takes.
    with paper as (
      select es.id, es.subject_id, es.max_marks, es.pass_marks,
             coalesce(es.practical_max, 0) as practical_max,
             sub.name as subject_name, sub.stream, sub.sort_order
        from public.exam_subjects es
        join public.subjects sub on sub.id = es.subject_id and sub.school_id = v_school
       where es.school_id = v_school and es.exam_term_id = p_exam_term_id
         and es.class_id = p_class_id
    ),
    pupil as (
      select e.id as enrollment_id, e.student_id, e.stream, e.bise_reg_no
        from public.enrollments e
        join public.students s on s.id = e.student_id and s.school_id = v_school
                             and s.deleted_at is null
       where e.school_id = v_school and e.session_id = v_session
         and e.class_id = p_class_id and e.status = 'active'
    ),
    -- One row per (pupil, paper they take), with the mark if there is one.
    cell as (
      select p.enrollment_id, p.student_id, p.stream, p.bise_reg_no,
             pa.subject_name, pa.sort_order, pa.max_marks, pa.pass_marks, pa.practical_max,
             me.id is not null           as marked,
             coalesce(me.is_absent, false) as is_absent,
             me.marks                    as theory,
             me.practical_marks          as practical
        from pupil p
        join paper pa on public.fn_takes_subject(pa.stream, p.stream)
        left join public.mark_entries me
          on me.exam_subject_id = pa.id and me.enrollment_id = p.enrollment_id
    ),
    -- Obtained and out-of, per cell. A cell with no mark at all contributes to
    -- NEITHER — that is what makes a provisional card honest instead of a card
    -- full of zeros.
    scored as (
      select c.*,
             case when not c.marked then null
                  when c.is_absent then 0
                  else coalesce(c.theory, 0) + coalesce(c.practical, 0) end as obtained,
             (c.max_marks + c.practical_max) as out_of
        from cell c
    ),
    agg as (
      select enrollment_id, student_id, stream, bise_reg_no,
             coalesce(sum(obtained), 0)                             as exam_marks,
             coalesce(sum(case when marked then out_of end), 0)     as exam_max,
             count(*) filter (where not marked)                     as unmarked,
             count(*) filter (where marked and obtained < pass_marks) as failed_subjects
        from scored
       group by enrollment_id, student_id, stream, bise_reg_no
    ),
    -- The assessment component. Only assessments carrying a weight count, so
    -- every assessment that exists today contributes nothing until somebody
    -- deliberately weights one.
    assess as (
      select me.enrollment_id,
             sum(a.weightage * case when me.is_absent then 0
                                    else coalesce(me.marks, 0) end / nullif(a.max_marks, 0))
               as num,
             sum(a.weightage) as den
        from public.assessments a
        join public.mark_entries me
          on me.assessment_id = a.id and me.enrollment_id in (select enrollment_id from agg)
       where a.school_id = v_school and a.session_id = v_session
         and a.class_id = p_class_id
         and coalesce(a.weightage, 0) > 0
         and coalesce(a.max_marks, 0) > 0
       group by me.enrollment_id
    ),
    pct as (
      select g.*,
             case when g.exam_max > 0 then g.exam_marks / g.exam_max * 100 end as exam_pct,
             case when coalesce(s.den, 0) > 0 then s.num / s.den * 100 end     as assess_pct
        from agg g left join assess s on s.enrollment_id = g.enrollment_id
    ),
    final as (
      select p.*,
             -- When a pupil has no weighted assessment the exam carries the
             -- whole result. NEVER a zero for a component that does not exist.
             case
               when p.exam_pct is null then null
               when v_aw > 0 and p.assess_pct is not null
                 then round(p.exam_pct * (100 - v_aw) / 100 + p.assess_pct * v_aw / 100, 2)
               else round(p.exam_pct, 2)
             end as pct,
             (v_aw > 0 and p.assess_pct is not null) as assessments_counted
        from pct p
    )
    select enrollment_id, student_id, stream, bise_reg_no,
           exam_marks, exam_max, unmarked, failed_subjects,
           exam_pct, assess_pct, pct, assessments_counted,
           -- Ranked on the FINAL percentage, and a pupil with nothing marked at
           -- all is not ranked: nulls last keeps them out of the top of the
           -- order, and the position is left null below.
           case when pct is not null and unmarked = 0
                then rank() over (order by case when unmarked = 0 then pct end desc nulls last)
           end as position
      from final
  loop
    select coalesce(max(version), 0) + 1 into v_ver from public.result_cards
      where enrollment_id = r.enrollment_id and exam_term_id = p_exam_term_id
        and school_id = v_school;

    select case when count(*) = 0 then null else
      round(100.0 * (count(*) filter (where status in ('present','late'))
                     + 0.5 * count(*) filter (where status = 'half_day')) / count(*), 1) end
      into v_att
    from public.attendance_daily
    where enrollment_id = r.enrollment_id and school_id = v_school
      and (v_from is null or attendance_date >= v_from)
      and (v_to   is null or attendance_date <= v_to);

    v_grade    := public.fn_grade_for(r.pct);
    v_bal      := public.student_balance(r.student_id);
    v_withheld := coalesce(v_withhold, false) and coalesce(v_bal, 0) > 0;

    -- The per-subject rows, over only this pupil's subjects, with theory and
    -- practical kept apart so the print can show either.
    select jsonb_build_object(
      'subjects', coalesce(jsonb_agg(jsonb_build_object(
          'subject',   x.subject_name,
          'max',       x.max_marks,
          'practical_max', x.practical_max,
          'pass',      x.pass_marks,
          'marks',     x.theory,
          'practical', x.practical,
          'obtained',  x.obtained,
          'out_of',    x.out_of,
          'is_absent', x.is_absent,
          'marked',    x.marked,
          'passed',    case when x.marked then x.obtained >= x.pass_marks end,
          'grade',     public.fn_grade_for(
                         case when x.marked and x.out_of > 0
                              then round(x.obtained / x.out_of * 100, 2) end)
        ) order by x.sort_order, x.subject_name), '[]'::jsonb),
      'total_marks', r.exam_marks, 'total_max', r.exam_max,
      'exam_percentage', case when r.exam_pct is not null then round(r.exam_pct, 2) end,
      'assessment_percentage', case when r.assess_pct is not null then round(r.assess_pct, 2) end,
      'assessment_weight_pct', case when r.assessments_counted then v_aw else 0 end,
      'percentage', r.pct, 'grade', v_grade, 'position', r.position,
      'attendance_pct', v_att,
      'stream', nullif(btrim(coalesce(r.stream, '')), ''),
      'bise_reg_no', nullif(btrim(coalesce(r.bise_reg_no, '')), ''),
      'failed_subjects', r.failed_subjects,
      -- The verdict. Both facts are recorded, not just the conclusion, so a
      -- school whose promotion rule differs has the numbers in front of them.
      'result', case
                  when r.pct is null then 'PENDING'
                  when r.failed_subjects = 0 and r.pct >= v_pass_pct then 'PASS'
                  else 'FAIL' end,
      'pass_percent', v_pass_pct,
      -- A provisional card SAYS it is provisional, and its denominator excludes
      -- what has not been marked. Both together, or it is the old defect with a
      -- label on it.
      'provisional', r.unmarked > 0,
      'unmarked_subjects', r.unmarked,
      'withheld', v_withheld, 'balance', v_bal,
      'generated_at', now(), 'version', v_ver)
      into v_frozen
    from (
      select sub.name as subject_name, sub.sort_order, es.max_marks, es.pass_marks,
             coalesce(es.practical_max, 0) as practical_max,
             me.id is not null as marked,
             coalesce(me.is_absent, false) as is_absent,
             me.marks as theory, me.practical_marks as practical,
             case when me.id is null then null
                  when coalesce(me.is_absent, false) then 0
                  else coalesce(me.marks, 0) + coalesce(me.practical_marks, 0) end as obtained,
             (es.max_marks + coalesce(es.practical_max, 0)) as out_of
        from public.exam_subjects es
        join public.subjects sub on sub.id = es.subject_id and sub.school_id = v_school
        left join public.mark_entries me
          on me.exam_subject_id = es.id and me.enrollment_id = r.enrollment_id
       where es.school_id = v_school and es.exam_term_id = p_exam_term_id
         and es.class_id = p_class_id
         and public.fn_takes_subject(sub.stream, r.stream)
    ) x;

    insert into public.result_cards(school_id, student_id, enrollment_id, exam_term_id,
      total_marks, total_max, percentage, grade, position, attendance_pct, version,
      frozen, generated_by)
    values (v_school, r.student_id, r.enrollment_id, p_exam_term_id,
      r.exam_marks, r.exam_max, r.pct, v_grade, r.position, v_att, v_ver,
      v_frozen, v_actor);
    v_count := v_count + 1;
  end loop;

  return jsonb_build_object(
    'generated', v_count,
    'provisional', v_incomplete > 0,
    'missing_marks', v_incomplete);
end;
$$;

-- ---------------------------------------------------------------------------
-- 9. Board registration numbers and streams, set from the app
--
-- Both columns have existed since the schema was written with no way to fill
-- them in, which is why the stream defect could not even be worked around by
-- hand: there was no screen that could set a pupil's stream.
-- ---------------------------------------------------------------------------
create or replace function public.fn_set_enrollment_stream(
  p_enrollment_id uuid, p_stream text, p_bise_reg_no text default null
) returns jsonb language plpgsql security definer set search_path = public as $$
declare v_school uuid := public.current_school_id(); v_name text;
begin
  if not public.has_role('owner','principal','admin_clerk') then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  perform public.assert_own('enrollments', p_enrollment_id);

  update public.enrollments
     set stream = nullif(btrim(coalesce(p_stream, '')), ''),
         bise_reg_no = nullif(btrim(coalesce(p_bise_reg_no, '')), ''),
         updated_at = now()
   where id = p_enrollment_id and school_id = v_school;

  select s.full_name into v_name
    from public.enrollments e
    join public.students s on s.id = e.student_id and s.school_id = v_school
   where e.id = p_enrollment_id and e.school_id = v_school;

  return jsonb_build_object(
    'student_name', coalesce(v_name, ''),
    'stream', nullif(btrim(coalesce(p_stream, '')), ''),
    'bise_reg_no', nullif(btrim(coalesce(p_bise_reg_no, '')), ''));
end;
$$;

-- The class list a school works down when setting streams, and the list it fills
-- board forms from. One call, because doing it pupil by pupil is why these
-- columns stayed empty.
create or replace function public.fn_class_streams(p_class_id uuid, p_session_id uuid default null)
returns table (
  enrollment_id uuid, student_id uuid, full_name text, father_name text,
  gr_no text, roll_no text, section_name text, stream text, bise_reg_no text
)
language plpgsql stable security definer set search_path = public as $$
declare v_school uuid := public.current_school_id(); v_session uuid;
begin
  if not public.has_role('owner','principal','admin_clerk','class_teacher') then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  perform public.assert_own('classes', p_class_id);

  if p_session_id is null then
    select current_session_id into v_session from public.school_settings
     where school_id = v_school;
  else
    perform public.assert_own('academic_sessions', p_session_id);
    v_session := p_session_id;
  end if;
  if v_session is null then raise exception 'No current session'; end if;

  return query
    select e.id, s.id, s.full_name, s.father_name, s.gr_no, e.roll_no, sec.name,
           e.stream, e.bise_reg_no
      from public.enrollments e
      join public.students s on s.id = e.student_id and s.school_id = v_school
                           and s.deleted_at is null
      left join public.sections sec on sec.id = e.section_id and sec.school_id = v_school
     where e.school_id = v_school and e.session_id = v_session
       and e.class_id = p_class_id and e.status = 'active'
     order by sec.sort_order nulls first,
              coalesce(nullif(regexp_replace(coalesce(e.roll_no, ''), '[^0-9]', '', 'g'), '')::int, 2147483647),
              s.full_name;
end;
$$;

-- Subjects with their stream and practical flag, so the setup screen can show
-- and set both. listSubjects previously selected neither, which is the other
-- half of why the columns stayed empty.
create or replace function public.fn_set_subject_details(
  p_subject_id uuid, p_stream text, p_is_practical boolean
) returns void language plpgsql security definer set search_path = public as $$
declare v_school uuid := public.current_school_id();
begin
  if not public.has_role('owner','principal','admin_clerk') then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  perform public.assert_own('subjects', p_subject_id);

  -- Turning the practical flag OFF while papers still carry practical marks
  -- would leave those marks unreachable and silently out of every total.
  if not coalesce(p_is_practical, false) and exists (
    select 1 from public.exam_subjects
     where school_id = v_school and subject_id = p_subject_id and coalesce(practical_max, 0) > 0
  ) then
    raise exception 'This subject has papers with practical marks. Set those to zero first.';
  end if;

  update public.subjects
     set stream = nullif(btrim(coalesce(p_stream, '')), ''),
         is_practical = coalesce(p_is_practical, false)
   where id = p_subject_id and school_id = v_school;
end;
$$;

-- ---------------------------------------------------------------------------
-- 10. Grants
-- ---------------------------------------------------------------------------
revoke all on function public.fn_takes_subject(text, text) from public;
revoke all on function public.fn_result_readiness(uuid, uuid) from public;
revoke all on function public.fn_upsert_exam_subject(uuid, uuid, uuid, numeric, numeric, numeric, date, text) from public;
revoke all on function public.fn_set_enrollment_stream(uuid, text, text) from public;
revoke all on function public.fn_class_streams(uuid, uuid) from public;
revoke all on function public.fn_set_subject_details(uuid, text, boolean) from public;
revoke all on function public.fn_generate_result_cards(uuid, uuid, boolean) from public;

grant execute on function public.fn_takes_subject(text, text) to authenticated;
grant execute on function public.fn_result_readiness(uuid, uuid) to authenticated;
grant execute on function public.fn_upsert_exam_subject(uuid, uuid, uuid, numeric, numeric, numeric, date, text) to authenticated;
grant execute on function public.fn_set_enrollment_stream(uuid, text, text) to authenticated;
grant execute on function public.fn_class_streams(uuid, uuid) to authenticated;
grant execute on function public.fn_set_subject_details(uuid, text, boolean) to authenticated;
grant execute on function public.fn_generate_result_cards(uuid, uuid, boolean) to authenticated;

-- The two-argument generator is GONE, not left as an overload. Leaving it would
-- mean the app could still call the version with no completeness check, which is
-- the entire defect this migration removes.
drop function if exists public.fn_generate_result_cards(uuid, uuid);

-- ─────────────────────────────────────────────────────────────────────────
-- 0059_readonly_boundary.sql
-- ─────────────────────────────────────────────────────────────────────────
-- =============================================================================
-- 0059 — `readonly` was incoherent in both directions at once.
--
-- Demonstrated on a real database before anything here was written. Signed in as
-- a `readonly` login, and remembering that the app puts this role in ADMIN_ROLES
-- so it is shown the WHOLE admin navigation:
--
--   students, attendance ........................ works
--   invoices, payments, expenses, till,
--   discounts, certificates, audit_log .......... ZERO ROWS — screens look empty
--   Reports -> Debit & Credit ................... 'Not permitted to read the accounts'
--   Staff ....................................... 'Not permitted'
--   Dashboard ................................... collected_month 500,
--                                                 finance_visible TRUE
--   Fee counter summary ......................... income_today 500
--
-- So the dashboard showed this role the school's takings while every screen it
-- could click through to showed nothing. Somebody sitting in that seat concludes
-- the software has lost the data.
--
-- It is also the FALLBACK role: handle_new_user gives the first account in a
-- school 'owner' and every other account 'readonly', so this was the experience
-- of any invited login whose role nobody set explicitly.
--
-- THE DECISION, with the argument against it, is in docs/READONLY-DESIGN.md:
-- `readonly` reads everything a staff member can read, INCLUDING money, and
-- writes nothing anywhere. The short version of why money is included — two of
-- the three money surfaces already showed it, so hiding it would have followed
-- the minority precedent and still left the dashboard leaking; and a role that
-- cannot see money cannot do the job schools want it for.
--
-- The dangerous half is WRITING, and that stays absolutely shut. There is a CI
-- guard (supabase/check-readonly-writes.py) so no future migration can open it
-- quietly.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. One helper carries the whole rule
--
-- Every READ gate becomes may_view(...); every WRITE gate stays has_role(...).
-- The rule is then legible at a glance — this list may act, and an observer may
-- also look — and it lives in one place instead of being restated in
-- twenty-five function bodies.
-- ---------------------------------------------------------------------------
create or replace function public.may_view(variadic p_roles public.user_role[])
returns boolean language sql stable security definer set search_path = public as $$
  select public.has_role(variadic p_roles) or public.has_role('readonly');
$$;

comment on function public.may_view(public.user_role[]) is
  'A READ gate: true for any of the given roles, and additionally for readonly. '
  'Must never appear in a write policy or a VOLATILE function — '
  'supabase/check-readonly-writes.py fails the build if it does.';

revoke all on function public.may_view(public.user_role[]) from public;
grant execute on function public.may_view(public.user_role[]) to authenticated;

-- ---------------------------------------------------------------------------
-- 2. Read gates in SECURITY DEFINER functions
--
-- Rewritten PROGRAMMATICALLY from pg_get_functiondef, not by hand. Twenty-five
-- function bodies retyped by hand is how a stack of earlier fixes gets silently
-- reverted — that has already happened once in this repo — and the end state is
-- asserted rather than the fact that a replacement matched, so re-running this
-- migration is a no-op.
--
-- THE TRAP, and why there is an exclusion list rather than a "STABLE means read"
-- assumption: two of these are STABLE and look exactly like reads, but they are
-- PERMISSION PREDICATES that gate writes somewhere else.
--
--   fn_may_manage_class      — a teacher's mark entry and attendance marking
--                              consult it. Adding readonly here would let a
--                              readonly login enter marks.
--   fn_may_write_school_file — the storage.objects INSERT/UPDATE policies
--                              consult it. Adding readonly here would let a
--                              readonly login overwrite a child's photograph.
--
-- Blanket-replacing in either would hand `readonly` the ability to write through
-- the functions that call them, which is the exact thing this migration is
-- supposed to make impossible.
-- ---------------------------------------------------------------------------
do $rewrite$
declare
  r record;
  v_def text;
  v_new text;
  v_changed integer := 0;
  -- Never rewritten. See the comment above; each is a write gate wearing a
  -- read gate's clothes.
  c_exclude text[] := array['fn_may_manage_class', 'fn_may_write_school_file'];
begin
  for r in
    select p.oid, p.proname
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and p.prosecdef
       -- STABLE or IMMUTABLE only. A VOLATILE function can write, and a read
       -- gate is not what has_role is doing inside one.
       and p.provolatile in ('s', 'i')
       and p.prosrc like '%has_role(%'
       and not (p.proname = any (c_exclude))
       -- may_view itself, obviously.
       and p.proname <> 'may_view'
     order by p.proname
  loop
    v_def := pg_get_functiondef(r.oid);
    v_new := replace(v_def, 'public.has_role(', 'public.may_view(');
    v_new := replace(v_new, ' has_role(', ' may_view(');
    if v_new <> v_def then
      -- pg_get_functiondef emits no trailing semicolon.
      execute v_new;
      v_changed := v_changed + 1;
    end if;
  end loop;
  raise notice '0059: rewrote % read gate(s) to may_view', v_changed;
end;
$rewrite$;

-- The end state, asserted. Not "a replacement matched" — that is not idempotent,
-- and an idempotent check is what lets a school re-run this file safely.
do $check$
declare v_left integer; v_bad text;
begin
  select count(*) into v_left
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.prosecdef and p.provolatile in ('s','i')
     and p.prosrc like '%has_role(%'
     and p.proname not in ('fn_may_manage_class', 'fn_may_write_school_file', 'may_view');
  if v_left > 0 then
    raise exception '0059: % read function(s) still gate on has_role', v_left;
  end if;

  -- And the thing that must never be true.
  select string_agg(p.proname, ', ') into v_bad
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.provolatile = 'v'
     and p.prosrc like '%may_view(%';
  if v_bad is not null then
    raise exception '0059: may_view reached a VOLATILE function: % — that is a write gate', v_bad;
  end if;
end;
$check$;

-- ---------------------------------------------------------------------------
-- 3. SELECT policies
--
-- Nineteen tables had a SELECT policy naming explicit roles with readonly absent,
-- which is why those screens returned zero rows.
--
-- cmd = 'r' ONLY. An ALL policy (students_write, invoices_write) covers SELECT
-- too, and rewriting one of those would open a write.
-- ---------------------------------------------------------------------------
do $policies$
declare
  r record;
  v_new text;
  v_changed integer := 0;
begin
  for r in
    select c.relname as tbl, pol.polname as pol,
           pg_get_expr(pol.polqual, pol.polrelid) as qual
      from pg_policy pol
      join pg_class c on c.oid = pol.polrelid
      join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'public'
       and pol.polcmd = 'r'                      -- SELECT and nothing else
       and pg_get_expr(pol.polqual, pol.polrelid) like '%has_role(%'
     order by c.relname, pol.polname
  loop
    v_new := replace(r.qual, 'has_role(', 'may_view(');
    execute format('alter policy %I on public.%I using (%s)', r.pol, r.tbl, v_new);
    v_changed := v_changed + 1;
  end loop;
  raise notice '0059: rewrote % SELECT policy/policies to may_view', v_changed;
end;
$policies$;

do $check$
declare v_bad text;
begin
  -- Every SELECT policy that names roles must now use may_view.
  select string_agg(c.relname || '.' || pol.polname, ', ') into v_bad
    from pg_policy pol
    join pg_class c on c.oid = pol.polrelid
    join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public' and pol.polcmd = 'r'
     and pg_get_expr(pol.polqual, pol.polrelid) like '%has_role(%';
  if v_bad is not null then
    raise exception '0059: SELECT policies still gate on has_role: %', v_bad;
  end if;

  -- And no write policy may mention it. This is the one that matters.
  select string_agg(c.relname || '.' || pol.polname, ', ') into v_bad
    from pg_policy pol
    join pg_class c on c.oid = pol.polrelid
    join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public' and pol.polcmd <> 'r'
     and (coalesce(pg_get_expr(pol.polqual, pol.polrelid), '')
       || coalesce(pg_get_expr(pol.polwithcheck, pol.polrelid), '')) like '%may_view(%';
  if v_bad is not null then
    raise exception '0059: may_view reached a WRITE policy: %', v_bad;
  end if;
end;
$check$;

-- ---------------------------------------------------------------------------
-- 4. The two money surfaces that already trusted readonly, made explicit
--
-- fn_dashboard_summary decided `finance_visible` from a has_role list that
-- happened to include readonly, which is where the incoherence started: the
-- tiles were shown and the screens behind them were empty. Now that the screens
-- work, the tile is honest — but the decision should be legible rather than
-- incidental, so it is restated here in terms of may_view.
--
-- Rewritten programmatically for the same reason as section 2: fn_dashboard_summary
-- is one of the largest functions in the schema and hand-retyping it would be
-- the third time this project nearly reverted a stack of fixes that way.
-- ---------------------------------------------------------------------------
do $finance$
declare v_def text; v_new text;
begin
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'fn_dashboard_summary';
  if v_def is null then return; end if;
  -- Section 2 has already turned its gates into may_view; this only asserts it.
  if v_def not like '%may_view(%' then
    raise exception '0059: fn_dashboard_summary was not rewritten — check section 2';
  end if;
end;
$finance$;

-- ---------------------------------------------------------------------------
-- 5. A write that changes nothing must be visible
--
-- RLS treats the three write verbs differently and it is easy to forget:
--   INSERT with no matching policy      -> RAISES
--   UPDATE / DELETE with no matching policy -> ZERO ROWS, no error
--
-- So `update students set full_name` as a readonly login returned SUCCESS. The
-- app said "Saved." and nothing changed. The web layer now checks the affected
-- rows (see mustWrite in web/src/lib/db.ts), but the same protection belongs on
-- the paths that go through the database, for anything that bypasses the app.
--
-- THE FIX LIVES IN THE APP, and only in the app, on purpose.
--
-- The first draft of this section added a `fn_assert_wrote(rows, what)` helper
-- here "so new functions have no excuse". supabase/check-reachable.sh then
-- failed the build, correctly: nothing called it. A helper granted to
-- `authenticated` that no caller uses is precisely the dead code that check
-- exists to catch, and exempting it would have been arguing with my own guard to
-- keep a line I had just written.
--
-- It is not needed either. Every write that matters already goes through a
-- SECURITY DEFINER function, and those raise their own errors — they do not
-- depend on a row count to notice a refusal, because the role check happens
-- before the UPDATE rather than being discovered by it. What was missing was
-- the check on the ELEVEN direct-table writes in web/src/lib/db.ts, and that is
-- where mustWrite() now sits.
--
-- Recorded here rather than left silent, because "why is there no database-side
-- guard for this?" is a reasonable question to ask of the next person reading
-- the migration.
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- 6. The invited login that had no profile at all
--
-- When the create-teacher Edge Function is not deployed, the app falls back to a
-- plain signUp — and that call passed no school_id, so handle_new_user returned
-- early and created NO profile row. The follow-up `update profiles set role`
-- then matched zero rows, raised nothing, and the app reported success. The
-- teacher could sign in and was told "This login is not attached to a school."
--
-- The app-side fix is to pass school_id. This is the belt: when a profile row is
-- created with no explicit role it is created INACTIVE, so an invite that lands
-- half-finished is inert rather than silently granted the fallback role. Every
-- access gate in the schema already keys on profiles.active (0053).
-- ---------------------------------------------------------------------------
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_school   uuid := nullif(new.raw_user_meta_data->>'school_id', '')::uuid;
  v_asked    text := nullif(new.raw_user_meta_data->>'role', '');
  v_is_first boolean;
  -- Whether the requested role is one we recognise. Metadata is CLIENT-SUPPLIED,
  -- so this is a whitelist and not a cast: casting 'superuser' to user_role would
  -- fail the signup itself, and honouring it is obviously worse.
  --
  -- coalesce is load-bearing. `null in (...)` is NULL, not false, so without it
  -- an invite with NO role at all made v_known NULL, `v_is_first or NULL` NULL,
  -- and the insert died on profiles.active NOT NULL — turning a half-finished
  -- invite from "inert" into "the signup fails". Found by running the suite, not
  -- by reading the line.
  v_known    boolean := coalesce(v_asked in ('principal','admin_clerk','accountant',
                                             'class_teacher','subject_teacher',
                                             'readonly','parent'), false);
begin
  -- No school in the invite metadata: create nothing rather than orphan a row.
  -- The provisioning function attaches the profile explicitly in that case.
  if v_school is null then
    return new;
  end if;

  select count(*) = 0 into v_is_first
  from public.profiles where school_id = v_school;

  insert into public.profiles (id, full_name, role, school_id, active)
  values (
    new.id,
    coalesce(nullif(new.raw_user_meta_data->>'full_name', ''), split_part(coalesce(new.email, ''), '@', 1)),
    (case when v_is_first then 'owner'
          when v_known   then v_asked
          else 'readonly' end)::public.user_role,
    v_school,
    -- Active only when we KNOW who this is: the school's first account, or an
    -- invite that named a role we recognise. Everything else lands INERT and
    -- waits for the owner to give it a role on the Users screen.
    --
    -- `v_known`, not `v_asked is not null`. The first version of this line used
    -- the latter, so an invite carrying an unrecognised role — say a typo, or a
    -- client sending 'superuser' — fell back to `readonly` and was created
    -- ACTIVE, quietly acquiring sight of the whole school. Caught by assertion
    -- 32 of supabase/tests/readonly_role.sql, which exists for exactly that.
    (v_is_first or v_known)
  )
  on conflict (id) do nothing;

  return new;
end;
$$;

-- ─────────────────────────────────────────────────────────────────────────
-- 0060_refundable_deposits.sql
-- ─────────────────────────────────────────────────────────────────────────
-- =============================================================================
-- 0060 — A security deposit was counted as profit.
--
-- Demonstrated on a real database before anything here was written. One pupil,
-- one invoice: Rs 2,000 tuition + Rs 5,000 REFUNDABLE security deposit, family
-- pays all 7,000.
--
--   fee_income ................................. 7,000   (should be 2,000)
--   profit ..................................... 7,000   (should be 2,000)
--   balance-sheet liability for the deposit .... 0       (should be 5,000)
--   ways to record a refund .................... none
--   functions reading fee_heads.is_refundable .. none
--
-- fn_finance_summary computes fee_income as the sum of every verified payment,
-- and profit = fee_income + other_income - expenses. A deposit is a payment, so
-- it went straight into profit. A school of 200 pupils on a Rs 5,000 deposit
-- shows ONE MILLION RUPEES of profit that is a liability — and a proprietor pays
-- a salary or a building instalment out of it.
--
-- fee_heads.is_refundable and the 'security_deposit' value of fee_head_type had
-- both existed since the first migration and nothing read either. The concept
-- was modelled and never wired — the same pattern as students.photo_url and
-- enrollments.stream.
--
-- The design, with the argument against each decision, is in
-- docs/DEPOSITS-DESIGN.md. The two that shape this file:
--
--  * A REFUNDABLE CHARGE GETS ITS OWN INVOICE. payment_allocations allocates to
--    an INVOICE, not a line, so on a mixed invoice a part-payment cannot be
--    split — and every splitting rule I could invent is a rule a parent can
--    argue with at the counter and the school cannot defend, because it exists
--    only inside the software. With refundable charges on their own invoice,
--    "how much deposit has this family paid" is exactly "allocations against
--    their deposit invoices", with no allocation-order rule anywhere.
--
--  * NETTING ON LEAVING IS AN ADJUSTMENT, NEVER A PAYMENT. The tempting
--    implementation of "the deposit clears the arrears" is a payments row. That
--    would be a lie in the cash reports: fn_finance_summary, the day book and
--    the till all read payments, so money nobody handed over would appear as
--    taken that day and the till would not balance.
--
-- SAFE BY DEFAULT: a school with no refundable fee head sees NO change to any
-- figure, because every sum below is zero. Nothing moves until somebody
-- deliberately marks a head refundable.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. An invoice may not mix refundable and non-refundable lines
--
-- This is the invariant the whole feature rests on. Enforced with a trigger so
-- it holds no matter which path inserts the line — the importer, the monthly
-- generator, a manual charge or a future screen.
--
-- HONEST ABOUT ITS LIMITS: the trigger reads sibling rows, so two genuinely
-- concurrent inserts of different kinds could both pass. That is a data-entry
-- invariant, not a concurrency defence — a school enters invoice lines from one
-- screen at a time — and the derived figures stay correct regardless, because a
-- mixed invoice is refused at the next line rather than silently miscounted.
-- ---------------------------------------------------------------------------
create or replace function public.fn_invoice_no_mixed_refundable()
returns trigger language plpgsql as $$
declare v_refundable int; v_ordinary int;
begin
  select count(*) filter (where h.is_refundable),
         count(*) filter (where not h.is_refundable)
    into v_refundable, v_ordinary
  from public.invoice_lines l
  join public.fee_heads h on h.id = l.fee_head_id
  where l.invoice_id = new.invoice_id;

  if v_refundable > 0 and v_ordinary > 0 then
    raise exception 'A refundable charge must be billed on its own challan, not '
                    'mixed with ordinary fees. Issue the deposit separately.'
      using errcode = '23514';
  end if;
  return null;
end;
$$;

-- IMMEDIATE, not deferrable. The first version of this was a
-- `deferrable initially deferred` constraint trigger, which fires at COMMIT —
-- so the error arrived detached from the statement that caused it, the whole
-- transaction died at the end instead of the one bad insert, and a caller could
-- not catch it at all. Caught by assertion 1 of supabase/tests/deposits.sql
-- failing: the raise never happened inside the block under test.
--
-- A plain AFTER ROW trigger fires within the statement, so the bad insert is the
-- thing that fails and the message points at it. A multi-row INSERT still works:
-- AFTER ROW triggers run for every affected row, so a statement adding both a
-- refundable and an ordinary line is refused on the second one.
drop trigger if exists trg_invoice_no_mixed_refundable on public.invoice_lines;
create trigger trg_invoice_no_mixed_refundable
  after insert or update on public.invoice_lines
  for each row execute function public.fn_invoice_no_mixed_refundable();

comment on function public.fn_invoice_no_mixed_refundable() is
  'Keeps refundable charges on their own invoice, so allocations against that '
  'invoice are unambiguously deposit money. See docs/DEPOSITS-DESIGN.md D1.';

-- ---------------------------------------------------------------------------
-- 2. The refund ledger
--
-- The ONLY new table. Everything else — what was charged, what was paid — is
-- derived from the invoice and payment machinery that already exists and is
-- already tested. A second place recording "how much has this family paid" would
-- be a second thing to disagree with the first.
-- ---------------------------------------------------------------------------
create table if not exists public.deposit_refunds (
  id            uuid primary key default gen_random_uuid(),
  school_id     uuid not null references public.schools(id) on delete cascade,
  student_id    uuid not null references public.students(id) on delete cascade,
  -- The total liability discharged. Split into the two ways it can be
  -- discharged, which must sum to `amount`.
  amount        numeric not null check (amount > 0),
  -- Applied against what the family owed. Recorded as an `adjustments` row, so
  -- no cash report gains money that never moved.
  applied_to_dues numeric not null default 0 check (applied_to_dues >= 0),
  -- Actually handed back.
  paid_out      numeric not null default 0 check (paid_out >= 0),
  method        text,
  reason        text,
  -- Whether the pupil was STILL ENROLLED when this was refunded. A deposit is
  -- normally held until leaving; an early refund is allowed (see D6) and is
  -- flagged here so the report can show those separately rather than having
  -- them look identical to ordinary leaving refunds.
  was_enrolled  boolean not null default false,
  adjustment_id uuid references public.adjustments(id),
  refunded_by   uuid,
  refunded_on   date not null default current_date,
  created_at    timestamptz not null default now(),
  constraint deposit_refunds_split_chk
    check (applied_to_dues + paid_out = amount)
);

create index if not exists ix_deposit_refunds_student
  on public.deposit_refunds(school_id, student_id);

alter table public.deposit_refunds enable row level security;

-- Append-only, like payments: a refund that can be edited is a refund that can
-- be made to disappear. A mistake is corrected by a second row, not by rewriting
-- the first.
drop policy if exists deposit_refunds_select on public.deposit_refunds;
create policy deposit_refunds_select on public.deposit_refunds
  for select using (
    school_id = public.current_school_id()
    and public.may_view('owner', 'principal', 'admin_clerk', 'accountant'));

drop policy if exists deposit_refunds_insert on public.deposit_refunds;
create policy deposit_refunds_insert on public.deposit_refunds
  for insert with check (
    school_id = public.current_school_id()
    and public.has_role('owner', 'principal'));

grant select on public.deposit_refunds to authenticated;
grant insert on public.deposit_refunds to authenticated;

-- ---------------------------------------------------------------------------
-- 3. How much refundable money is this school holding for this pupil?
--
-- Derived, never stored. Allocations against invoices whose lines are refundable,
-- minus refunds already made.
--
-- Note what is NOT here: any filter on the pupil's status. The report of what is
-- held MUST include children who have left and not been refunded, because that
-- is exactly the money the school still owes. Excluding off-roll pupils would
-- make the liability shrink the moment a child left — the same mistake
-- fn_report_balance_sheet already documents avoiding for arrears.
-- ---------------------------------------------------------------------------
create or replace function public.fn_deposit_held(p_student_id uuid)
returns numeric language sql stable security definer set search_path = public as $$
  select greatest(
    coalesce((
      -- Paid in, against deposit invoices only.
      select sum(al.amount)
        from public.payment_allocations al
        join public.payments p on p.id = al.payment_id
        join public.invoices i on i.id = al.invoice_id
       where i.school_id = public.current_school_id()
         and i.student_id = p_student_id
         and i.status <> 'void'
         and p.status = 'verified'
         and exists (
           select 1 from public.invoice_lines l
           join public.fee_heads h on h.id = l.fee_head_id
           where l.invoice_id = i.id and h.is_refundable)
    ), 0)
    - coalesce((
      select sum(r.amount) from public.deposit_refunds r
       where r.school_id = public.current_school_id()
         and r.student_id = p_student_id
    ), 0),
    0);
$$;

comment on function public.fn_deposit_held(uuid) is
  'Refundable money the school is holding for this pupil: allocations against '
  'deposit invoices, less refunds. Derived — never stored, so it cannot drift.';

-- ---------------------------------------------------------------------------
-- 4. Charging a deposit — on its own invoice, by construction
-- ---------------------------------------------------------------------------
create or replace function public.fn_charge_deposit(
  p_student_id uuid, p_fee_head_id uuid, p_amount numeric,
  p_due_date date default null, p_note text default null
) returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_school uuid := public.current_school_id();
  v_enr uuid; v_sess uuid; v_inv uuid; v_name text; v_refundable boolean;
begin
  if not public.has_role('owner', 'principal', 'admin_clerk', 'accountant') then
    raise exception 'Not permitted to charge a deposit' using errcode = '42501';
  end if;
  perform public.assert_own('students', p_student_id);
  perform public.assert_own('fee_heads', p_fee_head_id);

  if coalesce(p_amount, 0) <= 0 then
    raise exception 'A deposit must be more than zero';
  end if;

  select is_refundable, name into v_refundable, v_name
    from public.fee_heads where id = p_fee_head_id and school_id = v_school;
  if not coalesce(v_refundable, false) then
    raise exception '% is not marked refundable. Use the ordinary fee screens '
                    'for it, or mark the head refundable first.', coalesce(v_name, 'That fee head');
  end if;

  select current_session_id into v_sess from public.school_settings where school_id = v_school;
  if v_sess is null then raise exception 'No current session'; end if;

  select id into v_enr from public.enrollments
   where school_id = v_school and student_id = p_student_id
     and session_id = v_sess and status = 'active'
   order by created_at desc limit 1;
  if v_enr is null then
    raise exception 'This pupil has no active enrolment in the current session';
  end if;

  -- Its OWN invoice. period_month is null: a deposit is a once-ever charge and
  -- not part of any month's billing, so it must never be picked up by a monthly
  -- run or counted as a month a family owes.
  insert into public.invoices (school_id, student_id, enrollment_id, session_id,
                               period_month, status, due_date, notes, issued_at)
  values (v_school, p_student_id, v_enr, v_sess, null, 'issued',
          coalesce(p_due_date, current_date),
          coalesce(nullif(btrim(p_note), ''), v_name || ' (refundable)'), now())
  returning id into v_inv;

  insert into public.invoice_lines (school_id, invoice_id, fee_head_id, description, amount)
  values (v_school, v_inv, p_fee_head_id, v_name || ' (refundable)', p_amount);

  return jsonb_build_object(
    'invoice_id', v_inv, 'amount', p_amount, 'fee_head', v_name);
end;
$$;

-- ---------------------------------------------------------------------------
-- 5. Refunding it
--
-- The arrears are netted FIRST, because that is how a school does it at the
-- counter: "you owe 3,000, your deposit is 5,000, here is 2,000 back."
--
-- The netting is an ADJUSTMENT and not a payment. A payments row would put money
-- nobody handed over into fn_finance_summary, the day book and the till.
-- ---------------------------------------------------------------------------
create or replace function public.fn_refund_deposit(
  p_student_id uuid,
  p_amount numeric default null,       -- null = everything held
  p_net_against_dues boolean default true,
  p_method text default 'cash',
  p_reason text default null
) returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_school uuid := public.current_school_id();
  v_actor  uuid := auth.uid();
  v_held   numeric;
  v_amount numeric;
  v_bal    numeric;
  v_applied numeric := 0;
  v_paid   numeric;
  v_adj    uuid;
  v_name   text;
  v_enrolled boolean;
  v_id     uuid;
begin
  -- Money leaving the school is an approval, not a clerical act.
  if not public.has_role('owner', 'principal') then
    raise exception 'Only an owner or principal may refund a deposit'
      using errcode = '42501';
  end if;
  perform public.assert_own('students', p_student_id);

  select full_name into v_name from public.students
   where id = p_student_id and school_id = v_school;

  v_held := public.fn_deposit_held(p_student_id);
  if v_held <= 0 then
    raise exception 'No refundable deposit is held for %', coalesce(v_name, 'this pupil');
  end if;

  v_amount := coalesce(p_amount, v_held);
  if v_amount <= 0 then
    raise exception 'A refund must be more than zero';
  end if;
  if v_amount > v_held then
    raise exception 'Only % is held for %. A refund cannot exceed it.',
      to_char(v_held, 'FM999999999.00'), coalesce(v_name, 'this pupil');
  end if;

  -- Still on the roll? Recorded rather than refused: a school will occasionally
  -- refund early, and refusing outright pushes them into booking it as an
  -- expense, where it vanishes from the deposit ledger entirely.
  select exists (
    select 1 from public.enrollments e
     where e.school_id = v_school and e.student_id = p_student_id
       and e.status = 'active'
  ) into v_enrolled;

  if coalesce(p_net_against_dues, true) then
    v_bal := public.student_balance(p_student_id);
    -- The deposit invoice itself is part of that balance if it was never paid;
    -- but fn_deposit_held only counts ALLOCATED money, so anything held here has
    -- already been paid and is not sitting in the balance as a charge.
    if v_bal > 0 then
      v_applied := least(v_bal, v_amount);
      v_adj := public.fn_add_adjustment(
        p_student_id, -v_applied,
        coalesce(nullif(btrim(p_reason), ''), 'Security deposit applied on leaving'));
    end if;
  end if;

  v_paid := v_amount - v_applied;

  insert into public.deposit_refunds
    (school_id, student_id, amount, applied_to_dues, paid_out, method, reason,
     was_enrolled, adjustment_id, refunded_by)
  values (v_school, p_student_id, v_amount, v_applied, v_paid,
          nullif(btrim(p_method), ''), nullif(btrim(p_reason), ''),
          v_enrolled, v_adj, v_actor)
  returning id into v_id;

  return jsonb_build_object(
    'refund_id', v_id,
    'student_name', coalesce(v_name, ''),
    'amount', v_amount,
    'applied_to_dues', v_applied,
    'paid_out', v_paid,
    'still_held', public.fn_deposit_held(p_student_id),
    'was_enrolled', v_enrolled);
end;
$$;

-- ---------------------------------------------------------------------------
-- 6. The report: what is the school holding, and for whom?
--
-- Includes pupils who have LEFT and not been refunded. That is the point — it is
-- the money still owed.
-- ---------------------------------------------------------------------------
create or replace function public.fn_deposits_held()
returns table (
  student_id uuid, full_name text, gr_no text, father_name text,
  class_name text, status text, left_on date,
  collected numeric, refunded numeric, held numeric
)
language plpgsql stable security definer set search_path = public as $$
declare v_school uuid := public.current_school_id(); v_sess uuid;
begin
  if not public.may_view('owner', 'principal', 'admin_clerk', 'accountant') then
    raise exception 'Not permitted to read the accounts' using errcode = '42501';
  end if;
  select current_session_id into v_sess from public.school_settings where school_id = v_school;

  return query
  with paid as (
    select i.student_id, sum(al.amount) as amt
      from public.payment_allocations al
      join public.payments p on p.id = al.payment_id
      join public.invoices i on i.id = al.invoice_id
     where i.school_id = v_school and i.status <> 'void' and p.status = 'verified'
       and exists (
         select 1 from public.invoice_lines l
         join public.fee_heads h on h.id = l.fee_head_id
         where l.invoice_id = i.id and h.is_refundable)
     group by i.student_id
  ),
  back as (
    select r.student_id, sum(r.amount) as amt
      from public.deposit_refunds r
     where r.school_id = v_school
     group by r.student_id
  )
  select s.id, s.full_name, s.gr_no, s.father_name,
         c.name, s.status::text, s.left_on,
         coalesce(pd.amt, 0), coalesce(b.amt, 0),
         coalesce(pd.amt, 0) - coalesce(b.amt, 0)
    from paid pd
    join public.students s on s.id = pd.student_id and s.school_id = v_school
    left join back b on b.student_id = s.id
    left join public.enrollments e
      on e.school_id = v_school and e.student_id = s.id and e.session_id = v_sess
    left join public.classes c on c.id = e.class_id and c.school_id = v_school
   where coalesce(pd.amt, 0) - coalesce(b.amt, 0) > 0
   order by s.full_name;
end;
$$;

-- ---------------------------------------------------------------------------
-- 7. Take deposits out of income, and put them on the liability side
--
-- Rewritten programmatically? No — these two functions are small enough to
-- restate, and the change is not a mechanical substitution. But BOTH are
-- rewritten in full here rather than patched by string replacement, because a
-- partial edit of a money function is how a report starts disagreeing with
-- itself.
-- ---------------------------------------------------------------------------
create or replace function public.fn_finance_summary(p_from date, p_to date)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_fee     numeric;
  v_dep     numeric;
  v_other   numeric;
  v_exp     numeric;
  v_by_cat  jsonb;
  v_school  uuid := public.current_school_id();
begin
  if not public.may_view('owner', 'principal', 'accountant') then
    raise exception 'Not permitted to view finances';
  end if;

  -- Gross receipts: verified payments in the window. Reversals carry a negative
  -- amount, so a reversed payment removes itself automatically.
  select coalesce(sum(p.amount), 0) into v_fee
  from public.payments p
  where p.school_id = v_school and p.status = 'verified'
    and p.created_at::date between p_from and p_to;

  -- Of which REFUNDABLE — money the school holds and must give back. Counting
  -- it as income is what made a Rs 5,000 deposit into Rs 5,000 of profit; at
  -- 200 pupils that is a million rupees a proprietor would take decisions on.
  --
  -- Matched by ALLOCATION against a deposit invoice, not by payment: a payment
  -- is not intrinsically a deposit, the invoice it settles is.
  select coalesce(sum(al.amount), 0) into v_dep
  from public.payment_allocations al
  join public.payments p on p.id = al.payment_id
  join public.invoices i on i.id = al.invoice_id
  where p.school_id = v_school and p.status = 'verified'
    and p.created_at::date between p_from and p_to
    and i.school_id = v_school and i.status <> 'void'
    and exists (
      select 1 from public.invoice_lines l
      join public.fee_heads h on h.id = l.fee_head_id
      where l.invoice_id = i.id and h.is_refundable);

  select coalesce(sum(o.amount), 0) into v_other
  from public.other_income o
  where o.school_id = v_school and o.received_on between p_from and p_to;

  select coalesce(sum(e.amount), 0) into v_exp
  from public.expenses e
  where e.school_id = v_school and e.spent_on between p_from and p_to;

  select coalesce(jsonb_agg(x order by x.total desc), '[]'::jsonb) into v_by_cat
  from (
    select coalesce(c.name, 'Uncategorised') as category,
           sum(e.amount) as total
    from public.expenses e
    left join public.expense_categories c on c.id = e.category_id
    where e.school_id = v_school and e.spent_on between p_from and p_to
    group by 1
    having sum(e.amount) <> 0
  ) x;

  return jsonb_build_object(
    'from', p_from, 'to', p_to,
    -- NET of deposits. A school with no refundable head sees exactly the old
    -- number, because v_dep is zero.
    'fee_income', v_fee - v_dep,
    -- Both halves are reported too, so a clerk reconciling against the till sees
    -- the CASH they counted as well as the INCOME that excludes the deposit.
    -- Replacing one number with another and saying nothing is how a school
    -- stops trusting a report.
    'fee_receipts_gross', v_fee,
    'deposits_collected', v_dep,
    'other_income', v_other,
    'total_income', v_fee - v_dep + v_other,
    'expenses', v_exp,
    'profit', v_fee - v_dep + v_other - v_exp,
    'expenses_by_category', v_by_cat);
end;
$$;

-- The balance sheet gains the liability. Patched by replacement rather than
-- retyped: it is one of the largest functions in the schema and hand-retyping it
-- would be the fourth time this project nearly reverted a stack of fixes that
-- way.
do $bs$
declare v_def text; v_new text;
begin
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'fn_report_balance_sheet';
  if v_def is null then
    raise exception '0060: fn_report_balance_sheet not found';
  end if;

  -- ALREADY PATCHED: nothing to do. This guard is load-bearing, not tidiness.
  -- Without it, re-running this migration inserts `v_deposits numeric;` a second
  -- time and the whole file dies with `duplicate declaration at or near
  -- "v_deposits"`. Found by re-running it, which is exactly what a school does
  -- when a bundle is pasted twice.
  --
  -- Keyed on the OUTPUT it produces, not on a flag: if a bundle ever restores
  -- the pre-0060 definition, deposits_held disappears and the patch correctly
  -- runs again.
  if v_def like '%deposits_held%' then
    return;
  end if;

  -- Declare the new variable.
  v_new := replace(v_def,
    '  v_students   int;',
    '  v_students   int;' || E'\n' || '  v_deposits   numeric;');

  -- Compute it, right after the expenses figure.
  v_new := replace(v_new,
    '  -- ---- money held that is not against a charge yet ----',
    '  -- ---- refundable money held, which is a LIABILITY and not income ----'
    || E'\n' ||
    '  -- Every deposit ever collected and not yet refunded, as at the date.' || E'\n' ||
    '  -- Not restricted to pupils on the roll: a child who has left and not been' || E'\n' ||
    '  -- refunded is exactly the money the school still owes.' || E'\n' ||
    '  select coalesce(sum(al.amount), 0) - coalesce((' || E'\n' ||
    '           select sum(r.amount) from public.deposit_refunds r' || E'\n' ||
    '            where r.school_id = v_school and r.refunded_on <= v_as_at), 0)' || E'\n' ||
    '    into v_deposits' || E'\n' ||
    '  from public.payment_allocations al' || E'\n' ||
    '  join public.payments p on p.id = al.payment_id' || E'\n' ||
    '  join public.invoices i on i.id = al.invoice_id' || E'\n' ||
    '  where p.school_id = v_school and p.status = ''verified''' || E'\n' ||
    '    and p.created_at::date <= v_as_at' || E'\n' ||
    '    and i.school_id = v_school and i.status <> ''void''' || E'\n' ||
    '    and exists (select 1 from public.invoice_lines l' || E'\n' ||
    '                join public.fee_heads h on h.id = l.fee_head_id' || E'\n' ||
    '                where l.invoice_id = i.id and h.is_refundable);' || E'\n' ||
    '  if v_deposits < 0 then v_deposits := 0; end if;' || E'\n\n' ||
    '  -- ---- money held that is not against a charge yet ----');

  -- Report it on the liability side, and take it out of what the school kept.
  v_new := replace(v_new,
    '    ''advance_held'',       v_advance,',
    '    ''advance_held'',       v_advance,' || E'\n' ||
    '    -- A refundable deposit is the one kind of money here that is NOT the' || E'\n' ||
    '    -- school''''s. Shown on the liability side, and removed from the' || E'\n' ||
    '    -- retained figure below.' || E'\n' ||
    '    ''deposits_held'',      v_deposits,' || E'\n' ||
    '    ''retained'',           v_receipts + v_other_in - v_expenses - v_deposits,');

  if v_new = v_def then
    raise exception '0060: no replacement matched in fn_report_balance_sheet — '
                    'the function has changed shape; re-check this block';
  end if;
  execute v_new;
end;
$bs$;

-- The end state, asserted.
do $check$
begin
  if not exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = 'fn_report_balance_sheet'
       and p.prosrc like '%deposits_held%'
  ) then
    raise exception '0060: fn_report_balance_sheet does not report deposits_held';
  end if;
  if not exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = 'fn_finance_summary'
       and p.prosrc like '%deposits_collected%'
  ) then
    raise exception '0060: fn_finance_summary does not report deposits_collected';
  end if;
end;
$check$;

-- ---------------------------------------------------------------------------
-- 8. A gap in 0059, found by wiring this feature
--
-- fn_profit_snapshot is the Accounts overview. It calls fn_finance_summary three
-- times and builds a jsonb; it writes nothing. But it is declared VOLATILE, and
-- 0059 rewrote read gates only in STABLE functions — on the reasoning that a
-- VOLATILE function can write and has_role inside one is not a read gate.
--
-- So it kept its has_role gate and refuses `readonly`, while 0059's companion
-- change put Accounts into the observer's navigation. An observer opening
-- Accounts got 'Not permitted to view finances' on the one screen the module
-- exists for.
--
-- check-readonly-writes.py could not see it either: it looks for STABLE
-- SECURITY DEFINER functions left on has_role, and this is VOLATILE. A blind
-- spot in the guard AND in the migration, in the same place.
--
-- Fixed both ways round: the gate becomes may_view, and the function is declared
-- STABLE — which it truthfully is — so it falls inside the guard's view from now
-- on rather than needing a special case. supabase/tests/readonly_role.sql also
-- gains a positive assertion that walks the observer's navigation and requires
-- every screen behind it to ANSWER, because a nav entry whose screen errors is
-- exactly this defect and only walking it catches the next one.
-- ---------------------------------------------------------------------------
do $snapshot$
declare v_def text; v_new text;
begin
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'fn_profit_snapshot';
  if v_def is null then return; end if;

  v_new := replace(v_def, 'public.has_role(', 'public.may_view(');
  v_new := replace(v_new, ' has_role(', ' may_view(');
  -- Declared VOLATILE by omission, so pg_get_functiondef prints no volatility
  -- keyword at all — there is nothing to replace, only somewhere to insert.
  -- The header it emits is:
  --     LANGUAGE plpgsql
  --      SECURITY DEFINER
  -- with a leading space on the second line.
  --
  -- Matched with `\s+` rather than chr(10) and a counted space. This header is
  -- generated by Postgres itself rather than copied out of prosrc, so its line
  -- ending really is always a line feed -- but the exact spacing has changed
  -- between server versions before, and a pattern that is right for one reason
  -- and wrong for another is not worth keeping when `\s+` is right for both.
  -- supabase/check-patch-anchors.py fails the build on the old form.
  if v_new not like '%STABLE%' then
    v_new := regexp_replace(v_new, 'LANGUAGE plpgsql\s+SECURITY DEFINER',
                            'LANGUAGE plpgsql' || chr(10) || ' STABLE SECURITY DEFINER');
  end if;
  execute v_new;
end;
$snapshot$;

do $check$
begin
  if not exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = 'fn_profit_snapshot'
       and p.prosrc like '%may_view(%'
  ) then
    raise exception '0060: fn_profit_snapshot still refuses an observer';
  end if;
  if not exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = 'fn_profit_snapshot'
       and p.provolatile in ('s','i')
  ) then
    raise exception '0060: fn_profit_snapshot is still VOLATILE, so '
                    'check-readonly-writes.py cannot see it';
  end if;
end;
$check$;

-- ---------------------------------------------------------------------------
-- 9. Grants
-- ---------------------------------------------------------------------------
revoke all on function public.fn_deposit_held(uuid) from public;
revoke all on function public.fn_charge_deposit(uuid, uuid, numeric, date, text) from public;
revoke all on function public.fn_refund_deposit(uuid, numeric, boolean, text, text) from public;
revoke all on function public.fn_deposits_held() from public;

grant execute on function public.fn_deposit_held(uuid) to authenticated;
grant execute on function public.fn_charge_deposit(uuid, uuid, numeric, date, text) to authenticated;
grant execute on function public.fn_refund_deposit(uuid, numeric, boolean, text, text) to authenticated;
grant execute on function public.fn_deposits_held() to authenticated;

-- ─────────────────────────────────────────────────────────────────────────
-- 0061_certificates.sql
-- ─────────────────────────────────────────────────────────────────────────
-- =============================================================================
-- 0061 — A leaving certificate was issued to a pupil who owed Rs 4,000, and
--        issuing it did not record that they had left.
--
-- Demonstrated on a real database before anything here was written. One pupil,
-- STILL ENROLLED, owing Rs 4,000. A leaving certificate was requested:
--
--   issued .................................... yes, serial 1
--   students.status afterwards ................ 'active'
--   students.left_on afterwards ............... null
--   enrolment status afterwards ............... 'active'
--   snapshot contents ......................... name, father, class, roll. Nothing else.
--   issued a second time ...................... yes, serial 2, also looking original
--   ways to cancel one issued in error ........ none
--
-- A School Leaving Certificate is the document a Pakistani family cannot enrol a
-- child anywhere else without. It is also the school's main lever for unpaid
-- fees. Both were broken:
--
--  * NO DUES CHECK. The one thing a school withholds until fees are paid, handed
--    over freely.
--
--  * ISSUING IT DID NOT RECORD THE LEAVING. The child stays on the attendance
--    sheet, in the class strength and IN NEXT MONTH'S BILLING, while holding a
--    certificate that says they have left. students.left_on and
--    fn_set_student_status have existed since 0054; this path never touched them.
--
--  * THE SNAPSHOT WAS MISSING WHAT AN SLC MUST STATE. An SLC says "was a bona
--    fide student from ___ to ___, last studying in class ___, conduct ___".
--    admission_date was on the pupil's record and was never copied. So the
--    wording was assembled from whatever a clerk typed into a free-form field,
--    and two clerks produced two different documents.
--
--  * TWO ORIGINALS. Serials 1 and 2, indistinguishable. The school cannot say
--    which is real, and a family holding both can present one at each of two
--    schools.
--
-- What already existed and is KEPT unchanged: the gapless per-type serial, the
-- frozen snapshot so a reprint never drifts, and the append-only insert policy.
--
-- The design, with the argument against each decision — including the serious
-- objection to D2, that printing a document should not quietly change a pupil's
-- status — is in docs/CERTIFICATES-DESIGN.md.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. Cancelling one issued in error
--
-- A SEPARATE TABLE, not columns on `certificates` and not an UPDATE path.
-- `certificates` stays strictly append-only: an UPDATE path would mean a
-- certificate could be edited into something it never was, and RLS cannot
-- restrict WHICH columns an update touches — only whether it may happen at all.
-- ---------------------------------------------------------------------------
create table if not exists public.certificate_cancellations (
  id             uuid primary key default gen_random_uuid(),
  school_id      uuid not null references public.schools(id) on delete cascade,
  certificate_id uuid not null references public.certificates(id) on delete cascade,
  reason         text not null,
  cancelled_by   uuid references public.profiles(id),
  cancelled_at   timestamptz not null default now(),
  -- One cancellation per certificate. Cancelling twice is not a thing, and
  -- without this a register could show two conflicting reasons.
  constraint certificate_cancellations_once unique (certificate_id)
);

create index if not exists ix_cert_cancel_school
  on public.certificate_cancellations(school_id);

alter table public.certificate_cancellations enable row level security;

drop policy if exists cert_cancel_select on public.certificate_cancellations;
create policy cert_cancel_select on public.certificate_cancellations
  for select using (
    school_id = public.current_school_id()
    and public.may_view('owner', 'principal', 'admin_clerk'));

drop policy if exists cert_cancel_insert on public.certificate_cancellations;
create policy cert_cancel_insert on public.certificate_cancellations
  for insert with check (
    school_id = public.current_school_id()
    and public.has_role('owner', 'principal'));

grant select, insert on public.certificate_cancellations to authenticated;

create or replace function public.fn_cancel_certificate(
  p_certificate_id uuid, p_reason text
) returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_school uuid := public.current_school_id();
  v_actor  uuid := auth.uid();
  v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
  v_type   text; v_serial bigint; v_name text; v_id uuid;
begin
  -- Cancelling a document a family may already be holding is not clerical.
  if not public.has_role('owner', 'principal') then
    raise exception 'Only an owner or principal may cancel a certificate'
      using errcode = '42501';
  end if;
  perform public.assert_own('certificates', p_certificate_id);

  if v_reason is null then
    raise exception 'A cancellation needs a reason — it stays on the register permanently';
  end if;

  select c.cert_type::text, c.serial_no, s.full_name
    into v_type, v_serial, v_name
  from public.certificates c
  join public.students s on s.id = c.student_id and s.school_id = v_school
  where c.id = p_certificate_id and c.school_id = v_school;

  insert into public.certificate_cancellations
    (school_id, certificate_id, reason, cancelled_by)
  values (v_school, p_certificate_id, v_reason, v_actor)
  returning id into v_id;

  return jsonb_build_object(
    'cancellation_id', v_id, 'cert_type', v_type,
    'serial_no', v_serial, 'student_name', coalesce(v_name, ''));
exception when unique_violation then
  raise exception 'That certificate has already been cancelled';
end;
$$;

-- ---------------------------------------------------------------------------
-- 2. Is this pupil clear to be given a certificate?
--
-- Read separately so a screen can show the position BEFORE the button is
-- pressed, and consulted again inside the issuer so the rule cannot be
-- bypassed by calling it directly.
-- ---------------------------------------------------------------------------
create or replace function public.fn_certificate_readiness(
  p_student_id uuid, p_cert_type public.certificate_type
) returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_school uuid := public.current_school_id();
  v_bal numeric; v_name text; v_status text; v_left date;
  v_prior bigint;
begin
  if not public.may_view('owner', 'principal', 'admin_clerk') then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  perform public.assert_own('students', p_student_id);

  select full_name, status::text, left_on into v_name, v_status, v_left
    from public.students where id = p_student_id and school_id = v_school;

  v_bal := public.student_balance(p_student_id);

  -- The highest serial already issued of this type, if any. Its presence is what
  -- makes the next one a duplicate.
  select max(serial_no) into v_prior
    from public.certificates
   where school_id = v_school and student_id = p_student_id
     and cert_type = p_cert_type
     and not exists (select 1 from public.certificate_cancellations x
                      where x.certificate_id = certificates.id);

  return jsonb_build_object(
    'student_name', coalesce(v_name, ''),
    'balance', coalesce(v_bal, 0),
    'status', v_status,
    'left_on', v_left,
    -- Only the leaving certificate is gated on dues. A bonafide is proof of
    -- enrolment — a family needs it for a bank account, a passport, a
    -- scholarship form — and a character certificate is a statement about
    -- conduct. Withholding either over fees is punitive and is not what schools
    -- do. See docs/CERTIFICATES-DESIGN.md D1.
    'dues_gate', (p_cert_type = 'leaving'),
    'blocked_by_dues', (p_cert_type = 'leaving' and coalesce(v_bal, 0) > 0),
    'would_be_duplicate', (v_prior is not null),
    'original_serial_no', v_prior);
end;
$$;

-- ---------------------------------------------------------------------------
-- 3. The issuer, rewritten
--
-- Every change is a defect from the header. What has NOT changed: the gapless
-- per-type serial, the frozen snapshot, and the append-only insert.
--
-- The two-argument form is DROPPED rather than left as an overload, because
-- leaving it would mean the app could still call the version with no dues gate
-- and no leaving record — which is the whole defect.
-- ---------------------------------------------------------------------------
create or replace function public.fn_issue_certificate(
  p_cert_type public.certificate_type,
  p_student_id uuid,
  p_data jsonb default '{}'::jsonb,
  -- Required for a leaving certificate, ignored otherwise. NOT optional
  -- extras: making them arguments is what stops anybody issuing an SLC by
  -- accident to see the wording, which is the answer to the objection that
  -- printing a document should not change a pupil's status.
  p_leaving_on date default null,
  p_leaving_reason text default null,
  p_leaving_status public.student_status default 'withdrawn',
  -- Releasing an SLC while fees are outstanding. Owner or principal only, and
  -- the amount and the authoriser go into the frozen snapshot, so the document
  -- itself carries the fact.
  p_override_dues boolean default false,
  p_override_reason text default null
) returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_school uuid := public.current_school_id();
  v_actor  uuid := auth.uid();
  v_serial bigint;
  v_id     uuid;
  v_snap   jsonb;
  v_ready  jsonb;
  v_bal    numeric;
  v_prior  bigint;
  v_left   date;
  v_status text;
  v_actor_name text;
  v_extra  jsonb;
  -- Keys the SNAPSHOT owns. `p_data` is a free-form field a clerk types into
  -- (conduct, purpose, remarks) and it used to be merged OVER the snapshot, so
  -- every one of these was whatever the caller said it was. Proven, not
  -- suspected: a clerk issued a second bonafide with
  -- {"is_duplicate": false, "dues_cleared": true, "balance_at_issue": 0,
  --  "student_name": "Somebody Else", "gr_no": "GR-9999"} and got serial 2
  -- printing a different child's name, with no DUPLICATE stamp, showing the
  -- fees as cleared while Rs 4,000 was outstanding.
  --
  -- Deleting the keys is deliberate rather than merging the other way round:
  -- jsonb_strip_nulls removes a snapshot key that came out null, so
  -- `p_data || v_snap` would still let `original_serial_no` through on a
  -- certificate that is not a duplicate. This list is the whole answer to
  -- "what can the caller not assert?", in one place.
  v_reserved text[] := array[
    'student_name','father_name','mother_name','gr_no','admission_no','dob',
    'gender','b_form','address','admission_date','attended_from','attended_to',
    'date_of_leaving','leaving_reason','class_name','section_name','roll_no',
    'stream','bise_reg_no','is_duplicate','original_serial_no',
    'balance_at_issue','dues_cleared','dues_override_reason','dues_override_by'];
begin
  if not public.has_role('owner','principal','admin_clerk') then
    raise exception 'Not permitted to issue certificates' using errcode = '42501';
  end if;
  perform public.assert_own('students', p_student_id);

  v_ready := public.fn_certificate_readiness(p_student_id, p_cert_type);
  v_bal   := (v_ready->>'balance')::numeric;
  v_prior := nullif(v_ready->>'original_serial_no', '')::bigint;

  -- ---- the dues gate -----------------------------------------------------
  if (v_ready->>'blocked_by_dues')::boolean then
    if not coalesce(p_override_dues, false) then
      raise exception
        '% owes %. A leaving certificate cannot be issued until that is cleared, '
        'or an owner or principal releases it on purpose.',
        v_ready->>'student_name', to_char(v_bal, 'FM999999999.00');
    end if;
    if not public.has_role('owner', 'principal') then
      raise exception 'Only an owner or principal may release a leaving '
                      'certificate while % is outstanding',
        to_char(v_bal, 'FM999999999.00') using errcode = '42501';
    end if;
    if nullif(btrim(coalesce(p_override_reason, '')), '') is null then
      raise exception 'Releasing a leaving certificate over unpaid fees needs a '
                      'reason — it is recorded on the certificate itself';
    end if;
  end if;

  -- ---- the leaving, recorded in the SAME transaction ---------------------
  if p_cert_type = 'leaving' then
    select status::text, left_on into v_status, v_left
      from public.students where id = p_student_id and school_id = v_school;

    if v_status = 'active' then
      if p_leaving_on is null then
        raise exception 'A leaving certificate needs the date the pupil left. '
                        'Issuing one records the leaving, so the register cannot '
                        'say they are still here.';
      end if;
      -- fn_set_student_status rather than writing the columns directly: 0054
      -- holds the rules and the audit trail, and duplicating them here is how
      -- the two drift apart.
      perform public.fn_set_student_status(
        p_student_id, coalesce(p_leaving_status, 'withdrawn'),
        coalesce(nullif(btrim(p_leaving_reason), ''), 'Left the school'),
        p_leaving_on);
      v_left := p_leaving_on;
    end if;
    -- Already recorded as left: use the recorded date and change nothing.
    v_left := coalesce(v_left, p_leaving_on, current_date);
  end if;

  -- one gapless serial sequence PER certificate type
  v_serial := public.next_counter('certificate_' || p_cert_type::text);

  select full_name into v_actor_name from public.profiles
   where id = v_actor and school_id = v_school;

  -- ---- the snapshot: everything the document must state -------------------
  -- Frozen, not looked up at print time, so a reprint five years later produces
  -- the same document. The photograph is the one deliberate exception and is
  -- read live: a card exists so somebody can recognise the child holding it.
  select jsonb_strip_nulls(jsonb_build_object(
      'student_name',  s.full_name,
      'father_name',   s.father_name,
      'mother_name',   s.mother_name,
      'gr_no',         s.gr_no,
      'admission_no',  s.admission_no,
      'dob',           s.dob,
      'gender',        s.gender,
      'b_form',        s.b_form,
      'address',       s.address,
      -- The dates an SLC has to state: "a bona fide student from ___ to ___".
      -- admission_date was on the record all along and was never copied.
      'admission_date',  s.admission_date,
      'attended_from',   s.admission_date,
      'attended_to',     case when p_cert_type = 'leaving' then v_left
                              else current_date end,
      'date_of_leaving', case when p_cert_type = 'leaving' then v_left end,
      'leaving_reason',  case when p_cert_type = 'leaving'
                              then nullif(btrim(coalesce(p_leaving_reason, '')), '') end,
      'class_name',    c.name,
      'section_name',  sec.name,
      'roll_no',       e.roll_no,
      'stream',        e.stream,
      'bise_reg_no',   e.bise_reg_no,
      -- A duplicate says so on its face. Originals get lost; a school that
      -- cannot issue a replacement writes one by hand and there is no record.
      'is_duplicate',       (v_prior is not null),
      'original_serial_no', v_prior,
      -- The dues position at the moment of issue, on the document.
      'balance_at_issue',   coalesce(v_bal, 0),
      'dues_cleared',       (coalesce(v_bal, 0) <= 0),
      'dues_override_reason',
        case when (v_ready->>'blocked_by_dues')::boolean
             then nullif(btrim(coalesce(p_override_reason, '')), '') end,
      'dues_override_by',
        case when (v_ready->>'blocked_by_dues')::boolean then v_actor_name end
    ))
    into v_snap
  from public.students s
  left join public.enrollments e
    on e.student_id = s.id and e.school_id = v_school
   and e.session_id = (select current_session_id from public.school_settings
                        where school_id = v_school)
  left join public.classes c on c.id = e.class_id and c.school_id = v_school
  left join public.sections sec on sec.id = e.section_id and sec.school_id = v_school
  where s.id = p_student_id and s.school_id = v_school;

  -- The clerk's free-form additions, with everything the snapshot owns removed.
  v_extra := coalesce(p_data, '{}'::jsonb) - v_reserved;

  insert into public.certificates(school_id, cert_type, student_id, serial_no, issued_by, data)
  values (v_school, p_cert_type, p_student_id, v_serial, v_actor,
          coalesce(v_snap, '{}'::jsonb) || v_extra)
  returning id into v_id;

  return jsonb_build_object(
    'id', v_id, 'serial_no', v_serial, 'cert_type', p_cert_type,
    'issued_on', current_date,
    'is_duplicate', (v_prior is not null),
    'dues_overridden', (v_ready->>'blocked_by_dues')::boolean,
    'left_on', case when p_cert_type = 'leaving' then v_left end);
end;
$$;

-- ---------------------------------------------------------------------------
-- 4. The register, with cancelled and duplicate state visible
--
-- Cancelled certificates are SHOWN, struck through, not hidden: a cancelled
-- serial is a fact somebody may have to explain, and a gap in the numbering with
-- no explanation is worse than a cancelled row.
-- ---------------------------------------------------------------------------
create or replace function public.fn_certificate_register(p_limit integer default 100)
returns table (
  id uuid, cert_type text, serial_no bigint, issued_on date,
  student_id uuid, student_name text, gr_no text, photo_path text,
  is_duplicate boolean, original_serial_no bigint,
  dues_cleared boolean, balance_at_issue numeric,
  cancelled_at timestamptz, cancel_reason text,
  issued_by_name text, data jsonb
)
language plpgsql stable security definer set search_path = public as $$
declare v_school uuid := public.current_school_id();
begin
  if not public.may_view('owner', 'principal', 'admin_clerk') then
    raise exception 'Not permitted' using errcode = '42501';
  end if;

  return query
  select c.id, c.cert_type::text, c.serial_no, c.issued_on,
         s.id, s.full_name, s.gr_no, s.photo_path,
         coalesce((c.data->>'is_duplicate')::boolean, false),
         nullif(c.data->>'original_serial_no', '')::bigint,
         coalesce((c.data->>'dues_cleared')::boolean, true),
         coalesce((c.data->>'balance_at_issue')::numeric, 0),
         x.cancelled_at, x.reason,
         p.full_name, c.data
    from public.certificates c
    join public.students s on s.id = c.student_id and s.school_id = v_school
    left join public.certificate_cancellations x
      on x.certificate_id = c.id and x.school_id = v_school
    left join public.profiles p on p.id = c.issued_by and p.school_id = v_school
   where c.school_id = v_school
   order by c.created_at desc
   limit greatest(1, least(coalesce(p_limit, 100), 500));
end;
$$;

-- ---------------------------------------------------------------------------
-- 5. Grants, and the old signature removed
-- ---------------------------------------------------------------------------
revoke all on function public.fn_cancel_certificate(uuid, text) from public;
revoke all on function public.fn_certificate_readiness(uuid, public.certificate_type) from public;
revoke all on function public.fn_certificate_register(integer) from public;
revoke all on function public.fn_issue_certificate(
  public.certificate_type, uuid, jsonb, date, text, public.student_status, boolean, text) from public;

grant execute on function public.fn_cancel_certificate(uuid, text) to authenticated;
grant execute on function public.fn_certificate_readiness(uuid, public.certificate_type) to authenticated;
grant execute on function public.fn_certificate_register(integer) to authenticated;
grant execute on function public.fn_issue_certificate(
  public.certificate_type, uuid, jsonb, date, text, public.student_status, boolean, text) to authenticated;

-- The three-argument form is GONE. Leaving it would mean the app could still
-- call the version with no dues gate and no leaving record, which is the entire
-- defect this migration removes.
drop function if exists public.fn_issue_certificate(public.certificate_type, uuid, jsonb);

-- ─────────────────────────────────────────────────────────────────────────
-- 0062_staff_checkin.sql
-- ─────────────────────────────────────────────────────────────────────────
-- =============================================================================
-- 0062 — Staff QR check-in that is not decorative
--
-- Probed on a real database before a line of this was written. One teacher,
-- login linked to her staff record, sitting at home:
--
--   she inserted her own attendance row .......... yes. No QR code involved.
--   with source = 'qr' and code_id null ......... nothing anywhere read code_id
--   she back-dated seven days she never worked .. yes
--   the code itself ............................. 32 static hex chars, no expiry
--   check-out, lateness, school day ............. none of the three existed
--
-- `staff_att_insert` allowed `staff_id = my_staff_id()`, which meant the whole
-- QR mechanism was a suggestion. fn_staff_check_in has always been SECURITY
-- DEFINER, so that policy branch was never needed for the feature to work.
--
-- The design and the argument against each decision are in
-- docs/STAFF-CHECKIN-DESIGN.md. No biometric — that was the instruction, and it
-- is also why this file is careful about the difference between "a body was at
-- the gate" and "a valid currently-displayed code was presented by a signed-in
-- account". It closes every gap between those two that can be closed and makes
-- the remaining one visible instead of silent.
--
-- Re-runnable.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. A teacher can never write her own attendance row
--
-- THE ONE THAT MATTERS. Everything else in this file is a lock on a door; this
-- is the wall next to it.
-- ---------------------------------------------------------------------------
drop policy if exists staff_att_insert on public.staff_attendance;
create policy staff_att_insert on public.staff_attendance
  for insert to authenticated
  with check (
    school_id = public.current_school_id()
    and public.has_role('owner', 'principal', 'admin_clerk')
  );

-- Attendance for a day that has not happened yet. A CHECK rather than a trigger:
-- declarative, applies to every path including ones nobody has written yet, and
-- cannot be forgotten. Past dates stay valid for ever so a dump/restore is safe.
do $$
begin
  if not exists (select 1 from pg_constraint
                  where conname = 'staff_attendance_not_future'
                    and conrelid = 'public.staff_attendance'::regclass) then
    -- Any future-dated rows already present would block the constraint. There
    -- should be none; if a database has them they were forged, and naming them
    -- is better than silently dropping the check.
    if exists (select 1 from public.staff_attendance where attendance_date > current_date) then
      raise exception 'staff_attendance already holds % future-dated row(s) — review them before applying 0062',
        (select count(*) from public.staff_attendance where attendance_date > current_date);
    end if;
    alter table public.staff_attendance
      add constraint staff_attendance_not_future check (attendance_date <= current_date);
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 2. The school day, so that "late" can mean something
--
-- attendance_status has had a 'late' value since the first migration and nothing
-- could ever produce it, because there was no start time to be late against.
-- ---------------------------------------------------------------------------
alter table public.school_settings
  add column if not exists day_starts_at time,
  add column if not exists day_ends_at time,
  add column if not exists late_grace_minutes integer not null default 10;

do $$
begin
  if not exists (select 1 from pg_constraint
                  where conname = 'school_settings_grace_chk'
                    and conrelid = 'public.school_settings'::regclass) then
    alter table public.school_settings
      add constraint school_settings_grace_chk
      check (late_grace_minutes between 0 and 240);
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 3. Rotating codes, check-out, and the columns that make a register auditable
-- ---------------------------------------------------------------------------
alter table public.staff_checkin_codes
  -- A rotating code is displayed on a screen and changes every 30 seconds. A
  -- static one is printed on a poster and a photograph of it works for ever;
  -- both are offered, and the Settings copy says which is which.
  add column if not exists rotating boolean not null default false,
  -- Never leaves the database. The display calls fn_checkin_display() and
  -- renders what comes back; a rotating code whose seed is in a browser is not
  -- a rotating code.
  add column if not exists secret text;

alter table public.staff_attendance
  add column if not exists checked_out_at timestamptz,
  add column if not exists late_minutes integer,
  add column if not exists worked_minutes integer,
  -- The token window the scan presented. Two check-ins seconds apart on the
  -- same window from two different devices is the shape of a relayed
  -- photograph, and a principal can only ask about it if it is recorded.
  add column if not exists code_window bigint;

do $$
begin
  if not exists (select 1 from pg_constraint
                  where conname = 'staff_attendance_out_after_in'
                    and conrelid = 'public.staff_attendance'::regclass) then
    alter table public.staff_attendance
      add constraint staff_attendance_out_after_in
      check (checked_out_at is null or checked_at is null or checked_out_at >= checked_at);
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 4. Every refused attempt, recorded
--
-- Without this, a teacher trying last term's photograph forty times, or a script
-- walking the token space, is invisible.
-- ---------------------------------------------------------------------------
create table if not exists public.staff_checkin_attempts (
  id          bigserial primary key,
  school_id   uuid not null references public.schools(id),
  profile_id  uuid references public.profiles(id),
  staff_id    uuid references public.staff(id) on delete set null,
  presented   text,
  reason      text not null,
  device      text,
  lat         double precision,
  lng         double precision,
  created_at  timestamptz not null default now()
);

create index if not exists idx_checkin_attempts_school
  on public.staff_checkin_attempts (school_id, created_at desc);
create index if not exists idx_checkin_attempts_profile
  on public.staff_checkin_attempts (profile_id, created_at desc);

alter table public.staff_checkin_attempts enable row level security;

-- Read-only to the office, and to nobody else. There is no INSERT policy at all:
-- rows arrive only through fn_staff_check_in, which is SECURITY DEFINER. A
-- teacher who could write this table could bury her own failures in noise.
drop policy if exists checkin_attempts_select on public.staff_checkin_attempts;
create policy checkin_attempts_select on public.staff_checkin_attempts
  for select to authenticated
  using (school_id = public.current_school_id()
         and public.may_view('owner', 'principal', 'admin_clerk'));

-- ---------------------------------------------------------------------------
-- 5. The token
--
-- code.window.digest, digest = left(sha256(secret || ':' || window || ':' ||
-- secret), 8). sha256() is built in from PG11; pgcrypto is NOT installed in this
-- project and no migration has ever required an extension, because CI runs on
-- plain Postgres 16. The trailing secret is there so that even the full digest
-- would not permit a length-extension — it costs nothing to include.
--
-- Internal: revoked from every client role. It takes a secret as an argument, so
-- anything that can call it can mint tokens.
-- ---------------------------------------------------------------------------
create or replace function public.fn__checkin_digest(p_secret text, p_window bigint)
returns text language sql immutable as $$
  select left(encode(sha256((p_secret || ':' || p_window::text || ':' || p_secret)::bytea),
                     'hex'), 8);
$$;

revoke all on function public.fn__checkin_digest(text, bigint) from public;
revoke all on function public.fn__checkin_digest(text, bigint) from anon;
revoke all on function public.fn__checkin_digest(text, bigint) from authenticated;

-- The rotation period, in one place. 30 seconds, and the previous window is also
-- accepted, so a scan is good for between 30 and 60 seconds.
create or replace function public.fn__checkin_period() returns integer
  language sql immutable as $$ select 30 $$;

revoke all on function public.fn__checkin_period() from public;
revoke all on function public.fn__checkin_period() from anon;
revoke all on function public.fn__checkin_period() from authenticated;

-- ---------------------------------------------------------------------------
-- 6. Generating a code — now with a mode
-- ---------------------------------------------------------------------------
drop function if exists public.fn_generate_checkin_code(text, date, date, boolean);
create or replace function public.fn_generate_checkin_code(
  p_label text default null,
  p_valid_from date default null,
  p_valid_to date default null,
  p_deactivate_others boolean default true,
  p_rotating boolean default false
) returns jsonb language plpgsql security definer set search_path = public as $$
declare v_code text; v_secret text; v_id uuid;
begin
  if not public.has_role('owner','principal','admin_clerk') then
    raise exception 'Not permitted to generate a check-in code' using errcode = '42501';
  end if;
  if p_valid_from is not null and p_valid_to is not null and p_valid_to < p_valid_from then
    raise exception 'The code cannot expire before it starts';
  end if;
  if p_deactivate_others then
    -- Without `where school_id`, rotating one school's QR would deactivate the
    -- check-in code of every school in the database at once.
    update public.staff_checkin_codes set active = false
     where active and school_id = public.current_school_id();
  end if;
  v_code := replace(gen_random_uuid()::text, '-', '');
  -- 256 bits from two UUIDs. gen_random_bytes would be tidier and lives in
  -- pgcrypto, which this project does not install.
  v_secret := case when p_rotating
                   then replace(gen_random_uuid()::text, '-', '')
                        || replace(gen_random_uuid()::text, '-', '')
              end;
  insert into public.staff_checkin_codes
    (code, label, valid_from, valid_to, active, created_by, rotating, secret)
  values (v_code, nullif(btrim(p_label),''), p_valid_from, p_valid_to, true,
          auth.uid(), coalesce(p_rotating, false), v_secret)
  returning id into v_id;
  -- The secret is NOT returned. The caller gets tokens from
  -- fn_checkin_display(), never the seed they are made from.
  return jsonb_build_object('id', v_id, 'code', v_code,
                            'rotating', coalesce(p_rotating, false));
end;
$$;

-- ---------------------------------------------------------------------------
-- 7. What the gate display renders
--
-- Called every few seconds by the screen at the gate. Office roles only: this is
-- the one place a live token is handed out, and a teacher who could call it
-- could sit at home refreshing it.
-- ---------------------------------------------------------------------------
--
-- STABLE, and gated on has_role rather than may_view — deliberately, and it is
-- the same category as fn_may_manage_class and fn_may_write_school_file: a
-- function that LOOKS like a read but authorises something. Handing an observer
-- a live check-in token is not letting them look at the school's records, it is
-- giving them a key to the gate. It is named in the has_role exemption list in
-- check-readonly-writes.py, verify.sql and detect.sql for that reason.
create or replace function public.fn_checkin_display()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_school uuid := public.current_school_id();
  v_c record; v_win bigint; v_period integer := public.fn__checkin_period();
  v_today date := (now() at time zone 'Asia/Karachi')::date;
begin
  -- has_role, not may_view: an observer must not be handed a live check-in
  -- token. It is not a read of the school's records, it is a key to the gate.
  if not public.has_role('owner','principal','admin_clerk') then
    raise exception 'Not permitted to show the check-in code' using errcode = '42501';
  end if;

  select * into v_c from public.staff_checkin_codes
   where school_id = v_school and active
     and (valid_from is null or valid_from <= v_today)
     and (valid_to   is null or valid_to   >= v_today)
   order by created_at desc limit 1;
  if not found then
    return jsonb_build_object('status', 'none');
  end if;

  if not v_c.rotating then
    return jsonb_build_object(
      'status', 'static', 'code', v_c.code, 'label', v_c.label,
      'rotating', false, 'valid_to', v_c.valid_to);
  end if;

  v_win := floor(extract(epoch from now()) / v_period)::bigint;
  return jsonb_build_object(
    'status', 'rotating', 'code', v_c.code, 'label', v_c.label, 'rotating', true,
    'token', v_c.code || '.' || v_win::text || '.'
             || public.fn__checkin_digest(v_c.secret, v_win),
    'period_seconds', v_period,
    -- How long THIS token still has. The display refreshes on it rather than on
    -- a fixed timer, so a token is never shown after it has stopped working.
    'expires_in', v_period - (floor(extract(epoch from now()))::bigint % v_period),
    'valid_to', v_c.valid_to);
end;
$$;

-- ---------------------------------------------------------------------------
-- 8. The check-in itself
--
-- Rewritten rather than patched. It now: refuses a plain code against a rotating
-- record (otherwise the rotation is decorative in exactly the way the direct
-- insert was), computes lateness against the school day, treats the second scan
-- as a departure, refuses to overwrite an office mark, and records every refusal.
--
-- REFUSALS RETURN, THEY DO NOT RAISE. The first draft of this function logged the
-- attempt and then raised, which logs nothing: plpgsql has no autonomous
-- transaction, so the raise rolls the log row back with it and the refusal
-- register would have been permanently empty — and the brute-force counter that
-- reads it would never have counted past zero. So a refusal comes back as
-- {status: 'refused', message: ...} and the log row commits. The web wrapper
-- turns that into the same thrown error the UI has always shown, so nothing
-- downstream can quietly ignore one.
--
-- Only two things still raise: not being signed in (there is no account to log
-- against) and the school having no location set while the geofence is on, which
-- is a misconfiguration by the office rather than an attempt by a teacher.
-- ---------------------------------------------------------------------------
drop function if exists public.fn_staff_check_in(text, double precision, double precision, text);
create or replace function public.fn_staff_check_in(
  p_code text,
  p_lat double precision default null,
  p_lng double precision default null,
  p_device text default null
) returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_school uuid;
  v_staff  uuid;
  v_c      record;
  v_now    timestamptz := now();
  v_today  date := (now() at time zone 'Asia/Karachi')::date;
  v_exist  record;
  v_geo_on boolean; v_lat double precision; v_lng double precision;
  v_radius integer; v_dist double precision;
  v_start  time; v_grace integer;
  v_period integer := public.fn__checkin_period();
  v_parts  text[]; v_bare text; v_win bigint; v_cur bigint;
  v_late   integer; v_status public.attendance_status;
  v_new    uuid; v_since_in integer;
begin
  if auth.uid() is null then raise exception 'Not authenticated' using errcode = '42501'; end if;
  v_school := public.current_school_id();
  v_staff  := public.my_staff_id();

  if v_staff is null then
    return public.fn__checkin_refuse(v_school, null, p_code, 'login not linked to a staff record',
      'Your login is not linked to a staff record — ask the principal to link it in Staff.',
      p_device, p_lat, p_lng);
  end if;

  -- ---- brute force ------------------------------------------------------
  -- More than ten refusals in ten minutes from THIS ACCOUNT and it stops. Per
  -- account rather than per school, so one person's locked-out phone cannot
  -- stop the rest of the staff room checking in. The lockout itself is NOT
  -- logged, so the window clears ten minutes after the last real attempt
  -- instead of extending itself for as long as somebody keeps trying.
  if (select count(*) from public.staff_checkin_attempts
       where school_id = v_school and profile_id = auth.uid()
         and created_at > v_now - interval '10 minutes') >= 10 then
    return jsonb_build_object('status', 'refused', 'reason', 'rate limited',
      'message', 'Too many failed check-in attempts. Wait ten minutes, or ask the office to mark you present.');
  end if;

  -- ---- the code ---------------------------------------------------------
  v_bare := btrim(coalesce(p_code, ''));
  if v_bare = '' then
    return public.fn__checkin_refuse(v_school, v_staff, p_code, 'no code presented',
      'No check-in code was presented. Scan the code again.', p_device, p_lat, p_lng);
  end if;

  -- A rotating token is code.window.digest. Split first, then look the code up,
  -- so a token built around another school's code cannot be matched by prefix.
  v_parts := string_to_array(v_bare, '.');
  select * into v_c from public.staff_checkin_codes
   where school_id = v_school and active and code = v_parts[1];
  if not found then
    return public.fn__checkin_refuse(v_school, v_staff, p_code, 'unknown or inactive code',
      'Invalid or inactive check-in code', p_device, p_lat, p_lng);
  end if;

  if v_c.valid_from is not null and v_today < v_c.valid_from then
    return public.fn__checkin_refuse(v_school, v_staff, p_code, 'code not active yet',
      'This check-in code is not active yet', p_device, p_lat, p_lng);
  end if;
  if v_c.valid_to is not null and v_today > v_c.valid_to then
    return public.fn__checkin_refuse(v_school, v_staff, p_code, 'code expired',
      'This check-in code has expired', p_device, p_lat, p_lng);
  end if;

  if v_c.rotating then
    if coalesce(array_length(v_parts, 1), 0) <> 3 then
      -- The whole point. A bare code against a rotating record is the
      -- photographed poster, and accepting it would make the rotation
      -- decorative in exactly the way the direct insert was.
      return public.fn__checkin_refuse(v_school, v_staff, p_code,
        'plain code presented against a rotating code',
        'This school uses a rotating check-in code. Scan the code on the screen at the gate — a saved link or an old photo will not work.',
        p_device, p_lat, p_lng);
    end if;
    begin
      v_win := nullif(v_parts[2], '')::bigint;
    exception when others then
      v_win := null;
    end;
    v_cur := floor(extract(epoch from v_now) / v_period)::bigint;
    -- The current window and the one before it. Nothing older: that is the
    -- difference between "a photograph is worth a minute" and "a photograph is
    -- worth a term".
    if v_win is null or v_win > v_cur or v_win < v_cur - 1 then
      return public.fn__checkin_refuse(v_school, v_staff, p_code, 'stale or future token',
        'That code has already changed. Look at the screen and scan the code showing now.',
        p_device, p_lat, p_lng);
    end if;
    if v_parts[3] <> public.fn__checkin_digest(v_c.secret, v_win) then
      return public.fn__checkin_refuse(v_school, v_staff, p_code, 'bad token digest',
        'That check-in code is not valid. Scan the code on the screen at the gate.',
        p_device, p_lat, p_lng);
    end if;
  elsif coalesce(array_length(v_parts, 1), 0) <> 1 then
    return public.fn__checkin_refuse(v_school, v_staff, p_code,
      'token presented against a static code',
      'Invalid or inactive check-in code', p_device, p_lat, p_lng);
  end if;

  -- ---- the geofence -----------------------------------------------------
  -- A deterrent, not a control: the coordinates come from the phone and a
  -- browser can be told to lie. Kept because it raises the effort, and the
  -- Settings copy says exactly this rather than implying more.
  select geofence_enabled, geo_lat, geo_lng, geo_radius_m, day_starts_at, late_grace_minutes
    into v_geo_on, v_lat, v_lng, v_radius, v_start, v_grace
    from public.school_settings where school_id = v_school;
  if coalesce(v_geo_on, false) then
    if p_lat is null or p_lng is null then
      return public.fn__checkin_refuse(v_school, v_staff, p_code, 'no location supplied',
        'Location is required to check in — enable location and try again.', p_device, p_lat, p_lng);
    end if;
    if v_lat is null or v_lng is null then
      -- The office has switched the geofence on and not set the school's
      -- position. That is a misconfiguration, not an attempt, so it raises
      -- rather than filling the refusal register with the office's own mistake.
      raise exception 'School location is not set — ask the principal to set it in Settings.';
    end if;
    v_dist := 2 * 6371000 * asin(least(1, sqrt(
      power(sin(radians((p_lat - v_lat) / 2)), 2)
      + cos(radians(v_lat)) * cos(radians(p_lat)) * power(sin(radians((p_lng - v_lng) / 2)), 2))));
    if v_dist > coalesce(v_radius, 200) then
      return public.fn__checkin_refuse(v_school, v_staff, p_code,
        'outside the geofence (' || round(v_dist) || ' m)',
        format('You are too far from the school to check in (about %s m away).', round(v_dist)),
        p_device, p_lat, p_lng);
    end if;
  end if;

  -- ---- what is already recorded for today -------------------------------
  select * into v_exist from public.staff_attendance
   where staff_id = v_staff and attendance_date = v_today and school_id = v_school;

  if v_exist.id is not null and v_exist.source = 'manual' then
    -- An office mark outranks a scan. Otherwise a teacher marked absent could
    -- scan the absence away.
    return jsonb_build_object(
      'status', 'office_marked',
      'attendance_status', v_exist.status,
      'reason', v_exist.reason,
      'checked_at', v_exist.checked_at);
  end if;

  if v_exist.id is not null then
    -- ---- the second scan is the check-out ------------------------------
    v_since_in := floor(extract(epoch from (v_now - v_exist.checked_at)) / 60)::integer;
    if v_exist.checked_at is not null and v_since_in < coalesce(v_grace, 10) then
      -- A double scan on arrival must not check somebody out at 08:01.
      return jsonb_build_object(
        'status', 'already', 'checked_at', v_exist.checked_at,
        'attendance_status', v_exist.status, 'late_minutes', v_exist.late_minutes);
    end if;
    update public.staff_attendance a
       set checked_out_at = v_now,
           worked_minutes = case when a.checked_at is not null
                                 then floor(extract(epoch from (v_now - a.checked_at)) / 60)::integer end,
           device = coalesce(nullif(btrim(p_device), ''), a.device)
     where a.id = v_exist.id and a.school_id = v_school
     returning * into v_exist;
    return jsonb_build_object(
      'status', 'out', 'checked_at', v_exist.checked_at,
      'checked_out_at', v_exist.checked_out_at,
      'worked_minutes', v_exist.worked_minutes,
      'attendance_status', v_exist.status, 'late_minutes', v_exist.late_minutes);
  end if;

  -- ---- lateness ---------------------------------------------------------
  -- With no start time set, nothing is ever late. Inventing a default would mark
  -- a whole staff room late on the day the school upgraded.
  v_late := null; v_status := 'present';
  if v_start is not null then
    v_late := floor(extract(epoch from
                ((v_now at time zone 'Asia/Karachi')::time - v_start)) / 60)::integer
              - coalesce(v_grace, 10);
    if v_late > 0 then v_status := 'late'; else v_late := 0; end if;
  end if;

  insert into public.staff_attendance
    (school_id, staff_id, attendance_date, status, checked_at, code_id, code_window,
     source, device, late_minutes)
  values (v_school, v_staff, v_today, v_status, v_now, v_c.id, v_win,
          'qr', nullif(btrim(p_device), ''), v_late)
  on conflict (staff_id, attendance_date) do nothing
  returning id into v_new;

  if v_new is null then
    -- Two scans in the same instant. Report what won rather than raising.
    select * into v_exist from public.staff_attendance
     where staff_id = v_staff and attendance_date = v_today and school_id = v_school;
    return jsonb_build_object('status', 'already', 'checked_at', v_exist.checked_at,
                              'attendance_status', v_exist.status,
                              'late_minutes', v_exist.late_minutes);
  end if;

  return jsonb_build_object('status', 'ok', 'checked_at', v_now,
                            'attendance_status', v_status, 'late_minutes', v_late,
                            'rotating', v_c.rotating);
end;
$$;

-- ---------------------------------------------------------------------------
-- 9. The refusal: one function that logs it AND builds the answer
--
-- Its own function so that logging and refusing cannot come apart — a new
-- refusal path physically cannot be written without recording it, because the
-- return value only exists here. The table needs no INSERT policy as a result: a
-- teacher who could write it could bury her own failures in noise.
--
-- Internal, revoked from every client role: it can write any reason against any
-- staff id in the caller's school.
-- ---------------------------------------------------------------------------
create or replace function public.fn__checkin_refuse(
  p_school uuid, p_staff uuid, p_presented text, p_reason text, p_message text,
  p_device text, p_lat double precision, p_lng double precision
) returns jsonb language plpgsql security definer set search_path = public as $$
begin
  insert into public.staff_checkin_attempts
    (school_id, profile_id, staff_id, presented, reason, device, lat, lng)
  values (p_school, auth.uid(), p_staff, left(coalesce(p_presented, ''), 120),
          p_reason, nullif(left(coalesce(p_device, ''), 120), ''), p_lat, p_lng);
  return jsonb_build_object('status', 'refused', 'reason', p_reason, 'message', p_message);
end;
$$;

revoke all on function public.fn__checkin_refuse(uuid, uuid, text, text, text, text, double precision, double precision) from public;
revoke all on function public.fn__checkin_refuse(uuid, uuid, text, text, text, text, double precision, double precision) from anon;
revoke all on function public.fn__checkin_refuse(uuid, uuid, text, text, text, text, double precision, double precision) from authenticated;

-- ---------------------------------------------------------------------------
-- 10. An office mark that overwrites a scan needs a reason
-- ---------------------------------------------------------------------------
create or replace function public.fn_set_staff_attendance(
  p_staff_id uuid, p_date date, p_status public.attendance_status, p_reason text default null
) returns void language plpgsql security definer set search_path = public as $$
declare v_prior record;
begin
  if not public.has_role('owner','principal','admin_clerk') then
    raise exception 'Not permitted to set staff attendance' using errcode = '42501';
  end if;
  perform public.assert_own('staff', p_staff_id);
  if p_date > current_date then
    raise exception 'Attendance cannot be recorded for a day that has not happened yet';
  end if;

  select * into v_prior from public.staff_attendance
   where staff_id = p_staff_id and attendance_date = p_date
     and school_id = public.current_school_id();

  -- Overwriting a recorded scan with a judgement is exactly the thing somebody
  -- has to be able to explain a month later. A principal who knows a teacher
  -- left at nine outranks the machine — but says so.
  if v_prior.id is not null and v_prior.source = 'qr'
     and nullif(btrim(coalesce(p_reason, '')), '') is null then
    raise exception 'This day was recorded by a check-in at %. Changing it needs a reason.',
      to_char(v_prior.checked_at at time zone 'Asia/Karachi', 'HH24:MI');
  end if;

  insert into public.staff_attendance
    (staff_id, attendance_date, status, source, reason, marked_by, checked_at)
  values (p_staff_id, p_date, p_status, 'manual', nullif(btrim(p_reason),''), auth.uid(), now())
  on conflict (staff_id, attendance_date) do update
    set status = excluded.status, source = 'manual', reason = excluded.reason,
        marked_by = excluded.marked_by,
        -- The scan is not erased. What time somebody actually arrived is a fact
        -- worth keeping even when the office overrides the status.
        checked_at = coalesce(public.staff_attendance.checked_at, excluded.checked_at);
end;
$$;

-- ---------------------------------------------------------------------------
-- 11. The daily register — the thing that makes any of this useful
--
-- The direct-insert loophole survived because nothing displayed code_id. Every
-- staff member, present or not, with what was scanned and what was typed.
-- ---------------------------------------------------------------------------
create or replace function public.fn_staff_attendance_day(p_date date default null)
returns table (
  staff_id uuid, full_name text, designation text, employee_no text,
  status text, checked_at timestamptz, checked_out_at timestamptz,
  late_minutes integer, worked_minutes integer,
  source text, scanned boolean, code_label text, code_window bigint,
  device text, reason text, marked_by_name text
) language plpgsql stable security definer set search_path = public as $$
declare
  v_school uuid := public.current_school_id();
  v_date date := coalesce(p_date, (now() at time zone 'Asia/Karachi')::date);
begin
  if not public.may_view('owner','principal','admin_clerk') then
    raise exception 'Not permitted' using errcode = '42501';
  end if;

  return query
  select s.id, s.full_name, s.designation, s.employee_no,
         coalesce(a.status::text, 'not marked'),
         a.checked_at, a.checked_out_at, a.late_minutes, a.worked_minutes,
         a.source,
         -- The distinction the register was missing. A row with source 'qr' and
         -- no code_id is what the forged insert produced.
         (a.id is not null and a.code_id is not null),
         c.label, a.code_window, a.device, a.reason, p.full_name
    from public.staff s
    left join public.staff_attendance a
      on a.staff_id = s.id and a.attendance_date = v_date and a.school_id = v_school
    left join public.staff_checkin_codes c
      on c.id = a.code_id and c.school_id = v_school
    left join public.profiles p
      on p.id = a.marked_by and p.school_id = v_school
   where s.school_id = v_school and s.status = 'active'
   order by s.full_name;
end;
$$;

-- ---------------------------------------------------------------------------
-- 12. Refused attempts, for the office
-- ---------------------------------------------------------------------------
create or replace function public.fn_checkin_attempts(p_limit integer default 50)
returns table (
  id bigint, staff_name text, reason text, presented text,
  device text, created_at timestamptz
) language plpgsql stable security definer set search_path = public as $$
declare v_school uuid := public.current_school_id();
begin
  if not public.may_view('owner','principal','admin_clerk') then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  return query
  select t.id, s.full_name, t.reason, t.presented, t.device, t.created_at
    from public.staff_checkin_attempts t
    left join public.staff s on s.id = t.staff_id and s.school_id = v_school
   where t.school_id = v_school
   order by t.created_at desc
   limit greatest(1, least(coalesce(p_limit, 50), 500));
end;
$$;

-- ---------------------------------------------------------------------------
-- 13. Grants
-- ---------------------------------------------------------------------------
grant execute on function public.fn_generate_checkin_code(text, date, date, boolean, boolean) to authenticated;
grant execute on function public.fn_checkin_display() to authenticated;
grant execute on function public.fn_staff_check_in(text, double precision, double precision, text) to authenticated;
grant execute on function public.fn_set_staff_attendance(uuid, date, public.attendance_status, text) to authenticated;
grant execute on function public.fn_staff_attendance_day(date) to authenticated;
grant execute on function public.fn_checkin_attempts(integer) to authenticated;
grant select on public.staff_checkin_attempts to authenticated;

-- ─────────────────────────────────────────────────────────────────────────
-- 0063_constraint_function_grants.sql
-- ─────────────────────────────────────────────────────────────────────────
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

-- ─────────────────────────────────────────────────────────────────────────
-- 0064_operator_billing.sql
-- ─────────────────────────────────────────────────────────────────────────
-- =============================================================================
-- 0064 — The operator had no books
--
-- This product's central promise to a school is that every rupee has a row. The
-- person SELLING the software kept no such rows about the schools.
--
-- Reproduced on a real database. Three customer schools; Al-Noor renews twelve
-- months of `growth`:
--
--   select fn_activate_subscription(<al-noor>, 'growth', 12);
--   → {"period_start": "2027-07-26", "period_end": "2028-07-25", ...}
--
--   what was Al-Noor charged? ......... no table records a charge to a school
--   how much has Al-Noor ever paid? ... no function answers it
--   which schools owe us money? ....... unanswerable
--   what did we invoice this month? ... `plans` holds a price list, nothing else
--   who granted it, and when? ......... nothing records the actor; audit_log had
--                                       zero rows for the renewal
--
-- The subtle one is "which schools owe us money". The console shows `days_left`,
-- so it LOOKS like it answers that — but a school that renewed on trust and
-- never paid is indistinguishable from one that paid in full. Both show 335 days
-- left. The receivable is invisible precisely because the screen looks like it is
-- showing it.
--
-- And a revenue leak found in the same probe: Al-Noor is on `growth` (limit 300)
-- with 420 students. The console itself computes limit_state = 'over' and
-- suggested_plan = 'institution' — and the renewal put it back on `growth` for
-- another year at the 300-student price. The screen knew; the renewal path never
-- asked.
--
-- Design and the argument against each decision: docs/OPERATOR-BILLING-DESIGN.md
--
-- Re-runnable.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. The two tables
--
-- Keyed on school_id and readable ONLY by is_platform_admin(). No policy here
-- mentions current_school_id(): the operator's reach stays exactly what it was
-- — schools, subscriptions, plans, counts — and a school user must see none of
-- this. See D5.
-- ---------------------------------------------------------------------------
create table if not exists public.platform_invoices (
  id            uuid primary key default gen_random_uuid(),
  school_id     uuid not null references public.schools(id) on delete cascade,
  plan_code     text not null references public.plans(code),
  cycle         public.billing_cycle not null,
  months        integer not null check (months >= 1),
  period_start  date not null,
  period_end    date not null,
  -- What we asked for, and what the price list said at the time. Keeping both
  -- is what makes a discount visible five years later: `amount` alone cannot
  -- distinguish a cheap plan from a generous one.
  amount        numeric(12,2) not null check (amount >= 0),
  list_amount   numeric(12,2) not null check (list_amount >= 0),
  issued_on     date not null default current_date,
  due_on        date,
  note          text,
  -- The operator has no profiles row, so this is the auth user id with no FK to
  -- profiles. A FK to auth.users would be right but auth.users is not ours to
  -- constrain against from a migration.
  created_by    uuid,
  created_at    timestamptz not null default now(),
  check (period_end >= period_start)
);

create index if not exists idx_platform_invoices_school
  on public.platform_invoices(school_id, issued_on desc);

create table if not exists public.platform_payments (
  id          uuid primary key default gen_random_uuid(),
  school_id   uuid not null references public.schools(id) on delete cascade,
  -- Nullable on purpose. The school side needs a real allocation engine because
  -- a parent's payment must be split oldest-month-first across several
  -- children; here one customer pays a handful of invoices a year and netting
  -- per school is both correct and checkable by eye. See D2.
  invoice_id  uuid references public.platform_invoices(id) on delete set null,
  amount      numeric(12,2) not null check (amount > 0),
  paid_on     date not null default current_date,
  method      text not null default 'bank'
                check (method in ('bank', 'cash', 'cheque', 'online', 'other')),
  reference   text,
  note        text,
  created_by  uuid,
  created_at  timestamptz not null default now()
);

create index if not exists idx_platform_payments_school
  on public.platform_payments(school_id, paid_on desc);

alter table public.platform_invoices enable row level security;
alter table public.platform_payments enable row level security;

-- Read-only through RLS even for the operator: every write goes through a
-- SECURITY DEFINER function, so there is one place that decides what a valid
-- charge or receipt looks like. An UPDATE path would let an invoice be edited
-- into something it never was, which is the same argument 0061 made about
-- certificates.
drop policy if exists platform_invoices_select on public.platform_invoices;
create policy platform_invoices_select on public.platform_invoices
  for select to authenticated using (public.is_platform_admin());

drop policy if exists platform_payments_select on public.platform_payments;
create policy platform_payments_select on public.platform_payments
  for select to authenticated using (public.is_platform_admin());

-- ---------------------------------------------------------------------------
-- 2. What a plan costs for a given number of months
--
-- One place, because "months >= 12 means yearly" is already decided by
-- fn_activate_subscription and the two must not disagree about the price of the
-- same renewal.
-- ---------------------------------------------------------------------------
create or replace function public.fn__plan_price(p_plan_code text, p_months integer)
returns numeric language sql stable as $$
  select case
    when p_months >= 12
      then round(p.price_yearly * (p_months::numeric / 12), 2)
      else round(p.price_monthly * p_months, 2)
  end
  from public.plans p where p.code = p_plan_code;
$$;

revoke all on function public.fn__plan_price(text, integer) from public;

-- ---------------------------------------------------------------------------
-- 3. What one school owes us
--
-- DERIVED, never stored. A stored balance drifts from the rows that produced it
-- and then two screens disagree about what a customer owes — the rule the
-- school-facing side already follows.
-- ---------------------------------------------------------------------------
create or replace function public.fn_platform_outstanding(p_school_id uuid)
returns numeric language plpgsql stable security definer set search_path = public as $$
declare v_inv numeric; v_paid numeric;
begin
  if not public.is_platform_admin() then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  select coalesce(sum(amount), 0) into v_inv
    from public.platform_invoices where school_id = p_school_id;
  select coalesce(sum(amount), 0) into v_paid
    from public.platform_payments where school_id = p_school_id;
  return v_inv - v_paid;
end;
$$;

-- ---------------------------------------------------------------------------
-- 4. Granting time now writes the charge
--
-- DROP first: `create or replace` cannot add parameters. The old 3-argument form
-- must not survive as an overload — leaving it would mean the app could still
-- call the version that grants a year and records no money, which is the whole
-- defect.
-- ---------------------------------------------------------------------------
drop function if exists public.fn_activate_subscription(uuid, text, integer);
drop function if exists public.fn_activate_subscription(uuid, text, integer, numeric, text, boolean);

create function public.fn_activate_subscription(
  p_school_id uuid,
  p_plan_code text,
  p_months integer default 12,
  -- Null means "charge the list price". An explicit amount that differs from
  -- list REQUIRES a note, so a discount is always one somebody wrote a reason
  -- for. Zero is a legitimate charge — a pilot, a favour, an apology — and
  -- recording it is the point: a free year that leaves no trace is how a
  -- business loses track of what it has given away.
  p_amount numeric default null,
  p_note text default null,
  -- Renewing a school onto a plan it has outgrown is refused unless the operator
  -- says so on purpose. The information was already on the screen and the
  -- renewal ignored it.
  p_allow_over_limit boolean default false
) returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_start date; v_end date; v_cycle public.billing_cycle;
  v_list numeric; v_amount numeric;
  v_count integer; v_limit integer; v_margin integer; v_suggest text;
  v_inv uuid; v_actor uuid := auth.uid();
  v_note text := nullif(btrim(coalesce(p_note, '')), '');
begin
  if not public.is_platform_admin() then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  if not exists (select 1 from public.plans where code = p_plan_code) then
    raise exception 'Unknown plan %', p_plan_code;
  end if;
  if p_months is null or p_months < 1 then
    raise exception 'Months must be at least 1';
  end if;

  -- ---- the over-limit refusal -------------------------------------------
  -- Counted fresh rather than trusting the stored count, because the whole
  -- decision turns on it and a stale count would wave the renewal through.
  perform public.fn_refresh_student_count(p_school_id);
  select sub.student_count, p.student_limit
    into v_count, v_limit
    from public.subscriptions sub
    join public.plans p on p.code = p_plan_code
   where sub.school_id = p_school_id;

  if v_count is null then
    raise exception 'No subscription for school %', p_school_id;
  end if;

  v_margin := public.plan_margin_limit(v_limit);
  if v_limit is not null and v_count > v_margin then
    select p2.code into v_suggest from public.plans p2
     where p2.active and (p2.student_limit is null or p2.student_limit >= v_count)
     order by p2.sort_order limit 1;
    if not coalesce(p_allow_over_limit, false) then
      raise exception
        '% has % students; % allows % (% with the margin). Put them on % instead, '
        'or renew on % on purpose.',
        (select name from public.schools where id = p_school_id),
        v_count, p_plan_code, v_limit, v_margin,
        coalesce(v_suggest, 'a custom plan'), p_plan_code;
    end if;
    -- Renewed over the limit deliberately: the fact goes ON the invoice, not
    -- into a log nobody reads.
    v_note := btrim(coalesce(v_note || ' — ', '')
      || format('renewed on %s with %s students against a limit of %s',
                p_plan_code, v_count, v_limit));
  end if;

  -- ---- the period --------------------------------------------------------
  -- Renewing early extends from the existing end date rather than from today,
  -- so a school that pays a week ahead does not lose that week.
  select case
    when period_end is not null and period_end >= current_date
      then period_end + 1 else current_date end
  into v_start
  from public.subscriptions where school_id = p_school_id;

  v_end   := (v_start + (p_months || ' months')::interval)::date - 1;
  v_cycle := case when p_months >= 12 then 'yearly' else 'monthly' end::public.billing_cycle;

  -- ---- the money --------------------------------------------------------
  v_list   := coalesce(public.fn__plan_price(p_plan_code, p_months), 0);
  v_amount := coalesce(p_amount, v_list);
  if v_amount < 0 then
    raise exception 'An amount cannot be negative';
  end if;
  if v_amount <> v_list and v_note is null then
    raise exception
      'Charging % where the price list says % needs a reason — it is recorded on '
      'the invoice.', to_char(v_amount, 'FM999999999.00'),
      to_char(v_list, 'FM999999999.00');
  end if;

  update public.subscriptions
     set plan_code     = p_plan_code,
         status        = 'active',
         cycle         = v_cycle,
         period_start  = v_start,
         period_end    = v_end,
         grace_ends_on = v_end + public.grace_days()
   where school_id = p_school_id;

  insert into public.platform_invoices
    (school_id, plan_code, cycle, months, period_start, period_end,
     amount, list_amount, due_on, note, created_by)
  values
    (p_school_id, p_plan_code, v_cycle, p_months, v_start, v_end,
     v_amount, v_list, current_date + 14, v_note, v_actor)
  returning id into v_inv;

  -- Against the school it concerns, so the school's own owner can see "your
  -- subscription was activated until ___". That is their subscription, not a
  -- leak. actor_role stays null: the operator has no profiles row and therefore
  -- no user_role, and inventing one would put a non-school identity into a
  -- school-scoped enum. Written explicitly rather than by audit_trigger(),
  -- which reads current_school_id() and would fail the NOT NULL for an operator.
  insert into public.audit_log(school_id, actor, action, entity, entity_id, after, reason)
  values (p_school_id, v_actor, 'subscription_activated', 'subscriptions',
          p_school_id::text,
          jsonb_build_object('plan_code', p_plan_code, 'months', p_months,
                             'period_start', v_start, 'period_end', v_end,
                             'amount', v_amount, 'list_amount', v_list,
                             'invoice_id', v_inv),
          v_note);

  return jsonb_build_object(
    'school_id', p_school_id, 'plan_code', p_plan_code,
    'period_start', v_start, 'period_end', v_end,
    'grace_ends_on', v_end + public.grace_days(),
    'invoice_id', v_inv, 'amount', v_amount, 'list_amount', v_list,
    'outstanding', public.fn_platform_outstanding(p_school_id));
end;
$$;

-- ---------------------------------------------------------------------------
-- 5. Recording what a school paid us
-- ---------------------------------------------------------------------------
create or replace function public.fn_platform_record_payment(
  p_school_id uuid,
  p_amount numeric,
  p_paid_on date default null,
  p_method text default 'bank',
  p_reference text default null,
  p_invoice_id uuid default null,
  p_note text default null
) returns jsonb language plpgsql security definer set search_path = public as $$
declare v_id uuid; v_actor uuid := auth.uid();
begin
  if not public.is_platform_admin() then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  if p_amount is null or p_amount <= 0 then
    raise exception 'A payment must be more than zero';
  end if;
  if not exists (select 1 from public.schools where id = p_school_id) then
    raise exception 'Unknown school %', p_school_id;
  end if;
  -- An invoice from ANOTHER school would silently move that school's balance.
  if p_invoice_id is not null
     and not exists (select 1 from public.platform_invoices
                      where id = p_invoice_id and school_id = p_school_id) then
    raise exception 'That invoice does not belong to this school';
  end if;

  insert into public.platform_payments
    (school_id, invoice_id, amount, paid_on, method, reference, note, created_by)
  values (p_school_id, p_invoice_id, p_amount,
          coalesce(p_paid_on, current_date), coalesce(p_method, 'bank'),
          nullif(btrim(coalesce(p_reference, '')), ''),
          nullif(btrim(coalesce(p_note, '')), ''), v_actor)
  returning id into v_id;

  insert into public.audit_log(school_id, actor, action, entity, entity_id, after, reason)
  values (p_school_id, v_actor, 'platform_payment_recorded', 'platform_payments',
          v_id::text,
          jsonb_build_object('amount', p_amount, 'method', coalesce(p_method, 'bank'),
                             'paid_on', coalesce(p_paid_on, current_date),
                             'invoice_id', p_invoice_id),
          nullif(btrim(coalesce(p_note, '')), ''));

  return jsonb_build_object(
    'payment_id', v_id, 'school_id', p_school_id, 'amount', p_amount,
    'outstanding', public.fn_platform_outstanding(p_school_id));
end;
$$;

-- ---------------------------------------------------------------------------
-- 6. One school's history, invoices and payments interleaved
-- ---------------------------------------------------------------------------
drop function if exists public.fn_platform_ledger(uuid);
create function public.fn_platform_ledger(p_school_id uuid)
returns table (
  entry_date date, kind text, description text,
  charged numeric, paid numeric, note text, reference text
) language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_platform_admin() then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  return query
  select i.issued_on, 'invoice'::text,
         format('%s · %s month%s · %s to %s', i.plan_code, i.months,
                case when i.months = 1 then '' else 's' end,
                i.period_start, i.period_end),
         i.amount, null::numeric,
         -- A discount only reads as a discount next to the list price.
         case when i.amount <> i.list_amount
              then format('list %s — %s', to_char(i.list_amount, 'FM999999999.00'),
                          coalesce(i.note, 'no reason recorded'))
              else i.note end,
         null::text
    from public.platform_invoices i
   where i.school_id = p_school_id
  union all
  select p.paid_on, 'payment'::text,
         format('%s payment', p.method),
         null::numeric, p.amount, p.note, p.reference
    from public.platform_payments p
   where p.school_id = p_school_id
   order by 1, 2 desc;
end;
$$;

-- ---------------------------------------------------------------------------
-- 7. What we invoiced and collected over a period
-- ---------------------------------------------------------------------------
drop function if exists public.fn_platform_revenue(date, date);
create function public.fn_platform_revenue(p_from date, p_to date)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_invoiced numeric; v_collected numeric; v_discounted numeric;
  v_outstanding numeric; v_by_plan jsonb; v_owing jsonb;
begin
  if not public.is_platform_admin() then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  if p_from is null or p_to is null or p_to < p_from then
    raise exception 'Give a start date and an end date, the end not before the start';
  end if;

  select coalesce(sum(amount), 0), coalesce(sum(list_amount - amount), 0)
    into v_invoiced, v_discounted
    from public.platform_invoices
   where issued_on between p_from and p_to;

  select coalesce(sum(amount), 0) into v_collected
    from public.platform_payments
   where paid_on between p_from and p_to;

  select coalesce(jsonb_agg(x order by x->>'plan_code'), '[]'::jsonb) into v_by_plan
    from (
      select jsonb_build_object('plan_code', plan_code,
                                'invoices', count(*),
                                'amount', sum(amount)) as x
        from public.platform_invoices
       where issued_on between p_from and p_to
       group by plan_code) g;

  -- Everything ever invoiced minus everything ever paid: a receivable does not
  -- belong to the month it was raised in.
  select coalesce(sum(i), 0), coalesce(jsonb_agg(j order by j->>'school_name'), '[]'::jsonb)
    into v_outstanding, v_owing
    from (
      select bal.owed as i,
             jsonb_build_object('school_id', bal.school_id,
                                'school_name', bal.name,
                                'outstanding', bal.owed) as j
        from (
          select s.id as school_id, s.name,
                 coalesce((select sum(amount) from public.platform_invoices
                            where school_id = s.id), 0)
               - coalesce((select sum(amount) from public.platform_payments
                            where school_id = s.id), 0) as owed
            from public.schools s) bal
       where bal.owed > 0) o;

  return jsonb_build_object(
    'from', p_from, 'to', p_to,
    'invoiced', v_invoiced, 'collected', v_collected,
    'discounted', v_discounted,
    'outstanding_total', v_outstanding,
    'by_plan', v_by_plan,
    'schools_owing', v_owing);
end;
$$;

-- ---------------------------------------------------------------------------
-- 8. The console list, with the receivable on it
--
-- DROP first: the return type gains a column, which `create or replace` cannot
-- do. `outstanding` is the column that turns "who expires soon" into "who owes
-- me money" — the two looked identical before, which was defect 1c.
-- ---------------------------------------------------------------------------
drop function if exists public.fn_platform_schools();
create function public.fn_platform_schools()
returns table (
  school_id uuid, school_name text, city text,
  contact_name text, contact_phone text,
  plan_code text, status public.subscription_status,
  expires_on date, days_left integer,
  student_count integer, student_limit integer,
  limit_state text, suggested_plan text, needs_upgrade boolean,
  outstanding numeric, last_paid_on date
) language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_platform_admin() then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  return query
    select
      s.id, s.name, s.city, s.contact_name, s.contact_phone,
      sub.plan_code,
      public.fn_effective_status(s.id),
      case when sub.status = 'trialing' then sub.trial_ends_on else sub.period_end end,
      (case when sub.status = 'trialing' then sub.trial_ends_on else sub.period_end end
        - current_date)::integer,
      sub.student_count,
      p.student_limit,
      case
        when p.student_limit is null then 'ok'
        when sub.student_count <= p.student_limit then 'ok'
        when sub.student_count <= public.plan_margin_limit(p.student_limit) then 'within_margin'
        else 'over' end,
      sug.code,
      sug.code is distinct from sub.plan_code,
      coalesce((select sum(i.amount) from public.platform_invoices i
                 where i.school_id = s.id), 0)
        - coalesce((select sum(pm.amount) from public.platform_payments pm
                     where pm.school_id = s.id), 0),
      (select max(pm.paid_on) from public.platform_payments pm
        where pm.school_id = s.id)
    from public.schools s
    join public.subscriptions sub on sub.school_id = s.id
    join public.plans p on p.code = sub.plan_code
    cross join lateral (
      select p2.code from public.plans p2
       where p2.active and (p2.student_limit is null or p2.student_limit >= sub.student_count)
       order by p2.sort_order limit 1
    ) sug
    order by s.name;
end;
$$;

-- ---------------------------------------------------------------------------
-- 9. Grants
--
-- Every one of these gates on is_platform_admin() as its first statement, so
-- granting to `authenticated` is what lets the operator's own signed-in session
-- call them. A school user calling any of them gets 42501.
-- ---------------------------------------------------------------------------
grant execute on function public.fn_platform_outstanding(uuid) to authenticated;
grant execute on function public.fn_platform_ledger(uuid) to authenticated;
grant execute on function public.fn_platform_revenue(date, date) to authenticated;
grant execute on function public.fn_platform_schools() to authenticated;
grant execute on function
  public.fn_activate_subscription(uuid, text, integer, numeric, text, boolean)
  to authenticated;
grant execute on function
  public.fn_platform_record_payment(uuid, numeric, date, text, text, uuid, text)
  to authenticated;

-- ─────────────────────────────────────────────────────────────────────────
-- 0065_invite_only_provisioning.sql
-- ─────────────────────────────────────────────────────────────────────────
-- =============================================================================
-- 0065 — A parent could make themselves principal
--
-- handle_new_user() decided a new login's SCHOOL and ROLE from
-- new.raw_user_meta_data. That field is whatever the browser passes to
-- auth.signUp({options:{data:{...}}}) using the PUBLIC anon key. 'principal' and
-- 'accountant' were both on its recognised-role whitelist, and a recognised role
-- was created ACTIVE.
--
-- Proven on a real database. Two strangers signed up naming a victim school:
--
--        full_name       |    role    | active
--   ---------------------+------------+--------
--    Real Owner          | owner      | t
--    Totally Normal Pare | accountant | t     <-- self-assigned
--    Also Normal         | principal  | t     <-- self-assigned
--
-- Both then passed has_role() and may_view(), so both could read that school's
-- fees, payments and children.
--
-- Every signed-in user already knows their own school_id, so the floor on this
-- was: ANY parent, teacher or clerk could create a second login and make
-- themselves PRINCIPAL of their own school. Reaching another school needed only
-- its UUID, which leaks through a screenshot or a support chat.
--
-- The whitelist was not the bug. 0059 added it, and it correctly stopped an
-- UNRECOGNISED role landing active. The bug is that a RECOGNISED role was
-- believed at all, because the thing supplying it is the attacker.
--
-- THE RULE THIS ESTABLISHES: authorisation never comes from a field the client
-- can write. Two trusted sources replace it.
--
--   1. raw_app_meta_data — settable only by the service role (the Edge
--      Functions). A browser signUp cannot write it. This is Supabase's own
--      documented split: user_metadata is user-controlled, app_metadata is not.
--   2. public.user_invites — a row an owner or principal created for a specific
--      email, which is an authorised act checked by RLS.
--
-- raw_user_meta_data is still read for ONE thing: the display name. A forged
-- full_name is a cosmetic nuisance, not a privilege.
--
-- DEPLOYMENT ORDER MATTERS. Both Edge Functions must be redeployed with this
-- migration, because they are what supply app_metadata. If the SQL lands first,
-- a brand-new school signup creates a login with NO profile and the app says
-- "this login is not attached to a school" — visible and recoverable. That is
-- the safe direction to fail; the reverse would leave the hole open.
--
-- Re-runnable.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. Invitations
--
-- The path that lets a school add a teacher WITHOUT the create-teacher Edge
-- Function being deployed. Creating the invite is the authorised act; the
-- signup that follows merely redeems it.
-- ---------------------------------------------------------------------------
create table if not exists public.user_invites (
  id          uuid primary key default gen_random_uuid(),
  school_id   uuid not null references public.schools(id) on delete cascade,
  -- Stored folded and trimmed, and matched the same way. An invite for
  -- "Ayesha@School.pk" must be redeemable by a login typed "ayesha@school.pk",
  -- or the school raises a support ticket about a working feature.
  email       text not null,
  role        public.user_role not null,
  full_name   text,
  created_by  uuid references public.profiles(id),
  created_at  timestamptz not null default now(),
  expires_at  timestamptz not null default now() + interval '7 days',
  accepted_at timestamptz,
  accepted_by uuid,
  -- An owner is never invited. The first account of a school becomes owner
  -- through provisioning, and later owners are promoted on the Users screen by
  -- an existing owner. Allowing 'owner' here would put the school's top
  -- privilege behind an email address.
  constraint user_invites_not_owner check (role <> 'owner'),
  constraint user_invites_email_folded check (email = lower(btrim(email)))
);

-- One LIVE invite per email per school. Partial, so a redeemed or revoked
-- invite does not block issuing a fresh one.
create unique index if not exists user_invites_pending_key
  on public.user_invites (school_id, email) where accepted_at is null;

create index if not exists idx_user_invites_email
  on public.user_invites (email) where accepted_at is null;

alter table public.user_invites enable row level security;

-- The school's owner or principal manages its own invites. Deliberately NOT
-- may_view(): an observer must not read a list of pending logins, and 'readonly'
-- has no business here at all.
drop policy if exists user_invites_select on public.user_invites;
create policy user_invites_select on public.user_invites
  for select to authenticated
  using (school_id = public.current_school_id() and public.has_role('owner','principal'));

-- No INSERT/UPDATE/DELETE policy on purpose. Every write goes through the
-- definer functions below, so one place decides what a valid invite is — the
-- same rule 0064's platform tables follow.

-- ---------------------------------------------------------------------------
-- 2. The trigger, rewritten
-- ---------------------------------------------------------------------------
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public, auth as $$
declare
  -- TRUSTED. app_metadata can only be written by the service role, so these
  -- came from an Edge Function and not from a browser.
  v_school   uuid := nullif(new.raw_app_meta_data->>'school_id', '')::uuid;
  v_asked    text := nullif(new.raw_app_meta_data->>'role', '');
  -- UNTRUSTED, and used only for the display name.
  v_name     text := coalesce(
                       nullif(new.raw_user_meta_data->>'full_name', ''),
                       split_part(coalesce(new.email, ''), '@', 1));
  v_email    text := lower(btrim(coalesce(new.email, '')));
  v_inv      public.user_invites;
  v_matches  integer;
  v_is_first boolean;
  v_role     public.user_role;
  -- Still a whitelist even though the source is trusted: a typo in an Edge
  -- Function must not crash a signup on an enum cast, and defence in depth here
  -- costs one expression.
  v_known    boolean := coalesce(v_asked in ('principal','admin_clerk','accountant',
                                             'class_teacher','subject_teacher',
                                             'readonly','parent'), false);
begin
  -- ---- path A: an invitation, redeemed by email --------------------------
  -- Checked FIRST, so a school that invited someone gets the role it chose even
  -- if a stale client also sent metadata.
  if v_school is null and v_email <> '' then
    -- Deliberately NOT "order by created_at desc limit 1". Two schools can
    -- invite the same address — a teacher moonlighting at both is ordinary in
    -- Pakistan — and there is no honest way to choose between them: a profile
    -- carries ONE school_id, so picking either silently puts that person inside
    -- one school's children's records while the other school believes they are
    -- in. Ordering by created_at also ties when both invites are written in one
    -- transaction, where now() is identical, making the choice arbitrary rather
    -- than merely debatable. Caught by assertion 23 of tests/provisioning.sql.
    --
    -- So: exactly one live invitation is redeemed. More than one creates
    -- NOTHING and leaves them all pending, which is a state a human can see and
    -- resolve — the schools revoke one, or issue a second address.
    select count(*) into v_matches
      from public.user_invites
     where email = v_email and accepted_at is null and expires_at > now();

    if v_matches = 1 then
      select * into v_inv
        from public.user_invites
       where email = v_email and accepted_at is null and expires_at > now();

      insert into public.profiles (id, full_name, role, school_id, active)
      values (new.id, coalesce(nullif(btrim(coalesce(v_inv.full_name,'')),''), v_name),
              v_inv.role, v_inv.school_id, true)
      on conflict (id) do nothing;

      update public.user_invites
         set accepted_at = now(), accepted_by = new.id
       where id = v_inv.id;

      return new;
    elsif v_matches > 1 then
      -- Ambiguous. Create nothing and leave every invitation pending.
      return new;
    end if;
  end if;

  -- ---- path B: provisioned by an Edge Function ---------------------------
  -- No trusted school means we create NOTHING. A login with no profile is
  -- inert: the app tells the person their login is not attached to a school,
  -- and an owner can attach it on the Users screen. That is the correct
  -- outcome for an uninvited stranger, and it is what closes the hole.
  if v_school is null then
    return new;
  end if;

  select count(*) = 0 into v_is_first
  from public.profiles where school_id = v_school;

  -- First account of a school is its owner. Safe now in a way it was not
  -- before: v_school came from app_metadata, so only the signup Edge Function
  -- that just created this school can name it.
  v_role := (case when v_is_first then 'owner'
                  when v_known   then v_asked
                  else 'readonly' end)::public.user_role;

  insert into public.profiles (id, full_name, role, school_id, active)
  values (new.id, v_name, v_role, v_school,
          -- Active only when we know who this is. An Edge Function that names a
          -- school but no recognised role lands the account INERT rather than
          -- quietly giving it sight of the whole school — the defect 0059 fixed
          -- and this keeps fixed.
          (v_is_first or v_known))
  on conflict (id) do nothing;

  return new;
end;
$$;

-- ---------------------------------------------------------------------------
-- 3. Managing invitations
-- ---------------------------------------------------------------------------
create or replace function public.fn_invite_user(
  p_email text,
  p_role public.user_role,
  p_full_name text default null
) returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_school uuid := public.current_school_id();
  v_email  text := lower(btrim(coalesce(p_email, '')));
  v_id     uuid;
begin
  if not public.has_role('owner','principal') then
    raise exception 'Only an owner or principal may invite a user'
      using errcode = '42501';
  end if;
  if v_email = '' or position('@' in v_email) = 0 then
    raise exception 'A valid email address is required';
  end if;
  if p_role = 'owner' then
    raise exception 'An owner cannot be invited. Create the account with '
                    'another role, then promote it on the Users screen.';
  end if;

  -- Somebody already signed in with this address. Inviting them again would
  -- create a second profile for one person, which is how a school ends up with
  -- two logins for the same teacher and no idea which is live.
  if exists (select 1 from auth.users u
              join public.profiles p on p.id = u.id
             where lower(btrim(u.email)) = v_email and p.school_id = v_school) then
    raise exception '% already has a login at this school', v_email;
  end if;

  insert into public.user_invites (school_id, email, role, full_name, created_by)
  values (v_school, v_email, p_role,
          nullif(btrim(coalesce(p_full_name, '')), ''), auth.uid())
  on conflict (school_id, email) where accepted_at is null
    do update set role       = excluded.role,
                  full_name  = excluded.full_name,
                  created_by = excluded.created_by,
                  created_at = now(),
                  expires_at = now() + interval '7 days'
  returning id into v_id;

  insert into public.audit_log(school_id, actor, action, entity, entity_id, after)
  values (v_school, auth.uid(), 'user_invited', 'user_invites', v_id::text,
          jsonb_build_object('email', v_email, 'role', p_role));

  return jsonb_build_object('id', v_id, 'email', v_email, 'role', p_role,
                            'expires_at', now() + interval '7 days');
end;
$$;

create or replace function public.fn_revoke_invite(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v_school uuid := public.current_school_id(); v_email text;
begin
  if not public.has_role('owner','principal') then
    raise exception 'Only an owner or principal may revoke an invitation'
      using errcode = '42501';
  end if;
  delete from public.user_invites
   where id = p_id and school_id = v_school and accepted_at is null
   returning email into v_email;
  if v_email is null then
    raise exception 'That invitation was not found, or it has already been used';
  end if;
  insert into public.audit_log(school_id, actor, action, entity, entity_id, after)
  values (v_school, auth.uid(), 'invite_revoked', 'user_invites', p_id::text,
          jsonb_build_object('email', v_email));
end;
$$;

drop function if exists public.fn_pending_invites();
create function public.fn_pending_invites()
returns table (id uuid, email text, role text, full_name text,
               invited_by text, created_at timestamptz, expires_at timestamptz,
               expired boolean)
language plpgsql stable security definer set search_path = public as $$
declare v_school uuid := public.current_school_id();
begin
  if not public.has_role('owner','principal') then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  return query
  select i.id, i.email, i.role::text, i.full_name, p.full_name,
         i.created_at, i.expires_at, i.expires_at <= now()
    from public.user_invites i
    left join public.profiles p on p.id = i.created_by and p.school_id = v_school
   where i.school_id = v_school and i.accepted_at is null
   order by i.created_at desc;
end;
$$;

grant execute on function public.fn_invite_user(text, public.user_role, text) to authenticated;
grant execute on function public.fn_revoke_invite(uuid) to authenticated;
grant execute on function public.fn_pending_invites() to authenticated;

-- ---------------------------------------------------------------------------
-- 4. Forensics for a database that was already exposed
--
-- The hole leaves a fingerprint: a login whose raw_user_meta_data carries a
-- 'role' key was created by the client path, because neither Edge Function ever
-- put a role there. Not proof of abuse — the old createTeacherLogin fallback did
-- exactly this legitimately — but it is the list worth reading by eye.
--
-- Run it, and check every row against the staff you actually hired:
--
--   select u.email, p.role, p.active, p.created_at, s.name
--     from auth.users u
--     join public.profiles p on p.id = u.id
--     join public.schools s on s.id = p.school_id
--    where u.raw_user_meta_data ? 'role'
--    order by p.created_at desc;
--
-- Deactivate anything you do not recognise:
--   update public.profiles set active = false where id = '<uuid>';
-- ---------------------------------------------------------------------------

-- ─────────────────────────────────────────────────────────────────────────
-- 0066_fee_setup.sql
-- ─────────────────────────────────────────────────────────────────────────
-- =============================================================================
-- 0066 — A school could not set a fee, and a scheduled rise double-billed
--
-- Three defects, all proven on a real database, all in the module the whole
-- product exists for.
--
-- 1. SAVING A FEE AMOUNT ALWAYS FAILED. 0035 replaced the 3-column unique key on
--    fee_structures with a 4-column one including effective_from. The app still
--    sent the old 3-column ON CONFLICT, so every save raised
--
--      ERROR:  there is no unique or exclusion constraint matching the
--              ON CONFLICT specification            (42P10)
--
--    A 100% failure rate since 0035, on Settings -> Fee Structure.
--
-- 2. NOTHING COULD CREATE A FEE HEAD. Fifteen Settings screens exist and none of
--    them manages fee_heads, so a new school had no 'Tuition' to put an amount
--    against: the Fee Structure grid showed an empty list with a Save button and
--    nothing to fill in. (The table has had a write policy all along — this was
--    a missing screen, not a missing permission.)
--
--    Together, 1 and 2 mean a fresh Pakistani school could not bill a monthly
--    fee at all. Challans printed Rs 0, Deposits stayed empty, and Year Rollover
--    dropped amounts. The dashboard's "N classes have students but no fee set"
--    warning was honest and the school had no way to act on it.
--
-- 3. A SCHEDULED FEE RISE DOUBLE-BILLED EVERY PARENT. effective_from arrived in
--    0035 and only ONE of four readers was taught about it:
--
--      fn_generate_class_invoices  correct — latest row on or before the month
--      fn_bill_student_month       NO date filter — joins EVERY dated row
--      fn_student_monthly_fee      NO date filter — SUMS every dated row
--      getFeeStructure (the grid)  NO date filter — arbitrary row wins
--
--    Proven: tuition 1500, a rise to 1800 scheduled from 2027-01-01, then bill
--    the pupil for MAY 2026:
--
--      description | amount
--      ------------+---------
--      Tuition     | 1500.00
--      Tuition     | 1800.00      <-- not in effect for another eight months
--
--    and fn_student_monthly_fee reported the monthly fee as 3300. The two
--    billing paths in the product disagreed with each other, and the wrong one
--    is the per-student path the fee counter uses.
--
-- Re-runnable.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. Fee heads: a real management surface
--
-- Through functions rather than the existing table policy, because there are
-- rules worth keeping in one place: two heads called 'Tuition' make the fee grid
-- ambiguous, and a head that has already been billed must never be deleted out
-- from under an invoice line that names it.
-- ---------------------------------------------------------------------------
create or replace function public.fn_upsert_fee_head(
  p_name text,
  p_type public.fee_head_type default 'monthly',
  p_is_recurring boolean default true,
  p_is_refundable boolean default false,
  p_sort_order integer default 0,
  p_id uuid default null
) returns uuid language plpgsql security definer set search_path = public as $$
declare
  v_school uuid := public.current_school_id();
  v_name   text := nullif(btrim(coalesce(p_name, '')), '');
  v_id     uuid;
begin
  if not public.has_role('owner','principal','admin_clerk') then
    raise exception 'Not permitted to change fee heads' using errcode = '42501';
  end if;
  if v_name is null then
    raise exception 'A fee head needs a name';
  end if;
  if p_id is not null then
    perform public.assert_own('fee_heads', p_id);
  end if;

  -- Case-insensitive, because "Tuition" and "tuition" in one grid is a support
  -- call about a duplicate row nobody can tell apart.
  if exists (select 1 from public.fee_heads
              where school_id = v_school
                and lower(btrim(name)) = lower(v_name)
                and (p_id is null or id <> p_id)) then
    raise exception 'This school already has a fee head called %', v_name;
  end if;

  -- A refundable head is money the school HOLDS and must give back (0060), so
  -- it cannot also be a recurring monthly charge — that combination would bill a
  -- deposit every month and report each one as a liability.
  if coalesce(p_is_refundable, false) and coalesce(p_is_recurring, false) then
    raise exception 'A refundable head cannot be recurring: a deposit is taken '
                    'once and given back, not charged every month';
  end if;

  if p_id is null then
    insert into public.fee_heads
      (school_id, name, type, is_recurring, is_refundable, sort_order, active)
    values (v_school, v_name, p_type, coalesce(p_is_recurring, true),
            coalesce(p_is_refundable, false), coalesce(p_sort_order, 0), true)
    returning id into v_id;
  else
    update public.fee_heads
       set name = v_name, type = p_type,
           is_recurring = coalesce(p_is_recurring, true),
           is_refundable = coalesce(p_is_refundable, false),
           sort_order = coalesce(p_sort_order, 0)
     where id = p_id and school_id = v_school
     returning id into v_id;
    if v_id is null then
      raise exception 'That fee head was not found in this school';
    end if;
  end if;

  return v_id;
end;
$$;

create or replace function public.fn_set_fee_head_active(p_id uuid, p_active boolean)
returns void language plpgsql security definer set search_path = public as $$
declare v_school uuid := public.current_school_id(); v_n integer;
begin
  if not public.has_role('owner','principal','admin_clerk') then
    raise exception 'Not permitted to change fee heads' using errcode = '42501';
  end if;
  perform public.assert_own('fee_heads', p_id);

  update public.fee_heads set active = coalesce(p_active, true)
   where id = p_id and school_id = v_school;
  get diagnostics v_n = row_count;
  if v_n = 0 then
    raise exception 'That fee head was not found in this school';
  end if;
end;
$$;

-- Deleting is deliberately NOT offered. An invoice line names its head, so
-- removing one would either break history or silently rewrite what a parent was
-- charged for. Deactivating stops it being billed and keeps every past challan
-- readable — the same choice 0053 made for staff and 0054 for pupils.
drop function if exists public.fn_fee_heads(boolean);
create function public.fn_fee_heads(p_include_inactive boolean default false)
returns table (id uuid, name text, type text, is_recurring boolean,
               is_refundable boolean, sort_order integer, active boolean,
               in_use boolean)
language plpgsql stable security definer set search_path = public as $$
declare v_school uuid := public.current_school_id();
begin
  if not public.may_view('owner','principal','admin_clerk','accountant') then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  return query
  select h.id, h.name, h.type::text, h.is_recurring, h.is_refundable,
         h.sort_order, h.active,
         -- Whether anything already depends on it. The management screen greys
         -- out "delete" reasoning and explains why a head can only be switched
         -- off, rather than offering an action that would fail.
         exists (select 1 from public.fee_structures fs
                  where fs.fee_head_id = h.id and fs.school_id = v_school)
         or exists (select 1 from public.invoice_lines il
                     where il.fee_head_id = h.id and il.school_id = v_school)
    from public.fee_heads h
   where h.school_id = v_school
     and (coalesce(p_include_inactive, false) or h.active)
   order by h.sort_order, h.name;
end;
$$;

-- ---------------------------------------------------------------------------
-- 2. Setting an amount, with the dated history it was designed for
--
-- The grid means "what this class pays now". So this sets the amount effective
-- FROM TODAY and leaves earlier months alone — which is the whole point of
-- effective_from, and what makes a challan re-read for March still say March's
-- price.
--
-- The exception is a fee that has no history yet: there, the row is written at
-- the base date so it also covers a month billed retrospectively. A school
-- setting up in August and back-billing April must not find April empty.
-- ---------------------------------------------------------------------------
create or replace function public.fn_set_fee_amount(
  p_session_id uuid,
  p_class_id uuid,
  p_fee_head_id uuid,
  p_amount numeric,
  -- Explicit date for the scheduled-rise case. Null means "from today".
  p_effective_from date default null
) returns date language plpgsql security definer set search_path = public as $$
declare
  v_school uuid := public.current_school_id();
  v_base   date := '1900-01-01';
  v_when   date;
  v_rows   integer;
  v_dated  integer;
begin
  if not public.has_role('owner','principal','admin_clerk') then
    raise exception 'Not permitted to set fee amounts' using errcode = '42501';
  end if;
  if p_amount is null or p_amount < 0 then
    raise exception 'A fee amount cannot be negative';
  end if;
  perform public.assert_own('academic_sessions', p_session_id);
  perform public.assert_own('classes', p_class_id);
  perform public.assert_own('fee_heads', p_fee_head_id);

  select count(*), count(*) filter (where effective_from > v_base)
    into v_rows, v_dated
    from public.fee_structures
   where school_id = v_school and session_id = p_session_id
     and class_id = p_class_id and fee_head_id = p_fee_head_id;

  v_when := coalesce(
    p_effective_from,
    -- No price on record at all, or only the base one: write the base, so the
    -- amount covers every month including one billed in arrears. Once a dated
    -- change exists, history is in play and a new amount starts today.
    case when v_dated = 0 then v_base else current_date end);

  insert into public.fee_structures
    (school_id, session_id, class_id, fee_head_id, amount, effective_from)
  values (v_school, p_session_id, p_class_id, p_fee_head_id, p_amount, v_when)
  on conflict (session_id, class_id, fee_head_id, effective_from)
    do update set amount = excluded.amount;

  return v_when;
end;
$$;

-- What the grid reads: the amount in force today, plus any change already
-- scheduled. Reading the raw table is what made the grid show an arbitrary row
-- once a school had used the increment tool.
drop function if exists public.fn_fee_structure(uuid, uuid);
create function public.fn_fee_structure(p_session_id uuid, p_class_id uuid)
returns table (fee_head_id uuid, fee_head text, is_recurring boolean,
               amount numeric, effective_from date,
               next_amount numeric, next_from date)
language plpgsql stable security definer set search_path = public as $$
declare v_school uuid := public.current_school_id();
begin
  if not public.may_view('owner','principal','admin_clerk','accountant') then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  perform public.assert_own('academic_sessions', p_session_id);
  perform public.assert_own('classes', p_class_id);

  return query
  select h.id, h.name, h.is_recurring,
         now_row.amount, now_row.effective_from,
         nxt.amount, nxt.effective_from
    from public.fee_heads h
    left join lateral (
      select fs.amount, fs.effective_from
        from public.fee_structures fs
       where fs.school_id = v_school and fs.session_id = p_session_id
         and fs.class_id = p_class_id and fs.fee_head_id = h.id
         and fs.effective_from <= current_date
       order by fs.effective_from desc limit 1
    ) now_row on true
    left join lateral (
      select fs.amount, fs.effective_from
        from public.fee_structures fs
       where fs.school_id = v_school and fs.session_id = p_session_id
         and fs.class_id = p_class_id and fs.fee_head_id = h.id
         and fs.effective_from > current_date
       order by fs.effective_from asc limit 1
    ) nxt on true
   where h.school_id = v_school and h.active
   order by h.sort_order, h.name;
end;
$$;

-- ---------------------------------------------------------------------------
-- 3. The two date-blind billers
--
-- Both now do exactly what fn_generate_class_invoices already did: take the
-- latest price on or before the month being billed. Without this, a school that
-- schedules a rise starts charging every parent the old price PLUS the new one.
-- ---------------------------------------------------------------------------
do $rewrite$
declare
  v_def text;
  -- The date-blind join, and its dated replacement. Written as a programmatic
  -- rewrite rather than a hand-copied function body so the surrounding logic —
  -- discounts, student_fee_items overrides, the invoice header — cannot drift
  -- from whatever the current migration left there.
  v_old_bill text := 'from public.fee_structures fs
  join public.fee_heads fh on fh.id = fs.fee_head_id
  left join public.student_fee_items sfi
    on sfi.enrollment_id = v_enr.id and sfi.fee_head_id = fh.id and sfi.active
  where fs.session_id = v_enr.session_id and fs.class_id = v_enr.class_id
    and fh.is_recurring and fh.active';
  v_new_bill text := 'from public.fee_heads fh
  join lateral (
    select fs.amount
      from public.fee_structures fs
     where fs.school_id = public.current_school_id()
       and fs.session_id = v_enr.session_id and fs.class_id = v_enr.class_id
       and fs.fee_head_id = fh.id
       and fs.effective_from <= coalesce(p_period_month, current_date)
     order by fs.effective_from desc limit 1
  ) fs on true
  left join public.student_fee_items sfi
    on sfi.enrollment_id = v_enr.id and sfi.fee_head_id = fh.id and sfi.active
  where fh.school_id = public.current_school_id() and fh.is_recurring and fh.active';
begin
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'fn_bill_student_month';

  if v_def is not null and strpos(v_def, v_old_bill) > 0 then
    execute replace(v_def, v_old_bill, v_new_bill) || ';';
    raise notice '0066: fn_bill_student_month now honours effective_from';
  end if;
end;
$rewrite$;

do $rewrite2$
declare
  v_def text;
  v_old text := 'from public.fee_structures fs
  join public.fee_heads fh on fh.id = fs.fee_head_id
  left join public.student_fee_items sfi
    on sfi.enrollment_id = v_enr.id and sfi.fee_head_id = fh.id and sfi.active
  where fs.session_id = v_enr.session_id and fs.class_id = v_enr.class_id
    and fh.is_recurring and fh.active';
  -- No date parameter here, and adding one would change the signature every
  -- caller depends on. current_date is the honest reading of "the monthly fee":
  -- what this pupil is charged now.
  v_new text := 'from public.fee_heads fh
  join lateral (
    select fs.amount
      from public.fee_structures fs
     where fs.school_id = public.current_school_id()
       and fs.session_id = v_enr.session_id and fs.class_id = v_enr.class_id
       and fs.fee_head_id = fh.id
       and fs.effective_from <= current_date
     order by fs.effective_from desc limit 1
  ) fs on true
  left join public.student_fee_items sfi
    on sfi.enrollment_id = v_enr.id and sfi.fee_head_id = fh.id and sfi.active
  where fh.school_id = public.current_school_id() and fh.is_recurring and fh.active';
begin
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'fn_student_monthly_fee';

  if v_def is not null and strpos(v_def, v_old) > 0 then
    execute replace(v_def, v_old, v_new) || ';';
    raise notice '0066: fn_student_monthly_fee now honours effective_from';
  end if;
end;
$rewrite2$;

-- ---------------------------------------------------------------------------
-- 4. Grants
-- ---------------------------------------------------------------------------
grant execute on function public.fn_upsert_fee_head(
  text, public.fee_head_type, boolean, boolean, integer, uuid) to authenticated;
grant execute on function public.fn_set_fee_head_active(uuid, boolean) to authenticated;
grant execute on function public.fn_fee_heads(boolean) to authenticated;
grant execute on function public.fn_set_fee_amount(uuid, uuid, uuid, numeric, date) to authenticated;
grant execute on function public.fn_fee_structure(uuid, uuid) to authenticated;

-- ─────────────────────────────────────────────────────────────────────────
-- 0067_live_student_count.sql
-- ─────────────────────────────────────────────────────────────────────────
-- =============================================================================
-- 0067 — A school could outgrow its plan and nobody would ever find out
--
-- subscriptions.student_count is a STORED number, and it drives everything the
-- operator uses to price a school: the console's "N students / limit",
-- limit_state, over_limit_flagged_at, suggested_plan, needs_upgrade, and the
-- licence banner the SCHOOL itself sees.
--
-- Before this migration it was refreshed from exactly two places:
-- fn_activate_subscription (0064) and the manual "Refresh counts" button. No
-- trigger on students, none on enrollments. So the number was whatever it had
-- been the last time a human clicked.
--
-- Proven on a real database — 400 children actually enrolled, Starter plan:
--
--   actually_enrolled | console_shows | plan_allows | flagged_over_limit
--   ------------------+---------------+-------------+--------------------
--                 400 |             0 |         100 | f
--
-- and the school's own licence banner also read 0 of 100, so neither side ever
-- learned. A school on Starter (Rs 9,500) that should be on Institution
-- (Rs 35,000) is Rs 25,500 a year of invisible revenue, per school. It is also
-- what made the owner's console show "0 students" for a school with two.
--
-- 0064 fixed the RENEWAL path — it re-counts before deciding, so it cannot price
-- a school onto a plan it has outgrown. This fixes the DETECTION path, which was
-- the half that tells anybody to act.
--
-- WHY A STATEMENT-LEVEL TRIGGER
--
-- Row-level would call fn_refresh_student_count once per row. That function
-- counts the whole school, updates subscriptions and upserts a snapshot — so
-- importing 400 pupils would do that 400 times, and every one of them takes a
-- row lock on the same subscriptions row, serialising the import against itself.
--
-- REFERENCING NEW TABLE (Postgres 10+) lets one statement see every row it
-- touched, so a 400-row insert refreshes once. The transition table also carries
-- school_id, which is what makes a statement trigger able to scope the work at
-- all — without it a statement-level trigger has no idea which school changed.
--
-- Re-runnable.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. The trigger function
--
-- One function for both tables and all three verbs. Which transition tables
-- exist depends on the verb — an INSERT has no OLD, a DELETE has no NEW — so it
-- branches on TG_OP and refreshes each affected school exactly once.
-- ---------------------------------------------------------------------------
create or replace function public.fn__refresh_counts_touched()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_schools uuid[];
  v_school  uuid;
begin
  -- Branch on TG_OP rather than declaring both transition tables everywhere:
  -- Postgres refuses OLD TABLE on an INSERT trigger and NEW TABLE on a DELETE
  -- one ("OLD TABLE can only be specified for a DELETE or UPDATE trigger"), so
  -- only the pair that exists for this verb may be named. plpgsql plans a
  -- statement the first time it is reached, so the unreachable branches never
  -- try to resolve a table that is not there.
  if tg_op = 'INSERT' then
    select array_agg(distinct school_id) into v_schools
      from touched_new where school_id is not null;
  elsif tg_op = 'DELETE' then
    select array_agg(distinct school_id) into v_schools
      from touched_old where school_id is not null;
  else
    select array_agg(distinct s) into v_schools
      from (select school_id as s from touched_new
            union
            select school_id as s from touched_old) x
     where s is not null;
  end if;

  foreach v_school in array coalesce(v_schools, '{}'::uuid[])
  loop
    -- Guard, not laziness: a school row can exist before its subscription does
    -- (the signup Edge Function creates the school, then the subscription), and
    -- fn_refresh_student_count raises 'No subscription for school %'. A pupil
    -- import must never fail because of a counter.
    if exists (select 1 from public.subscriptions where school_id = v_school) then
      perform public.fn_refresh_student_count(v_school);
    end if;
  end loop;
  return null;
end;
$$;

revoke all on function public.fn__refresh_counts_touched() from public;

-- ---------------------------------------------------------------------------
-- 2. The triggers
--
-- On enrollments AND students, because fn_count_students joins both: an
-- enrolment appearing or its status changing moves the count, and so does a
-- pupil being marked withdrawn or soft-deleted while their enrolment row sits
-- untouched.
--
-- Statement-level AFTER, so a bulk import refreshes once. DEFERRABLE is
-- deliberately NOT used — 0060 learned that a deferred constraint trigger fires
-- at COMMIT, detached from the statement that caused it and impossible to catch.
-- ---------------------------------------------------------------------------
drop trigger if exists trg_enrollments_count_ins on public.enrollments;
create trigger trg_enrollments_count_ins
  after insert on public.enrollments
  referencing new table as touched_new
  for each statement execute function public.fn__refresh_counts_touched();

drop trigger if exists trg_enrollments_count_upd on public.enrollments;
create trigger trg_enrollments_count_upd
  after update on public.enrollments
  referencing new table as touched_new old table as touched_old
  for each statement execute function public.fn__refresh_counts_touched();

drop trigger if exists trg_enrollments_count_del on public.enrollments;
create trigger trg_enrollments_count_del
  after delete on public.enrollments
  referencing old table as touched_old
  for each statement execute function public.fn__refresh_counts_touched();

drop trigger if exists trg_students_count_ins on public.students;
create trigger trg_students_count_ins
  after insert on public.students
  referencing new table as touched_new
  for each statement execute function public.fn__refresh_counts_touched();

drop trigger if exists trg_students_count_upd on public.students;
create trigger trg_students_count_upd
  after update on public.students
  referencing new table as touched_new old table as touched_old
  for each statement execute function public.fn__refresh_counts_touched();

drop trigger if exists trg_students_count_del on public.students;
create trigger trg_students_count_del
  after delete on public.students
  referencing old table as touched_old
  for each statement execute function public.fn__refresh_counts_touched();

-- ---------------------------------------------------------------------------
-- 3. Bring every existing school's count up to date
--
-- Without this, a database that already has the stale number keeps it until
-- somebody edits a pupil. The owner's console showing "0 students / 100" for a
-- school with pupils is exactly that state, and a migration that fixes the
-- mechanism while leaving the wrong number on screen has not fixed the
-- complaint.
-- ---------------------------------------------------------------------------
do $backfill$
declare v_school uuid; v_n integer := 0;
begin
  for v_school in select school_id from public.subscriptions loop
    perform public.fn_refresh_student_count(v_school);
    v_n := v_n + 1;
  end loop;
  raise notice '0067: recounted % school(s)', v_n;
end;
$backfill$;

-- ─────────────────────────────────────────────────────────────────────────
-- Record what this bundle applied (no-op before 0069 creates the ledger)
-- ─────────────────────────────────────────────────────────────────────────
do $ledger$
begin
  if to_regprocedure('public.fn_record_migration(text,text,text)') is null then
    raise notice 'migration ledger not present yet — nothing recorded';
    return;
  end if;
  perform public.fn_record_migration('0057_photos_and_logo.sql', '6_photos_and_records.sql');
  perform public.fn_record_migration('0058_exam_computation.sql', '6_photos_and_records.sql');
  perform public.fn_record_migration('0059_readonly_boundary.sql', '6_photos_and_records.sql');
  perform public.fn_record_migration('0060_refundable_deposits.sql', '6_photos_and_records.sql');
  perform public.fn_record_migration('0061_certificates.sql', '6_photos_and_records.sql');
  perform public.fn_record_migration('0062_staff_checkin.sql', '6_photos_and_records.sql');
  perform public.fn_record_migration('0063_constraint_function_grants.sql', '6_photos_and_records.sql');
  perform public.fn_record_migration('0064_operator_billing.sql', '6_photos_and_records.sql');
  perform public.fn_record_migration('0065_invite_only_provisioning.sql', '6_photos_and_records.sql');
  perform public.fn_record_migration('0066_fee_setup.sql', '6_photos_and_records.sql');
  perform public.fn_record_migration('0067_live_student_count.sql', '6_photos_and_records.sql');
end $ledger$;

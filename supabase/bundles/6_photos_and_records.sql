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
  -- with a leading space on the second line, which is why the match includes it.
  if v_new not like '%STABLE%' then
    v_new := replace(v_new, 'LANGUAGE plpgsql' || chr(10) || ' SECURITY DEFINER',
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

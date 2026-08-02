-- =============================================================================
-- Bulk student import — load a paper register (CSV → JSON array) in one call.
--
-- This is the onboarding workhorse: a new school arrives with hundreds of
-- students on paper/Excel. fn_import_students validates every row, resolves
-- class/section BY NAME (so the operator never deals in UUIDs), de-duplicates on
-- GR / Admission No, and admits the good rows — reusing fn_admit_student so GR
-- numbering stays gapless and each student lands on the roster + is billable.
--
-- It is forgiving by design: one bad row never aborts the batch. Each row comes
-- back with a status (created / skipped / error) and a human message, so the
-- operator fixes the few problem rows and re-imports just those.
--
-- p_dry_run = true validates only (no writes) — the UI runs this first so the
-- operator sees exactly what will happen before committing.
--
-- Recognised row keys (all optional except full_name + class):
--   full_name*, father_name, mother_name, b_form, dob (YYYY-MM-DD), gender
--   (male/female/other), address, phone, whatsapp, gr_no, admission_no,
--   admission_date (YYYY-MM-DD), class* (name), section (name), roll_no,
--   guardian_name, guardian_relation, guardian_phone, guardian_whatsapp
-- =============================================================================

create or replace function public.fn_import_students(
  p_session uuid, p_rows jsonb, p_dry_run boolean default false
) returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_row     jsonb;
  v_idx     int := 0;
  v_created int := 0;
  v_skipped int := 0;
  v_errors  int := 0;
  v_results jsonb := '[]'::jsonb;
  v_class   uuid;
  v_section uuid;
  v_gender  text;
  v_gr      text;
  v_admno   text;
  v_name    text;
  v_cls_in  text;
  v_sec_in  text;
  v_status  text;
  v_msg     text;
  v_admit   jsonb;
  v_cnt     int;
  v_dob     text;
  v_adm     text;
begin
  if not public.has_role('owner','principal','admin_clerk') then
    raise exception 'Not permitted to import students';
  end if;
  if p_session is null then
    raise exception 'A target academic session is required';
  end if;
  if p_rows is null or jsonb_typeof(p_rows) <> 'array' then
    raise exception 'rows must be a JSON array';
  end if;
  if not exists (select 1 from public.academic_sessions where id = p_session) then
    raise exception 'Target session does not exist';
  end if;

  for v_row in select value from jsonb_array_elements(p_rows) as value
  loop
    v_idx    := v_idx + 1;
    v_class  := null;
    v_section:= null;
    v_status := null;
    v_msg    := null;
    v_name   := btrim(coalesce(v_row->>'full_name', ''));
    v_cls_in := btrim(coalesce(v_row->>'class', ''));
    v_sec_in := btrim(coalesce(v_row->>'section', ''));
    v_gender := lower(nullif(btrim(coalesce(v_row->>'gender', '')), ''));
    v_gr     := nullif(btrim(coalesce(v_row->>'gr_no', '')), '');
    v_admno  := nullif(btrim(coalesce(v_row->>'admission_no', '')), '');

    -- 1. required: full name
    if v_name = '' then
      v_status := 'error'; v_msg := 'Full name is required';
    end if;

    -- 2. resolve class by name (case-insensitive, must be active)
    if v_status is null then
      if v_cls_in = '' then
        v_status := 'error'; v_msg := 'Class is required';
      else
        select id into v_class from public.classes
         where active and lower(btrim(name)) = lower(v_cls_in)
         order by level_order limit 1;
        if v_class is null then
          v_status := 'error'; v_msg := 'Unknown class: ' || v_cls_in;
        end if;
      end if;
    end if;

    -- 3. resolve section within the class (only if one was given)
    if v_status is null and v_sec_in <> '' then
      select id into v_section from public.sections
       where class_id = v_class and lower(btrim(name)) = lower(v_sec_in)
       limit 1;
      if v_section is null then
        v_status := 'error';
        v_msg := 'Unknown section "' || v_sec_in || '" for class ' || v_cls_in;
      end if;
    end if;

    -- 4. gender must be a valid enum value if supplied
    if v_status is null and v_gender is not null and v_gender not in ('male','female','other') then
      v_status := 'error'; v_msg := 'Invalid gender (use male/female/other): ' || v_gender;
    end if;

    -- 5. dates must be YYYY-MM-DD if supplied. We insist on ISO rather than just
    --    casting, because Postgres silently mis-parses ambiguous input (e.g.
    --    '12-04-2015' → Dec 4), which would corrupt a date of birth.
    if v_status is null then
      v_dob := nullif(btrim(coalesce(v_row->>'dob', '')), '');
      v_adm := nullif(btrim(coalesce(v_row->>'admission_date', '')), '');
      if (v_dob is not null and v_dob !~ '^\d{4}-\d{2}-\d{2}$')
         or (v_adm is not null and v_adm !~ '^\d{4}-\d{2}-\d{2}$') then
        v_status := 'error'; v_msg := 'Dates must be in YYYY-MM-DD format';
      else
        begin
          perform v_dob::date;
          perform v_adm::date;
        exception when others then
          v_status := 'error'; v_msg := 'Invalid date (use YYYY-MM-DD)';
        end;
      end if;
    end if;

    -- 6. de-duplicate on GR / Admission No so re-running a file is safe
    if v_status is null and v_gr is not null then
      select count(*) into v_cnt from public.students where gr_no = v_gr;
      if v_cnt > 0 then v_status := 'skipped'; v_msg := 'GR ' || v_gr || ' already exists'; end if;
    end if;
    if v_status is null and v_admno is not null then
      select count(*) into v_cnt from public.students where admission_no = v_admno;
      if v_cnt > 0 then v_status := 'skipped'; v_msg := 'Admission No ' || v_admno || ' already exists'; end if;
    end if;

    -- 7. admit (unless this is a dry run or the row already failed/duplicated)
    if v_status is null then
      if p_dry_run then
        v_status := 'ok';
      else
        begin
          v_admit := public.fn_admit_student(
            v_row
            || jsonb_build_object(
                 'session_id', p_session::text,
                 'class_id',   v_class::text,
                 'section_id', v_section::text)
            || case
                 when nullif(btrim(coalesce(v_row->>'guardian_name','')), '') is not null then
                   jsonb_build_object('guardian', jsonb_build_object(
                     'name',     v_row->>'guardian_name',
                     'relation', v_row->>'guardian_relation',
                     'phone',    v_row->>'guardian_phone',
                     'whatsapp', v_row->>'guardian_whatsapp'))
                 else '{}'::jsonb
               end);
          v_status := 'created';
          v_gr := v_admit->>'gr_no';
        exception when others then
          v_status := 'error'; v_msg := SQLERRM;
        end;
      end if;
    end if;

    -- tally (a dry-run 'ok' counts as "would create")
    if    v_status in ('created','ok') then v_created := v_created + 1;
    elsif v_status = 'skipped'         then v_skipped := v_skipped + 1;
    else                                    v_errors  := v_errors  + 1;
    end if;

    v_results := v_results || jsonb_build_object(
      'row', v_idx, 'status', v_status, 'message', v_msg,
      'name', v_name, 'gr_no', v_gr);
  end loop;

  return jsonb_build_object(
    'dry_run', p_dry_run,
    'total',   v_idx,
    'created', v_created,
    'skipped', v_skipped,
    'errors',  v_errors,
    'rows',    v_results);
end;
$$;

grant execute on function public.fn_import_students(uuid, jsonb, boolean) to authenticated;

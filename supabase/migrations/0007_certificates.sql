-- =============================================================================
-- Certificates — issue a leaving / character / bonafide certificate (or ID card)
-- with a gapless per-type serial number. Append-only, like payments: the
-- certificates table has SELECT + INSERT policies only, and this function is the
-- single writer. A reprint reads the frozen `data` snapshot, so it never drifts.
-- =============================================================================

create or replace function public.fn_issue_certificate(
  p_cert_type public.certificate_type, p_student_id uuid, p_data jsonb default '{}'::jsonb
) returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_actor  uuid := auth.uid();
  v_serial bigint;
  v_id     uuid;
  v_snap   jsonb;
begin
  if not public.has_role('owner','principal','admin_clerk') then
    raise exception 'Not permitted to issue certificates';
  end if;

  -- one gapless serial sequence PER certificate type (unique (cert_type, serial_no))
  v_serial := public.next_counter('certificate_' || p_cert_type::text);

  -- snapshot the student's identity + current enrolment so a reprint is stable
  select jsonb_strip_nulls(jsonb_build_object(
      'student_name', s.full_name, 'father_name', s.father_name, 'gr_no', s.gr_no,
      'dob', s.dob, 'gender', s.gender,
      'class_name', c.name, 'section_name', sec.name, 'roll_no', e.roll_no
    ))
    into v_snap
  from public.students s
  left join public.enrollments e
    on e.student_id = s.id
   and e.session_id = (select current_session_id from public.school_settings where id = 1)
  left join public.classes c on c.id = e.class_id
  left join public.sections sec on sec.id = e.section_id
  where s.id = p_student_id;

  insert into public.certificates(cert_type, student_id, serial_no, issued_by, data)
  values (p_cert_type, p_student_id, v_serial, v_actor,
          coalesce(v_snap, '{}'::jsonb) || coalesce(p_data, '{}'::jsonb))
  returning id into v_id;

  return jsonb_build_object('id', v_id, 'serial_no', v_serial, 'cert_type', p_cert_type, 'issued_on', current_date);
end;
$$;

grant execute on function public.fn_issue_certificate(public.certificate_type, uuid, jsonb) to authenticated;

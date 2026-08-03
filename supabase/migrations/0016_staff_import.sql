-- =============================================================================
-- Bulk staff import — the staff-side counterpart of the student importer
-- (0012). A school onboarding types (or exports) its staff list once; this loads
-- it in one call, validated, forgiving one bad row, and de-duplicated on
-- Employee No / CNIC so re-running a file is safe.
--
-- Recognised row keys (only full_name required): full_name, designation,
-- employee_no, mobile, whatsapp, cnic, joined_on (YYYY-MM-DD).
-- =============================================================================

create or replace function public.fn_import_staff(
  p_rows jsonb, p_dry_run boolean default false
) returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_row     jsonb;
  v_idx     int := 0;
  v_created int := 0;
  v_skipped int := 0;
  v_errors  int := 0;
  v_results jsonb := '[]'::jsonb;
  v_name    text;
  v_emp     text;
  v_cnic    text;
  v_joined  text;
  v_status  text;
  v_msg     text;
begin
  if not public.has_role('owner','principal','admin_clerk') then
    raise exception 'Not permitted to import staff';
  end if;
  if p_rows is null or jsonb_typeof(p_rows) <> 'array' then
    raise exception 'rows must be a JSON array';
  end if;

  for v_row in select value from jsonb_array_elements(p_rows) as value
  loop
    v_idx := v_idx + 1;
    v_status := null; v_msg := null;
    v_name   := btrim(coalesce(v_row->>'full_name', ''));
    v_emp    := nullif(btrim(coalesce(v_row->>'employee_no', '')), '');
    v_cnic   := nullif(btrim(coalesce(v_row->>'cnic', '')), '');
    v_joined := nullif(btrim(coalesce(v_row->>'joined_on', '')), '');

    if v_name = '' then
      v_status := 'error'; v_msg := 'Full name is required';
    end if;

    if v_status is null and v_joined is not null then
      if v_joined !~ '^\d{4}-\d{2}-\d{2}$' then
        v_status := 'error'; v_msg := 'Joining date must be YYYY-MM-DD';
      else
        begin perform v_joined::date; exception when others then
          v_status := 'error'; v_msg := 'Invalid joining date'; end;
      end if;
    end if;

    if v_status is null and v_emp is not null
       and exists (select 1 from public.staff where employee_no = v_emp and deleted_at is null) then
      v_status := 'skipped'; v_msg := 'Employee No ' || v_emp || ' already exists';
    end if;
    if v_status is null and v_cnic is not null
       and exists (select 1 from public.staff where cnic = v_cnic and deleted_at is null) then
      v_status := 'skipped'; v_msg := 'CNIC already exists';
    end if;

    if v_status is null then
      if p_dry_run then
        v_status := 'ok';
      else
        begin
          insert into public.staff(full_name, designation, employee_no, mobile, whatsapp, cnic, joined_on)
          values (
            v_name,
            nullif(btrim(coalesce(v_row->>'designation','')), ''),
            v_emp,
            nullif(btrim(coalesce(v_row->>'mobile','')), ''),
            nullif(btrim(coalesce(v_row->>'whatsapp','')), ''),
            v_cnic,
            v_joined::date);
          v_status := 'created';
        exception when others then
          v_status := 'error'; v_msg := SQLERRM;
        end;
      end if;
    end if;

    if    v_status in ('created','ok') then v_created := v_created + 1;
    elsif v_status = 'skipped'         then v_skipped := v_skipped + 1;
    else                                    v_errors  := v_errors  + 1;
    end if;

    v_results := v_results || jsonb_build_object(
      'row', v_idx, 'status', v_status, 'message', v_msg, 'name', v_name);
  end loop;

  return jsonb_build_object(
    'dry_run', p_dry_run, 'total', v_idx,
    'created', v_created, 'skipped', v_skipped, 'errors', v_errors, 'rows', v_results);
end;
$$;

grant execute on function public.fn_import_staff(jsonb, boolean) to authenticated;

-- =============================================================================
-- Opening fee-balance import — the second half of onboarding.
--
-- A school going live mid-year doesn't just need its students loaded (see
-- 0012_import.sql); each student already OWES an arrears balance from before the
-- system existed. Without loading it, Fees would start everyone at zero and the
-- defaulter list would be wrong on day one.
--
-- We model an opening balance the same way the rest of the money system already
-- works (see 0002_fees.sql): a single "issued" invoice carrying one line for the
-- outstanding amount, tagged notes = 'opening_balance'. Because the balance is
-- derived (SUM of non-void invoice charges − verified payments), this flows
-- straight into student_balance(), invoice_balances, fn_defaulters and FIFO
-- payment allocation with no special-casing. period_month is left NULL so the
-- opening balance sorts first ("oldest debt") and is settled before new challans.
--
-- Students are matched by GR No (best), else Admission No, else Name(+Father).
-- Idempotent: a student who already has an opening_balance invoice for the
-- session is skipped, so re-running a file is safe.
--
-- Recognised row keys: gr_no | admission_no | full_name (+ father_name) to
-- identify the student, amount (required, currency/commas tolerated), due_date
-- (optional, YYYY-MM-DD).
-- =============================================================================

create or replace function public.fn_import_opening_balances(
  p_session uuid, p_rows jsonb, p_dry_run boolean default false
) returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_row     jsonb;
  v_idx     int := 0;
  v_created int := 0;
  v_skipped int := 0;
  v_errors  int := 0;
  v_results jsonb := '[]'::jsonb;
  v_gr      text;
  v_adm     text;
  v_name    text;
  v_father  text;
  v_amt_raw text;
  v_amt_cln text;
  v_amount  numeric;
  v_due     text;
  v_due_d   date;
  v_student uuid;
  v_enroll  uuid;
  v_status  text;
  v_msg     text;
  v_label   text;
  v_cnt     int;
  v_inv     uuid;
begin
  if not public.has_role('owner','principal','admin_clerk','accountant') then
    raise exception 'Not permitted to import fee balances';
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
    v_idx     := v_idx + 1;
    v_student := null; v_enroll := null; v_status := null; v_msg := null;
    v_amount  := null; v_due_d := null;
    v_gr      := nullif(btrim(coalesce(v_row->>'gr_no', '')), '');
    v_adm     := nullif(btrim(coalesce(v_row->>'admission_no', '')), '');
    v_name    := nullif(btrim(coalesce(v_row->>'full_name', '')), '');
    v_father  := nullif(btrim(coalesce(v_row->>'father_name', '')), '');
    v_amt_raw := btrim(coalesce(v_row->>'amount', ''));
    v_due     := nullif(btrim(coalesce(v_row->>'due_date', '')), '');
    v_label   := coalesce(v_gr, v_adm, v_name, '(row ' || v_idx || ')');

    -- 1. amount (tolerate "Rs 12,000.00" style input)
    if v_amt_raw = '' then
      v_status := 'skipped'; v_msg := 'No amount given';
    else
      v_amt_cln := regexp_replace(v_amt_raw, '[^0-9.\-]', '', 'g');
      begin
        if v_amt_cln in ('', '-', '.', '-.') then raise exception 'empty'; end if;
        v_amount := v_amt_cln::numeric;
      exception when others then
        v_status := 'error'; v_msg := 'Invalid amount: ' || v_amt_raw;
      end;
    end if;
    if v_status is null and v_amount < 0 then
      v_status := 'error'; v_msg := 'Amount cannot be negative (advances aren''t handled here)';
    end if;
    if v_status is null and v_amount = 0 then
      v_status := 'skipped'; v_msg := 'Zero balance';
    end if;

    -- 2. due date (optional)
    if v_status is null and v_due is not null then
      if v_due !~ '^\d{4}-\d{2}-\d{2}$' then
        v_status := 'error'; v_msg := 'Due date must be YYYY-MM-DD';
      else
        begin v_due_d := v_due::date; exception when others then
          v_status := 'error'; v_msg := 'Invalid due date'; end;
      end if;
    end if;

    -- 3. resolve the student (GR → Admission No → Name)
    if v_status is null then
      if v_gr is not null then
        select id into v_student from public.students where gr_no = v_gr and deleted_at is null;
        if v_student is null then v_status := 'error'; v_msg := 'No student with GR ' || v_gr; end if;
      elsif v_adm is not null then
        select count(*) into v_cnt from public.students where admission_no = v_adm and deleted_at is null;
        if v_cnt = 0 then
          v_status := 'error'; v_msg := 'No student with Admission No ' || v_adm;
        elsif v_cnt > 1 then
          v_status := 'error'; v_msg := 'Admission No ' || v_adm || ' matches several students — use GR No';
        else
          select id into v_student from public.students where admission_no = v_adm and deleted_at is null;
        end if;
      elsif v_name is not null then
        select count(*) into v_cnt from public.students
          where lower(full_name) = lower(v_name)
            and (v_father is null or lower(coalesce(father_name, '')) = lower(v_father))
            and deleted_at is null;
        if v_cnt = 0 then
          v_status := 'error'; v_msg := 'No student named ' || v_name;
        elsif v_cnt > 1 then
          v_status := 'error'; v_msg := 'Name ' || v_name || ' matches several students — use GR No';
        else
          select id into v_student from public.students
            where lower(full_name) = lower(v_name)
              and (v_father is null or lower(coalesce(father_name, '')) = lower(v_father))
              and deleted_at is null;
        end if;
      else
        v_status := 'error'; v_msg := 'No identifier — provide GR No, Admission No, or Name';
      end if;
    end if;

    -- friendlier label once we know who this is
    if v_student is not null then
      v_label := coalesce((select full_name from public.students where id = v_student), v_label);
    end if;

    -- 4. the student must be enrolled in the target session (so the balance shows
    --    up on that session's defaulter list)
    if v_status is null then
      select id into v_enroll from public.enrollments
        where student_id = v_student and session_id = p_session;
      if v_enroll is null then
        v_status := 'error'; v_msg := 'Student is not enrolled in the selected session';
      end if;
    end if;

    -- 5. de-duplicate: one opening balance per student per session
    if v_status is null then
      select count(*) into v_cnt from public.invoices
        where student_id = v_student and session_id = p_session
          and notes = 'opening_balance' and status <> 'void';
      if v_cnt > 0 then v_status := 'skipped'; v_msg := 'Opening balance already imported'; end if;
    end if;

    -- 6. create the opening-balance invoice (unless dry run / rejected / duplicate)
    if v_status is null then
      if p_dry_run then
        v_status := 'ok';
      else
        begin
          insert into public.invoices(
            student_id, enrollment_id, session_id, period_month, status,
            arrears_brought_forward, fine, due_date, notes, issued_at, created_by)
          values (
            v_student, v_enroll, p_session, null, 'issued',
            0, 0, v_due_d, 'opening_balance', now(), auth.uid())
          returning id into v_inv;

          insert into public.invoice_lines(invoice_id, fee_head_id, description, amount, is_discount)
          values (v_inv, null, 'Opening balance (arrears brought forward)', v_amount, false);

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
      'row', v_idx, 'status', v_status, 'message', v_msg,
      'name', v_label, 'gr_no', v_gr, 'amount', v_amount);
  end loop;

  return jsonb_build_object(
    'dry_run', p_dry_run, 'total', v_idx,
    'created', v_created, 'skipped', v_skipped, 'errors', v_errors,
    'rows', v_results);
end;
$$;

grant execute on function public.fn_import_opening_balances(uuid, jsonb, boolean) to authenticated;

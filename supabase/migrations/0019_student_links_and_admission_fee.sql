-- =============================================================================
-- Admissions depth (testing round 1):
--   * Explicit family links (sibling / relative) — replaces the fragile
--     "same father name" heuristic and makes the Sibling discount mean something.
--   * Admission fee captured at admission as a REAL invoice + receipt, so the
--     cash hits the day-book and expected-vs-collected reconciliation. An
--     admission fee that were only a profile flag would be money nobody can
--     reconcile — the exact leak the fee-integrity controls exist to stop.
--
-- fn_admit_student is re-created here (supersedes 0004) with two new optional
-- inputs in its jsonb payload:
--   links:          [ { related_student_id, relation } ]
--   admission_fee:  { charged: bool, amount: numeric|null }
-- =============================================================================

-- --- Family links ----------------------------------------------------------
create table if not exists public.student_links (
  id                 uuid primary key default gen_random_uuid(),
  student_id         uuid not null references public.students(id) on delete cascade,
  related_student_id uuid not null references public.students(id) on delete cascade,
  relation           text,                    -- 'Brother','Sister','Cousin', free text
  created_by         uuid references public.profiles(id),
  created_at         timestamptz not null default now(),
  constraint student_links_distinct check (student_id <> related_student_id),
  unique (student_id, related_student_id)
);
create index if not exists idx_student_links_student on public.student_links (student_id);
create index if not exists idx_student_links_related on public.student_links (related_student_id);

alter table public.student_links enable row level security;
create policy student_links_select on public.student_links for select to authenticated using (true);
create policy student_links_write on public.student_links for all to authenticated
  using (public.has_role('owner','principal','admin_clerk'))
  with check (public.has_role('owner','principal','admin_clerk'));

create trigger trg_audit_student_links after insert or update or delete on public.student_links
  for each row execute function public.audit_trigger();

-- Link two students (idempotent per unordered-ish pair; one row, queried both
-- directions). Any admin role may link; it is not a money action.
create or replace function public.fn_link_students(p_a uuid, p_b uuid, p_relation text)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_id uuid;
begin
  if not public.has_role('owner','principal','admin_clerk') then
    raise exception 'Not permitted to link students';
  end if;
  if p_a is null or p_b is null then raise exception 'Both students are required'; end if;
  if p_a = p_b then raise exception 'Cannot link a student to themselves'; end if;
  -- Both sides, or a sibling discount could be justified by a student who
  -- belongs to a different school entirely.
  perform public.assert_own('students', p_a);
  perform public.assert_own('students', p_b);
  insert into public.student_links(student_id, related_student_id, relation, created_by)
  values (p_a, p_b, nullif(btrim(p_relation),''), auth.uid())
  on conflict (student_id, related_student_id) do update set relation = excluded.relation
  returning id into v_id;
  return v_id;
end;
$$;

-- --- Admit student (supersedes 0004): + family links + admission fee --------
create or replace function public.fn_admit_student(p jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_actor   uuid := auth.uid();
  v_prefix  text;
  v_counter bigint;
  v_gr      text;
  v_student uuid;
  v_enroll  uuid;
  v_session uuid := nullif(p->>'session_id','')::uuid;
  v_class   uuid := nullif(p->>'class_id','')::uuid;
  v_section uuid := nullif(p->>'section_id','')::uuid;
  v_roll    text := nullif(p->>'roll_no','');
  v_gr_in   text := nullif(p->>'gr_no','');
  v_next    int;
  v_g       jsonb := p->'guardian';
  v_link    jsonb;
  v_af      jsonb := p->'admission_fee';
  v_af_amt  numeric := 0;
  v_af_head uuid;
  v_af_inv  uuid;
  v_af_pay  uuid;
  v_receipt bigint;
  v_af_receipt bigint := null;
  v_af_recorded numeric := null;
begin
  if not public.has_role('owner','principal','admin_clerk') then
    raise exception 'Not permitted to admit students';
  end if;
  if nullif(p->>'full_name','') is null then raise exception 'Student name is required'; end if;
  if v_session is null then raise exception 'Academic session is required'; end if;
  if v_class   is null then raise exception 'Class is required'; end if;

  -- The ids arrive inside the jsonb payload, so they need checking just like a
  -- named uuid parameter would.
  perform public.assert_own('academic_sessions', v_session);
  perform public.assert_own('classes', v_class);
  perform public.assert_own('sections', v_section);

  if v_gr_in is not null then
    v_gr := v_gr_in;
  else
    select gr_prefix into v_prefix from public.school_settings where school_id = public.current_school_id();
    v_counter := public.next_counter('gr');
    v_gr := coalesce(v_prefix, '') || lpad(v_counter::text, 4, '0');
  end if;

  insert into public.students(
    gr_no, admission_no, full_name, father_name, mother_name, b_form, dob, gender,
    address, phone, whatsapp, status, admission_date, notes)
  values (
    v_gr,
    nullif(p->>'admission_no',''),
    p->>'full_name',
    nullif(p->>'father_name',''),
    nullif(p->>'mother_name',''),
    nullif(p->>'b_form',''),
    nullif(p->>'dob','')::date,
    nullif(p->>'gender','')::public.gender,
    nullif(p->>'address',''),
    nullif(p->>'phone',''),
    nullif(p->>'whatsapp',''),
    'active',
    coalesce(nullif(p->>'admission_date','')::date, current_date),
    nullif(p->>'notes',''))
  returning id into v_student;

  if v_roll is null then
    select coalesce(max(nullif(regexp_replace(coalesce(roll_no,''), '[^0-9]', '', 'g'), '')::int), 0) + 1
    into v_next
    from public.enrollments
    where session_id = v_session and class_id = v_class and section_id is not distinct from v_section;
    v_roll := v_next::text;
  end if;

  insert into public.enrollments(student_id, session_id, class_id, section_id, roll_no, status)
  values (v_student, v_session, v_class, v_section, v_roll, 'active')
  returning id into v_enroll;

  -- optional primary guardian (kept for callers that still send one; the web
  -- admission form now relies on father/mother + the student contact number)
  if v_g is not null and jsonb_typeof(v_g) = 'object' and nullif(v_g->>'name','') is not null then
    insert into public.guardians(student_id, name, relation, phone, whatsapp, is_primary)
    values (v_student, v_g->>'name', nullif(v_g->>'relation',''), nullif(v_g->>'phone',''),
            nullif(v_g->>'whatsapp',''), true);
  end if;

  -- optional family links (sibling / relative already in the school)
  if p->'links' is not null and jsonb_typeof(p->'links') = 'array' then
    for v_link in select * from jsonb_array_elements(p->'links') loop
      if nullif(v_link->>'related_student_id','') is not null
         and nullif(v_link->>'related_student_id','')::uuid <> v_student then
        insert into public.student_links(student_id, related_student_id, relation, created_by)
        values (v_student, nullif(v_link->>'related_student_id','')::uuid,
                nullif(v_link->>'relation',''), v_actor)
        on conflict (student_id, related_student_id) do nothing;
      end if;
    end loop;
  end if;

  -- optional admission fee → a real one-off invoice (+ receipt when an amount
  -- is given). period_month is null so it never appears in the monthly list.
  if v_af is not null and jsonb_typeof(v_af) = 'object' and (v_af->>'charged')::boolean is true then
    v_af_amt := coalesce(nullif(v_af->>'amount','')::numeric, 0);
    if v_af_amt < 0 then raise exception 'Admission fee cannot be negative'; end if;

    select id into v_af_head from public.fee_heads where type = 'admission' and active
      order by sort_order limit 1;
    if v_af_head is null then
      insert into public.fee_heads(name, type, is_recurring, sort_order)
      values ('Admission Fee', 'admission', false, 20) returning id into v_af_head;
    end if;

    insert into public.invoices(student_id, enrollment_id, session_id, period_month, status,
        arrears_brought_forward, due_date, issued_at, created_by, notes)
    values (v_student, v_enroll, v_session, null, 'issued', 0, current_date, now(), v_actor, 'Admission fee')
    returning id into v_af_inv;

    insert into public.invoice_lines(invoice_id, fee_head_id, description, amount, is_discount)
    values (v_af_inv, v_af_head, 'Admission Fee', v_af_amt, false);

    if v_af_amt > 0 then
      v_af_receipt := public.next_counter('receipt');
      insert into public.payments(student_id, amount, method, receipt_no, status, received_by, note)
      values (v_student, v_af_amt, 'cash', v_af_receipt, 'verified', v_actor, 'Admission fee')
      returning id into v_af_pay;
      insert into public.payment_allocations(payment_id, invoice_id, amount)
      values (v_af_pay, v_af_inv, v_af_amt);
      v_af_recorded := v_af_amt;
    end if;
    -- either way, nothing is left owing for the admission fee line
    update public.invoices set status = 'paid' where id = v_af_inv;
  end if;

  return jsonb_build_object(
    'student_id', v_student, 'enrollment_id', v_enroll, 'gr_no', v_gr, 'roll_no', v_roll,
    'admission_fee_amount', v_af_recorded, 'admission_receipt_no', v_af_receipt);
end;
$$;

grant execute on function public.fn_link_students(uuid, uuid, text) to authenticated;
grant execute on function public.fn_admit_student(jsonb) to authenticated;

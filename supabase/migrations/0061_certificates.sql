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

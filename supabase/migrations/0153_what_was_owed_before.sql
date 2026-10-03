-- =============================================================================
-- 0153. What was owed before.
--
-- A school moving onto this software brings children who already owe money:
-- months of fee, an admission fee never paid, a stationery bill, a picnic. The
-- paper register has it and the software had no way to take it in. Rapid entry
-- read the request end to end, the screens and every function behind them, and
-- these are the faults this migration closes.
--
--  1. ONLY ONE KIND OF DUE, AND ONLY THIS YEAR'S. Rapid entry took "owed for a
--     month" and nothing else, and only for a finished month of the current
--     school year. A school joining in its first month (the usual moment to
--     switch) could record nothing at all, every due from last year was
--     refused, and an unpaid admission fee, stationery, books, uniform,
--     transport, exam fee or anything with a name of its own had nowhere to go.
--     fn__record_dues takes all of them: a month up to three years back, or a
--     named due. One bad line is refused on its own and the rest are kept.
--
--  2. NO WAY TO ADD A DUE TO A CHILD ALREADY IN THE SOFTWARE. fn_record_dues
--     does it from the child's page, and fn_student_dues lists what was
--     entered, so a due the month strip cannot show is still on screen.
--
--  3. "ALREADY COLLECTED THIS MONTH" PAID THE OLDEST DUE. The payment was
--     recorded after the arrears, and allocation pays the oldest invoice first,
--     so August was marked paid and this month stayed on the unpaid list.
--     This month is now billed and paid BEFORE any due is entered. A part
--     payment can be recorded, and a class with no fee set says so instead of
--     quietly recording nothing.
--
--  4. ONE BAD MONTH CANCELLED THEM ALL, AND A RETRIED SAVE ADMITTED EVERYONE
--     TWICE. Each due now has its own savepoint and its own message. A save
--     carries a request id; the same id twice returns the first answer, so a
--     lost response on a weak connection cannot create a second set of
--     children who could then never be deleted. A misspelt key in a row is
--     refused instead of being dropped with the money in it.
--
--  5. A DISCOUNT SILENTLY CUT A TYPED DUE. The billing run and the repricer
--     both added discount lines to the arrears invoices. A due is a figure off
--     the school's own paper and is now left as typed: invoices carry
--     carried_kind, and neither writer touches a row that has one.
--
--  6. A SECOND CHALLAN FOR THE SAME MONTH. fn_bill_student_month did not round
--     its month, so the 15th and the 1st were two months to the unique index.
--
--  7. "opening_balance" PRINTED AS THE MONTH. Every reader that labels a charge
--     with no month printed the raw marker from notes. They now print the
--     due's own name, or "Opening balance", and the counter and the parent
--     portal, which printed "Other charges" for all of them, get the name too.
--     Fees, Arrears counts named dues, and a holiday month can still be skipped
--     when the only charges in it are dues typed in by hand.
--
-- The CSV import of opening balances (fn_import_opening_balances) is not
-- touched. Nothing here writes notes = 'opening_balance', so the importer's
-- own duplicate check is unchanged.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. What kind of due an invoice is, and what it is called.
--
-- carried_kind is set on a charge the school TYPED IN from its own records,
-- never on one this software billed. It is the marker every writer below
-- checks before it changes a charge, so it is a column and not a word in
-- notes: fn_apply_fine, fn_waive_fine and fn_defer_invoice all append to notes,
-- which is how the opening-balance marker stopped matching itself.
-- ---------------------------------------------------------------------------
alter table public.invoices add column if not exists carried_kind text;
alter table public.invoices add column if not exists label text;

-- The months 0142 entered at onboarding are the same thing, and need the same
-- protection from the discount writers.
update public.invoices
   set carried_kind = 'month'
 where carried_kind is null
   and period_month is not null
   and split_part(coalesce(notes, ''), E'\n', 1) = 'rde_arrears';

do $c$
begin
  if not exists (select 1 from pg_constraint
                  where conrelid = 'public.invoices'::regclass
                    and conname = 'invoices_carried_kind_chk') then
    alter table public.invoices add constraint invoices_carried_kind_chk
      check (carried_kind is null or carried_kind in (
        'month', 'admission', 'annual', 'exam', 'transport',
        'stationery', 'books', 'uniform', 'other'));
  end if;
  -- A month due has its month, and a named due has none. A named due with a
  -- month would collide with that month's challan on uq_invoice_enroll_month.
  if not exists (select 1 from pg_constraint
                  where conrelid = 'public.invoices'::regclass
                    and conname = 'invoices_carried_shape_chk') then
    alter table public.invoices add constraint invoices_carried_shape_chk
      check (carried_kind is null
             or ((carried_kind = 'month') = (period_month is not null)));
  end if;
  if not exists (select 1 from pg_constraint
                  where conrelid = 'public.invoices'::regclass
                    and conname = 'invoices_label_len_chk') then
    alter table public.invoices add constraint invoices_label_len_chk
      check (label is null or char_length(label) between 1 and 80);
  end if;
end
$c$;

-- ---------------------------------------------------------------------------
-- 2. A save that is answered once.
--
-- Rapid entry admits a class in one call. If the answer is lost on the way
-- back (a phone on a weak signal), the clerk presses Save again and every
-- child is admitted a second time, with a second set of dues. A child with
-- invoices can never be deleted, so the duplicates are permanent. The browser
-- now sends a request id with each save and keeps it for a retry of the same
-- rows; the second arrival returns the first answer.
--
-- Read and written only inside fn_rde_add_students. RLS on and no policy, so a
-- browser cannot read or write it at all.
-- ---------------------------------------------------------------------------
create table if not exists public.rde_saves (
  id          uuid primary key default gen_random_uuid(),
  school_id   uuid not null references public.schools(id) on delete cascade,
  request_id  uuid not null,
  result      jsonb not null default '{}'::jsonb,
  created_by  uuid default auth.uid(),
  created_at  timestamptz not null default now()
);
create unique index if not exists uq_rde_saves_request
  on public.rde_saves (school_id, request_id);
alter table public.rde_saves enable row level security;
revoke all on public.rde_saves from anon, authenticated;
drop trigger if exists trg_rde_saves_school on public.rde_saves;
create trigger trg_rde_saves_school before insert or update on public.rde_saves
  for each row execute function public.enforce_school_id();

-- ---------------------------------------------------------------------------
-- 3. What to call a charge that has no month.
--
-- Every reader below used coalesce(notes, 'One-off'), and notes is a machine
-- marker that other functions append to. The due's own name comes first, then
-- the known markers in words, then the first line of whatever note there is.
-- ---------------------------------------------------------------------------
create or replace function public.fn__one_off_label(p_label text, p_notes text)
returns text
language sql
immutable
set search_path = public
as $$
  select coalesce(
    nullif(btrim(p_label), ''),
    case split_part(coalesce(p_notes, ''), E'\n', 1)
      when '' then null
      when 'opening_balance' then 'Opening balance'
      when 'rde_arrears' then 'Earlier fees'
      else nullif(btrim(split_part(p_notes, E'\n', 1)), '')
    end,
    'Other charge');
$$;
revoke all on function public.fn__one_off_label(text, text) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 4. The writer. One child, one list of dues, one answer per line.
--
-- A due is an INVOICE with one line, never an adjustment: payments are only
-- ever allocated to invoices, so an adjustment can be owed but never paid.
--
--   {kind: 'month', month: '2026-02', amount: 3000}
--       The monthly fee for a month that has FINISHED, up to three years back.
--       Not this month: this month is billed by the software and a second
--       charge for it would be a double bill. The month goes on the enrolment
--       of the school year it belongs to when the child has one, otherwise on
--       the given one, and is refused if the child already has any charge for
--       that month on any enrolment (uq_invoice_enroll_month is per enrolment
--       and would not see the other year's).
--
--   {kind: 'stationery' | 'books' | 'uniform' | 'admission' | 'annual' |
--          'exam' | 'transport' | 'other', label: 'Picnic', amount: 800}
--       A named due with no month. 'other' must be named; the rest are named
--       after their kind unless a name is given. The same name and amount
--       twice is taken as a retry and not added again.
--
-- Amounts may be typed the way people type them: "Rs 5,000" is 5000.
--
-- Not granted to anybody. fn_record_dues and fn_rde_add_students check the
-- caller's role and the child's school before they call it.
-- ---------------------------------------------------------------------------
create or replace function public.fn__record_dues(
  p_student_id uuid, p_enrollment_id uuid, p_dues jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
set timezone to 'Asia/Karachi'
as $$
declare
  v_school  uuid := public.current_school_id();
  v_this    date := public.fn__karachi_month();
  v_today   date := (now() at time zone 'Asia/Karachi')::date;
  v_floor   date;
  v_enr     record;
  v_tgt     record;
  v_item    jsonb;
  v_i       integer := 0;
  v_kind    text;
  v_raw     text;
  v_month   date;
  v_amt     numeric;
  v_label   text;
  v_inv     uuid;
  v_have    numeric;
  v_seen    date[] := '{}';
  v_status  text;
  v_msg     text;
  v_items   jsonb := '[]'::jsonb;
  v_n       integer := 0;
  v_months  integer := 0;
  v_total   numeric := 0;
begin
  if v_school is null then
    raise exception 'No school context for this user' using errcode = '42501';
  end if;
  if p_dues is null or jsonb_typeof(p_dues) = 'null' then
    return jsonb_build_object('recorded', 0, 'months', 0, 'total', 0,
                              'items', '[]'::jsonb);
  end if;
  if jsonb_typeof(p_dues) <> 'array' then
    raise exception 'Dues must be sent as a list.' using errcode = '22023';
  end if;
  if jsonb_array_length(p_dues) > 120 then
    raise exception 'Record at most 120 dues for one child at a time.'
      using errcode = '54000';
  end if;
  perform public.fn__only_these_keys(p_dues, '{kind,month,amount,label}'::text[], 'A due');

  select e.id, e.student_id, e.session_id into v_enr
    from public.enrollments e
   where e.id = p_enrollment_id and e.school_id = v_school;
  if not found or v_enr.student_id is distinct from p_student_id then
    raise exception 'That enrolment is not this child''s in this school.'
      using errcode = '42501';
  end if;

  v_floor := (v_this - interval '36 months')::date;

  for v_item in select value from jsonb_array_elements(p_dues) loop
    v_i      := v_i + 1;
    v_kind   := lower(btrim(coalesce(v_item->>'kind', '')));
    v_month  := null;
    v_label  := null;
    v_amt    := null;
    v_inv    := null;
    v_status := 'recorded';
    v_msg    := null;

    begin  -- each due is its own savepoint: one bad line costs only itself
      v_raw := regexp_replace(lower(btrim(coalesce(v_item->>'amount', ''))),
                              '(pkr|rs\.?|,|\s)', '', 'g');
      if v_raw = '' then
        v_status := 'refused';
        v_msg := 'A due with no amount was left out.';
      elsif v_raw !~ '^[0-9]+(\.[0-9]{1,2})?$' then
        v_status := 'refused';
        v_msg := format('"%s" is not an amount, so that due was left out.',
                        v_item->>'amount');
      elsif v_raw::numeric <= 0 then
        v_status := 'refused';
        v_msg := 'A due of Rs 0 was left out.';
      elsif v_raw::numeric > 10000000 then
        v_status := 'refused';
        v_msg := format('Rs %s is more than one due can be. Check the amount.',
                        to_char(v_raw::numeric, 'FM999,999,999,990'));
      else
        v_amt := v_raw::numeric;
      end if;

      if v_status = 'recorded' and v_kind = 'month' then
        v_raw := btrim(coalesce(v_item->>'month', ''));
        if v_raw !~ '^[0-9]{4}-(0[1-9]|1[0-2])(-[0-9]{2})?$' then
          v_status := 'refused';
          v_msg := format('Rs %s was given no month it was owed for, so it was left out.',
                          to_char(v_amt, 'FM999,999,990'));
        else
          v_month := to_date(left(v_raw, 7) || '-01', 'YYYY-MM-DD');
          if v_month >= v_this then
            -- "has not" is what rapid_data_entry.sql 17 reads for.
            v_status := 'refused';
            v_msg := format('%s has not finished yet. This month is billed by the '
                            'software itself, so a due for it would be charged twice.',
                            to_char(v_month, 'Mon YYYY'));
          elsif v_month < v_floor then
            v_status := 'refused';
            v_msg := format('%s is more than three years ago. Enter older money as '
                            'one named due, for example "Dues for %s".',
                            to_char(v_month, 'Mon YYYY'), to_char(v_month, 'YYYY'));
          elsif v_month = any(v_seen) then
            v_status := 'skipped';
            v_msg := format('%s was listed twice. The first amount was kept.',
                            to_char(v_month, 'Mon YYYY'));
          else
            v_seen := v_seen || v_month;
            if exists (select 1 from public.invoices i
                        where i.school_id = v_school and i.student_id = p_student_id
                          and i.period_month = v_month and i.status <> 'void') then
              select coalesce(sum(b.charge), 0) into v_have
                from public.invoice_balances b
                join public.invoices i on i.id = b.invoice_id
               where i.school_id = v_school and i.student_id = p_student_id
                 and i.period_month = v_month and i.status <> 'void';
              v_status := 'skipped';
              v_msg := format('%s already has a charge of Rs %s on this child''s account, '
                              'so it was left alone. To change it, cancel that charge first.',
                              to_char(v_month, 'Mon YYYY'),
                              to_char(v_have, 'FM999,999,990'));
            else
              -- The year this month belongs to, when the child was in it.
              select e.id, e.session_id into v_tgt
                from public.enrollments e
                join public.academic_sessions s on s.id = e.session_id
               where e.student_id = p_student_id and e.school_id = v_school
                 and s.starts_on is not null and s.ends_on is not null
                 and v_month >= date_trunc('month', s.starts_on)::date
                 and v_month <= s.ends_on
               order by s.starts_on desc
               limit 1;
              if not found then
                select v_enr.id, v_enr.session_id into v_tgt;
              end if;

              -- Dated at the month it was owed for, so the statement reads in
              -- order and an as-at balance sheet for that month includes it.
              insert into public.invoices(student_id, enrollment_id, session_id,
                  period_month, status, arrears_brought_forward, fine, due_date,
                  issued_at, created_by, carried_kind)
              values (p_student_id, v_tgt.id, v_tgt.session_id,
                  v_month, 'issued', 0, 0,
                  (v_month + interval '1 month' - interval '1 day')::date,
                  v_month::timestamp at time zone 'Asia/Karachi', auth.uid(), 'month')
              returning id into v_inv;
              insert into public.invoice_lines(invoice_id, fee_head_id, description,
                                               amount, is_discount)
              values (v_inv, null, 'Monthly fee', v_amt, false);
            end if;
          end if;
        end if;

      elsif v_status = 'recorded'
            and v_kind in ('admission', 'annual', 'exam', 'transport',
                           'stationery', 'books', 'uniform', 'other') then
        v_label := nullif(btrim(regexp_replace(
                     regexp_replace(coalesce(v_item->>'label', ''), '[[:cntrl:]]', ' ', 'g'),
                     '\s+', ' ', 'g')), '');
        if v_label is null then
          v_label := case v_kind
                       when 'admission'  then 'Admission fee'
                       when 'annual'     then 'Annual charges'
                       when 'exam'       then 'Exam fee'
                       when 'transport'  then 'Transport'
                       when 'stationery' then 'Stationery'
                       when 'books'      then 'Books'
                       when 'uniform'    then 'Uniform'
                     end;
        end if;
        if v_label is null then
          v_status := 'refused';
          v_msg := format('A due of Rs %s has no name, so it was left out. '
                          'Say what it is for, for example Picnic or Lab charges.',
                          to_char(v_amt, 'FM999,999,990'));
        elsif char_length(v_label) > 80 then
          v_status := 'refused';
          v_msg := 'The name of a due can be at most 80 letters.';
        elsif exists (
                select 1 from public.invoices i
                  join public.invoice_lines l on l.invoice_id = i.id and not l.is_discount
                 where i.school_id = v_school and i.student_id = p_student_id
                   and i.status <> 'void' and i.period_month is null
                   and i.carried_kind = v_kind
                   and lower(i.label) = lower(v_label)
                   and l.amount = v_amt) then
          v_status := 'skipped';
          v_msg := format('%s of Rs %s is already on this child''s account, '
                          'so it was not added twice.',
                          v_label, to_char(v_amt, 'FM999,999,990'));
        else
          insert into public.invoices(student_id, enrollment_id, session_id,
              period_month, status, arrears_brought_forward, fine, due_date,
              issued_at, created_by, carried_kind, label)
          values (p_student_id, v_enr.id, v_enr.session_id,
              null, 'issued', 0, 0, v_today, now(), auth.uid(), v_kind, v_label)
          returning id into v_inv;
          insert into public.invoice_lines(invoice_id, fee_head_id, description,
                                           amount, is_discount)
          values (v_inv, null, v_label, v_amt, false);
        end if;

      elsif v_status = 'recorded' then
        v_status := 'refused';
        v_msg := case when v_kind = ''
                      then 'A due with no kind was left out.'
                      else format('"%s" is not a kind of due, so it was left out.', v_kind)
                 end;
      end if;

    exception when others then
      v_status := 'refused';
      v_inv    := null;
      v_msg    := 'A due could not be recorded: ' || sqlerrm;
    end;

    if v_status = 'recorded' then
      v_n := v_n + 1;
      v_total := v_total + v_amt;
      if v_kind = 'month' then v_months := v_months + 1; end if;
    end if;
    v_items := v_items || jsonb_build_array(jsonb_build_object(
      'i', v_i, 'kind', nullif(v_kind, ''), 'month', v_month, 'label', v_label,
      'amount', v_amt, 'status', v_status, 'message', v_msg, 'invoice_id', v_inv));
  end loop;

  -- Money typed in by hand is the one charge with no billing run behind it, so
  -- who typed it and what is the record.
  if v_n > 0 then
    insert into public.audit_log(school_id, actor, actor_role, action, entity,
                                 entity_id, before, after, reason)
    values (v_school, auth.uid(),
            (select role from public.profiles where id = auth.uid()),
            'DUES_RECORDED', 'students', p_student_id::text, null,
            jsonb_build_object('recorded', v_n, 'total', v_total,
              'items', (select coalesce(jsonb_agg(x), '[]'::jsonb)
                          from jsonb_array_elements(v_items) x
                         where x->>'status' = 'recorded')),
            null);
  end if;

  return jsonb_build_object('recorded', v_n, 'months', v_months,
                            'total', v_total, 'items', v_items);
end;
$$;
revoke all on function public.fn__record_dues(uuid, uuid, jsonb) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 5. Dues for a child who is already in the software.
--
-- The school's paper says what a child owed before; the child was entered
-- without it. Recorded on the enrolment of the current year, or the child's
-- latest one if they are not in the current year.
-- ---------------------------------------------------------------------------
create or replace function public.fn_record_dues(p_student_id uuid, p_dues jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
set timezone to 'Asia/Karachi'
as $$
declare
  v_school uuid := public.current_school_id();
  v_enr    uuid;
begin
  if not public.has_role('owner', 'principal') then
    raise exception 'Not permitted to record dues' using errcode = '42501';
  end if;
  if p_student_id is null then
    raise exception 'Pick a child first.' using errcode = '22023';
  end if;
  perform public.assert_own('students', p_student_id);
  if exists (select 1 from public.students
              where id = p_student_id and school_id = v_school
                and deleted_at is not null) then
    raise exception 'This child has been deleted, so no dues can be added.'
      using errcode = '22023';
  end if;

  select e.id into v_enr
    from public.enrollments e
    join public.academic_sessions s on s.id = e.session_id
   where e.student_id = p_student_id and e.school_id = v_school
   order by s.is_current desc, s.starts_on desc nulls last, e.created_at desc
   limit 1;
  if v_enr is null then
    raise exception 'This child is not in any class yet, so there is no account '
      'to put the dues on. Put them in a class first.' using errcode = '22023';
  end if;

  return public.fn__record_dues(p_student_id, v_enr, p_dues);
end;
$$;
revoke all on function public.fn_record_dues(uuid, jsonb) from public, anon;
grant execute on function public.fn_record_dues(uuid, jsonb) to authenticated;

-- ---------------------------------------------------------------------------
-- 6. The dues a child's month strip cannot show.
--
-- The strip on the child's page has a row per month of this year from the
-- admission month on. A due typed in from paper is usually before that (the
-- child was admitted today, the debt is from August), or has no month at all.
-- This lists every due typed in by hand, and every other charge with no month
-- (an imported opening balance, an admission fee) except a refundable
-- deposit, which has its own line on the page.
-- ---------------------------------------------------------------------------
create or replace function public.fn_student_dues(p_student_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_school uuid := public.current_school_id();
  v_rows   jsonb;
begin
  if not public.may_view('owner', 'principal', 'readonly') then
    raise exception 'Not permitted to view fee records' using errcode = '42501';
  end if;
  perform public.assert_own('students', p_student_id);

  select coalesce(jsonb_agg(jsonb_build_object(
           'invoice_id',   i.id,
           'kind',         coalesce(i.carried_kind,
                             case when split_part(coalesce(i.notes, ''), E'\n', 1) = 'opening_balance'
                                  then 'opening' else 'one_off' end),
           'carried',      i.carried_kind is not null,
           'label',        case when i.period_month is null
                                then public.fn__one_off_label(i.label, i.notes) end,
           'period_month', i.period_month,
           'due_date',     i.due_date,
           'voucher_code', i.voucher_code,
           'charge',       b.charge,
           'paid',         b.allocated,
           'outstanding',  greatest(b.charge - b.allocated, 0),
           'status',       i.status,
           'entered_on',   i.created_at,
           'entered_by',   pr.full_name)
         order by i.period_month nulls last, i.created_at), '[]'::jsonb)
    into v_rows
    from public.invoices i
    join public.invoice_balances b on b.invoice_id = i.id
    left join public.profiles pr on pr.id = i.created_by
   where i.school_id = v_school
     and i.student_id = p_student_id
     and i.status <> 'void'
     and (i.carried_kind is not null
          or (i.period_month is null
              and not exists (
                    select 1 from public.invoice_lines l
                      join public.fee_heads fh on fh.id = l.fee_head_id
                     where l.invoice_id = i.id and fh.is_refundable)));

  return jsonb_build_object(
    'dues', v_rows,
    'outstanding', coalesce((select sum((x->>'outstanding')::numeric)
                               from jsonb_array_elements(v_rows) x), 0));
end;
$$;
revoke all on function public.fn_student_dues(uuid) from public, anon;
grant execute on function public.fn_student_dues(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 7. 0142's month writer, kept as a door into the one writer above so there
-- are not two sets of rules. Nothing calls it now; it is not granted.
-- ---------------------------------------------------------------------------
create or replace function public.fn__rde_arrears(p_enrollment_id uuid, p_months jsonb)
returns integer
language plpgsql
security definer
set search_path = public
set timezone to 'Asia/Karachi'
as $$
declare
  v_student uuid;
begin
  if p_months is null or jsonb_typeof(p_months) <> 'array' then return 0; end if;
  select e.student_id into v_student
    from public.enrollments e
   where e.id = p_enrollment_id and e.school_id = public.current_school_id();
  if not found then raise exception 'Enrolment not found'; end if;
  return coalesce((public.fn__record_dues(v_student, p_enrollment_id,
           (select coalesce(jsonb_agg(jsonb_build_object(
                      'kind', 'month', 'month', a->>'month', 'amount', a->'amount')),
                    '[]'::jsonb)
              from jsonb_array_elements(p_months) a))->>'months')::integer, 0);
end;
$$;
revoke all on function public.fn__rde_arrears(uuid, jsonb) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 8. Rapid entry, in the right order.
--
-- What changed from 0142, and why:
--
--   * THIS MONTH IS BILLED AND PAID FIRST. A payment is allocated to the
--     child's oldest open charge, so recording "already collected" after the
--     dues paid August and left October unpaid. Done first, the only charge
--     the new child has is this month's, which is where the money belongs.
--     paid_amount records a part payment; more than the fee records the fee
--     and says so; a class with no fee set yet says that, instead of
--     recording nothing in silence and billing the month in full later.
--
--   * DUES OF EVERY KIND, through fn__record_dues: 'dues' is the list, and the
--     old 'arrears' list of {month, amount} is still read, as month dues, so a
--     browser that has not reloaded keeps working. Each due is answered on its
--     own and the row's message says which were left out and why.
--
--   * A REQUEST ID. The same id twice returns the first answer (see rde_saves).
--
--   * AN UNKNOWN KEY IS REFUSED. A row key this function does not read used to
--     be dropped with whatever was in it.
-- ---------------------------------------------------------------------------
create or replace function public.fn_rde_add_students(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
set timezone to 'Asia/Karachi'
as $$
declare
  v_session uuid := nullif(p->>'session_id','')::uuid;
  v_class   uuid := nullif(p->>'class_id','')::uuid;
  v_section uuid := nullif(p->>'section_id','')::uuid;
  v_request uuid := nullif(p->>'request_id','')::uuid;
  v_rows    jsonb := coalesce(p->'rows', '[]'::jsonb);
  v_school  uuid := public.current_school_id();
  v_row     jsonb;
  v_idx     int := 0;
  v_res     jsonb;
  v_out     jsonb := '[]'::jsonb;
  v_created int := 0;
  v_failed  int := 0;
  v_drafts  int := 0;
  v_student uuid;
  v_enroll  uuid;
  v_sib     uuid;
  v_payload jsonb;
  v_warn    text;
  v_disc    jsonb;
  v_disc_id uuid;
  v_month   date := public.fn__karachi_month();
  v_due     integer;
  v_inv     uuid;
  v_owed    numeric;
  v_lines   integer;
  v_raw     text;
  v_want    numeric;
  v_paid    numeric;
  v_dues    jsonb;
  v_dres    jsonb;
  v_bad     text;
  v_claim   uuid;
  v_result  jsonb;
begin
  if not public.has_role('owner','principal','admin_clerk') then
    raise exception 'Not permitted to admit students' using errcode = '42501';
  end if;
  if v_session is null then raise exception 'Pick a school year first.'; end if;
  if v_class   is null then raise exception 'Pick a class first.'; end if;
  if jsonb_typeof(v_rows) <> 'array' then raise exception 'rows must be a list'; end if;
  -- A CEILING, because this runs in one transaction and one browser must not be
  -- able to hold a write lock on the roster for a minute. The grid sends a
  -- longer list as several saves of this size.
  if jsonb_array_length(v_rows) > 200 then
    raise exception 'Save at most 200 rows at a time.' using errcode = '54000';
  end if;
  perform public.fn__only_these_keys(v_rows,
    '{full_name,roll_no,gr_no,father_name,mother_name,gender,b_form,dob,phone,whatsapp,father_cnic,admission_date,sibling_student_id,discount,arrears,dues,bill_this_month,paid_this_month,paid_amount}'::text[],
    'Rapid entry');
  perform public.assert_own('academic_sessions', v_session);
  perform public.assert_own('classes', v_class);
  perform public.assert_own('sections', v_section);

  -- The same save arriving twice gets the first answer. The claim is made in
  -- this transaction, so a second arrival waits for the first to finish and
  -- then reads what it stored; a save that fails takes its claim with it.
  if v_request is not null then
    delete from public.rde_saves
     where school_id = v_school and created_at < now() - interval '14 days';
    insert into public.rde_saves(school_id, request_id)
    values (v_school, v_request)
    on conflict (school_id, request_id) do nothing
    returning id into v_claim;
    if v_claim is null then
      select result into v_result from public.rde_saves
       where school_id = v_school and request_id = v_request;
      return coalesce(v_result, '{}'::jsonb) || jsonb_build_object('replayed', true);
    end if;
  end if;

  select due_day into v_due from public.school_settings
   where school_id = v_school;

  for v_row in select * from jsonb_array_elements(v_rows) loop
    v_idx := v_idx + 1;
    v_warn := null;
    v_dres := null;
    v_paid := null;

    -- A blank line in the middle of a grid is not an error. A clerk who tabs
    -- past a row they meant to skip should not be told off for it.
    continue when nullif(btrim(coalesce(v_row->>'full_name','')), '') is null;

    begin  -- ---- the savepoint that protects every other row ----------------
      v_sib := nullif(v_row->>'sibling_student_id','')::uuid;

      v_payload := jsonb_build_object(
        'session_id',  v_session,
        'class_id',    v_class,
        'section_id',  v_section,
        'full_name',   v_row->>'full_name',
        'roll_no',     v_row->>'roll_no',
        'gr_no',       v_row->>'gr_no',
        'father_name', v_row->>'father_name',
        'mother_name', v_row->>'mother_name',
        'gender',      v_row->>'gender',
        'b_form',      v_row->>'b_form',
        'dob',         v_row->>'dob',
        'phone',       v_row->>'phone',
        'whatsapp',    v_row->>'whatsapp',
        'father_cnic', v_row->>'father_cnic',
        'admission_date', v_row->>'admission_date')
        -- THE SIBLING, AND THIS IS THE BILLING MERGE. fn_admit_student reads
        -- links[0] and puts the new child into that child's family, so from the
        -- next challan run the house receives ONE bill for both.
        || case when v_sib is null then '{}'::jsonb
                else jsonb_build_object('links',
                       jsonb_build_array(jsonb_build_object(
                         'related_student_id', v_sib, 'relation', 'sibling')))
           end;

      v_res := public.fn_admit_student(v_payload);
      v_student := (v_res->>'student_id')::uuid;
      v_enroll  := (v_res->>'enrollment_id')::uuid;
      if (v_res->>'is_draft')::boolean then v_drafts := v_drafts + 1; end if;

      -- ---- the concession -------------------------------------------------
      v_disc := v_row->'discount';
      if v_disc is not null and jsonb_typeof(v_disc) = 'object'
         and coalesce(nullif(v_disc->>'amount','')::numeric, 0) > 0 then
        begin
          v_disc_id := public.fn_add_discount(
            v_student,
            coalesce(nullif(v_disc->>'type',''), 'sibling')::public.discount_type,
            (v_disc->>'amount')::numeric,
            coalesce((v_disc->>'is_percent')::boolean, false),
            nullif(v_disc->>'reason',''),
            v_month, null);
          perform public.fn_set_discount_status(v_disc_id, 'approved');
        exception when others then
          v_warn := coalesce(v_warn || ' ', '') || 'Discount not applied: ' || sqlerrm;
        end;
      end if;

      -- ---- this month, BEFORE any due -------------------------------------
      -- Billed either way: a child entered today is on this month's challan
      -- run like everybody else. Raising it here is what lets the clerk take
      -- the fee at the counter the same morning.
      v_inv := null;
      if coalesce((v_row->>'bill_this_month')::boolean, true) then
        begin
          v_inv := public.fn_bill_student_month(
                     v_enroll, v_month,
                     public.fn__day_in_month(v_month, coalesce(v_due, 10)));
        exception when others then
          v_inv := null;
          v_warn := coalesce(v_warn || ' ', '') || 'This month was not billed: ' || sqlerrm;
        end;
      end if;

      -- ---- and whether it has been paid -----------------------------------
      v_raw := regexp_replace(lower(btrim(coalesce(v_row->>'paid_amount', ''))),
                              '(pkr|rs\.?|,|\s)', '', 'g');
      v_want := case when v_raw ~ '^[0-9]+(\.[0-9]{1,2})?$' then v_raw::numeric end;
      if v_raw <> '' and v_want is null then
        v_warn := coalesce(v_warn || ' ', '')
          || format('"%s" is not an amount, so no payment was recorded for this month.',
                    v_row->>'paid_amount');
      elsif v_inv is not null
            and (coalesce((v_row->>'paid_this_month')::boolean, false) or v_want > 0) then
        begin
          select count(*) into v_lines
            from public.invoice_lines l where l.invoice_id = v_inv and not l.is_discount;
          select greatest(
                   coalesce((select sum(case when l.is_discount then -l.amount else l.amount end)
                               from public.invoice_lines l where l.invoice_id = v_inv), 0)
                   - coalesce((select sum(a.amount) from public.payment_allocations a
                                join public.payments pm on pm.id = a.payment_id
                                                       and pm.status = 'verified'
                               where a.invoice_id = v_inv), 0), 0)
            into v_owed;
          if v_lines = 0 then
            v_warn := coalesce(v_warn || ' ', '')
              || 'This month was marked as collected, but this class has no monthly fee '
              || 'set yet, so there was no fee to mark paid. Set the class fee in Fees, '
              || 'then take the payment on the child''s page.';
          elsif v_owed > 0 then
            v_paid := case when v_want is null or v_want <= 0 or v_want >= v_owed
                           then v_owed else v_want end;
            perform public.fn_record_payment(v_student, v_paid, 'cash',
              'Fee for ' || to_char(v_month, 'Mon YYYY')
              || case when v_paid < v_owed then ' (part, collected before onboarding)'
                      else ' (already collected, entered at onboarding)' end, false);
            if v_want > v_owed then
              v_warn := coalesce(v_warn || ' ', '')
                || format('Rs %s was typed as collected, but this month''s fee is Rs %s, '
                          'so Rs %s was recorded.',
                          to_char(v_want, 'FM999,999,990'), to_char(v_owed, 'FM999,999,990'),
                          to_char(v_owed, 'FM999,999,990'));
            end if;
          end if;
        exception when others then
          v_paid := null;
          v_warn := coalesce(v_warn || ' ', '')
            || 'The payment for this month was not recorded: ' || sqlerrm;
        end;
      end if;

      -- ---- what the child already owed ------------------------------------
      v_dues := case when jsonb_typeof(v_row->'dues') = 'array'
                     then v_row->'dues' else '[]'::jsonb end
             || coalesce((
                  select jsonb_agg(jsonb_build_object(
                           'kind', 'month', 'month', a->>'month', 'amount', a->'amount'))
                    from jsonb_array_elements(
                           case when jsonb_typeof(v_row->'arrears') = 'array'
                                then v_row->'arrears' else '[]'::jsonb end) a), '[]'::jsonb);
      if jsonb_array_length(v_dues) > 0 then
        begin
          v_dres := public.fn__record_dues(v_student, v_enroll, v_dues);
          select string_agg(x->>'message', ' ' order by (x->>'i')::int) into v_bad
            from jsonb_array_elements(v_dres->'items') x
           where x->>'status' <> 'recorded';
          if v_bad is not null then
            v_warn := coalesce(v_warn || ' ', '') || v_bad;
          end if;
        exception when others then
          v_dres := null;
          v_warn := coalesce(v_warn || ' ', '') || 'Previous dues not recorded: ' || sqlerrm;
        end;
      end if;

      v_created := v_created + 1;
      v_out := v_out || jsonb_build_array(jsonb_build_object(
        'row', v_idx, 'status', case when v_warn is null then 'created' else 'partial' end,
        'student_id', v_student, 'gr_no', v_res->>'gr_no', 'roll_no', v_res->>'roll_no',
        'full_name', v_row->>'full_name', 'is_draft', (v_res->>'is_draft')::boolean,
        'arrears_months', coalesce((v_dres->>'months')::int, 0),
        'dues_recorded', coalesce((v_dres->>'recorded')::int, 0),
        'dues_total', coalesce((v_dres->>'total')::numeric, 0),
        'dues', coalesce(v_dres->'items', '[]'::jsonb),
        'paid_amount', v_paid,
        'message', v_warn));

    exception when others then
      -- The row is rolled back to the savepoint. Everything before it stands.
      v_failed := v_failed + 1;
      v_out := v_out || jsonb_build_array(jsonb_build_object(
        'row', v_idx, 'status', 'error', 'full_name', v_row->>'full_name',
        'message', sqlerrm));
    end;
  end loop;

  v_result := jsonb_build_object(
    'created', v_created, 'failed', v_failed, 'drafts', v_drafts, 'results', v_out);
  if v_claim is not null then
    update public.rde_saves set result = v_result where id = v_claim;
  end if;
  return v_result;
end;
$$;

-- ---------------------------------------------------------------------------
-- 9. The billing run leaves a typed due as typed.
--
-- Reproduced whole from the catalogue. The only change: steps 2 and 3,
-- which add the fee lines and the discount lines to every invoice of the month
-- that lacks them, skip an invoice with carried_kind. A due typed from the
-- school's paper is the amount owed, and step 3 was taking a concession off it
-- a second time.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_bill_month(p_session_id uuid, p_period_month date, p_due_date date DEFAULT NULL::date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
 SET "TimeZone" TO 'Asia/Karachi'
AS $function$
declare
  v_actor   uuid := auth.uid();
  v_school  uuid := public.current_school_id();
  v_month   date := date_trunc('month', p_period_month)::date;
  v_due     date;
  v_billed  integer := 0;
  v_nofee   integer := 0;
  v_names   text;
begin
  if not public.has_role('owner', 'principal') then
    raise exception 'Not permitted to raise fees' using errcode = '42501';
  end if;
  perform public.assert_own('academic_sessions', p_session_id);
  perform public.fn__assert_date_in_session(p_session_id, v_month,
            'Raising the fee for a month', true);

  v_due := coalesce(
    p_due_date,
    public.fn__day_in_month(v_month,
      (select due_day from public.school_settings where school_id = v_school)));

  -- 1. THE INVOICES. `on conflict do nothing` against the partial unique index
  -- is what makes this safe to run again, and it is the whole reason the
  -- self-healing pass below can be called on every page load without counting
  -- anything twice.
  --
  -- Arrears are snapshotted from a single aggregate over the ledger rather than
  -- a per-pupil function call. The figure is what the child owed BEFORE this
  -- month's charge, which is what a challan prints.
  with roll as (
    select e.id as enrollment_id, e.student_id, e.class_id
      from public.enrollments e
      join public.students s
        on s.id = e.student_id
       and s.school_id = v_school
       and s.status = 'active'
       and s.deleted_at is null
     where e.session_id = p_session_id
       and e.status = 'active'
       -- NOT BEFORE THE CHILD WAS ADMITTED, and this was found by the test
       -- rather than by reading. Without it the self-healing pass bills a
       -- pupil admitted in September for May, June, July and August as well,
       -- because it walks every month of the session and every active
       -- enrolment is active in all of them. The parent's first challan would
       -- have been five months of fees for a child who had been there a week.
       --
       -- The bound is the LATER of the session start and the admission month,
       -- which is what coalesce plus the comparison gives: a pupil admitted in
       -- 2024 and enrolled in this year's session is billed from the session
       -- start, not from 2024, because months before the session start are
       -- never walked at all.
       --
       -- A pupil who joins mid-month is charged the whole month. That is the
       -- ordinary arrangement in these schools and it is the school's to waive
       -- on the child's ledger if they disagree; guessing a pro-rata rule here
       -- would be inventing a policy nobody asked for.
       and date_trunc('month', coalesce(s.admission_date, v_month))::date <= v_month
       and not exists (
             select 1 from public.invoices i
              where i.enrollment_id = e.id
                and i.period_month = v_month
                and i.status <> 'void')
  ),
  charged as (
    select i.student_id,
           sum(coalesce(l.net, 0)) + sum(coalesce(i.fine, 0)) as charge
      from public.invoices i
      left join lateral (
             select sum(case when l.is_discount then -l.amount else l.amount end) as net
               from public.invoice_lines l where l.invoice_id = i.id) l on true
     where i.school_id = v_school and i.status <> 'void'
       and i.student_id in (select student_id from roll)
     group by i.student_id
  ),
  paid as (
    select i.student_id, sum(al.amount) as allocated
      from public.payment_allocations al
      join public.invoices i on i.id = al.invoice_id
      join public.payments p on p.id = al.payment_id
     where p.status = 'verified' and i.school_id = v_school
       and i.student_id in (select student_id from roll)
     group by i.student_id
  ),
  adj as (
    select a.student_id, sum(a.amount) as amount
      from public.adjustments a
     where a.student_id in (select student_id from roll)
     group by a.student_id
  )
  insert into public.invoices(
    student_id, enrollment_id, session_id, period_month, status,
    arrears_brought_forward, due_date, issued_at, created_by)
  select r.student_id, r.enrollment_id, p_session_id, v_month, 'issued',
         coalesce(c.charge, 0) + coalesce(j.amount, 0) - coalesce(pd.allocated, 0),
         v_due, now(), v_actor
    from roll r
    left join charged c on c.student_id = r.student_id
    left join paid    pd on pd.student_id = r.student_id
    left join adj     j  on j.student_id = r.student_id
  on conflict do nothing;

  get diagnostics v_billed = row_count;

  -- 2. THE LINES. Every recurring fee head, at the amount in force FOR THE
  -- MONTH BEING BILLED rather than for today, with a per-pupil override
  -- winning over the class amount. Both rules are 0066's and are kept.
  insert into public.invoice_lines(invoice_id, fee_head_id, description, amount, is_discount)
  select i.id, fh.id, fh.name, coalesce(sfi.amount, amt.amount), false
    from public.invoices i
    join public.enrollments e on e.id = i.enrollment_id
    join public.fee_heads fh
      on fh.school_id = v_school and fh.is_recurring and fh.active
    join lateral (
           select fs.amount
             from public.fee_structures fs
            where fs.school_id = v_school
              and fs.session_id = p_session_id
              and fs.class_id = e.class_id
              and fs.fee_head_id = fh.id
              and fs.effective_from <= v_month
            order by fs.effective_from desc
            limit 1) amt on true
    left join public.student_fee_items sfi
      on sfi.student_id = i.student_id and sfi.fee_head_id = fh.id and sfi.active
   where i.school_id = v_school
     and i.session_id = p_session_id
     and i.period_month = v_month
     and i.status <> 'void'
     and i.carried_kind is null
     and not exists (select 1 from public.invoice_lines l
                      where l.invoice_id = i.id and not l.is_discount);

  -- 3. THE DISCOUNTS. Applied in the order they were granted and capped at the
  -- charge, which is fn__apply_discount_lines' rule, expressed as one statement
  -- rather than a loop per pupil. The running total is over the discounts
  -- BEFORE this one, so the cap is the room left rather than the whole charge.
  --
  -- Keyed on the CHILD and bounded by the months the discount covers, which is
  -- 0138's model. Keyed on the enrolment, as it was, every concession in the
  -- school would evaporate at rollover and this function would cheerfully bill
  -- the full fee to every family that had one.
  insert into public.invoice_lines(invoice_id, fee_head_id, description, amount, is_discount)
  select d.invoice_id, null, 'Discount: ' || d.type,
         least(d.amt, greatest(d.gross - d.used_before, 0)), true
    from (
      select i.id as invoice_id,
             dc.type,
             g.gross,
             case when dc.is_percent then round(g.gross * dc.amount / 100.0, 2)
                  else dc.amount end as amt,
             coalesce(sum(case when dc.is_percent
                               then round(g.gross * dc.amount / 100.0, 2)
                               else dc.amount end)
                      over (partition by i.id order by dc.created_at, dc.id
                            rows between unbounded preceding and 1 preceding), 0) as used_before
        from public.invoices i
        join public.discounts dc
          on dc.student_id = i.student_id
         and dc.school_id = v_school
         and dc.status = 'approved'
         and dc.starts_on <= v_month
         and (dc.ends_on is null or dc.ends_on >= v_month)
        join lateral (
               select coalesce(sum(l.amount), 0) as gross
                 from public.invoice_lines l
                where l.invoice_id = i.id and not l.is_discount) g on true
       where i.school_id = v_school
         and i.session_id = p_session_id
         and i.period_month = v_month
         and i.status <> 'void'
         -- 0153. A due typed in by hand is the amount owed, not a fee to discount.
         and i.carried_kind is null
         and not exists (select 1 from public.invoice_lines l
                          where l.invoice_id = i.id and l.is_discount)
    ) d
   where least(d.amt, greatest(d.gross - d.used_before, 0)) > 0;

  -- 4. A CLASS WITH NO FEE SET IS NAMED, NOT SILENTLY BILLED ZERO. This is the
  -- failure a school meets on its first month: the structure was filled in for
  -- five classes out of twelve and the other seven were charged nothing, which
  -- looks exactly like everybody having paid.
  select count(distinct c.id), string_agg(distinct c.name, ', ' order by c.name)
    into v_nofee, v_names
    from public.enrollments e
    join public.classes c on c.id = e.class_id
    join public.students s on s.id = e.student_id
                          and s.status = 'active' and s.deleted_at is null
   where e.session_id = p_session_id and e.status = 'active'
     and e.school_id = v_school
     and not exists (
           select 1 from public.fee_structures fs
            join public.fee_heads fh on fh.id = fs.fee_head_id
                                    and fh.is_recurring and fh.active
            where fs.session_id = p_session_id
              and fs.class_id = e.class_id
              and fs.effective_from <= v_month);

  insert into public.billing_months(school_id, session_id, period_month, state,
                                    due_date, billed_at, billed_by, pupils_billed)
  values (v_school, p_session_id, v_month, 'billed', v_due, now(), v_actor, v_billed)
  on conflict (session_id, period_month) do update
    set state = 'billed',
        due_date = excluded.due_date,
        billed_at = now(),
        billed_by = v_actor,
        pupils_billed = public.billing_months.pupils_billed + excluded.pupils_billed;

  return jsonb_build_object(
    'period_month', v_month,
    'due_date', v_due,
    'billed', v_billed,
    'classes_with_no_fee', v_nofee,
    'classes_with_no_fee_names', v_names);
end;
$function$;

-- ---------------------------------------------------------------------------
-- 10. Repricing a child's months leaves a typed due as typed.
--
-- Reproduced whole. A discount approved, edited or ended reprices every unpaid
-- month from its start; a backdated one reached the dues typed in at
-- onboarding and halved them. Those now stay as the school wrote them.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_reprice_student(p_student_id uuid, p_from_month date DEFAULT NULL::date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
 SET "TimeZone" TO 'Asia/Karachi'
AS $function$
declare
  v_school  uuid := public.current_school_id();
  v_from    date := date_trunc('month', coalesce(p_from_month, public.fn__karachi_month()))::date;
  v_inv     record;
  v_gross   numeric;
  v_room    numeric;
  v_rec     record;
  v_amt     numeric;
  v_done    integer := 0;
  v_held    integer := 0;
begin
  if not public.has_role('owner', 'principal') then
    raise exception 'Not permitted to change fees' using errcode = '42501';
  end if;
  perform public.assert_own('students', p_student_id);
  -- Bounded for the same reason fn_add_discount is: this takes a month from the
  -- caller and rewrites charges from it onwards. 0130's guard found it.
  perform public.fn__assert_date_in_calendar(v_from, 'The month to reprice from');

  for v_inv in
    select i.id, i.period_month,
           coalesce((select sum(al.amount) from public.payment_allocations al
                       join public.payments p on p.id = al.payment_id
                      where al.invoice_id = i.id and p.status = 'verified'), 0) as allocated
      from public.invoices i
     where i.school_id = v_school
       and i.student_id = p_student_id
       and i.status <> 'void'
       and i.period_month is not null
       and i.period_month >= v_from
       -- 0153. A due typed in by hand is the amount owed, not a fee to discount.
       and i.carried_kind is null
     order by i.period_month
  loop
    if v_inv.allocated <> 0 then
      v_held := v_held + 1;
      continue;
    end if;

    delete from public.invoice_lines where invoice_id = v_inv.id and is_discount;

    select coalesce(sum(amount), 0) into v_gross
      from public.invoice_lines where invoice_id = v_inv.id and not is_discount;

    v_room := v_gross;
    for v_rec in select * from public.fn__discounts_live(p_student_id, v_inv.period_month) loop
      exit when v_room <= 0;
      v_amt := case when v_rec.is_percent then round(v_gross * v_rec.amount / 100.0, 2)
                    else v_rec.amount end;
      v_amt := least(v_amt, v_room);
      if v_amt > 0 then
        insert into public.invoice_lines(invoice_id, fee_head_id, description, amount, is_discount)
        values (v_inv.id, null, 'Discount: ' || v_rec.type, v_amt, true);
        v_room := v_room - v_amt;
      end if;
    end loop;

    -- The status is a label over the money and has to follow it: a challan that
    -- a discount has just cleared in full is paid, not issued.
    update public.invoices i
       set status = (case
             when (select b.allocated from public.invoice_balances b where b.invoice_id = i.id)
                  >= (select b.charge from public.invoice_balances b where b.invoice_id = i.id)
             then 'paid'
             when (select b.allocated from public.invoice_balances b where b.invoice_id = i.id) > 0
             then 'partial'
             else 'issued' end)::public.invoice_status
     where i.id = v_inv.id;

    v_done := v_done + 1;
  end loop;

  return jsonb_build_object('repriced', v_done, 'left_alone_because_paid', v_held,
                            'from_month', v_from);
end;
$function$;

-- ---------------------------------------------------------------------------
-- 11. One challan per month, whatever day the caller names.
--
-- Reproduced whole. period_month is a label for a month and the unique index
-- compares it exactly, so 15 September and 1 September were two Septembers:
-- two challans, and Arrears counted the month twice. The month is now rounded
-- to its first day before anything is looked up or written.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_bill_student_month(p_enrollment_id uuid, p_period_month date, p_due_date date)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
 SET "TimeZone" TO 'Asia/Karachi'
AS $function$
declare
  v_actor   uuid := auth.uid();
  v_enr     record;
  v_inv     uuid;
  v_arrears numeric;
  v_tuition numeric;
  v_month   date := date_trunc('month', p_period_month)::date;
begin
  if not public.has_role('owner','principal','admin_clerk','accountant') then
    raise exception 'Not permitted to generate invoices';
  end if;
  perform public.assert_own('enrollments', p_enrollment_id);
  select e.id, e.student_id, e.session_id, e.class_id into v_enr
  from public.enrollments e where e.id = p_enrollment_id;
  if not found then raise exception 'Enrolment not found'; end if;

  -- 0130: the month being billed belongs to the year the child is
  -- enrolled in. A challan dated outside it shows in no month's
  -- collection and on no defaulter list.
  perform public.fn__assert_date_in_session(v_enr.session_id,
            v_month, 'Generating a challan',
            -- whole months: period_month is the FIRST of the month, a
            -- label for "September" and not a day. A school whose year
            -- begins on the 7th still bills that whole month.
            true);
  if p_due_date is not null
     and (p_due_date < v_month - 31
          or p_due_date > v_month + 180) then
    raise exception 'A challan for % cannot be due on %. Check the '
      'date.', to_char(v_month, 'Mon YYYY'),
      to_char(p_due_date, 'DD Mon YYYY')
      using errcode = '22008';
  end if;


  select id into v_inv from public.invoices
   where enrollment_id = p_enrollment_id and period_month = v_month and status <> 'void'
   limit 1;
  if found then return v_inv; end if;

  v_arrears := public.student_balance(v_enr.student_id);
  begin
    insert into public.invoices(student_id, enrollment_id, session_id, period_month, status,
        arrears_brought_forward, due_date, issued_at, created_by)
    values (v_enr.student_id, v_enr.id, v_enr.session_id, v_month, 'issued',
        v_arrears, p_due_date, now(), v_actor)
    returning id into v_inv;
  exception when unique_violation then
    -- lost a race with a concurrent bill for the same (enrolment, month)
    select id into v_inv from public.invoices
     where enrollment_id = p_enrollment_id and period_month = v_month and status <> 'void' limit 1;
    return v_inv;
  end;

  insert into public.invoice_lines(invoice_id, fee_head_id, description, amount, is_discount)
  select v_inv, fh.id, fh.name, coalesce(sfi.amount, fs.amount), false
  from public.fee_heads fh
  join lateral (
    select fs.amount
      from public.fee_structures fs
     where fs.school_id = public.current_school_id()
       and fs.session_id = v_enr.session_id and fs.class_id = v_enr.class_id
       and fs.fee_head_id = fh.id
       and fs.effective_from <= coalesce(v_month, current_date)
     order by fs.effective_from desc limit 1
  ) fs on true
  left join public.student_fee_items sfi
    on sfi.student_id = v_enr.student_id and sfi.fee_head_id = fh.id and sfi.active
  where fh.school_id = public.current_school_id() and fh.is_recurring and fh.active;

  select coalesce(sum(amount), 0) into v_tuition
  from public.invoice_lines where invoice_id = v_inv and not is_discount;

  perform public.fn__apply_discount_lines(v_inv, v_enr.id, v_tuition);
  return v_inv;
end;
$function$;

-- ---------------------------------------------------------------------------
-- 12. A holiday month can still be skipped after a due was typed into it.
--
-- Reproduced whole. Skipping a month was refused once any charge existed in
-- it, and a single child's typed-in due for June was enough to stop the school
-- marking June a holiday for everyone. Typed dues are not counted; they stay
-- on the child's account whatever the month's state.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_set_month_state(p_session_id uuid, p_period_month date, p_state text, p_due_date date DEFAULT NULL::date, p_note text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
 SET "TimeZone" TO 'Asia/Karachi'
AS $function$
declare
  v_school uuid := public.current_school_id();
  v_month  date := date_trunc('month', p_period_month)::date;
  v_have   integer;
begin
  if not public.has_role('owner', 'principal') then
    raise exception 'Not permitted to change the billing calendar' using errcode = '42501';
  end if;
  perform public.assert_own('academic_sessions', p_session_id);
  if p_state not in ('scheduled', 'skipped') then
    raise exception 'A month can be set to scheduled or skipped. Billing it is what '
      'raises the fees.' using errcode = '22023';
  end if;

  perform public.fn__assert_date_in_session(p_session_id, v_month,
            'Changing the billing calendar', true);
  if p_due_date is not null then
    perform public.fn__assert_date_in_calendar(p_due_date, 'The day a month''s fee falls due');
  end if;

  select count(*) into v_have from public.invoices i
   where i.school_id = v_school and i.session_id = p_session_id
     and i.period_month = v_month and i.status <> 'void'
     and i.carried_kind is null;

  if p_state = 'skipped' and v_have > 0 then
    raise exception '% has already been charged to % pupil(s). Skipping it here '
      'would not take those charges back. Void them first if that is what you '
      'mean.', to_char(v_month, 'Mon YYYY'), v_have using errcode = '22023';
  end if;

  insert into public.billing_months(school_id, session_id, period_month, state, due_date, note)
  values (v_school, p_session_id, v_month, p_state, p_due_date, nullif(btrim(p_note), ''))
  on conflict (session_id, period_month) do update
    set state = excluded.state,
        due_date = coalesce(excluded.due_date, public.billing_months.due_date),
        note = coalesce(excluded.note, public.billing_months.note);

  return jsonb_build_object('period_month', v_month, 'state', p_state);
end;
$function$;

-- ---------------------------------------------------------------------------
-- 13. Fees, Arrears sees a named due.
--
-- Reproduced whole. The list counted only months, so an unpaid admission fee,
-- a stationery bill or an imported opening balance was on the child's balance
-- and on no list anybody worked from. They are now in the amount. months_owed
-- still counts months only, and oldest_month stays a month (null when the
-- child owes only named dues).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_arrears(p_session_id uuid)
 RETURNS TABLE(student_id uuid, gr_no text, full_name text, class_name text, section_name text, roll_no text, family_id uuid, family_head text, phone text, months_owed integer, oldest_month date, amount numeric)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
 SET "TimeZone" TO 'Asia/Karachi'
AS $function$
declare
  v_school uuid := public.current_school_id();
  v_month  date := public.fn__karachi_month();
begin
  if not public.may_view('owner', 'principal', 'readonly') then
    raise exception 'Not permitted to view fee records' using errcode = '42501';
  end if;
  perform public.assert_own('academic_sessions', p_session_id);

  return query
  with inv as (
    select i.id, i.student_id, i.period_month, i.fine
      from public.invoices i
     where i.school_id = v_school
       and i.status <> 'void'
       and ((i.period_month is not null and i.period_month < v_month)
            -- 0153. Named dues typed in by hand, and the CSV opening balance.
            or (i.period_month is null
                and (i.carried_kind is not null
                     or split_part(coalesce(i.notes, ''), E'\n', 1) = 'opening_balance')))
       -- A challan the office has deliberately deferred is not an arrear: the
       -- school has already said "pay me in November". 0083 put that field
       -- there and nothing on the defaulters screen ever read it.
       and (i.deferred_until is null or i.deferred_until <= (now() at time zone 'Asia/Karachi')::date)
  ),
  lines as (
    select l.invoice_id, sum(case when l.is_discount then -l.amount else l.amount end) as net
      from public.invoice_lines l join inv on inv.id = l.invoice_id group by l.invoice_id
  ),
  alloc as (
    select al.invoice_id, sum(al.amount) as paid
      from public.payment_allocations al
      join public.payments p on p.id = al.payment_id and p.status = 'verified'
      join inv on inv.id = al.invoice_id group by al.invoice_id
  ),
  owing as (
    select inv.student_id, inv.period_month,
           coalesce(l.net, 0) + coalesce(inv.fine, 0) - coalesce(a.paid, 0) as due
      from inv
      left join lines l on l.invoice_id = inv.id
      left join alloc a on a.invoice_id = inv.id
  ),
  rolled as (
    select o.student_id,
           (count(*) filter (where o.period_month is not null))::integer as months_owed,
           min(o.period_month) as oldest_month,
           sum(o.due) as amount
      from owing o
     where o.due > 0
     group by o.student_id
  )
  select s.id, s.gr_no, s.full_name, c.name, sec.name, e.roll_no,
         s.family_id, f.head_name, coalesce(f.phone, s.phone),
         r.months_owed, r.oldest_month, r.amount
    from rolled r
    join public.students s on s.id = r.student_id
                          and s.status = 'active' and s.deleted_at is null
    join public.enrollments e on e.student_id = s.id and e.session_id = p_session_id
                             and e.status = 'active'
    join public.classes c on c.id = e.class_id
    left join public.sections sec on sec.id = e.section_id
    left join public.families f on f.id = s.family_id
   order by r.oldest_month, r.amount desc;
end;
$function$;

-- ---------------------------------------------------------------------------
-- 14. The child's fee state names the other dues.
--
-- Reproduced whole, with two keys added: other_dues_count and
-- other_dues_amount, the named dues and opening balance still owed. The
-- "earlier months unpaid" figure stays months only, so the two can be shown
-- side by side without one hiding inside the other.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_student_fee_state(p_student_id uuid, p_month date DEFAULT NULL::date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
 SET "TimeZone" TO 'Asia/Karachi'
AS $function$
declare
  v_school uuid := public.current_school_id();
  v_month  date := date_trunc('month', coalesce(p_month, public.fn__karachi_month()))::date;
  v_charge numeric; v_paid numeric; v_inv integer;
  v_arr_n integer; v_arr_amt numeric; v_arr_old date;
  v_family uuid; v_credit numeric := 0;
  v_oth_n integer; v_oth_amt numeric;
begin
  if not public.may_view('owner', 'principal', 'readonly') then
    raise exception 'Not permitted to view fee records' using errcode = '42501';
  end if;
  perform public.assert_own('students', p_student_id);
  select family_id into v_family from public.students where id = p_student_id;

  select count(i.id),
         coalesce(sum(coalesce(l.net, 0) + i.fine), 0),
         coalesce(sum(coalesce(a.paid, 0)), 0)
    into v_inv, v_charge, v_paid
    from public.invoices i
    left join lateral (
      select sum(case when x.is_discount then -x.amount else x.amount end) as net
        from public.invoice_lines x where x.invoice_id = i.id) l on true
    left join lateral (
      select sum(al.amount) as paid from public.payment_allocations al
        join public.payments p on p.id = al.payment_id and p.status = 'verified'
       where al.invoice_id = i.id) a on true
   where i.school_id = v_school and i.student_id = p_student_id
     and i.period_month = v_month and i.status <> 'void';

  select count(*)::integer, coalesce(sum(due), 0), min(period_month)
    into v_arr_n, v_arr_amt, v_arr_old
    from (
      select i.period_month,
             coalesce((select sum(case when x.is_discount then -x.amount else x.amount end)
                         from public.invoice_lines x where x.invoice_id = i.id), 0)
             + i.fine
             - coalesce((select sum(al.amount) from public.payment_allocations al
                           join public.payments p on p.id = al.payment_id and p.status = 'verified'
                          where al.invoice_id = i.id), 0) as due
        from public.invoices i
       where i.school_id = v_school and i.student_id = p_student_id
         and i.status <> 'void' and i.period_month is not null
         and i.period_month < v_month
         and (i.deferred_until is null
              or i.deferred_until <= (now() at time zone 'Asia/Karachi')::date)
    ) q
   where q.due > 0;

  select count(*)::integer, coalesce(sum(due), 0)
    into v_oth_n, v_oth_amt
    from (
      select coalesce((select sum(case when x.is_discount then -x.amount else x.amount end)
                         from public.invoice_lines x where x.invoice_id = i.id), 0)
             + i.fine
             - coalesce((select sum(al.amount) from public.payment_allocations al
                           join public.payments p on p.id = al.payment_id and p.status = 'verified'
                          where al.invoice_id = i.id), 0) as due
        from public.invoices i
       where i.school_id = v_school and i.student_id = p_student_id
         and i.status <> 'void' and i.period_month is null
         and (i.carried_kind is not null
              or split_part(coalesce(i.notes, ''), E'\n', 1) = 'opening_balance')
         and (i.deferred_until is null
              or i.deferred_until <= (now() at time zone 'Asia/Karachi')::date)
    ) q
   where q.due > 0;

  if v_family is not null then
    v_credit := public.family_credit(v_family);
  end if;

  return jsonb_build_object(
    'month', v_month,
    'billed', v_inv > 0,
    -- 'paid' is only true of a month that was actually charged. A child nobody
    -- billed is neither paid nor unpaid and saying either would be a lie.
    'state', case when v_inv = 0 then 'not_billed'
                  when v_charge - v_paid <= 0 then 'paid'
                  when v_paid > 0 then 'part_paid'
                  else 'unpaid' end,
    'charge', v_charge,
    'paid', v_paid,
    'due', greatest(v_charge - v_paid, 0),
    'arrears_months', coalesce(v_arr_n, 0),
    'arrears_amount', coalesce(v_arr_amt, 0),
    'arrears_oldest', v_arr_old,
    -- 0153. Named dues and the opening balance, still owed.
    'other_dues_count', coalesce(v_oth_n, 0),
    'other_dues_amount', coalesce(v_oth_amt, 0),
    'balance', public.student_balance(p_student_id),
    -- The money the school is holding for this family that is not yet against
    -- any month. Invisible on the child's screen until now.
    'family_credit', v_credit);
end;
$function$;

-- ---------------------------------------------------------------------------
-- 15. The counter says what each charge is.
--
-- Reproduced whole. Every charge with no month reached the counter as
-- "Other charges": an unpaid admission fee, stationery and an opening balance
-- looked the same to the clerk taking the money. Each now carries its label
-- and whether it was typed in from paper, and each child carries the named
-- dues still owed.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_family_sheet(p_family_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_out   jsonb;
  v_month date := public.fn__karachi_month();
begin
  if not public.may_view('owner', 'principal', 'readonly') then
    raise exception 'Not permitted to view fee records';
  end if;
  perform public.assert_own('families', p_family_id);

  select jsonb_build_object(
    'family', to_jsonb(f) - 'school_id',
    -- The month every per-child figure below is FOR. Without it the screen has
    -- to work out the school's month for itself in the browser's timezone, and
    -- a browser in Karachi and a server in UTC disagree for five hours a day.
    'month', v_month,
    'credit', public.family_credit(f.id),
    'outstanding', public.family_outstanding(f.id),
    'children', coalesce((
      select jsonb_agg(jsonb_build_object(
        'student_id', s.id,
        'full_name',  s.full_name,
        'gr_no',      s.gr_no,
        'status',     s.status,
        -- A face at the till. The search list above it has had one since the
        -- roster did, and for the stated reason: four boys called Muhammad Ali
        -- in one school is ordinary here. The sheet where the money is taken
        -- had none, which is the one screen where opening the wrong child
        -- costs somebody a receipt.
        'photo_path', s.photo_path,
        -- Which class this child's fee is the fee OF, taken from the same
        -- function that works out the fee, so the label and the figure cannot
        -- come from different enrolments.
        'class_name',   fee.j->>'class_name',
        'section_name', fee.j->>'section_name',
        'roll_no',      fee.j->>'roll_no',
        'gross',        coalesce((fee.j->>'gross')::numeric, 0),
        'discount',     coalesce((fee.j->>'discount')::numeric, 0),
        'net',          coalesce((fee.j->>'net')::numeric, 0),
        -- What came off, what kind, at what rate and why. This is the answer to
        -- the question asked at the window, and the counter had no way to give
        -- it: the concession was visible on the child's page in another module
        -- and nowhere near the person taking the money.
        'discount_lines', coalesce(fee.j->'lines', '[]'::jsonb),
        -- This month on its own, separated from the arrears. One balance for
        -- both is what makes a clerk say "you owe Rs 16,200" to a parent who
        -- wants to pay September and is then told nothing about the four months
        -- behind it.
        'month_state',    st.j->>'state',
        'month_charge',   coalesce((st.j->>'charge')::numeric, 0),
        'month_paid',     coalesce((st.j->>'paid')::numeric, 0),
        'month_due',      coalesce((st.j->>'due')::numeric, 0),
        'arrears_months', coalesce((st.j->>'arrears_months')::integer, 0),
        'arrears_amount', coalesce((st.j->>'arrears_amount')::numeric, 0),
        'arrears_oldest', st.j->>'arrears_oldest',
        -- Read out of the same object rather than calling student_balance a
        -- second time. fn_student_fee_state has already worked it out, and 0118
        -- exists because a balance that reads the whole ledger is expensive
        -- enough to be worth not doing twice per child.
        'balance', coalesce((st.j->>'balance')::numeric, 0),
        'other_dues_count',  coalesce((st.j->>'other_dues_count')::integer, 0),
        'other_dues_amount', coalesce((st.j->>'other_dues_amount')::numeric, 0),
        'invoices',   coalesce((
          select jsonb_agg(jsonb_build_object(
            'invoice_id',   b.invoice_id,
            'period_month', i.period_month,
            'due_date',     i.due_date,
            'charge',       b.charge,
            'allocated',    b.allocated,
            'outstanding',  b.charge - b.allocated,
            'status',       b.status,
            'label',        case when i.period_month is null
                                 then public.fn__one_off_label(i.label, i.notes) end,
            'carried',      i.carried_kind is not null
          ) order by i.period_month nulls first)
          from public.invoice_balances b
          join public.invoices i on i.id = b.invoice_id
          where b.student_id = s.id and b.status in ('issued', 'partial')
            and b.charge - b.allocated > 0
        ), '[]'::jsonb)
      ) order by s.full_name)
      from public.students s
      left join lateral (select public.fn_student_fee_for_month(s.id, v_month) as j) fee on true
      left join lateral (select public.fn_student_fee_state(s.id, v_month) as j) st on true
      where s.family_id = f.id
    ), '[]'::jsonb)
  ) into v_out
  from public.families f where f.id = p_family_id;

  if v_out is null then raise exception 'Family not found'; end if;
  return v_out;
end;
$function$;

-- ---------------------------------------------------------------------------
-- 16. The parent sees what each charge is.
--
-- Reproduced whole. The portal listed a charge with no month as "Other
-- charges" under the heading "Monthly challans". Each charge now carries its
-- label and whether it was carried in from the school's earlier records.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_portal_child_fees(p_student_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
 SET "TimeZone" TO 'Asia/Karachi'
AS $function$
declare v_fam uuid; v_out jsonb;
begin
  perform public.fn__assert_my_child(p_student_id);
  v_fam := public.my_family_id();

  select jsonb_build_object(
    'student_id', p_student_id,
    'balance', public.student_balance(p_student_id),
    'family_outstanding', public.family_outstanding(v_fam),
    'family_credit', public.family_credit(v_fam),
    -- Refundable money the school is HOLDING for this child. Not part of the
    -- balance, which is what is owed: this is the other direction, and a parent
    -- who is never shown it has no way to ask for it back.
    'deposit_held', public.fn__deposit_held(p_student_id),
    'invoices', coalesce((
      select jsonb_agg(jsonb_build_object(
        'period_month', i.period_month, 'due_date', i.due_date,
        'charge', b.charge, 'paid', b.allocated,
        'outstanding', b.charge - b.allocated, 'status', b.status,
        'label', case when i.period_month is null
                      then public.fn__one_off_label(i.label, i.notes) end,
        'carried', i.carried_kind is not null
      ) order by i.period_month desc nulls last)
      from public.invoice_balances b
      join public.invoices i on i.id = b.invoice_id
      where b.student_id = p_student_id
    ), '[]'::jsonb),
    'adjustments', coalesce((
      select jsonb_agg(jsonb_build_object(
        'on', a.created_at::date,
        'amount', a.amount,
        'reason', coalesce(nullif(btrim(a.reason), ''), 'Adjustment')
      ) order by a.created_at desc)
      from public.adjustments a
      where a.student_id = p_student_id
    ), '[]'::jsonb),
    'charges_not_on_a_challan', coalesce((
      select sum(a.amount) from public.adjustments a where a.student_id = p_student_id
    ), 0),
    'receipts', coalesce((
      select jsonb_agg(jsonb_build_object(
        'receipt_no', p.receipt_no, 'amount', p.amount,
        'method', p.method, 'paid_on', p.created_at,
        'received_by', pr.full_name
      ) order by p.created_at desc)
      from public.payments p
      left join public.profiles pr on pr.id = p.received_by
      where p.family_id = v_fam and p.status = 'verified'
    ), '[]'::jsonb)
  ) into v_out;

  return v_out;
end;
$function$;

-- ---------------------------------------------------------------------------
-- 17. A receipt says what it paid.
--
-- Reproduced whole, with each line's label for a charge that has no month.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn__payment_applied(p_payment_id uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select coalesce(jsonb_agg(x order by x.period_month nulls first, x.student_name, x.amount), '[]'::jsonb)
  from (
    select s.id            as student_id,
           s.full_name     as student_name,
           s.gr_no         as gr_no,
           i.period_month  as period_month,
           case when i.period_month is null
                then public.fn__one_off_label(i.label, i.notes) end as label,
           pa.amount       as amount
    from public.payment_allocations pa
    join public.invoices i on i.id = pa.invoice_id
    join public.students s on s.id = i.student_id
    where pa.payment_id = p_payment_id
      and i.school_id = public.current_school_id()
      and s.school_id = public.current_school_id()
  ) x;
$function$;

-- ---------------------------------------------------------------------------
-- 18. The statement says a month once, and names what a payment paid.
--
-- Reproduced whole. 0142's onboarding lines already carried their month
-- ("Fee for Aug 2026 (entered at onboarding)") and the statement added it
-- again. A payment against a charge with no month now names the charge.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn__student_ledger(p_student_id uuid)
 RETURNS TABLE(seq bigint, entry_on date, kind text, particulars text, reference text, debit numeric, credit numeric, balance_after numeric, recorded_by text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
 SET "TimeZone" TO 'Asia/Karachi'
AS $function$
  with entries as (
    -- The charge lines of every live challan
    select coalesce(i.issued_at::date, i.created_at::date) as entry_on,
           'charge'::text as kind,
           coalesce(l.description, 'Fee')
             || case when i.period_month is null
                       or position(to_char(i.period_month, 'Mon YYYY')
                                   in coalesce(l.description, '')) > 0
                     then ''
                     else ' for ' || to_char(i.period_month, 'Mon YYYY') end as particulars,
           coalesce(i.voucher_code, '') as reference,
           l.amount as debit, 0::numeric as credit,
           1 as rank,
           i.created_by as actor
    from public.invoices i
    join public.invoice_lines l on l.invoice_id = i.id
    where i.student_id = p_student_id and i.school_id = public.current_school_id()
      and i.status <> 'void' and not l.is_discount

    union all

    -- and the discount lines of the same challans, shown as the reduction they
    -- are rather than folded into the charge above. A parent who was granted a
    -- sibling discount should be able to see it every month.
    select coalesce(i.issued_at::date, i.created_at::date),
           'discount',
           coalesce(l.description, 'Discount')
             || coalesce(' for ' || to_char(i.period_month, 'Mon YYYY'), ''),
           coalesce(i.voucher_code, ''),
           0, l.amount,
           2,
           i.created_by
    from public.invoices i
    join public.invoice_lines l on l.invoice_id = i.id
    where i.student_id = p_student_id and i.school_id = public.current_school_id()
      and i.status <> 'void' and l.is_discount

    union all

    -- The fine, which is on the challan rather than on a line of it. This is
    -- the row Dues by Fee Head was missing.
    select coalesce(i.issued_at::date, i.created_at::date),
           'fine',
           'Late fee' || coalesce(' for ' || to_char(i.period_month, 'Mon YYYY'), ''),
           coalesce(i.voucher_code, ''),
           i.fine, 0,
           3,
           i.created_by
    from public.invoices i
    where i.student_id = p_student_id and i.school_id = public.current_school_id()
      and i.status <> 'void' and coalesce(i.fine, 0) <> 0

    union all

    -- Manual charges and waivers. Until this migration these existed only
    -- inside the balance.
    select a.created_at::date,
           'adjustment',
           coalesce(nullif(btrim(a.reason), ''), 'Adjustment'),
           '',
           case when a.amount > 0 then a.amount else 0 end,
           case when a.amount < 0 then -a.amount else 0 end,
           4,
           a.created_by
    from public.adjustments a
    where a.student_id = p_student_id and a.school_id = public.current_school_id()

    union all

    -- Money received, attributed to the child whose challan it settled. A
    -- family payment has no student_id of its own, so the invoice is what says
    -- which child it belongs to.
    select p.created_at::date,
           'payment',
           case when p.amount < 0 then 'Payment reversed' else 'Payment received' end
             || ' for ' || coalesce(to_char(i.period_month, 'Mon YYYY'),
                                    public.fn__one_off_label(i.label, i.notes)),
           coalesce('#' || p.receipt_no::text, ''),
           0, al.amount,
           5,
           p.received_by
    from public.payment_allocations al
    join public.invoices i on i.id = al.invoice_id
    join public.payments p on p.id = al.payment_id
    where i.student_id = p_student_id
      and i.school_id = public.current_school_id()
      and p.school_id = public.current_school_id()
      and p.status = 'verified'
  )
  select row_number() over w as seq,
         e.entry_on, e.kind, e.particulars, e.reference, e.debit, e.credit,
         sum(e.debit - e.credit) over (
           w rows between unbounded preceding and current row
         ) as balance_after,
         coalesce(pr.full_name, '') as recorded_by
  from entries e
  left join public.profiles pr on pr.id = e.actor
  window w as (order by e.entry_on, e.rank, e.particulars, e.reference)
  order by seq;
$function$;

-- ---------------------------------------------------------------------------
-- 19. A challan with no month prints what it is for.
--
-- Reproduced whole. The "Month" row printed notes, which for an imported
-- opening balance is the machine word opening_balance.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_challan(p_invoice_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_inv     record;
  v_lines   jsonb;
  v_charge  numeric;
  v_paid    numeric;
  v_this    numeric;
  v_total   numeric;
begin
  if not public.may_view('owner', 'principal', 'admin_clerk', 'accountant') then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  perform public.assert_own('invoices', p_invoice_id);
  -- 0087. A cancelled challan must not print: the slip is bank-payable, so
  -- printing one after the charge was cancelled is a way to collect cash
  -- that the books will never expect.
  if exists (select 1 from public.invoices
              where id = p_invoice_id and status = 'void') then
    raise exception 'This challan was cancelled and cannot be printed. See '
      'Fees → Cancelled charges for who cancelled it and why.'
      using errcode = '42501';
  end if;

  select i.id, i.student_id, i.period_month, i.due_date, i.fine, i.voucher_code,
         i.arrears_brought_forward, i.status, i.notes, i.label,
         s.full_name, s.gr_no, s.father_name, s.phone, s.whatsapp,
         f.head_name as family_head, f.head_cnic as family_cnic,
         c.name as class_name, sec.name as section_name, e.roll_no
    into v_inv
  from public.invoices i
  join public.students s   on s.id = i.student_id
  left join public.families f on f.id = s.family_id
  left join public.enrollments e on e.id = i.enrollment_id
  left join public.classes c   on c.id = e.class_id
  left join public.sections sec on sec.id = e.section_id
  where i.id = p_invoice_id;

  if not found then
    raise exception 'No such challan' using errcode = '42704';
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'description', l.description,
           'amount',      l.amount,
           'is_discount', l.is_discount) order by l.is_discount, l.description), '[]'::jsonb)
    into v_lines
  from public.invoice_lines l where l.invoice_id = p_invoice_id;

  select coalesce(sum(case when l.is_discount then -l.amount else l.amount end), 0)
    into v_charge
  from public.invoice_lines l where l.invoice_id = p_invoice_id;
  v_charge := v_charge + coalesce(v_inv.fine, 0);

  select coalesce(sum(al.amount), 0) into v_paid
  from public.payment_allocations al
  join public.payments p on p.id = al.payment_id
  where al.invoice_id = p_invoice_id and p.status = 'verified';

  v_this  := v_charge - v_paid;
  v_total := public.student_balance(v_inv.student_id);

  return jsonb_build_object(
    'invoice_id',     v_inv.id,
    'voucher_code',   v_inv.voucher_code,
    'status',         v_inv.status,
    'period_month',   v_inv.period_month,
    'period_label',   coalesce(to_char(v_inv.period_month, 'FMMonth YYYY'),
                               public.fn__one_off_label(v_inv.label, v_inv.notes)),
    'due_date',       v_inv.due_date,
    'student_id',     v_inv.student_id,
    'student_name',   v_inv.full_name,
    'gr_no',          v_inv.gr_no,
    'roll_no',        v_inv.roll_no,
    'father_name',    v_inv.father_name,
    'family_head',    v_inv.family_head,
    'family_cnic',    v_inv.family_cnic,
    'phone',          coalesce(v_inv.whatsapp, v_inv.phone),
    'class_name',     v_inv.class_name,
    'section_name',   v_inv.section_name,
    'lines',          v_lines,
    'fine',           coalesce(v_inv.fine, 0),
    'this_month',     v_charge,
    'already_paid',   v_paid,
    'this_month_due', v_this,
    -- Live, so a parent who has paid since generation is not asked twice.
    'previous_dues',  v_total - v_this,
    'total_payable',  v_total,
    -- The stale figure, named as such, for comparing a reprint with the original.
    'arrears_snapshot_at_generation', v_inv.arrears_brought_forward);
end;
$function$;

-- ---------------------------------------------------------------------------
-- 20. Unpaid challans names a charge with no month. Reproduced whole.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_report_unpaid_invoices(p_session_id uuid)
 RETURNS TABLE(invoice_id uuid, voucher_code text, period_label text, due_date date, days_overdue integer, student_id uuid, student_name text, gr_no text, class_name text, section_name text, father_name text, charge numeric, paid numeric, due numeric)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
 SET "TimeZone" TO 'Asia/Karachi'
AS $function$
declare v_school uuid := public.current_school_id();
begin
  if not public.may_view('owner', 'principal', 'admin_clerk', 'accountant') then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  perform public.assert_own('academic_sessions', p_session_id);

  return query
  select i.id, i.voucher_code,
         coalesce(to_char(i.period_month, 'Mon YYYY'), public.fn__one_off_label(i.label, i.notes)),
         i.due_date,
         case when i.due_date is null or i.due_date >= current_date then 0
              else (current_date - i.due_date) end::int,
         s.id, s.full_name, s.gr_no, c.name, sec.name, s.father_name,
         ch.charge, coalesce(pd.paid, 0), ch.charge - coalesce(pd.paid, 0)
  from public.invoices i
  join public.students s on s.id = i.student_id
  left join public.enrollments e on e.id = i.enrollment_id
  left join public.classes c   on c.id = e.class_id
  left join public.sections sec on sec.id = e.section_id
  cross join lateral (
    select coalesce((select sum(case when l.is_discount then -l.amount else l.amount end)
                       from public.invoice_lines l where l.invoice_id = i.id), 0)
           + coalesce(i.fine, 0) as charge
  ) ch
  left join lateral (
    select sum(al.amount) as paid
      from public.payment_allocations al
      join public.payments p on p.id = al.payment_id
     where al.invoice_id = i.id and p.status = 'verified'
  ) pd on true
  where i.school_id = v_school
    and i.session_id = p_session_id
    and i.status <> 'void'
    and s.deleted_at is null
    and ch.charge - coalesce(pd.paid, 0) > 0
  order by i.due_date nulls last, s.full_name;
end;
$function$;

-- ---------------------------------------------------------------------------
-- 21. Cancelled charges names a charge with no month. Reproduced whole.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_voided_invoices(p_from date, p_to date)
 RETURNS TABLE(invoice_id uuid, voided_at timestamp with time zone, student_id uuid, student_name text, gr_no text, class_name text, section_name text, period_label text, voucher_code text, amount numeric, voided_by text, reason text)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
 SET "TimeZone" TO 'Asia/Karachi'
AS $function$
declare v_school uuid := public.current_school_id();
begin
  if not public.may_view('owner', 'principal', 'admin_clerk', 'accountant') then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  if p_from is null or p_to is null then
    raise exception 'A date range is required';
  end if;
  if p_to < p_from then
    raise exception 'The end date is before the start date';
  end if;

  return query
  select i.id,
         i.voided_at,
         i.student_id,
         s.full_name,
         s.gr_no,
         c.name,
         sec.name,
         coalesce(to_char(i.period_month, 'FMMonth YYYY'),
                  public.fn__one_off_label(i.label, i.notes)),
         i.voucher_code,
         coalesce((select sum(case when l.is_discount then -l.amount else l.amount end)
                     from public.invoice_lines l where l.invoice_id = i.id), 0)
           + coalesce(i.fine, 0),
         coalesce(pr.full_name, '-'),
         coalesce(i.void_reason, '-')
    from public.invoices i
    join public.students s on s.id = i.student_id and s.school_id = v_school
    left join public.enrollments e on e.id = i.enrollment_id
    left join public.classes c   on c.id = e.class_id
    left join public.sections sec on sec.id = e.section_id
    left join public.profiles pr on pr.id = i.voided_by
   where i.school_id = v_school
     and i.status = 'void'
     -- A challan voided before this migration existed has no voided_at. Those
     -- are impossible today (nothing could write `void`) but a database
     -- restored from elsewhere might carry one, and dropping it silently would
     -- make the register lie about what it contains.
     and coalesce(i.voided_at::date, i.created_at::date) between p_from and p_to
   order by i.voided_at desc nulls last, s.full_name;
end;
$function$;

-- ---------------------------------------------------------------------------
-- 22. Recent payments says what a receipt paid for. Reproduced whole.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_recent_payments(p_limit integer DEFAULT 25)
 RETURNS TABLE(payment_id uuid, receipt_no bigint, paid_at timestamp with time zone, student_id uuid, student_name text, gr_no text, family_id uuid, parent_name text, class_name text, section_name text, paid_for text, amount numeric, method payment_method, late_fee numeric, discount numeric, note text, status text, received_by text, is_reversal boolean)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_school uuid := public.current_school_id();
begin
  if not public.may_view('owner', 'principal', 'admin_clerk', 'accountant') then
    raise exception 'Not permitted' using errcode = '42501';
  end if;

  return query
  select
    p.id,
    p.receipt_no,
    p.created_at,
    eff.sid,
    -- A family payment has NO payments.student_id: the money came from the
    -- father, not from a child. Falling back to the allocations is what makes
    -- this column non-empty for exactly the payments the family feature
    -- creates, and it names every child the receipt actually covered — which is
    -- what the clerk needs to say out loud at the window.
    coalesce(s.full_name, alloc.names, '-'),
    s.gr_no,
    p.family_id,
    f.head_name,
    c.name,
    sec.name,
    (select string_agg(distinct
              coalesce(to_char(i.period_month, 'Mon YYYY'), public.fn__one_off_label(i.label, i.notes)),
              ', ' order by coalesce(to_char(i.period_month, 'Mon YYYY'), public.fn__one_off_label(i.label, i.notes)))
       from public.payment_allocations al
       join public.invoices i on i.id = al.invoice_id
      where al.payment_id = p.id),
    p.amount,
    p.method,
    coalesce((select sum(d.fine)
                from (select distinct i2.id, i2.fine
                        from public.payment_allocations al2
                        join public.invoices i2 on i2.id = al2.invoice_id
                       where al2.payment_id = p.id) d), 0),
    coalesce((select sum(l.amount)
                from public.payment_allocations al3
                join public.invoice_lines l on l.invoice_id = al3.invoice_id
               where al3.payment_id = p.id and l.is_discount), 0),
    p.note,
    p.status::text,
    coalesce(pr.full_name, '-'),
    p.reversal_of is not null
  from public.payments p
  -- Which children this receipt settled anything for.
  left join lateral (
    select string_agg(distinct s2.full_name, ', ' order by s2.full_name) as names,
           count(distinct s2.id)                                        as n,
           (array_agg(distinct s2.id))[1]                               as only_id
      from public.payment_allocations al4
      join public.invoices i4  on i4.id = al4.invoice_id
      join public.students s2  on s2.id = i4.student_id
     where al4.payment_id = p.id
  ) alloc on true
  -- The one student this payment is ABOUT, if there is exactly one. A family
  -- payment spread across three siblings has no single class, and showing one
  -- of the three would be worse than showing none.
  left join lateral (
    select coalesce(p.student_id,
                    case when alloc.n = 1 then alloc.only_id end) as sid
  ) eff on true
  left join public.students   s   on s.id = eff.sid
  left join public.families    f  on f.id = p.family_id
  left join public.enrollments e  on e.student_id = eff.sid and e.status = 'active'
  left join public.classes     c  on c.id = e.class_id
  left join public.sections    sec on sec.id = e.section_id
  left join public.profiles    pr on pr.id = p.received_by
  where p.school_id = v_school
  -- receipt_no is the tie-break, and it has to be here: now() is
  -- transaction-stable, so every payment taken in ONE transaction shares a
  -- created_at to the microsecond and the order between them was undefined.
  -- The receipt number is gapless, rises with time, and is the number printed on
  -- the slip in the parent's hand.
  order by p.created_at desc, p.receipt_no desc
  limit greatest(1, least(coalesce(p_limit, 25), 200));
end;
$function$;

-- ---------------------------------------------------------------------------
-- 23. The day book says what a receipt paid for. Reproduced whole.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_report_ledger(p_from date, p_to date, p_kind text DEFAULT 'all'::text)
 RETURNS TABLE(entry_date date, kind text, category text, particulars text, reference text, party text, method text, debit numeric, credit numeric, recorded_by text, is_reversal boolean)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
 SET "TimeZone" TO 'Asia/Karachi'
AS $function$
declare v_school uuid := public.current_school_id();
begin
  -- Matches fn_finance_summary's boundary (owner / principal / accountant)
  -- rather than inventing a third one. Note a PRE-EXISTING inconsistency this
  -- deliberately does not paper over: fn_dashboard_summary shows the money
  -- tiles to `readonly` too, while fn_finance_summary refuses it. A full
  -- debit-and-credit statement naming every payer and payee is more sensitive
  -- than a tile, so it follows the stricter of the two. Whether `readonly`
  -- should see money at all is a decision for the school to make, not one to
  -- settle silently here.
  if not public.may_view('owner', 'principal', 'accountant') then
    raise exception 'Not permitted to read the accounts' using errcode = '42501';
  end if;
  if p_from is null or p_to is null then
    raise exception 'A date range is required';
  end if;
  if p_to < p_from then
    raise exception 'The end date is before the start date';
  end if;

  return query
  with rows_in as (
    -- Fee receipts. Verified only: a pending bank transfer is not income yet.
    select p.created_at::date               as entry_date,
           'income'::text                   as kind,
           'Fee collection'::text           as category,
           coalesce(
             (select string_agg(distinct
                       coalesce(to_char(i.period_month, 'Mon YYYY'),
                                public.fn__one_off_label(i.label, i.notes)), ', ')
                from public.payment_allocations al
                join public.invoices i on i.id = al.invoice_id
               where al.payment_id = p.id),
             'On account')                  as particulars,
           coalesce('#' || p.receipt_no::text, '-') as reference,
           coalesce(f.head_name, s.full_name, '-')  as party,
           p.method::text                   as method,
           -- A reversal is stored as a payment with a NEGATIVE amount. Putting
           -- it straight into `debit` gave a "money in" column containing
           -- -300, and made the two sides net out so a reversed receipt looked
           -- like it had never happened. A contra entry belongs on the opposite
           -- side as a positive figure, which is how a ledger is read and how
           -- the totals stay meaningful.
           case when p.amount >= 0 then p.amount else 0 end   as debit,
           case when p.amount <  0 then -p.amount else 0 end  as credit,
           coalesce(pr.full_name, '-')      as recorded_by,
           p.reversal_of is not null        as is_reversal
    from public.payments p
    left join public.families f on f.id = p.family_id
    left join public.students s on s.id = p.student_id
    left join public.profiles pr on pr.id = p.received_by
    where p.school_id = v_school
      and p.status = 'verified'
      and p.created_at::date between p_from and p_to

    union all

    -- Non-fee income: hall rent, a van hire, a book sale.
    select oi.received_on, 'income', 'Other income',
           oi.source, '-', '-', oi.method::text,
           oi.amount, 0::numeric,
           coalesce(pr.full_name, '-'),
           false
    from public.other_income oi
    left join public.profiles pr on pr.id = oi.recorded_by
    where oi.school_id = v_school
      and oi.received_on between p_from and p_to

    union all

    select e.spent_on, 'expense', coalesce(ec.name, 'Uncategorised'),
           coalesce(e.note, coalesce(ec.name, 'Expense')),
           coalesce('V' || e.voucher_no::text, '-'),
           coalesce(e.payee, '-'), e.method::text,
           0::numeric, e.amount,
           coalesce(pr.full_name, '-'),
           e.reversal_of is not null
    from public.expenses e
    left join public.expense_categories ec on ec.id = e.category_id
    left join public.profiles pr on pr.id = e.recorded_by
    where e.school_id = v_school
      and e.spent_on between p_from and p_to
  )
  select r.entry_date, r.kind, r.category, r.particulars, r.reference,
         r.party, r.method, r.debit, r.credit, r.recorded_by, r.is_reversal
  from rows_in r
  where p_kind = 'all' or r.kind = p_kind
  order by r.entry_date, r.kind desc, r.reference;
end;
$function$;

-- ---------------------------------------------------------------------------
-- 24. Search finds a challan with no month and still says whose it is.
--
-- Reproduced whole. The subtitle was the name joined to the month, and a null
-- month made the whole subtitle null.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_global_search(p_term text, p_limit integer DEFAULT 20)
 RETURNS TABLE(kind text, id uuid, title text, subtitle text, detail text, route text, exact boolean)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
 SET "TimeZone" TO 'Asia/Karachi'
AS $function$
declare
  v_school uuid := public.current_school_id();
  v_term   text := nullif(btrim(coalesce(p_term, '')), '');
  v_like   text;
  v_lim    int  := least(greatest(coalesce(p_limit, 20), 1), 100);
  v_digits text;
  v_fuzzy  boolean;
begin
  if not public.is_staff() then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  if v_term is null then return; end if;

  -- Backslash FIRST, then the wildcards, or the escapes get escaped. Getting
  -- this wrong in 0041 meant searching "%" returned the whole school.
  -- ONE backslash per escape, not two. standard_conforming_strings is ON in
  -- Postgres, so '\\' in SQL source is TWO backslash characters — which turns
  -- the pattern for "%" into "contains a literal backslash". That returns
  -- nothing, which LOOKS right, but it is right for the wrong reason: a name
  -- genuinely containing "%" is then unfindable, and a GR number like GR_001
  -- cannot be searched for either. Verified empirically, not by reading.
  v_like := '%' || replace(replace(replace(v_term, '\', '\\'),
                                   '%', '\%'), '_', '\_') || '%';
  -- Phone numbers get typed with dashes and spaces in every combination, so a
  -- digits-only comparison is the only one that reliably matches.
  v_digits := nullif(regexp_replace(v_term, '[^0-9]', '', 'g'), '');

  -- Two characters is the floor for the FUZZY branches: a single character
  -- matches most of the school and makes the box feel broken rather than fast.
  --
  -- Exact numeric lookups are exempt, and deliberately so — a receipt or
  -- enquiry numbered 1 to 9 would otherwise be permanently unfindable, which is
  -- every receipt a school writes on its first day.
  v_fuzzy := length(v_term) >= 2;
  if not v_fuzzy and v_digits is null then return; end if;

  -- The union is wrapped so the ordering can use an expression: a UNION's own
  -- ORDER BY accepts only output column names, not a CASE.
  return query
  with hits as (
  -- ---- students: everybody who can see the school may find a pupil ----
  select 'student'::text as kind, s.id, s.full_name as title,
         coalesce(c.name, 'Not enrolled')
           || case when e.roll_no is not null then ' · Roll ' || e.roll_no else '' end
           as subtitle,
         'GR ' || coalesce(s.gr_no, '-')
           || case when s.father_name is not null then ' · ' || s.father_name else '' end
           as detail,
         '/students'::text as route,
         -- coalesce is load-bearing: b_form is often NULL, so `false or NULL`
         -- is NULL, and `order by exact desc` puts NULLs FIRST in Postgres —
         -- which would sort a real GR-number match BEHIND the fuzzy ones and
         -- defeat the whole point of the ordering.
         coalesce(s.gr_no = v_term or s.b_form = v_term, false) as exact
  from public.students s
  left join public.enrollments e
         on e.student_id = s.id and e.status = 'active' and e.school_id = v_school
  left join public.classes c on c.id = e.class_id and c.school_id = v_school
  where s.school_id = v_school and s.deleted_at is null
    and ((v_fuzzy and (s.full_name ilike v_like
      or coalesce(s.gr_no, '') ilike v_like
      or coalesce(s.father_name, '') ilike v_like
      or coalesce(s.b_form, '') ilike v_like))
      or (v_digits is not null and length(v_digits) >= 4
          and regexp_replace(coalesce(s.phone, ''), '[^0-9]', '', 'g') like '%' || v_digits || '%'))

  union all
  -- ---- staff ----
  select 'staff', st.id, st.full_name,
         coalesce(st.designation, 'Staff'),
         case when st.employee_no is not null then '#' || st.employee_no else '' end
           || case when st.mobile is not null then ' · ' || st.mobile else '' end,
         '/staff', coalesce(st.employee_no = v_term or st.cnic = v_term, false)
  from public.staff st
  where st.school_id = v_school and st.deleted_at is null
    and public.may_view('owner', 'principal', 'admin_clerk', 'accountant')
    and ((v_fuzzy and (st.full_name ilike v_like
      or coalesce(st.employee_no, '') ilike v_like
      or coalesce(st.cnic, '') ilike v_like))
      or (v_digits is not null and length(v_digits) >= 4
          and regexp_replace(coalesce(st.mobile, ''), '[^0-9]', '', 'g') like '%' || v_digits || '%'))

  union all
  -- ---- families: the "I am Bilal's father" case ----
  -- Money-adjacent, so office and finance only. A teacher has no business in
  -- the family ledger.
  select 'family', f.id, coalesce(f.head_name, 'Family'),
         coalesce(nullif((select string_agg(s2.full_name, ', ' order by s2.full_name)
                          from public.students s2
                          where s2.family_id = f.id and s2.deleted_at is null), ''),
                  'No children linked'),
         coalesce(f.head_cnic, '') || case when f.phone is not null then ' · ' || f.phone else '' end,
         '/families', coalesce(f.head_cnic = v_term, false)
  from public.families f
  where f.school_id = v_school
    and public.may_view('owner', 'principal', 'admin_clerk', 'accountant')
    and ((v_fuzzy and (coalesce(f.head_name, '') ilike v_like
      or coalesce(f.head_cnic, '') ilike v_like))
      or (v_digits is not null and length(v_digits) >= 4
          and regexp_replace(coalesce(f.phone, ''), '[^0-9]', '', 'g') like '%' || v_digits || '%'))

  union all
  -- ---- a printed challan, by its voucher code ----
  -- The code on the slip a parent hands over. Exact only: a partial voucher
  -- match is meaningless and would bury the real answers.
  select 'challan', i.id,
         'Challan ' || i.voucher_code,
         coalesce(s.full_name, 'Unknown student')
           || ' · ' || coalesce(to_char(i.period_month, 'Mon YYYY'),
                                public.fn__one_off_label(i.label, i.notes)),
         case when i.status = 'void' then 'Cancelled' else initcap(i.status::text) end
           || case when i.due_date is not null
                   then ' · due ' || to_char(i.due_date, 'DD Mon') else '' end,
         '/fees', true
  from public.invoices i
  left join public.students s on s.id = i.student_id and s.school_id = v_school
  where i.school_id = v_school
    and public.may_view('owner', 'principal', 'admin_clerk', 'accountant')
    and i.voucher_code is not null
    and upper(i.voucher_code) = upper(v_term)

  union all
  -- ---- a receipt, by its number ----
  select 'receipt', p.id,
         'Receipt #' || p.receipt_no,
         coalesce(s.full_name, fam.head_name, 'Unknown payer'),
         trim(to_char(p.amount, 'FM999,999,990')) || ' · ' || to_char(p.created_at, 'DD Mon YYYY'),
         '/fees', true
  from public.payments p
  left join public.students s on s.id = p.student_id and s.school_id = v_school
  left join public.families fam on fam.id = p.family_id and fam.school_id = v_school
  where p.school_id = v_school
    and public.may_view('owner', 'principal', 'admin_clerk', 'accountant')
    and v_digits is not null and p.receipt_no::text = v_digits

  union all
  -- ---- an admission enquiry ----
  select 'enquiry', en.id, en.child_name,
         'Enquiry #' || en.enquiry_no || ' · ' || en.status::text,
         coalesce(en.father_name, '') || case when en.phone is not null
                                              then ' · ' || en.phone else '' end,
         '/enquiries', coalesce(en.enquiry_no::text = v_digits, false)
  from public.admission_enquiries en
  where en.school_id = v_school
    and public.may_view('owner', 'principal', 'admin_clerk')
    and ((v_fuzzy and (en.child_name ilike v_like
      or coalesce(en.father_name, '') ilike v_like))
      or en.enquiry_no::text = v_digits
      or (v_digits is not null and length(v_digits) >= 4
          and regexp_replace(coalesce(en.phone, ''), '[^0-9]', '', 'g') like '%' || v_digits || '%'))

  )
  -- An exact identifier match is almost always what was typed, so it goes
  -- first. After that, students before everything else: they are what a school
  -- looks up all day.
  select h.kind, h.id, h.title, h.subtitle, h.detail, h.route, h.exact
  from hits h
  order by h.exact desc,
           case h.kind when 'student' then 0 when 'family' then 1 when 'challan' then 2
                       when 'receipt' then 3 when 'staff' then 4 else 5 end,
           h.title
  limit v_lim;
end;
$function$;

-- ---------------------------------------------------------------------------
-- 25. Did it take?
--
-- A WARNING and not an exception, for the reason recorded in 0100: a bundle
-- runs as ONE transaction and raising here would revert everything else in it.
-- supabase/tests/what_was_owed_before.sql walks it as real logins.
-- ---------------------------------------------------------------------------
do $assert$
declare v_bad text[] := '{}';
begin
  if to_regprocedure('public.fn_record_dues(uuid,jsonb)') is null then
    v_bad := v_bad || 'fn_record_dues is missing';
  end if;
  if to_regprocedure('public.fn_student_dues(uuid)') is null then
    v_bad := v_bad || 'fn_student_dues is missing';
  end if;
  if to_regprocedure('public.fn__record_dues(uuid,uuid,jsonb)') is null then
    v_bad := v_bad || 'fn__record_dues is missing';
  end if;
  if to_regclass('public.rde_saves') is null then
    v_bad := v_bad || 'rde_saves is missing';
  end if;
  if not exists (select 1 from information_schema.columns
                  where table_schema = 'public' and table_name = 'invoices'
                    and column_name = 'carried_kind') then
    v_bad := v_bad || 'invoices.carried_kind is missing';
  end if;
  if not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                  where n.nspname = 'public' and p.proname = 'fn_rde_add_students'
                    and p.prosrc like '%fn__record_dues%'
                    and p.prosrc like '%request_id%') then
    v_bad := v_bad || 'fn_rde_add_students still pays the oldest due first';
  end if;
  if not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                  where n.nspname = 'public' and p.proname = 'fn_reprice_student'
                    and p.prosrc like '%carried_kind is null%') then
    v_bad := v_bad || 'fn_reprice_student still discounts a typed due';
  end if;
  if not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                  where n.nspname = 'public' and p.proname = 'fn_bill_month'
                    and p.prosrc like '%carried_kind is null%') then
    v_bad := v_bad || 'fn_bill_month still discounts a typed due';
  end if;
  if array_length(v_bad, 1) > 0 then
    raise warning '0153 did not fully apply: %', array_to_string(v_bad, '; ');
  end if;
end $assert$;

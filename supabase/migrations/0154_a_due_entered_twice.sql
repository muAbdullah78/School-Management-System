-- =============================================================================
-- 0154. A due entered twice.
--
-- 0153 refused a named due when the child already had one with the same name
-- and amount, ever. That was meant to catch a save pressed twice, and it also
-- refused the real thing: a second picnic in the spring, next term's books at
-- the same price, or two identical lines a clerk typed into one save on
-- purpose. Only a due entered by an EARLIER save in the last ten minutes is
-- now taken as a retry. Rapid entry's own retries are already answered once
-- by its request id; this window covers a child's page, which has none.
--
-- fn__record_dues is reproduced whole from the catalogue with that one change.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.fn__record_dues(p_student_id uuid, p_enrollment_id uuid, p_dues jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
 SET "TimeZone" TO 'Asia/Karachi'
AS $function$
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
        -- 0154. A RETRY, NOT A SECOND DEBT. The same due entered again within
        -- ten minutes by an EARLIER save is a save pressed twice or an answer
        -- lost on the way back. Older than that it is a new due (a second
        -- picnic, next term's books) and is recorded, and two identical lines
        -- in one save are what the clerk typed, so both go in.
        elsif exists (
                select 1 from public.invoices i
                  join public.invoice_lines l on l.invoice_id = i.id and not l.is_discount
                 where i.school_id = v_school and i.student_id = p_student_id
                   and i.status <> 'void' and i.period_month is null
                   and i.carried_kind = v_kind
                   and lower(i.label) = lower(v_label)
                   and l.amount = v_amt
                   and i.created_at < now()
                   and i.created_at > now() - interval '10 minutes') then
          v_status := 'skipped';
          v_msg := format('%s of Rs %s was entered a few minutes ago, so this looks '
                          'like the same save twice and it was not added again.',
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
$function$;

revoke all on function public.fn__record_dues(uuid, uuid, jsonb) from public, anon, authenticated;

do $assert$
begin
  if not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                  where n.nspname = 'public' and p.proname = 'fn__record_dues'
                    and p.prosrc like '%10 minutes%') then
    raise warning '0154 did not fully apply: fn__record_dues still refuses a repeated due for ever';
  end if;
end $assert$;

-- =============================================================================
-- 0141  The counter could not see the discount
--
-- TWO SCREENS SHOW THE SAME CHILD'S FEE AND THEY DO NOT SHOW THE SAME THING.
--
-- Open a child from Students and the Fees tab says: September 2026, not paid,
-- Rs 2,700 charged. Monthly fee (Class 1) Rs 2,700, with Rs 4,500 struck
-- through. Discount on fee: Hardship, 40 per cent, "Hard Core", from Sept 2026,
-- ongoing, in force.
--
-- Open the same child at the counter, which is where the money is actually
-- taken, and the entire card reads:
--
--     Abdullah Dar   GR 0001                            Rs 2,700
--     Sept 2026                                         Rs 2,700
--
-- That is the whole of it. Not the class, so a clerk cannot tell a Class 1 fee
-- from a Class 9 one and cannot notice they have opened the wrong Abdullah. Not
-- the fee before the concession, so Rs 2,700 looks like the price of Class 1 and
-- the next parent is quoted it. Not the concession, so nobody at the window can
-- answer "why is my brother charged more", and nobody can see that the 40 per
-- cent is still running six months after the reason for it ended. Not whether
-- this month is paid, only a number that mixes this month with four earlier
-- ones.
--
-- A school does not run its fee desk out of the Students module. It runs it at
-- the counter, and the counter was the screen that knew least.
--
-- WHY THE ANSWER IS NOT "COPY THE QUERY ACROSS". Copying is how the two screens
-- came to disagree in the first place. fn_family_sheet worked out its own
-- figures from invoice_balances while the child's page asked
-- fn_student_fee_for_month, and a second definition of the same number is a
-- second number waiting to be different. So the sheet now CALLS the functions
-- the child's page calls. It cannot disagree with them, because it is them.
--
-- WHAT fn_student_fee_for_month GAINS. It already knew which enrolment covers
-- the month asked about, because a fee is a class's fee and a child changes
-- class; it just kept that to itself and returned four numbers. It now says
-- which class, section and roll the answer is FOR. That removes the reason
-- anybody else would ever re-derive it, which is the whole point, and it fixes a
-- quieter fault on the child's page as well: the "Monthly fee (Class 1)" label
-- was read from the CURRENT enrolment, so asking what last April cost printed
-- last April's money under this year's class name.
--
-- The no-enrolment path returned an object with no 'month' key at all, so a
-- caller reading it got a null month for a child with no enrolment and no way
-- to tell that from a missing read. It returns the full shape now, with nulls.
-- =============================================================================

-- =================================== 1. what a month costs, and for which class
-- Reproduced whole. 0140's note applies: a fee function this batch touches is
-- retyped complete with the live roles, not string-patched, because a text patch
-- anchored on a line a later migration removes is what took bundle 7 down.
create or replace function public.fn_student_fee_for_month(p_student_id uuid, p_month date)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_school uuid := public.current_school_id();
  v_month  date := date_trunc('month', coalesce(p_month, public.fn__karachi_month()))::date;
  v_enr    record;
  v_gross  numeric := 0;
  v_disc   numeric := 0;
  v_room   numeric;
  v_rec    record;
  v_amt    numeric;
  v_lines  jsonb := '[]'::jsonb;
begin
  if not public.may_view('owner', 'principal', 'readonly') then
    raise exception 'Not permitted to view fee records' using errcode = '42501';
  end if;
  perform public.assert_own('students', p_student_id);

  -- THE ENROLMENT THAT COVERS THE MONTH ASKED ABOUT, not the current one. The
  -- first draft ordered by is_current and answered every question with this
  -- year's class and this year's fee, so asking what next September costs
  -- returned this September's answer. The test caught it: a 25 per cent waiver
  -- came back as Rs 1,000 of a Rs 4,000 fee when next year's fee is Rs 4,500.
  --
  -- The class, section and roll come out with it now. Every caller that wants to
  -- print "Monthly fee (Class 1)" beside this figure needs to know WHICH class
  -- the figure is for, and the only two that existed were both reading the
  -- current enrolment instead, which is a different question with the same
  -- answer eleven months in twelve.
  select e.id, e.session_id, e.class_id, e.roll_no,
         c.name as class_name, sec.name as section_name
    into v_enr
    from public.enrollments e
    join public.academic_sessions s on s.id = e.session_id
    join public.classes c on c.id = e.class_id
    left join public.sections sec on sec.id = e.section_id
   where e.student_id = p_student_id and e.status = 'active'
     and date_trunc('month', s.starts_on)::date <= v_month
     and date_trunc('month', s.ends_on)::date   >= v_month
   order by s.starts_on desc
   limit 1;
  -- Asked about a month in no session at all (before the child joined, or after
  -- the last year on record), fall back to the nearest year so the screen shows
  -- a number rather than a blank.
  if not found then
    select e.id, e.session_id, e.class_id, e.roll_no,
           c.name as class_name, sec.name as section_name
      into v_enr
      from public.enrollments e
      join public.academic_sessions s on s.id = e.session_id
      join public.classes c on c.id = e.class_id
      left join public.sections sec on sec.id = e.section_id
     where e.student_id = p_student_id and e.status = 'active'
     -- abs(date - date), which is a count of DAYS. This line read
     -- abs(extract(epoch from (s.starts_on - v_month))) until 0141 and that is
     -- not a working expression: subtracting one date from another in Postgres
     -- gives an INTEGER, and extract(epoch from <integer>) does not exist. The
     -- whole branch raised
     --
     --     function pg_catalog.extract(unknown, integer) does not exist
     --
     -- the moment it was reached. Nothing reached it, because PL/pgSQL does not
     -- parse a statement until it runs one and every test had an enrolment whose
     -- session covered the month. It shipped in bundle 41. A child between two
     -- sessions, or one enrolled only for next year, would have crashed their
     -- own Fees tab, and it surfaced here only because the family sheet now asks
     -- this question for every child in a family rather than for one child the
     -- caller had already chosen.
     order by abs(s.starts_on - v_month), s.starts_on desc
     limit 1;
  end if;
  -- THE FULL SHAPE, with nulls. This used to return four keys and no 'month',
  -- so a caller that read the month back could not tell "this child has no
  -- enrolment" from "the read did not happen".
  if not found then
    return jsonb_build_object('month', v_month, 'gross', 0, 'discount', 0, 'net', 0,
                              'lines', '[]'::jsonb, 'enrollment_id', null,
                              'session_id', null, 'class_id', null, 'class_name', null,
                              'section_name', null, 'roll_no', null);
  end if;

  select coalesce(sum(coalesce(sfi.amount, amt.amount)), 0) into v_gross
    from public.fee_heads fh
    join lateral (
           select fs.amount from public.fee_structures fs
            where fs.school_id = v_school and fs.session_id = v_enr.session_id
              and fs.class_id = v_enr.class_id and fs.fee_head_id = fh.id
              and fs.effective_from <= v_month
            order by fs.effective_from desc limit 1) amt on true
    left join public.student_fee_items sfi
      on sfi.student_id = p_student_id and sfi.fee_head_id = fh.id and sfi.active
   where fh.school_id = v_school and fh.is_recurring and fh.active;

  v_room := v_gross;
  for v_rec in select * from public.fn__discounts_live(p_student_id, v_month) loop
    exit when v_room <= 0;
    v_amt := case when v_rec.is_percent then round(v_gross * v_rec.amount / 100.0, 2)
                  else v_rec.amount end;
    v_amt := least(v_amt, v_room);
    if v_amt > 0 then
      v_disc := v_disc + v_amt;
      v_room := v_room - v_amt;
      v_lines := v_lines || jsonb_build_array(jsonb_build_object(
        'discount_id', v_rec.id, 'type', v_rec.type, 'amount', v_amt,
        'is_percent', v_rec.is_percent, 'rate', v_rec.amount, 'reason', v_rec.reason));
    end if;
  end loop;

  return jsonb_build_object('month', v_month, 'gross', v_gross,
                            'discount', v_disc, 'net', v_gross - v_disc, 'lines', v_lines,
                            'enrollment_id', v_enr.id, 'session_id', v_enr.session_id,
                            'class_id', v_enr.class_id, 'class_name', v_enr.class_name,
                            'section_name', v_enr.section_name, 'roll_no', v_enr.roll_no);
end;
$$;
revoke all on function public.fn_student_fee_for_month(uuid, date) from public, anon;
grant execute on function public.fn_student_fee_for_month(uuid, date) to authenticated;

-- ============================================ 2. the sheet the counter reads ==
-- STABLE now, and that is not a tidy-up. check-readonly-writes.py refuses
-- may_view() inside a VOLATILE function, for the good reason that may_view lets
-- a readonly login through and a volatile function may write. This one reads
-- and nothing else, everything it calls is stable, and saying so is what lets
-- the gate below be the same gate the rest of the fee module uses.
--
-- admin_clerk and accountant come out of that gate. 0133 withdrew both and added
-- a check constraint that makes the values unreachable, so no profile can hold
-- one; and the functions this now calls refuse them anyway, so leaving the names
-- here would only describe a door that is already bricked up.
create or replace function public.fn_family_sheet(p_family_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
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
        'invoices',   coalesce((
          select jsonb_agg(jsonb_build_object(
            'invoice_id',   b.invoice_id,
            'period_month', i.period_month,
            'due_date',     i.due_date,
            'charge',       b.charge,
            'allocated',    b.allocated,
            'outstanding',  b.charge - b.allocated,
            'status',       b.status
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
$$;
revoke all on function public.fn_family_sheet(uuid) from public, anon;
grant execute on function public.fn_family_sheet(uuid) to authenticated;

-- ================================================ 3. the discount register ===
-- THE SCHOOL-WIDE LIST WAS STILL READING THE MODEL 0138 REPLACED. The screen
-- fetched it straight from PostgREST as
--
--     discounts ... enrollments!inner(students(full_name, gr_no), classes(name))
--
-- and an inner join on enrollments does two wrong things at once now that
-- enrollment_id is nullable and carries no meaning. A concession granted to a
-- child with no active enrolment has a null there and DISAPPEARS FROM THE
-- REGISTER, silently, while still coming off every challan. And the class it
-- prints is the class of the enrolment the discount was recorded against, which
-- after one rollover is last year's.
--
-- It showed no dates and no in-force state either, so a waiver that ended in
-- March still read "approved" with a Revoke button beside it, and there was no
-- way to see, for the whole school, which concessions are actually running this
-- month. That is the one question a head asks of this list.
--
-- 'live' is the same rule fn__discounts_live applies when pricing a month:
-- approved, started on or before the month, not ended before it. Written once
-- there, asserted here against it in the suite, rather than recomputed in a
-- browser out of three columns.
drop function if exists public.fn_discounts_register(boolean);
create or replace function public.fn_discounts_register(p_live_only boolean default false)
returns table(
  id uuid, student_id uuid, student_name text, gr_no text,
  class_name text, section_name text,
  type text, amount numeric, is_percent boolean, reason text,
  status text, starts_on date, ends_on date,
  live boolean, created_at timestamptz,
  proposed_by text, approved_by text
) language plpgsql stable security definer set search_path = public as $$
declare v_month date := public.fn__karachi_month();
begin
  -- RAISES rather than returning nothing. A gate written into the WHERE clause
  -- hands an unauthorised caller an empty list, and "No discounts yet" is a
  -- sentence about the school, not about permission.
  if not public.may_view('owner', 'principal', 'readonly') then
    raise exception 'Not permitted to view fee records' using errcode = '42501';
  end if;
  return query
  select d.id, d.student_id, s.full_name, s.gr_no,
         c.name, sec.name,
         d.type::text, d.amount, d.is_percent, d.reason,
         d.status::text, d.starts_on, d.ends_on,
         (d.status = 'approved' and d.starts_on <= v_month
          and (d.ends_on is null or d.ends_on >= v_month)),
         d.created_at,
         coalesce(pb.full_name, '-'), coalesce(ab.full_name, '-')
    from public.discounts d
    join public.students s on s.id = d.student_id
    -- LEFT, and through the CURRENT session. A child between years keeps their
    -- row in the register with an empty class rather than vanishing from it.
    left join public.enrollments e
      on e.student_id = s.id and e.status = 'active'
     and e.session_id = (select ss.current_session_id from public.school_settings ss
                          where ss.school_id = d.school_id)
    left join public.classes c on c.id = e.class_id
    left join public.sections sec on sec.id = e.section_id
    left join public.profiles pb on pb.id = d.created_by
    left join public.profiles ab on ab.id = d.approved_by
   where d.school_id = public.current_school_id()
     and (not coalesce(p_live_only, false)
          or (d.status = 'approved' and d.starts_on <= v_month
              and (d.ends_on is null or d.ends_on >= v_month)))
   -- Anything waiting on a decision first, then newest.
   order by (d.status = 'pending') desc, d.created_at desc, d.id;
end;
$$;
revoke all on function public.fn_discounts_register(boolean) from public, anon;
grant execute on function public.fn_discounts_register(boolean) to authenticated;

-- ========================================= 4. the report that counted twice ==
-- MEASURED, NOT SUSPECTED. On a test database with one concession and one
-- child:
--
--     one session                 fn_report_discounts returns 1 row
--     after a second enrolment    fn_report_discounts returns 2 rows
--
-- 0138 moved this report onto the child correctly and then left the class join
-- as `enrollments e on e.student_id = d.student_id and e.status = 'active'`,
-- with nothing pinning it to a session. A child has one active enrolment per
-- year, so the first rollover fans every discount out into one row PER YEAR the
-- child has been at the school. The screen lists each concession twice, three
-- times the year after, and a head reading "money the school chose not to
-- collect" is reading a number that is wrong by a multiple. The React table
-- gives both copies the same key as well, because the key is built from student,
-- date, type and amount, and all four match.
--
-- THE RETURN TYPE DOES NOT CHANGE, AND THAT IS NOT A STYLE CHOICE. The first
-- draft of this section added starts_on, ends_on and live, which needs a drop
-- because create or replace refuses a new return type. Preflight caught what
-- that does:
--
--     a bundle a school is told to re-run cannot be re-run   FAIL
--       4_operations.sql:  cannot change return type of existing function
--       41_the_fee_module: cannot change return type of existing function
--
-- 0044 and 0138 both define this function with create or replace and the old
-- shape. Once a database carries the new shape, neither of those bundles can be
-- applied again, and a bundle is ONE transaction so the whole file rolls back.
-- verify.sql tells a school to re-run bundles by name, so that is a repair path
-- that dead-ends. It is the same trap 0085 and 0135 recorded.
--
-- The months a concession covers are on fn_discounts_register above, which is
-- new and free to have any shape it likes, and on the child's own page. 0138's
-- comment inside this function claimed the report showed them while the return
-- type had no such column, so the claim is corrected here rather than left to
-- mislead the next person.
create or replace function public.fn_report_discounts(p_from date, p_to date)
returns table(
  granted_on date, student_id uuid, student_name text, gr_no text, class_name text,
  reason_type text, is_percent boolean, amount numeric, reason text, status text,
  proposed_by text, approved_by text, approved_at timestamptz
) language plpgsql stable security definer set search_path = public as $$
declare v_school uuid := public.current_school_id();
begin
  if not public.may_view('owner', 'principal', 'readonly') then
    raise exception 'Not permitted to read discounts' using errcode = '42501';
  end if;

  -- 0138 MOVED THE KEY FROM THE ENROLMENT TO THE CHILD. The paragraph that stood
  -- here argued the opposite, that scoping a discount to one session was correct
  -- because last year's hardship waiver should not silently continue. The
  -- argument was sound and the code did not implement it: nothing asked the
  -- school at rollover, the waiver just stopped, in silence, for every family at
  -- once. A discount now ends when somebody ends it.
  --
  -- That paragraph also said this report "shows the months it covered so that
  -- ending is visible", and it did not: there is no such column in the type
  -- above and there cannot be one without breaking two frozen bundles. The
  -- months are on fn_discounts_register and on the child's page. Fees →
  -- Discounts is where a head asks what is running this month.
  return query
  select d.created_at::date, s.id, s.full_name, s.gr_no, c.name,
         d.type::text, d.is_percent, d.amount, d.reason, d.status::text,
         coalesce(pb.full_name, '-'), coalesce(ab.full_name, '-'), d.approved_at
  from public.discounts d
  join public.students s on s.id = d.student_id
  -- PINNED TO THE CURRENT SESSION. Without this the join matches one row per
  -- year the child has been enrolled and the whole report multiplies.
  left join public.enrollments e
    on e.student_id = d.student_id and e.status = 'active'
   and e.session_id = (select ss.current_session_id from public.school_settings ss
                        where ss.school_id = d.school_id)
  left join public.classes c on c.id = e.class_id
  left join public.profiles pb on pb.id = d.created_by
  left join public.profiles ab on ab.id = d.approved_by
  where d.school_id = v_school
    and s.deleted_at is null
    and (p_from is null or d.created_at::date >= p_from)
    and (p_to   is null or d.created_at::date <= p_to)
  order by d.created_at desc, d.id;
end;
$$;
revoke all on function public.fn_report_discounts(date, date) from public, anon;
grant execute on function public.fn_report_discounts(date, date) to authenticated;

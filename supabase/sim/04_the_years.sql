-- =============================================================================
-- SIMULATION, PART 4: three academic years, in order, one month at a time.
--
-- WHY THIS FILE EXISTS IN THIS SHAPE, AND IT IS THE MAIN LESSON OF THE RUN
--
-- The first version of this simulation seeded module by module: all the
-- students, then all the attendance, then all the billing. It produced 3.4
-- children per section-day across two years and looked like a school with
-- nobody in it. The reason is structural and worth writing down: an enrollment
-- exists in ONE session, and the only thing that creates next year's enrollment
-- is fn_rollover. Seed the modules in parallel and every year except the one
-- the children were admitted into is empty.
--
-- So the simulation walks the calendar instead. Set the current session, raise
-- the fees, take the year's enquiries and convert some of them, bill each month
-- and collect against it, then roll the whole school forward and do it again.
-- That is also the order a real school does it in, which is why it is the only
-- order that produces data a real report can read.
--
-- WHAT IS DELIBERATELY IMPERFECT. Roughly one family in seven does not pay in
-- a given month, a tenth of payments are short, some invoices attract a late
-- fine and a few of those fines are waived. A school where every challan is
-- paid in full on time has no defaulter list, no ageing, no reconciliation gap
-- and nothing for the fee reports to be right or wrong about.
--
-- Run: psql -v ON_ERROR_STOP=1 -f supabase/sim/04_the_years.sql
-- =============================================================================

\set ON_ERROR_STOP on

begin;

select set_config('request.jwt.claims',
  jsonb_build_object('sub', p.id::text, 'role','authenticated')::text, true)
from public.profiles p join public.schools s on s.id = p.school_id
where s.name = 'Chaudhary Puclix High School Ghauriii'
  and p.role = 'owner' and p.active limit 1;
set local role authenticated;

-- Name pools again: this file admits children too, and a temp table dropped on
-- commit cannot be shared across files.
create temp table sim_boy(n text) on commit drop;
insert into sim_boy(n) values
 ('Ahmed'),('Hamza'),('Bilal'),('Usman'),('Zain'),('Hassan'),('Hussain'),('Umar'),
 ('Talha'),('Saad'),('Ibrahim'),('Ali'),('Abdullah'),('Ayan'),('Rayyan'),('Arham'),
 ('Shahzaib'),('Faizan'),('Danish'),('Salman'),('Adnan'),('Waleed'),('Zohaib'),
 ('Noman'),('Kashif'),('Junaid'),('Asad'),('Fahad'),('Rehan'),('Sufyan');
create temp table sim_girl(n text) on commit drop;
insert into sim_girl(n) values
 ('Ayesha'),('Fatima'),('Maryam'),('Zainab'),('Khadija'),('Hafsa'),('Amna'),
 ('Iqra'),('Sana'),('Hira'),('Rabia'),('Nimra'),('Areeba'),('Laiba'),('Eman'),
 ('Aleena'),('Zoya'),('Mahnoor'),('Anaya'),('Iman'),('Alishba'),('Kinza'),
 ('Mehak'),('Sidra'),('Tayyaba'),('Warda'),('Nida'),('Saba'),('Bushra');
create temp table sim_fam(n text) on commit drop;
insert into sim_fam(n) values
 ('Chaudhary'),('Malik'),('Khan'),('Butt'),('Awan'),('Gujjar'),('Rajput'),
 ('Qureshi'),('Sheikh'),('Mughal'),('Abbasi'),('Satti'),('Janjua'),('Kiyani'),
 ('Bhatti'),('Cheema'),('Sandhu'),('Warraich'),('Dar'),('Mir'),('Baig'),
 ('Durrani'),('Yousafzai'),('Afridi'),('Soomro'),('Memon'),('Ansari'),
 ('Siddiqui'),('Farooqi'),('Zaidi'),('Naqvi'),('Rizvi');
create temp table sim_dad(n text) on commit drop;
insert into sim_dad(n) values
 ('Muhammad Aslam'),('Abdul Rehman'),('Ghulam Nabi'),('Muhammad Akram'),
 ('Zafar Iqbal'),('Nasir Mahmood'),('Shahid Anwar'),('Riaz Ahmed'),
 ('Tanveer Abbas'),('Mushtaq Ali'),('Sajjad Haider'),('Khalid Pervaiz'),
 ('Muhammad Yousaf'),('Rashid Minhas'),('Amjad Hussain'),('Liaqat Ali'),
 ('Muhammad Shafiq'),('Ijaz Ahmad'),('Sabir Hussain'),('Manzoor Elahi'),
 ('Sarfraz Khan'),('Iftikhar Ahmed'),('Tahir Mehmood'),('Javed Iqbal');
create temp table sim_mum(n text) on commit drop;
insert into sim_mum(n) values
 ('Naseem Akhtar'),('Parveen Bibi'),('Shamim Akhtar'),('Razia Sultana'),
 ('Nasreen Begum'),('Zubaida Khatoon'),('Rukhsana Kausar'),('Shahnaz Bibi'),
 ('Tahira Bano'),('Farzana Kausar'),('Rehana Kausar'),('Sajida Parveen');

do $sim$
declare
  v_school  uuid := public.current_school_id();
  v_ses     record;
  v_next    uuid;
  v_month   date;
  v_cls     record;
  v_fam     record;
  v_inv     record;
  v_seq     int;
  v_i       int;
  v_boy     boolean;
  v_first   text; v_surname text; v_dad text; v_mum text; v_cnic text; v_phone text;
  v_lvl     int; v_class uuid; v_section uuid;
  v_enq     jsonb; v_enq_id uuid; v_admit date; v_dob date;
  v_intake  int;
  v_due     numeric;
  v_pay     numeric;
  v_method  public.payment_method;
  v_res     jsonb;
  v_nboy int; v_ngirl int; v_nfam int; v_ndad int; v_nmum int;
  v_gen int := 0; v_paid int := 0; v_fined int := 0; v_disc int := 0;
  v_chronic boolean;
  v_enq_made int := 0; v_adm int := 0; v_left int := 0;
  v_cat_sal uuid; v_cat_util uuid; v_cat_rent uuid; v_cat_stat uuid; v_cat_maint uuid;
  v_head_dep uuid;
  v_roll jsonb;
begin
  if v_school is null then raise exception 'No owner session.'; end if;

  select count(*) into v_nboy from sim_boy;   select count(*) into v_ngirl from sim_girl;
  select count(*) into v_nfam from sim_fam;   select count(*) into v_ndad  from sim_dad;
  select count(*) into v_nmum from sim_mum;

  select id into v_cat_sal   from public.expense_categories where school_id=v_school and name='Salaries';
  select id into v_cat_util  from public.expense_categories where school_id=v_school and name='Utilities';
  select id into v_cat_rent  from public.expense_categories where school_id=v_school and name='Rent';
  select id into v_cat_stat  from public.expense_categories where school_id=v_school and name='Stationery';
  select id into v_cat_maint from public.expense_categories where school_id=v_school and name='Maintenance';
  select id into v_head_dep  from public.fee_heads where school_id=v_school and name='Security Deposit';

  -- The pool index for new children continues where the opening roll stopped.
  v_seq := 120;

  for v_ses in
    select id, name, starts_on, ends_on from public.academic_sessions
     where school_id = v_school and ends_on >= date '2024-02-01'
       and starts_on <= current_date
     order by starts_on
  loop
    raise notice '--- session % (% to %) ---', v_ses.name, v_ses.starts_on, v_ses.ends_on;
    perform public.fn_set_current_session(v_ses.id);

    -- ===== 1. The annual fee increase ======================================
    -- Skipped for 2023-2024, whose sheet 02 wrote directly: a school does not
    -- raise fees in the middle of a year it did not start with us.
    if v_ses.name <> '2023-2024' then
      perform public.fn_fee_increment(
        v_ses.id,
        (select array_agg(id) from public.classes where school_id=v_school),
        (select array_agg(id) from public.fee_heads
          where school_id=v_school and name in ('Monthly Tuition','Annual Charges','Transport')),
        10, null, v_ses.starts_on, true);
      raise notice '  fee increment applied for %', v_ses.name;
    end if;

    -- ===== 2. This year's enquiries, and the ones that converted ============
    -- Every new child arrives as an enquiry first, with a follow-up logged,
    -- because that is the pipeline the Enquiries screen reports on. Roughly
    -- three enquiries per admission, which is a believable conversion rate for
    -- a school of this size, and it leaves lost and contacted enquiries behind
    -- for fn_enquiry_summary to count.
    v_intake := case v_ses.name
      when '2023-2024' then 6      -- February and March only
      when '2024-2025' then 45
      when '2025-2026' then 50
      else 45 end;

    for v_i in 1..(v_intake * 3) loop
      v_seq := v_seq + 1;
      v_boy := (v_seq % 100) < 54;
      v_first := case when v_boy
        then (select n from sim_boy  offset ((v_seq * 7) % v_nboy)  limit 1)
        else (select n from sim_girl offset ((v_seq * 11) % v_ngirl) limit 1) end;
      -- Reuse CNICs 1..70 for the later arrivals so siblings appear across
      -- years, which is what 03 stopped short of.
      v_cnic  := '61101-' || lpad((3000000 + (((v_seq - 120) % 70) + 1))::text, 7, '0')
                 || '-' || ((v_seq % 9) + 1)::text;
      v_surname := (select n from sim_fam offset ((v_seq * 5) % v_nfam) limit 1);
      v_dad   := (select n from sim_dad offset ((v_seq * 3) % v_ndad) limit 1);
      v_mum   := (select n from sim_mum offset ((v_seq * 13) % v_nmum) limit 1);
      -- ::bigint, because v_seq * 7654321 crosses 2^31 at v_seq = 281, which
      -- lands inside the third year's intake: an overflow that only appears
      -- after two simulated years is exactly the kind this run exists to find.
      v_phone := '03' || lpad(((v_seq::bigint * 7654321) % 100000000)::text, 9, '0');

      -- New intake is bottom-heavy: Nursery to Class 5, which is where a
      -- growing school actually grows.
      v_lvl := ((v_seq * 3) % 7) + 1;
      select id into v_class from public.classes where school_id=v_school and level_order=v_lvl;

      v_admit := greatest(v_ses.starts_on, date '2024-02-01')
                 + ((v_seq * 11) % greatest(1, least(
                     (least(v_ses.ends_on, current_date)
                      - greatest(v_ses.starts_on, date '2024-02-01'))::int, 300)));
      if v_admit > current_date then v_admit := current_date; end if;
      v_dob := (date_trunc('year', v_admit)::date - ((v_lvl + 3) * 365)) + ((v_seq * 29) % 365);

      v_enq := public.fn_add_enquiry(jsonb_build_object(
        'child_name',   v_first || ' ' || v_surname,
        'father_name',  v_dad,
        'father_cnic',  v_cnic,
        'phone',        v_phone,
        'whatsapp',     v_phone,
        'address',      'House ' || (10 + (v_seq % 300))::text || ', Ghauri Town, Islamabad',
        'dob',          v_dob,
        'gender',       case when v_boy then 'male' else 'female' end,
        'session_id',   v_ses.id,
        'class_id',     v_class,
        'class_wanted', (select name from public.classes where id = v_class),
        'source',       (array['walk_in','phone','referral','banner','social_media','other'])
                          [((v_seq % 6) + 1)],
        'source_note',  case when (v_seq % 6) = 2 then 'Referred by an existing parent' else null end,
        'follow_up_on', v_admit - 3,
        'notes',        'Asked about the van route and the fee structure.'
      ));
      -- 'enquiry_id', not 'id'. fn_add_enquiry returns enquiry_id alongside a
      -- possible_duplicate warning and whether it queued a WhatsApp, and the
      -- first draft read the wrong key and got "Enquiry not found" from the
      -- very next call.
      v_enq_id := (v_enq->>'enquiry_id')::uuid;
      v_enq_made := v_enq_made + 1;

      perform public.fn_log_enquiry_contact(
        v_enq_id,
        case when (v_seq % 3) = 0 then 'called, interested'
             when (v_seq % 3) = 1 then 'visited the school'
             else 'called, no answer' end,
        'Spoke to the father.', v_admit - 1);

      -- One in three converts. The rest stay contacted or are marked lost,
      -- which is what gives the pipeline a shape.
      if (v_i % 3) = 1 then
        v_mum := v_mum;  -- (kept: mother's name goes on the admission, not the enquiry)
        select id into v_section from public.sections
         where class_id = v_class order by sort_order
         offset ((v_seq) % (select count(*) from public.sections where class_id=v_class)) limit 1;
        begin
          -- fn_enquiry_admit, NOT fn_admit_student, and the difference is not
          -- cosmetic. fn_set_enquiry_status refuses the value 'admitted'
          -- outright -- "Use fn_enquiry_admit to admit, it creates the student
          -- record too" -- because an enquiry marked admitted with no student
          -- behind it is a lie the Enquiries screen would then report. So the
          -- conversion is one call that builds the payload from the enquiry,
          -- admits the child, and writes admitted_student_id back.
          --
          -- The first draft called fn_admit_student and then tried to set the
          -- status, which admitted 150 children and then reported every one of
          -- them as a failure, because the exception handler around both could
          -- not tell which half had thrown. The guard was right and the seed
          -- was wrong; the error message named the function to use, which is
          -- how it was found in one reading.
          v_res := public.fn_enquiry_admit(v_enq_id, jsonb_build_object(
            'mother_name',    v_mum,
            'section_id',     v_section,
            'admission_date', v_admit,
            'b_form',         '61101-' || lpad((7000000 + v_seq)::text, 7, '0') || '-' || ((v_seq % 9) + 1)::text,
            'whatsapp',       v_phone,
            'admission_fee',  jsonb_build_object('charged', (v_seq % 11) <> 0)
          ));
          v_adm := v_adm + 1;
          -- A security deposit on about half the new admissions, which is what
          -- gives fn_deposits_held and the balance sheet something to hold.
          if (v_seq % 2) = 0 then
            perform public.fn_charge_deposit(
              (v_res->>'student_id')::uuid, v_head_dep, 1000, v_admit + 14,
              'Refundable security deposit at admission');
          end if;
        exception when others then
          raise notice '  conversion failed for %: %', v_first || ' ' || v_surname, sqlerrm;
        end;
      elsif (v_i % 3) = 2 then
        perform public.fn_set_enquiry_status(v_enq_id, 'contacted', null, v_admit + 10);
      else
        perform public.fn_set_enquiry_status(v_enq_id, 'lost',
          case when (v_seq % 4) = 0 then 'Chose a school nearer home'
               when (v_seq % 4) = 1 then 'Fee too high'
               when (v_seq % 4) = 2 then 'Wanted a class we do not offer'
               else 'Stopped responding' end);
      end if;
    end loop;

    -- ===== 3. Month by month ================================================
    for v_month in
      select generate_series(
        greatest(date_trunc('month', v_ses.starts_on)::date, date '2024-02-01'),
        least(date_trunc('month', v_ses.ends_on)::date, date_trunc('month', current_date)::date),
        interval '1 month')::date
    loop
      -- 3a. The challans, one call per class, which is what the Fees screen does.
      for v_cls in select id from public.classes where school_id=v_school order by level_order loop
        v_gen := v_gen + coalesce(
          public.fn_generate_class_invoices(v_ses.id, v_cls.id, v_month, v_month + 9), 0);
      end loop;

      -- 3b. Discounts, granted in the first month of each session only. Sibling
      -- discounts go to the second child of a family, which is the rule a
      -- Pakistani school actually applies.
      if v_month = greatest(date_trunc('month', v_ses.starts_on)::date, date '2024-02-01') then
        for v_inv in
          select e.id as enrollment_id, row_number() over () as k
            from public.enrollments e
            join public.students st on st.id = e.student_id
           where e.session_id = v_ses.id and e.status = 'active'
             and st.family_id in (select family_id from public.students
                                   where school_id=v_school and family_id is not null
                                   group by family_id having count(*) > 1)
           limit 60
        loop
          begin
            declare v_d uuid;
            begin
              v_d := public.fn_add_discount(v_inv.enrollment_id,
                (array['sibling','merit','hardship','staff_child','scholarship'])[((v_inv.k % 5) + 1)]::public.discount_type,
                case when (v_inv.k % 5) = 0 then 25 else 500 end,
                (v_inv.k % 5) = 0,
                'Granted at the start of ' || v_ses.name);
              v_disc := v_disc + 1;
              -- Not every discount is approved. A pending one and a rejected
              -- one are what the discount report exists to surface.
              if (v_inv.k % 7) = 0 then
                perform public.fn_set_discount_status(v_d, 'rejected');
              elsif (v_inv.k % 7) <> 1 then
                perform public.fn_set_discount_status(v_d, 'approved');
              end if;
            end;
          exception when others then
            raise notice '  discount skipped: %', sqlerrm;
          end;
        end loop;
      end if;

      -- 3c. Collection. One payment per FAMILY, not per child, because that is
      -- how a counter takes money from a father with three children and it is
      -- the only path that exercises fn_apply_family_credit.
      for v_fam in
        select f.id,
               (hashtextextended(f.id::text || v_month::text, 17) % 100 + 100) % 100 as luck,
               -- On the family and NOT on the month: see the note below.
               ((hashtextextended(f.id::text, 909) % 100 + 100) % 100) < 9 as chronic,
               sum(public.student_balance(st.id)) as owed
          from public.families f
          join public.students st on st.family_id = f.id
          join public.enrollments e on e.student_id = st.id and e.session_id = v_ses.id
         where f.school_id = v_school and e.status = 'active'
         group by f.id
      loop
        v_chronic := v_fam.chronic;
        continue when v_fam.owed is null or v_fam.owed <= 0;

        -- A DEFAULTER STAYS A DEFAULTER, and getting this wrong produced a
        -- school with a 98.6% collection rate.
        --
        -- The first version drew the "did not pay this month" card per family
        -- PER MONTH. One family in seven skipped a month, and then the next
        -- month the same roll came up differently and they paid the whole
        -- accumulated balance, clearing their arrears. Over 31 months that
        -- left 86 unpaid challans out of 6,177: no defaulter list, no ageing,
        -- nothing for the fee reports to be right or wrong about, and a school
        -- no Pakistani principal would recognise.
        --
        -- So chronic default is a property of the FAMILY (hashed on the family
        -- id alone) and not of the month. About one family in eleven is
        -- persistently behind and pays roughly half of what it owes when it
        -- pays at all, which is what actually generates arrears that survive.
        continue when v_chronic and (v_fam.luck < 55);
        continue when (not v_chronic) and v_fam.luck < 9;

        v_pay := case
          when v_chronic       then round((v_fam.owed * 0.45)::numeric)
          when v_fam.luck < 20 then round((v_fam.owed * 0.4)::numeric)  -- short payment
          when v_fam.luck < 30 then round((v_fam.owed * 0.7)::numeric)  -- part payment
          else v_fam.owed end;                                          -- paid in full
        if v_pay <= 0 then continue; end if;

        v_method := (array['cash','cash','cash','cash','bank_challan','jazzcash','easypaisa','bank_transfer'])
                      [((v_fam.luck % 8) + 1)]::public.payment_method;
        begin
          v_res := public.fn_record_family_payment(v_fam.id, v_pay, v_method,
                     'Fee for ' || to_char(v_month, 'Mon YYYY'),
                     -- A few online payments arrive unverified, which is what
                     -- fn_verify_payment is for and what the pending badge on
                     -- the payments screen means.
                     v_method in ('jazzcash','easypaisa') and (v_fam.luck % 11) = 0);
          v_paid := v_paid + 1;
        exception when others then
          raise notice '  payment skipped for family %: %', v_fam.id, sqlerrm;
        end;
      end loop;

      -- 3d. Late fines on the previous month's unpaid challans, and a few
      -- waived when a parent came in and explained themselves.
      for v_inv in
        select i.id, row_number() over (order by i.id) as k
          from public.invoices i
         where i.school_id = v_school
           and i.period_month = (v_month - interval '1 month')::date
           and i.status in ('issued','partial')
           and i.due_date < v_month
         limit 25
      loop
        begin
          perform public.fn_apply_fine(v_inv.id, 100, 'Late payment fine for '
            || to_char(v_month - interval '1 month', 'Mon YYYY'));
          v_fined := v_fined + 1;
          if (v_inv.k % 6) = 0 then
            perform public.fn_waive_fine(v_inv.id, 'Father came in, fine waived by the principal');
          end if;
        exception when others then
          raise notice '  fine skipped: %', sqlerrm;
        end;
      end loop;

      -- 3e. What the school spent. Salaries every month, utilities every month,
      -- rent quarterly, and the odd repair, all with real spent_on dates
      -- because fn_record_expense accepts one.
      perform public.fn_record_expense(
        round((21 * 32000 * (1 + (extract(year from v_month) - 2024) * 0.08))::numeric),
        -- least(..., current_date): salaries go out at the end of the month
        -- and this month has not ended, so an unclamped date books three
        -- payrolls that have not happened yet.
        v_cat_sal, least((v_month + interval '1 month - 3 days')::date, current_date),
        'Staff salaries', 'bank_transfer', to_char(v_month, 'Mon YYYY') || ' payroll');
      perform public.fn_record_expense(
        round((38000 + ((hashtextextended(v_month::text, 21) % 20000 + 20000) % 20000))::numeric),
        v_cat_util, least((v_month + interval '12 days')::date, current_date),
        'IESCO and SNGPL', 'cash', 'Electricity and gas');
      if extract(month from v_month) in (4, 7, 10, 1) then
        perform public.fn_record_expense(180000, v_cat_rent,
          least((v_month + interval '5 days')::date, current_date),
          'Building owner', 'bank_transfer', 'Quarterly rent');
      end if;
      if (hashtextextended(v_month::text, 33) % 3 + 3) % 3 = 0 then
        perform public.fn_record_expense(
          round((6000 + ((hashtextextended(v_month::text, 44) % 25000 + 25000) % 25000))::numeric),
          v_cat_maint, least((v_month + interval '18 days')::date, current_date),
          'Local contractor', 'cash', 'Repairs and whitewash');
      end if;
      perform public.fn_record_expense(
        round((9000 + ((hashtextextended(v_month::text, 55) % 12000 + 12000) % 12000))::numeric),
        v_cat_stat, least((v_month + interval '8 days')::date, current_date),
        'Ghauri Book Depot', 'cash', 'Registers, chalk and printing');

      -- Money in that is not fees: the tuck shop rent and the odd donation.
      perform public.fn_record_other_income(
        round((12000 + ((hashtextextended(v_month::text, 66) % 8000 + 8000) % 8000))::numeric),
        'Canteen rent', least((v_month + interval '4 days')::date, current_date), 'cash', null);
      if (hashtextextended(v_month::text, 77) % 5 + 5) % 5 = 0 then
        perform public.fn_record_other_income(
          round((25000 + ((hashtextextended(v_month::text, 88) % 50000 + 50000) % 50000))::numeric),
          'Donation', least((v_month + interval '20 days')::date, current_date), 'bank_transfer',
          'From a parent, towards the science lab');
      end if;
    end loop;

    -- ===== 4. Children who left during the year =============================
    -- Two or three a year: a transfer, a family moving city, one struck off.
    for v_inv in
      select st.id, row_number() over (order by st.id) as k
        from public.students st
        join public.enrollments e on e.student_id = st.id and e.session_id = v_ses.id
       where st.school_id = v_school and st.status = 'active'
         and (hashtextextended(st.id::text || v_ses.name, 91) % 100 + 100) % 100 < 3
       limit 4
    loop
      begin
        perform public.fn_set_student_status(v_inv.id,
          case when (v_inv.k % 3) = 0 then 'struck_off' else 'withdrawn' end::public.student_status,
          case when (v_inv.k % 3) = 0 then 'Fees unpaid for four months'
               when (v_inv.k % 3) = 1 then 'Family moved to Lahore'
               else 'Transferred to another school' end,
          least(v_ses.ends_on, current_date) - ((v_inv.k * 23) % 200)::int);
        v_left := v_left + 1;
      exception when others then
        raise notice '  leaver skipped: %', sqlerrm;
      end;
    end loop;

    -- ===== 5. The rollover ==================================================
    -- Only for a year that has actually finished. 2026-2027 is in progress, so
    -- it is left alone, which is the state the school is in today.
    if v_ses.ends_on < current_date then
      select id into v_next from public.academic_sessions
       where school_id = v_school and starts_on = v_ses.ends_on + 1;
      if v_next is not null then
        v_roll := public.fn_rollover(v_ses.id, v_next, '[]'::jsonb, true);
        raise notice '  ROLLOVER % -> %: promoted=%, graduated=%, retained=%, skipped=%',
          v_ses.name,
          (select name from public.academic_sessions where id = v_next),
          v_roll->>'promoted', v_roll->>'graduated', v_roll->>'retained', v_roll->>'skipped';
      end if;
    end if;
  end loop;

  raise notice '=== enquiries=% admitted=% invoices_generated=% payments=% fines=% discounts=% leavers=%',
    v_enq_made, v_adm, v_gen, v_paid, v_fined, v_disc, v_left;
end
$sim$;

commit;

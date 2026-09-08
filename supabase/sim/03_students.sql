-- =============================================================================
-- SIMULATION, PART 3: the hundred and twenty children already on the roll.
--
-- EVERY ONE THROUGH fn_admit_student, which is the only way the family model
-- gets exercised. That function reads father_cnic and puts siblings in the SAME
-- family (migration 0036), which is what makes one payment cover two children.
-- Inserting into students directly would produce 260 families of one and leave
-- fn_record_family_payment, fn_family_sheet, the sibling discount and
-- fn_apply_family_credit with nothing to act on.
--
-- ONLY THE OPENING ROLL IS HERE. The school bought the software in February
-- 2024 with about 120 children already enrolled, and those are the ones this
-- file admits. Every later arrival comes through 04_the_years.sql as an
-- enquiry that was followed up and converted, in the session it belongs to,
-- because that is the only order in which the chronology can be true: a child
-- admitted into 2025-2026 cannot exist before the rollover that created that
-- year's roll.
--
-- SIBLINGS ARE DELIBERATE AND CLUSTERED. Roughly one child in four shares a
-- father CNIC with another, which is what a Pakistani private school actually
-- looks like, and it is the difference between a family sheet with one line on
-- it and one worth printing.
--
-- Run: psql -v ON_ERROR_STOP=1 -f supabase/sim/03_students.sql
-- =============================================================================

\set ON_ERROR_STOP on

begin;

select set_config('request.jwt.claims',
  jsonb_build_object('sub', p.id::text, 'role','authenticated')::text, true)
from public.profiles p join public.schools s on s.id = p.school_id
where s.name = 'Chaudhary Puclix High School Ghauriii'
  and p.role = 'owner' and p.active limit 1;
set local role authenticated;

-- --- Name pools ---------------------------------------------------------------
-- Punjabi, Pashto, Sindhi and Muhajir naming patterns mixed, because a roll of
-- thirty Ahmeds is not what a school in Islamabad looks like and a search test
-- against thirty identical names proves nothing about the search.
create temp table sim_boy(n text) on commit drop;
insert into sim_boy(n) values
 ('Ahmed'),('Hamza'),('Bilal'),('Usman'),('Zain'),('Hassan'),('Hussain'),('Umar'),
 ('Talha'),('Saad'),('Ibrahim'),('Ali'),('Abdullah'),('Ayan'),('Rayyan'),('Arham'),
 ('Shahzaib'),('Faizan'),('Danish'),('Salman'),('Adnan'),('Waleed'),('Zohaib'),
 ('Noman'),('Kashif'),('Junaid'),('Asad'),('Fahad'),('Rehan'),('Sufyan'),
 ('Mudassir'),('Waqas'),('Shoaib'),('Imran'),('Naveed'),('Tariq'),('Yasir');
create temp table sim_girl(n text) on commit drop;
insert into sim_girl(n) values
 ('Ayesha'),('Fatima'),('Maryam'),('Zainab'),('Khadija'),('Hafsa'),('Amna'),
 ('Iqra'),('Sana'),('Hira'),('Rabia'),('Nimra'),('Areeba'),('Laiba'),('Eman'),
 ('Aleena'),('Zoya'),('Mahnoor'),('Anaya'),('Iman'),('Alishba'),('Kinza'),
 ('Mehak'),('Sidra'),('Tayyaba'),('Warda'),('Nida'),('Saba'),('Bushra'),
 ('Shanzay'),('Minahil'),('Umaima'),('Hoorain');
create temp table sim_fam(n text) on commit drop;
insert into sim_fam(n) values
 ('Chaudhary'),('Malik'),('Khan'),('Butt'),('Awan'),('Gujjar'),('Rajput'),
 ('Qureshi'),('Sheikh'),('Mughal'),('Abbasi'),('Satti'),('Janjua'),('Kiyani'),
 ('Bhatti'),('Cheema'),('Sandhu'),('Warraich'),('Dar'),('Mir'),('Baig'),
 ('Durrani'),('Yousafzai'),('Afridi'),('Shinwari'),('Soomro'),('Jatoi'),
 ('Memon'),('Ansari'),('Siddiqui'),('Farooqi'),('Zaidi'),('Naqvi'),('Rizvi');
create temp table sim_dad(n text) on commit drop;
insert into sim_dad(n) values
 ('Muhammad Aslam'),('Abdul Rehman'),('Ghulam Nabi'),('Muhammad Akram'),
 ('Zafar Iqbal'),('Nasir Mahmood'),('Shahid Anwar'),('Riaz Ahmed'),
 ('Tanveer Abbas'),('Mushtaq Ali'),('Sajjad Haider'),('Khalid Pervaiz'),
 ('Muhammad Yousaf'),('Rashid Minhas'),('Amjad Hussain'),('Liaqat Ali'),
 ('Muhammad Shafiq'),('Ijaz Ahmad'),('Sabir Hussain'),('Manzoor Elahi'),
 ('Sarfraz Khan'),('Iftikhar Ahmed'),('Tahir Mehmood'),('Javed Iqbal'),
 ('Muhammad Naeem'),('Asghar Ali'),('Zulfiqar Ahmed'),('Noor Muhammad'),
 ('Muhammad Ramzan'),('Allah Yar'),('Bashir Ahmad'),('Sultan Mehmood');
create temp table sim_mum(n text) on commit drop;
insert into sim_mum(n) values
 ('Naseem Akhtar'),('Parveen Bibi'),('Shamim Akhtar'),('Razia Sultana'),
 ('Nasreen Begum'),('Zubaida Khatoon'),('Rukhsana Kausar'),('Shahnaz Bibi'),
 ('Tahira Bano'),('Farzana Kausar'),('Rehana Kausar'),('Sajida Parveen'),
 ('Kaneez Fatima'),('Surraya Begum'),('Iqbal Bano'),('Zarina Bibi');

-- --- The admissions ------------------------------------------------------------
do $sim$
declare
  v_school uuid := public.current_school_id();
  v_sess_2324 uuid; v_sess_2425 uuid; v_sess_2526 uuid; v_sess_2627 uuid;
  v_i int; v_boy boolean; v_first text; v_fam text; v_dad text; v_mum text;
  v_lvl int; v_class uuid; v_section uuid; v_sess uuid;
  v_admit date; v_dob date; v_cnic text; v_phone text;
  v_sib int; v_cnic_pool text[]; v_res jsonb;
  v_nboy int; v_ngirl int; v_nfam int; v_ndad int; v_nmum int;
  v_made int := 0;
begin
  if v_school is null then raise exception 'No owner session.'; end if;
  if exists (select 1 from public.students where school_id = v_school) then
    raise notice 'students already present (%), nothing to do',
      (select count(*) from public.students where school_id = v_school);
    return;
  end if;

  select id into v_sess_2324 from public.academic_sessions where school_id=v_school and name='2023-2024';
  select id into v_sess_2425 from public.academic_sessions where school_id=v_school and name='2024-2025';
  select id into v_sess_2526 from public.academic_sessions where school_id=v_school and name='2025-2026';
  select id into v_sess_2627 from public.academic_sessions where school_id=v_school and name='2026-2027';

  select count(*) into v_nboy  from sim_boy;
  select count(*) into v_ngirl from sim_girl;
  select count(*) into v_nfam  from sim_fam;
  select count(*) into v_ndad  from sim_dad;
  select count(*) into v_nmum  from sim_mum;

  -- A HUNDRED AND NINETY CNICs, SHARED ACROSS THE WHOLE TWO YEARS, and the
  -- arithmetic matters.
  -- Reusing a father's CNIC is the only thing that makes fn_admit_student put
  -- two children in one family (migration 0036), so the sibling rate is set
  -- here and nowhere else.
  -- The first draft used a pool of 80 for 260 children and produced 80 families
  -- of 3.25 each: every single family had siblings, which exercises the family
  -- model hard and is not what a school looks like. A pool of 190 across the
  -- full intake gives ~190 families of which ~70 gain a second child, an
  -- average of 1.37, which is about right for a Pakistani private school and
  -- still leaves plenty of family sheets worth printing. The later years draw
  -- from the same pool, so a sibling pair can be admitted two years apart:
  -- that is the case which catches a family query assuming one enrollment.
  select array_agg('61101-' || lpad((3000000 + g)::text, 7, '0') || '-' ||
                   ((g % 9) + 1)::text)
    into v_cnic_pool
    from generate_series(1, 190) g;

  for v_i in 1..120 loop
    v_boy   := (v_i % 100) < 54;               -- 54% boys, roughly national
    v_first := case when v_boy
      then (select n from sim_boy  offset ((v_i * 7) % v_nboy)  limit 1)
      else (select n from sim_girl offset ((v_i * 11) % v_ngirl) limit 1) end;
    -- The opening roll takes CNICs 1..120 from the pool. 04_the_years.sql
    -- continues at 121 and then deliberately reuses 1..70 for second children.
    v_sib   := v_i;
    v_fam   := (select n from sim_fam offset ((v_sib * 5) % v_nfam) limit 1);
    v_dad   := (select n from sim_dad offset ((v_sib * 3) % v_ndad) limit 1);
    v_mum   := (select n from sim_mum offset ((v_sib * 13) % v_nmum) limit 1);
    v_cnic  := v_cnic_pool[v_sib];
    v_phone := '03' || lpad(((v_sib * 1234567) % 100000000)::text, 9, '0');

    -- WHEN each child arrives, and this is the whole chronology.
    --   1..120  : already on the roll when the school bought the software
    --   121..165: admitted during 2024-2025
    --   166..215: during 2025-2026
    --   216..260: during 2026-2027, up to today
    -- These children were admitted between 2019 and early 2024: they were
    -- already at the school when it started paying us. Their admission dates
    -- are historical and their enrollment is in the 2023-2024 session, which
    -- is the year in progress in February 2024.
    v_admit := date '2019-04-01' + ((v_i * 37) % 1750);
    v_sess  := v_sess_2324;
    v_lvl   := ((v_i * 5) % 12) + 1;
    select id into v_class from public.classes
     where school_id = v_school and level_order = v_lvl;
    select id into v_section from public.sections
     where class_id = v_class order by sort_order
     offset (v_i % (select count(*) from public.sections where class_id = v_class)) limit 1;

    -- Age that matches the class, so the Birthdays screen and any age report
    -- have something coherent to show.
    v_dob := (date_trunc('year', v_admit)::date - ((v_lvl + 3) * 365))
             + ((v_i * 29) % 365);

    v_res := public.fn_admit_student(jsonb_build_object(
      'full_name',      v_first || ' ' || v_fam,
      'father_name',    v_dad,
      'mother_name',    v_mum,
      'father_cnic',    v_cnic,
      'b_form',         '61101-' || lpad((7000000 + v_i)::text, 7, '0') || '-' || ((v_i % 9) + 1)::text,
      'dob',            v_dob,
      'gender',         case when v_boy then 'male' else 'female' end,
      'address',        'House ' || (10 + (v_i % 300))::text || ', Street ' ||
                        (1 + (v_i % 24))::text || ', Ghauri Town Phase ' ||
                        (1 + (v_i % 5))::text || ', Islamabad',
      'phone',          v_phone,
      'whatsapp',       v_phone,
      'admission_date', v_admit,
      'session_id',     v_sess,
      'class_id',       v_class,
      'section_id',     v_section,
      -- The admission fee is charged for most, waived for a handful. A school
      -- where every single admission fee was charged never exercises the
      -- "charged: false" branch or the discount report.
      'admission_fee',  jsonb_build_object('charged', (v_i % 11) <> 0)
    ));
    v_made := v_made + 1;
  end loop;

  raise notice 'opening roll admitted=%  students=%  families=%  enrollments=%',
    v_made,
    (select count(*) from public.students where school_id = v_school),
    (select count(*) from public.families where school_id = v_school),
    (select count(*) from public.enrollments where school_id = v_school);
  raise notice 'families with more than one child = %',
    (select count(*) from (select family_id from public.students
                            where school_id = v_school and family_id is not null
                            group by family_id having count(*) > 1) q);
end
$sim$;

commit;

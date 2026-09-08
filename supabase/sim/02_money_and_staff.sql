-- =============================================================================
-- SIMULATION, PART 2: what the school charges, and who works there.
--
-- FEE HEADS GO THROUGH fn_upsert_fee_head AND NOT AN INSERT, because that
-- function is what decides whether a head is billable monthly, once a year, or
-- held as a refundable deposit, and those three behave differently everywhere
-- downstream. A security deposit that arrives as a plain insert with the wrong
-- is_refundable flag looks identical in the table and produces a balance sheet
-- that does not balance.
--
-- AMOUNTS RISE WITH THE CLASS AND WITH THE YEAR. A flat fee across twelve
-- classes and three sessions would leave fn_fee_increment, the head-wise dues
-- report and the class dues report all reading the same number, and none of
-- them would be telling us anything.
--
-- Run: psql -v ON_ERROR_STOP=1 -f supabase/sim/02_money_and_staff.sql
-- =============================================================================

\set ON_ERROR_STOP on

begin;

select set_config(
  'request.jwt.claims',
  jsonb_build_object('sub', p.id::text, 'role', 'authenticated')::text, true)
from public.profiles p join public.schools s on s.id = p.school_id
where s.name = 'Chaudhary Puclix High School Ghauriii'
  and p.role = 'owner' and p.active limit 1;
set local role authenticated;

do $sim$
declare
  v_school uuid := public.current_school_id();
  v_admission uuid; v_tuition uuid; v_annual uuid; v_exam uuid;
  v_deposit uuid; v_transport uuid; v_misc uuid;
  r record; s record;
  v_base numeric; v_year_factor numeric;
begin
  if v_school is null then raise exception 'No owner session.'; end if;

  -- --- 1. Fee heads ----------------------------------------------------------
  select id into v_admission from public.fee_heads where school_id = v_school and name = 'Admission Fee';
  if v_admission is null then
    v_admission := public.fn_upsert_fee_head('Admission Fee', 'admission', false, false, 1);
  end if;
  select id into v_tuition from public.fee_heads where school_id = v_school and name = 'Monthly Tuition';
  if v_tuition is null then
    v_tuition := public.fn_upsert_fee_head('Monthly Tuition', 'monthly', true, false, 2);
  end if;
  select id into v_annual from public.fee_heads where school_id = v_school and name = 'Annual Charges';
  if v_annual is null then
    v_annual := public.fn_upsert_fee_head('Annual Charges', 'annual', false, false, 3);
  end if;
  select id into v_exam from public.fee_heads where school_id = v_school and name = 'Exam Fee';
  if v_exam is null then
    v_exam := public.fn_upsert_fee_head('Exam Fee', 'exam', false, false, 4);
  end if;
  -- REFUNDABLE, and the only one. fn_charge_deposit, fn_deposits_held and
  -- fn_refund_deposit all hang off this flag, and migration 0117's invoice
  -- trigger refuses to mix a refundable line with a normal one on one challan.
  select id into v_deposit from public.fee_heads where school_id = v_school and name = 'Security Deposit';
  if v_deposit is null then
    v_deposit := public.fn_upsert_fee_head('Security Deposit', 'security_deposit', false, true, 5);
  end if;
  select id into v_transport from public.fee_heads where school_id = v_school and name = 'Transport';
  if v_transport is null then
    v_transport := public.fn_upsert_fee_head('Transport', 'transport', true, false, 6);
  end if;
  select id into v_misc from public.fee_heads where school_id = v_school and name = 'Stationery';
  if v_misc is null then
    v_misc := public.fn_upsert_fee_head('Stationery', 'misc', false, false, 7);
  end if;

  -- --- 2. Fee structures, per class per session ------------------------------
  -- Rs 900 in Nursery rising to Rs 2,550 in Class 10, and the whole sheet up
  -- roughly 10% a year. Transport is deliberately NOT set for every class: a
  -- head with no amount in some classes is what "classes without fee" on the
  -- dashboard counts, and a school where that number is always zero never
  -- exercises it.
  for s in select id, name, starts_on from public.academic_sessions
            where school_id = v_school order by starts_on loop
    v_year_factor := case s.name
      when '2023-2024' then 1.00 when '2024-2025' then 1.10
      when '2025-2026' then 1.21 else 1.33 end;
    for r in select id, name, level_order from public.classes
              where school_id = v_school order by level_order loop
      v_base := 900 + (r.level_order - 1) * 150;

      -- THROUGH fn_set_fee_amount, NOT AN INSERT, and the reason is a finding:
      -- `authenticated` has no INSERT grant on fee_structures at all. Every
      -- table where money or a permanent record lives is RPC-only in this
      -- schema (invoices, payments, allocations, discounts, attendance, marks,
      -- result cards, certificates, fee heads and structures, login secrets),
      -- while reference data and settings are directly writable behind RLS.
      -- The first draft of this file inserted straight into the table and was
      -- refused, which is the boundary working exactly as designed.
      perform public.fn_set_fee_amount(s.id, r.id, v.head, round(v.amt), s.starts_on)
        from (values
          (v_tuition,   v_base * v_year_factor),
          (v_admission, 3000 * v_year_factor),
          (v_annual,    (1500 + r.level_order * 100) * v_year_factor),
          (v_exam,      (300 + r.level_order * 25) * v_year_factor),
          (v_deposit,   1000::numeric),
          (v_misc,      (250 + r.level_order * 20) * v_year_factor)
        ) as v(head, amt);

      -- Transport only for the classes that actually use the van, so that
      -- "classes without a fee" on the dashboard has something real to count.
      if r.level_order between 3 and 10 then
        perform public.fn_set_fee_amount(s.id, r.id, v_transport,
                                         round(1200 * v_year_factor), s.starts_on);
      end if;
    end loop;
  end loop;

  raise notice 'fee heads=%  fee structure rows=%',
    (select count(*) from public.fee_heads where school_id = v_school),
    (select count(*) from public.fee_structures where school_id = v_school);
end
$sim$;

-- --- 3. Staff ----------------------------------------------------------------
-- Twenty-three people, with joining dates spread across the two years and two
-- who have since left. A roster where everybody joined on day one and nobody
-- ever left leaves fn_staff_leave, fn_staff_rejoin and the left_on filters in
-- every roster query completely unvisited.
do $sim$
declare
  v_school uuid := public.current_school_id();
  r record;
begin
  insert into public.staff (full_name, designation, employee_no, mobile, whatsapp,
                            cnic, joined_on, left_on, status, dob)
  select v.nm, v.desig, v.emp, v.mob, v.mob, v.cnic, v.joined, v.left_on, v.st, v.dob
    from (values
      ('Rana Abdul Rasheed', 'Principal',        'E-001', '03005512340', '61101-2233445-1', date '2019-04-01', null::date, 'active', date '1974-06-12'),
      ('Nasreen Akhtar',     'Vice Principal',   'E-002', '03215512341', '61101-2233446-2', date '2020-04-01', null,        'active', date '1980-02-28'),
      ('Bilal Ahmed Khan',   'Admin Clerk',      'E-003', '03335512342', '61101-2233447-3', date '2021-08-16', null,        'active', date '1993-11-05'),
      ('Sadia Parveen',      'Admin Clerk',      'E-004', '03455512343', '61101-2233448-4', date '2024-05-02', null,        'active', date '1996-07-19'),
      ('Muhammad Tanveer',   'Accountant',       'E-005', '03005512344', '61101-2233449-5', date '2022-01-10', null,        'active', date '1988-03-30'),
      ('Ayesha Siddiqua',    'Class Teacher',    'E-006', '03215512345', '61101-2233450-6', date '2021-04-01', null,        'active', date '1994-09-14'),
      ('Farhat Naz',         'Class Teacher',    'E-007', '03335512346', '61101-2233451-7', date '2021-04-01', null,        'active', date '1991-12-01'),
      ('Kausar Bibi',        'Class Teacher',    'E-008', '03455512347', '61101-2233452-8', date '2022-04-01', null,        'active', date '1985-05-23'),
      ('Shazia Rehman',      'Class Teacher',    'E-009', '03005512348', '61101-2233453-9', date '2022-04-01', null,        'active', date '1990-08-08'),
      ('Iram Shahzadi',      'Class Teacher',    'E-010', '03215512349', '61101-2233454-0', date '2023-04-03', null,        'active', date '1997-01-17'),
      ('Saima Noreen',       'Class Teacher',    'E-011', '03335512350', '61101-2233455-1', date '2023-04-03', null,        'active', date '1995-04-04'),
      ('Zubair Hussain',     'Class Teacher',    'E-012', '03455512351', '61101-2233456-2', date '2023-09-01', null,        'active', date '1992-10-26'),
      ('Abdul Waheed',       'Class Teacher',    'E-013', '03005512352', '61101-2233457-3', date '2024-04-01', null,        'active', date '1989-02-11'),
      ('Rukhsana Kausar',    'Class Teacher',    'E-014', '03215512353', '61101-2233458-4', date '2024-04-01', null,        'active', date '1998-06-30'),
      ('Naveed Iqbal',       'Class Teacher',    'E-015', '03335512354', '61101-2233459-5', date '2024-08-19', null,        'active', date '1993-07-07'),
      ('Hina Aslam',         'Class Teacher',    'E-016', '03455512355', '61101-2233460-6', date '2025-04-01', null,        'active', date '1999-03-21'),
      ('Tahira Yasmin',      'Class Teacher',    'E-017', '03005512356', '61101-2233461-7', date '2025-04-01', null,        'active', date '1996-11-11'),
      ('Imran Sajid',        'Subject Teacher',  'E-018', '03215512357', '61101-2233462-8', date '2022-04-01', null,        'active', date '1987-08-15'),
      ('Asma Batool',        'Subject Teacher',  'E-019', '03335512358', '61101-2233463-9', date '2023-04-03', null,        'active', date '1994-05-09'),
      ('Waqar Younis Butt',  'Subject Teacher',  'E-020', '03455512359', '61101-2233464-0', date '2025-08-18', null,        'active', date '1990-01-25'),
      ('Allah Ditta',        'Caretaker',        'E-021', '03005512360', '61101-2233465-1', date '2019-04-01', null,        'active', date '1968-04-02'),
      -- The two who left. One resigned mid-session, one at a year end.
      ('Sumaira Kanwal',     'Class Teacher',    'E-022', '03215512361', '61101-2233466-2', date '2021-04-01', date '2024-11-30', 'left', date '1992-02-14'),
      ('Ghulam Murtaza',     'Subject Teacher',  'E-023', '03335512362', '61101-2233467-3', date '2022-04-01', date '2025-03-31', 'left', date '1986-09-19')
    ) as v(nm, desig, emp, mob, cnic, joined, left_on, st, dob)
   where not exists (select 1 from public.staff st2
                      where st2.school_id = v_school and st2.employee_no = v.emp);

  -- --- 4. Class teachers -----------------------------------------------------
  -- fn_set_class_teacher rather than an update, because it is the function that
  -- keeps one teacher per section and writes the teacher_assignments row the
  -- teacher's own "my assignments" screen reads.
  -- One teacher per section, in every session, because teacher_assignments is
  -- keyed by session: an assignment made once in 2023-2024 leaves a teacher
  -- with no classes for the next three years, and "my assignments" empty.
  for r in
    with secs as (
      select s.id as section_id, s.class_id,
             row_number() over (order by c.level_order, s.sort_order) as pos
        from public.sections s
        join public.classes c on c.id = s.class_id
       where c.school_id = v_school
    ), tchr as (
      select id, row_number() over (order by employee_no) as k,
             count(*) over () as total
        from public.staff
       where school_id = v_school and designation = 'Class Teacher' and status = 'active'
    )
    select sec.section_id, sec.class_id, t.id as staff_id, ses.id as session_id
      from secs sec
      join tchr t on t.k = ((sec.pos - 1) % t.total) + 1
      cross join (select id from public.academic_sessions where school_id = v_school) ses
  loop
    begin
      perform public.fn_set_class_teacher(r.staff_id, r.session_id, r.class_id, r.section_id);
    exception when others then
      raise notice 'class teacher assignment skipped: %', sqlerrm;
    end;
  end loop;

  raise notice 'staff=% (active=%)  teacher assignments=%',
    (select count(*) from public.staff where school_id = v_school),
    (select count(*) from public.staff where school_id = v_school and status = 'active'),
    (select count(*) from public.teacher_assignments where school_id = v_school);
end
$sim$;

commit;

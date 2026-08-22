-- =============================================================================
-- Admission enquiries: does the lead actually get followed up, and converted
-- without being lost or duplicated?
--
-- The rules this file defends:
--
--  1. AN ENQUIRY IS NEVER INVISIBLE. Every open enquiry has a follow-up date,
--     because one with a null date appears on no list and is the exact failure
--     the table exists to prevent. fn_add_enquiry defaults it; the summary
--     reports any that slipped through anyway rather than hiding them.
--  2. THE LIST IS ORDERED BY WHO HAS WAITED LONGEST, not by who called most
--     recently. Newest-first buries the parent waiting nine days.
--  3. CONVERTING CANNOT HAPPEN TWICE. A double-click must not burn a second GR
--     number and leave the school a duplicate child to unpick.
--  4. THERE IS ONE ADMISSION PATH. Converting delegates to fn_admit_student, so
--     the GR number, the family linkage and the subscription student limit all
--     behave identically to a walk-in. A second path that drifts is a bug
--     factory.
--  5. NOTHING IS DELETED. A lost enquiry keeps its row and must state why.
--  6. THE CONVERSION RATE DOES NOT LIE. An enquiry taken this morning is not a
--     failure. The rate counts decided outcomes only, and is null — not 0% —
--     when nothing has been decided.
--  7. The WhatsApp toggle genuinely blocks, search cannot be broken by a
--     wildcard, nothing crosses a school boundary, and a teacher cannot read
--     the enquiry book.
--
-- Run: psql -v ON_ERROR_STOP=1 -f supabase/tests/enquiries.sql
-- =============================================================================

\set ON_ERROR_STOP on

begin;

create or replace function auth.uid() returns uuid language sql stable as
  $$ select nullif(current_setting('test.uid', true), '')::uuid $$;

create or replace function pg_temp.ok(p_cond boolean, p_label text)
returns void language plpgsql as $$
begin
  if p_cond then raise notice 'PASS  %', p_label;
  else raise exception 'FAIL  %', p_label; end if;
end;
$$;

create or replace function pg_temp.be(p_name text) returns void language sql as $$
  select set_config('test.uid',
    (select id::text from public.profiles where full_name = p_name), false);
$$;

create or replace function pg_temp.add(p jsonb) returns jsonb
language sql as $$ select public.fn_add_enquiry(p) $$;

create or replace function pg_temp.eid(p_no bigint) returns uuid language sql as $$
  select id from public.admission_enquiries
   where school_id = public.current_school_id() and enquiry_no = p_no
$$;

-- --- Fixture -----------------------------------------------------------------
-- School A with staff at every relevant role, one class, one fee structure.
-- School B exists so isolation can be checked, with its own enquiries.
do $seed$
declare
  v_a uuid; v_b uuid;
  v_oa uuid := '00000000-0000-0000-0000-00000000e901';
  v_cl uuid := '00000000-0000-0000-0000-00000000e902';
  v_tc uuid := '00000000-0000-0000-0000-00000000e903';
  v_ro uuid := '00000000-0000-0000-0000-00000000e904';
  v_ob uuid := '00000000-0000-0000-0000-00000000e905';
  v_sess uuid; v_class uuid; v_head uuid;
  v_sess_b uuid; v_class_b uuid;
begin
  insert into public.schools (name) values ('Enq A') returning id into v_a;
  insert into public.subscriptions (school_id, plan_code, status, trial_ends_on)
    values (v_a, 'growth', 'active', current_date + 30);
  insert into public.schools (name) values ('Enq B') returning id into v_b;
  insert into public.subscriptions (school_id, plan_code, status, trial_ends_on)
    values (v_b, 'growth', 'active', current_date + 30);

  alter table public.profiles disable trigger user;
  insert into auth.users (id, email) values
    (v_oa,'eqa@eq.test'), (v_cl,'eqc@eq.test'), (v_tc,'eqt@eq.test'),
    (v_ro,'eqr@eq.test'), (v_ob,'eqb@eq.test') on conflict (id) do nothing;
  insert into public.profiles (id, full_name, role, school_id) values
    (v_oa, 'Enq Owner',    'owner',           v_a),
    (v_cl, 'Enq Clerk',    'admin_clerk',     v_a),
    (v_tc, 'Enq Teacher',  'class_teacher',   v_a),
    (v_ro, 'Enq Readonly', 'readonly',        v_a),
    (v_ob, 'Enq Other',    'owner',           v_b)
    on conflict (id) do update set school_id = excluded.school_id,
                                   role      = excluded.role,
                                   full_name = excluded.full_name,
                                   active    = true;
  alter table public.profiles enable trigger user;

  perform set_config('test.uid', v_oa::text, false);
  insert into public.academic_sessions (name, is_current, school_id)
    values ('2025-2026', true, v_a) returning id into v_sess;
  update public.school_settings set current_session_id = v_sess where school_id = v_a;
  insert into public.classes (name, level_order, school_id)
    values ('Class 3', 3, v_a) returning id into v_class;
  insert into public.fee_heads (name, type, is_recurring, sort_order, school_id)
    values ('Tuition', 'monthly', true, 10, v_a) returning id into v_head;
  insert into public.fee_structures (session_id, class_id, fee_head_id, amount, school_id)
    values (v_sess, v_class, v_head, 3000, v_a);

  perform set_config('test.uid', v_ob::text, false);
  insert into public.academic_sessions (name, is_current, school_id)
    values ('2025-2026', true, v_b) returning id into v_sess_b;
  update public.school_settings set current_session_id = v_sess_b where school_id = v_b;
  insert into public.classes (name, level_order, school_id)
    values ('B Class', 1, v_b) returning id into v_class_b;

  perform set_config('test.uid', v_oa::text, false);
end;
$seed$;

-- =============================================================================
-- 1. Recording an enquiry
-- =============================================================================
do $$
declare r jsonb;
begin
  r := pg_temp.add(jsonb_build_object(
    'child_name', 'Hira Khan', 'father_name', 'Imran Khan',
    'phone', '03001234567', 'source', 'banner',
    'class_id', (select id from public.classes where name = 'Class 3'),
    'session_id', pg_temp.eid(0)));  -- deliberately null; class without session is legal
  perform pg_temp.ok((r->>'enquiry_no')::bigint = 1,
    '1  the first enquiry is number 1, per school');
  perform pg_temp.ok((r->>'possible_duplicate') is null,
    '2  a first enquiry is not flagged as a duplicate of itself');
  perform pg_temp.ok((r->>'message_queued')::boolean,
    '3  the acknowledgement message is queued on recording');
end $$;

-- Only two fields are required. Anything more and a clerk on the phone stops
-- making the record at all.
do $$
begin
  begin
    perform pg_temp.add(jsonb_build_object('phone', '03009999999'));
    raise exception 'FAIL  4  an enquiry with no child name was accepted';
  exception when others then
    if sqlstate = 'P0001' and sqlerrm like '%name is required%'
    then raise notice 'PASS  4  the child''s name is required';
    else raise; end if;
  end;
  begin
    perform pg_temp.add(jsonb_build_object('child_name', 'No Phone'));
    raise exception 'FAIL  5  an enquiry with no phone was accepted';
  exception when others then
    if sqlstate = 'P0001' and sqlerrm like '%phone number is required%'
    then raise notice 'PASS  5  an enquiry nobody can ring is refused';
    else raise; end if;
  end;
end $$;

-- An open enquiry with no follow-up date appears on no list. That must be
-- impossible by default, not left to whoever fills the form.
do $$
declare v_d date;
begin
  select follow_up_on into v_d from public.admission_enquiries where enquiry_no = 1;
  perform pg_temp.ok(v_d is not null and v_d > current_date,
    '6  a follow-up date is defaulted, so no enquiry is ever invisible');
end $$;

-- Same phone AND same child: warn, never block. The same number enquiring
-- again is usually a second child, and refusing that would be wrong.
do $$
declare r jsonb;
begin
  r := pg_temp.add(jsonb_build_object('child_name','hira khan','phone','03001234567'));
  perform pg_temp.ok((r->>'possible_duplicate') is not null
                 and (r->'possible_duplicate'->>'enquiry_no')::bigint = 1,
    '7  a repeat of the same child on the same number is flagged (case-insensitively)');
  perform pg_temp.ok((r->>'enquiry_no')::bigint = 2,
    '8  ...but still recorded, because a second child on one number is normal');

  r := pg_temp.add(jsonb_build_object('child_name','Bilal Khan','phone','03001234567'));
  perform pg_temp.ok((r->>'possible_duplicate') is null,
    '9  a DIFFERENT child on the same number is not a duplicate');
end $$;

-- =============================================================================
-- 2. Following up
-- =============================================================================
do $$
declare v_e uuid := pg_temp.eid(1); v_st text;
begin
  perform public.fn_log_enquiry_contact(v_e, 'Rang, no answer', 'Try after Maghrib',
                                        current_date + 2);
  perform public.fn_log_enquiry_contact(v_e, 'Spoke to father', 'Wants to see the lab',
                                        current_date + 5);
  perform pg_temp.ok((select count(*) from public.fn_enquiry_contacts(v_e)) = 2,
    '10 the follow-up log appends rather than overwriting');

  select status into v_st from public.admission_enquiries where id = v_e;
  perform pg_temp.ok(v_st = 'contacted',
    '11 logging a call advances new -> contacted without a second action');

  perform pg_temp.ok(
    (select follow_up_on from public.admission_enquiries where id = v_e)
      = current_date + 5,
    '12 the next follow-up date moves with the log, so it cannot fall off the list');
end $$;

-- An empty outcome tells the next person nothing, which defeats the log.
do $$
begin
  begin
    perform public.fn_log_enquiry_contact(pg_temp.eid(1), '   ');
    raise exception 'FAIL  13 an empty follow-up outcome was accepted';
  exception when others then
    if sqlstate = 'P0001' and sqlerrm like '%what happened%'
    then raise notice 'PASS  13 an empty follow-up outcome is refused';
    else raise; end if;
  end;
end $$;

-- =============================================================================
-- 3. Losing an enquiry — the record a school actually learns from
-- =============================================================================
do $$
begin
  begin
    perform public.fn_set_enquiry_status(pg_temp.eid(2), 'lost', null);
    raise exception 'FAIL  14 an enquiry was lost without a reason';
  exception when others then
    if sqlstate = 'P0001' and sqlerrm like '%why it was lost%'
    then raise notice 'PASS  14 losing an enquiry requires a reason';
    else raise; end if;
  end;

  perform public.fn_set_enquiry_status(pg_temp.eid(2), 'lost', 'Fee too high');
  perform pg_temp.ok(
    (select lost_reason from public.admission_enquiries where enquiry_no = 2) = 'Fee too high',
    '15 the reason is kept — "why did we not get these children" is the whole point');
  perform pg_temp.ok(
    (select follow_up_on from public.admission_enquiries where enquiry_no = 2) is null,
    '16 a lost enquiry drops off the follow-up list');
  perform pg_temp.ok(
    (select count(*) from public.admission_enquiries where enquiry_no = 2) = 1,
    '17 losing an enquiry does not delete it');
end $$;

-- Admission is not a status you can type. It creates a student, so it has to go
-- through the function that creates one.
do $$
begin
  begin
    perform public.fn_set_enquiry_status(pg_temp.eid(3), 'admitted');
    raise exception 'FAIL  18 an enquiry was marked admitted with no student behind it';
  exception when others then
    if sqlstate = 'P0001' and sqlerrm like '%fn_enquiry_admit%'
    then raise notice 'PASS  18 status cannot be set to admitted by hand';
    else raise; end if;
  end;
end $$;

-- =============================================================================
-- 4. Converting — one admission path, and only once
-- =============================================================================
do $$
declare
  v_e uuid := pg_temp.eid(1);
  r jsonb;
  v_stu uuid;
begin
  r := public.fn_enquiry_admit(v_e, jsonb_build_object('roll_no', '11'));
  v_stu := (r->>'student_id')::uuid;

  perform pg_temp.ok(v_stu is not null and nullif(r->>'gr_no','') is not null,
    '19 converting produces a real student with a GR number from fn_admit_student');
  perform pg_temp.ok((r->>'family_id') is not null,
    '20 ...and the family linkage from 0036 applies, exactly as for a walk-in');

  -- Prefill without retyping is the entire reason to convert rather than admit
  -- fresh, so check the enquiry's own details actually carried over.
  perform pg_temp.ok(
    (select full_name from public.students where id = v_stu) = 'Hira Khan'
    and (select father_name from public.students where id = v_stu) = 'Imran Khan',
    '21 the enquiry prefills the admission — the clerk retypes nothing');
  perform pg_temp.ok(
    (select roll_no from public.enrollments where student_id = v_stu limit 1) = '11',
    '22 a caller override beats the enquiry value');

  perform pg_temp.ok(
    (select status from public.admission_enquiries where id = v_e) = 'admitted'
    and (select admitted_student_id from public.admission_enquiries where id = v_e) = v_stu,
    '23 the enquiry is kept and linked to the student, not deleted');
  perform pg_temp.ok(
    (select follow_up_on from public.admission_enquiries where id = v_e) is null,
    '24 an admitted enquiry stops asking to be followed up');
  perform pg_temp.ok((r->>'message_queued')::boolean,
    '25 the admission confirmation is queued');
end $$;

-- THE load-bearing guard. A double-click here burns a GR number and leaves a
-- duplicate child for somebody to find and unpick by hand.
do $$
declare v_before int;
begin
  select count(*) into v_before from public.students
   where school_id = public.current_school_id();
  begin
    perform public.fn_enquiry_admit(pg_temp.eid(1));
    raise exception 'FAIL  26 the same enquiry was admitted twice';
  exception when others then
    if sqlstate = 'P0001' and sqlerrm like '%already admitted%'
    then raise notice 'PASS  26 admitting the same enquiry twice is refused';
    else raise; end if;
  end;
  perform pg_temp.ok(
    (select count(*) from public.students where school_id = public.current_school_id())
      = v_before,
    '27 ...and no second student was created by the attempt');
end $$;

-- A lost enquiry that turns up after all should be reopened deliberately, so
-- the record shows what happened rather than skipping from lost to admitted.
do $$
begin
  begin
    perform public.fn_enquiry_admit(pg_temp.eid(2));
    raise exception 'FAIL  28 a lost enquiry was admitted directly';
  exception when others then
    if sqlstate = 'P0001' and sqlerrm like '%marked lost%'
    then raise notice 'PASS  28 a lost enquiry must be reopened before admitting';
    else raise; end if;
  end;

  -- Reopening must put it back on somebody's list, or it silently vanishes.
  perform public.fn_set_enquiry_status(pg_temp.eid(2), 'contacted');
  perform pg_temp.ok(
    (select follow_up_on from public.admission_enquiries where enquiry_no = 2)
      is not null,
    '29 reopening a lost enquiry restores a follow-up date');
  perform pg_temp.ok(
    (select lost_reason from public.admission_enquiries where enquiry_no = 2) is null,
    '30 ...and clears the stale lost reason');
end $$;

-- =============================================================================
-- 5. The list
-- =============================================================================
do $$
declare
  v_first  bigint;
  v_open   int;
  v_closed int;
begin
  -- Two open enquiries, one deliberately overdue.
  update public.admission_enquiries set follow_up_on = current_date - 9
   where enquiry_no = 3;

  select enquiry_no into v_first from public.fn_enquiry_list() limit 1;
  perform pg_temp.ok(v_first = 3,
    '31 the longest-waiting open enquiry is first, not the newest');

  perform pg_temp.ok(
    (select days_overdue from public.fn_enquiry_list() where enquiry_no = 3) = 9,
    '32 days_overdue counts from the follow-up date');
  perform pg_temp.ok(
    (select days_overdue from public.fn_enquiry_list() where enquiry_no = 1) = 0,
    '33 a closed enquiry is never reported as overdue');

  -- Closed rows sort last regardless of their dates.
  select count(*) filter (where status in ('new','contacted','visited')),
         count(*) filter (where status in ('admitted','lost'))
    into v_open, v_closed
  from public.fn_enquiry_list();
  perform pg_temp.ok(v_open > 0 and v_closed > 0,
    '34 the list shows open and closed together (the history is the value)');
end $$;

do $$
begin
  perform pg_temp.ok(
    (select count(*) from public.fn_enquiry_list(null, null, null, null, true)) = 1,
    '35 "due only" shows just the overdue open enquiry, not the closed or future');
  perform pg_temp.ok(
    (select count(*) from public.fn_enquiry_list('lost')) = 0,
    '36 filtering by status works (enquiry 2 was reopened, so nothing is lost)');
end $$;

-- Search. Getting the escaping wrong once meant a bare "%" returned the whole
-- school; see 0041.
do $$
declare v_all bigint;
begin
  select count(*) into v_all from public.fn_enquiry_list();
  perform pg_temp.ok((select count(*) from public.fn_enquiry_list(null,null,null,'%')) = 0,
    '37 searching "%" matches nothing, rather than returning every enquiry');
  perform pg_temp.ok((select count(*) from public.fn_enquiry_list(null,null,null,'_')) = 0,
    '38 searching "_" is escaped too');
  perform pg_temp.ok(
    (select count(*) from public.fn_enquiry_list(null,null,null,'Bilal')) = 1,
    '39 searching a real name finds it');
  perform pg_temp.ok(
    (select count(*) from public.fn_enquiry_list(null,null,null,'0300123')) >= 2,
    '40 searching a partial phone number finds the family''s enquiries');
  -- Searching "3" DOES also match every phone number containing a 3, and that
  -- is correct: the search is one box across name, phone and number, and a
  -- clerk typing 3 has not told us which they meant. So the promise is narrower
  -- than "only enquiry 3" — it is that the NUMBER match is exact rather than a
  -- substring, and that the enquiry is in the results.
  perform pg_temp.ok(
    exists (select 1 from public.fn_enquiry_list(null,null,null,'3') where enquiry_no = 3),
    '41 searching an enquiry number finds that enquiry');
  perform pg_temp.ok(
    (select count(*) from public.fn_enquiry_list(null,null,null,'13')) = 0,
    '41b the number match is exact — "13" does not match enquiry 1 or 3');
end $$;

-- total_count must describe the whole result, not the page — the mistake that
-- made the student roster claim a school had 50 children.
do $$
declare v_page bigint; v_total bigint;
begin
  select count(*), max(total_count) into v_page, v_total
  from public.fn_enquiry_list(null, null, null, null, false, 1, 0);
  perform pg_temp.ok(v_page = 1 and v_total > 1,
    format('42 total_count is the full match count (%s) not the page size (%s)',
           v_total, v_page));
end $$;

-- =============================================================================
-- 6. The summary, and the conversion rate that must not lie
-- =============================================================================
do $$
declare r jsonb;
begin
  r := public.fn_enquiry_summary();
  perform pg_temp.ok((r->>'admitted')::int = 1 and (r->>'decided')::int = 1,
    '43 one admitted, and only decided enquiries count as decided');
  perform pg_temp.ok((r->>'conversion_rate')::numeric = 100.0,
    '44 one admitted of one decided is 100%, not diluted by the open ones');
  perform pg_temp.ok((r->>'overdue')::int = 1,
    '45 the overdue count is what makes this a worklist rather than a report');
  perform pg_temp.ok((r->>'open_no_date')::int = 0,
    '46 no open enquiry is missing a follow-up date');
end $$;

-- A school on its first day has decided nothing. "0%" would be a lie.
do $$
declare
  v_c uuid; v_oc uuid := '00000000-0000-0000-0000-00000000e909';
  r jsonb;
begin
  perform set_config('test.uid', '', false);
  insert into public.schools (name) values ('Enq Fresh') returning id into v_c;
  insert into public.subscriptions (school_id, plan_code, status, trial_ends_on)
    values (v_c, 'growth', 'active', current_date + 30);
  alter table public.profiles disable trigger user;
  insert into auth.users (id, email) values (v_oc, 'eqf@eq.test') on conflict (id) do nothing;
  insert into public.profiles (id, full_name, role, school_id)
    values (v_oc, 'Enq Fresh Owner', 'owner', v_c)
    on conflict (id) do update set school_id = excluded.school_id, role = excluded.role,
                                   full_name = excluded.full_name, active = true;
  alter table public.profiles enable trigger user;
  perform set_config('test.uid', v_oc::text, false);

  r := public.fn_enquiry_summary();
  perform pg_temp.ok((r->>'conversion_rate') is null,
    '47 a school with nothing decided has a null conversion rate, not 0%');

  perform pg_temp.add(jsonb_build_object('child_name','Fresh Kid','phone','03111111111'));
  r := public.fn_enquiry_summary();
  perform pg_temp.ok((r->>'conversion_rate') is null and (r->>'open')::int = 1,
    '48 an enquiry taken today is open, not a failure');
  perform pg_temp.ok((r->>'admitted')::int = 0,
    '49 ...and a fresh school sees only its own single enquiry');

  perform pg_temp.be('Enq Owner');
end $$;

-- Where the enquiries came from, and which sources convert.
do $$
declare v_banner record;
begin
  select * into v_banner from public.fn_enquiry_sources() where source = 'banner';
  perform pg_temp.ok(v_banner.enquiries = 1 and v_banner.admitted = 1
                 and v_banner.conversion_rate = 100.0,
    '50 the source breakdown shows what the banner actually produced');
  perform pg_temp.ok(
    (select conversion_rate from public.fn_enquiry_sources() where source = 'walk_in')
      is null,
    '51 a source with nothing decided has a null rate, not a fake 0%');
end $$;

-- =============================================================================
-- 7. The WhatsApp toggle must genuinely block
-- =============================================================================
do $$
declare v_before int; v_after int; r jsonb;
begin
  update public.message_templates set enabled = false
   where school_id = public.current_school_id() and template_key = 'enquiry_received';

  select count(*) into v_before from public.message_outbox
   where school_id = public.current_school_id();
  r := pg_temp.add(jsonb_build_object('child_name','Silent Kid','phone','03007777777'));
  select count(*) into v_after from public.message_outbox
   where school_id = public.current_school_id();

  perform pg_temp.ok(v_after = v_before,
    '52 a disabled template writes NO outbox row — the toggle is not decorative');
  perform pg_temp.ok(not (r->>'message_queued')::boolean,
    '53 ...and the caller is told no message went out');
  perform pg_temp.ok((r->>'enquiry_id') is not null,
    '54 ...while the enquiry itself is still recorded');

  update public.message_templates set enabled = true
   where school_id = public.current_school_id() and template_key = 'enquiry_received';
end $$;

-- WhatsApp number wins over the landline, same as everywhere else.
--
-- Looked up by enquiry_id, NOT by "the most recent outbox row": now() is
-- transaction-stable in Postgres, so every row this suite creates shares one
-- created_at and "most recent" is an arbitrary tie-break. That is also the
-- reason message_outbox.enquiry_id exists — without it a queued enquiry message
-- could not be traced back to its enquiry from the WhatsApp queue either.
do $$
declare r jsonb; v_to text; v_eid uuid;
begin
  r := pg_temp.add(jsonb_build_object('child_name','Wa Kid','phone','0511234567',
                                      'whatsapp','03008888888'));
  v_eid := (r->>'enquiry_id')::uuid;
  select to_phone into v_to from public.message_outbox
   where school_id = public.current_school_id() and enquiry_id = v_eid;
  perform pg_temp.ok(v_to = '03008888888',
    '55 the WhatsApp number is preferred over the landline');
  perform pg_temp.ok(
    (select count(*) from public.message_outbox
      where school_id = public.current_school_id() and enquiry_id = v_eid) = 1,
    '55b a queued enquiry message points back at its enquiry');
end $$;

-- =============================================================================
-- 8. Tenant isolation
-- =============================================================================
do $$
declare v_a_ids uuid[];
begin
  select array_agg(id) into v_a_ids from public.admission_enquiries
   where school_id = public.current_school_id();

  perform pg_temp.be('Enq Other');
  perform public.fn_add_enquiry(jsonb_build_object('child_name','B Child','phone','03219999999'));

  perform pg_temp.ok((select count(*) from public.fn_enquiry_list()) = 1,
    '56 school B sees only its own enquiry');
  perform pg_temp.ok(
    (select enquiry_no from public.fn_enquiry_list() limit 1) = 1,
    '57 enquiry numbering restarts per school, so both can have number 1');
  perform pg_temp.ok((public.fn_enquiry_summary()->>'admitted')::int = 0,
    '58 school A''s admission does not appear in school B''s summary');

  -- Reading another school's enquiry by id must fail, not return a row.
  begin
    perform public.fn_enquiry_contacts(v_a_ids[1]);
    raise exception 'FAIL  59 school B read school A''s follow-up history';
  exception when others then
    if sqlerrm like '%FAIL  59%' then raise;
    else raise notice 'PASS  59 reading another school''s enquiry by id is refused';
    end if;
  end;

  begin
    perform public.fn_enquiry_admit(v_a_ids[1]);
    raise exception 'FAIL  60 school B admitted school A''s enquiry';
  exception when others then
    if sqlerrm like '%FAIL  60%' then raise;
    else raise notice 'PASS  60 admitting another school''s enquiry is refused';
    end if;
  end;

  perform pg_temp.be('Enq Owner');
end $$;

-- =============================================================================
-- 9. Who may touch the enquiry book
-- =============================================================================
do $$
begin
  perform pg_temp.be('Enq Clerk');
  perform public.fn_enquiry_list();
  perform public.fn_add_enquiry(jsonb_build_object('child_name','Clerk Kid','phone','03005555555'));
  raise notice 'PASS  61 a clerk on reception — who takes these calls — may record and read';

  perform pg_temp.be('Enq Teacher');
  begin
    perform public.fn_enquiry_list();
    raise exception 'FAIL  62 a class teacher read the enquiry book';
  exception when insufficient_privilege then
    raise notice 'PASS  62 a class teacher is refused';
  end;

  perform pg_temp.be('Enq Readonly');
  begin
    perform public.fn_add_enquiry(jsonb_build_object('child_name','X','phone','1'));
    raise exception 'FAIL  63 a readonly user recorded an enquiry';
  exception when insufficient_privilege then
    raise notice 'PASS  63 a readonly user cannot write';
  end;

  perform pg_temp.be('Enq Owner');
end $$;

-- profiles.active is enforced at current_school_id(), so a dismissed clerk
-- loses the enquiry book along with everything else.
do $$
declare v_clerk uuid;
begin
  select id into v_clerk from public.profiles where full_name = 'Enq Clerk';
  update public.profiles set active = false where id = v_clerk;
  perform set_config('test.uid', v_clerk::text, false);
  begin
    perform public.fn_enquiry_list();
    raise exception 'FAIL  64 a deactivated clerk read the enquiry book';
  exception when insufficient_privilege then
    raise notice 'PASS  64 a deactivated clerk is refused';
  end;
  update public.profiles set active = true where id = v_clerk;
  perform pg_temp.be('Enq Owner');
end $$;

-- Writes must go through the functions, so the enquiry number stays gapless and
-- the status transitions stay legal. `set local role` matters here: RLS does not
-- apply to the table owner, so without it this would pass for the wrong reason.
do $$
begin
  begin
    set local role authenticated;
    insert into public.admission_enquiries (school_id, enquiry_no, child_name, phone)
    values (public.current_school_id(), 9999, 'Direct Insert', '0300');
    reset role;
    raise exception 'FAIL  65 a direct INSERT bypassed the enquiry functions';
  exception when insufficient_privilege then
    reset role;
    raise notice 'PASS  65 no direct INSERT policy — writes go through the functions';
  end;
end $$;

-- DELETE is checked by ROW COUNT, not by catching an error, and the difference
-- matters. An INSERT with no matching policy raises; a DELETE or UPDATE with no
-- matching policy silently affects zero rows. So a test that only waits for an
-- exception here would fail to notice a real DELETE policy being added later —
-- it would just stop seeing the error it was looking for.
do $$
declare v_deleted int;
begin
  set local role authenticated;
  delete from public.admission_enquiries where enquiry_no = 1;
  get diagnostics v_deleted = row_count;
  reset role;

  perform pg_temp.ok(v_deleted = 0,
    '66 a direct DELETE removes nothing — the history is the product');
  perform pg_temp.ok(
    exists (select 1 from public.admission_enquiries
             where school_id = public.current_school_id() and enquiry_no = 1),
    '66b ...and the enquiry is demonstrably still there');
end $$;

-- Same for UPDATE: silently zero rows, so a clerk cannot reopen an admitted
-- enquiry or rewrite a lost reason behind the functions' backs.
do $$
declare v_upd int;
begin
  set local role authenticated;
  update public.admission_enquiries set status = 'new', lost_reason = null
   where enquiry_no = 1;
  get diagnostics v_upd = row_count;
  reset role;

  perform pg_temp.ok(v_upd = 0,
    '66c a direct UPDATE changes nothing — status transitions go through the functions');
  perform pg_temp.ok(
    (select status from public.admission_enquiries
      where school_id = public.current_school_id() and enquiry_no = 1) = 'admitted',
    '66d ...and the admitted enquiry was not quietly reopened');
end $$;

-- The internal message helper must not be callable by a logged-in user.
do $$
begin
  begin
    set local role authenticated;
    perform public.fn_queue_enquiry_message('enquiry_received', pg_temp.eid(3));
    reset role;
    raise exception 'FAIL  67 fn_queue_enquiry_message is callable by authenticated';
  exception when insufficient_privilege then
    reset role;
    raise notice 'PASS  67 the internal message helper is revoked from authenticated';
  end;
end $$;

rollback;

-- =============================================================================
-- Reviews: prove the average cannot be faked, INCLUDING BY US.
--
-- Storing a rating is easy. The whole value of 0093 is in the rules, and a rule
-- that is not tested is a comment. Every one of them is asserted here, and each
-- assertion is written so that REMOVING the rule makes the test fail.
--
-- The ones that matter most, because they are the ones somebody would be
-- tempted to loosen later:
--
--   * a clerk cannot review, and neither can a school that has not used it
--   * a reversed payment does not count towards "has used it"
--   * one review per school, enforced by an index and not by a form
--   * the cooling-off window really does hide a review
--   * an operator can hide only for abuse, and CANNOT hide for a low rating
--   * hiding writes an operator_actions row
--   * anon reads a view with no author column, not the table
--   * nobody signed in can write the table directly
--
-- Run: psql -v ON_ERROR_STOP=1 -f supabase/tests/reviews.sql
-- =============================================================================

\set ON_ERROR_STOP on
begin;

create or replace function auth.uid() returns uuid language sql stable as
  $$ select nullif(current_setting('test.uid', true), '')::uuid $$;

create temp table ids (k text primary key, v uuid);

-- =============================================================================
-- Seed: one school old enough and used enough, one brand new
-- =============================================================================
do $seed$
declare
  s_ok uuid := gen_random_uuid(); s_new uuid := gen_random_uuid();
  o_ok uuid := '00000000-0000-0000-0000-00000000e001';
  c_ok uuid := '00000000-0000-0000-0000-00000000e002';
  o_new uuid := '00000000-0000-0000-0000-00000000e003';
  cls uuid; sec uuid; stu uuid; fam uuid;
begin
  -- Old enough: created_at backdated 40 days.
  insert into public.schools (id, name, city, created_at)
    values (s_ok, 'Al Noor Public School', 'Sahiwal', now() - interval '40 days');
  insert into public.schools (id, name, city, created_at)
    values (s_new, 'Brand New Academy', 'Multan', now() - interval '2 days');
  insert into public.subscriptions (school_id, plan_code, status, trial_ends_on)
    values (s_ok, 'starter', 'active', current_date + 14),
           (s_new, 'starter', 'trialing', current_date + 12);

  -- profiles.id references auth.users, so the users have to exist first.
  insert into auth.users (id, email) values
    (o_ok, 'owner@alnoor.test'), (c_ok, 'clerk@alnoor.test'), (o_new, 'owner@brandnew.test')
    on conflict (id) do nothing;

  -- Triggers off while seeding: the role guard and the school guard exist to
  -- stop the APP doing this, and we are standing in for the service-role
  -- provisioning path that legitimately may.
  alter table public.profiles disable trigger user;
  insert into public.profiles (id, school_id, full_name, role) values
    (o_ok,  s_ok,  'Basha Salamat', 'owner'),
    (c_ok,  s_ok,  'Office Clerk',  'admin_clerk'),
    (o_new, s_new, 'New Owner',     'owner');
  alter table public.profiles enable trigger user;

  -- Enough real use: 25 confirmed payments. Seeded directly, standing in for
  -- the service-role path, because the point of the test is the review rules
  -- and not the fee counter.
  insert into public.classes (school_id, name, level_order)
    values (s_ok, 'Class 5', 5) returning id into cls;
  insert into public.sections (school_id, class_id, name) values (s_ok, cls, 'A') returning id into sec;
  insert into public.families (school_id, head_name) values (s_ok, 'Muhammad Aslam') returning id into fam;
  insert into public.students (school_id, gr_no, full_name, family_id, admission_date, status)
    values (s_ok, 'GR-1', 'Ahmed Raza', fam, current_date - 35, 'active') returning id into stu;

  insert into public.payments (school_id, student_id, family_id, amount, method, receipt_no, status)
    select s_ok, stu, fam, 1500, 'cash', 5000 + g, 'confirmed'
      from generate_series(1, 25) g;

  insert into ids values ('s_ok', s_ok), ('s_new', s_new),
                         ('o_ok', o_ok), ('c_ok', c_ok), ('o_new', o_new);
end $seed$;

-- =============================================================================
-- 1. Who may write one
-- =============================================================================
do $who$
declare e jsonb; msg text;
begin
  -- A CLERK MAY NOT. The clerk is not who decided to buy the software.
  perform set_config('test.uid', (select v::text from ids where k='c_ok'), false);
  e := public.fn_review_eligibility();
  if (e->>'may_review')::boolean then
    raise exception 'FAIL: a clerk may write the school''s review';
  end if;
  if e->>'reason' <> 'not_the_decision_maker' then
    raise exception 'FAIL: a clerk is refused for the wrong reason: %', e->>'reason';
  end if;

  begin
    perform public.fn_review_upsert(5::smallint, 'Very good', repeat('Good software. ', 5), 'named');
    raise exception 'FAIL: fn_review_upsert let a clerk through';
  exception when others then
    msg := SQLERRM;
    if msg like 'FAIL:%' then raise; end if;
  end;

  -- A BRAND NEW SCHOOL MAY NOT, however senior the person is.
  perform set_config('test.uid', (select v::text from ids where k='o_new'), false);
  e := public.fn_review_eligibility();
  if (e->>'may_review')::boolean then
    raise exception 'FAIL: a two day old school may write a review';
  end if;
  if e->>'reason' <> 'too_new' then
    raise exception 'FAIL: a new school is refused for the wrong reason: %', e->>'reason';
  end if;
  if (e->>'days_using')::int <> 2 then
    raise exception 'FAIL: days_using is % for a school seeded 2 days ago', e->>'days_using';
  end if;

  -- AN ELIGIBLE OWNER MAY.
  perform set_config('test.uid', (select v::text from ids where k='o_ok'), false);
  e := public.fn_review_eligibility();
  if not (e->>'may_review')::boolean then
    raise exception 'FAIL: an owner of a 40 day old school with 25 receipts is refused: %', e;
  end if;
  if (e->>'receipts')::int <> 25 then
    raise exception 'FAIL: receipts counted as % of 25', e->>'receipts';
  end if;

  raise notice 'ok: a clerk and a brand new school are both refused, an established owner is not';
end $who$;

-- =============================================================================
-- 2. A REVERSED payment does not buy eligibility
--
-- Otherwise twenty entered-and-reversed payments are a review, which is the
-- cheapest possible way to fake a customer.
-- =============================================================================
do $reversed$
declare s uuid; stu uuid; fam uuid; e jsonb; before int;
begin
  select v into s from ids where k='s_new';

  -- The caller is switched FIRST. enforce_school_id() refuses a write aimed at
  -- a school the caller does not belong to, and seeding this school's fixtures
  -- while still acting as the other school's owner is exactly that.
  perform set_config('test.uid', (select v::text from ids where k='o_new'), false);

  select id into fam from public.families where school_id = s limit 1;
  if fam is null then
    insert into public.families (school_id, head_name) values (s, 'Nobody') returning id into fam;
  end if;

  -- Age the new school past the 21 day gate so ONLY the receipt count is left
  -- as the thing under test.
  update public.schools set created_at = now() - interval '40 days' where id = s;

  e := public.fn_review_eligibility();
  before := (e->>'receipts')::int;

  insert into public.students (school_id, gr_no, full_name, family_id, admission_date, status)
    values (s, 'GR-N1', 'Test Pupil', fam, current_date - 30, 'active') returning id into stu;

  -- 30 payments, all of them reversals or reversed originals.
  insert into public.payments (school_id, student_id, family_id, amount, method, receipt_no, status)
    select s, stu, fam, 1000, 'cash', 9000 + g, 'reversed' from generate_series(1, 30) g;

  e := public.fn_review_eligibility();
  if (e->>'receipts')::int <> before then
    raise exception 'FAIL: % reversed payments raised the receipt count from % to %',
      30, before, e->>'receipts';
  end if;
  if (e->>'may_review')::boolean then
    raise exception 'FAIL: 30 reversed payments bought a review';
  end if;
  raise notice 'ok: reversed payments do not count towards having used the software';
end $reversed$;

-- =============================================================================
-- 3. Writing, the cooling-off window, and one per school
-- =============================================================================
do $write$
declare rid uuid; rid2 uuid; n int; pub int;
begin
  perform set_config('test.uid', (select v::text from ids where k='o_ok'), false);
  rid := public.fn_review_upsert(
    5::smallint, 'Our clerk stopped dreading the first of the month',
    'We ran one class in parallel for two weeks and the totals agreed with our register, so we moved the whole school over. The part that changed the office was one payment covering all three of a family''s children.',
    'named');
  if rid is null then raise exception 'FAIL: an eligible owner could not write a review'; end if;

  -- INVISIBLE during the window. This is the assertion that a removed cooling
  -- off period would break.
  select count(*) into pub from public.reviews_public where id = rid;
  if pub <> 0 then
    raise exception 'FAIL: a review is public during its 24 hour cooling-off window';
  end if;
  select total into n from public.reviews_summary;
  if n <> 0 then
    raise exception 'FAIL: the summary counts a review still inside its window (total=%)', n;
  end if;

  -- ONE PER SCHOOL: a second write is an edit of the same row.
  rid2 := public.fn_review_upsert(
    4::smallint, 'Good, with one thing I would change',
    'Changed my mind about the fifth star: the attendance screen is excellent but I would like the fee report to remember which class I looked at last. Everything else has held up over a term.',
    'named');
  if rid2 <> rid then
    raise exception 'FAIL: a second review created a new row (% then %), so a school can review itself twice', rid, rid2;
  end if;
  select count(*) into n from public.reviews where school_id = (select v from ids where k='s_ok');
  if n <> 1 then raise exception 'FAIL: % review rows for one school', n; end if;

  -- Now let the window elapse and confirm it becomes public with no scheduler.
  update public.reviews set publish_at = now() - interval '1 minute' where id = rid;
  select count(*) into pub from public.reviews_public where id = rid;
  if pub <> 1 then
    raise exception 'FAIL: a review whose window has passed is still not public';
  end if;
  select total into n from public.reviews_summary;
  if n <> 1 then raise exception 'FAIL: summary total is % after one review went public', n; end if;

  -- EDITING RE-ARMS THE WINDOW, or a public five-star review could be rewritten
  -- into anything with no pause at all.
  perform public.fn_review_upsert(
    5::smallint, 'Back to five stars after the update',
    'They shipped the thing I asked for in my last review, so I am putting the star back. Two terms in now and the reconciliation screen has found real money twice.',
    'named');
  select count(*) into pub from public.reviews_public where id = rid;
  if pub <> 0 then
    raise exception 'FAIL: editing a published review did not put it back into the window';
  end if;

  raise notice 'ok: one review per school, invisible for 24 hours, public afterwards with no scheduler, and an edit re-arms the window';
end $write$;

-- =============================================================================
-- 4. What the public can and cannot read
-- =============================================================================
do $public$
declare txt text; n int; cols text;
begin
  -- Make it public again for these checks.
  update public.reviews set publish_at = now() - interval '1 minute'
   where school_id = (select v from ids where k='s_ok');

  -- The view must not expose who wrote it or why it was hidden.
  select string_agg(column_name, ',' order by column_name) into cols
    from information_schema.columns
   where table_schema = 'public' and table_name = 'reviews_public';
  if cols like '%author%' then
    raise exception 'FAIL: reviews_public exposes an author column: %', cols;
  end if;
  if cols like '%hidden%' then
    raise exception 'FAIL: reviews_public exposes the moderation columns: %', cols;
  end if;

  -- city_only really hides the school's name.
  perform set_config('test.uid', (select v::text from ids where k='o_ok'), false);
  perform public.fn_review_upsert(
    5::smallint, 'Anonymous but real',
    'I would rather not have our school named on a website, but the software is worth saying something about. The fee side alone paid for it in the first term we used it properly.',
    'city_only');
  update public.reviews set publish_at = now() - interval '1 minute'
   where school_id = (select v from ids where k='s_ok');

  select school_name into txt from public.reviews_public limit 1;
  if txt <> 'A school' then
    raise exception 'FAIL: city_only still printed the school name: %', txt;
  end if;
  select city into txt from public.reviews_public limit 1;
  if txt is distinct from 'Sahiwal' then
    raise exception 'FAIL: city_only lost the city, which it is supposed to keep: %', txt;
  end if;

  -- ANON reads the views and NOT the table.
  set local role anon;
  begin
    select count(*) into n from public.reviews;
    reset role;
    raise exception 'FAIL: anon can read public.reviews directly';
  exception when insufficient_privilege then
    reset role;
  end;
  set local role anon;
  select count(*) into n from public.reviews_public;
  if n <> 1 then reset role; raise exception 'FAIL: anon sees % public reviews, expected 1', n; end if;
  select total into n from public.reviews_summary;
  reset role;
  if n <> 1 then raise exception 'FAIL: anon sees a summary total of %', n; end if;

  raise notice 'ok: anon reads the views and not the table, and city_only keeps the city but not the name';
end $public$;

-- =============================================================================
-- 5. Nobody signed in may write the table directly
-- =============================================================================
do $direct$
declare n int;
begin
  perform set_config('test.uid', (select v::text from ids where k='o_ok'), false);
  set local role authenticated;

  begin
    insert into public.reviews (school_name, rating, title, body)
      values ('Invented School', 5, 'Five stars', repeat('Wonderful software. ', 4));
    reset role;
    raise exception 'FAIL: a signed-in user can INSERT a review directly, so any rating can be forged';
  exception when insufficient_privilege then null;
  end;

  begin
    update public.reviews set rating = 5;
    reset role;
    raise exception 'FAIL: a signed-in user can UPDATE a rating directly';
  exception when insufficient_privilege then null;
  end;

  begin
    delete from public.reviews;
    reset role;
    raise exception 'FAIL: a signed-in user can DELETE a review directly';
  exception when insufficient_privilege then null;
  end;

  reset role;
  raise notice 'ok: insert, update and delete on reviews are all closed to a signed-in session';
end $direct$;

-- =============================================================================
-- 6. The operator's power is narrow, and it is logged
-- =============================================================================
do $mod$
declare rid uuid; admin uuid := '00000000-0000-0000-0000-00000000e0aa'; n int; msg text;
begin
  select id into rid from public.reviews
   where school_id = (select v from ids where k='s_ok') limit 1;
  update public.reviews set publish_at = now() - interval '1 minute' where id = rid;

  -- A NON-OPERATOR CANNOT HIDE ANYTHING.
  perform set_config('test.uid', (select v::text from ids where k='o_ok'), false);
  begin
    perform public.fn_platform_review_hide(rid, 'spam', null);
    raise exception 'FAIL: a school owner can hide a review';
  exception when others then
    msg := SQLERRM;
    if msg like 'FAIL:%' then raise; end if;
  end;

  insert into auth.users (id, email) values (admin, 'ops@example.test')
    on conflict (id) do nothing;
  insert into public.platform_admins (user_id, email) values (admin, 'ops@example.test')
    on conflict (user_id) do nothing;
  perform set_config('test.uid', admin::text, false);

  -- AN INVENTED REASON IS REFUSED. "It is negative" is not on the list, and
  -- this is the assertion that would fail if somebody added it.
  begin
    perform public.fn_platform_review_hide(rid, 'unflattering', 'we do not like it');
    raise exception 'FAIL: a review was hidden for a reason that is not abuse';
  exception when others then
    msg := SQLERRM;
    if msg like 'FAIL:%' then raise; end if;
  end;
  begin
    perform public.fn_platform_review_hide(rid, 'low_rating', 'one star');
    raise exception 'FAIL: "low_rating" was accepted as a reason to hide a review';
  exception when others then
    msg := SQLERRM;
    if msg like 'FAIL:%' then raise; end if;
  end;

  -- The two judgement categories need a written explanation.
  begin
    perform public.fn_platform_review_hide(rid, 'not_a_customer', 'no');
    raise exception 'FAIL: not_a_customer was accepted with a two character note';
  exception when others then
    msg := SQLERRM;
    if msg like 'FAIL:%' then raise; end if;
  end;

  -- A REAL ABUSE HIDE WORKS, removes it from public, and is logged.
  select count(*) into n from public.operator_actions where action = 'review.hide';
  perform public.fn_platform_review_hide(rid, 'names_a_child', null);
  if (select count(*) from public.reviews_public where id = rid) <> 0 then
    raise exception 'FAIL: a hidden review is still in reviews_public';
  end if;
  if (select total from public.reviews_summary) <> 0 then
    raise exception 'FAIL: a hidden review is still counted in the summary';
  end if;
  if (select count(*) from public.operator_actions where action = 'review.hide') <> n + 1 then
    raise exception 'FAIL: hiding a review wrote no operator_actions row';
  end if;
  if (select detail->>'reason' from public.operator_actions
       where action = 'review.hide' order by at desc limit 1) <> 'names_a_child' then
    raise exception 'FAIL: the logged reason is not the one given';
  end if;
  -- The rating is logged too, so hiding a run of one-star reviews is visible
  -- in the log without reading each review.
  if (select detail->>'rating' from public.operator_actions
       where action = 'review.hide' order by at desc limit 1) is null then
    raise exception 'FAIL: the operator log does not record the rating that was hidden';
  end if;

  -- RESTORING needs a written reason and puts it back.
  begin
    perform public.fn_platform_review_restore(rid, 'oops');
    raise exception 'FAIL: a review was restored with a four character reason';
  exception when others then
    msg := SQLERRM;
    if msg like 'FAIL:%' then raise; end if;
  end;
  perform public.fn_platform_review_restore(rid, 'Checked with the school: no child is named.');
  update public.reviews set publish_at = now() - interval '1 minute' where id = rid;
  if (select count(*) from public.reviews_public where id = rid) <> 1 then
    raise exception 'FAIL: a restored review is not public again';
  end if;
  if (select count(*) from public.operator_actions where action = 'review.restore') < 1 then
    raise exception 'FAIL: restoring a review wrote no operator_actions row';
  end if;

  raise notice 'ok: only an operator may hide, only for a listed abuse category, never for a low rating, and every hide and restore is logged';
end $mod$;

-- =============================================================================
-- 7. Withdrawing, and what happens when a school is purged
-- =============================================================================
do $life$
declare s uuid; rid uuid; n int;
begin
  select v into s from ids where k='s_ok';
  select id into rid from public.reviews where school_id = s limit 1;

  perform set_config('test.uid', (select v::text from ids where k='o_ok'), false);
  if public.fn_review_withdraw() <> 1 then
    raise exception 'FAIL: the author could not withdraw their own review';
  end if;
  if (select count(*) from public.reviews_public where id = rid) <> 0 then
    raise exception 'FAIL: a withdrawn review is still public';
  end if;

  -- The partial unique index must free up, or a school that withdraws can never
  -- review again.
  perform public.fn_review_upsert(
    3::smallint, 'Second attempt, more measured',
    'I withdrew the first one because I wrote it in a good mood on a Friday. Two terms in, three stars is fair: the fee side is excellent and the reports still need work.',
    'named');
  select count(*) into n from public.reviews where school_id = s and status <> 'withdrawn';
  if n <> 1 then
    raise exception 'FAIL: after withdrawing, a school has % live reviews instead of 1', n;
  end if;

  -- A PURGED SCHOOL'S REVIEW SURVIVES. ON DELETE SET NULL, not CASCADE: if a
  -- school leaving could delete its own review, a departure would quietly raise
  -- our average, which is the one thing this table must never allow.
  update public.reviews set publish_at = now() - interval '1 minute' where school_id = s;
  select count(*) into n from public.reviews_public;
  if n <> 1 then raise exception 'FAIL: expected 1 public review before the purge, found %', n; end if;

  -- Stand in for fn_platform_purge_school's final step.
  delete from public.payments where school_id = s;
  delete from public.students where school_id = s;
  delete from public.families where school_id = s;
  delete from public.sections where school_id = s;
  delete from public.classes where school_id = s;
  delete from public.subscriptions where school_id = s;
  -- guard_profile_school() refuses to move a user between schools, and it is
  -- right to: it is what stops a clerk being reassigned into another school's
  -- data. fn_platform_purge_school runs as the definer past it; here we stand
  -- in for that path explicitly rather than pretending the guard is not there.
  alter table public.profiles disable trigger user;
  update public.profiles set school_id = null where school_id = s;
  alter table public.profiles enable trigger user;
  delete from public.school_settings where school_id = s;
  delete from public.audit_log where school_id = s;
  update public.operator_actions set school_id = null where school_id = s;
  delete from public.reviews r where false;   -- explicitly NOT deleting reviews
  delete from public.schools where id = s;

  select count(*) into n from public.reviews_public;
  if n <> 1 then
    raise exception 'FAIL: purging the school removed its review from public view (% left)', n;
  end if;
  if (select school_id from public.reviews where id is not null limit 1) is not null then
    raise exception 'FAIL: the review still references a school that no longer exists';
  end if;

  raise notice 'ok: an author may withdraw and write again, and a purged school''s review survives with no school_id';
end $life$;

select 'REVIEWS: ALL TESTS PASSED' as result;

rollback;

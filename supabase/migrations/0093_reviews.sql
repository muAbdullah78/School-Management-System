-- =============================================================================
-- 0093  Customer reviews, and the rules that make them worth reading
--
-- WHAT THIS IS FOR. A school owner deciding whether to ring us wants to know
-- what other Pakistani schools think. There was no way to say anything, so the
-- only reviews of this product were the ones we wrote about ourselves, which
-- are worth nothing to a buyer and are exactly what Google calls self-serving.
--
-- THE DESIGN PROBLEM IS NOT "STORE A RATING". It is: how do you build a review
-- system whose average cannot be faked, INCLUDING BY US? Anybody can add a
-- five-star row to a table. So the rules are here, in the database, and not in
-- a form:
--
--   1. ONE REVIEW PER SCHOOL. A unique constraint, not a check in the UI.
--   2. ONLY AN OWNER OR PRINCIPAL of that school may write it. A clerk is not
--      the person who decided to buy.
--   3. THE SCHOOL MUST HAVE ACTUALLY USED IT: 21 days since the school was
--      created and 20 real receipts issued. A signup-and-review farm cannot
--      clear that, and a school that has not taken twenty fees has not formed
--      an opinion worth publishing.
--   4. A COOLING-OFF WINDOW. For 24 hours a review is the author's alone:
--      editable, withdrawable, invisible. Then it is public, and nobody has to
--      approve it. That is the point: an approval queue is a place where
--      inconvenient reviews go to die. It is not even a scheduled job, because
--      a job that stops running would hide every review silently. Publication
--      is a condition on the read.
--   5. THE OPERATOR MAY HIDE ONLY FOR ABUSE, and must name which kind. The
--      categories are a CHECK constraint, and "it is negative" is not one of
--      them. Every hide writes an operator_actions row, so hiding a run of
--      one-star reviews is a visible pattern rather than a private decision.
--   6. THE AGGREGATE INCLUDES EVERY PUBLISHED REVIEW, and the public summary
--      carries the full distribution and the count. An average of 4.9 over
--      three reviews reads as three reviews, and a curated average is obvious
--      from a distribution with a hole in it.
--
-- WHAT THIS DELIBERATELY DOES NOT DO. It does not promise stars in Google.
-- Google does not show review snippets for self-serving reviews on an
-- Organization, and even for a SoftwareApplication it is at their discretion.
-- docs/SEO.md says so plainly. The reason to build this is the school owner
-- reading the page, not the search result.
--
-- WHY ANON READS A VIEW AND NOT A FUNCTION. 0071 closed the whole function
-- surface to anon and check-definer-idor.py fails CI if one function in public
-- is executable without a login. So the public read is a table policy plus an
-- explicit column grant, exactly as 0082 did for plans and app_releases: a
-- policy says which rows and a grant says which columns can be reached at all.
--
-- Re-runnable.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. The table
-- ---------------------------------------------------------------------------
create table if not exists public.reviews (
  id            uuid primary key default gen_random_uuid(),

  -- SET NULL rather than CASCADE, and this is the 0080 pattern. If a school is
  -- purged, its review stays as the anonymous opinion of a school that once
  -- used this. Deleting it would let a school's departure quietly raise our
  -- average, which is the one thing this table must not allow.
  school_id     uuid references public.schools(id) on delete set null,

  -- Kept for the record even after the person leaves the school. Not shown
  -- publicly unless display_mode says so.
  author        uuid,
  author_name   text,
  school_name   text not null,
  city          text,

  rating        smallint not null check (rating between 1 and 5),
  title         text not null check (length(btrim(title)) between 4 and 90),
  body          text not null check (length(btrim(body)) between 40 and 1800),

  -- What the public page is allowed to print. The reviewer chooses, because it
  -- is their school's name.
  --   named     the school's name and city
  --   city_only "A school in Sahiwal"
  display_mode  text not null default 'named'
                check (display_mode in ('named', 'city_only')),

  -- THREE states, and 'published' is deliberately not one of them.
  --
  --   live      the normal state. Public once publish_at has passed.
  --   hidden    an operator removed it for abuse, with a reason below.
  --   withdrawn the author took it down.
  --
  -- Publication is a CONDITION ON A READ, not a status somebody sets, because
  -- the alternative is a scheduler. A cron job that flips pending to published
  -- fails silently when it stops running, and the failure mode is every review
  -- invisible for ever with nothing anywhere saying so. Nothing has to happen
  -- for a review to go live, which is the only way to be certain it will.
  status        text not null default 'live'
                check (status in ('live', 'hidden', 'withdrawn')),

  -- The end of the cooling-off window. Before this the review is the author's
  -- alone: editable, withdrawable, and invisible to the public.
  publish_at    timestamptz not null default now() + interval '24 hours',

  -- Only ever an abuse category. There is deliberately no value here meaning
  -- "unflattering", and the CHECK is what makes that a fact rather than a
  -- policy somebody could quietly change in a form.
  hidden_reason text check (hidden_reason in (
                  'spam', 'not_a_customer', 'abusive_language',
                  'names_a_child', 'names_a_person', 'off_topic'
                )),
  hidden_note   text,
  hidden_by     uuid,
  hidden_at     timestamptz,

  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);

-- ONE PER SCHOOL. A partial unique index rather than a plain one, so a
-- withdrawn review does not block the school from ever writing another.
create unique index if not exists reviews_one_per_school
  on public.reviews (school_id)
  where school_id is not null and status <> 'withdrawn';

create index if not exists reviews_public_idx
  on public.reviews (status, publish_at desc);

-- A hidden row must say why. Enforced as a table constraint rather than trusted
-- to the function, so a direct write by service role cannot skip it either.
alter table public.reviews drop constraint if exists reviews_hidden_needs_reason;
alter table public.reviews add constraint reviews_hidden_needs_reason check (
  (status = 'hidden') = (hidden_reason is not null)
);

alter table public.reviews enable row level security;

-- ---------------------------------------------------------------------------
-- 2. Eligibility, as one function so the app and the writer cannot disagree
--
-- Returns a jsonb the app can render directly: whether this user may write a
-- review, and if not, exactly which condition is unmet. A form that says only
-- "you cannot review" teaches the user nothing and generates a support call.
-- ---------------------------------------------------------------------------
create or replace function public.fn_review_eligibility()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_school uuid := public.current_school_id();
  v_role   public.user_role;
  v_age    integer;
  v_paid   integer;
  v_have   uuid;
begin
  if v_school is null then
    return jsonb_build_object('may_review', false, 'reason', 'no_school');
  end if;

  select role into v_role from public.profiles where id = auth.uid();
  select greatest(0, (current_date - created_at::date))::integer into v_age
    from public.schools where id = v_school;

  -- Real receipts only: a reversal is not a collection, and counting one would
  -- let twenty entered-and-reversed payments buy eligibility.
  select count(*)::integer into v_paid
    from public.payments
   where school_id = v_school
     and reversal_of is null
     and coalesce(status, 'confirmed') <> 'reversed';

  select id into v_have
    from public.reviews
   where school_id = v_school and status <> 'withdrawn'
   limit 1;

  return jsonb_build_object(
    'may_review', (v_role in ('owner', 'principal') and v_age >= 21 and v_paid >= 20),
    'reason', case
      when v_role not in ('owner', 'principal') then 'not_the_decision_maker'
      when v_age < 21 then 'too_new'
      when v_paid < 20 then 'not_enough_use'
      else null end,
    'role', v_role,
    'days_using', v_age,
    'days_needed', 21,
    'receipts', v_paid,
    'receipts_needed', 20,
    'existing_review', v_have
  );
end;
$$;

revoke all on function public.fn_review_eligibility() from public, anon;
grant execute on function public.fn_review_eligibility() to authenticated;

-- ---------------------------------------------------------------------------
-- 3. Writing one
--
-- Upsert, so editing during the cooling-off window is the same call. Editing
-- RESETS the window: a review that has been rewritten has not been sat with
-- for 24 hours yet.
-- ---------------------------------------------------------------------------
create or replace function public.fn_review_upsert(
  p_rating smallint,
  p_title text,
  p_body text,
  p_display_mode text default 'named'
) returns uuid language plpgsql security definer set search_path = public as $$
declare
  v_school uuid := public.current_school_id();
  v_elig   jsonb := public.fn_review_eligibility();
  v_id     uuid;
  v_name   text;
  v_city   text;
  v_author text;
begin
  if not (v_elig->>'may_review')::boolean then
    raise exception 'You cannot write a review yet: %', coalesce(v_elig->>'reason', 'unknown')
      using hint = 'fn_review_eligibility() says which condition is unmet';
  end if;
  if p_display_mode is null or p_display_mode not in ('named', 'city_only') then
    raise exception 'display_mode must be named or city_only';
  end if;

  -- The school's own name at the time of writing, not a name the caller sends.
  -- A parameter here would let a reviewer print any school's name they liked.
  select coalesce(nullif(btrim(s.name), ''), 'A school') , s.city
    into v_name, v_city
    from public.schools s where s.id = v_school;
  select full_name into v_author from public.profiles where id = auth.uid();

  insert into public.reviews as r
    (school_id, author, author_name, school_name, city,
     rating, title, body, display_mode, status, publish_at, updated_at)
  values
    (v_school, auth.uid(), v_author, v_name, v_city,
     p_rating, btrim(p_title), btrim(p_body), p_display_mode,
     'live', now() + interval '24 hours', now())
  on conflict (school_id) where (school_id is not null and status <> 'withdrawn')
  do update set
    rating = excluded.rating,
    title = excluded.title,
    body = excluded.body,
    display_mode = excluded.display_mode,
    school_name = excluded.school_name,
    city = excluded.city,
    -- A rewritten review goes back into the window. Otherwise a review that
    -- has been public for a year could be edited into anything with no pause,
    -- and an operator who hid it for abuse would find the hide undone by the
    -- same edit.
    status = 'live',
    publish_at = now() + interval '24 hours',
    hidden_reason = null, hidden_note = null, hidden_by = null, hidden_at = null,
    updated_at = now()
  where r.author = auth.uid() or public.has_role('owner')
  returning id into v_id;

  if v_id is null then
    raise exception 'This school already has a review written by somebody else'
      using hint = 'An owner may replace it; a principal may not replace an owner''s';
  end if;
  return v_id;
end;
$$;

revoke all on function public.fn_review_upsert(smallint, text, text, text)
  from public, anon;
grant execute on function public.fn_review_upsert(smallint, text, text, text) to authenticated;

-- ---------------------------------------------------------------------------
-- 4. Withdrawing one
--
-- The author's own review, at any time, published or not. Marked withdrawn
-- rather than deleted so the partial unique index frees up and the row remains
-- as evidence that it existed.
-- ---------------------------------------------------------------------------
create or replace function public.fn_review_withdraw() returns integer
language plpgsql security definer set search_path = public as $$
declare v_n integer;
begin
  update public.reviews
     set status = 'withdrawn', updated_at = now()
   where school_id = public.current_school_id()
     and status <> 'withdrawn'
     and (author = auth.uid() or public.has_role('owner'));
  get diagnostics v_n = row_count;
  return v_n;
end;
$$;

revoke all on function public.fn_review_withdraw() from public, anon;
grant execute on function public.fn_review_withdraw() to authenticated;

-- ---------------------------------------------------------------------------
-- 5. Reading your own school's review, whatever state it is in
-- ---------------------------------------------------------------------------
drop policy if exists reviews_select_own on public.reviews;
create policy reviews_select_own on public.reviews for select to authenticated
  using (school_id = public.current_school_id() or public.is_platform_admin());

grant select on public.reviews to authenticated;

-- No direct writes by anybody signed in. Everything goes through the functions
-- above, which is what makes the eligibility rules unavoidable rather than
-- advisory. Same posture as the fourteen money tables closed by 0086.
revoke insert, update, delete on public.reviews from authenticated;

-- AND THE TABLE IS TAKEN AWAY FROM anon EXPLICITLY, which the test suite is
-- what found.
--
-- Supabase's default privileges grant every new table in `public` to anon and
-- authenticated, and RLS is then the only thing standing in the way. For this
-- table RLS would have held, because reviews_select_own is `to authenticated`
-- and anon has no policy at all, so an anonymous SELECT returns zero rows.
--
-- But "returns zero rows because no policy matched" and "cannot reach the
-- table" are different guarantees, and the difference is one accidentally
-- permissive policy wide. The author's user id, the author's name, the
-- moderation note and the hidden reason all live in these columns. anon reads
-- reviews_public, which is a view with none of them in it, so there is no
-- reason for the table itself to be reachable and a good reason for it not to
-- be.
revoke all on public.reviews from anon;

-- ---------------------------------------------------------------------------
-- 6. What the public may read
--
-- A VIEW, so anon never touches the table and cannot reach a column that is
-- not on this list. The author's name, the author's user id, the operator's
-- note and the hidden reason are all absent by construction rather than by a
-- policy somebody could widen.
--
-- security_invoker = off (the default for a view owned by the definer) would
-- bypass the table's RLS, which here is exactly what is wanted and is why the
-- column list is the security boundary. The WHERE clause is the row boundary.
-- ---------------------------------------------------------------------------
create or replace view public.reviews_public as
  select
    r.id,
    r.rating,
    r.title,
    r.body,
    -- The reviewer's choice, applied here rather than trusted to a client.
    case when r.display_mode = 'named' then r.school_name
         else 'A school' end as school_name,
    r.city,
    r.display_mode,
    -- The date only. A timestamp to the second on a page listing four schools
    -- is enough to work out which review is whose if you know when you wrote
    -- yours.
    r.publish_at::date as published_on
  from public.reviews r
 where r.status = 'live'
   and r.publish_at <= now();

alter view public.reviews_public set (security_invoker = off);

grant select on public.reviews_public to anon, authenticated;

-- ---------------------------------------------------------------------------
-- 7. The summary, including the distribution
--
-- The distribution is not decoration. An average alone can be curated; an
-- average shown beside "five stars: 12, four: 3, three: 0, two: 0, one: 0"
-- either matches or does not, and a run of hidden one-star reviews leaves a
-- hole anybody can see. Published as a view for the same reason as above.
-- ---------------------------------------------------------------------------
create or replace view public.reviews_summary as
  select
    count(*)::integer as total,
    -- Two decimals is what schema.org's ratingValue wants and what a page
    -- should print. Null with no reviews, so the caller cannot render "0.0 out
    -- of 5", which would read as the worst possible score rather than as
    -- silence.
    case when count(*) > 0
      then round(avg(rating)::numeric, 2)
      else null end as average,
    count(*) filter (where rating = 5)::integer as five,
    count(*) filter (where rating = 4)::integer as four,
    count(*) filter (where rating = 3)::integer as three,
    count(*) filter (where rating = 2)::integer as two,
    count(*) filter (where rating = 1)::integer as one
  from public.reviews_public;

alter view public.reviews_summary set (security_invoker = off);

grant select on public.reviews_summary to anon, authenticated;

-- ---------------------------------------------------------------------------
-- 8. The operator's ONLY power over a review
--
-- Hide it for abuse, naming which kind, or put it back. There is no function
-- here that edits a rating, a title or a body, and there is no category
-- meaning "unflattering". The categories are a CHECK constraint on the table,
-- so this is a fact about the schema rather than a promise about the console.
--
-- Every call writes an operator_actions row, which is what turns hiding a run
-- of one-star reviews from a private decision into a visible pattern.
-- ---------------------------------------------------------------------------
create or replace function public.fn_platform_review_hide(
  p_id uuid, p_reason text, p_note text default null
) returns void language plpgsql security definer set search_path = public as $$
declare v_school uuid; v_rating smallint;
begin
  if not public.is_platform_admin() then
    raise exception 'Only a platform operator may hide a review';
  end if;
  if p_reason is null or p_reason not in (
       'spam', 'not_a_customer', 'abusive_language',
       'names_a_child', 'names_a_person', 'off_topic') then
    raise exception 'A review may only be hidden for abuse, and the reason must be one of: spam, not_a_customer, abusive_language, names_a_child, names_a_person, off_topic'
      using hint = 'A review being negative is not a reason to hide it';
  end if;
  -- A note is required for the two categories that are a judgement about a
  -- person rather than about the text, because those are the two somebody
  -- could reach for to hide criticism.
  if p_reason in ('not_a_customer', 'off_topic')
     and coalesce(length(btrim(p_note)), 0) < 15 then
    raise exception 'Hiding a review as % needs a written explanation of at least 15 characters', p_reason;
  end if;

  update public.reviews
     set status = 'hidden', hidden_reason = p_reason, hidden_note = nullif(btrim(p_note), ''),
         hidden_by = auth.uid(), hidden_at = now(), updated_at = now()
   where id = p_id
     and status <> 'withdrawn'
  returning school_id, rating into v_school, v_rating;

  if v_school is null and not exists (select 1 from public.reviews where id = p_id) then
    raise exception 'No such review';
  end if;

  perform public.fn__log_operator_action(
    'review.hide', v_school,
    jsonb_build_object('review_id', p_id, 'reason', p_reason,
                       'rating', v_rating, 'note', nullif(btrim(p_note), '')));
end;
$$;

create or replace function public.fn_platform_review_restore(p_id uuid, p_note text)
returns void language plpgsql security definer set search_path = public as $$
declare v_school uuid;
begin
  if not public.is_platform_admin() then
    raise exception 'Only a platform operator may restore a review';
  end if;
  if coalesce(length(btrim(p_note)), 0) < 10 then
    raise exception 'Restoring a review needs a written reason of at least 10 characters';
  end if;

  update public.reviews
     set status = 'live', hidden_reason = null, hidden_note = null,
         hidden_by = null, hidden_at = null, updated_at = now()
   where id = p_id and status = 'hidden'
  returning school_id into v_school;

  perform public.fn__log_operator_action(
    'review.restore', v_school,
    jsonb_build_object('review_id', p_id, 'note', btrim(p_note)));
end;
$$;

-- Everything an operator sees, including hidden rows, for the console.
create or replace function public.fn_platform_reviews(p_limit integer default 200)
returns table (
  id uuid, school_id uuid, school_name text, city text, author_name text,
  rating smallint, title text, body text, display_mode text, status text,
  publish_at timestamptz, is_public boolean,
  hidden_reason text, hidden_note text, hidden_at timestamptz,
  created_at timestamptz, updated_at timestamptz
) language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_platform_admin() then
    raise exception 'Only a platform operator may list reviews';
  end if;
  return query
    select r.id, r.school_id, r.school_name, r.city, r.author_name,
           r.rating, r.title, r.body, r.display_mode, r.status,
           r.publish_at,
           (r.status = 'live' and r.publish_at <= now()) as is_public,
           r.hidden_reason, r.hidden_note, r.hidden_at,
           r.created_at, r.updated_at
      from public.reviews r
     order by r.created_at desc
     limit greatest(1, least(coalesce(p_limit, 200), 1000));
end;
$$;

revoke all on function public.fn_platform_review_hide(uuid, text, text) from public, anon;
revoke all on function public.fn_platform_review_restore(uuid, text) from public, anon;
revoke all on function public.fn_platform_reviews(integer) from public, anon;
grant execute on function public.fn_platform_review_hide(uuid, text, text) to authenticated;
grant execute on function public.fn_platform_review_restore(uuid, text) to authenticated;
grant execute on function public.fn_platform_reviews(integer) to authenticated;

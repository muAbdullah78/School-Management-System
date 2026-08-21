-- =============================================================================
-- 0043 — Let a school edit and switch off what its parents receive.
--
-- WHY
--
-- message_templates has existed since 0034 with a `body` and an `enabled` flag,
-- seeded per school, and NOTHING in the app has ever read or written it. So the
-- wording a school sends to three hundred parents was fixed by a migration, and
-- a school that wanted to stop one of the five message types had no way to.
--
-- The RLS policy on the table already permits owner/principal to write, so the
-- app can edit these directly — no RPC is needed for that half. What is missing
-- is a way BACK: a school that deletes half a template and sends it out needs to
-- restore the original, and the originals live here in SQL.
--
-- This mirrors OurSchoolSoftware's "Automation Settings", where every event has
-- an editable body, a visible list of supported merge tags, and an Enabled
-- toggle so a school can silence any single one. Theirs is SMS; ours is
-- WhatsApp click-to-chat, so the same workflow costs nothing to run.
--
-- WHAT THIS AVOIDS
--
-- The default bodies were written out once inside fn__seed_message_templates.
-- Adding a reset would have meant a second copy of the same five paragraphs,
-- which would drift. They are extracted here into one function that both the
-- seed and the reset call, so there is exactly one place the wording lives.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. The defaults, in one place, with the merge tags each one may use.
--
-- The tag list is a FACT ABOUT THE CALL SITE, not decoration: {receipt} only
-- resolves for payment_received because fn__queue_payment_receipt is the only
-- caller that passes it. Showing a school a tag that will never resolve means
-- they put it in a message and a parent receives the literal "{receipt}".
--
-- Universal tags, filled in by fn_queue_message for every template:
--   {parent} {children} {school} {date} {balance}
-- ---------------------------------------------------------------------------
create or replace function public.fn__default_message_templates()
returns table (template_key text, label text, body text, tags text[])
language sql immutable set search_path = public as $$
  values
    ('payment_received', 'Payment received',
     'Assalam-o-Alaikum {parent}. We have received Rs {amount} for {children} on {date}. '
     || 'Receipt #{receipt}. Remaining balance: Rs {balance}. Received by {received_by}. '
     || 'Thank you — {school}.',
     array['parent','children','school','date','balance','amount','receipt','received_by']),

    ('fee_reminder', 'Fee reminder',
     'Assalam-o-Alaikum {parent}. A balance of Rs {balance} is outstanding for {children}. '
     || 'Kindly clear it at the school office at your convenience. Thank you — {school}.',
     array['parent','children','school','date','balance','amount']),

    ('fee_reminder_final', 'Fee reminder (final)',
     'Assalam-o-Alaikum {parent}. Rs {balance} remains outstanding for {children} despite '
     || 'earlier reminders. Please visit the school office this week so we can sort it out '
     || 'together. Thank you — {school}.',
     array['parent','children','school','date','balance','amount']),

    ('absent_today', 'Absent today',
     'Assalam-o-Alaikum {parent}. {children} was marked absent today, {date}. '
     || 'If this is a mistake please contact the office. — {school}.',
     array['parent','children','school','date','balance']),

    ('result_published', 'Result published',
     'Assalam-o-Alaikum {parent}. The result for {children} has been published and can be '
     || 'viewed in the parent portal. — {school}.',
     array['parent','children','school','date','balance'])
$$;

-- ---------------------------------------------------------------------------
-- 2. Seeding, now reading from the single source above.
--
-- Same behaviour as before — on conflict do nothing, so an existing school's
-- edited wording is never overwritten by a re-run.
-- ---------------------------------------------------------------------------
create or replace function public.fn__seed_message_templates(p_school uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  insert into public.message_templates (school_id, template_key, label, body)
  select p_school, d.template_key, d.label, d.body
  from public.fn__default_message_templates() d
  on conflict (school_id, template_key) do nothing;
end;
$$;

-- Any school created before this migration is missing nothing, but a school
-- created between 0034 and here could be missing a template if the list ever
-- grew. Cheap to make certain.
do $$
declare s record;
begin
  for s in select id from public.schools loop
    perform public.fn__seed_message_templates(s.id);
  end loop;
end $$;

-- ---------------------------------------------------------------------------
-- 3. What the settings screen reads.
--
-- Returns the school's current wording alongside the tags each template may
-- use, so the editor can show them without the client holding its own copy of
-- facts that live at the call sites.
--
-- is_staff() rather than owner/principal: a clerk should be able to SEE what
-- goes out over their name. The table's own policy still stops them editing.
-- ---------------------------------------------------------------------------
create or replace function public.fn_message_settings()
returns table (
  template_key text,
  label        text,
  body         text,
  enabled      boolean,
  tags         text[],
  is_default   boolean
) language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_staff() then
    raise exception 'Not permitted' using errcode = '42501';
  end if;

  return query
  select t.template_key, t.label, t.body, t.enabled,
         coalesce(d.tags, array['parent','children','school','date','balance']),
         -- So the editor can offer "Restore default" only where it would do
         -- something, rather than on every row.
         t.body = d.body
  from public.message_templates t
  left join public.fn__default_message_templates() d on d.template_key = t.template_key
  where t.school_id = public.current_school_id()
  order by t.label;
end;
$$;

-- ---------------------------------------------------------------------------
-- 4. Restore one template's original wording.
--
-- owner/principal only, matching the table's write policy — this changes what
-- every parent receives.
-- ---------------------------------------------------------------------------
create or replace function public.fn_reset_message_template(p_template_key text)
returns text language plpgsql security definer set search_path = public as $$
declare v_body text;
begin
  if not public.has_role('owner', 'principal') then
    raise exception 'Only the owner or principal can change message wording';
  end if;

  select d.body into v_body
  from public.fn__default_message_templates() d
  where d.template_key = p_template_key;

  if v_body is null then
    raise exception 'No such message template: %', p_template_key;
  end if;

  update public.message_templates
     set body = v_body
   where school_id = public.current_school_id()
     and template_key = p_template_key;

  return v_body;
end;
$$;

-- ---------------------------------------------------------------------------
-- 5. Grants.
-- ---------------------------------------------------------------------------
grant execute on function public.fn_message_settings()             to authenticated;
grant execute on function public.fn_reset_message_template(text)   to authenticated;
grant execute on function public.fn__default_message_templates()   to authenticated;

revoke all on function public.fn_message_settings()           from anon;
revoke all on function public.fn_reset_message_template(text) from anon;

-- =============================================================================
-- 0080 — A school could never leave
--
-- Phase 4 of docs/SUPER-ADMIN-DESIGN.md, second of two, and the last thing this
-- product could not do at all.
--
-- THE DEFECT
--
-- 37 tables reference public.schools with ON DELETE NO ACTION. So
--
--   delete from public.schools where id = '…';
--
-- fails on the first foreign key it meets, and there is no function anywhere in
-- the schema that removes a school. A demo school created to show somebody the
-- software is permanent. A school that signed up, never uploaded a student and
-- went quiet is permanent. A customer who left in 2027 and asked for their data
-- to be deleted is permanent, and the answer to them is "we cannot".
--
-- Reproduced: the delete above raises
--   update or delete on table "schools" violates foreign key constraint
--   "academic_sessions_school_id_fkey" on table "academic_sessions"
--
-- THREE STEPS, AND THE ORDER IS THE SAFETY
--
--   1. ARCHIVE   0079. Hidden, licence dead, data intact, reversible.
--   2. EXPORT    everything they own, as JSON, one table at a time. Given to
--                them, and kept as our own record that it was taken.
--   3. PURGE     irreversible, and refused unless 1 and 2 have happened and the
--                operator types the school's name.
--
-- Nothing here can be reached by accident. Each step refuses until the previous
-- one is done, and the last one refuses until somebody has typed a name.
--
-- WHERE THE READ BOUNDARY MOVES, STATED PLAINLY
--
-- The export returns EVERY ROW of a school's data: children's names, guardians'
-- phone numbers, marks, payments. That is far beyond what
-- fn_platform_school_detail (0075) allows, which is counts and dates and
-- nothing about a person.
--
-- The line that keeps it defensible is that the export REFUSES on a school that
-- is not archived. Archiving is a deliberate act with a mandatory reason, logged
-- in the operator's history and in the school's own audit trail, and it is
-- reversible — so a bulk pull of a live customer's records is not something this
-- function can be used for. A live school that wants its data has its own Backup
-- screen, which is where that belongs.
--
-- Every export is recorded in platform_exports with the row counts, and that row
-- SURVIVES the purge (school_id becomes null, the name is denormalised). If a
-- school ever says "you deleted our records", the answer is a dated row saying
-- what was handed over first.
--
-- OUR OWN SALES LEDGER SURVIVES, AND THAT NEEDED A SCHEMA CHANGE
--
-- 0064 gave platform_invoices and platform_payments `on delete cascade`, so
-- purging a school would have destroyed our own invoices to it. That is wrong
-- twice over: a business keeps its sales ledger after a customer leaves, and
-- under the Income Tax Ordinance those records have to be retained for years
-- after the transaction. A purge in 2028 must not make the 2027 tax year
-- unauditable.
--
-- So both tables lose the cascade, gain a nullable school_id with ON DELETE SET
-- NULL, and carry the school's NAME denormalised — set by the same BEFORE INSERT
-- trigger that numbers the document (0077), so an orphaned invoice can still say
-- who it was for. Every total in the product filters on school_id, so an
-- orphaned row simply stops matching any school without any of them changing.
--
-- The one thing that DOES go with the school is the school's own audit_log: it
-- is their record of their own staff's actions, it is their data, and a request
-- to delete their data means it too.
--
-- WHY THE PURGE DOES NOT LIST ITS TABLES
--
-- A hardcoded delete order is wrong the day somebody adds a table. This deletes
-- from the CATALOGUE — every table in public with a school_id — and retries
-- until a pass makes no progress, because the dependency order between them
-- (payment_allocations before payments, invoice_lines before invoices) is
-- already recorded in the foreign keys. If it stalls it raises and names exactly
-- what is left, rather than half-deleting a school and reporting success.
--
-- Re-runnable.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 0. Our own ledger must outlive the customer
--
-- See the header. Done first because the purge below depends on it.
-- ---------------------------------------------------------------------------
alter table public.platform_invoices
  add column if not exists school_name text;
alter table public.platform_payments
  add column if not exists school_name text;

do $keep$
declare r record;
begin
  -- Backfill the names before dropping the NOT NULL, so no existing row ends up
  -- orphaned AND anonymous.
  update public.platform_invoices i set school_name = s.name
    from public.schools s where s.id = i.school_id and i.school_name is null;
  update public.platform_payments p set school_name = s.name
    from public.schools s where s.id = p.school_id and p.school_name is null;

  alter table public.platform_invoices alter column school_id drop not null;
  alter table public.platform_payments alter column school_id drop not null;

  -- Replace the cascade with set-null. Named explicitly rather than looked up:
  -- if a future migration renames these constraints this block must fail loudly
  -- rather than silently leave a cascade in place, which would delete our own
  -- invoices the next time a school was purged.
  for r in
    select 'platform_invoices' as t, 'platform_invoices_school_id_fkey' as c
    union all
    select 'platform_payments', 'platform_payments_school_id_fkey'
  loop
    if not exists (select 1 from pg_constraint where conname = r.c) then
      raise exception '0080: expected constraint % on % — it has been renamed, and '
        'this migration cannot safely change what it cannot find', r.c, r.t;
    end if;
    if (select confdeltype from pg_constraint where conname = r.c) <> 'n' then
      execute format('alter table public.%I drop constraint %I', r.t, r.c);
      execute format('alter table public.%I add constraint %I foreign key (school_id) '
                     'references public.schools(id) on delete set null', r.t, r.c);
      raise notice '0080: %.school_id no longer cascades — our ledger survives a purge', r.t;
    end if;
  end loop;
end $keep$;

-- The name is stamped at INSERT by the same trigger that numbers the document.
-- Rewritten in place rather than restated, and the end state asserted.
do $stamp$
declare v_src text; v_new text;
begin
  v_src := pg_get_functiondef('public.fn__assign_doc_no()'::regprocedure);
  v_new := replace(v_src,
    E'  if new.doc_no is not null and new.serial is not null then
    return new;
  end if;',
    E'  -- The school''s name, kept on the document itself. 0080 lets an invoice
'
    || E'  -- outlive the school it was raised against, and an invoice that cannot say
'
    || E'  -- who it was for is not a business record.
'
    || E'  if new.school_name is null then
'
    || E'    select s.name into new.school_name from public.schools s where s.id = new.school_id;
'
    || E'  end if;
'
    || E'  if new.doc_no is not null and new.serial is not null then
    return new;
  end if;');
  if v_new <> v_src then
    execute v_new;
  end if;
  if position('new.school_name' in
      pg_get_functiondef('public.fn__assign_doc_no()'::regprocedure)) = 0 then
    raise exception '0080: fn__assign_doc_no does not stamp the school name — the text it was matched on has changed';
  end if;
end $stamp$;

-- Payments have no numbering trigger, so they get their own one-line one.
create or replace function public.fn__stamp_payment_school_name()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.school_name is null then
    select s.name into new.school_name from public.schools s where s.id = new.school_id;
  end if;
  return new;
end;
$$;

revoke all on function public.fn__stamp_payment_school_name() from public, anon, authenticated;

drop trigger if exists trg_stamp_payment_school_name on public.platform_payments;
create trigger trg_stamp_payment_school_name
  before insert on public.platform_payments
  for each row execute function public.fn__stamp_payment_school_name();

-- ---------------------------------------------------------------------------
-- 1. The record that survives
-- ---------------------------------------------------------------------------
create table if not exists public.platform_exports (
  id           uuid primary key default gen_random_uuid(),
  -- Nullable, and ON DELETE SET NULL. The whole point of this row is to outlive
  -- the school it describes: after a purge there is no school_id to point at,
  -- and the row must still say what was handed over and when.
  school_id    uuid references public.schools(id) on delete set null,
  school_name  text not null,
  taken_at     timestamptz not null default now(),
  taken_by     uuid,
  taken_by_email text,
  counts       jsonb not null default '{}'::jsonb,
  total_rows   integer not null default 0,
  note         text
);

create index if not exists idx_platform_exports_school
  on public.platform_exports(school_id, taken_at desc);

alter table public.platform_exports enable row level security;

-- Operator only, and read-only through RLS: the row is written by
-- fn_platform_record_export so a "we exported it" claim cannot be typed in
-- after the fact.
drop policy if exists platform_exports_select on public.platform_exports;
create policy platform_exports_select on public.platform_exports
  for select to authenticated using (public.is_platform_admin());

-- ---------------------------------------------------------------------------
-- 2. Which tables hold this school's data
--
-- From the catalogue. Used by the manifest, the export and the purge, so all
-- three agree by construction — an export that missed a table the purge then
-- deleted would be the worst possible bug in this file.
--
-- `platform_%` tables are excluded: our invoices to the school and their reports
-- of payment are OUR business records, not the school's data. They are kept
-- after a purge for the same reason a shop keeps its own sales ledger. The purge
-- clears their school_id link instead of the rows, via the ON DELETE rules
-- already on those tables.
-- ---------------------------------------------------------------------------
create or replace function public.fn__school_data_tables()
returns table (table_name text) language sql stable as $$
  select c.relname::text
    from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
    join pg_attribute a on a.attrelid = c.oid
   where n.nspname = 'public' and c.relkind = 'r'
     and a.attname = 'school_id' and not a.attisdropped
     and c.relname not like 'platform\_%'
     and c.relname not like 'operator\_%'
     and c.relname not in ('subscriptions', 'student_count_snapshots')
   order by c.relname;
$$;

revoke all on function public.fn__school_data_tables() from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 3. What is there to export
-- ---------------------------------------------------------------------------
create or replace function public.fn_platform_export_manifest(p_school_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_school record; r record; v_n bigint; v_total bigint := 0;
  v_tables jsonb := '[]'::jsonb;
begin
  if not public.is_platform_admin() then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  select * into v_school from public.schools where id = p_school_id;
  if not found then
    raise exception 'Unknown school %', p_school_id;
  end if;
  -- The line from the header. A manifest is only counts, but it is the front
  -- door to the export, and refusing here means the console cannot even offer
  -- the button on a live school.
  if v_school.archived_at is null then
    raise exception
      'Archive % first. A full export is an offboarding step, not a way to pull a '
      'live customer''s records — and archiving is reversible.', v_school.name
      using errcode = '42501';
  end if;

  for r in select table_name from public.fn__school_data_tables() loop
    execute format('select count(*) from public.%I where school_id = $1', r.table_name)
      into v_n using p_school_id;
    v_total := v_total + v_n;
    -- Every table, including the empty ones. A manifest that silently omits
    -- what has no rows makes it impossible to tell "they never used marks" from
    -- "marks were left out of the export".
    v_tables := v_tables || jsonb_build_object('name', r.table_name, 'rows', v_n);
  end loop;

  return jsonb_build_object(
    'school_id', p_school_id,
    'school_name', v_school.name,
    'archived_at', v_school.archived_at,
    'tables', v_tables,
    'total_rows', v_total,
    'previous_exports', coalesce((
      select jsonb_agg(jsonb_build_object('taken_at', e.taken_at,
                                          'total_rows', e.total_rows,
                                          'by', e.taken_by_email)
                       order by e.taken_at desc)
        from public.platform_exports e where e.school_id = p_school_id), '[]'::jsonb));
end;
$$;

-- ---------------------------------------------------------------------------
-- 4. One table at a time
--
-- Paged rather than one giant jsonb. A school with three years of daily
-- attendance for 600 children is over a million rows in one table alone, and a
-- single response carrying all of it would either exhaust memory or be truncated
-- by something between here and the browser — and a truncated export that
-- reported success is how "we gave you everything" becomes untrue.
-- ---------------------------------------------------------------------------
create or replace function public.fn_platform_export_table(
  p_school_id uuid, p_table text,
  p_offset integer default 0, p_limit integer default 1000
) returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_rows jsonb; v_lim integer := greatest(1, least(coalesce(p_limit, 1000), 5000));
begin
  if not public.is_platform_admin() then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  if not exists (select 1 from public.schools
                  where id = p_school_id and archived_at is not null) then
    raise exception 'Archive the school first' using errcode = '42501';
  end if;
  -- The table name comes from the client and goes into dynamic SQL. Checked
  -- against the catalogue-derived list rather than quoted-and-hoped: %I would
  -- stop an injection but would still happily read `platform_payments` or
  -- another school's… no, school_id scopes that — but it would read tables that
  -- are not this school's data to give away.
  if not exists (select 1 from public.fn__school_data_tables()
                  where table_name = p_table) then
    raise exception '% is not one of this school''s data tables', coalesce(p_table, '(null)');
  end if;

  -- Ordered by ctid so paging is stable: not every one of these tables has an
  -- id, and ORDER BY on a column that does not exist everywhere would have to be
  -- guessed per table. ctid is physical and does not move under a read-only
  -- export of an archived school, which is the only thing this runs on.
  execute format(
    'select coalesce(jsonb_agg(to_jsonb(t) order by t.ctid), ''[]''::jsonb) '
    'from (select * , ctid from public.%I where school_id = $1 '
    '       order by ctid offset $2 limit $3) t', p_table)
    into v_rows using p_school_id, greatest(0, coalesce(p_offset, 0)), v_lim;

  return jsonb_build_object(
    'table', p_table, 'offset', greatest(0, coalesce(p_offset, 0)),
    'limit', v_lim, 'rows', v_rows,
    'count', jsonb_array_length(v_rows));
end;
$$;

-- ---------------------------------------------------------------------------
-- 5. Recording that it was handed over
-- ---------------------------------------------------------------------------
create or replace function public.fn_platform_record_export(
  p_school_id uuid, p_counts jsonb, p_note text default null
) returns jsonb language plpgsql security definer set search_path = public as $$
declare v_name text; v_id uuid; v_total integer := 0; k text;
begin
  if not public.is_platform_admin() then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  select name into v_name from public.schools where id = p_school_id;
  if v_name is null then
    raise exception 'Unknown school %', p_school_id;
  end if;
  if p_counts is null or jsonb_typeof(p_counts) <> 'object' then
    raise exception 'Give the row counts that were actually written to the file';
  end if;

  for k in select x from jsonb_object_keys(p_counts) x loop
    v_total := v_total + coalesce((p_counts->>k)::integer, 0);
  end loop;

  insert into public.platform_exports
    (school_id, school_name, taken_by, taken_by_email, counts, total_rows, note)
  values (p_school_id, v_name, auth.uid(),
          (select email from public.platform_admins where user_id = auth.uid()),
          p_counts, v_total, nullif(btrim(coalesce(p_note, '')), ''))
  returning id into v_id;

  perform public.fn__log_operator_action('school_exported', p_school_id,
    jsonb_build_object('export_id', v_id, 'total_rows', v_total));

  insert into public.audit_log(school_id, actor, action, entity, entity_id, after)
  values (p_school_id, auth.uid(), 'school_exported', 'schools', p_school_id::text,
          jsonb_build_object('total_rows', v_total, 'export_id', v_id));

  return jsonb_build_object('export_id', v_id, 'total_rows', v_total,
                            'taken_at', now());
end;
$$;

-- ---------------------------------------------------------------------------
-- 6. Purge
--
-- The only irreversible thing in this product. Five refusals stand in front of
-- it, and each one is a mistake somebody would otherwise make:
--
--   not the operator          — obvious
--   not archived              — purging a live customer
--   never exported            — destroying records nobody has a copy of
--   the phrase does not match — the wrong school in a list of fifty
--   still owes money          — writing off a debt by deleting the debtor
--
-- The last one is overridable, because "they will never pay and I want them
-- gone" is a legitimate business decision. The other four are not.
-- ---------------------------------------------------------------------------
create or replace function public.fn_platform_purge_school(
  p_school_id uuid,
  -- Must equal the school's name exactly. Case and spacing included: this is
  -- the last thing standing between a mis-click and a customer's records.
  p_confirm_name text,
  p_force_despite_debt boolean default false
) returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_school record;
  v_owed   numeric;
  v_export record;
  r        record;
  v_n      bigint;
  v_deleted jsonb := '{}'::jsonb;
  v_total   bigint := 0;
  v_left    text;
  v_pass    integer := 0;
  v_progress boolean;
  v_photos  integer := 0;
begin
  if not public.is_platform_admin() then
    raise exception 'Not permitted' using errcode = '42501';
  end if;

  select * into v_school from public.schools where id = p_school_id;
  if not found then
    raise exception 'Unknown school %', p_school_id;
  end if;

  -- --- refusal 1: not archived ---------------------------------------------
  if v_school.archived_at is null then
    raise exception
      'Archive % first. Archiving is reversible and this is not.', v_school.name
      using errcode = '42501';
  end if;

  -- --- refusal 2: never exported -------------------------------------------
  select * into v_export from public.platform_exports
   where school_id = p_school_id order by taken_at desc limit 1;
  if v_export.id is null then
    raise exception
      'Nothing has been exported for %. Take the export first — it is what you '
      'hand them, and it is the only answer to "you deleted our records".',
      v_school.name;
  end if;

  -- --- refusal 3: the phrase ------------------------------------------------
  -- Exact, including case. A near-miss is refused with the difference named,
  -- because "confirmation failed" on a destructive action sends people back to
  -- try again harder rather than to check which school they are looking at.
  if p_confirm_name is distinct from v_school.name then
    raise exception
      'That is not the name. To purge this school, type exactly: %', v_school.name;
  end if;

  -- --- refusal 4: money still owed -----------------------------------------
  v_owed := public.fn__platform_billed(p_school_id) - public.fn__platform_settled(p_school_id);
  if v_owed > 0 and not coalesce(p_force_despite_debt, false) then
    raise exception
      '% still owes %. Deleting the school does not collect it and does not write '
      'it off — raise a credit note if you are forgiving it, or purge on purpose.',
      v_school.name, to_char(v_owed, 'FM999,999,999.00');
  end if;

  -- --- the log entry goes FIRST -------------------------------------------
  -- Written before anything is deleted, and with school_id NULL so it survives
  -- the delete of the school it describes. operator_actions.school_id has an
  -- ON DELETE NO ACTION foreign key to schools, so a row pointing at this school
  -- would either block the purge or have to be deleted with it — and a purge
  -- that erases its own record is not an audit trail.
  perform public.fn__log_operator_action('school_purged', null,
    jsonb_build_object(
      'school_id', p_school_id,
      'school_name', v_school.name,
      'city', v_school.city,
      'archived_at', v_school.archived_at,
      'archive_reason', v_school.archive_reason,
      'exported_at', v_export.taken_at,
      'exported_rows', v_export.total_rows,
      'outstanding_written_off', case when v_owed > 0 then v_owed else 0 end,
      'created_at', v_school.created_at));

  -- --- the delete, in whatever order the foreign keys allow ----------------
  -- Up to 12 passes. Each pass tries every remaining table and swallows a
  -- foreign-key violation, which simply means "something still points at this,
  -- come back next pass". The loop ends when a pass deletes nothing, and then
  -- either everything is gone or the raise below names what is left.
  loop
    v_pass := v_pass + 1;
    v_progress := false;
    for r in select table_name from public.fn__school_data_tables() loop
      begin
        execute format('delete from public.%I where school_id = $1', r.table_name)
          using p_school_id;
        get diagnostics v_n = row_count;
        if v_n > 0 then
          v_progress := true;
          v_total := v_total + v_n;
          v_deleted := v_deleted || jsonb_build_object(
            r.table_name, coalesce((v_deleted->>r.table_name)::bigint, 0) + v_n);
        end if;
      exception
        -- Only a dependency. Any OTHER error is a real fault and must not be
        -- swallowed: a permission problem or a trigger raising would otherwise
        -- look identical to "try again next pass" and the loop would report a
        -- clean purge of a school it never touched.
        when foreign_key_violation then null;
      end;
    end loop;
    exit when not v_progress or v_pass >= 12;
  end loop;

  -- Anything left is a table this function cannot reach, and the honest thing is
  -- to stop and say which. The transaction rolls back, so the school is intact.
  --
  -- Counted with count(*) rather than from pg_class.reltuples, which is an
  -- estimate and can read zero on a table that has rows.
  for r in select table_name from public.fn__school_data_tables() loop
    execute format('select count(*) from public.%I where school_id = $1', r.table_name)
      into v_n using p_school_id;
    if v_n > 0 then
      v_left := coalesce(v_left || ', ', '') || r.table_name || ' (' || v_n::text || ')';
    end if;
  end loop;
  if v_left is not null then
    raise exception
      'Could not finish: % still holds rows for this school after % passes. Nothing '
      'has been deleted — the whole purge is one transaction.', v_left, v_pass;
  end if;

  -- --- the photographs -----------------------------------------------------
  -- Storage objects are not in public and no foreign key reaches them, so
  -- deleting the school's rows leaves its children's photographs in the bucket
  -- forever. Guarded on the schema existing because the test harness has no
  -- storage schema, and a purge that fails there would be a purge that cannot be
  -- tested.
  if to_regclass('storage.objects') is not null then
    execute 'delete from storage.objects where name like $1'
      using p_school_id::text || '/%';
    get diagnostics v_photos = row_count;
  end if;

  -- --- the operator's own history ------------------------------------------
  -- operator_actions.school_id has an ON DELETE NO ACTION foreign key, so these
  -- rows would block the delete. They are UNLINKED rather than deleted: what the
  -- vendor did to a customer is the vendor's record, and it is the only thing
  -- that can answer "when did we suspend them, and why" after the fact. The
  -- name goes into the detail so an unlinked row is still readable.
  update public.operator_actions
     set school_id = null,
         detail = coalesce(detail, '{}'::jsonb)
                  || jsonb_build_object('purged_school_name', v_school.name,
                                        'purged_school_id', p_school_id)
   where school_id = p_school_id;

  -- Support VISITS go. operator_sessions.school_id is NOT NULL so it cannot be
  -- unlinked, and nothing is lost: every entry and exit is already an
  -- operator_actions row, which has just been preserved above.
  delete from public.operator_sessions where school_id = p_school_id;

  -- --- subscriptions and the snapshots ------------------------------------
  -- Excluded from fn__school_data_tables because they are the licence rather
  -- than the school's own records, but they still have to go or the school row
  -- cannot be deleted.
  delete from public.student_count_snapshots where school_id = p_school_id;
  delete from public.subscriptions where school_id = p_school_id;

  -- Our own sales ledger stays. Section 0 above changed platform_invoices and
  -- platform_payments from ON DELETE CASCADE to SET NULL and denormalised the
  -- school name onto each row, so this delete orphans them rather than
  -- destroying them — which is what retaining tax records requires.
  -- platform_payment_claims still cascades: a request to be checked is not a
  -- business record, and the payment it became survives on its own.
  delete from public.schools where id = p_school_id;

  return jsonb_build_object(
    'purged', true,
    'school_name', v_school.name,
    'rows_deleted', v_total,
    'photos_deleted', v_photos,
    'passes', v_pass,
    'by_table', v_deleted,
    'exported_at', v_export.taken_at,
    'kept', jsonb_build_object(
      'invoices', (select count(*) from public.platform_invoices
                    where school_name = v_school.name and school_id is null),
      'payments', (select count(*) from public.platform_payments
                    where school_name = v_school.name and school_id is null),
      'why', 'Your own invoices and receipts are kept, with the school''s name on '
        || 'them. A business keeps its sales ledger after a customer leaves, and '
        || 'tax records have to be retained for years after the transaction.'),
    'also_kept', 'The export record, and everything this console recorded that you '
      || 'did to them — suspensions, discounts, support visits.');
end;
$$;

-- ---------------------------------------------------------------------------
-- 7. Grants
-- ---------------------------------------------------------------------------
grant  execute on function public.fn_platform_export_manifest(uuid)   to authenticated;
revoke execute on function public.fn_platform_export_manifest(uuid) from public, anon;
grant  execute on function public.fn_platform_export_table(uuid, text, integer, integer)   to authenticated;
revoke execute on function public.fn_platform_export_table(uuid, text, integer, integer) from public, anon;
grant  execute on function public.fn_platform_record_export(uuid, jsonb, text)   to authenticated;
revoke execute on function public.fn_platform_record_export(uuid, jsonb, text) from public, anon;
grant  execute on function public.fn_platform_purge_school(uuid, text, boolean)   to authenticated;
revoke execute on function public.fn_platform_purge_school(uuid, text, boolean) from public, anon;

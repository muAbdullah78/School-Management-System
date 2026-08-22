-- =============================================================================
-- 0052 — Give the fee counter's "Latest payments" list a stable order.
--
-- WHAT WAS WRONG
--
-- fn_recent_payments ended `order by p.created_at desc` with no tie-break. In
-- Postgres now() is TRANSACTION-stable: every payment taken inside one
-- transaction shares a created_at to the microsecond. Two receipts written in
-- the same transaction — which is exactly what fn_record_bulk_payments does for
-- a whole class — therefore had no defined order between them, and the list
-- could reshuffle between one page load and the next.
--
-- For a clerk sitting on this screen all morning during the first ten days of a
-- month, a list that reorders itself is a list they stop trusting. And it is
-- worse than cosmetic: "the top row is the payment I just took" is the
-- assumption the screen invites, and without a tie-break that assumption is
-- sometimes wrong.
--
-- HOW IT SURFACED
--
-- counter.sql asserted `class_name = 'Class 1'` on `limit 1` — the first row. It
-- passed in the forward run and failed in the reverse one, because with equal
-- timestamps the row returned first depends on physical heap order, which
-- differs according to what ran before. The reverse-order CI pass exists
-- precisely to find this, and it did — on merged main.
--
-- Two fixes, because there were two faults: the function now has a deterministic
-- order (here), and the test no longer leans on the order at all (counter.sql
-- assertions 14-16c).
--
-- The body below is the LIVE definition with ONLY the ORDER BY changed, so
-- nothing else about the function can drift in the copying. Written by hand the
-- first time, the return type was invented and Postgres rejected it outright —
-- "cannot change return type of existing function" — which is a good reason to
-- copy rather than retype a 19-column signature.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.fn_recent_payments(p_limit integer DEFAULT 25)
 RETURNS TABLE(payment_id uuid, receipt_no bigint, paid_at timestamp with time zone, student_id uuid, student_name text, gr_no text, family_id uuid, parent_name text, class_name text, section_name text, paid_for text, amount numeric, method payment_method, late_fee numeric, discount numeric, note text, status text, received_by text, is_reversal boolean)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_school uuid := public.current_school_id();
begin
  if not public.is_staff() then
    raise exception 'Not permitted' using errcode = '42501';
  end if;

  return query
  select
    p.id,
    p.receipt_no,
    p.created_at,
    eff.sid,
    -- A family payment has NO payments.student_id: the money came from the
    -- father, not from a child. Falling back to the allocations is what makes
    -- this column non-empty for exactly the payments the family feature
    -- creates, and it names every child the receipt actually covered — which is
    -- what the clerk needs to say out loud at the window.
    coalesce(s.full_name, alloc.names, '—'),
    s.gr_no,
    p.family_id,
    f.head_name,
    c.name,
    sec.name,
    (select string_agg(distinct
              coalesce(to_char(i.period_month, 'Mon YYYY'), coalesce(i.notes, 'Other')),
              ', ' order by coalesce(to_char(i.period_month, 'Mon YYYY'), coalesce(i.notes, 'Other')))
       from public.payment_allocations al
       join public.invoices i on i.id = al.invoice_id
      where al.payment_id = p.id),
    p.amount,
    p.method,
    coalesce((select sum(d.fine)
                from (select distinct i2.id, i2.fine
                        from public.payment_allocations al2
                        join public.invoices i2 on i2.id = al2.invoice_id
                       where al2.payment_id = p.id) d), 0),
    coalesce((select sum(l.amount)
                from public.payment_allocations al3
                join public.invoice_lines l on l.invoice_id = al3.invoice_id
               where al3.payment_id = p.id and l.is_discount), 0),
    p.note,
    p.status::text,
    coalesce(pr.full_name, '—'),
    p.reversal_of is not null
  from public.payments p
  -- Which children this receipt settled anything for.
  left join lateral (
    select string_agg(distinct s2.full_name, ', ' order by s2.full_name) as names,
           count(distinct s2.id)                                        as n,
           (array_agg(distinct s2.id))[1]                               as only_id
      from public.payment_allocations al4
      join public.invoices i4  on i4.id = al4.invoice_id
      join public.students s2  on s2.id = i4.student_id
     where al4.payment_id = p.id
  ) alloc on true
  -- The one student this payment is ABOUT, if there is exactly one. A family
  -- payment spread across three siblings has no single class, and showing one
  -- of the three would be worse than showing none.
  left join lateral (
    select coalesce(p.student_id,
                    case when alloc.n = 1 then alloc.only_id end) as sid
  ) eff on true
  left join public.students   s   on s.id = eff.sid
  left join public.families    f  on f.id = p.family_id
  left join public.enrollments e  on e.student_id = eff.sid and e.status = 'active'
  left join public.classes     c  on c.id = e.class_id
  left join public.sections    sec on sec.id = e.section_id
  left join public.profiles    pr on pr.id = p.received_by
  where p.school_id = v_school
  -- receipt_no is the tie-break, and it has to be here: now() is
  -- transaction-stable, so every payment taken in ONE transaction shares a
  -- created_at to the microsecond and the order between them was undefined.
  -- The receipt number is gapless, rises with time, and is the number printed on
  -- the slip in the parent's hand.
  order by p.created_at desc, p.receipt_no desc
  limit greatest(1, least(coalesce(p_limit, 25), 200));
end;
$function$;

-- The semicolon matters. pg_get_functiondef() — which this body was copied from,
-- so that nothing could drift — emits NO trailing terminator. On its own the file
-- still applies, because psql flushes whatever is left in the buffer at EOF. But
-- supabase/bundles/ CONCATENATES the migrations, so without it this
-- function's closing $function$ ran straight into the next migration's CREATE
-- and bundle 5 died with "syntax error at or near CREATE".
--
-- Caught by CI's "bundles apply as single transactions" step, which exists for
-- exactly this: a migration can be perfectly valid alone and invalid in the
-- artefact a school actually pastes.

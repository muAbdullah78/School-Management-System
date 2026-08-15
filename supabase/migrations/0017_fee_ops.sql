-- =============================================================================
-- Fee engine depth — the money controls the plan (03-FEATURES) calls essential
-- that had tables but no operations/UI yet:
--   * Discounts as approvable, reasoned, audited records (separation of duties:
--     anyone with fee access proposes; only owner/principal approves).
--   * Fines / late fees, waivable with a reason.
--   * Adjustments (corrections / waivers / refunds) that actually move the
--     balance — the adjustments table existed but student_balance ignored it.
--
-- The discounts + adjustments tables already have audit triggers (0001), so
-- every change here is tamper-evident.
-- =============================================================================

-- Adjustments were invoice-scoped and not counted anywhere. Make them
-- student-scoped (an invoice link is now optional) so a correction/refund/waiver
-- can stand on its own, and fold them into the derived balance.
alter table public.adjustments add column if not exists student_id uuid references public.students(id);
alter table public.adjustments alter column invoice_id drop not null;

-- Backfill student_id for any pre-existing invoice-scoped adjustments.
update public.adjustments a
   set student_id = i.student_id
  from public.invoices i
 where a.invoice_id = i.id and a.student_id is null;

-- Balance = invoice charges (lines net of discounts) + fines + signed adjustments
-- − verified payments. (Adjustments: positive = extra charge, negative = credit.)
create or replace function public.student_balance(p_student_id uuid)
returns numeric language sql stable security invoker set search_path = public as $$
  select
    coalesce((
      select sum(case when l.is_discount then -l.amount else l.amount end)
      from public.invoice_lines l
      join public.invoices i on i.id = l.invoice_id
      where i.student_id = p_student_id and i.status <> 'void'
    ), 0)
    + coalesce((
      select sum(i.fine) from public.invoices i
      where i.student_id = p_student_id and i.status <> 'void'
    ), 0)
    + coalesce((
      select sum(a.amount) from public.adjustments a
      where a.student_id = p_student_id
    ), 0)
    - coalesce((
      select sum(p.amount) from public.payments p
      where p.student_id = p_student_id and p.status = 'verified'
    ), 0);
$$;

-- --- Discounts -------------------------------------------------------------
-- Propose a discount on an enrolment (starts 'pending'). Any fee role may
-- propose; it only bites once approved (fn_generate_class_invoices reads
-- approved discounts).
create or replace function public.fn_add_discount(
  p_enrollment_id uuid, p_type public.discount_type, p_amount numeric,
  p_is_percent boolean, p_reason text
) returns uuid language plpgsql security definer set search_path = public as $$
declare v_id uuid;
begin
  if not public.has_role('owner','principal','admin_clerk','accountant') then
    raise exception 'Not permitted to propose discounts';
  end if;
  perform public.assert_own('enrollments', p_enrollment_id);
  if p_amount is null or p_amount <= 0 then raise exception 'Discount amount must be positive'; end if;
  if p_is_percent and p_amount > 100 then raise exception 'A percentage discount cannot exceed 100%%'; end if;
  if not exists (select 1 from public.enrollments where id = p_enrollment_id) then
    raise exception 'Enrolment not found';
  end if;
  insert into public.discounts(enrollment_id, type, amount, is_percent, reason, status, created_by)
  values (p_enrollment_id, p_type, p_amount, coalesce(p_is_percent,false), nullif(btrim(p_reason),''), 'pending', auth.uid())
  returning id into v_id;
  return v_id;
end;
$$;

-- Approve / reject / revoke a discount — owner/principal only (separation of duties).
create or replace function public.fn_set_discount_status(
  p_discount_id uuid, p_status public.discount_status
) returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.has_role('owner','principal') then
    raise exception 'Only the owner or principal may approve or reject discounts';
  end if;
  perform public.assert_own('discounts', p_discount_id);
  update public.discounts
     set status = p_status,
         approved_by = case when p_status = 'approved' then auth.uid() else approved_by end,
         approved_at = case when p_status = 'approved' then now() else approved_at end
   where id = p_discount_id;
  if not found then raise exception 'Discount not found'; end if;
end;
$$;

-- --- Fines -----------------------------------------------------------------
-- Add a late fee / fine onto an invoice (increments its fine). A charge, so a
-- clerk/accountant may apply it; the reason is appended to the invoice note.
create or replace function public.fn_apply_fine(
  p_invoice_id uuid, p_amount numeric, p_reason text
) returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.has_role('owner','principal','admin_clerk','accountant') then
    raise exception 'Not permitted to apply fines';
  end if;
  perform public.assert_own('invoices', p_invoice_id);
  if p_amount is null or p_amount <= 0 then raise exception 'Fine amount must be positive'; end if;
  update public.invoices
     set fine = fine + p_amount,
         notes = coalesce(notes || E'\n', '') || 'Fine +' || p_amount::text
                 || case when nullif(btrim(p_reason),'') is null then '' else ': ' || p_reason end
   where id = p_invoice_id and status <> 'void';
  if not found then raise exception 'Invoice not found or is void'; end if;
end;
$$;

-- Waive (zero) an invoice's fine — owner/principal only (like a discount/void).
create or replace function public.fn_waive_fine(
  p_invoice_id uuid, p_reason text
) returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.has_role('owner','principal') then
    raise exception 'Only the owner or principal may waive a fine';
  end if;
  perform public.assert_own('invoices', p_invoice_id);
  update public.invoices
     set fine = 0,
         notes = coalesce(notes || E'\n', '') || 'Fine waived'
                 || case when nullif(btrim(p_reason),'') is null then '' else ': ' || p_reason end
   where id = p_invoice_id and status <> 'void';
  if not found then raise exception 'Invoice not found or is void'; end if;
end;
$$;

-- --- Adjustments (corrections / waivers / refunds) -------------------------
-- A signed change to a student's balance with a mandatory reason. Positive adds
-- a charge; negative gives a credit (waiver / refund of a credit balance).
-- Owner/principal only — it directly changes what a family owes.
create or replace function public.fn_add_adjustment(
  p_student_id uuid, p_amount numeric, p_reason text
) returns uuid language plpgsql security definer set search_path = public as $$
declare v_id uuid;
begin
  if not public.has_role('owner','principal') then
    raise exception 'Only the owner or principal may adjust a balance';
  end if;
  perform public.assert_own('students', p_student_id);
  if p_amount is null or p_amount = 0 then raise exception 'Adjustment amount cannot be zero'; end if;
  if nullif(btrim(p_reason),'') is null then raise exception 'A reason is required'; end if;
  if not exists (select 1 from public.students where id = p_student_id) then
    raise exception 'Student not found';
  end if;
  insert into public.adjustments(student_id, amount, reason, approved_by, created_by)
  values (p_student_id, p_amount, btrim(p_reason), auth.uid(), auth.uid())
  returning id into v_id;
  return v_id;
end;
$$;

grant execute on function public.fn_add_discount(uuid, public.discount_type, numeric, boolean, text) to authenticated;
grant execute on function public.fn_set_discount_status(uuid, public.discount_status) to authenticated;
grant execute on function public.fn_apply_fine(uuid, numeric, text) to authenticated;
grant execute on function public.fn_waive_fine(uuid, text) to authenticated;
grant execute on function public.fn_add_adjustment(uuid, numeric, text) to authenticated;

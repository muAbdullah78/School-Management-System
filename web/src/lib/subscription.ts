/**
 * One description of a school's subscription, shared by every screen that
 * talks about it: the banner, Settings then Subscription, the locked screen,
 * the term chooser, and the console's school page.
 *
 * WHY ONE SHAPE. Before 0155 the banner, the next-payment panel, the renewal
 * reminder and the invoice each worked out "what is owed and when" for
 * themselves, from different columns, and they disagreed: a negotiated school
 * was told it owed Rs 0 while its invoice said Rs 72,000, and a school with a
 * code was quoted the list price while it was invoiced less. The database now
 * builds this view once (fn__subscription_view) and every reader passes it
 * through, so the screens cannot drift from each other or from the invoice.
 *
 * THE RULES IT DESCRIBES, which the database enforces whatever the UI does:
 *   - access runs on what is PAID: raising an invoice moves nothing;
 *   - every invoice is due on the first day of the period it pays for, and the
 *     school keeps working for `grace_days` after that, then locks;
 *   - an Enterprise school is priced by us; with no price agreed it locks the
 *     day its trial ends;
 *   - the pupil limit is the limit, and extra room ends on `extra_until`.
 */
import { requireSupabase } from './supabase'
import { fmtDate } from './format'
import type { SubscriptionStatus } from './licence'

export type Term = 1 | 3 | 12

export interface TermOption {
  months: Term
  /** What the term costs before any code: 3 months less 10%, a year as ten months. */
  term_price: number
  /** What the next invoice would say for this term, the school's live code included. */
  amount: number
  per_month: number
  /** Against paying month by month for the same time, code included. */
  saving: number
  discount_amount: number
  /** Why the school's code would not come off this term, in a sentence. */
  discount_note: string | null
  chosen: boolean
}

export interface Quote {
  priced: boolean
  /** Present when priced is false: 'needs_price' (Enterprise not priced yet), 'term', 'not_sold'. */
  reason?: string
  plan_code: string
  plan_name: string
  by_arrangement?: boolean
  months: number
  period_start: string | null
  period_end: string | null
  month_price: number
  list_amount: number
  term_price: number
  term_saving: number
  discount: {
    code: string; label: string; kind: 'percent' | 'flat'; value: number
    months_covered: number; amount: number; granted_by_kind: 'school' | 'platform'
  } | null
  discount_note: string | null
  discount_amount: number
  amount: number
}

export interface OpenInvoice {
  id: string
  doc_no: string | null
  months: number
  period_start: string
  period_end: string
  amount: number
  total: number
  paid: number
  owed: number
  due_on: string | null
  discount_code: string | null
  discount_amount: number
}

export type LockedBecause = 'suspended' | 'cancelled' | 'needs_price' | 'unpaid' | 'expired'

export interface SubscriptionView {
  plan: {
    code: string; name: string; by_arrangement: boolean
    student_limit: number | null; min_students: number
  }
  price: {
    priced: boolean
    month: number | null; quarter: number | null; year: number | null
    agreed: boolean; agreed_at: string | null
    /** Operator view only: how the price was agreed. */
    agreed_reason: string | null
    quarter_set: boolean; year_set: boolean
  }
  terms: TermOption[]
  term_months: Term
  status: SubscriptionStatus
  stored_status: SubscriptionStatus
  in_trial: boolean
  trial_ends_on: string | null
  paid_from: string | null
  /** The last day covered by invoices paid in full. */
  paid_through: string | null
  /** The later of paid_through and the trial's end. */
  covered_to: string | null
  grace_days: number
  /** The first day the school is locked if nothing more is paid. */
  locks_on: string | null
  days_to_lock: number | null
  locked_because: LockedBecause | null
  needs_price: boolean
  cancel_at_period_end: boolean
  suspended: boolean
  suspend_reason: string | null
  students: {
    count: number; limit: number | null; plan_limit: number | null
    extra: number | null; extra_until: string | null
    /** Operator view only. */
    extra_reason: string | null
    extra_expired: boolean
    declared: number | null
    room: number | null
    warn: boolean; full: boolean; over: boolean
  }
  open_invoice: OpenInvoice | null
  /** Money owed on every live invoice. */
  owed: number
  /** Money paid in and not yet against any invoice. */
  credit: number
  next: { period_start: string; months: number; quote: Quote } | null
  /** What to pay now: what is owed, or the next term once it is within thirty
   *  days or the school has run out, less any credit. */
  pay_now: number
  can_request_invoice: boolean
}

export interface RaisedInvoice {
  invoice_id: string
  doc_no: string | null
  plan_code: string
  plan_name: string
  months: number
  period_start: string
  period_end: string
  due_on: string
  amount: number
  term_price: number
  discount_code: string | null
  discount_amount: number
  owed: number
  status: SubscriptionStatus
  already?: boolean
}

/** Ask for the next invoice (an accounts office often needs one before it pays). */
export async function requestMyInvoice(): Promise<RaisedInvoice> {
  const sb = requireSupabase()
  const { data, error } = await sb.rpc('fn_my_request_invoice')
  if (error) throw new Error(error.message)
  return data as RaisedInvoice
}

export interface RedeemResult {
  ok: boolean
  /** Present when ok is false, already a sentence. */
  reason?: string
  /** The school already has a code: show what would be replaced and ask. */
  needs_replace?: boolean
  preview?: CodePreview
  code?: string
  label?: string
  summary?: string
  trial_ends_on?: string | null
  what_next?: string
  /** The open invoice reissued so the code is on it, when nothing was paid on it. */
  reissued?: { voided?: string; raised?: RaisedInvoice | { not_raised: string }; kept?: string; why?: string } | null
}

export interface CodePreview {
  ok: boolean
  reason?: string
  already_yours?: boolean
  code?: string
  label?: string
  kind?: 'percent' | 'flat' | 'trial_days'
  value?: number
  duration?: 'months' | 'until' | 'forever' | 'once'
  duration_months?: number | null
  duration_until?: string | null
  summary?: string
  trial_days?: number | null
  /** Which invoice it would first come off. */
  applies_to?: 'open_invoice' | 'invoice_after_open' | 'next_invoice'
  period_start?: string | null
  months?: number
  term_price?: number | null
  months_covered?: number
  discount_amount?: number
  amount?: number | null
  skipped?: string | null
  replaces?: { code: string; label: string; granted_by_kind: 'school' | 'platform'; summary: string } | null
}

/**
 * Use a code. A refusal comes back as data ({ok:false, reason}), because the
 * database logs every refused try and a raised error would roll the log back.
 * `replace` is the school's yes to taking off the code it already has.
 */
export async function redeemCode(code: string, replace = false): Promise<RedeemResult> {
  const sb = requireSupabase()
  const { data, error } = await sb.rpc('fn_my_redeem_code', { p_code: code, p_replace: replace })
  if (error) throw new Error(error.message)
  return data as RedeemResult
}

/** What a code would do, for this school's plan and a term, without using it. */
export async function previewCode(
  code: string, planCode: string | null, termMonths: number | null,
): Promise<CodePreview> {
  const sb = requireSupabase()
  const { data, error } = await sb.rpc('fn_preview_discount', {
    p_code: code, p_plan_code: planCode, p_term_months: termMonths,
  })
  if (error) throw new Error(error.message)
  return data as CodePreview
}

export interface MyCode {
  code: string | null
  label: string | null
  kind: 'percent' | 'flat' | null
  value: number | null
  duration: 'months' | 'until' | 'forever' | null
  ends_on: string | null
  months_left: number | null
  months_total: number | null
  times_applied: number | null
  total_saved: number | null
  granted_by_us: boolean
  can_remove: boolean
  plan_codes: string[] | null
  min_term_months: number | null
  summary: string | null
  trial_code: { code: string; days: number; on: string } | null
}

/** What my school has: its live money code and the trial code it used, if any. */
export async function myCode(): Promise<MyCode | null> {
  const sb = requireSupabase()
  const { data, error } = await sb.rpc('fn_my_discount')
  if (error) throw new Error(error.message)
  return (data ?? null) as MyCode | null
}

export async function removeMyCode(): Promise<{ removed: boolean; code?: string }> {
  const sb = requireSupabase()
  const { data, error } = await sb.rpc('fn_my_remove_discount')
  if (error) throw new Error(error.message)
  return data as { removed: boolean; code?: string }
}

/** "Starter, Rs 2,000 a month" or "Enterprise, price agreed with you". */
export function planLine(v: SubscriptionView): string {
  if (v.plan.by_arrangement && !v.price.priced) return `${v.plan.name}, price to be agreed with you`
  if (v.price.month == null) return v.plan.name
  return `${v.plan.name}, Rs ${Math.round(v.price.month).toLocaleString('en-PK')} a month`
}

/** What the locked screen leads with. Plain words for a school owner. */
export function lockedSentence(v: SubscriptionView): string | null {
  switch (v.locked_because) {
    case 'needs_price':
      return 'Your free trial has ended and we have not agreed your price yet. We will call you; '
        + 'once your price is set you have the usual fourteen days to pay.'
    case 'unpaid':
      return 'A payment is more than fourteen days overdue, so new entries are paused until it reaches us.'
    case 'expired':
      return v.in_trial
        ? 'Your free trial and its fourteen days of grace have ended.'
        : 'Your paid period and its fourteen days of grace have ended.'
    case 'suspended':
      return 'This school has been paused by us. Please call us.'
    case 'cancelled':
      // The school asked to stop and its period has run out. That is its own
      // decision, and it can undo it (fn_resume_my_subscription works after the
      // end), so it is told when it ended rather than that we cancelled it.
      return endedAsAsked(v)
        ? `Your subscription ended on ${fmtDate(v.covered_to)}, as you asked.`
        : 'This subscription has been cancelled.'
    default:
      return null
  }
}

/**
 * Ended because the school asked to stop at the end of its period, rather than
 * cancelled by us. Only the first can be restarted by the school itself.
 */
export function endedAsAsked(v: SubscriptionView): boolean {
  return v.status === 'cancelled' && v.cancel_at_period_end && v.stored_status !== 'cancelled'
}

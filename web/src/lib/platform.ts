/**
 * Platform administration — the product owner's view across all schools.
 *
 * Everything here calls SECURITY DEFINER functions that check
 * `is_platform_admin()` themselves, so the browser never needs (and never has)
 * the service_role key. The one exception is creating a school's owner LOGIN,
 * which requires minting an auth user and therefore an Edge Function.
 */
import { requireSupabase } from './supabase'

export type LimitState = 'ok' | 'within_margin' | 'over'

export interface PlatformSchool {
  school_id: string
  school_name: string
  city: string | null
  contact_name: string | null
  contact_phone: string | null
  plan_code: string
  status: 'trialing' | 'active' | 'grace' | 'locked' | 'cancelled'
  expires_on: string | null
  days_left: number | null
  student_count: number
  student_limit: number | null
  limit_state: LimitState
  suggested_plan: string
  needs_upgrade: boolean
  /** Everything ever invoiced to this school minus everything it ever paid.
   *  This is the column that makes an expiry date and a debt two different
   *  things: before it existed, a school that renewed on trust and never paid
   *  looked identical to one that paid in full. */
  outstanding: number
  last_paid_on: string | null
  /** `status` reads 'locked' for a suspended school AND for an expired one.
   *  These two are what tell them apart — which is why 0079 did not add an enum
   *  value it could not add inside a transaction anyway. */
  suspended: boolean
  suspend_reason: string | null
  archived: boolean
}

export interface LedgerEntry {
  /** The invoice or the payment row itself, so a line can be opened. Before
   *  0077 a ledger line could not be pointed at: "the Rs 38,000 one" was the
   *  only way to refer to it, and two renewals of the same plan in a year made
   *  that ambiguous. */
  entry_id: string
  entry_date: string
  kind: 'invoice' | 'credit_note' | 'payment'
  /** Null on a payment — only documents carry a number. */
  doc_no: string | null
  description: string
  /** Signed: negative for a credit note, zero for a voided document. */
  charged: number | null
  /** Cash plus any tax the school withheld and paid to the FBR in our name. */
  paid: number | null
  voided: boolean
  note: string | null
  reference: string | null
}

export interface PlatformRevenue {
  from: string
  to: string
  invoiced: number
  collected: number
  /** List price minus what was actually charged, over the period. A figure
   *  nothing could produce before — discounts left no trace. */
  discounted: number
  /** Credit notes raised in the period. NOT a discount — a refund and a
   *  discount are different facts and 0077 keeps them apart. */
  credited: number
  /** Invoices cancelled in the period. Reported rather than silently dropped: a
   *  month where three invoices were voided is a month to look at. */
  voided: number
  net_invoiced: number
  /** Money that actually reached the bank — collected minus withheld tax. */
  cash_received: number
  /** Income tax the schools deducted at source and paid on our behalf. It is
   *  settled, but it is not cash. */
  tax_withheld: number
  /** Withheld tax with no CPR on record yet. Each rupee here is a deduction we
   *  cannot claim until the certificate arrives. */
  tax_certificates_awaited: number
  /** Everything ever invoiced minus everything ever paid. Not period-scoped: a
   *  receivable does not belong to the month it was raised in. */
  outstanding_total: number
  by_plan: { plan_code: string; invoices: number; amount: number }[]
  schools_owing: { school_id: string; school_name: string; outstanding: number }[]
}

export interface Plan {
  code: string
  name: string
  student_limit: number | null
  price_monthly: number
  price_yearly: number
  sort_order: number
  active: boolean
}

/** True if the signed-in user is a platform admin. Safe to call for anyone. */
export async function amPlatformAdmin(): Promise<boolean> {
  const sb = requireSupabase()
  const { data, error } = await sb.rpc('is_platform_admin')
  if (error) return false
  return Boolean(data)
}

export async function listPlatformSchools(
  includeArchived = false,
): Promise<PlatformSchool[]> {
  const sb = requireSupabase()
  const { data, error } = await sb.rpc('fn_platform_schools', {
    p_include_archived: includeArchived,
  })
  if (error) throw new Error(error.message)
  return (data ?? []) as PlatformSchool[]
}

export async function listPlans(): Promise<Plan[]> {
  const sb = requireSupabase()
  const { data, error } = await sb.from('plans').select('*').eq('active', true).order('sort_order')
  if (error) throw new Error(error.message)
  return (data ?? []) as Plan[]
}

export interface ActivationResult {
  invoice_id: string
  amount: number
  list_amount: number
  outstanding: number
  period_start: string
  period_end: string
}

/**
 * Grant a school time, and write the charge for it in the same transaction.
 *
 * `amount` null means "charge the plan's list price". An amount that differs
 * from list REQUIRES a note — including zero, because a free year that leaves no
 * trace is how a business loses track of what it has given away.
 *
 * The call REFUSES a school whose student count has outgrown the target plan,
 * naming the count, the limit and the plan that fits. `allowOverLimit` is the
 * deliberate override, and the breach then goes on the invoice.
 */
export async function activateSubscription(
  schoolId: string, planCode: string, months: number,
  opts: { amount?: number | null; note?: string | null; allowOverLimit?: boolean } = {},
): Promise<ActivationResult> {
  const sb = requireSupabase()
  const { data, error } = await sb.rpc('fn_activate_subscription', {
    p_school_id: schoolId, p_plan_code: planCode, p_months: months,
    p_amount: opts.amount ?? null,
    p_note: opts.note ?? null,
    p_allow_over_limit: opts.allowOverLimit ?? false,
  })
  if (error) throw new Error(error.message)
  return data as ActivationResult
}

/** Record money a school actually sent us. */
/**
 * Record what a school paid us — and what it withheld.
 *
 * `taxWithheld` is not an optional nicety. Under section 153(1)(b) a Pakistani
 * buyer of services must deduct income tax at source, so a school invoiced
 * Rs 38,000 transfers Rs 34,960 and sends a CPR for the Rs 3,040 it paid to the
 * FBR on our behalf. Recording only the 34,960 leaves Rs 3,040 outstanding
 * forever and has the operator chasing a school for money it has already paid.
 */
export async function recordPlatformPayment(input: {
  schoolId: string; amount: number; paidOn?: string | null
  method?: string; reference?: string | null; invoiceId?: string | null; note?: string | null
  taxWithheld?: number | null; taxCertificate?: string | null
}): Promise<{
  payment_id: string; outstanding: number
  tax_withheld: number; settled: number; awaiting_certificate: boolean
}> {
  const sb = requireSupabase()
  const { data, error } = await sb.rpc('fn_platform_record_payment', {
    p_school_id: input.schoolId, p_amount: input.amount,
    p_paid_on: input.paidOn ?? null, p_method: input.method ?? 'bank',
    p_reference: input.reference ?? null, p_invoice_id: input.invoiceId ?? null,
    p_note: input.note ?? null,
    p_tax_withheld: input.taxWithheld ?? 0,
    p_tax_certificate: input.taxCertificate ?? null,
  })
  if (error) throw new Error(error.message)
  return data as {
    payment_id: string; outstanding: number
    tax_withheld: number; settled: number; awaiting_certificate: boolean
  }
}

/** The CPR usually arrives weeks after the transfer, so it can be attached later. */
export async function attachTaxCertificate(
  paymentId: string, certificate: string,
): Promise<void> {
  const sb = requireSupabase()
  const { error } = await sb.rpc('fn_platform_attach_tax_certificate', {
    p_payment_id: paymentId, p_certificate: certificate,
  })
  if (error) throw new Error(error.message)
}

/** One school's invoices and payments, interleaved, oldest first. */
export async function platformLedger(schoolId: string): Promise<LedgerEntry[]> {
  const sb = requireSupabase()
  const { data, error } = await sb.rpc('fn_platform_ledger', { p_school_id: schoolId })
  if (error) throw new Error(error.message)
  return (data ?? []) as LedgerEntry[]
}

/** What we invoiced and collected over a period, and who owes us. */
export async function platformRevenue(from: string, to: string): Promise<PlatformRevenue> {
  const sb = requireSupabase()
  const { data, error } = await sb.rpc('fn_platform_revenue', { p_from: from, p_to: to })
  if (error) throw new Error(error.message)
  return data as PlatformRevenue
}

/** What one school owes right now. */
export async function platformOutstanding(schoolId: string): Promise<number> {
  const sb = requireSupabase()
  const { data, error } = await sb.rpc('fn_platform_outstanding', { p_school_id: schoolId })
  if (error) throw new Error(error.message)
  return Number(data ?? 0)
}

export async function extendTrial(schoolId: string, days: number): Promise<void> {
  const sb = requireSupabase()
  const { error } = await sb.rpc('fn_extend_trial', { p_school_id: schoolId, p_days: days })
  if (error) throw new Error(error.message)
}

/**
 * How far has the production database actually got?
 *
 * Until 0069 nothing recorded it. Twice the answer had to be guessed from an
 * error message a school reported — once wrongly, and the repair built on that
 * guess failed on its own first statement. With fifty schools behind one
 * hand-pasted Postgres, "what is applied?" has to be a question with an answer.
 *
 * `gaps` is the one to read: a bundle is applied as ONE transaction, so a bundle
 * that dies halfway rolls back entirely and its migrations never arrive. That
 * leaves a hole in the middle of the sequence, and a human scrolling seventy
 * filenames does not see it. The list is capped at 25 with `gaps_total` holding
 * the real number, because one badly-named row can open a range of thousands.
 */
export interface SchemaState {
  applied_count: number
  latest: string | null
  latest_at: string | null
  gaps: string[]
  gaps_total: number
  bundles: { bundle: string; files: number; applied_at: string }[]
}

export async function platformSchemaState(): Promise<SchemaState> {
  const sb = requireSupabase()
  const { data, error } = await sb.rpc('fn_platform_schema_state')
  if (error) throw new Error(error.message)
  return data as SchemaState
}

/**
 * Read-only support access into one school.
 *
 * The owner chose full permanent read over consented, time-boxed access — see
 * docs/SUPER-ADMIN-DESIGN.md §2.1 for the argument they overrode. What is fixed
 * is the read-only half: entering a school grants the reach of the `readonly`
 * observer role and nothing more, refused at the database rather than hidden in
 * this file. A UI check would be a suggestion.
 *
 * The reason is required by the database, not by this form. Every visit is
 * logged, and the SCHOOL can read that log under Settings → Support visits,
 * which is what turns permanent access into something to volunteer rather than
 * hope is never asked about.
 */
export interface OperatorSession {
  session_id: string
  school_id: string
  school_name: string
  reason: string
  started_at: string
  expires_at: string
  read_only: true
}

export async function operatorEnter(
  schoolId: string, reason: string, minutes = 60,
): Promise<OperatorSession> {
  const sb = requireSupabase()
  const { data, error } = await sb.rpc('fn_operator_enter', {
    p_school_id: schoolId, p_reason: reason, p_minutes: minutes,
  })
  if (error) throw new Error(error.message)
  return data as OperatorSession
}

export async function operatorLeave(): Promise<number> {
  const sb = requireSupabase()
  const { data, error } = await sb.rpc('fn_operator_leave')
  if (error) throw new Error(error.message)
  return Number(data ?? 0)
}

/** The caller's own active session, or null. Drives the banner. */
export async function operatorCurrent(): Promise<OperatorSession | null> {
  const sb = requireSupabase()
  const { data, error } = await sb.rpc('fn_operator_current')
  if (error) return null
  return (data ?? null) as OperatorSession | null
}

export interface OperatorAction {
  at: string
  actor_email: string | null
  action: string
  detail: Record<string, unknown>
}

/** What we have done to this school: prices chosen, trials extended, visits made. */
export async function schoolActions(schoolId: string, limit = 100): Promise<OperatorAction[]> {
  const sb = requireSupabase()
  const { data, error } = await sb.rpc('fn_platform_school_actions', {
    p_school_id: schoolId, p_limit: limit,
  })
  if (error) throw new Error(error.message)
  return (data ?? []) as OperatorAction[]
}

/** Plain English for one logged action, for a list a human reads down. */
export function describeAction(a: OperatorAction): string {
  const d = a.detail ?? {}
  const pkr = (v: unknown) => `Rs ${Number(v ?? 0).toLocaleString('en-PK')}`
  switch (a.action) {
    case 'school_created':
      return `School added${d.city ? ` (${String(d.city)})` : ''}`
    case 'licence_changed': {
      const to = (d.to ?? {}) as Record<string, unknown>
      const from = (d.from ?? {}) as Record<string, unknown>
      const bits: string[] = []
      if (to.plan_code && to.plan_code !== from.plan_code) {
        bits.push(`plan ${from.plan_code ? `${String(from.plan_code)} → ` : ''}${String(to.plan_code)}`)
      }
      if (to.status && to.status !== from.status) bits.push(`status ${String(to.status)}`)
      if (to.period_end && to.period_end !== from.period_end) bits.push(`paid until ${String(to.period_end)}`)
      if (to.trial_ends_on && to.trial_ends_on !== from.trial_ends_on) bits.push(`trial until ${String(to.trial_ends_on)}`)
      return `Licence changed — ${bits.length ? bits.join(', ') : 'no visible change'}`
    }
    case 'invoice_raised': {
      const disc = Number(d.discount ?? 0)
      // The discount is the figure worth surfacing: it is the one thing an
      // invoice row alone cannot explain six months later.
      return `Invoiced ${pkr(d.amount)} for ${String(d.months ?? '?')} month(s) on ${String(d.plan_code ?? '?')}`
        + (disc > 0 ? ` — ${pkr(disc)} off list${d.note ? `: ${String(d.note)}` : ''}` : '')
    }
    case 'payment_recorded':
      return `Payment ${pkr(d.amount)} by ${String(d.method ?? 'bank')}`
        + (d.reference ? ` · ${String(d.reference)}` : '')
    case 'school_entered':
      return `Entered the school (read only) — ${String(d.reason ?? 'no reason given')}`
    case 'school_left':
      return 'Left the school'
    // --- 0076-0078 ---------------------------------------------------------
    case 'credit_note_raised':
      return `Credit note ${String(d.doc_no ?? '')} for ${pkr(d.total ?? d.amount)}`
        + (d.note ? ` — ${String(d.note)}` : '')
    case 'invoice_voided':
    case 'credit_note_voided':
      return `${String(d.doc_no ?? 'A document')} voided — ${String(d.reason ?? 'no reason recorded')}`
        + (d.licence_untouched ? ' (the licence was left running)' : '')
    case 'invoice_tax_set':
      return `Tax on ${String(d.doc_no ?? 'the invoice')} set to ${String(d.tax_pct ?? 0)}% (${pkr(d.tax_amount)})`
    case 'tax_certificate_attached':
      return `Withholding certificate ${String(d.certificate ?? '')} recorded for ${pkr(d.tax_withheld)}`
    case 'renewal_reminder':
      return `Renewal reminder sent by ${String(d.channel ?? 'WhatsApp')} (${String(d.stage ?? '?')} stage)`
        + (d.note ? ` — ${String(d.note)}` : '')
    case 'payment_claim_confirmed': {
      // The gap between the two figures is the interesting part: it is usually
      // the withholding tax, and it is what the school will ask about.
      const said = Number(d.claimed_amount ?? 0)
      const got = Number(d.confirmed_amount ?? 0)
      return `Reported payment confirmed — ${pkr(got)}`
        + (said && said !== got ? ` (the school reported ${pkr(said)})` : '')
        + (d.reference ? ` · ${String(d.reference)}` : '')
    }
    case 'payment_claim_rejected':
      return `Reported payment of ${pkr(d.amount)} rejected — ${String(d.reason ?? 'no reason recorded')}`
    case 'settings_changed': {
      const f = Array.isArray(d.fields) ? (d.fields as unknown[]).map(String) : []
      // The KEYS, never the values: a bank account number does not belong in an
      // activity feed, and "who changed the bank details, and when" is the
      // question this answers.
      return `Our own billing details changed${f.length ? `: ${f.join(', ')}` : ''}`
    }
    default:
      return a.action.replace(/_/g, ' ')
  }
}

/**
 * Everything about one school, in one call.
 *
 * The console listed eight fields per school and that was every fact it held
 * about a customer. This is the screen that answers "what is going on at Al Qalam
 * School?"
 *
 * `readiness` is the part worth reading first. A school that paid and never used
 * the software looks identical, in a list, to one that runs on it daily — until
 * it does not renew. And the commonest reason a school stalls is being stuck one
 * step in: until 0066 no school could create a fee head at all, so every one of
 * them was stuck at the same place with no way to say so. The first unfinished
 * row is the phone call worth making.
 *
 * WHAT IT DELIBERATELY DOES NOT CONTAIN: any child, guardian, family or parent
 * phone number. Counts and dates only. For anything about an individual there is
 * a support visit — read-only, logged, and shown to the school. "How many pupils"
 * is business information; "which pupils" is the school's own affair, and wanting
 * the second should cost you a record saying why.
 */
export interface ReadinessItem {
  key: string
  label: string
  done: boolean
  detail: string
}

export interface SchoolDetail {
  school: {
    id: string; name: string; city: string | null
    contact_name: string | null; contact_phone: string | null; contact_email: string | null
    notes: string | null; active: boolean; created_at: string
    display_name: string | null; address: string | null; phone: string | null
    principal_name: string | null; has_logo: boolean
  }
  licence: {
    plan_code: string; plan_name: string; status: string; cycle: string
    expires_on: string | null; days_left: number | null
    student_count: number; student_limit: number | null; margin_limit: number | null
    counted_at: string | null; over_limit_since: string | null
    limit_state: LimitState; suggested_plan: string | null
  } | null
  money: {
    invoiced: number; paid: number; outstanding: number
    last_paid_on: string | null; invoice_count: number
  }
  people: {
    name: string; role: string; active: boolean; added_on: string
    ever_signed_in: boolean; last_sign_in: string | null
  }[]
  counts: {
    classes: number; sections: number; fee_heads: number; classes_priced: number
    students: number; staff: number; families: number; parents_linked: number
  }
  readiness: ReadinessItem[]
  activity: {
    last_payment: string | null; last_invoice: string | null
    last_attendance: string | null; last_mark: string | null
    last_certificate: string | null; last_till_close: string | null
    last_message: string | null
  }
  not_recorded: string[]
}

export async function schoolDetail(schoolId: string): Promise<SchoolDetail> {
  const sb = requireSupabase()
  const { data, error } = await sb.rpc('fn_platform_school_detail', { p_school_id: schoolId })
  if (error) throw new Error(error.message)
  return data as SchoolDetail
}

export async function refreshAllCounts(): Promise<number> {
  const sb = requireSupabase()
  const { data, error } = await sb.rpc('fn_platform_refresh_counts')
  if (error) throw new Error(error.message)
  return (data as number) ?? 0
}

/**
 * Sort so the work comes first: schools that need action at the top, quiet ones
 * at the bottom. Locked and expiring schools are money on the table; over-limit
 * schools are a phone call worth making.
 */
export function actionRank(s: PlatformSchool): number {
  if (s.status === 'locked' || s.status === 'cancelled') return 0
  if (s.status === 'grace') return 1
  if (s.days_left !== null && s.days_left <= 7) return 2
  // Money already invoiced and not paid outranks an over-limit school: one is a
  // debt, the other is a conversation. Before `outstanding` existed this
  // ranking could not tell the two apart at all.
  if (s.outstanding > 0) return 3
  if (s.limit_state === 'over') return 4
  if (s.status === 'trialing') return 5
  return 6
}

export function sortByAction(list: PlatformSchool[]): PlatformSchool[] {
  return [...list].sort((a, b) => {
    const r = actionRank(a) - actionRank(b)
    if (r !== 0) return r
    const da = a.days_left ?? 9999
    const db = b.days_left ?? 9999
    if (da !== db) return da - db
    return a.school_name.localeCompare(b.school_name)
  })
}

/** One short line saying what to do about this school, or null if nothing. */
export function actionNeeded(s: PlatformSchool): string | null {
  // An unpaid invoice is worth saying whatever the licence status is: a school
  // can be comfortably active and still owe for the year it is halfway through.
  if (s.outstanding > 0 && s.status !== 'locked' && s.status !== 'cancelled') {
    return `Owes ${s.outstanding.toLocaleString('en-PK')} — unpaid invoice`
  }
  switch (s.status) {
    case 'locked':
      return 'Locked — chase payment or reactivate'
    case 'cancelled':
      return 'Cancelled'
    case 'grace':
      return `In grace — ${s.days_left ?? 0} day(s) before it locks`
    case 'trialing':
      if ((s.days_left ?? 0) <= 3) return `Trial ends in ${s.days_left} day(s) — call them`
      return null
    case 'active':
      if ((s.days_left ?? 999) <= 7) return `Renewal due in ${s.days_left} day(s)`
      if (s.needs_upgrade && s.limit_state === 'over') {
        return `Over limit — move to ${s.suggested_plan} at renewal`
      }
      return null
    default:
      return null
  }
}

// ===========================================================================
// Phase 3 — billing documents, corrections, renewals and the claim queue.
// Migrations 0076, 0077, 0078.
// ===========================================================================

/**
 * The vendor's own registered details.
 *
 * `missing` is the field the screen exists for. An invoice printed with a blank
 * NTN is useless to the school receiving it and they will not tell us — they
 * will simply fail to claim the expense, or phone about it three weeks later.
 */
export interface PlatformSettings {
  business_name: string
  ntn: string | null
  strn: string | null
  address: string | null
  city: string | null
  phone: string | null
  email: string | null
  website: string | null
  bank_name: string | null
  bank_title: string | null
  bank_account: string | null
  bank_iban: string | null
  invoice_prefix: string
  credit_prefix: string
  payment_terms_days: number
  default_withholding_pct: number
  invoice_footer: string | null
  gateway_enabled: boolean
  gateway_provider: string | null
  updated_at: string
  /** Required fields still blank. Empty means ready to invoice. */
  missing: string[]
}

export async function platformSettings(): Promise<PlatformSettings> {
  const sb = requireSupabase()
  const { data, error } = await sb.rpc('fn_platform_settings')
  if (error) throw new Error(error.message)
  return data as PlatformSettings
}

/**
 * Save only the keys given.
 *
 * A patch rather than the whole row, so saving one field cannot overwrite the
 * other nineteen with whatever the form last rendered. The database refuses a
 * key it does not know, so a typo is an error rather than a value that appears
 * saved and was not.
 */
export async function savePlatformSettings(
  patch: Partial<Record<keyof PlatformSettings, unknown>>,
): Promise<PlatformSettings> {
  const sb = requireSupabase()
  const { data, error } = await sb.rpc('fn_platform_save_settings', { p: patch })
  if (error) throw new Error(error.message)
  return data as PlatformSettings
}

/** Everything needed to render one invoice or credit note. */
export interface InvoiceDocument {
  id: string
  kind: 'invoice' | 'credit_note'
  doc_no: string
  title: string
  issued_on: string
  due_on: string | null
  voided: boolean
  voided_at: string | null
  void_reason: string | null
  credits_doc_no: string | null
  seller: {
    name: string | null; ntn: string | null; strn: string | null
    address: string | null; city: string | null
    phone: string | null; email: string | null; website: string | null
  }
  /** Repeated from Settings on purpose: the moment somebody is about to print
   *  is the moment a blank NTN matters. */
  seller_missing: string[]
  buyer: {
    school_id: string; name: string; address: string | null; city: string | null
    phone: string | null; email: string | null; attention: string | null
  }
  lines: {
    description: string
    /** Raw dates. Formatted by the document component so every date on the page
     *  reads the same way — see the note in fn__invoice_document. */
    period_start: string; period_end: string
    months: number; cycle: string
    amount: number; list_amount: number | null
  }[]
  tax: { pct: number; amount: number; label: string | null }
  totals: {
    subtotal: number; tax: number; total: number
    credited: number; paid: number
    /** This DOCUMENT's balance, not the school's. Putting the school balance
     *  here makes one invoice look unpaid because another one is. */
    balance: number
  }
  amount_in_words: string
  bank: { bank_name: string | null; title: string | null; account: string | null; iban: string | null } | null
  withholding_note: string | null
  note: string | null
  footer: string | null
  payments: {
    paid_on: string; amount: number; method: string; reference: string | null
    tax_withheld: number; tax_certificate: string | null; settled: number
  }[]
  credit_notes: {
    id: string; doc_no: string; issued_on: string
    amount: number; tax_amount: number; total: number
    note: string | null; voided: boolean
  }[]
}

export async function platformInvoice(invoiceId: string): Promise<InvoiceDocument> {
  const sb = requireSupabase()
  const { data, error } = await sb.rpc('fn_platform_invoice', { p_invoice_id: invoiceId })
  if (error) throw new Error(error.message)
  return data as InvoiceDocument
}

/**
 * Cancel a document that should never have existed.
 *
 * Refused once anything is attached to it — a payment or a credit note — which
 * is exactly the case a credit note exists for. `warning` is returned when the
 * licence the invoice paid for is still running: voiding the charge is a
 * correction to the books, not a repossession of the year.
 */
export async function voidInvoice(
  invoiceId: string, reason: string,
): Promise<{ doc_no: string; warning: string | null; outstanding: number }> {
  const sb = requireSupabase()
  const { data, error } = await sb.rpc('fn_platform_void_invoice', {
    p_invoice_id: invoiceId, p_reason: reason,
  })
  if (error) throw new Error(error.message)
  return data as { doc_no: string; warning: string | null; outstanding: number }
}

/**
 * Give part of a correct invoice back.
 *
 * The invoice stands; a second document reduces what is due. `taxAmount` null
 * credits the tax in proportion, which is right in every ordinary case.
 */
export async function creditNote(input: {
  invoiceId: string; amount: number; reason: string; taxAmount?: number | null
}): Promise<{
  credit_note_id: string; doc_no: string; credits_doc_no: string
  amount: number; tax_amount: number; total: number; outstanding: number
}> {
  const sb = requireSupabase()
  const { data, error } = await sb.rpc('fn_platform_credit_note', {
    p_invoice_id: input.invoiceId, p_amount: input.amount,
    p_reason: input.reason, p_tax_amount: input.taxAmount ?? null,
  })
  if (error) throw new Error(error.message)
  return data as {
    credit_note_id: string; doc_no: string; credits_doc_no: string
    amount: number; tax_amount: number; total: number; outstanding: number
  }
}

/**
 * Set the sales-tax line on an invoice.
 *
 * Separate from raising it, because the operator often does not know the rate at
 * the moment the licence is granted, and a renewal must not wait on a tax
 * question. Refused once the invoice has been paid or credited: the total on a
 * document the customer is holding must not change under them.
 */
export async function setInvoiceTax(
  invoiceId: string, pct: number, amount?: number | null,
): Promise<{ doc_no: string; tax_pct: number; tax_amount: number; total: number }> {
  const sb = requireSupabase()
  const { data, error } = await sb.rpc('fn_platform_set_invoice_tax', {
    p_invoice_id: invoiceId, p_tax_pct: pct, p_tax_amount: amount ?? null,
  })
  if (error) throw new Error(error.message)
  return data as { doc_no: string; tax_pct: number; tax_amount: number; total: number }
}

export type RenewalBucket =
  | 'cancelled' | 'locked' | 'grace' | 'overdue' | 'today'
  | 'week' | 'fortnight' | 'month' | 'later' | 'unknown'

/**
 * The renewal worklist, worst first.
 *
 * With three schools you know them. With fifty, a licence that expired eleven
 * days ago is row 34 of an alphabetical list and the first anyone hears of it is
 * the principal phoning to say the software has locked — which is the worst
 * possible moment for a renewal conversation.
 */
export interface DueSoonRow {
  school_id: string
  school_name: string
  city: string | null
  contact_name: string | null
  contact_phone: string | null
  plan_code: string
  status: string
  expires_on: string | null
  days_left: number | null
  bucket: RenewalBucket
  student_count: number
  student_limit: number | null
  suggested_plan: string | null
  needs_upgrade: boolean
  /** Priced on the plan the student count fits, not the plan they are sitting
   *  on — quoting the old price to a school that has outgrown it is how a
   *  renewal becomes an argument. */
  renewal_amount: number | null
  outstanding: number
  /** How far the live invoices reach. Null means never invoiced at all. */
  invoiced_to: string | null
  /** Licence time nobody billed for. Null on a school with no invoices, because
   *  a trial is unbilled on purpose. */
  unbilled_days: number | null
  never_invoiced: boolean
  last_reminded_at: string | null
  last_reminded_stage: string | null
}

export async function dueSoon(days = 45): Promise<DueSoonRow[]> {
  const sb = requireSupabase()
  const { data, error } = await sb.rpc('fn_platform_due_soon', { p_days: days })
  if (error) throw new Error(error.message)
  return (data ?? []) as DueSoonRow[]
}

export type ReminderStage = 'ahead' | 'due' | 'today' | 'grace' | 'locked'

export interface RenewalMessage {
  school_id: string
  school_name: string
  stage: ReminderStage
  contact_name: string | null
  phone: string | null
  expires_on: string | null
  days_left: number | null
  stops_on: string | null
  renewal_amount: number | null
  outstanding: number
  text: string
  /** Digits with Pakistan's country code, ready for whatsappLink(). Null when
   *  the school has no number on record — a wa.me link built on an empty string
   *  opens a blank contact picker, which reads as the software losing the
   *  message. */
  phone_intl: string | null
  no_phone_reason: string | null
}

/** Composes the message. Does NOT record anything — see markReminded. */
export async function renewalMessage(
  schoolId: string, stage?: ReminderStage,
): Promise<RenewalMessage> {
  const sb = requireSupabase()
  const { data, error } = await sb.rpc('fn_platform_renewal_message', {
    p_school_id: schoolId, p_stage: stage ?? null,
  })
  if (error) throw new Error(error.message)
  return data as RenewalMessage
}

/**
 * Records that WhatsApp was opened for this school, which is the honest claim:
 * we know a message was composed and the chat opened, and we do not know it was
 * read. The worklist shows it so nobody nags the same school twice in a morning.
 */
export async function markReminded(
  schoolId: string, stage: ReminderStage, note?: string | null,
): Promise<void> {
  const sb = requireSupabase()
  const { error } = await sb.rpc('fn_platform_mark_reminded', {
    p_school_id: schoolId, p_stage: stage, p_note: note ?? null,
  })
  if (error) throw new Error(error.message)
}

/**
 * A school saying it has transferred money.
 *
 * A REQUEST, not a receipt. It changes no total and appears in no revenue
 * figure until the operator has seen the transfer on the bank statement — a
 * school-writable payment would let a school clear its own balance by typing a
 * number.
 */
export interface PaymentClaim {
  id: string
  school_id: string
  school_name: string
  amount: number
  paid_on: string
  method: string
  reference: string | null
  from_bank: string | null
  note: string | null
  claimed_at: string
  /** Who at the school reported it — who to ask when a reference does not match. */
  claimed_by_name: string | null
  status: 'pending' | 'confirmed' | 'rejected'
  decided_at: string | null
  decision_note: string | null
  payment_id: string | null
  outstanding: number
}

export async function paymentClaims(
  status: 'pending' | 'confirmed' | 'rejected' | 'all' = 'pending',
): Promise<PaymentClaim[]> {
  const sb = requireSupabase()
  const { data, error } = await sb.rpc('fn_platform_payment_claims', { p_status: status })
  if (error) throw new Error(error.message)
  return (data ?? []) as PaymentClaim[]
}

/**
 * Turn a report into money.
 *
 * Goes through the ordinary receipt path, so a confirmed report and a payment
 * the operator typed in are indistinguishable afterwards. `amount` null accepts
 * what the school said; an explicit amount is for when the bank statement
 * disagrees, which happens when a school transfers net of withholding tax and
 * reports the gross.
 */
export async function confirmClaim(input: {
  claimId: string; amount?: number | null; invoiceId?: string | null
  taxWithheld?: number | null; taxCertificate?: string | null; note?: string | null
}): Promise<{ claim_id: string; payment_id: string; amount: number }> {
  const sb = requireSupabase()
  const { data, error } = await sb.rpc('fn_platform_confirm_claim', {
    p_claim_id: input.claimId, p_amount: input.amount ?? null,
    p_invoice_id: input.invoiceId ?? null,
    p_tax_withheld: input.taxWithheld ?? 0,
    p_tax_certificate: input.taxCertificate ?? null,
    p_note: input.note ?? null,
  })
  if (error) throw new Error(error.message)
  return data as { claim_id: string; payment_id: string; amount: number }
}

/** The reason is shown to the school. "Rejected" with nothing else is how a
 *  customer relationship breaks over a typo in a reference number. */
export async function rejectClaim(claimId: string, reason: string): Promise<void> {
  const sb = requireSupabase()
  const { error } = await sb.rpc('fn_platform_reject_claim', {
    p_claim_id: claimId, p_reason: reason,
  })
  if (error) throw new Error(error.message)
}

// ===========================================================================
// Phase 4 — lifecycle: start a school, suspend it, and end it.
// Migrations 0079, 0080.
// ===========================================================================

/**
 * Stop a school working, immediately, whatever its licence dates say.
 *
 * The reason is NOT an operator note. fn_my_licence returns it and the school's
 * own banner shows it, because a school whose software stops with no explanation
 * phones in a panic — and the person answering is the person who suspended it.
 * The database refuses a blank reason for exactly that reason.
 */
export async function suspendSchool(
  schoolId: string, reason: string,
): Promise<{ suspended: boolean; reason: string; what_still_works: string }> {
  const sb = requireSupabase()
  const { data, error } = await sb.rpc('fn_platform_suspend_school', {
    p_school_id: schoolId, p_reason: reason,
  })
  if (error) throw new Error(error.message)
  return data as { suspended: boolean; reason: string; what_still_works: string }
}

export async function unsuspendSchool(
  schoolId: string, note?: string | null,
): Promise<{ suspended: boolean; status: string }> {
  const sb = requireSupabase()
  const { data, error } = await sb.rpc('fn_platform_unsuspend_school', {
    p_school_id: schoolId, p_note: note ?? null,
  })
  if (error) throw new Error(error.message)
  return data as { suspended: boolean; status: string }
}

/**
 * End the commercial relationship. NOT archive (which hides them) and NOT purge
 * (which destroys them) — a school that cancels in June and comes back in August
 * finds everything as it was, which happens more often than not.
 *
 * `note` in the response says whether money is still owed, because cancelling
 * does not write a debt off and the console must not imply that it does.
 */
export async function cancelSubscription(
  schoolId: string, reason: string,
): Promise<{ status: string; outstanding: number; note: string; data: string }> {
  const sb = requireSupabase()
  const { data, error } = await sb.rpc('fn_platform_cancel_subscription', {
    p_school_id: schoolId, p_reason: reason,
  })
  if (error) throw new Error(error.message)
  return data as { status: string; outstanding: number; note: string; data: string }
}

/**
 * A different grace window for one school. Null restores the standard one and
 * needs no reason; anything else is a favour or a squeeze and needs one.
 */
export async function setGrace(
  schoolId: string, days: number | null, reason?: string | null,
): Promise<{ grace_days: number; is_override: boolean; status: string }> {
  const sb = requireSupabase()
  const { data, error } = await sb.rpc('fn_platform_set_grace', {
    p_school_id: schoolId, p_days: days, p_reason: reason ?? null,
  })
  if (error) throw new Error(error.message)
  return data as { grace_days: number; is_override: boolean; status: string }
}

/** Out of the console, licence dead, data completely intact. Reversible. */
export async function archiveSchool(
  schoolId: string, reason: string,
): Promise<{ archived: boolean; outstanding: number; what_this_did: string[]; reversible: boolean }> {
  const sb = requireSupabase()
  const { data, error } = await sb.rpc('fn_platform_archive_school', {
    p_school_id: schoolId, p_reason: reason,
  })
  if (error) throw new Error(error.message)
  return data as {
    archived: boolean; outstanding: number; what_this_did: string[]; reversible: boolean
  }
}

export async function unarchiveSchool(
  schoolId: string,
): Promise<{ archived: boolean; note: string }> {
  const sb = requireSupabase()
  const { data, error } = await sb.rpc('fn_platform_unarchive_school', {
    p_school_id: schoolId,
  })
  if (error) throw new Error(error.message)
  return data as { archived: boolean; note: string }
}

export async function createSchool(input: {
  name: string; city?: string | null; contactName?: string | null
  contactPhone?: string | null; contactEmail?: string | null
  planCode?: string; trialDays?: number; notes?: string | null
}): Promise<{
  school_id: string; name: string; plan_code: string
  trial_ends_on: string; trial_days: number; still_needed: string
}> {
  const sb = requireSupabase()
  const { data, error } = await sb.rpc('fn_platform_create_school', {
    p: {
      name: input.name, city: input.city ?? null,
      contact_name: input.contactName ?? null,
      contact_phone: input.contactPhone ?? null,
      contact_email: input.contactEmail ?? null,
      plan_code: input.planCode ?? 'starter',
      trial_days: input.trialDays ?? 14,
      notes: input.notes ?? null,
    },
  })
  if (error) throw new Error(error.message)
  return data as {
    school_id: string; name: string; plan_code: string
    trial_ends_on: string; trial_days: number; still_needed: string
  }
}

// --- offboarding -----------------------------------------------------------

export interface ExportManifest {
  school_id: string
  school_name: string
  archived_at: string
  /** Every data table, INCLUDING the empty ones. A manifest that omits what has
   *  no rows makes "they never used marks" and "marks were left out of the
   *  export" look identical. */
  tables: { name: string; rows: number }[]
  total_rows: number
  previous_exports: { taken_at: string; total_rows: number; by: string | null }[]
}

/** Refuses unless the school is ARCHIVED. A full export of every child's name
 *  and every guardian's phone number is an offboarding step, not a way to pull a
 *  live customer's records — and archiving is reversible, logged and reasoned. */
export async function exportManifest(schoolId: string): Promise<ExportManifest> {
  const sb = requireSupabase()
  const { data, error } = await sb.rpc('fn_platform_export_manifest', {
    p_school_id: schoolId,
  })
  if (error) throw new Error(error.message)
  return data as ExportManifest
}

/** One table, one page. A school with three years of daily attendance for 600
 *  children is over a million rows in that table alone, and a truncated export
 *  that reported success is how "we gave you everything" becomes untrue. */
export async function exportTable(
  schoolId: string, table: string, offset = 0, limit = 1000,
): Promise<{ table: string; offset: number; limit: number; rows: unknown[]; count: number }> {
  const sb = requireSupabase()
  const { data, error } = await sb.rpc('fn_platform_export_table', {
    p_school_id: schoolId, p_table: table, p_offset: offset, p_limit: limit,
  })
  if (error) throw new Error(error.message)
  return data as {
    table: string; offset: number; limit: number; rows: unknown[]; count: number
  }
}

/** The row that survives the purge, and the only answer to "you deleted our
 *  records". Written from the counts ACTUALLY put in the file. */
export async function recordExport(
  schoolId: string, counts: Record<string, number>, note?: string | null,
): Promise<{ export_id: string; total_rows: number; taken_at: string }> {
  const sb = requireSupabase()
  const { data, error } = await sb.rpc('fn_platform_record_export', {
    p_school_id: schoolId, p_counts: counts, p_note: note ?? null,
  })
  if (error) throw new Error(error.message)
  return data as { export_id: string; total_rows: number; taken_at: string }
}

/**
 * The only irreversible thing in this product.
 *
 * Five refusals stand in front of it: not the operator, not archived, never
 * exported, the typed name does not match, and money still owed. Only the last
 * is overridable — "they will never pay and I want them gone" is a legitimate
 * decision; the other four are not.
 */
export async function purgeSchool(
  schoolId: string, confirmName: string, forceDespiteDebt = false,
): Promise<{
  purged: boolean; school_name: string; rows_deleted: number
  photos_deleted: number; passes: number; by_table: Record<string, number>
  exported_at: string
  kept: { invoices: number; payments: number; why: string }
  also_kept: string
}> {
  const sb = requireSupabase()
  const { data, error } = await sb.rpc('fn_platform_purge_school', {
    p_school_id: schoolId, p_confirm_name: confirmName,
    p_force_despite_debt: forceDespiteDebt,
  })
  if (error) throw new Error(error.message)
  return data as {
    purged: boolean; school_name: string; rows_deleted: number
    photos_deleted: number; passes: number; by_table: Record<string, number>
    exported_at: string
    kept: { invoices: number; payments: number; why: string }
    also_kept: string
  }
}

/**
 * The owner login for a school the console created.
 *
 * fn_platform_create_school makes the school row; nobody can sign in to it until
 * this runs, and in the console the two states look identical. Minting an auth
 * user needs the service_role key, so it goes through an Edge Function that
 * checks is_platform_admin() itself and refuses a school that already has
 * logins.
 *
 * NOT the public signup link: /signup calls `signup-school`, which creates a
 * NEW school, so a principal following that link would end up with a second
 * empty one while the school the operator set up stayed unreachable.
 */
export async function createSchoolOwner(input: {
  schoolId: string; email: string; password: string; fullName: string
}): Promise<{ school_name: string; email: string; next: string }> {
  const sb = requireSupabase()
  const { data, error } = await sb.functions.invoke('create-school-owner', {
    body: {
      school_id: input.schoolId,
      email: input.email.trim().toLowerCase(),
      password: input.password,
      full_name: input.fullName.trim(),
    },
  })
  if (!error) return data as { school_name: string; email: string; next: string }

  // The function ran and refused. Its own message is the useful one — "that
  // school already has logins" is an instruction, and replacing it with a
  // generic failure is how a fixable situation becomes a support call.
  if ((error as { name?: string }).name === 'FunctionsHttpError') {
    let msg = error.message
    try {
      const ctx = await (error as unknown as {
        context?: { json?: () => Promise<{ error?: string }> }
      }).context?.json?.()
      if (ctx?.error) msg = ctx.error
    } catch { /* keep the original message */ }
    throw new Error(msg)
  }
  throw new Error(
    'The create-school-owner function is not deployed. Run '
    + '`supabase functions deploy create-school-owner`, or send the school the '
    + 'signup page and let them create their own school instead.',
  )
}

// ===========================================================================
// Phase 5 — what the business is worth. Migration 0081.
// ===========================================================================

/**
 * MRR, ARR, churn, trial conversion and the per-plan breakdown.
 *
 * Every block carries a `basis` or a `note` saying what it measures. A metric on
 * a dashboard with no definition becomes whatever the person looking at it
 * assumes, and two people then argue about a number they define differently.
 *
 * `measurable: false` is a real answer and the UI must render it as one. Churn
 * on a database with no dated history is unknown, not zero, and a confident zero
 * is the most misleading thing this screen could show.
 */
export interface PlatformMetrics {
  as_at: string
  recurring: {
    mrr: number; arr: number; paying_schools: number; in_grace: number
    /** Average revenue per PAYING school. Dividing by trials and locked accounts
     *  makes the figure drop every time a demo is set up. */
    arps: number
    basis: string
  }
  /** Live schools with licence time no invoice covers. They add nothing to MRR
   *  because nothing was billed — and the count is reported so the zero is
   *  visible rather than silent. */
  unbilled: { schools: number; note: string }
  counts: {
    paying: number; in_grace: number; on_trial: number
    locked: number; cancelled: number; archived: number
    live_total: number; students_at_paying_schools: number
  }
  conversion:
    | { measurable: false; why: string }
    | { measurable: true; trials_finished: number; converted: number; rate_pct: number; basis: string }
  churn:
    | { measurable: false; why: string }
    | { measurable: true; lost_12m: number; rate_pct: number; history_starts: string; basis: string }
  /** Returned by fn_platform_revenue since 0064 and rendered nowhere until now. */
  by_plan: {
    plan_code: string; plan_name: string; schools: number
    students: number; mrr: number
    /** What they WOULD contribute at list price. The gap is what has been given
     *  away, which is the figure 0064 was written to make visible. */
    list_mrr: number
  }[]
}

export async function platformMetrics(asAt?: string): Promise<PlatformMetrics> {
  const sb = requireSupabase()
  const { data, error } = await sb.rpc('fn_platform_metrics', { p_as_at: asAt ?? null })
  if (error) throw new Error(error.message)
  return data as PlatformMetrics
}

/**
 * One row per month: schools, and the pupils inside them.
 *
 * Read from student_count_snapshots, which 0026 has written on every recount
 * since it shipped and which nothing had ever read. It is a daily record of the
 * customers' growth, which is the vendor's own growth.
 */
export interface GrowthPoint {
  month: string
  schools: number
  students: number
  avg_per_school: number
}

export async function platformGrowth(months = 12): Promise<GrowthPoint[]> {
  const sb = requireSupabase()
  const { data, error } = await sb.rpc('fn_platform_growth', { p_months: months })
  if (error) throw new Error(error.message)
  return (data ?? []) as GrowthPoint[]
}

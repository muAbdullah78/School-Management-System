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
}

export interface LedgerEntry {
  entry_date: string
  kind: 'invoice' | 'payment'
  description: string
  charged: number | null
  paid: number | null
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

export async function listPlatformSchools(): Promise<PlatformSchool[]> {
  const sb = requireSupabase()
  const { data, error } = await sb.rpc('fn_platform_schools')
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
export async function recordPlatformPayment(input: {
  schoolId: string; amount: number; paidOn?: string | null
  method?: string; reference?: string | null; invoiceId?: string | null; note?: string | null
}): Promise<{ payment_id: string; outstanding: number }> {
  const sb = requireSupabase()
  const { data, error } = await sb.rpc('fn_platform_record_payment', {
    p_school_id: input.schoolId, p_amount: input.amount,
    p_paid_on: input.paidOn ?? null, p_method: input.method ?? 'bank',
    p_reference: input.reference ?? null, p_invoice_id: input.invoiceId ?? null,
    p_note: input.note ?? null,
  })
  if (error) throw new Error(error.message)
  return data as { payment_id: string; outstanding: number }
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
    default:
      return a.action.replace(/_/g, ' ')
  }
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

/**
 * Subscription state for the signed-in school.
 *
 * Everything here comes from one server call (`fn_my_licence`). The server is
 * the authority. It refuses writes from a locked school regardless of what the
 * UI does, so this is only about showing the school an honest, early warning
 * rather than letting them discover it when a Save fails.
 */
import { requireSupabase } from './supabase'

export type SubscriptionStatus = 'trialing' | 'active' | 'grace' | 'locked' | 'cancelled'
export type LimitState = 'ok' | 'within_margin' | 'over'

export interface Licence {
  ok: true
  school_id: string
  status: SubscriptionStatus
  locked: boolean
  can_read: boolean
  can_export: boolean
  can_operate: boolean
  plan_code: string
  plan_name: string
  /** 0127 added 'quarterly' to this enum. Nothing in the app narrows on it,
   *  but a union that omits a value the database can return is a type that
   *  lies, and the next `switch` written against it would silently miss a case. */
  cycle: 'monthly' | 'quarterly' | 'yearly'
  price_monthly: number
  price_yearly: number
  expires_on: string | null
  days_left: number | null
  student_count: number
  student_limit: number | null
  /** How many months the NEXT invoice covers. 1, 3 or 12 from the price list;
   *  an operator can invoice any number from 1 to 60. */
  term_months?: number | null
  margin_limit: number | null
  limit_state: LimitState
  limit_notice: string | null
  // ---- 0128: the limit stopped being advisory ----
  /** What the PLAN covers, beside `student_limit`, which now includes any
   *  allowance an operator granted this school. */
  plan_student_limit?: number | null
  limit_is_granted?: boolean
  /** Places left, or null when the plan has no limit at all. */
  room?: number | null
  /** At or above the limit: an admission is refused right now. */
  at_limit?: boolean
  /** At or above 90% of it, which is when the warning starts. */
  warn_limit?: boolean
  /** The same news worded for somebody who cannot act on it: a clerk is the
   *  person who presses Admit, and telling them nothing means they meet the
   *  refusal with a parent standing at the desk. */
  limit_notice_staff?: string | null
}

export interface LicenceUnavailable {
  ok: false
  reason: 'no_school' | 'no_subscription'
}

export async function fetchLicence(): Promise<Licence | LicenceUnavailable> {
  const sb = requireSupabase()
  const { data, error } = await sb.rpc('fn_my_licence')
  if (error) throw new Error(error.message)
  return data as Licence | LicenceUnavailable
}

/**
 * How loudly to warn about an approaching expiry.
 *
 * Silent until a week out, then steadily louder. A banner that shouts from day
 * one is a banner people stop reading by the time it matters.
 */
export type Urgency = 'none' | 'info' | 'warn' | 'critical'

export function expiryUrgency(lic: Licence): Urgency {
  if (lic.status === 'locked' || lic.status === 'cancelled') return 'critical'
  if (lic.status === 'grace') return 'critical'
  const d = lic.days_left
  if (d === null) return 'none'
  if (d <= 3) return 'critical'
  if (d <= 7) return 'warn'
  if (lic.status === 'trialing' && d <= 14) return 'info'
  return 'none'
}

/** Plain-language expiry line. Written to be read by a school owner, not a developer. */
export function expiryMessage(lic: Licence): string | null {
  const d = lic.days_left
  switch (lic.status) {
    case 'trialing':
      if (d === null) return null
      if (d <= 0) return 'Your free trial has ended.'
      return d === 1 ? 'Last day of your free trial.' : `${d} days left in your free trial.`
    case 'active':
      if (d === null || d > 7) return null
      if (d <= 0) return 'Your subscription ends today.'
      return d === 1 ? 'Your subscription ends tomorrow.' : `Your subscription ends in ${d} days.`
    case 'grace':
      if (d === null || d <= 0) return 'Your subscription has ended. Please renew today.'
      return d === 1
        ? 'Your subscription has ended. You have 1 day left before the app stops accepting entries.'
        : `Your subscription has ended. You have ${d} days left before the app stops accepting entries.`
    case 'locked':
      return 'Your subscription has ended.'
    case 'cancelled':
      return 'Your subscription has been cancelled.'
    default:
      return null
  }
}

/**
 * The student-limit strip: what to say, to whom, and how loudly.
 *
 * Pure, and out here rather than inside LicenceBanner, because this is the
 * decision that went wrong. The component used to gate on
 * `limit_state !== 'ok' && limit_notice`, and limit_state is 'ok' while the
 * count is at or BELOW the limit. So a school sitting exactly on its limit, the
 * moment migration 0128 starts refusing the next admission, had its warning
 * suppressed here while the server was willing to give it. A rule that lives
 * inside a component is a rule nothing can test.
 *
 * Two wordings, because two audiences:
 *
 *   owner, principal   `limit_notice`, which names Settings then Subscription
 *                      and both ways out, because they can take one.
 *   admin_clerk        `limit_notice_staff`, which says what is happening, that
 *                      it is not their doing, and who can fix it. They are the
 *                      person who presses Admit and meets the refusal.
 *   everyone else      nothing. A teacher does not admit pupils.
 *
 * Returns null when there is nothing to say, which is the ordinary case: below
 * 90% of the limit the server sends no notice at all, because a banner a school
 * sees every day is a banner it stops reading.
 */
export function limitBanner(
  lic: Licence, role: string | null | undefined,
): { text: string; atLimit: boolean } | null {
  const text = role === 'owner' || role === 'principal'
    ? lic.limit_notice
    : role === 'admin_clerk'
      ? (lic.limit_notice_staff ?? null)
      : null
  if (!text) return null
  // `at_limit` arrived with 0128. The fallback stops an app running against a
  // database without it from painting every warning as a wall.
  return { text, atLimit: lic.at_limit ?? lic.limit_state === 'over' }
}

export function formatPkr(amount: number): string {
  return `Rs ${Math.round(amount).toLocaleString('en-PK')}`
}

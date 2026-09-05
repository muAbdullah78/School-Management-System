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
  cycle: 'monthly' | 'yearly'
  price_monthly: number
  price_yearly: number
  expires_on: string | null
  days_left: number | null
  student_count: number
  student_limit: number | null
  margin_limit: number | null
  limit_state: LimitState
  limit_notice: string | null
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

export function formatPkr(amount: number): string {
  return `Rs ${Math.round(amount).toLocaleString('en-PK')}`
}

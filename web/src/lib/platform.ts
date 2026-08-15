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

export async function activateSubscription(
  schoolId: string, planCode: string, months: number,
): Promise<void> {
  const sb = requireSupabase()
  const { error } = await sb.rpc('fn_activate_subscription', {
    p_school_id: schoolId, p_plan_code: planCode, p_months: months,
  })
  if (error) throw new Error(error.message)
}

export async function extendTrial(schoolId: string, days: number): Promise<void> {
  const sb = requireSupabase()
  const { error } = await sb.rpc('fn_extend_trial', { p_school_id: schoolId, p_days: days })
  if (error) throw new Error(error.message)
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
  if (s.limit_state === 'over') return 3
  if (s.status === 'trialing') return 4
  return 5
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

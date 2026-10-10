/**
 * Subscription state for the signed-in school.
 *
 * Everything here comes from one server call (`fn_my_licence`). The server is
 * the authority. It refuses writes from a locked school regardless of what the
 * UI does, so this is only about showing the school an honest, early warning
 * rather than letting them discover it when a Save fails.
 */
import { requireSupabase } from './supabase'
import { today as pkToday } from './dates'
import { fmtDate } from './format'

export type SubscriptionStatus = 'trialing' | 'active' | 'grace' | 'locked' | 'cancelled'
/** 0155 removed the hidden 10% margin: a roll is within its limit or over it. */
export type LimitState = 'ok' | 'over'

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
  // ---- 0155: access runs on what is paid ----
  /** Why the school is locked, when it is. */
  locked_because?: 'suspended' | 'cancelled' | 'needs_price' | 'unpaid' | 'expired' | null
  /** The first day the school is locked if nothing more is paid. */
  locks_on?: string | null
  paid_through?: string | null
  trial_ends_on?: string | null
  /** What to pay now, credit taken off. */
  pay_now?: number
  by_arrangement?: boolean
  /** Enterprise with no price agreed yet. */
  needs_price?: boolean
  /** When extra room we granted ends. */
  extra_until?: string | null
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
 * How loudly to warn, and what to say, under the 0155 rules.
 *
 * WHAT CHANGED, AND WHY THE OLD WORDS WERE WRONG. Before 0155 a licence ran to
 * a date and then had grace, so "your subscription ends in 3 days" was the
 * whole story. Now access runs on what is PAID: every invoice is due on the
 * first day of the period it pays for, the school keeps working for fourteen
 * days of grace after that, and only then do new entries pause. So the day a
 * payment falls due is not the day anything stops, and a red banner on the due
 * date would be shouting about a day that changes nothing. The loud colours
 * are kept for the days that count: the last few before new entries pause.
 *
 * One exception, and it is the reason `needs_price` is read here: an Enterprise
 * school with no price agreed has nothing it can be invoiced for, so it gets no
 * grace. Its trial's end IS the day it locks, and the banner says so from the
 * start and gets louder as that day comes.
 *
 * THE COUNTS INCLUDE TODAY. `days_left` is the number of days from today to the
 * last covered day, so on the last day of a trial it is 0 and on signup day of
 * a fourteen-day trial it is 13. A school counts the day it is in, so "14 days
 * left" on day one is what it reads, and "0 days left" is never shown.
 *
 * `today` is a parameter so the rules can be tested against a fixed date; the
 * app passes nothing and gets today in Pakistan, the same clock the database
 * uses.
 */
export type Urgency = 'none' | 'info' | 'warn' | 'critical'

/** Whole calendar days from one YYYY-MM-DD date to another. */
function daysFrom(from: string, to: string): number {
  const at = (s: string) => Date.UTC(+s.slice(0, 4), +s.slice(5, 7) - 1, +s.slice(8, 10))
  return Math.round((at(to) - at(from)) / 86_400_000)
}

/**
 * Days left to pay, today included, before new entries pause. From `locks_on`,
 * the first locked day, when the database sent it; an older database that did
 * not gets the same count from `days_left`, whose last day is the day before.
 */
function daysToLock(lic: Licence, today: string): number | null {
  if (lic.locks_on) return daysFrom(today, lic.locks_on)
  return lic.days_left == null ? null : lic.days_left + 1
}

/**
 * A paid school with a payment past its due date while its paid period is
 * still running. That happens when we move a school up a plan mid-period and
 * charge the difference: the charge is due the day it is raised, so the
 * fourteen days start then, inside time the school has already paid for. The
 * tell is a lock date that comes before the paid period ends.
 */
function paymentClockRunning(lic: Licence): boolean {
  return lic.status === 'active' && !!lic.locks_on && !!lic.paid_through
    && lic.locks_on <= lic.paid_through
}

function leftToPay(n: number | null): string {
  if (n === null) return 'Please pay soon to keep new entries working.'
  if (n <= 1) return 'Today is the last day to pay before new entries are paused.'
  return `${n} days left to pay before new entries are paused.`
}

export function expiryUrgency(lic: Licence, today: string = pkToday()): Urgency {
  if (lic.status === 'locked' || lic.status === 'cancelled') return 'critical'
  if (lic.status === 'grace' || paymentClockRunning(lic)) {
    const n = daysToLock(lic, today)
    return n !== null && n <= 3 ? 'critical' : 'warn'
  }
  const d = lic.days_left
  if (d === null) return 'none'
  const left = d + 1
  if (lic.status === 'trialing') {
    // Locks at the trial's end with no grace, so it escalates like a lock.
    if (lic.needs_price) return left <= 3 ? 'critical' : left <= 7 ? 'warn' : 'info'
    // Grace follows an ordinary trial, so its end is news, not an alarm.
    if (left <= 3) return 'warn'
    return left <= 14 ? 'info' : 'none'
  }
  if (lic.status === 'active') {
    // Due within a week, and only when there is something to pay: credit
    // already covering the next term leaves nothing to say.
    if (d > 7 || lic.pay_now === 0) return 'none'
    return 'info'
  }
  return 'none'
}

/** Plain-language line for the strip. Written to be read by a school owner, not a developer. */
export function expiryMessage(lic: Licence, today: string = pkToday()): string | null {
  const d = lic.days_left
  switch (lic.status) {
    case 'trialing': {
      if (d === null) return null
      const left = d + 1
      const trial = left <= 1
        ? 'Today is the last day of your free trial.'
        : `${left} days left in your free trial.`
      if (lic.needs_price) {
        return `${trial} We have not agreed your price yet, and new entries are paused `
          + 'when the trial ends until we do.'
      }
      return trial
    }
    case 'active': {
      if (paymentClockRunning(lic)) return `A payment is due. ${leftToPay(daysToLock(lic, today))}`
      if (d === null || d > 7 || lic.pay_now === 0) return null
      // Due on the first day of the next period, the day after the paid one ends.
      const due = d + 1
      return due === 1 ? 'Your next payment is due tomorrow.' : `Your next payment is due in ${due} days.`
    }
    case 'grace':
      return `${lic.paid_through ? 'Your paid period has ended.' : 'Your free trial has ended.'} `
        + leftToPay(daysToLock(lic, today))
    case 'locked':
      switch (lic.locked_because) {
        case 'needs_price': return 'Your free trial has ended and your price is not agreed yet.'
        case 'unpaid': return 'A payment is overdue, so new entries are paused.'
        case 'suspended': return 'This school has been paused by us.'
        case 'cancelled': return 'This subscription has been cancelled.'
        case 'expired':
          return lic.paid_through
            ? 'Your paid period has ended, so new entries are paused.'
            : 'Your free trial has ended, so new entries are paused.'
        default: return 'New entries are paused until a payment reaches us.'
      }
    case 'cancelled':
      return 'This subscription has been cancelled.'
    default:
      return null
  }
}

/**
 * The student-limit strip: what to say, to whom, and how loudly.
 *
 * Pure, and out here rather than inside RollLimitNotice, because this is the
 * decision that went wrong. The component used to gate on
 * `limit_state !== 'ok' && limit_notice`, and limit_state is 'ok' while the
 * count is at or BELOW the limit. So a school sitting exactly on its limit, the
 * moment the database starts refusing the next admission, had its warning
 * suppressed while the server was willing to give it. A rule that lives inside
 * a component is a rule nothing can test.
 *
 * THE LIMIT IS THE LIMIT (0155). There used to be a hidden 10% on top of every
 * plan, and the words around it had to explain a number nobody was shown. Now
 * the warning starts at 90% and admissions stop at 100%, and nothing here
 * mentions a margin because there is none.
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
 * EXTRA ROOM ENDS, and the owner is told when. Room we grant above the plan
 * lasts to the next renewal (`extra_until`) and then the plan's own limit is
 * back. A school relying on it finds out on the day admissions stop unless
 * something says the date beforehand, so the leadership wording carries it,
 * and a school whose roll only fits because of that room hears it even when
 * the server has no limit notice to send.
 *
 * Returns null when there is nothing to say, which is the ordinary case: below
 * 90% of the limit the server sends no notice at all, because a banner a school
 * sees every day is a banner it stops reading.
 */
export function limitBanner(
  lic: Licence, role: string | null | undefined,
): { text: string; atLimit: boolean } | null {
  const leader = role === 'owner' || role === 'principal'
  let text = leader
    ? lic.limit_notice
    : role === 'admin_clerk'
      ? (lic.limit_notice_staff ?? null)
      : null
  if (leader && lic.extra_until) {
    const ends = `The extra room we gave you ends on ${fmtDate(lic.extra_until)}.`
    const plan = lic.plan_student_limit
    if (text) {
      text = `${text} ${ends}`
    } else if (plan != null && lic.student_count > plan) {
      text = `You have ${lic.student_count.toLocaleString('en-PK')} pupils and your plan covers `
        + `${plan.toLocaleString('en-PK')}. ${ends} If you still need the room after that, `
        + 'ask us from Settings then Subscription before then.'
    }
  }
  if (!text) return null
  // `at_limit` arrived with 0128. The fallback stops an app running against a
  // database without it from painting every warning as a wall.
  return { text, atLimit: lic.at_limit ?? lic.limit_state === 'over' }
}

export function formatPkr(amount: number): string {
  return `Rs ${Math.round(amount).toLocaleString('en-PK')}`
}

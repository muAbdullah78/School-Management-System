/**
 * The rules a discount code lives by, on our side of the console.
 *
 * NOTHING HERE DECIDES ANYTHING. The database checks every code it is given
 * (fn__discount_validate) and works out every saving (fn__discount_calc). This
 * file mirrors those two so the form can say what is wrong before the round
 * trip and the worked example can put a figure on a code before it exists. The
 * sentences are the database's own, word for word, so an operator reads the
 * same words whichever side noticed first; when the two ever disagree it is the
 * database's sentence that is shown, because it is the one that refused.
 */
import type { DiscountCode, DiscountDuration, DiscountKind, DiscountTerms } from '@/lib/platform'

/** One plan as the price list gives it (fn_platform_price_list). */
export interface PricedPlan {
  code: string
  name: string
  active: boolean
  by_arrangement: boolean
  month: number
  quarter: number
  year: number
}

/** The form, as typed. Numbers stay text until they are sent, so a half-typed
 *  box is never silently a zero. */
export interface TermsForm {
  code: string
  label: string
  description: string
  kind: DiscountKind
  value: string
  /** 'once' only ever for trial days, which have no duration to choose. */
  duration: DiscountDuration
  durationMonths: string
  durationUntil: string
  redeemFrom: string
  redeemUntil: string
  maxRedemptions: string
  /** Empty means every plan. */
  planCodes: string[]
  minTermMonths: '' | '3' | '12'
  active: boolean
  private: boolean
  schoolId: string
}

export const BLANK_FORM: TermsForm = {
  code: '', label: '', description: '', kind: 'percent', value: '10',
  duration: 'months', durationMonths: '3', durationUntil: '',
  redeemFrom: '', redeemUntil: '', maxRedemptions: '',
  planCodes: [], minTermMonths: '', active: true, private: false, schoolId: '',
}

/** A saved code, as the form holds it. */
export function formFromCode(c: DiscountCode): TermsForm {
  return {
    code: c.code,
    label: c.label ?? '',
    description: c.description ?? '',
    kind: c.kind,
    value: c.value == null ? '' : String(Number(c.value)),
    duration: c.duration,
    durationMonths: c.duration_months == null ? '' : String(c.duration_months),
    durationUntil: c.duration_until ?? '',
    redeemFrom: c.redeem_from ?? '',
    redeemUntil: c.redeem_until ?? '',
    maxRedemptions: c.max_redemptions == null ? '' : String(c.max_redemptions),
    planCodes: c.plan_codes ?? [],
    minTermMonths: c.min_term_months === 3 ? '3' : c.min_term_months === 12 ? '12' : '',
    active: c.active,
    private: !!c.private,
    schoolId: c.school_id ?? '',
  }
}

/**
 * The form as the database reads it.
 *
 * SHAPED THE WAY fn__discount_from_json SHAPES IT, so that comparing two of
 * these is comparing what would be saved: trial days are added once and have
 * no plans or term; a duration drops the fields it does not use; a private code
 * is one school's and has one place.
 */
export function termsFromForm(f: TermsForm, planOrder: string[] = []): DiscountTerms {
  const trial = f.kind === 'trial_days'
  const duration: DiscountDuration = trial ? 'once' : f.duration
  const num = (s: string) => (s.trim() === '' ? null : Number(s))
  const order = (c: string) => {
    const i = planOrder.indexOf(c)
    return i < 0 ? planOrder.length : i
  }
  const plans = trial || f.planCodes.length === 0
    ? null
    : [...new Set(f.planCodes)].sort((a, b) => order(a) - order(b) || a.localeCompare(b))
  return {
    label: f.label.trim(),
    description: f.description.trim(),
    kind: f.kind,
    value: num(f.value) ?? 0,
    duration,
    duration_months: duration === 'months' ? num(f.durationMonths) : null,
    duration_until: duration === 'until' ? (f.durationUntil || null) : null,
    redeem_from: f.redeemFrom || null,
    redeem_until: f.redeemUntil || null,
    max_redemptions: f.private ? 1 : num(f.maxRedemptions),
    plan_codes: plans,
    min_term_months: trial || !f.minTermMonths ? null : (Number(f.minTermMonths) as 3 | 12),
    active: f.active,
    private: f.private,
    school_id: f.private ? (f.schoolId || null) : null,
  }
}

/** What may still change once a school has the code (fn_platform_edit_discount). */
export const OPEN_WHEN_LOCKED = [
  'label', 'description', 'redeem_from', 'redeem_until', 'max_redemptions', 'active',
] as const

/**
 * The fields an edit actually changes, and nothing else.
 *
 * ONLY WHAT CHANGED IS SENT. The database re-checks dates only on the fields
 * an edit touches, and a locked code refuses any change to what it gives; a
 * form that sent every field would trip both over values nobody typed.
 */
export function changedTerms(
  before: DiscountTerms, after: DiscountTerms, locked: boolean,
): Partial<DiscountTerms> {
  const out: Partial<DiscountTerms> = {}
  const keys = (locked ? OPEN_WHEN_LOCKED : Object.keys(after)) as (keyof DiscountTerms)[]
  for (const k of keys) {
    if (JSON.stringify(before[k] ?? null) !== JSON.stringify(after[k] ?? null)) {
      (out as Record<string, unknown>)[k] = after[k] ?? null
    }
  }
  return out
}

const CODE_SHAPE = /^[A-Z0-9][A-Z0-9_-]{5,31}$/

/** A code as the database stores it: no spaces, upper case (fn__norm_code). */
export function normCode(s: string): string {
  return s.replace(/\s/g, '').toUpperCase()
}

/**
 * The first rule these terms break, in the database's words, or null.
 *
 * `before` is the code as it was (an edit) or absent (a new code). The dates
 * in the past are refused only when they are new or were changed, as the
 * database does: an expired code can still have its label corrected.
 */
export function checkTerms(
  t: DiscountTerms & { code?: string | null },
  ctx: { today: string; before?: DiscountTerms; seatsTaken?: number; codeName?: string },
): string | null {
  const creating = !ctx.before
  const code = normCode(t.code ?? '')
  if (creating && !(t.private && code === '') && !CODE_SHAPE.test(code)) {
    return 'A code is 6 to 32 letters, digits, dashes or underscores, starting with a letter or digit. Short codes are guessed.'
  }
  if (!t.label.trim() || t.label.length > 80) {
    return 'Give the code a label of up to 80 characters. It is the name the school sees.'
  }
  if (!t.description.trim()) {
    return 'Say what the code is for, in our own words. Schools never see this.'
  }
  const v = Number(t.value)
  if (!Number.isFinite(v) || v <= 0) return 'A discount of nothing is not a discount.'
  if (t.kind === 'percent' && v > 100) return 'A percentage is at most 100.'
  if (t.kind === 'flat' && (!Number.isInteger(v) || v > 50000)) {
    return 'Rupees off each month is a whole number, at most Rs 50,000.'
  }
  if (t.kind === 'trial_days' && (!Number.isInteger(v) || v > 30)) {
    return 'A trial can be extended by 1 to 30 days with a code.'
  }
  if (t.kind !== 'trial_days') {
    if (t.duration === 'months') {
      const m = t.duration_months
      if (m == null || !Number.isInteger(m) || m < 1 || m > 36) {
        return 'Say how many months the code lasts: 1 to 36.'
      }
    }
    if (t.duration === 'until') {
      if (!t.duration_until) return 'Say the date the code runs until.'
      const untilChanged = creating || ctx.before?.duration_until !== t.duration_until
      const floor = t.redeem_until && t.redeem_until > ctx.today ? t.redeem_until : ctx.today
      if (untilChanged && t.duration_until < floor) {
        return 'A code cannot end before today, or before the last day it can be used.'
      }
    }
    if (t.kind === 'percent' && v >= 100 && t.duration === 'forever' && !t.private) {
      return 'A code that makes the subscription free for ever must be private to one school.'
    }
  }
  if (t.redeem_from && t.redeem_until && t.redeem_until < t.redeem_from) {
    return 'The last day it can be used comes before the first.'
  }
  const windowChanged = creating || ctx.before?.redeem_until !== t.redeem_until
  if (t.redeem_until && t.redeem_until < ctx.today && windowChanged) {
    return 'The last day it can be used is in the past.'
  }
  if (t.max_redemptions != null && (!Number.isInteger(t.max_redemptions) || t.max_redemptions < 1)) {
    return 'A limit on schools is at least 1, or none.'
  }
  if (!creating && t.max_redemptions != null && (ctx.seatsTaken ?? 0) > t.max_redemptions) {
    return `${ctx.seatsTaken} school(s) already hold a place on ${ctx.codeName ?? 'this code'}. The limit cannot go below that.`
  }
  if (t.private && !t.school_id) return 'A private code is made for one school. Choose the school.'
  return null
}

/** True for the refusal an edit gets when the code changed under it (40001).
 *  The client in lib/platform.ts passes the message on without the code, so
 *  the sentence is what is matched; the code is read too in case it is kept. */
export function isStaleEdit(e: unknown): boolean {
  const err = e as { code?: string; message?: string } | null
  return err?.code === '40001' || /^Somebody changed /.test(err?.message ?? '')
}

/** True when a give was refused only because the school has a live code and
 *  replacing it was not asked for. */
export function needsReplace(e: unknown): boolean {
  return /Replace it on purpose/.test((e as Error | null)?.message ?? '')
}

// ------------------------------------------------------------------ prices --

/** A plan's price for a term of 1, 3 or 12 months, or null when it is priced
 *  with each school (Enterprise) and so has no figure on the list. */
export function termPrice(p: PricedPlan, months: 1 | 3 | 12): number | null {
  if (p.by_arrangement) return null
  const n = Number(months === 1 ? p.month : months === 3 ? p.quarter : p.year)
  return Number.isFinite(n) && n > 0 ? n : null
}

/** A date plus whole months, the way Postgres adds an interval: the 31st of
 *  January plus a month is the 28th (or 29th) of February. */
export function addMonths(ymd: string, k: number): string {
  const [y, m, d] = ymd.split('-').map(Number)
  const total = y * 12 + (m - 1) + k
  const ny = Math.floor(total / 12)
  const nm = total % 12
  const last = new Date(Date.UTC(ny, nm + 1, 0)).getUTCDate()
  const pad = (n: number, w = 2) => String(n).padStart(w, '0')
  return `${pad(ny, 4)}-${pad(nm + 1)}-${pad(Math.min(d, last))}`
}

/** The billed months of an N-month invoice starting `start` that start on or
 *  before `until` (fn__months_until). */
export function monthsUntil(start: string, months: number, until: string): number {
  let n = 0
  for (let k = 0; k < Math.max(months, 1); k++) if (addMonths(start, k) <= until) n++
  return n
}

/** Round half away from zero over an exact fraction of whole numbers, which is
 *  what Postgres's round() does to an exact numeric. Floating point division
 *  would put 2.5 at 2.4999999 often enough to matter. */
function roundFraction(num: number, den: number): number {
  const q = Math.floor(num / den)
  const r = num - q * den
  return 2 * r >= den ? q + 1 : q
}

export interface CodeTerms {
  code: string
  kind: DiscountKind
  value: number
  duration: DiscountDuration
  /** For a months code: the billed months it still has to give. */
  monthsLeft: number | null
  until: string | null
  planCodes: string[] | null
  minTerm: number | null
}

/**
 * What a code takes off one invoice: fn__discount_calc, line for line.
 *
 * Counted in BILLED MONTHS. On an N-month invoice the code covers the months
 * it still has (a months code), the months that start by its date (an until
 * code), or all N (for as long as they subscribe). A percentage takes that
 * share of the term price; rupees come off each covered month. Never more than
 * the term price, and whole rupees.
 */
export function discountCalc(
  c: CodeTerms,
  inv: { planCode: string; planNames: string; months: number; start: string; termPrice: number | null },
): { covered: number; amount: number; skipped?: string } {
  if ((c.kind !== 'percent' && c.kind !== 'flat') || inv.termPrice == null || inv.termPrice <= 0
      || inv.months < 1) {
    return { covered: 0, amount: 0 }
  }
  if (c.planCodes && !c.planCodes.includes(inv.planCode)) {
    return { covered: 0, amount: 0,
      skipped: `Code ${c.code} is for ${inv.planNames}, so it does not apply to this invoice.` }
  }
  if (c.minTerm != null && inv.months < c.minTerm) {
    return { covered: 0, amount: 0,
      skipped: `Code ${c.code} needs paying for ${c.minTerm} months or more at a time, so it does not apply to a ${inv.months}-month invoice.` }
  }
  const covered = c.duration === 'forever' ? inv.months
    : c.duration === 'months' ? Math.min(inv.months, Math.max(c.monthsLeft ?? 0, 0))
    : c.duration === 'until' && c.until ? monthsUntil(inv.start, inv.months, c.until)
    : 0
  if (covered <= 0) {
    return { covered: 0, amount: 0,
      skipped: `Code ${c.code} has run its course, so it does not apply to this invoice.` }
  }
  let off: number
  if (c.kind === 'percent') {
    // term price x covered / months x pct / 100, in whole numbers: the
    // percentage is held to two decimals as the column holds it.
    const pct = Math.round(Number(c.value) * 100)
    off = roundFraction(Math.round(inv.termPrice) * covered * pct, inv.months * 100 * 100)
  } else {
    off = Number(c.value) * covered
  }
  off = Math.min(Math.max(off, 0), inv.termPrice)
  return { covered, amount: off }
}

// --------------------------------------------------------------- words ----

export const KIND_WORDS: Record<DiscountKind, string> = {
  percent: 'Percent off',
  flat: 'Rupees off each month',
  trial_days: 'Extra trial days',
}

const DURATION_WORDS: Record<DiscountDuration, string> = {
  months: 'for some months',
  until: 'until a date',
  forever: 'for as long as they subscribe',
  once: 'once',
}

export function termWord(months: number): string {
  return months === 1 ? 'monthly' : months === 12 ? 'yearly' : `${months}-month`
}

export function planNames(codes: string[] | null | undefined, plans: PricedPlan[]): string {
  if (!codes || codes.length === 0) return 'every plan'
  return codes.map((c) => plans.find((p) => p.code === c)?.name ?? c).join(' or ')
}

/** What a log entry calls each field it shows a change to. */
export const FIELD_WORDS: Record<string, string> = {
  label: 'What schools see',
  description: 'Our description',
  kind: 'Kind',
  value: 'Amount',
  duration: 'How long',
  duration_months: 'Months',
  duration_until: 'Runs until',
  redeem_from: 'Can be taken up from',
  redeem_until: 'Can be taken up until',
  max_redemptions: 'Most schools',
  plan_codes: 'Plans',
  min_term_months: 'Shortest term',
  active: 'On offer',
  private: 'Private',
  school_id: 'For school',
}

/** The order a change list reads in: what it gives, then who, then when. */
const FIELD_ORDER = Object.keys(FIELD_WORDS)

/**
 * The fields that differ between two snapshots of a code, in reading order.
 * The version stamp is not a field anybody changed, so it is left out.
 */
export function changedFields(
  before: Record<string, unknown> | null, after: Record<string, unknown> | null,
): string[] {
  if (!before || !after) return []
  return FIELD_ORDER.filter((k) => k in after
    && JSON.stringify(before[k] ?? null) !== JSON.stringify(after[k] ?? null))
}

/** One field's value, as a person reads it. */
export function fieldValue(
  k: string, v: unknown,
  ctx: { plans: PricedPlan[]; schoolName: (id: string) => string | null; fmtDate: (s: string) => string },
): string {
  const none = v == null || v === '' || (Array.isArray(v) && v.length === 0)
  switch (k) {
    case 'kind': return none ? 'none' : KIND_WORDS[v as DiscountKind] ?? String(v)
    case 'duration': return none ? 'none' : DURATION_WORDS[v as DiscountDuration] ?? String(v)
    case 'max_redemptions': return none ? 'no limit' : String(v)
    case 'plan_codes': return planNames(none ? null : (v as string[]), ctx.plans)
    case 'min_term_months': return none ? 'any term' : `${v} months`
    case 'redeem_from': return none ? 'any time' : ctx.fmtDate(String(v))
    case 'redeem_until': return none ? 'no end' : ctx.fmtDate(String(v))
    case 'duration_until': return none ? 'none' : ctx.fmtDate(String(v))
    case 'active': return v ? 'Yes' : 'No, retired'
    case 'private': return v ? 'Yes' : 'No'
    case 'school_id': return none ? 'none' : ctx.schoolName(String(v)) ?? 'a school no longer listed'
    case 'value': return none ? 'none' : String(Number(v))
    default: return none ? 'none' : `"${String(v)}"`
  }
}

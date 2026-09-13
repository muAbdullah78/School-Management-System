import { requireSupabase } from '@/lib/supabase'

/**
 * The published price list, for the one screen with no login behind it.
 *
 * WHY THE PRICES COME FROM THE DATABASE AND NOT FROM HERE. fn__plan_price is
 * not a lookup. It takes the cheaper of two answers (the laddered price for
 * the period, and the cheapest single standard term that covers it) and falls
 * back to the monthly rate when a plan's quarterly rate is zero. Working that
 * out in the browser would agree with the invoice until somebody changed one
 * of the nine rates, and then the signup form would quote a figure the first
 * invoice contradicts, on the screen where a school decides to buy.
 *
 * fn_signup_plans is granted to `anon` deliberately: it returns the published
 * price list and nothing else, and it is the only thing that decides which
 * plans a school may pick for itself. The by-arrangement plan is excluded
 * there rather than here, because a plan with no price has no student limit
 * either and offering it would be unlimited pupils for nothing.
 */
export interface SignupTerm {
  months: number
  amount: number
  /** Against paying monthly for the same time, in rupees. */
  saving: number
}

export interface SignupPlan {
  code: string
  name: string
  student_limit: number | null
  terms: SignupTerm[]
}

export async function listSignupPlans(): Promise<SignupPlan[]> {
  const sb = requireSupabase()
  const { data, error } = await sb.rpc('fn_signup_plans')
  if (error) throw new Error(error.message)
  return (data ?? []) as SignupPlan[]
}

/** "Monthly", "3 months", "A year": the three terms that are sold. */
export const TERM_LABEL: Record<number, string> = {
  1: 'Monthly',
  3: 'Every 3 months',
  12: 'Yearly',
}

/**
 * How a term reads inside a sentence, as opposed to on a button.
 *
 * Kept beside TERM_LABEL so the two cannot drift into saying different things
 * about the same number, and it copes with a term that is not one of the
 * three: an operator can invoice any number of months from 1 to 60, so a
 * school can legitimately be on a six-month term that no button represents.
 */
export function termSentence(months: number | null | undefined): string {
  if (months === 1) return 'every month'
  if (months === 3) return 'every three months'
  if (months === 12) return 'once a year'
  if (!months || months < 1) return 'by arrangement'
  return `every ${months} months`
}

/** The plan a roll of this size falls into, for the hint under the chooser. */
export function planForRoll(plans: SignupPlan[], roll: number): SignupPlan | null {
  const fits = plans.filter((p) => p.student_limit === null || p.student_limit >= roll)
  return fits[0] ?? null
}

/* ------------------------------------------------------- the second step --
   Everything below is the plan screen a school sees AFTER its account exists.

   WHY THE ACCOUNT EXISTS FIRST, which is the whole state-management answer for
   a two-step signup. The alternative is holding step one in the browser until
   step two is finished, and then a school that closes the tab between them has
   given us their details and got nothing, and we have their details and no
   account to attach them to. Storing that half-filled form anywhere means a
   public, unauthenticated write endpoint holding a stranger's email and
   telephone number, which is a spam target and a pile of personal data nobody
   consented to.

   So step one creates the school and signs them in. There is no partial state
   to reconcile because there is no partial state: a school that abandons step
   two is a real customer on a real fourteen-day trial, on the first plan on
   sale, who can change it from this same screen whenever they like. That is
   exactly what already happens today when the price list fails to load. */

export interface RegionList { regions: string[] }

/** The provinces and territories, from the database rather than from here.
 *  Two copies of seven strings is how a signup gets refused by a check
 *  constraint at the last step of a six-field form. */
export async function listRegions(): Promise<string[]> {
  const sb = requireSupabase()
  const { data, error } = await sb.rpc('fn_signup_regions')
  if (error) throw new Error(error.message)
  return (data ?? []) as string[]
}

export interface ChosenPlan {
  plan_code: string
  plan_name: string
  student_limit: number | null
  term_months: number
  status: string
  trial_ends_on: string | null
  amount: number
  what_next: string
}

/** Set my own school's plan and term. Raises no invoice and takes no money. */
export async function chooseMyPlan(
  planCode: string, termMonths: number,
): Promise<ChosenPlan> {
  const sb = requireSupabase()
  const { data, error } = await sb.rpc('fn_my_choose_plan', {
    p_plan_code: planCode, p_term_months: termMonths,
  })
  if (error) throw new Error(error.message)
  return data as ChosenPlan
}

export interface DiscountPreview {
  ok: boolean
  /** Present when ok is false. Already a sentence a school can act on. */
  reason?: string
  code?: string
  description?: string
  kind?: 'percent' | 'flat' | 'trial_days'
  value?: number
  duration?: 'once' | 'forever' | 'months' | 'until'
  list_amount?: number
  discount_amount?: number
  amount?: number
  trial_days?: number | null
  summary?: string
}

/**
 * What a code would do, without doing it.
 *
 * THE REFUSAL COMES BACK AS DATA, NOT AS A THROWN ERROR, and that is
 * deliberate. "That code expired on 03 Sep 2026" is an ordinary answer to an
 * ordinary question, not a failure: a red banner and a stack trace for somebody
 * who typed a code they were given is the wrong shape of feedback entirely.
 * Applying it later DOES throw, because by then it is a refusal to act.
 */
export async function previewDiscount(
  code: string, planCode: string, termMonths: number,
): Promise<DiscountPreview> {
  const sb = requireSupabase()
  const { data, error } = await sb.rpc('fn_preview_discount', {
    p_code: code, p_plan_code: planCode, p_term_months: termMonths,
  })
  if (error) throw new Error(error.message)
  return data as DiscountPreview
}

export interface AppliedDiscount {
  code: string
  summary: string
  trial_ends_on: string | null
  what_next: string
}

export async function applyDiscount(code: string): Promise<AppliedDiscount> {
  const sb = requireSupabase()
  const { data, error } = await sb.rpc('fn_my_apply_discount', { p_code: code })
  if (error) throw new Error(error.message)
  return data as AppliedDiscount
}

export interface MyDiscount {
  code: string
  description: string
  kind: 'percent' | 'flat' | 'trial_days'
  value: number
  duration: string
  ends_on: string | null
  uses_left: number | null
  times_applied: number
  total_saved: number
  summary: string
}

/** What my school is on, or null. */
export async function myDiscount(): Promise<MyDiscount | null> {
  const sb = requireSupabase()
  const { data, error } = await sb.rpc('fn_my_discount')
  if (error) throw new Error(error.message)
  return (data ?? null) as MyDiscount | null
}

export async function removeMyDiscount(): Promise<void> {
  const sb = requireSupabase()
  const { error } = await sb.rpc('fn_my_remove_discount')
  if (error) throw new Error(error.message)
}

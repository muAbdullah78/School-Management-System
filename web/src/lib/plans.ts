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

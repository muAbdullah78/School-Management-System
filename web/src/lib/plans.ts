import { requireSupabase } from '@/lib/supabase'

/**
 * The published price list, for the one screen with no login behind it.
 *
 * WHY THE PRICES COME FROM THE DATABASE AND NOT FROM HERE. The invoice is
 * priced by the database, and a second copy of nine figures in the browser
 * agrees with it only until somebody changes one of them. Then the signup form
 * quotes a figure the first invoice contradicts, on the screen where a school
 * decides to buy.
 *
 * THREE PLANS (0155). Starter covers up to 280 pupils, Growth up to 1,000, and
 * Enterprise is priced with each school by us. A school does not pick a plan:
 * it says how many pupils it has and the plan follows (planForStudents mirrors
 * the database's rule for the hint on the form; the database decides).
 * fn_signup_plans is granted to `anon` because it returns the price list and
 * nothing else.
 */
export interface SignupTerm {
  months: 1 | 3 | 12
  amount: number
  /** What a month works out at on this term. */
  per_month: number
  /** Against paying monthly for the same time, in rupees. */
  saving: number
}

export interface SignupPlan {
  code: string
  name: string
  /** The most pupils it covers; null for Enterprise, which has no limit. */
  student_limit: number | null
  /** The smallest roll it is offered to: 1, 281, 1,001. */
  min_students: number
  /** Enterprise: no list price, agreed with each school. */
  by_arrangement: boolean
  month_price: number | null
  /** Empty for Enterprise. */
  terms: SignupTerm[]
  /** Enterprise only: how its price is worked out once agreed. */
  how_priced: string | null
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
 * about the same number. One, three and twelve months are the only terms sold
 * or invoiced since 0155.
 */
export function termSentence(months: number | null | undefined): string {
  if (months === 1) return 'every month'
  if (months === 3) return 'every three months'
  if (months === 12) return 'once a year'
  return 'by arrangement'
}

/**
 * The plan a roll of this size belongs on: the one whose range holds it. The
 * same rule as fn__plan_for_students, for the hint beside the number on the
 * signup form; the database applies it again when the school is created.
 */
export function planForStudents(plans: SignupPlan[], students: number): SignupPlan | null {
  if (!Number.isFinite(students) || students < 1) return null
  const fits = plans
    .filter((p) => p.min_students <= students && (p.student_limit === null || p.student_limit >= students))
    .sort((a, b) => b.min_students - a.min_students)
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
   two is a real customer on a real fourteen-day trial, on the plan its number
   of pupils put it on, paying monthly until it chooses otherwise from this
   same screen or from Settings, Subscription. */

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

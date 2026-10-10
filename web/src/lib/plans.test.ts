import { describe, expect, it } from 'vitest'
import { TERM_LABEL, termSentence, planForStudents, type SignupPlan } from '@/lib/plans'

/* The shape fn_signup_plans returns since 0155. The figures are fixtures: the
   rule under test is which plan a roll belongs on, not what any plan costs. */
const PLANS: SignupPlan[] = [
  { code: 'starter', name: 'Starter', student_limit: 280, min_students: 1, by_arrangement: false,
    month_price: 2000, how_priced: null,
    terms: [{ months: 1, amount: 2000, per_month: 2000, saving: 0 },
            { months: 3, amount: 5400, per_month: 1800, saving: 600 },
            { months: 12, amount: 20000, per_month: 1667, saving: 4000 }] },
  { code: 'growth', name: 'Growth', student_limit: 1000, min_students: 281, by_arrangement: false,
    month_price: 4000, how_priced: null,
    terms: [{ months: 1, amount: 4000, per_month: 4000, saving: 0 },
            { months: 3, amount: 10800, per_month: 3600, saving: 1200 },
            { months: 12, amount: 40000, per_month: 3333, saving: 8000 }] },
  { code: 'enterprise', name: 'Enterprise', student_limit: null, min_students: 1001, by_arrangement: true,
    month_price: null, terms: [],
    how_priced: 'We agree a monthly price with you. Three months is 10% off it and a year is two months free.' },
]

/**
 * One, three or twelve months, and nothing else.
 *
 * Since 0155 those are the only terms sold OR invoiced: the operator's own
 * invoice is refused for any other number, so a six-month term cannot exist
 * any more and nothing has to be worded for one.
 */
describe('how a billing term reads', () => {
  it('names the three that are sold', () => {
    expect(TERM_LABEL[1]).toBe('Monthly')
    expect(TERM_LABEL[3]).toBe('Every 3 months')
    expect(TERM_LABEL[12]).toBe('Yearly')
  })

  it('says the three in a sentence, in the words a school uses', () => {
    expect(termSentence(1)).toBe('every month')
    expect(termSentence(3)).toBe('every three months')
    expect(termSentence(12)).toBe('once a year')
  })

  it('never renders an empty term', () => {
    // A school with no subscription, or one read before the query settles.
    // "Paid " with nothing after it is worse than a hedge.
    for (const v of [null, undefined, 0, -1, 6]) {
      expect(termSentence(v as number | null | undefined)).toBe('by arrangement')
    }
  })
})

/**
 * The roll decides the plan: 1 to 280 Starter, 281 to 1,000 Growth, more than
 * 1,000 Enterprise. The signup form shows this as the number is typed, so it
 * has to agree with fn__plan_for_students at every edge.
 */
describe('which plan a roll belongs on', () => {
  it('puts each roll on the plan whose range holds it, edges included', () => {
    expect(planForStudents(PLANS, 1)?.code).toBe('starter')
    expect(planForStudents(PLANS, 280)?.code).toBe('starter')
    expect(planForStudents(PLANS, 281)?.code).toBe('growth')
    expect(planForStudents(PLANS, 1000)?.code).toBe('growth')
    expect(planForStudents(PLANS, 1001)?.code).toBe('enterprise')
    expect(planForStudents(PLANS, 100000)?.code).toBe('enterprise')
  })

  it('gives Enterprise no price to show, only how it is priced', () => {
    const e = planForStudents(PLANS, 2500)!
    expect(e.by_arrangement).toBe(true)
    expect(e.terms).toEqual([])
    expect(e.month_price).toBeNull()
    expect(e.how_priced).toMatch(/agree a monthly price/i)
  })

  it('returns nothing for a number that is not a roll', () => {
    for (const n of [0, -5, Number.NaN, Number.POSITIVE_INFINITY]) {
      expect(planForStudents(PLANS, n)).toBeNull()
    }
  })

  it('returns nothing when there are no plans at all', () => {
    // The price list did not load. The form must still submit, and it can
    // only do that if "no plan" is an answer rather than a crash.
    expect(planForStudents([], 100)).toBeNull()
  })

  it('finds nothing in a price list from before the ranges existed', () => {
    // An older database sends plans with no min_students. Guessing from a
    // list like that would show a school a plan the database will not give it.
    const old = PLANS.map(({ min_students: _m, ...p }) => p) as unknown as SignupPlan[]
    expect(planForStudents(old, 100)).toBeNull()
  })
})

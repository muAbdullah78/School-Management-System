import { describe, expect, it } from 'vitest'
import { TERM_LABEL, termSentence, planForRoll, type SignupPlan } from '@/lib/plans'

const PLANS: SignupPlan[] = [
  { code: 'starter', name: 'Starter (up to 150 students)', student_limit: 150, terms: [] },
  { code: 'growth', name: 'Growth (151-350 students)', student_limit: 350, terms: [] },
  { code: 'institution', name: 'Institution (351-600 students)', student_limit: 600, terms: [] },
]

/**
 * The three terms are sold; any number of months can be invoiced.
 *
 * fn_choose_term sells 1, 3 and 12. fn_activate_subscription accepts 1 to 60
 * and, since migration 0127, records what it invoiced. So a school really can
 * be on a six-month term, and every surface that renders a term has to cope
 * with one rather than fall through to an empty string.
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

  it('copes with a term an operator invoiced that no button represents', () => {
    expect(termSentence(6)).toBe('every 6 months')
    expect(termSentence(24)).toBe('every 24 months')
  })

  it('never renders an empty term', () => {
    // A school with no subscription, or one read before the query settles.
    // "Paid " with nothing after it is worse than a hedge.
    for (const v of [null, undefined, 0, -1]) {
      expect(termSentence(v as number | null | undefined)).toBe('by arrangement')
    }
  })
})

describe('which plan a roll falls into', () => {
  it('picks the smallest plan that covers the roll', () => {
    expect(planForRoll(PLANS, 1)?.code).toBe('starter')
    expect(planForRoll(PLANS, 150)?.code).toBe('starter')
    // 151 is the first roll Starter does not cover, and the band in Growth's
    // own name says so.
    expect(planForRoll(PLANS, 151)?.code).toBe('growth')
    expect(planForRoll(PLANS, 350)?.code).toBe('growth')
    expect(planForRoll(PLANS, 351)?.code).toBe('institution')
    expect(planForRoll(PLANS, 600)?.code).toBe('institution')
  })

  it('returns nothing when no plan on sale covers the roll', () => {
    // 601 and up is priced in a conversation, and fn_signup_plans does not
    // offer it: a plan with no price has no student limit either, so a school
    // self-serving onto it would get unlimited pupils for nothing.
    expect(planForRoll(PLANS, 601)).toBeNull()
  })

  it('treats a plan with no limit as covering any roll', () => {
    const withCustom = [...PLANS,
      { code: 'custom', name: 'Custom', student_limit: null, terms: [] }]
    expect(planForRoll(withCustom, 5000)?.code).toBe('custom')
  })

  it('returns nothing when there are no plans at all', () => {
    expect(planForRoll([], 100)).toBeNull()
  })
})

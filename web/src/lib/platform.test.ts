import { describe, it, expect } from 'vitest'
import { actionNeeded, describeAction, sortByAction, type PlatformSchool } from './platform'

const base: PlatformSchool = {
  school_id: 's', school_name: 'A School', city: null, contact_name: null, contact_phone: null,
  plan_code: 'starter', status: 'active', expires_on: '2027-01-01', days_left: 300,
  student_count: 100, student_limit: 200, limit_state: 'ok',
  suggested_plan: 'starter', needs_upgrade: false,
  outstanding: 0, last_paid_on: null,
  suspended: false, suspend_reason: null, archived: false,
}
const s = (p: Partial<PlatformSchool>): PlatformSchool => ({ ...base, ...p })

describe('actionNeeded', () => {
  it('says nothing about a healthy paying school', () => {
    expect(actionNeeded(s({}))).toBeNull()
  })

  it('flags locked, grace and imminent renewals', () => {
    expect(actionNeeded(s({ status: 'locked' }))).toMatch(/chase payment/i)
    expect(actionNeeded(s({ status: 'grace', days_left: 3 }))).toMatch(/grace/i)
    expect(actionNeeded(s({ status: 'active', days_left: 5 }))).toMatch(/renewal due/i)
  })

  it('names the plan to move an over-limit school onto', () => {
    const msg = actionNeeded(s({ limit_state: 'over', needs_upgrade: true, suggested_plan: 'growth' }))
    expect(msg).toMatch(/growth/)
    // Phrased as a renewal-time change, never as something to enforce now:
    // the whole rule is that going over does not interrupt the school.
    expect(msg).toMatch(/at renewal/i)
  })

  it('stays quiet about a school inside its margin', () => {
    expect(actionNeeded(s({ limit_state: 'within_margin' }))).toBeNull()
  })

  it('names an unpaid invoice whatever the licence status is', () => {
    // A school can be comfortably active and still owe for the year it is
    // halfway through. Before `outstanding` existed the console could not tell
    // that school apart from one that had paid in full.
    expect(actionNeeded(s({ outstanding: 35000 }))).toMatch(/owes/i)
    expect(actionNeeded(s({ status: 'trialing', days_left: 12, outstanding: 9500 }))).toMatch(/owes/i)
  })

  it('does not say "owes" about a locked school. That message is chase payment', () => {
    // Two messages competing for one line. Locked is the stronger statement:
    // the school cannot use the software at all, which is what to lead with.
    expect(actionNeeded(s({ status: 'locked', outstanding: 9500 }))).toMatch(/chase payment/i)
  })

  it('does not nag about a trial that has just started', () => {
    expect(actionNeeded(s({ status: 'trialing', days_left: 12 }))).toBeNull()
    expect(actionNeeded(s({ status: 'trialing', days_left: 2 }))).toMatch(/call them/i)
  })
})

describe('sortByAction', () => {
  it('puts the work first: lost money before quiet schools', () => {
    const list = [
      s({ school_name: 'Healthy' }),
      s({ school_name: 'Locked', status: 'locked' }),
      s({ school_name: 'Trial', status: 'trialing', days_left: 10 }),
      s({ school_name: 'Grace', status: 'grace', days_left: 4 }),
      s({ school_name: 'Expiring', status: 'active', days_left: 3 }),
    ]
    expect(sortByAction(list).map((x) => x.school_name))
      .toEqual(['Locked', 'Grace', 'Expiring', 'Trial', 'Healthy'])
  })

  it('ranks an unpaid invoice above an over-limit school', () => {
    // One is a debt, the other is a conversation.
    const list = [
      s({ school_name: 'OverLimit', limit_state: 'over', needs_upgrade: true }),
      s({ school_name: 'Owes', outstanding: 20000 }),
    ]
    expect(sortByAction(list).map((x) => x.school_name)).toEqual(['Owes', 'OverLimit'])
  })

  it('breaks ties by urgency, then name', () => {
    const list = [
      s({ school_name: 'Later', status: 'active', days_left: 7 }),
      s({ school_name: 'Sooner', status: 'active', days_left: 1 }),
    ]
    expect(sortByAction(list).map((x) => x.school_name)).toEqual(['Sooner', 'Later'])
  })
})

/**
 * The six heaviest things anybody can do to a customer fell through to
 * describeAction's default and rendered as their own slug with the reason
 * thrown away.
 *
 * The History dialog's whole stated purpose is "who chose it, and the reason
 * somebody typed at the time". 0079 calls the cancellation reason "the only
 * churn data this business will ever have" and then nothing ever showed it. A
 * school could be suspended, cancelled, archived and finally have its records
 * destroyed, and the history read:
 *
 *     school suspended
 *     subscription cancelled
 *     school archived
 *     school purged
 *
 * Four slugs, no reasons, no amounts, and nothing to distinguish the last one -
 * which cannot be undone - from the first.
 */
describe('describeAction: the actions that used to say nothing', () => {
  const a = (action: string, detail: Record<string, unknown> = {}) =>
    describeAction({ action, at: '2026-09-06T00:00:00Z', actor_email: 'op@vendor.test', detail } as never)

  it('shows why a school was cancelled, and what it cost them', () => {
    const out = a('subscription_cancelled', {
      reason: 'Moved to a competitor on price',
      outstanding_at_cancellation: 38000,
      paid_until: '2027-06-30', days_given_up: 297,
    })
    expect(out).toContain('Moved to a competitor on price')
    expect(out).toContain('38,000')
    expect(out).toContain('297')
    expect(out).not.toBe('subscription cancelled')
  })

  it('shows the sentence the school itself is being shown', () => {
    const out = a('school_suspended', { reason: 'Three months unpaid and not answering' })
    expect(out).toContain('Three months unpaid and not answering')
    expect(out).toContain('shown this')
  })

  it('marks the one entry that cannot be undone', () => {
    const out = a('school_purged', { reason: 'Closed down, data retention expired', rows: 41233 })
    expect(out).toContain('DESTROYED')
    expect(out).toContain('Closed down, data retention expired')
  })

  it('says what a grace period changed from and to', () => {
    expect(a('grace_changed', { days: 30, standard: 14, reason: 'Their accountant is slow' }))
      .toContain('30')
    expect(a('grace_changed', { days: null, standard: 14 })).toContain('standard 14')
  })

  it('reads an archive and an unarchive back', () => {
    expect(a('school_archived', { reason: 'Left in August', outstanding: 5000 }))
      .toContain('Left in August')
    expect(a('school_unarchived', { was_reason: 'Left in August' }))
      .toContain('Left in August')
  })

  it('reports a reinstatement by where it actually landed', () => {
    // The honest half: reinstating a school whose dates ran out puts it back
    // as locked, and the feed has to say locked rather than reinstated.
    expect(a('subscription_reinstated', { effective_status: 'locked' })).toContain('locked')
    expect(a('subscription_reinstated', { effective_status: 'active' })).toContain('active')
  })

  it('still falls back to the slug for something nobody has taught it yet', () => {
    expect(a('some_future_action')).toBe('some future action')
  })
})

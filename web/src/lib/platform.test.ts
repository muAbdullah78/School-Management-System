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
    // A locked school that owes NOTHING is a renewal to sell, not a debt to
    // chase. This used to read "chase payment or reactivate" either way, which
    // is advice to phone a principal about money they do not owe.
    expect(actionNeeded(s({ status: 'locked' }))).toMatch(/renew them/i)
    expect(actionNeeded(s({ status: 'grace', days_left: 3 }))).toMatch(/grace/i)
    expect(actionNeeded(s({ status: 'active', days_left: 5 }))).toMatch(/renewal due/i)
  })

  it('never tells the operator to chase a school we switched off ourselves', () => {
    // fn_effective_status returns 'locked' for a manual suspension exactly as
    // it does for an expired licence, so a school WE suspended arrived here
    // indistinguishable from one that had not paid, and got "chase payment".
    // The reason we suspended them is two fields away.
    const msg = actionNeeded(s({
      status: 'locked', suspended: true, outstanding: 40000,
      suspend_reason: 'Three months unpaid and not answering',
    }))
    expect(msg).toMatch(/we suspended them/i)
    expect(msg).toContain('Three months unpaid and not answering')
    expect(msg).not.toMatch(/chase/i)
  })

  it('says nothing at all about an archived school', () => {
    // A departed customer is off the renewal worklist by design. Telling the
    // operator to chase them is how last year's churn gets worked as this
    // year's pipeline.
    expect(actionNeeded(s({ archived: true, status: 'cancelled', outstanding: 12000 })))
      .toBeNull()
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

  it('puts the locked school\'s debt on the same line as the lock', () => {
    // Two facts competing for one line, and the old version dropped one of
    // them: "Locked: chase payment or reactivate" never said how much, so the
    // operator had to open the school to find out whether this was a phone call
    // about Rs 9,500 or about nothing at all.
    const msg = actionNeeded(s({ status: 'locked', outstanding: 9500 }))
    expect(msg).toMatch(/locked/i)
    expect(msg).toContain('9,500')
    expect(msg).toMatch(/chase the payment/i)
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
      s({ school_name: 'LockedOwing', status: 'locked', outstanding: 38000 }),
      s({ school_name: 'LockedClear', status: 'locked' }),
      s({ school_name: 'Trial', status: 'trialing', days_left: 10 }),
      s({ school_name: 'Grace', status: 'grace', days_left: 4 }),
      s({ school_name: 'Expiring', status: 'active', days_left: 3 }),
    ]
    // Locked WITH an invoice is the first call of the day. Locked with nothing
    // owed is a renewal to sell, so it drops below the two deadlines.
    expect(sortByAction(list).map((x) => x.school_name))
      .toEqual(['LockedOwing', 'Grace', 'Expiring', 'LockedClear', 'Trial', 'Healthy'])
  })

  it('sinks archived, cancelled and suspended below the live worklist', () => {
    // ALL THREE USED TO RANK 0, the very top. Archiving sets the subscription
    // to 'cancelled' and this ranking tested that status first, so a customer
    // filed away last year sorted above a trial ending tomorrow. A suspension
    // reports as 'locked', so a school we switched off ourselves sorted above
    // every school that actually owed us money.
    const list = [
      s({ school_name: 'Archived', archived: true, status: 'cancelled' }),
      s({ school_name: 'Cancelled', status: 'cancelled' }),
      s({ school_name: 'Suspended', status: 'locked', suspended: true,
          suspend_reason: 'not answering' }),
      s({ school_name: 'Owing', outstanding: 38000 }),
      s({ school_name: 'Trial', status: 'trialing', days_left: 10 }),
    ]
    expect(sortByAction(list).map((x) => x.school_name))
      .toEqual(['Owing', 'Trial', 'Suspended', 'Cancelled', 'Archived'])
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

import { describe, it, expect } from 'vitest'
import { actionNeeded, sortByAction, type PlatformSchool } from './platform'

const base: PlatformSchool = {
  school_id: 's', school_name: 'A School', city: null, contact_name: null, contact_phone: null,
  plan_code: 'starter', status: 'active', expires_on: '2027-01-01', days_left: 300,
  student_count: 100, student_limit: 200, limit_state: 'ok',
  suggested_plan: 'starter', needs_upgrade: false,
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
    // Phrased as a renewal-time change, never as something to enforce now —
    // the whole rule is that going over does not interrupt the school.
    expect(msg).toMatch(/at renewal/i)
  })

  it('stays quiet about a school inside its margin', () => {
    expect(actionNeeded(s({ limit_state: 'within_margin' }))).toBeNull()
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

  it('breaks ties by urgency, then name', () => {
    const list = [
      s({ school_name: 'Later', status: 'active', days_left: 7 }),
      s({ school_name: 'Sooner', status: 'active', days_left: 1 }),
    ]
    expect(sortByAction(list).map((x) => x.school_name)).toEqual(['Sooner', 'Later'])
  })
})

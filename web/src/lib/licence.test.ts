import { describe, it, expect } from 'vitest'
import { expiryMessage, expiryUrgency, formatPkr, limitBanner, type Licence } from './licence'

const base: Licence = {
  ok: true,
  school_id: 's1',
  status: 'active',
  locked: false,
  can_read: true,
  can_export: true,
  can_operate: true,
  plan_code: 'starter',
  plan_name: 'Starter',
  cycle: 'yearly',
  price_monthly: 3500,
  price_yearly: 35000,
  expires_on: '2026-12-31',
  days_left: 200,
  student_count: 150,
  student_limit: 200,
  margin_limit: 220,
  limit_state: 'ok',
  limit_notice: null,
}
const lic = (p: Partial<Licence>): Licence => ({ ...base, ...p })

describe('expiryUrgency', () => {
  it('stays silent when a subscription is comfortably in date', () => {
    expect(expiryUrgency(lic({ status: 'active', days_left: 200 }))).toBe('none')
    expect(expiryUrgency(lic({ status: 'active', days_left: 30 }))).toBe('none')
  })

  it('escalates as the end approaches', () => {
    expect(expiryUrgency(lic({ status: 'active', days_left: 7 }))).toBe('warn')
    expect(expiryUrgency(lic({ status: 'active', days_left: 3 }))).toBe('critical')
  })

  it('treats grace as critical. The app stops accepting entries at the end of it', () => {
    expect(expiryUrgency(lic({ status: 'grace', days_left: 10 }))).toBe('critical')
  })

  it('treats a trial as informational until it gets close', () => {
    expect(expiryUrgency(lic({ status: 'trialing', days_left: 14 }))).toBe('info')
    expect(expiryUrgency(lic({ status: 'trialing', days_left: 2 }))).toBe('critical')
  })
})

describe('expiryMessage', () => {
  it('says nothing to an active school with plenty of time', () => {
    expect(expiryMessage(lic({ status: 'active', days_left: 60 }))).toBeNull()
  })

  it('uses singular wording on the last day', () => {
    expect(expiryMessage(lic({ status: 'trialing', days_left: 1 }))).toBe('Last day of your free trial.')
    expect(expiryMessage(lic({ status: 'active', days_left: 1 }))).toBe('Your subscription ends tomorrow.')
  })

  it('tells a school in grace exactly what runs out and when', () => {
    expect(expiryMessage(lic({ status: 'grace', days_left: 5 })))
      .toBe('Your subscription has ended. You have 5 days left before the app stops accepting entries.')
  })

  it('never implies data is withheld', () => {
    for (const status of ['trialing', 'grace', 'locked', 'cancelled'] as const) {
      const m = expiryMessage(lic({ status, days_left: 0 })) ?? ''
      expect(m).not.toMatch(/delet|lost|remov|lock(ed)? out|forfeit/i)
    }
  })
})

describe('formatPkr', () => {
  it('formats whole rupees', () => {
    expect(formatPkr(35000)).toBe('Rs 35,000')
    expect(formatPkr(3500)).toBe('Rs 3,500')
  })
})

describe('limitBanner', () => {
  // The bug this function was extracted for. limit_state is 'ok' while the
  // count is at or BELOW the limit, so gating on `limit_state !== 'ok'` hid the
  // warning for the entire band that matters: the 90% run-up, AND the exact
  // moment the roll is full and the next admission is refused.
  it('speaks when the school is exactly on its limit, where limit_state is still ok', () => {
    const l = lic({
      student_count: 200, student_limit: 200,
      limit_state: 'ok', at_limit: true,
      limit_notice: 'Your roll is full: 200 pupils, and your plan covers 200.',
    })
    expect(limitBanner(l, 'owner')?.text).toContain('roll is full')
    expect(limitBanner(l, 'owner')?.atLimit).toBe(true)
  })

  it('speaks through the 90% run-up, and quietly', () => {
    const l = lic({
      student_count: 182, student_limit: 200,
      limit_state: 'ok', at_limit: false, warn_limit: true,
      limit_notice: '182 of the 200 pupils your plan covers.',
    })
    expect(limitBanner(l, 'principal')?.text).toContain('182 of the 200')
    // Grey, not amber. Nothing is refused yet and a wall-coloured warning that
    // turns out to be nothing is how a school learns to ignore the strip.
    expect(limitBanner(l, 'principal')?.atLimit).toBe(false)
  })

  it('says nothing at all when the server sent no notice', () => {
    expect(limitBanner(lic({ limit_notice: null }), 'owner')).toBeNull()
    // Not even when the state says over. The server decides WHEN, and a screen
    // that invents a sentence from limit_state is a second implementation of a
    // rule that already exists in fn_my_licence.
    expect(limitBanner(lic({ limit_state: 'over', limit_notice: null }), 'owner')).toBeNull()
  })

  it('gives the clerk their own wording and never the leadership one', () => {
    const l = lic({
      limit_notice: 'Ask us for more room from Settings then Subscription.',
      limit_notice_staff: 'The roll is full. Ask the owner or principal.',
      at_limit: true,
    })
    // A clerk cannot open Settings, Subscription, so being sent there is worse
    // than being told nothing: they go looking and find a locked door.
    expect(limitBanner(l, 'admin_clerk')?.text).toBe('The roll is full. Ask the owner or principal.')
    expect(limitBanner(l, 'owner')?.text).toContain('Settings then Subscription')
  })

  it('tells nobody who does not admit pupils', () => {
    const l = lic({ limit_notice: 'x', limit_notice_staff: 'y', at_limit: true })
    for (const role of ['teacher', 'accountant', 'readonly', 'parent', undefined, null]) {
      expect(limitBanner(l, role)).toBeNull()
    }
  })

  it('does not paint a wall on a database that has not had 0128 applied', () => {
    // at_limit absent, which is every database before the migration. The old
    // limit_state is the fallback, so an over-limit school is still amber and a
    // within-margin one is still grey.
    const over = lic({ limit_state: 'over', limit_notice: 'over', at_limit: undefined })
    const near = lic({ limit_state: 'within_margin', limit_notice: 'near', at_limit: undefined })
    expect(limitBanner(over, 'owner')?.atLimit).toBe(true)
    expect(limitBanner(near, 'owner')?.atLimit).toBe(false)
  })

  // A clerk with no staff wording, which is what an app running against a
  // pre-0128 database sees. Telling them the leadership sentence instead would
  // be a regression to the behaviour the old comment warned about.
  it('falls silent for a clerk rather than borrowing the leadership sentence', () => {
    const l = lic({ limit_notice: 'Ask us from Settings', limit_notice_staff: undefined })
    expect(limitBanner(l, 'admin_clerk')).toBeNull()
  })
})

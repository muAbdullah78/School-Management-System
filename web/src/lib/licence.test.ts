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
  margin_limit: 200,
  limit_state: 'ok',
  limit_notice: null,
}
const lic = (p: Partial<Licence>): Licence => ({ ...base, ...p })

const TODAY = '2026-10-10'

describe('expiryUrgency', () => {
  it('stays silent when a paid school is comfortably in date', () => {
    expect(expiryUrgency(lic({ status: 'active', days_left: 200 }), TODAY)).toBe('none')
    expect(expiryUrgency(lic({ status: 'active', days_left: 30 }), TODAY)).toBe('none')
  })

  it('treats a payment coming due as news, because fourteen days of grace follow it', () => {
    // The due date changes nothing under 0155: the school keeps working for
    // the grace period after it. Red on that day would be shouting about a
    // day that stops nothing.
    expect(expiryUrgency(lic({ status: 'active', days_left: 7, pay_now: 2000 }), TODAY)).toBe('info')
    expect(expiryUrgency(lic({ status: 'active', days_left: 1, pay_now: 2000 }), TODAY)).toBe('info')
  })

  it('says nothing about a payment the school has already covered', () => {
    expect(expiryUrgency(lic({ status: 'active', days_left: 3, pay_now: 0 }), TODAY)).toBe('none')
  })

  it('gets louder through grace as the pause comes closer', () => {
    expect(expiryUrgency(lic({ status: 'grace', locks_on: '2026-10-20' }), TODAY)).toBe('warn')
    expect(expiryUrgency(lic({ status: 'grace', locks_on: '2026-10-13' }), TODAY)).toBe('critical')
  })

  it('treats an ordinary trial as information, with grace still to come after it', () => {
    expect(expiryUrgency(lic({ status: 'trialing', days_left: 13 }), TODAY)).toBe('info')
    expect(expiryUrgency(lic({ status: 'trialing', days_left: 2 }), TODAY)).toBe('warn')
  })

  it('escalates an unpriced Enterprise trial like a lock, because it is one', () => {
    const e = (d: number) => lic({ status: 'trialing', days_left: d, needs_price: true, by_arrangement: true })
    expect(expiryUrgency(e(13), TODAY)).toBe('info')
    expect(expiryUrgency(e(6), TODAY)).toBe('warn')
    expect(expiryUrgency(e(2), TODAY)).toBe('critical')
  })

  it('treats a paid school with an overdue charge like grace', () => {
    // We moved it up a plan mid-period and the difference is due: the lock
    // date comes before the paid period ends.
    const l = lic({ status: 'active', days_left: 9, paid_through: '2026-12-31', locks_on: '2026-10-20', pay_now: 1500 })
    expect(expiryUrgency(l, TODAY)).toBe('warn')
  })

  it('is critical once new entries are paused, whatever the reason', () => {
    expect(expiryUrgency(lic({ status: 'locked', locked: true }), TODAY)).toBe('critical')
    expect(expiryUrgency(lic({ status: 'cancelled', locked: true }), TODAY)).toBe('critical')
  })
})

describe('expiryMessage', () => {
  it('says nothing to a paid school with plenty of time', () => {
    expect(expiryMessage(lic({ status: 'active', days_left: 60 }), TODAY)).toBeNull()
  })

  it('counts the trial in days of access, today included', () => {
    // Signup day of a fourteen-day trial: the last day is thirteen days away.
    expect(expiryMessage(lic({ status: 'trialing', days_left: 13 }), TODAY)).toBe('14 days left in your free trial.')
    expect(expiryMessage(lic({ status: 'trialing', days_left: 1 }), TODAY)).toBe('2 days left in your free trial.')
    expect(expiryMessage(lic({ status: 'trialing', days_left: 0 }), TODAY)).toBe('Today is the last day of your free trial.')
  })

  it('tells an Enterprise school with no price that its trial end is the lock', () => {
    const m = expiryMessage(lic({ status: 'trialing', days_left: 9, needs_price: true }), TODAY) ?? ''
    expect(m).toMatch(/^10 days left in your free trial\./)
    expect(m).toMatch(/not agreed your price/)
    expect(m).toMatch(/paused when the trial ends until we do/)
  })

  it('tells a school in grace how many days are left to pay, from locks_on', () => {
    expect(expiryMessage(lic({ status: 'grace', paid_through: null, locks_on: '2026-10-15' }), TODAY))
      .toBe('Your free trial has ended. 5 days left to pay before new entries are paused.')
    expect(expiryMessage(lic({ status: 'grace', paid_through: '2026-10-01', locks_on: '2026-10-11' }), TODAY))
      .toBe('Your paid period has ended. Today is the last day to pay before new entries are paused.')
  })

  it('counts from days_left when a database sends no lock date', () => {
    // An older fn_my_licence: the last working day is days_left away.
    expect(expiryMessage(lic({ status: 'grace', days_left: 4, locks_on: undefined }), TODAY))
      .toBe('Your free trial has ended. 5 days left to pay before new entries are paused.')
  })

  it('tells a paid school when its next payment is due', () => {
    // Due on the first day of the next period, the day after days_left.
    expect(expiryMessage(lic({ status: 'active', days_left: 5, pay_now: 2000 }), TODAY))
      .toBe('Your next payment is due in 6 days.')
    expect(expiryMessage(lic({ status: 'active', days_left: 0, pay_now: 2000 }), TODAY))
      .toBe('Your next payment is due tomorrow.')
    expect(expiryMessage(lic({ status: 'active', days_left: 5, pay_now: 0 }), TODAY)).toBeNull()
  })

  it('tells a paid school with an overdue charge how long it has', () => {
    const l = lic({ status: 'active', days_left: 9, paid_through: '2026-12-31', locks_on: '2026-10-20', pay_now: 1500 })
    expect(expiryMessage(l, TODAY)).toBe('A payment is due. 10 days left to pay before new entries are paused.')
  })

  it('says why a locked school is paused', () => {
    expect(expiryMessage(lic({ status: 'locked', locked_because: 'needs_price' }), TODAY)).toMatch(/price is not agreed/)
    expect(expiryMessage(lic({ status: 'locked', locked_because: 'unpaid' }), TODAY)).toMatch(/payment is overdue/)
    expect(expiryMessage(lic({ status: 'locked', locked_because: 'expired', paid_through: null }), TODAY))
      .toMatch(/free trial has ended/)
  })

  it('never implies data is withheld', () => {
    for (const status of ['trialing', 'grace', 'locked', 'cancelled'] as const) {
      const m = expiryMessage(lic({ status, days_left: 0, needs_price: status === 'trialing' }), TODAY) ?? ''
      expect(m).not.toMatch(/delet|lost|remov|lock(ed)? out|forfeit/i)
    }
  })

  it('never names a price, because it is shown to everybody', () => {
    const cases = [
      lic({ status: 'trialing', days_left: 3, pay_now: 2000 }),
      lic({ status: 'active', days_left: 3, pay_now: 2000 }),
      lic({ status: 'grace', locks_on: '2026-10-15', pay_now: 2000 }),
    ]
    for (const l of cases) expect(expiryMessage(l, TODAY) ?? '').not.toMatch(/Rs\s?\d/)
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
    // at_limit absent, which is every database before the migration. The
    // limit_state is the fallback, so an over-limit school is still amber and
    // one that is only near its limit is still grey.
    const over = lic({ limit_state: 'over', limit_notice: 'over', at_limit: undefined })
    const near = lic({ limit_state: 'ok', limit_notice: 'near', at_limit: undefined })
    expect(limitBanner(over, 'owner')?.atLimit).toBe(true)
    expect(limitBanner(near, 'owner')?.atLimit).toBe(false)
  })

  it('tells the owner when the extra room we gave ends', () => {
    const l = lic({
      student_count: 300, student_limit: 320, plan_student_limit: 280,
      limit_notice: '300 of the 320 pupils your plan covers.', warn_limit: true, at_limit: false,
      extra_until: '2026-11-30',
    })
    expect(limitBanner(l, 'owner')?.text).toMatch(/extra room we gave you ends on 30 Nov 2026/)
    // Not the clerk: there is nothing they can do about the date.
    expect(limitBanner({ ...l, limit_notice_staff: 'Ask the owner.' }, 'admin_clerk')?.text).toBe('Ask the owner.')
  })

  it('says what follows the extra room when the roll only fits because of it', () => {
    // The dashboard read "300 of the 320 pupils your plan covers ... The extra
    // room we gave you ends on 31 Oct 2026" and stopped there, as if nothing
    // followed. What follows is a roll over its plan and admissions refused.
    const l = lic({
      student_count: 300, student_limit: 320, plan_student_limit: 280,
      limit_notice: '300 of the 320 pupils your plan covers.', warn_limit: true, at_limit: false,
      extra_until: '2026-10-31',
    })
    expect(limitBanner(l, 'owner')?.text).toBe('300 of the 320 pupils your plan covers. The extra room we gave '
      + 'you ends on 31 Oct 2026. After that your plan covers 280, fewer than the 300 on your roll, so ask us before then.')
  })

  it('speaks up for a school that only fits because of extra room, even with no notice', () => {
    const l = lic({
      student_count: 300, student_limit: 400, plan_student_limit: 280,
      limit_notice: null, extra_until: '2026-11-30',
    })
    const t = limitBanner(l, 'principal')?.text ?? ''
    expect(t).toMatch(/You have 300 pupils and your plan covers 280/)
    expect(t).toMatch(/ends on 30 Nov 2026/)
    // And quiet when the room is not being leant on.
    expect(limitBanner(lic({ ...l, student_count: 200 }), 'principal')).toBeNull()
  })

  it('never talks about a margin, because there is none', () => {
    const l = lic({
      student_count: 280, student_limit: 280, at_limit: true,
      limit_notice: 'Your roll is full: 280 pupils, and your plan covers 280.',
      extra_until: '2026-11-30',
    })
    expect(limitBanner(l, 'owner')?.text).not.toMatch(/margin|10%|extra 10/i)
  })

  // A clerk with no staff wording, which is what an app running against a
  // pre-0128 database sees. Telling them the leadership sentence instead would
  // be a regression to the behaviour the old comment warned about.
  it('falls silent for a clerk rather than borrowing the leadership sentence', () => {
    const l = lic({ limit_notice: 'Ask us from Settings', limit_notice_staff: undefined })
    expect(limitBanner(l, 'admin_clerk')).toBeNull()
  })
})

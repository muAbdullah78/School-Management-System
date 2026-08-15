import { describe, it, expect } from 'vitest'
import { expiryMessage, expiryUrgency, formatPkr, type Licence } from './licence'

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

  it('treats grace as critical — the app stops accepting entries at the end of it', () => {
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

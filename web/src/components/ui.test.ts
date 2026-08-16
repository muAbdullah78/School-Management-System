import { describe, expect, it } from 'vitest'
import { balanceTone, money } from './ui'

/**
 * Colour carries meaning in this app, so the mapping is worth pinning down.
 * If someone "tidies" balanceTone so that a credit renders amber, a parent who
 * has paid ahead starts looking like a defaulter on every screen at once.
 */
describe('balanceTone', () => {
  it('shows money owed as due (amber)', () => {
    expect(balanceTone(1)).toBe('due')
    expect(balanceTone(25_000)).toBe('due')
  })

  it('shows a settled balance as money (emerald)', () => {
    expect(balanceTone(0)).toBe('money')
  })

  it('shows a credit as info (sky), never as owed', () => {
    expect(balanceTone(-1)).toBe('info')
    expect(balanceTone(-5_000)).toBe('info')
  })
})

describe('money', () => {
  it('is the single formatter, re-exported from lib/format', () => {
    expect(money(1200)).toBe('Rs 1,200')
    expect(money(0)).toBe('Rs 0')
  })

  it('treats a missing figure as zero rather than rendering NaN', () => {
    expect(money(null)).toBe('Rs 0')
    expect(money(undefined)).toBe('Rs 0')
  })

  it('does not bill in paisa', () => {
    expect(money(1200.4)).toBe('Rs 1,200')
  })
})

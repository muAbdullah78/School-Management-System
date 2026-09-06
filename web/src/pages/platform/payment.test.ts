import { describe, it, expect, afterEach, vi } from 'vitest'
import { money, whyNot } from './PlatformPage'

/**
 * A disabled button that does not say why is a broken screen.
 *
 * The Record button on the operator's payment dialog was gated on
 * `Number.isFinite(Number(amount))`, and Pakistani figures are written with
 * commas. So pasting "38,000" straight off a bank statement - the single most
 * likely thing an operator does on that screen - greyed out the only button on
 * the dialog, with no message anywhere. The screen looked fine. It just did
 * nothing, forever, until somebody guessed.
 */
afterEach(() => vi.useRealTimers())

const ok = (amount: string, tax = '', paidOn = '2026-09-06') =>
  whyNot(amount, money(amount), tax, tax.trim() === '' ? 0 : money(tax), paidOn)

describe('money()', () => {
  it('reads a figure written the way a bank statement writes it', () => {
    expect(money('38,000')).toBe(38000)
    expect(money('1,250,000.50')).toBe(1250000.5)
    expect(money(' 38000 ')).toBe(38000)
    expect(money('Rs 38,000')).toBe(38000)
    expect(money('rs.38,000')).toBe(38000)
  })

  it('still refuses something that is not a figure at all', () => {
    expect(money('')).toBeNaN()
    expect(money('thirty eight thousand')).toBeNaN()
    expect(money('38,00o')).toBeNaN()   // a typed letter o for a zero
  })
})

describe('whyNot(): the reason the Record button is dead', () => {
  it('lets an ordinary payment through', () => {
    vi.useFakeTimers(); vi.setSystemTime(new Date('2026-09-06T07:00:00.000Z'))
    expect(ok('38,000')).toBeNull()
    expect(ok('34960', '3040')).toBeNull()
  })

  it('names the text it could not read rather than going quiet', () => {
    vi.useFakeTimers(); vi.setSystemTime(new Date('2026-09-06T07:00:00.000Z'))
    const why = ok('thirty eight thousand')
    expect(why).toContain('thirty eight thousand')
    expect(why).toMatch(/not an amount/i)
  })

  it('asks for an amount before it complains about one', () => {
    vi.useFakeTimers(); vi.setSystemTime(new Date('2026-09-06T07:00:00.000Z'))
    expect(ok('')).toMatch(/enter the amount/i)
  })

  it('refuses zero and negatives, and says where a reversal belongs', () => {
    vi.useFakeTimers(); vi.setSystemTime(new Date('2026-09-06T07:00:00.000Z'))
    expect(ok('0')).toMatch(/more than zero/i)
    expect(ok('-5000')).toMatch(/credit or void/i)
  })

  it('refuses a future date, which neither the input nor the database did', () => {
    // `max` on an <input type="date"> is enforced by native FORM validation and
    // there is no form on that dialog, so a typed date went straight through.
    // fn_platform_record_payment has no future check either: a payment dated
    // next March would have landed in the books and turned up in the wrong
    // month's revenue.
    vi.useFakeTimers(); vi.setSystemTime(new Date('2026-09-06T07:00:00.000Z'))
    expect(ok('38000', '', '2027-03-01')).toMatch(/in the future/i)
    expect(ok('38000', '', '2026-09-06')).toBeNull()
    expect(ok('38000', '', '2026-09-05')).toBeNull()
  })

  it('reckons "the future" in Pakistan, not in UTC', () => {
    // 02:00 on the 6th in Karachi. `new Date().toISOString().slice(0, 10)` -
    // which is what this screen used - says the 5th, so an operator
    // reconciling the bank after midnight was refused today's date.
    vi.useFakeTimers(); vi.setSystemTime(new Date('2026-09-05T21:00:00.000Z'))
    expect(new Date().toISOString().slice(0, 10)).toBe('2026-09-05')
    expect(ok('38000', '', '2026-09-06')).toBeNull()
  })

  it('refuses tax that is not a figure', () => {
    vi.useFakeTimers(); vi.setSystemTime(new Date('2026-09-06T07:00:00.000Z'))
    expect(ok('38000', 'three thousand')).toMatch(/not an amount/i)
    expect(ok('38000', '3,040')).toBeNull()
  })
})

import { describe, it, expect, afterEach, vi } from 'vitest'
import { today, monthStart, daysAgo, daysFromNow, monthsAgoStart, ymd } from './dates'

/**
 * These tests exist because fourteen screens were quietly wrong and none of
 * them looked wrong.
 *
 * Every assertion below is paired with the recipe it replaced, computed inline,
 * so the test does not merely say "this is the answer" - it says what the old
 * code returned instead and why anybody would have believed it. Both bugs
 * produced a plausible date, which is exactly why they survived.
 *
 * Nothing here depends on the machine's own timezone: dates.ts pins Asia/Karachi
 * explicitly, so this suite gives the same result on a UTC build runner and on a
 * laptop in Lahore. The old code did not, which is the other half of the defect.
 */
afterEach(() => vi.useRealTimers())

/** 02:00 in Karachi on 6 September 2026. In UTC it is still the 5th. */
const KARACHI_2AM = new Date('2026-09-05T21:00:00.000Z')
/** Midday in Karachi on the same day, when nothing is ambiguous. */
const KARACHI_NOON = new Date('2026-09-06T07:00:00.000Z')

describe('today()', () => {
  it('names the Pakistani day, not the UTC one, in the small hours', () => {
    vi.useFakeTimers()
    vi.setSystemTime(KARACHI_2AM)

    // What every screen used to do.
    expect(new Date().toISOString().slice(0, 10)).toBe('2026-09-05')
    // What the day actually is where the school is.
    expect(today()).toBe('2026-09-06')
  })

  it('agrees with the old recipe during the day, which is why nobody noticed', () => {
    vi.useFakeTimers()
    vi.setSystemTime(KARACHI_NOON)
    expect(today()).toBe('2026-09-06')
    expect(new Date().toISOString().slice(0, 10)).toBe('2026-09-06')
  })
})

describe('monthStart()', () => {
  it('is the first of the month, and the old recipe never was', () => {
    vi.useFakeTimers()
    vi.setSystemTime(KARACHI_NOON)

    // The recipe from AccountsPage and MessagesPage was
    //
    //     new Date(d.getFullYear(), d.getMonth(), 1).toISOString().slice(0, 10)
    //
    // which builds LOCAL midnight on the 1st and then converts it to UTC. On a
    // machine in Pakistan that midnight is 7pm on the LAST DAY OF THE MONTH
    // BEFORE. Wrong at every hour of every day rather than only at night, and
    // it silently pulled the previous month's last day into every "this month"
    // total on the Accounts screen.
    //
    // It cannot be reproduced by calling the old expression here, because that
    // would depend on the test runner's own timezone and CI runs in UTC - which
    // is precisely why nothing caught it. So the +05:00 instant it produced is
    // named directly.
    const karachiLocalMidnightOnTheFirst = new Date('2026-09-01T00:00:00.000+05:00')
    expect(karachiLocalMidnightOnTheFirst.toISOString().slice(0, 10)).toBe('2026-08-31')

    expect(monthStart()).toBe('2026-09-01')
  })

  it('is still the first when the UTC clock says last month', () => {
    vi.useFakeTimers()
    // 01:00 on 1 October in Karachi. In UTC it is 30 September.
    vi.setSystemTime(new Date('2026-09-30T20:00:00.000Z'))
    expect(today()).toBe('2026-10-01')
    expect(monthStart()).toBe('2026-10-01')
    // The pair that used to break: a range whose end came from today() and
    // whose start came from a correct month start produced from > to, and an
    // empty report with no error on it.
    expect(monthStart() <= today()).toBe(true)
  })
})

describe('counting days', () => {
  it('goes back a whole number of days in Pakistan', () => {
    vi.useFakeTimers()
    vi.setSystemTime(KARACHI_2AM)
    expect(daysAgo(0)).toBe('2026-09-06')
    expect(daysAgo(7)).toBe('2026-08-30')
    expect(daysAgo(90)).toBe('2026-06-08')
  })

  it('goes forward for a follow-up date set in the evening', () => {
    vi.useFakeTimers()
    // 9pm in Karachi. In UTC it is already 4pm the same day, but the old
    // enquiry code did the arithmetic and THEN went through toISOString.
    vi.setSystemTime(new Date('2026-09-06T16:00:00.000Z'))
    expect(today()).toBe('2026-09-06')
    expect(daysFromNow(3)).toBe('2026-09-09')
    expect(daysFromNow(0)).toBe(today())
  })
})

describe('monthsAgoStart()', () => {
  it('walks back whole months', () => {
    vi.useFakeTimers()
    vi.setSystemTime(KARACHI_NOON)
    expect(monthsAgoStart(0)).toBe('2026-09-01')
    expect(monthsAgoStart(2)).toBe('2026-07-01')
  })

  it('crosses the year boundary, which is where off-by-one months hide', () => {
    vi.useFakeTimers()
    vi.setSystemTime(new Date('2026-01-15T07:00:00.000Z'))
    expect(monthsAgoStart(2)).toBe('2025-11-01')
    expect(monthsAgoStart(1)).toBe('2025-12-01')
    expect(monthsAgoStart(13)).toBe('2024-12-01')
  })
})

describe('ymd()', () => {
  it('formats a given instant, always zero padded', () => {
    expect(ymd(new Date('2026-03-01T06:00:00.000Z'))).toBe('2026-03-01')
    // 03:00 UTC on the 1st is 08:00 in Karachi, still the 1st.
    expect(ymd(new Date('2026-03-01T03:00:00.000Z'))).toBe('2026-03-01')
    // 20:00 UTC on the 1st is 01:00 on the 2nd in Karachi.
    expect(ymd(new Date('2026-03-01T20:00:00.000Z'))).toBe('2026-03-02')
  })
})

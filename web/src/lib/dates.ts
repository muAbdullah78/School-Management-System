/**
 * Today, in the timezone the database reckons a school day in.
 *
 * WHY THIS FILE EXISTS.
 *
 * Fourteen screens derived a calendar date with some spelling of
 *
 *     new Date().toISOString().slice(0, 10)
 *
 * which is not today. It is today IN UTC, and Pakistan is UTC+5. Between
 * midnight and 5am in Karachi it names yesterday, so an operator recording a
 * payment at half past midnight got yesterday's date pre-filled AND a date
 * picker whose `max` refused to let them pick the real today.
 *
 * The month version was worse, and wrong at every hour of every day:
 *
 *     new Date(d.getFullYear(), d.getMonth(), 1).toISOString().slice(0, 10)
 *
 * builds LOCAL midnight on the 1st, then converts it to UTC, which is 7pm on
 * the LAST DAY OF THE PREVIOUS MONTH. Every screen defaulting to "this month"
 * has been quietly starting its range one day early since it was written, so
 * every "this month" total on Accounts and every message count carried the 31st
 * of the month before. Nobody would ever report that: the number looks like a
 * number.
 *
 * ASIA/KARACHI RATHER THAN THE DEVICE'S OWN TIMEZONE.
 *
 * The database is the authority on what day it is - 0107 made the staff
 * attendance rule reckon in Asia/Karachi explicitly, and the attendance and fee
 * rules follow it - so the browser has to agree with the database, not with
 * whatever the laptop's clock is set to. A school office machine with the
 * timezone left on the factory default is common enough that "local" is not a
 * safe synonym for "Pakistan" here.
 *
 * en-CA is not a typo. It is the locale whose short date format is exactly
 * YYYY-MM-DD, which is what Postgres wants and what every <input type="date">
 * wants, so no reassembly is needed and no zero-padding can be forgotten.
 */
export const SCHOOL_TZ = 'Asia/Karachi'

const YMD = new Intl.DateTimeFormat('en-CA', {
  timeZone: SCHOOL_TZ, year: 'numeric', month: '2-digit', day: '2-digit',
})

/** A given instant as a YYYY-MM-DD date in Pakistan. Defaults to now. */
export function ymd(at: Date = new Date()): string {
  return YMD.format(at)
}

/** Today in Pakistan, as YYYY-MM-DD. */
export function today(): string {
  return ymd()
}

/** The first of the current month in Pakistan, as YYYY-MM-DD. */
export function monthStart(): string {
  return `${today().slice(0, 7)}-01`
}

/**
 * A whole number of days before today in Pakistan, as YYYY-MM-DD.
 *
 * Counted by subtracting from the UTC instant and re-reading the result in
 * Karachi, which is exact because Pakistan has had no daylight saving since
 * 2009 and no plans to bring it back. If that ever changes this is the one
 * function to fix.
 */
export function daysAgo(n: number): string {
  return ymd(new Date(Date.now() - n * 86400000))
}

/** The first of the month n months back, as YYYY-MM-DD. */
export function monthsAgoStart(n: number): string {
  const [y, m] = today().split('-').map(Number)
  const total = y * 12 + (m - 1) - n
  return `${String(Math.floor(total / 12)).padStart(4, '0')}-${String((total % 12) + 1).padStart(2, '0')}-01`
}

/**
 * A filename-safe stamp of the current instant, for downloads.
 *
 * Deliberately still UTC, and deliberately not this file's business otherwise:
 * a backup file is stamped with an instant, not with a school day, and two
 * exports taken a minute apart must sort correctly whoever downloaded them.
 */
export function fileStamp(): string {
  return new Date().toISOString()
}

/** A whole number of days AFTER today in Pakistan, as YYYY-MM-DD. */
export function daysFromNow(n: number): string {
  return daysAgo(-n)
}

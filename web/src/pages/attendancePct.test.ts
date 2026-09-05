/**
 * The one attendance rule, pinned.
 *
 * This product computed the same percentage three different ways and a school
 * could see three different numbers for the same child on the same day. The two
 * that were wrong were the two most seen: the owner's dashboard, and the figure
 * shown to a PARENT.
 *
 * The rule is: present + late + half of a half day, over marked days. It lives
 * in the database as fn__attendance_pct (0097); this is the dashboard's copy,
 * which exists only because that tile is handed counts rather than a
 * percentage. supabase/tests/attendance_rule.sql asserts the surfaces agree.
 */
import { describe, expect, it } from 'vitest'
import { attendancePct } from './Dashboard'

const at = (present: number, late: number, half_day: number, marked: number) =>
  attendancePct({ present, late, half_day, marked })

describe('the attendance percentage', () => {
  it('is null when nothing is marked, not zero', () => {
    // Zero would read as "nobody came in", which is a different and far more
    // alarming claim than "the register has not been taken".
    expect(at(0, 0, 0, 0)).toBeNull()
  })

  it('counts a child who arrived LATE as having come in', () => {
    // The old dashboard dropped late entirely, so a class that all arrived late
    // showed as nobody having attended.
    expect(at(0, 10, 0, 10)).toBe(100)
  })

  it('counts a half day as HALF a day, not a whole one', () => {
    // The old dashboard and the parent portal both counted it whole, which
    // always flattered the figure.
    expect(at(0, 0, 10, 10)).toBe(50)
  })

  it('counts absent as absent', () => {
    expect(at(5, 0, 0, 10)).toBe(50)
  })

  it('treats approved leave the same way the result card does', () => {
    // A leave day is a marked day and is not in the numerator, so it lowers the
    // percentage. That is what fn_attendance_summary, the teacher portal and the
    // printed result card have always done. The point is that the dashboard
    // agrees with them rather than inventing a fourth answer.
    expect(at(9, 0, 0, 10)).toBe(90)
  })

  it('matches the worked example from the database function', () => {
    // fn__attendance_pct(8, 1, 2, 12) = 83.3, rounded to whole here because the
    // tile has no room for a decimal.
    expect(at(8, 1, 2, 12)).toBe(83)
  })
})

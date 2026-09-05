// @vitest-environment jsdom
import { describe, it, expect, afterEach, vi } from 'vitest'
import { render, screen, cleanup } from '@testing-library/react'
import { ResultCardPrint } from './ResultCardPrint'
import type { ResultCardRow, ResultCardFrozen } from '@/lib/db'

// The component reads the school's name and logo from hooks that talk to
// Supabase. Neither is what these tests are about, and a real client is not
// available here.
vi.mock('@/hooks/useSchoolName', () => ({ useSchoolName: () => 'Register School' }))
vi.mock('@/hooks/useSchoolLogo', () => ({ useSchoolLogo: () => null }))

/**
 * The attendance line on a card that goes home.
 *
 * A day marked `Leave` counts against the percentage in the same way as
 * absence, and that stays: the figure has to answer "how much of the year was
 * this child here" to carry the 75% rule that decides who may sit the board
 * exams. What was wrong is that the card printed 60% and nothing else, so a
 * school that had APPROVED five days of leave sent home a card reading as
 * though the child had not turned up, and the clerk at the counter had nothing
 * printed to settle it with.
 *
 * Two cases, and the second is the one that breaks on upgrade if nobody writes
 * it down: a reprint of an older card has a frozen snapshot with no attendance
 * counts in it at all, and must render exactly as it always did rather than
 * printing "undefined present of undefined days".
 */
function frozen(p: Partial<ResultCardFrozen> = {}): ResultCardFrozen {
  return {
    subjects: [],
    total_marks: 0,
    total_max: 0,
    percentage: 60,
    grade: 'C',
    position: 3,
    attendance_pct: 60,
    withheld: false,
    balance: 0,
    ...p,
  }
}

// Spelled out in full and NOT cast. `as ResultCardRow` on an object with a
// field the interface does not have is how a fixture stops describing the real
// row: the first draft of this file said `student_name` where the row says
// `full_name`, and a cast would have hidden that.
function card(f: ResultCardFrozen): ResultCardRow {
  return {
    id: 'rc1',
    enrollment_id: 'e1',
    student_id: 's1',
    full_name: 'Leave Child',
    gr_no: 'GR-2',
    roll_no: '2',
    total_marks: 0,
    total_max: 0,
    percentage: 60,
    grade: 'C',
    position: 3,
    attendance_pct: 60,
    version: 1,
    frozen: f,
    published_at: null,
  }
}

const props = {
  termName: 'Final',
  className: 'Class 4',
  sectionName: 'A',
  onClose: () => {},
}

describe('ResultCardPrint attendance', () => {
  afterEach(cleanup)

  it('accounts for the leave the school approved, and says what the percentage counts', () => {
    render(<ResultCardPrint card={card(frozen({
      attendance: {
        present: 6, absent: 1, leave: 3, late: 0,
        half_day: 0, marked_days: 10, present_pct: 60,
      },
    }))} {...props} />)

    // The percentage is unchanged: it counts every day the school was open.
    // getAllByText, not getByText: the card prints 60% twice, once as the
    // overall percentage and once as attendance, and they coincide in this
    // fixture. Asserting on a count here would be asserting on the layout.
    expect(screen.getAllByText('60%').length).toBeGreaterThan(0)
    // And the days behind it are printed, so nobody has to take the number on
    // trust.
    expect(screen.getByText(/6 present of 10 days marked/)).toBeTruthy()
    expect(screen.getByText(/3 days were leave/)).toBeTruthy()
    expect(screen.getByText(/counts every day the school was open/)).toBeTruthy()
  })

  it('says "day was" for a single day, because a card goes home to a parent', () => {
    render(<ResultCardPrint card={card(frozen({
      attendance: {
        present: 9, absent: 0, leave: 1, late: 0,
        half_day: 0, marked_days: 10, present_pct: 90,
      },
    }))} {...props} />)
    expect(screen.getByText(/1 day was leave/)).toBeTruthy()
  })

  it('prints nothing extra when there was no leave to account for', () => {
    render(<ResultCardPrint card={card(frozen({
      attendance: {
        present: 9, absent: 1, leave: 0, late: 0,
        half_day: 0, marked_days: 10, present_pct: 90,
      },
    }))} {...props} />)
    expect(screen.queryByText(/days marked, of which/)).toBeNull()
    expect(screen.queryByText(/counts every day the school was open/)).toBeNull()
  })

  it('reprints an older card, whose frozen snapshot has no counts at all', () => {
    // THE UPGRADE CASE. Every optional field on ResultCardFrozen exists because
    // a card generated before it was added must still reprint, and this is the
    // one that would have printed "undefined present of undefined days marked"
    // on last term's cards.
    render(<ResultCardPrint card={card(frozen())} {...props} />)
    expect(screen.getAllByText('60%').length).toBeGreaterThan(0)
    expect(screen.queryByText(/days marked, of which/)).toBeNull()
    expect(screen.queryByText(/undefined/)).toBeNull()
  })
})

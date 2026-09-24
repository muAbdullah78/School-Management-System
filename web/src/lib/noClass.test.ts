import { describe, expect, it } from 'vitest'
import { diagnoseNoClass } from './noClass'
import type { StudentWithoutAClass } from './db'

const row = (last_session: string | null, i = 0): StudentWithoutAClass => ({
  student_id: `s${i}-${last_session}`, full_name: 'X', gr_no: null, father_name: null,
  admission_date: null, last_class: last_session ? 'Class 1' : null, last_session,
})

describe('why children are on no class list', () => {
  it('names the session a skipped rollover left them in', () => {
    const rows = [row('2025-2026', 1), row('2025-2026', 2), row('2024-2025', 3), row(null, 4)]
    expect(diagnoseNoClass(rows, '2026-2027')).toEqual({
      total: 4, leftBehind: 3, fromSession: '2025-2026', neverEnrolled: 1, endedThisSession: 0,
    })
  })
  it('does not blame the rollover for a place ended this session', () => {
    const d = diagnoseNoClass([row('2026-2027', 1), row('2026-2027', 2)], '2026-2027')
    expect(d.leftBehind).toBe(0)
    expect(d.endedThisSession).toBe(2)
    expect(d.fromSession).toBeNull()
  })
  it('an empty list is an empty diagnosis', () => {
    expect(diagnoseNoClass([], '2026-2027')).toEqual({
      total: 0, leftBehind: 0, fromSession: null, neverEnrolled: 0, endedThisSession: 0,
    })
  })
})

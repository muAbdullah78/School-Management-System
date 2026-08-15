import { describe, it, expect } from 'vitest'
import {
  upsertPending, removePending, countMarks, attendanceKey, isNetworkError,
  ownedBy, notOwnedBy,
  type PendingAttendance,
} from './offlineQueue'

const mk = (key: string, n: number, school?: string): PendingAttendance => ({
  key, date: '2026-08-02', label: key,
  marks: Array.from({ length: n }, (_, i) => ({ enrollment_id: `${key}-${i}`, status: 'present' })),
  queued_at: '2026-08-02T00:00:00Z',
  school_id: school,
})

describe('upsertPending', () => {
  it('appends a new key', () => {
    expect(upsertPending([mk('a', 1)], mk('b', 1)).map((e) => e.key)).toEqual(['a', 'b'])
  })
  it('replaces an existing key rather than duplicating', () => {
    const out = upsertPending([mk('a', 1), mk('b', 1)], mk('a', 5))
    expect(out.map((e) => e.key)).toEqual(['b', 'a'])
    expect(out.find((e) => e.key === 'a')!.marks).toHaveLength(5)
  })
})

describe('removePending', () => {
  it('drops the matching key', () => {
    expect(removePending([mk('a', 1), mk('b', 1)], 'a').map((e) => e.key)).toEqual(['b'])
  })
})

describe('countMarks', () => {
  it('sums marks across batches', () => {
    expect(countMarks([mk('a', 3), mk('b', 2)])).toBe(5)
  })
})

describe('attendanceKey', () => {
  it('is stable per date/class/section and handles a null section', () => {
    expect(attendanceKey('2026-08-02', 'c1', 's1')).toBe('2026-08-02|c1|s1')
    expect(attendanceKey('2026-08-02', 'c1', null)).toBe('2026-08-02|c1|none')
  })
})

describe('queue ownership', () => {
  // The office PC is shared and the queue outlives a logout. A batch queued by
  // one school carries enrolment ids the next school cannot use — the server
  // rejects them — so it must be discarded, not retried forever.
  it('keeps only the signed-in school’s batches', () => {
    const list = [mk('a', 1, 'school-1'), mk('b', 1, 'school-2'), mk('c', 1, 'school-1')]
    expect(ownedBy(list, 'school-1').map((e) => e.key)).toEqual(['a', 'c'])
    expect(notOwnedBy(list, 'school-1').map((e) => e.key)).toEqual(['b'])
  })

  it('treats an unstamped batch as foreign rather than guessing', () => {
    const list = [mk('legacy', 1, undefined), mk('mine', 1, 'school-1')]
    expect(ownedBy(list, 'school-1').map((e) => e.key)).toEqual(['mine'])
    expect(notOwnedBy(list, 'school-1').map((e) => e.key)).toEqual(['legacy'])
  })
})

describe('isNetworkError', () => {
  it('treats fetch TypeErrors as network errors', () => {
    expect(isNetworkError(new TypeError('Failed to fetch'))).toBe(true)
  })
  it('treats network-ish messages as network errors', () => {
    expect(isNetworkError(new Error('NetworkError when attempting to fetch resource'))).toBe(true)
  })
  it('does not treat a normal server error as a network error', () => {
    expect(isNetworkError(new Error('duplicate key value violates unique constraint'))).toBe(false)
  })
})

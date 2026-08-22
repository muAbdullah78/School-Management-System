import { describe, it, expect } from 'vitest'
import { compareCells } from './DataTable'

describe('compareCells', () => {
  // The null rule is the one worth pinning down: a blank cell is missing data,
  // not the smallest value. Sorting defaulters by "who owes most" is useless if
  // the students with no balance recorded push the real debtors off the screen.
  it('sorts nulls last, whichever direction you ask for', () => {
    expect(compareCells(null, 5, 'asc')).toBeGreaterThan(0)
    expect(compareCells(null, 5, 'desc')).toBeGreaterThan(0)
    expect(compareCells(5, null, 'asc')).toBeLessThan(0)
    expect(compareCells(5, null, 'desc')).toBeLessThan(0)
  })

  it('treats undefined the same as null', () => {
    expect(compareCells(undefined, 1, 'asc')).toBeGreaterThan(0)
    expect(compareCells(undefined, undefined, 'asc')).toBe(0)
  })

  it('compares numbers numerically, not as text', () => {
    // The classic bug: "100" < "9" as strings.
    expect(compareCells(100, 9, 'asc')).toBeGreaterThan(0)
    expect(compareCells(100, 9, 'desc')).toBeLessThan(0)
  })

  it('compares text with numeric awareness so Class 10 follows Class 9', () => {
    expect(compareCells('Class 9', 'Class 10', 'asc')).toBeLessThan(0)
    expect(compareCells('Roll 2', 'Roll 12', 'asc')).toBeLessThan(0)
  })

  it('reverses for desc', () => {
    expect(compareCells('a', 'b', 'asc')).toBeLessThan(0)
    expect(compareCells('a', 'b', 'desc')).toBeGreaterThan(0)
  })

  it('is a usable Array.sort comparator, nulls at the end', () => {
    const rows: (number | null)[] = [500, null, 1200, 0, null, 75]
    expect([...rows].sort((a, b) => compareCells(a, b, 'desc'))).toEqual([
      1200, 500, 75, 0, null, null,
    ])
  })
})

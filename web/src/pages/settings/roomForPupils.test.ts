import { describe, it, expect } from 'vitest'
import { roundUpRoom } from './RoomForPupils'

/**
 * The number the request box starts with.
 *
 * It matters more than it looks. A school that has to invent a figure invents
 * the smallest one that solves today, gets it, and is back asking again a month
 * later, which costs both sides a second round trip. So the box opens on the
 * next round number above the limit.
 */
describe('roundUpRoom', () => {
  it('offers the next fifty under five hundred', () => {
    expect(roundUpRoom(150)).toBe(200)
    expect(roundUpRoom(120)).toBe(150)
    expect(roundUpRoom(3)).toBe(50)
  })

  it('offers the next hundred above it, because 650 is not a number anybody asks for', () => {
    expect(roundUpRoom(600)).toBe(700)
    expect(roundUpRoom(500)).toBe(600)
    expect(roundUpRoom(1200)).toBe(1300)
  })

  // The property that actually matters, and the one a plain
  // `Math.round(limit / 50) * 50` gets wrong: the suggestion must be MORE than
  // the limit, or the request is refused by the database for asking for what
  // they already have.
  it('is always more than the limit, at every value either side of a step', () => {
    for (const n of [1, 49, 50, 51, 99, 100, 149, 199, 200, 499, 500, 501, 999, 1000]) {
      expect(roundUpRoom(n), `roundUpRoom(${n})`).toBeGreaterThan(n)
    }
  })
})

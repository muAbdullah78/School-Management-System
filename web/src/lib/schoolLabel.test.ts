import { describe, expect, it } from 'vitest'
import { clusters, schoolLabel } from './schoolLabel'

describe('clusters', () => {
  it('keeps a surrogate pair together', () => {
    // Two code units, one grapheme. Array.from already handles this; the test
    // exists so a future "optimisation" back to split('') is caught.
    expect(clusters('🏫')).toEqual(['🏫'])
  })

  it('keeps a base letter and its combining mark together where the engine can', () => {
    const parts = clusters('école')
    // Intl.Segmenter gives 5; the code-point fallback gives 6. Both are
    // acceptable, an index-based split giving a broken first character is not.
    expect(parts.length).toBeLessThanOrEqual(6)
    expect(parts[0]).not.toBe('é'.slice(0, 1) + '')
    expect(parts.join('')).toBe('école')
  })
})

describe('schoolLabel', () => {
  it('shows the fallback for an empty or whitespace field', () => {
    expect(schoolLabel('', 'Your school').text).toBe('Your school')
    expect(schoolLabel('   ', 'Your school').text).toBe('Your school')
  })

  it('trims but does not otherwise alter a short name', () => {
    expect(schoolLabel('  Iqra Model School  ', 'Your school').text).toBe('Iqra Model School')
  })

  it('truncates on the cluster budget and marks it with one ellipsis', () => {
    const long = 'Government Girls Higher Secondary School Sahiwal'
    const out = schoolLabel(long, 'Your school', 26)
    expect(out.text.endsWith('…')).toBe(true)
    expect(clusters(out.text).length).toBe(27) // 26 plus the ellipsis
    expect(long.startsWith(out.text.slice(0, -1))).toBe(true)
  })

  it('never cuts through a surrogate pair', () => {
    const name = '🏫'.repeat(10)
    const out = schoolLabel(name, 'x', 4)
    // The replacement character is what a slice(0, n) on the string produces.
    expect(out.text).not.toContain('�')
    expect(out.text).toBe('🏫🏫🏫🏫…')
  })

  it('flags Arabic script and drops the tracking that destroys its joins', () => {
    const out = schoolLabel('اقرا ماڈل ہائی اسکول', 'Your school')
    expect(out.rtl).toBe(true)
    expect(out.style.letterSpacing).toBe('normal')
    expect(out.style.fontFamily).toContain('Nastaliq')
  })

  it('leaves a Latin name in the interface font with its own tracking', () => {
    const out = schoolLabel('Iqra Model School', 'Your school')
    expect(out.rtl).toBe(false)
    expect(out.style.fontFamily).toBeUndefined()
  })

  it('steps the size down by length rather than fitting continuously', () => {
    // 11, 19 and 28 clusters: one name per step of the ladder. A name past the
    // budget always lands on the smallest step, which is why c is measured at
    // 28 rather than at 48: both are the same step, and asserting otherwise
    // would be asserting a ladder with more rungs than it has.
    const a = schoolLabel('Iqra School', 'x').size
    const b = schoolLabel('Government Girls HS', 'x').size
    const c = schoolLabel('Government Girls High School', 'x').size
    expect(a).toBeGreaterThan(b)
    expect(b).toBeGreaterThan(c)
    // Steps: adding one character must not usually change the size.
    expect(schoolLabel('Iqra School', 'x').size).toBe(schoolLabel('Iqra Schooll', 'x').size)
  })

  it('measures the budget against the fallback too, so a long fallback cannot overflow', () => {
    const out = schoolLabel('', 'A very long placeholder that nobody would choose', 10)
    expect(clusters(out.text).length).toBe(11)
  })
})

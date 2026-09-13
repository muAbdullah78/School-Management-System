import { describe, expect, it } from 'vitest'
import {
  FIT_MAX_LINES, capacity, clusters, fitSchoolName, schoolLabel,
} from './schoolLabel'

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

describe('fitSchoolName', () => {
  // The real box, and it is the mobile drawer's rather than the desktop
  // sidebar's: the drawer is narrower once its close button is taken off.
  // The arithmetic is in AppShell beside NAME_BOX_PX.
  const BOX = 142

  it('leaves an ordinary name at full size, whole and on one line', () => {
    const f = fitSchoolName('Iqra Model School', 'Your school', BOX)
    expect(f.text).toBe('Iqra Model School')
    expect(f.size).toBe(14)
    expect(f.lines).toBe(1)
    expect(f.clipped).toBe(false)
  })

  it('shows the whole of the long names this market actually has', () => {
    // Every one of these was truncated by the old `truncate` at roughly twenty
    // characters, on the school's own name, in the school's own software.
    for (const name of [
      'Beaconhouse School System',
      'The City School Gulberg Campus',
      'Government Girls Higher Secondary School Chaklala',
      'Allama Iqbal Public Higher Secondary School Rawalpindi Cantt',
    ]) {
      const f = fitSchoolName(name, 'Your school', BOX)
      expect(f.text, name).toBe(name)
      expect(f.clipped, name).toBe(false)
      expect(f.lines, name).toBeLessThanOrEqual(FIT_MAX_LINES)
    }
  })

  it('steps down rather than cutting: a longer name gets a smaller size', () => {
    const short = fitSchoolName('City School', 'Your school', BOX)
    const long = fitSchoolName(
      'Allama Iqbal Public Higher Secondary School Rawalpindi Cantt', 'Your school', BOX)
    expect(long.size).toBeLessThan(short.size)
  })

  it('picks a step the name genuinely fits in', () => {
    // The property the whole ladder exists for. Whatever step is chosen, the
    // name has to fit the box at that size on that many lines. A ramp of sizes
    // picked by eye passes the examples above and fails this.
    for (let n = 1; n <= 200; n++) {
      const f = fitSchoolName('x'.repeat(n), 'Your school', BOX)
      expect(clusters(f.text).length, `${n} clusters`)
        .toBeLessThanOrEqual(capacity(BOX, f.size, f.lines))
    }
  })

  it('never needs more lines than the caller clamps at', () => {
    for (let n = 1; n <= 200; n++) {
      expect(fitSchoolName('y'.repeat(n), 'Your school', BOX).lines)
        .toBeLessThanOrEqual(FIT_MAX_LINES)
    }
  })

  it('cuts only what is not a school name, and says so when it does', () => {
    const absurd = 'A'.repeat(400)
    const f = fitSchoolName(absurd, 'Your school', BOX)
    expect(f.clipped).toBe(true)
    expect(f.text.endsWith('…')).toBe(true)
    // clipped is what tells the sidebar a tooltip is load bearing rather than
    // decorative, so it must never be true for a name that was shown in full.
    expect(fitSchoolName('Iqra Model School', 'Your school', BOX).clipped).toBe(false)
  })

  it('falls back while the field is empty', () => {
    expect(fitSchoolName('', 'Your school', BOX).text).toBe('Your school')
    expect(fitSchoolName('   ', 'Your school', BOX).text).toBe('Your school')
  })

  it('hands an Urdu name to the browser to shape, with no tracking on it', () => {
    const f = fitSchoolName('گورنمنٹ ہائی اسکول راولپنڈی', 'Your school', BOX)
    expect(f.rtl).toBe(true)
    expect(f.style.letterSpacing).toBe('normal')
    expect(f.style.fontFamily).toContain('Nastaliq')
  })

  it('never cuts through a surrogate pair', () => {
    const f = fitSchoolName('🏫'.repeat(300), 'Your school', BOX)
    expect(f.text).not.toContain('�')
    // Every code point but the ellipsis is a whole school. Spreading a string
    // iterates code points rather than UTF-16 units, so a pair cut down the
    // middle shows up here as a lone surrogate and not as a shorter string.
    expect([...f.text.replace('…', '')].every((c) => c === '🏫')).toBe(true)
  })

  it('gives a wider box more room before it steps down', () => {
    const name = 'Government Girls Higher Secondary School Chaklala'
    expect(fitSchoolName(name, 'Your school', 300).size)
      .toBeGreaterThanOrEqual(fitSchoolName(name, 'Your school', BOX).size)
  })
})

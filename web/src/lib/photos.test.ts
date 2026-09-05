/**
 * The pure parts of the photograph layer.
 *
 * downscale() and the upload paths need a browser and a Supabase project, so
 * they are covered by supabase/tests/photos.sql on the server side and by the
 * manual checklist for the storage API. What IS testable here is every piece of
 * logic that decides what the user sees when something is missing, which is
 * the case that will actually occur, in every school, for most pupils, for a
 * long time.
 */
import { describe, it, expect } from 'vitest'
import { initials, avatarTone, ACCEPTED_TYPES, MAX_UPLOAD_BYTES } from './photos'

describe('initials', () => {
  it('takes the first and last name, which is how a register reads', () => {
    expect(initials('Muhammad Ali Khan')).toBe('MK')
    expect(initials('Ayesha Siddiqui')).toBe('AS')
  })

  it('handles a single name, common on Pakistani records', () => {
    expect(initials('Bilal')).toBe('BI')
  })

  it('never renders empty, because an empty avatar looks like a broken image', () => {
    expect(initials('')).toBe('?')
    expect(initials(null)).toBe('?')
    expect(initials(undefined)).toBe('?')
    expect(initials('   ')).toBe('?')
  })

  it('survives the double spaces that come out of a pasted spreadsheet', () => {
    expect(initials('Muhammad   Ali')).toBe('MA')
    expect(initials('  Zainab  Ahmed  ')).toBe('ZA')
  })

  it('does not crash on a name that is one character', () => {
    expect(initials('A')).toBe('A')
  })
})

describe('avatarTone', () => {
  it('gives the same person the same colour every time. The whole point, since a\n'
     + 'colour that changed on each render would make a photo-less list unscannable', () => {
    expect(avatarTone('Muhammad Ali')).toBe(avatarTone('Muhammad Ali'))
  })

  it('returns a real class for a missing name rather than undefined', () => {
    expect(avatarTone(null)).toMatch(/^bg-/)
    expect(avatarTone('')).toMatch(/^bg-/)
  })

  it('spreads different names across more than one tone', () => {
    const tones = new Set(
      ['Ali', 'Bilal', 'Sara', 'Zainab', 'Hassan', 'Fatima', 'Usman', 'Ayesha']
        .map(avatarTone))
    expect(tones.size).toBeGreaterThan(1)
  })
})

describe('the limits agree with the bucket', () => {
  // If these drift from migration 0057 the browser accepts a file the server
  // then rejects, which reads to a clerk as "the upload is broken".
  it('accepts exactly the three types the bucket allows', () => {
    expect(ACCEPTED_TYPES).toEqual(['image/jpeg', 'image/png', 'image/webp'])
  })

  it('caps at 2 MB, the bucket file_size_limit', () => {
    expect(MAX_UPLOAD_BYTES).toBe(2097152)
  })

  it('does not accept a PDF or an SVG', () => {
    // SVG is deliberate: it can carry script, and it would be served from the
    // same origin as the app.
    expect(ACCEPTED_TYPES).not.toContain('application/pdf')
    expect(ACCEPTED_TYPES).not.toContain('image/svg+xml')
  })
})

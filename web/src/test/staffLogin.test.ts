// @vitest-environment node
/**
 * The staff-login credential suggestion, which mirrors the parent-portal
 * generator: a first-name-plus-number address, lowercased, spaces and special
 * characters stripped. A wrong sanitisation here produces an address the auth
 * service rejects AFTER the office thinks the teacher can sign in.
 */
import { describe, expect, it } from 'vitest'
import { suggestStaffEmail } from '@/pages/staff/StaffPage'

describe('suggestStaffEmail', () => {
  it('builds firstname + digits @gmail.com, lowercased and stripped', () => {
    expect(suggestStaffEmail('Khuda Bakhsh', '0332 232 3454')).toBe('khuda03322323454@gmail.com')
  })
  it('uses only the first word of the name', () => {
    expect(suggestStaffEmail('Madam Ayesha Khan', '03001234567')).toBe('madam03001234567@gmail.com')
  })
  it('strips special characters from the name', () => {
    expect(suggestStaffEmail("M.d'Souza", '0300-1234567')).toBe('mdsouza03001234567@gmail.com')
  })
  it('returns empty when the number is missing, so the office must type one', () => {
    expect(suggestStaffEmail('Ali', null)).toBe('')
    expect(suggestStaffEmail('Ali', '')).toBe('')
  })
  it('returns empty when the name has no usable letters', () => {
    expect(suggestStaffEmail('!!!', '03001234567')).toBe('')
  })
})

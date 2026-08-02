import { describe, it, expect } from 'vitest'
import { fmtPKR, fmtDate, monthToDate, todayISO, waLink } from './format'

const digits = (s: string) => s.replace(/\D/g, '')

describe('fmtPKR', () => {
  it('treats null/undefined as zero', () => {
    expect(fmtPKR(null)).toBe('Rs 0')
    expect(fmtPKR(undefined)).toBe('Rs 0')
    expect(fmtPKR(0)).toBe('Rs 0')
  })
  it('prefixes Rs and keeps the integer digits (grouping is locale-defined)', () => {
    const out = fmtPKR(1234)
    expect(out.startsWith('Rs ')).toBe(true)
    expect(digits(out)).toBe('1234')
  })
  it('rounds away decimals', () => {
    expect(digits(fmtPKR(99.9))).toBe('100')
  })
})

describe('fmtDate', () => {
  it('renders an em dash for empty/invalid input', () => {
    expect(fmtDate(null)).toBe('—')
    expect(fmtDate(undefined)).toBe('—')
    expect(fmtDate('')).toBe('—')
    expect(fmtDate('not-a-date')).toBe('—')
  })
  it('renders a real date containing the year', () => {
    const out = fmtDate('2025-08-02')
    expect(out).not.toBe('—')
    expect(out).toContain('2025')
  })
})

describe('monthToDate', () => {
  it('turns YYYY-MM into the first of the month', () => {
    expect(monthToDate('2025-08')).toBe('2025-08-01')
  })
  it('passes through anything that is not YYYY-MM', () => {
    expect(monthToDate('2025-8')).toBe('2025-8')
    expect(monthToDate('garbage')).toBe('garbage')
  })
})

describe('todayISO', () => {
  it('is a YYYY-MM-DD string', () => {
    expect(todayISO()).toMatch(/^\d{4}-\d{2}-\d{2}$/)
  })
})

describe('waLink', () => {
  it('returns null when there is no usable number', () => {
    expect(waLink(null)).toBeNull()
    expect(waLink(undefined)).toBeNull()
    expect(waLink('')).toBeNull()
    expect(waLink('abc')).toBeNull()
    expect(waLink('123')).toBeNull() // too short
  })
  it('normalises a local 03xx number to the 92 country code', () => {
    expect(waLink('0300 1234567')).toBe('https://wa.me/923001234567')
  })
  it('normalises a bare 10-digit 3xx number', () => {
    expect(waLink('3001234567')).toBe('https://wa.me/923001234567')
  })
  it('leaves an already-international 92 number intact', () => {
    expect(waLink('+92 300 1234567')).toBe('https://wa.me/923001234567')
  })
})

import { describe, it, expect } from 'vitest'
import {
  canonicalBalanceColumn, mapBalanceRow, mapBalanceRows, missingBalanceColumns,
} from './importBalances'

describe('canonicalBalanceColumn', () => {
  it('maps identifier headings', () => {
    expect(canonicalBalanceColumn('GR No')).toBe('gr_no')
    expect(canonicalBalanceColumn('Adm No')).toBe('admission_no')
    expect(canonicalBalanceColumn('Student Name')).toBe('full_name')
    expect(canonicalBalanceColumn("Father's Name")).toBe('father_name')
  })
  it('maps the many ways schools name an arrears column to amount', () => {
    for (const h of ['Amount', 'Balance', 'Arrears', 'Outstanding', 'Dues', 'Opening Balance', 'Previous Balance', 'B/F']) {
      expect(canonicalBalanceColumn(h)).toBe('amount')
    }
  })
  it('maps due-date headings', () => {
    expect(canonicalBalanceColumn('Due Date')).toBe('due_date')
    expect(canonicalBalanceColumn('Pay By')).toBe('due_date')
  })
  it('returns null for unknown headings', () => {
    expect(canonicalBalanceColumn('Remarks')).toBeNull()
  })
})

describe('mapBalanceRow', () => {
  it('remaps and drops blanks/unknowns', () => {
    expect(
      mapBalanceRow({ 'GR No': 'GR100', 'Outstanding': '12,000', 'Remarks': 'call parent', 'Due Date': '' }),
    ).toEqual({ gr_no: 'GR100', amount: '12,000' })
  })
})

describe('mapBalanceRows', () => {
  it('maps a batch', () => {
    expect(mapBalanceRows([{ 'GR No': 'G1', Balance: '100' }, { 'GR No': 'G2', Balance: '200' }])).toEqual([
      { gr_no: 'G1', amount: '100' },
      { gr_no: 'G2', amount: '200' },
    ])
  })
})

describe('missingBalanceColumns', () => {
  it('is empty with an identifier + amount', () => {
    expect(missingBalanceColumns(['GR No', 'Balance'])).toEqual([])
    expect(missingBalanceColumns(['Student Name', 'Arrears'])).toEqual([])
  })
  it('flags a missing amount', () => {
    expect(missingBalanceColumns(['GR No'])).toEqual(['amount'])
  })
  it('flags a missing identifier', () => {
    expect(missingBalanceColumns(['Balance'])).toEqual(['a student identifier (gr_no, admission_no or full_name)'])
  })
})

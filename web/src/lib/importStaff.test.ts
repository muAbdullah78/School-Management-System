import { describe, it, expect } from 'vitest'
import { canonicalStaffColumn, mapStaffRow, missingStaffColumns } from './importStaff'

describe('canonicalStaffColumn', () => {
  it('maps common staff headings', () => {
    expect(canonicalStaffColumn('Staff Name')).toBe('full_name')
    expect(canonicalStaffColumn('Designation')).toBe('designation')
    expect(canonicalStaffColumn('Emp No')).toBe('employee_no')
    expect(canonicalStaffColumn('Mobile')).toBe('mobile')
    expect(canonicalStaffColumn('CNIC')).toBe('cnic')
    expect(canonicalStaffColumn('Date of Joining')).toBe('joined_on')
  })
  it('returns null for unknown headings', () => {
    expect(canonicalStaffColumn('Salary')).toBeNull()
  })
})

describe('mapStaffRow', () => {
  it('remaps and drops blanks/unknowns', () => {
    expect(mapStaffRow({ 'Staff Name': 'Mr Khan', 'Post': 'Teacher', 'Salary': '50000', 'CNIC': '' }))
      .toEqual({ full_name: 'Mr Khan', designation: 'Teacher' })
  })
})

describe('missingStaffColumns', () => {
  it('is empty when a name column is present', () => {
    expect(missingStaffColumns(['Employee Name', 'Post'])).toEqual([])
  })
  it('flags a missing name column', () => {
    expect(missingStaffColumns(['Post', 'Mobile'])).toEqual(['full_name'])
  })
})

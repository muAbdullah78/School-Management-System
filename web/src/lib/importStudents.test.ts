import { describe, it, expect } from 'vitest'
import {
  normalizeHeader, canonicalColumn, mapImportRow, mapImportRows, missingRequiredColumns,
} from './importStudents'

describe('normalizeHeader', () => {
  it('lower-cases and underscores spaces', () => {
    expect(normalizeHeader('Full Name')).toBe('full_name')
  })
  it('drops apostrophes rather than turning them into separators', () => {
    expect(normalizeHeader("Father's Name")).toBe('fathers_name')
  })
  it('collapses runs of punctuation and trims underscores', () => {
    expect(normalizeHeader('  GR # No.  ')).toBe('gr_no')
  })
})

describe('canonicalColumn', () => {
  it('maps common heading variants to canonical keys', () => {
    expect(canonicalColumn('Full Name')).toBe('full_name')
    expect(canonicalColumn('Student Name')).toBe('full_name')
    expect(canonicalColumn("Father's Name")).toBe('father_name')
    expect(canonicalColumn('DOB')).toBe('dob')
    expect(canonicalColumn('Date of Birth')).toBe('dob')
    expect(canonicalColumn('Grade')).toBe('class')
    expect(canonicalColumn('Roll #')).toBe('roll_no')
    expect(canonicalColumn('GR No')).toBe('gr_no')
    expect(canonicalColumn('Adm No')).toBe('admission_no')
    expect(canonicalColumn('Mobile')).toBe('phone')
    expect(canonicalColumn('Parent Name')).toBe('guardian_name')
  })
  it('returns null for unknown headings', () => {
    expect(canonicalColumn('Favourite Colour')).toBeNull()
  })
})

describe('mapImportRow', () => {
  it('remaps headings to canonical keys and drops blanks + unknowns', () => {
    expect(
      mapImportRow({
        'Full Name': 'Ali Raza',
        "Father's Name": 'Raza',
        'Class': 'Class 1',
        'Section': 'A',
        'DOB': '',
        'Favourite Colour': 'blue',
      }),
    ).toEqual({
      full_name: 'Ali Raza',
      father_name: 'Raza',
      class: 'Class 1',
      section: 'A',
    })
  })

  it('trims surrounding whitespace on values', () => {
    expect(mapImportRow({ Name: '  Sara  ', Class: ' 2 ' })).toEqual({
      full_name: 'Sara',
      class: '2',
    })
  })
})

describe('mapImportRows', () => {
  it('maps a batch', () => {
    expect(mapImportRows([{ Name: 'A', Grade: '1' }, { Name: 'B', Grade: '2' }])).toEqual([
      { full_name: 'A', class: '1' },
      { full_name: 'B', class: '2' },
    ])
  })
})

describe('missingRequiredColumns', () => {
  it('is empty when name + class are present under any alias', () => {
    expect(missingRequiredColumns(['Student Name', 'Grade', 'Section'])).toEqual([])
  })
  it('flags a missing class column', () => {
    expect(missingRequiredColumns(['Full Name', 'Section'])).toEqual(['class'])
  })
  it('flags both when neither is present', () => {
    expect(missingRequiredColumns(['Section', 'Roll'])).toEqual(['full_name', 'class'])
  })
})

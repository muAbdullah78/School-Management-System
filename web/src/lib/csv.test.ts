import { describe, it, expect } from 'vitest'
import { toCSV, parseCSV, parseCSVToObjects } from './csv'

describe('toCSV', () => {
  it('joins headers and rows with CRLF', () => {
    expect(toCSV(['a', 'b'], [[1, 2]])).toBe('a,b\r\n1,2')
  })

  it('renders null/undefined as empty cells', () => {
    expect(toCSV(['a', 'b', 'c'], [[null, undefined, '']])).toBe('a,b,c\r\n,,')
  })

  it('quotes values containing a comma', () => {
    expect(toCSV(['x'], [['a,b']])).toBe('x\r\n"a,b"')
  })

  it('escapes embedded double quotes by doubling them', () => {
    expect(toCSV(['x'], [['he said "hi"']])).toBe('x\r\n"he said ""hi"""')
  })

  it('quotes values containing a newline', () => {
    expect(toCSV(['x'], [['line1\nline2']])).toBe('x\r\n"line1\nline2"')
  })

  it('leaves plain numbers and strings unquoted', () => {
    expect(toCSV(['n', 's'], [[42, 'plain']])).toBe('n,s\r\n42,plain')
  })

  it('handles multiple rows', () => {
    expect(toCSV(['a'], [['1'], ['2'], ['3']])).toBe('a\r\n1\r\n2\r\n3')
  })

  it('round-trips through parseCSV', () => {
    const csv = toCSV(['name', 'note'], [['Ali', 'a,b'], ['Sara', 'he said "hi"']])
    expect(parseCSV(csv)).toEqual([
      ['name', 'note'],
      ['Ali', 'a,b'],
      ['Sara', 'he said "hi"'],
    ])
  })
})

describe('parseCSV', () => {
  it('parses a simple grid', () => {
    expect(parseCSV('a,b\n1,2')).toEqual([['a', 'b'], ['1', '2']])
  })

  it('handles CRLF line endings', () => {
    expect(parseCSV('a,b\r\n1,2\r\n3,4')).toEqual([['a', 'b'], ['1', '2'], ['3', '4']])
  })

  it('keeps commas inside quoted fields', () => {
    expect(parseCSV('x\n"a,b"')).toEqual([['x'], ['a,b']])
  })

  it('unescapes doubled quotes', () => {
    expect(parseCSV('x\n"he said ""hi"""')).toEqual([['x'], ['he said "hi"']])
  })

  it('keeps newlines inside quoted fields', () => {
    expect(parseCSV('x\n"line1\nline2"')).toEqual([['x'], ['line1\nline2']])
  })

  it('strips a leading BOM', () => {
    expect(parseCSV('﻿a,b\n1,2')).toEqual([['a', 'b'], ['1', '2']])
  })

  it('does not emit a trailing blank row for a trailing newline', () => {
    expect(parseCSV('a\n1\n')).toEqual([['a'], ['1']])
  })
})

describe('parseCSVToObjects', () => {
  it('keys rows by the header row and trims values', () => {
    const { headers, rows } = parseCSVToObjects('Name, Class \nAli, 1 \nSara,2')
    expect(headers).toEqual(['Name', 'Class'])
    expect(rows).toEqual([
      { Name: 'Ali', Class: '1' },
      { Name: 'Sara', Class: '2' },
    ])
  })

  it('drops fully-blank lines', () => {
    const { rows } = parseCSVToObjects('name\nAli\n\nSara\n')
    expect(rows.map((r) => r.name)).toEqual(['Ali', 'Sara'])
  })

  it('returns empty for empty input', () => {
    expect(parseCSVToObjects('')).toEqual({ headers: [], rows: [] })
  })

  it('fills missing trailing cells with empty strings', () => {
    const { rows } = parseCSVToObjects('a,b,c\n1,2')
    expect(rows[0]).toEqual({ a: '1', b: '2', c: '' })
  })
})

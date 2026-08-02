import { describe, it, expect } from 'vitest'
import { toCSV } from './csv'

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
})

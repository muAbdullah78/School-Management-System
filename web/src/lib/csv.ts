/** Minimal CSV builder + download. Values are stringified and quoted when they
 *  contain a comma, quote or newline (RFC-4180 style). No external deps. */
export function toCSV(headers: string[], rows: (string | number | null | undefined)[][]): string {
  const esc = (v: string | number | null | undefined) => {
    const s = v == null ? '' : String(v)
    return /[",\n]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s
  }
  return [headers.map(esc).join(','), ...rows.map((r) => r.map(esc).join(','))].join('\r\n')
}

/** Trigger a browser download of arbitrary text content. */
export function downloadText(filename: string, content: string, mime = 'text/plain;charset=utf-8;'): void {
  const blob = new Blob([content], { type: mime })
  const url = URL.createObjectURL(blob)
  const a = document.createElement('a')
  a.href = url
  a.download = filename
  document.body.appendChild(a)
  a.click()
  document.body.removeChild(a)
  URL.revokeObjectURL(url)
}

export function downloadCSV(filename: string, csv: string): void {
  // Prepend a BOM so Excel opens UTF-8 (Urdu names etc.) correctly.
  downloadText(filename, '﻿' + csv, 'text/csv;charset=utf-8;')
}

export function downloadJSON(filename: string, data: unknown): void {
  downloadText(filename, JSON.stringify(data, null, 2), 'application/json;charset=utf-8;')
}

/** Parse CSV text into a grid of string cells (RFC-4180: quoted fields, escaped
 *  quotes as "", commas/newlines inside quotes, CRLF or LF line endings, optional
 *  leading BOM). No external deps. */
export function parseCSV(input: string): string[][] {
  const s = input.replace(/^﻿/, '') // strip a leading UTF-8 BOM
  const rows: string[][] = []
  let row: string[] = []
  let field = ''
  let inQuotes = false
  let i = 0
  while (i < s.length) {
    const c = s[i]
    if (inQuotes) {
      if (c === '"') {
        if (s[i + 1] === '"') { field += '"'; i += 2; continue } // escaped quote
        inQuotes = false; i++; continue
      }
      field += c; i++; continue
    }
    if (c === '"') { inQuotes = true; i++; continue }
    if (c === ',') { row.push(field); field = ''; i++; continue }
    if (c === '\r') { i++; continue } // fold CR (handles CRLF)
    if (c === '\n') { row.push(field); rows.push(row); row = []; field = ''; i++; continue }
    field += c; i++
  }
  if (field.length > 0 || row.length > 0) { row.push(field); rows.push(row) }
  return rows
}

export interface ParsedCSV {
  headers: string[]
  rows: Record<string, string>[]
}

/** Parse CSV text into objects keyed by the (trimmed) header row. Fully-blank
 *  lines are dropped. Values are trimmed. */
export function parseCSVToObjects(input: string): ParsedCSV {
  const grid = parseCSV(input).filter((r) => r.some((c) => c.trim() !== ''))
  if (grid.length === 0) return { headers: [], rows: [] }
  const headers = grid[0].map((h) => h.trim())
  const rows = grid.slice(1).map((cells) => {
    const o: Record<string, string> = {}
    headers.forEach((h, idx) => { o[h] = (cells[idx] ?? '').trim() })
    return o
  })
  return { headers, rows }
}

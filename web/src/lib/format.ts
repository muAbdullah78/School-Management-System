/** Pakistani Rupee formatting (English, per locked decisions). */
export function fmtPKR(n: number | null | undefined): string {
  const v = Number(n ?? 0)
  return 'Rs ' + v.toLocaleString('en-PK', { maximumFractionDigits: 0 })
}

export function fmtDate(s?: string | null): string {
  if (!s) return '—'
  const d = new Date(s)
  return isNaN(d.getTime()) ? '—' : d.toLocaleDateString('en-PK', { year: 'numeric', month: 'short', day: 'numeric' })
}

/** First day of a month as YYYY-MM-DD from a <input type="month"> value (YYYY-MM). */
export function monthToDate(ym: string): string {
  return /^\d{4}-\d{2}$/.test(ym) ? `${ym}-01` : ym
}

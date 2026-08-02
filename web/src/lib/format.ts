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

/** Today as YYYY-MM-DD in local time (the value shape a <input type="date"> wants). */
export function todayISO(): string {
  const d = new Date()
  const m = String(d.getMonth() + 1).padStart(2, '0')
  const day = String(d.getDate()).padStart(2, '0')
  return `${d.getFullYear()}-${m}-${day}`
}

/**
 * Build a WhatsApp click-to-chat URL (wa.me) from a Pakistani phone number.
 * MANUAL link only — the app never sends anything automatically (locked
 * decision). Local 03xx… numbers are normalised to the 92 country code.
 * Returns null when there aren't enough digits to be a real number.
 */
export function waLink(raw: string | null | undefined): string | null {
  if (!raw) return null
  let digits = raw.replace(/\D/g, '')
  if (!digits) return null
  if (digits.startsWith('0')) digits = '92' + digits.slice(1)
  else if (digits.startsWith('92')) { /* already international */ }
  else if (digits.length === 10 && digits.startsWith('3')) digits = '92' + digits
  if (digits.length < 11) return null
  return `https://wa.me/${digits}`
}

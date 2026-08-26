/** Pakistani Rupee formatting (English, per locked decisions). */
/**
 * Rupees, no decimals.
 *
 * The sign goes OUTSIDE the currency: −Rs 33,500, not "Rs -33,500". The second
 * form is what toLocaleString gives you by default and it is wrong — the minus
 * belongs to the quantity, not to the unit, and buried after "Rs " it is easy
 * to skim straight past. That matters here: negatives in this product are a
 * credit on a family's account or a school that has spent more than it has
 * taken, and both are exactly the figures nobody may misread.
 */
export function fmtPKR(n: number | null | undefined): string {
  // Rounded ONCE, with both the sign and the digits taken from the same rounded
  // value — otherwise -0.4 rounds to "0" for display while still testing as
  // negative, and prints "−Rs 0".
  const v = Math.round(Number(n ?? 0))
  const abs = Math.abs(v).toLocaleString('en-PK', { maximumFractionDigits: 0 })
  return (v < 0 ? '−' : '') + 'Rs ' + abs
}

/**
 * The same number WITHOUT the unit, for a table that states the unit once in its
 * heading.
 *
 * Not a nicety. On a 360px phone — most of the parents using the portal — four
 * money columns each carrying "Rs " either wrap "Rs" onto its own line or push
 * the rightmost column off the edge, and the rightmost column is Outstanding:
 * the one number the page exists to show. Dropping the repeated unit buys back
 * about 25px per column, which is the difference.
 *
 * Sign handling is fmtPKR's, deliberately: rounded once, minus in front, so a
 * credit reads −4,500 and never "4,500" or "-0".
 */
export function fmtAmount(n: number | null | undefined): string {
  const v = Math.round(Number(n ?? 0))
  return (v < 0 ? '−' : '') + Math.abs(v).toLocaleString('en-PK', { maximumFractionDigits: 0 })
}

export function fmtDate(s?: string | null): string {
  if (!s) return '—'
  const d = new Date(s)
  return isNaN(d.getTime()) ? '—' : d.toLocaleDateString('en-PK', { year: 'numeric', month: 'short', day: 'numeric' })
}

/**
 * Date AND time, for the few places where the hour matters.
 *
 * Support visits are the reason this exists: "26 Aug 2026" tells a principal
 * nothing useful about a visit they want to ask about, and two visits on the same
 * day would be indistinguishable.
 */
export function fmtDateTime(s?: string | null): string {
  if (!s) return '—'
  const d = new Date(s)
  return isNaN(d.getTime())
    ? '—'
    : d.toLocaleString('en-PK', {
        year: 'numeric', month: 'short', day: 'numeric',
        hour: 'numeric', minute: '2-digit',
      })
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

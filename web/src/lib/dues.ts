/**
 * What a child already owed before the software knew them.
 *
 * A school moving onto the software brings children who owe: months of fee, an
 * admission fee nobody collected, a stationery bill, a picnic. The paper
 * register has it. Every screen that takes those dues in (Quick Add, the class
 * grid, the child's own page) shares this file, so they cannot disagree about
 * what a due is, which months can be owed, or how "Rs 5,000" is read.
 *
 * THE RULES ARE THE DATABASE'S (fn__record_dues, 0153), repeated here only so
 * the clerk is told before saving rather than after:
 *
 *   a month due      a month that has FINISHED, up to three years back. Never
 *                    this month: the software bills this month itself.
 *   a named due      admission, annual, exam, transport, stationery, books,
 *                    uniform, or "other" with a name the school types.
 */

export type NamedKind =
  | 'admission' | 'annual' | 'exam' | 'transport'
  | 'stationery' | 'books' | 'uniform' | 'other'
export type DueKind = 'month' | NamedKind

/** The named dues, in the order the chips are offered. */
export const NAMED_DUES: { kind: NamedKind; label: string }[] = [
  { kind: 'admission',  label: 'Admission fee' },
  { kind: 'annual',     label: 'Annual charges' },
  { kind: 'exam',       label: 'Exam fee' },
  { kind: 'transport',  label: 'Transport' },
  { kind: 'stationery', label: 'Stationery' },
  { kind: 'books',      label: 'Books' },
  { kind: 'uniform',    label: 'Uniform' },
  { kind: 'other',      label: 'Something else' },
]

/** How far back a month due may go. fn__record_dues refuses anything older. */
export const MONTHS_BACK = 36

/** What the server is sent. */
export interface DueInput {
  kind: DueKind
  month?: string
  label?: string
  amount: number
}

/** One named due while it is being typed. */
export interface NamedDraft {
  key: string
  kind: NamedKind
  label: string
  amount: string
}

/** The editor's state: amounts exactly as typed, so "5,0" mid-keystroke is kept. */
export interface DuesDraft {
  /** 'YYYY-MM-01' to the amount typed for it. */
  months: Record<string, string>
  named: NamedDraft[]
}

export function emptyDues(): DuesDraft {
  return { months: {}, named: [] }
}

let keySeq = 0
export function newNamed(kind: NamedKind): NamedDraft {
  const preset = NAMED_DUES.find((d) => d.kind === kind)
  return {
    key: `d${++keySeq}`,
    kind,
    label: kind === 'other' ? '' : (preset?.label ?? ''),
    amount: '',
  }
}

/**
 * An amount the way people type it. "5000", "5,000", "Rs 5,000", "PKR 5000".
 *
 * null for an empty box, NaN for something that is not an amount, so the
 * caller can tell "nothing typed" from "typed wrong".
 */
export function parseAmount(raw: string | null | undefined): number | null {
  const t = (raw ?? '').toLowerCase().replace(/pkr|rs\.?|,|\s/g, '')
  if (t === '') return null
  if (!/^\d+(\.\d{1,2})?$/.test(t)) return NaN
  return Number(t)
}

/** This month in Karachi, as 'YYYY-MM-01'. A UTC machine is still on yesterday for five hours. */
export function karachiMonth(now: number = Date.now()): string {
  const k = new Date(now + 5 * 60 * 60 * 1000)
  return `${k.getUTCFullYear()}-${String(k.getUTCMonth() + 1).padStart(2, '0')}-01`
}

/**
 * Every month a due can be for, newest first: last month back to MONTHS_BACK.
 *
 * Unlike finishedMonths this does not stop at the start of the school year. A
 * school that switches in its first month has nothing BUT last year's dues,
 * and that is exactly when schools switch.
 */
export function dueMonths(now: number = Date.now(), back: number = MONTHS_BACK): string[] {
  const [y0, m0] = karachiMonth(now).split('-').map(Number)
  const out: string[] = []
  let y = y0
  let m = m0
  for (let i = 0; i < back; i++) {
    m -= 1
    if (m === 0) { m = 12; y -= 1 }
    out.push(`${y}-${String(m).padStart(2, '0')}-01`)
  }
  return out
}

export interface DuesCheck {
  dues: DueInput[]
  /** Sentences for the lines that cannot be sent as they are. */
  problems: string[]
  total: number
  months: number
  named: number
}

/**
 * The draft as the server will take it, plus what is wrong with it.
 *
 * Empty boxes are not dues and not problems. A box with something that is not
 * an amount is a problem, named, so the clerk fixes it before saving rather
 * than finding out from the result that one line was left out.
 */
export function checkDues(d: DuesDraft, labelMonth: (iso: string) => string = (s) => s): DuesCheck {
  const dues: DueInput[] = []
  const problems: string[] = []
  let total = 0
  let months = 0
  let named = 0
  const allowed = new Set(dueMonths())
  for (const [month, raw] of Object.entries(d.months).sort(([a], [b]) => a.localeCompare(b))) {
    const amt = parseAmount(raw)
    if (amt === null || amt === 0) continue
    if (Number.isNaN(amt)) { problems.push(`${labelMonth(month)}: "${raw}" is not an amount.`); continue }
    if (!allowed.has(month)) {
      problems.push(`${labelMonth(month)} cannot carry a due: it has not finished, or it is more than three years ago.`)
      continue
    }
    dues.push({ kind: 'month', month: month.slice(0, 7), amount: amt })
    total += amt
    months += 1
  }
  for (const n of d.named) {
    const amt = parseAmount(n.amount)
    const name = n.label.trim()
    if (amt === null && name === '') continue
    const what = name || NAMED_DUES.find((x) => x.kind === n.kind)?.label || 'A due'
    if (amt === null || amt === 0) { problems.push(`${what}: type the amount owed.`); continue }
    if (Number.isNaN(amt)) { problems.push(`${what}: "${n.amount}" is not an amount.`); continue }
    if (n.kind === 'other' && name === '') {
      problems.push(`A due of Rs ${amt.toLocaleString('en-PK')} needs a name: say what it is for.`)
      continue
    }
    if (name.length > 80) { problems.push(`${what.slice(0, 30)}…: keep the name under 80 letters.`); continue }
    dues.push({ kind: n.kind, label: name || undefined, amount: amt })
    total += amt
    named += 1
  }
  return { dues, problems, total, months, named }
}

export function isDuesEmpty(d: DuesDraft | null | undefined): boolean {
  if (!d) return true
  return Object.values(d.months).every((v) => !(v ?? '').trim())
    && d.named.every((n) => !n.amount.trim() && !n.label.trim())
}

/** The grid keeps every cell as a string, so a row's dues travel as JSON. */
export function encodeDues(d: DuesDraft): string {
  return isDuesEmpty(d) ? '' : JSON.stringify(d)
}

export function decodeDues(raw: string | null | undefined): DuesDraft {
  if (!raw) return emptyDues()
  try {
    const v = JSON.parse(raw) as Partial<DuesDraft>
    const months: Record<string, string> = {}
    if (v.months && typeof v.months === 'object') {
      for (const [k, val] of Object.entries(v.months)) {
        if (/^\d{4}-\d{2}-01$/.test(k) && typeof val === 'string') months[k] = val
      }
    }
    const named: NamedDraft[] = Array.isArray(v.named)
      ? v.named
          .filter((n): n is NamedDraft => !!n && typeof n === 'object'
            && NAMED_DUES.some((x) => x.kind === (n as NamedDraft).kind))
          .map((n) => ({
            key: `d${++keySeq}`, kind: n.kind,
            label: String(n.label ?? ''), amount: String(n.amount ?? ''),
          }))
      : []
    return { months, named }
  } catch {
    return emptyDues()
  }
}

/** "Rs 14,000 · 3 months · 2 other dues", or '' when there is nothing. */
export function duesSummary(c: Pick<DuesCheck, 'total' | 'months' | 'named'>): string {
  if (c.total <= 0) return ''
  const parts = [`Rs ${Math.round(c.total).toLocaleString('en-PK')}`]
  if (c.months > 0) parts.push(`${c.months} month${c.months === 1 ? '' : 's'}`)
  if (c.named > 0) parts.push(`${c.named} other due${c.named === 1 ? '' : 's'}`)
  return parts.join(' · ')
}

/** What the server said about one due, as it comes back. */
export interface DueResult {
  i: number
  kind: DueKind | null
  month: string | null
  label: string | null
  amount: number | null
  status: 'recorded' | 'skipped' | 'refused'
  message: string | null
  invoice_id: string | null
}

export interface RecordDuesResult {
  recorded: number
  months: number
  total: number
  items: DueResult[]
}

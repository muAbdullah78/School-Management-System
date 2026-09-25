/**
 * The pieces every report is made of, written once.
 *
 * Nineteen reports each built their own date boxes, their own "Total: Rs X"
 * line and their own Print button, in four different grey boxes, and the
 * screenshot showed the result: a wall of plain tables where every figure
 * looked the same weight and every method read "bank_transfer".
 */
import type { ReactNode } from 'react'
import { useSchoolName } from '@/hooks/useSchoolName'
import { Button, inputClass } from '@/components/ui'
import { PAYMENT_METHODS } from '@/lib/constants'
import { today, monthStart, monthsAgoStart, daysAgo } from '@/lib/dates'
import { fmtDate, shiftDate } from '@/lib/format'

/* ------------------------------------------------------------ methods --- */

const METHOD: Record<string, string> = Object.fromEntries(PAYMENT_METHODS.map((m) => [m.value, m.label]))

/** "bank_transfer" is a database value. The office reads "Bank Transfer". */
export function methodLabel(m: string | null | undefined): string {
  if (!m) return '-'
  return METHOD[m] ?? m.replace(/_/g, ' ').replace(/^./, (c) => c.toUpperCase())
}

/** Words for the statuses the reports print, where the database keeps codes. */
const STATUS: Record<string, string> = {
  active: 'On the roll', withdrawn: 'Withdrawn', struck_off: 'Struck off', graduated: 'Graduated',
  promoted: 'Promoted', retained: 'Kept back', transferred: 'Transferred', left: 'Left',
  approved: 'Approved', pending: 'Waiting for approval', rejected: 'Refused', expired: 'Ended',
}
export function statusLabel(s: string | null | undefined): string {
  if (!s) return '-'
  return STATUS[s] ?? s.replace(/_/g, ' ').replace(/^./, (c) => c.toUpperCase())
}

/* ------------------------------------------------------------- ranges --- */

export interface Range { from: string; to: string }

function lastMonth(): Range {
  const from = monthsAgoStart(1)
  return { from, to: shiftDate(monthStart(), -1) }
}

export function rangePresets(): { key: string; label: string; range: Range }[] {
  const t = today()
  return [
    { key: 'today', label: 'Today', range: { from: t, to: t } },
    { key: 'yesterday', label: 'Yesterday', range: { from: shiftDate(t, -1), to: shiftDate(t, -1) } },
    { key: 'month', label: 'This month', range: { from: monthStart(), to: t } },
    { key: 'last', label: 'Last month', range: lastMonth() },
    { key: '90', label: 'Last 90 days', range: { from: daysAgo(89), to: t } },
  ]
}

function daysBetween(a: string, b: string): number {
  const [ya, ma, da] = a.split('-').map(Number)
  const [yb, mb, db] = b.split('-').map(Number)
  return Math.round((Date.UTC(yb, mb - 1, db) - Date.UTC(ya, ma - 1, da)) / 86_400_000)
}

/** Why a range cannot be asked for, in words, or null. Said here, before the
 *  database refuses it in its own. */
export function rangeProblem(r: Range, maxDays = 400): string | null {
  if (!r.from || !r.to) return 'Give both dates.'
  if (r.to < r.from) return 'The end date is before the start date.'
  if (daysBetween(r.from, r.to) > maxDays) return 'Ask for a year at a time or less.'
  return null
}

/**
 * The date range, with the ranges an office actually asks for one tap away.
 * `blank` allows both boxes empty, meaning "everything", for the registers
 * that have always worked that way.
 */
export function RangePicker({ value, onChange, blank = false, presets = rangePresets() }: {
  value: Range
  onChange: (r: Range) => void
  blank?: boolean
  presets?: { key: string; label: string; range: Range }[]
}) {
  const t = today()
  const on = (r: Range) => r.from === value.from && r.to === value.to
  return (
    <div className="flex flex-wrap items-end gap-2 print:hidden">
      <div className="flex flex-wrap gap-1.5">
        {blank && (
          <Chip on={!value.from && !value.to} onClick={() => onChange({ from: '', to: '' })}>Everything</Chip>
        )}
        {presets.map((p) => (
          <Chip key={p.key} on={on(p.range)} onClick={() => onChange(p.range)}>{p.label}</Chip>
        ))}
      </div>
      <div className="flex items-end gap-2">
        <label className="block">
          <span className="mb-1 block text-xs font-medium text-slate-500">From</span>
          <input type="date" value={value.from} max={value.to || t}
            onChange={(e) => onChange({ ...value, from: e.target.value })} className={`${inputClass} w-auto`} />
        </label>
        <label className="block">
          <span className="mb-1 block text-xs font-medium text-slate-500">To</span>
          <input type="date" value={value.to} min={value.from || undefined} max={t}
            onChange={(e) => onChange({ ...value, to: e.target.value })} className={`${inputClass} w-auto`} />
        </label>
      </div>
    </div>
  )
}

export function Chip({ on, onClick, children }: { on: boolean; onClick: () => void; children: ReactNode }) {
  return (
    <button type="button" aria-pressed={on} onClick={onClick}
      className={`rounded-full px-3 py-1.5 text-sm font-medium ring-1 transition ${
        on ? 'bg-brand-600 text-white ring-brand-600' : 'bg-white text-slate-600 ring-slate-300 hover:bg-slate-50'}`}>
      {children}
    </button>
  )
}

export function rangeWords(r: Range): string {
  if (!r.from && !r.to) return 'All dates'
  if (r.from === r.to) return fmtDate(r.from)
  return `${r.from ? fmtDate(r.from) : 'The start'} to ${r.to ? fmtDate(r.to) : 'today'}`
}

/* -------------------------------------------------------------- tiles --- */

export type TileTone = 'brand' | 'money' | 'due' | 'danger' | 'info' | 'plain'

const TILE: Record<TileTone, { box: string; value: string }> = {
  brand: { box: 'border-brand-100 bg-brand-50', value: 'text-brand-800' },
  money: { box: 'border-money-100 bg-money-50', value: 'text-money-800' },
  due: { box: 'border-due-200 bg-due-50', value: 'text-due-800' },
  danger: { box: 'border-danger-200 bg-danger-50', value: 'text-danger-700' },
  info: { box: 'border-info-100 bg-info-50', value: 'text-info-800' },
  plain: { box: 'border-slate-200 bg-white', value: 'text-slate-900' },
}

/** One figure. Green only for money that came in, amber only for money or work
 *  still owed, red only for something wrong: the same meanings as every other
 *  screen, so a colour never has to be learnt twice. */
export function Tile({ label, value, sub, tone = 'plain' }: {
  label: string; value: ReactNode; sub?: ReactNode; tone?: TileTone
}) {
  const t = TILE[tone]
  return (
    <div className={`min-w-0 rounded-2xl border px-4 py-3 ${t.box}`}>
      <div className="text-xs font-medium text-slate-600">{label}</div>
      <div className={`mt-0.5 truncate text-xl font-semibold tabular-nums sm:text-2xl ${t.value}`}>{value}</div>
      {sub && <div className="mt-0.5 text-xs text-slate-500">{sub}</div>}
    </div>
  )
}

export function Tiles({ children }: { children: ReactNode }) {
  return <div className="grid grid-cols-2 gap-3 lg:grid-cols-4">{children}</div>
}

/* -------------------------------------------------------------- frame --- */

/**
 * The printable page: the school's name at the top, what the report is and
 * for which dates, then the report. Print and CSV sit above it and never print.
 */
export function ReportFrame({ title, subtitle, onCSV, onPrint = () => window.print(), children, bare = false }: {
  title: string
  subtitle?: string
  onCSV?: (() => void) | null
  onPrint?: (() => void) | null
  children: ReactNode
  /** No white card around it, for a report that is already cards. */
  bare?: boolean
}) {
  const schoolName = useSchoolName()
  return (
    <div className="space-y-3">
      {(onCSV || onPrint) && (
        <div className="flex flex-wrap justify-end gap-2 print:hidden">
          {onCSV && <Button size="sm" variant="soft" tone="neutral" onClick={onCSV}>Download CSV</Button>}
          {onPrint && <Button size="sm" variant="soft" tone="brand" onClick={onPrint}>Print or save as PDF</Button>}
        </div>
      )}
      <div id="report" className={bare ? '' : 'rounded-2xl border border-slate-200 bg-white p-4 shadow-card sm:p-5 print:border-0 print:p-0 print:shadow-none'}>
        <div className="mb-4 flex flex-wrap items-baseline justify-between gap-x-4 gap-y-1 border-b border-slate-100 pb-3">
          <div className="min-w-0">
            <div className="text-base font-semibold text-slate-900">{schoolName}</div>
            <div className="text-sm text-slate-600">{title}</div>
          </div>
          {subtitle && <div className="text-sm text-slate-500">{subtitle}</div>}
        </div>
        {children}
      </div>
    </div>
  )
}

export function Loading({ what = 'the report' }: { what?: string }) {
  return <p className="py-8 text-center text-sm text-slate-500">Working out {what}…</p>
}

export function Failed({ error }: { error: unknown }) {
  return (
    <p className="rounded-xl border border-danger-200 bg-danger-50 px-4 py-3 text-sm text-danger-700">
      {(error as Error)?.message ?? 'The report could not be read.'}
    </p>
  )
}

export function Empty({ title, children }: { title: string; children?: ReactNode }) {
  return (
    <div className="rounded-xl border border-dashed border-slate-300 bg-slate-50/60 px-4 py-8 text-center">
      <div className="text-sm font-medium text-slate-700">{title}</div>
      {children && <div className="mx-auto mt-1 max-w-md text-sm text-slate-500">{children}</div>}
    </div>
  )
}

export function Note({ children }: { children: ReactNode }) {
  return <p className="mt-3 text-xs leading-relaxed text-slate-500">{children}</p>
}

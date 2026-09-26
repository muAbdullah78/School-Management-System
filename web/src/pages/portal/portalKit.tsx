/**
 * The small pieces every tab of the parent portal draws with.
 *
 * Kept apart from the tabs so a date reads the same way on the fee card, the
 * calendar and the test list, and so the colour rules live in one place:
 *
 *   money green   money in, paid, present: never a test score
 *   due amber     owed, late, below the pass mark
 *   danger red    overdue, absent from school
 *   info sky      leave the school approved
 *   brand indigo  everything that is neither: the child, the score, the trend
 *
 * Subject colours are identity, not status, so they are drawn from hues that
 * mean nothing else on the page.
 */
import type { ReactNode } from 'react'

export function monthLabel(m: string | null): string {
  if (!m) return 'Other charges'
  const d = new Date(m.length === 10 ? `${m}T00:00:00` : m)
  return isNaN(d.getTime())
    ? m
    : d.toLocaleDateString('en-PK', { month: 'long', year: 'numeric' })
}

export function dayLabel(d: string): string {
  const dt = new Date(`${d}T00:00:00`)
  return isNaN(dt.getTime())
    ? d
    : dt.toLocaleDateString('en-PK', { weekday: 'short', day: 'numeric', month: 'short' })
}

export function shortDate(d: string | null | undefined): string {
  if (!d) return ''
  const dt = new Date(`${d.slice(0, 10)}T00:00:00`)
  return isNaN(dt.getTime()) ? d : dt.toLocaleDateString('en-PK', { day: 'numeric', month: 'short' })
}

/** Whole days from `from` to `to`, both YYYY-MM-DD. */
export function daysBetween(from: string, to: string): number {
  const a = Date.UTC(+from.slice(0, 4), +from.slice(5, 7) - 1, +from.slice(8, 10))
  const b = Date.UTC(+to.slice(0, 4), +to.slice(5, 7) - 1, +to.slice(8, 10))
  return Math.round((b - a) / 86400000)
}

/** A birthday is today when the month and day match, in Pakistan. */
export function isBirthday(dob: string | null | undefined, today: string): boolean {
  return !!dob && dob.length >= 10 && dob.slice(5, 10) === today.slice(5, 10)
}

export function firstName(full: string | null | undefined): string {
  return (full ?? '').trim().split(/\s+/)[0] ?? ''
}

/** A score as a whole-number percentage, or null when there is nothing to divide. */
export function pct(marks: number | null, max: number): number | null {
  if (marks == null || !max) return null
  return Math.round((marks / max) * 100)
}

/** Marks as a person writes them: 18, 17.5, never 18.00. */
export function markText(n: number | null): string {
  if (n == null) return '-'
  return Number.isInteger(n) ? String(n) : String(Math.round(n * 10) / 10)
}

/** The pass mark the teacher's side uses for class tests (fn_tests_marks). */
export const TEST_PASS_PCT = 33

// Shared with the teacher screens, so a subject is the same colour for a
// teacher and a parent, and a date leaf looks the same on both.
export { subjectTone, SubjectChip, DateChip } from '@/components/chips'

/** A card on the portal. Rounder and softer than the office's, on purpose. */
export function PCard({ children, className = '', padded = true }: { children: ReactNode; className?: string; padded?: boolean }) {
  return (
    <section className={`rounded-3xl bg-white shadow-card ring-1 ring-slate-200/70 ${padded ? 'p-4 sm:p-5' : ''} ${className}`}>
      {children}
    </section>
  )
}

export function PTitle({ icon, children, right, tone = 'brand' }: {
  icon?: ReactNode; children: ReactNode; right?: ReactNode; tone?: 'brand' | 'money' | 'due' | 'sky' | 'violet'
}) {
  const skin = {
    brand: 'bg-brand-50 text-brand-600',
    money: 'bg-money-50 text-money-600',
    due: 'bg-due-50 text-due-600',
    sky: 'bg-sky-50 text-sky-600',
    violet: 'bg-violet-50 text-violet-600',
  }[tone]
  return (
    <div className="mb-3 flex items-center justify-between gap-3">
      <h2 className="flex min-w-0 items-center gap-2.5 text-base font-semibold text-slate-900">
        {icon && <span className={`flex h-8 w-8 shrink-0 items-center justify-center rounded-xl ${skin}`}>{icon}</span>}
        <span className="min-w-0 break-words leading-snug">{children}</span>
      </h2>
      {right}
    </div>
  )
}

/** A grey placeholder the shape of what is loading, so the page does not jump. */
export function Skeleton({ lines = 3 }: { lines?: number }) {
  return (
    <PCard>
      <div className="animate-pulse space-y-3" aria-label="Loading">
        <div className="h-5 w-1/3 rounded-full bg-slate-200" />
        {Array.from({ length: lines }, (_, i) => (
          <div key={i} className="h-10 rounded-2xl bg-slate-100" />
        ))}
      </div>
    </PCard>
  )
}

export function Problem({ error, onRetry }: { error: unknown; onRetry?: () => void }) {
  return (
    <PCard>
      <p className="text-sm text-danger-700">
        This could not be loaded. {(error as Error)?.message}
      </p>
      {onRetry && (
        <button type="button" onClick={onRetry}
          className="mt-3 rounded-full bg-white px-4 py-2 text-sm font-medium text-brand-700 ring-1 ring-brand-200 hover:bg-brand-50">
          Try again
        </button>
      )}
    </PCard>
  )
}

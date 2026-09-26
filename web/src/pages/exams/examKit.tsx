/**
 * What every Exams screen shares: who is looking, which term and class are
 * picked, the guard that stops a switch throwing typed work away, and the few
 * visual pieces the five screens are built from.
 *
 * THE TERM AND THE CLASS LIVE IN THE ADDRESS BAR (?term=&class=), beside the
 * tab. Each screen used to keep its own pickers, so going from Marks Entry to
 * Result Cards meant choosing the same term and class a second time, and a
 * reload forgot both. Now they are chosen once and every tab reads them.
 */
import { createContext, useContext, useEffect, type ReactNode } from 'react'
import { useSearchParams } from 'react-router-dom'
import { useQuery } from '@tanstack/react-query'
import { getCurrentSession, listExamTerms, listClasses, getMyTeaching, type ExamTerm } from '@/lib/db'
import { todayISO } from '@/lib/format'

/* ------------------------------------------------------------------ who --- */

export type ExamRole = 'office' | 'observer' | 'class_teacher' | 'subject_teacher' | 'none'

/** The office sets up and publishes; an observer reads the cards; a class
 *  teacher marks their classes and writes remarks; a subject teacher marks. */
export function examRole(role: string | null | undefined): ExamRole {
  if (role === 'owner' || role === 'principal' || role === 'admin_clerk') return 'office'
  if (role === 'readonly') return 'observer'
  if (role === 'class_teacher') return 'class_teacher'
  if (role === 'subject_teacher') return 'subject_teacher'
  return 'none'
}

/** Releasing results to parents is narrower than preparing them (0033). */
export function mayRelease(role: string | null | undefined): boolean {
  return role === 'owner' || role === 'principal'
}

/* ------------------------------------------------------ term and class --- */

/* TWO PICKS IN ONE TICK MUST BOTH LAND. The page picks the term and a tab
   picks the only class a teacher has, in the same round of effects. Each call
   of setSearchParams builds on the address as it was when its component last
   drew, so the second call silently undid the first: the teacher landed on no
   class at all. The address a pick builds on is carried here until the
   router has caught up. */
let pendingSearch: string | null = null

export function useExamPick() {
  const [params, setParams] = useSearchParams()
  const termId = params.get('term') ?? ''
  const classId = params.get('class') ?? ''
  function set(patch: { term?: string | null; class?: string | null }) {
    setParams((prev) => {
      const p = new URLSearchParams(pendingSearch ?? prev)
      for (const [k, v] of Object.entries(patch)) {
        if (v) p.set(k, v)
        else p.delete(k)
      }
      pendingSearch = p.toString()
      queueMicrotask(() => { pendingSearch = null })
      return p
    }, { replace: true })
  }
  return {
    termId, classId, set,
    setTerm: (id: string) => set({ term: id }),
    setClass: (id: string) => set({ class: id }),
  }
}

/** The session, its terms and the school's classes: the three reads every tab
 *  starts from, on the query keys the rest of the app already uses. */
export function useExamBasics() {
  const session = useQuery({ queryKey: ['currentSession'], queryFn: getCurrentSession })
  const sessionId = session.data?.id
  const terms = useQuery({
    queryKey: ['examTerms', sessionId], queryFn: () => listExamTerms(sessionId!), enabled: !!sessionId,
  })
  const classes = useQuery({ queryKey: ['classes'], queryFn: listClasses })
  return { session, sessionId, terms, classes }
}

/** What the signed-in teacher teaches (0151). Only asked for a teacher. */
export function useTeaching(enabled: boolean) {
  return useQuery({ queryKey: ['myTeaching'], queryFn: getMyTeaching, enabled })
}

/**
 * The term to open on when none is named: the one running today, else the most
 * recent one to have started, else the next to start, else the last made. A
 * school opening Exams in the middle of First Term should land on First Term.
 */
export function defaultTerm(terms: ExamTerm[], today = todayISO()): ExamTerm | undefined {
  if (terms.length === 0) return undefined
  const dated = terms.filter((t) => !!t.starts_on)
  const running = dated.find((t) => t.starts_on! <= today && (!t.ends_on || t.ends_on >= today))
  if (running) return running
  const started = dated.filter((t) => t.starts_on! <= today)
    .sort((a, b) => b.starts_on!.localeCompare(a.starts_on!))[0]
  if (started) return started
  const next = dated.filter((t) => t.starts_on! > today)
    .sort((a, b) => a.starts_on!.localeCompare(b.starts_on!))[0]
  return next ?? terms[terms.length - 1]
}

/* ------------------------------------------------------- unsaved work --- */

interface DirtyApi {
  setDirty: (key: string, dirty: boolean) => void
  /** Runs `run` now, or asks first when something typed is not saved. */
  guard: (run: () => void) => void
}

const DirtyCtx = createContext<DirtyApi>({ setDirty: () => {}, guard: (run) => run() })
export const DirtyProvider = DirtyCtx.Provider

/**
 * Report this screen's unsaved work to the page, and get the guard back.
 *
 * The page asks before it switches tab or term, and warns before the browser
 * closes or reloads. Before this a typed marksheet was lost to a tab click
 * without a word.
 */
export function useUnsaved(dirty: boolean, key: string): (run: () => void) => void {
  const ctx = useContext(DirtyCtx)
  useEffect(() => { ctx.setDirty(key, dirty) }, [ctx, key, dirty])
  useEffect(() => () => ctx.setDirty(key, false), [ctx, key])
  return ctx.guard
}

/* ------------------------------------------------------------- pieces --- */

export const PANEL = 'rounded-3xl bg-white p-4 shadow-card ring-1 ring-slate-200/70 sm:p-5'

export function Panel({ children, className = '' }: { children: ReactNode; className?: string }) {
  return <section className={`${PANEL} ${className}`}>{children}</section>
}

export function PanelHead({ icon, title, sub, action }: {
  icon?: ReactNode; title: ReactNode; sub?: ReactNode; action?: ReactNode
}) {
  return (
    <div className="mb-4 flex flex-wrap items-start justify-between gap-3">
      <div className="flex min-w-0 items-start gap-3">
        {icon && (
          <span className="flex h-10 w-10 shrink-0 items-center justify-center rounded-2xl bg-brand-50 text-lg text-brand-700 ring-1 ring-brand-100">
            {icon}
          </span>
        )}
        <div className="min-w-0">
          <h2 className="text-base font-semibold text-slate-900">{title}</h2>
          {sub && <p className="mt-0.5 text-sm text-slate-500">{sub}</p>}
        </div>
      </div>
      {action && <div className="flex flex-wrap items-center gap-2">{action}</div>}
    </div>
  )
}

export type ChipTone = 'brand' | 'sky' | 'violet' | 'due' | 'danger' | 'slate' | 'solid'

const CHIP: Record<ChipTone, string> = {
  brand: 'bg-brand-50 text-brand-700 ring-brand-200',
  sky: 'bg-sky-50 text-sky-700 ring-sky-200',
  violet: 'bg-violet-50 text-violet-700 ring-violet-200',
  due: 'bg-due-50 text-due-800 ring-due-200',
  danger: 'bg-danger-50 text-danger-700 ring-danger-200',
  slate: 'bg-slate-100 text-slate-600 ring-slate-200',
  solid: 'bg-brand-600 text-white ring-brand-600',
}

export function Chip({ tone = 'slate', children, title }: { tone?: ChipTone; children: ReactNode; title?: string }) {
  return (
    <span title={title} className={`inline-flex items-center gap-1 whitespace-nowrap rounded-full px-2 py-0.5 text-[11px] font-semibold ring-1 ${CHIP[tone]}`}>
      {children}
    </span>
  )
}

/** A thin progress bar. Amber while work is waiting, indigo when it is done. */
export function Meter({ value, max, className = '' }: { value: number; max: number; className?: string }) {
  const pct = max > 0 ? Math.min(100, Math.round((100 * value) / max)) : 0
  const done = max > 0 && value >= max
  return (
    <div className={`h-1.5 overflow-hidden rounded-full bg-slate-100 ${className}`}
      role="progressbar" aria-valuenow={value} aria-valuemin={0} aria-valuemax={max}>
      <div className={`h-full rounded-full transition-all ${done ? 'bg-brand-500' : 'bg-due-400'}`}
        style={{ width: `${max > 0 && value > 0 ? Math.max(pct, 3) : 0}%` }} />
    </div>
  )
}

export interface PillItem {
  id: string
  label: string
  /** A second, smaller line: a count, a status. */
  sub?: ReactNode
  /** A small coloured dot before the label: the state at a glance. */
  dot?: 'due' | 'brand' | 'danger' | 'sky' | 'violet' | 'slate'
}

const DOT: Record<NonNullable<PillItem['dot']>, string> = {
  due: 'bg-due-400', brand: 'bg-brand-500', danger: 'bg-danger-500',
  sky: 'bg-sky-500', violet: 'bg-violet-500', slate: 'bg-slate-300',
}

/**
 * A row of choices, one of them picked. On a phone it scrolls sideways inside
 * itself rather than wrapping into five rows of buttons above the work; from
 * `sm` it wraps. Each is a real button with aria-pressed.
 */
export function Pills({ items, value, onPick, label, className = '' }: {
  items: PillItem[]; value: string; onPick: (id: string) => void; label: string; className?: string
}) {
  return (
    <div role="group" aria-label={label}
      className={`-mx-1 flex gap-2 overflow-x-auto px-1 pb-1 sm:flex-wrap sm:overflow-visible ${className}`}
      style={{ scrollbarWidth: 'none' }}>
      {items.map((it) => {
        const on = it.id === value
        return (
          <button key={it.id} type="button" aria-pressed={on} onClick={() => onPick(it.id)}
            style={{ touchAction: 'manipulation' }}
            className={`flex shrink-0 items-center gap-2 rounded-2xl px-3 py-2 text-left text-sm ring-1 transition focus:outline-none focus-visible:ring-2 focus-visible:ring-brand-500 ${
              on ? 'bg-brand-600 text-white shadow-sm ring-brand-600'
                : 'bg-white text-slate-700 shadow-sm ring-slate-200 hover:bg-brand-50 hover:ring-brand-300'}`}>
            {it.dot && <span className={`h-2 w-2 shrink-0 rounded-full ${on ? 'bg-white' : DOT[it.dot]}`} aria-hidden />}
            <span className="min-w-0">
              <span className="block whitespace-nowrap font-medium leading-tight">{it.label}</span>
              {it.sub != null && (
                <span className={`block whitespace-nowrap text-[11px] leading-tight ${on ? 'text-white/80' : 'text-slate-500'}`}>{it.sub}</span>
              )}
            </span>
          </button>
        )
      })}
    </div>
  )
}

export function Stat({ label, value, sub, tone = 'plain' }: {
  label: string; value: ReactNode; sub?: ReactNode; tone?: 'plain' | 'due' | 'danger' | 'brand'
}) {
  const skin = tone === 'due' ? 'bg-due-50 text-due-900 ring-due-200'
    : tone === 'danger' ? 'bg-danger-50 text-danger-900 ring-danger-200'
    : tone === 'brand' ? 'bg-brand-50 text-brand-900 ring-brand-200'
    : 'bg-white text-slate-900 ring-slate-200'
  return (
    <div className={`rounded-2xl px-3 py-2.5 ring-1 ${skin}`}>
      <div className="text-[11px] font-semibold uppercase tracking-wide opacity-70">{label}</div>
      <div className="mt-0.5 text-xl font-bold tabular-nums leading-tight">{value}</div>
      {sub != null && <div className="mt-0.5 text-xs opacity-80">{sub}</div>}
    </div>
  )
}

/** Said, not hidden, when the database has not had this release pasted in. */
export function NeedsUpdate({ what }: { what: string }) {
  return (
    <p className="rounded-2xl bg-sky-50 px-3 py-2 text-sm text-sky-800 ring-1 ring-sky-200">
      {what} needs the latest database update. Ask the school owner to paste
      {' '}<b>bundle 53</b> in the Supabase SQL editor.
    </p>
  )
}

export const FIELD = 'mt-1 w-full rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm text-slate-900 shadow-sm focus:border-brand-500 focus:outline-none focus:ring-2 focus:ring-brand-100 disabled:bg-slate-50 disabled:text-slate-400'

/** Roll numbers as numbers: "10" after "9", and a roll with letters in it
 *  sorted by its digits. The same rule the marksheet uses in the database. */
export function rollNumber(roll: string | null | undefined): number {
  const n = parseInt((roll ?? '').replace(/[^0-9]/g, ''), 10)
  return Number.isNaN(n) ? Number.MAX_SAFE_INTEGER : n
}

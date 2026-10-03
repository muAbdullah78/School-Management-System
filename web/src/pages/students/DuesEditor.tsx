/**
 * What the child already owes, typed off the school's paper.
 *
 * ONE EDITOR, THREE SCREENS. Quick Add shows it inline, the class grid opens it
 * per row, and the child's own page opens it for a child already entered. The
 * rules (lib/dues.ts) and the shape it hands back are the same everywhere, so a
 * due typed in one place cannot mean something else in another.
 *
 * MONTHS ARE TICKED, NOT TYPED. A school's register says "owes July, August,
 * September" far more often than it lists three different sums, so ticking a
 * month fills in this class's monthly fee and the clerk only types where the
 * amount differs. The list can be narrowed to this school year, the last year,
 * all three years, or one month picked by name, and a month already filled in
 * is never hidden by the narrowing: it is listed under the box instead.
 *
 * NAMED DUES ARE CHIPS. Admission fee, stationery, books and the rest add a line
 * with the name filled in; "Something else" adds a line whose name the school
 * types, which is the blank box for whatever the paper calls it.
 */
import { useEffect, useMemo, useRef, useState, type ReactNode } from 'react'
import { fmtAmount, fmtMonth } from '@/lib/format'
import {
  NAMED_DUES, checkDues, dueMonths, duesSummary, newNamed, parseAmount,
  type DuesDraft, type NamedKind,
} from '@/lib/dues'
import { IconPlus, IconTrash, IconAlert } from '@/components/icons'

const BOX =
  'rounded-lg border border-slate-300 bg-white px-2.5 py-1.5 text-sm text-slate-900 outline-none transition placeholder:text-slate-400 focus:border-brand-500 focus:ring-2 focus:ring-brand-100'

type View = 'year' | '12' | 'all' | 'one'

export function DuesEditor({
  value, onChange, sessionStart, monthlyFee, idPrefix = 'dues',
}: {
  value: DuesDraft
  onChange: (d: DuesDraft) => void
  /** The current school year's first day, to mark last year's months. */
  sessionStart: string | null
  /** This class's monthly fee now, which a ticked month is filled with. */
  monthlyFee?: number | null
  idPrefix?: string
}) {
  const all = useMemo(() => dueMonths(), [])
  const startMonth = sessionStart ? `${sessionStart.slice(0, 7)}-01` : null
  const thisYear = useMemo(
    () => (startMonth ? all.filter((m) => m >= startMonth) : []),
    [all, startMonth],
  )
  const [view, setView] = useState<View>(() => (thisYear.length > 0 ? 'year' : '12'))
  const [one, setOne] = useState<string>(() => all[0])

  const shown = view === 'year' ? thisYear
    : view === '12' ? all.slice(0, 12)
      : view === 'all' ? all
        : [one]

  const check = useMemo(() => checkDues(value, fmtMonth), [value])
  const filled = Object.entries(value.months).filter(([, v]) => (v ?? '').trim() !== '')
  const hiddenFilled = filled.filter(([m]) => !shown.includes(m)).map(([m]) => m).sort()

  /** What a ticked month is filled with: the class fee, else the last amount typed. */
  const lastTyped = filled.length > 0 ? filled[filled.length - 1][1] : ''
  const fill = monthlyFee && monthlyFee > 0 ? String(monthlyFee) : lastTyped

  const amountRefs = useRef<Map<string, HTMLInputElement>>(new Map())

  function setMonth(m: string, v: string) {
    const months = { ...value.months }
    if (v === '') delete months[m]
    else months[m] = v
    onChange({ ...value, months })
  }

  function toggle(m: string, on: boolean) {
    if (!on) { setMonth(m, ''); return }
    setMonth(m, fill)
    requestAnimationFrame(() => {
      const el = amountRefs.current.get(m)
      el?.focus()
      el?.select()
    })
  }

  function tickShown() {
    if (!fill) return
    const months = { ...value.months }
    for (const m of shown) if (!(months[m] ?? '').trim()) months[m] = fill
    onChange({ ...value, months })
  }

  function clearMonths() {
    onChange({ ...value, months: {} })
  }

  function addNamed(kind: NamedKind) {
    const line = newNamed(kind)
    onChange({ ...value, named: [...value.named, line] })
    requestAnimationFrame(() => {
      document.getElementById(`${idPrefix}-${line.key}-${kind === 'other' ? 'label' : 'amount'}`)?.focus()
    })
  }

  function setNamed(key: string, patch: Partial<{ label: string; amount: string }>) {
    onChange({
      ...value,
      named: value.named.map((n) => (n.key === key ? { ...n, ...patch } : n)),
    })
  }

  function removeNamed(key: string) {
    onChange({ ...value, named: value.named.filter((n) => n.key !== key) })
  }

  const views: { v: View; label: string; hide?: boolean }[] = [
    { v: 'year', label: 'This school year', hide: thisYear.length === 0 },
    { v: '12', label: 'Last 12 months' },
    { v: 'all', label: 'Last 3 years' },
    { v: 'one', label: 'One month' },
  ]

  return (
    <div className="space-y-4">
      {/* ---------------------------------------------------- the months -- */}
      <section aria-labelledby={`${idPrefix}-months`}>
        <div className="flex flex-wrap items-baseline justify-between gap-x-3 gap-y-1">
          <h4 id={`${idPrefix}-months`} className="text-sm font-medium text-slate-800">
            Unpaid monthly fee
          </h4>
          {monthlyFee != null && monthlyFee > 0 && (
            <span className="text-xs text-slate-500">
              This class pays Rs {fmtAmount(monthlyFee)} a month; a ticked month is filled with it.
            </span>
          )}
        </div>

        <div className="mt-2 flex flex-wrap items-center gap-1.5" role="group" aria-label="Which months to show">
          {views.filter((x) => !x.hide).map((x) => (
            <button
              key={x.v} type="button" aria-pressed={view === x.v}
              onClick={() => setView(x.v)}
              className={`rounded-full px-2.5 py-1 text-xs font-medium ring-1 transition ${
                view === x.v
                  ? 'bg-brand-600 text-white ring-brand-600'
                  : 'bg-white text-slate-600 ring-slate-200 hover:bg-slate-50'}`}
            >
              {x.label}
            </button>
          ))}
          {view === 'one' && (
            <select
              value={one} onChange={(e) => setOne(e.target.value)}
              aria-label="The month" className={`${BOX} py-1 text-xs`}
            >
              {all.map((m) => <option key={m} value={m}>{fmtMonth(m)}</option>)}
            </select>
          )}
        </div>

        <ul className="mt-2 max-h-72 divide-y divide-slate-100 overflow-y-auto rounded-lg border border-slate-200">
          {shown.map((m) => {
            const v = value.months[m] ?? ''
            const on = v.trim() !== ''
            const bad = on && Number.isNaN(parseAmount(v) ?? 0)
            const lastYear = startMonth !== null && m < startMonth
            return (
              <li key={m} className={`flex items-center gap-2 px-2.5 py-1.5 sm:px-3 ${on ? 'bg-due-50/50' : ''}`}>
                <input
                  id={`${idPrefix}-m-${m}`} type="checkbox" checked={on}
                  onChange={(e) => toggle(m, e.target.checked)}
                  className="h-4 w-4 shrink-0 accent-brand-600"
                />
                <label htmlFor={`${idPrefix}-m-${m}`} className="min-w-0 flex-1 cursor-pointer text-sm text-slate-700">
                  {fmtMonth(m)}
                  {lastYear && <span className="ml-1.5 text-xs text-slate-400">last year</span>}
                </label>
                <span className="shrink-0 text-xs text-slate-400" aria-hidden="true">Rs</span>
                <input
                  ref={(el) => { if (el) amountRefs.current.set(m, el); else amountRefs.current.delete(m) }}
                  value={v} inputMode="decimal" placeholder="0"
                  aria-label={`Amount owed for ${fmtMonth(m)}`}
                  aria-invalid={bad || undefined}
                  onChange={(e) => setMonth(m, e.target.value)}
                  className={`${BOX} w-24 shrink-0 text-right tabular-nums sm:w-28 ${bad ? 'border-danger-500' : ''}`}
                />
              </li>
            )
          })}
        </ul>

        <div className="mt-1.5 flex flex-wrap items-center gap-x-3 gap-y-1 text-xs">
          <button type="button" onClick={tickShown} disabled={!fill}
            className="font-medium text-brand-700 hover:underline disabled:cursor-not-allowed disabled:text-slate-400 disabled:no-underline">
            Tick every month shown
          </button>
          {filled.length > 0 && (
            <button type="button" onClick={clearMonths} className="text-slate-500 hover:underline">
              Clear the months
            </button>
          )}
          {!fill && (
            <span className="text-slate-400">Type one amount first, and ticking fills the rest with it.</span>
          )}
        </div>
        {hiddenFilled.length > 0 && (
          <p className="mt-1.5 rounded-lg bg-slate-100 px-2.5 py-1.5 text-xs text-slate-600">
            Also owed, outside this view: {hiddenFilled.map((m) => `${fmtMonth(m)} (Rs ${value.months[m]})`).join(', ')}.
          </p>
        )}
      </section>

      {/* ------------------------------------------------ the named dues -- */}
      <section aria-labelledby={`${idPrefix}-named`}>
        <h4 id={`${idPrefix}-named`} className="text-sm font-medium text-slate-800">Other dues</h4>
        <div className="mt-2 flex flex-wrap gap-1.5">
          {NAMED_DUES.map((d) => (
            <button
              key={d.kind} type="button" onClick={() => addNamed(d.kind)}
              className="inline-flex items-center gap-1 rounded-full bg-white px-2.5 py-1 text-xs font-medium text-slate-700 ring-1 ring-slate-200 transition hover:bg-slate-50"
            >
              <IconPlus />{d.label}
            </button>
          ))}
        </div>

        {value.named.length > 0 && (
          <ul className="mt-2 space-y-2">
            {value.named.map((n) => {
              const preset = NAMED_DUES.find((x) => x.kind === n.kind)
              return (
                <li key={n.key} className="flex flex-wrap items-center gap-2 rounded-lg border border-slate-200 p-2 sm:flex-nowrap">
                  <input
                    id={`${idPrefix}-${n.key}-label`}
                    value={n.label} maxLength={80}
                    onChange={(e) => setNamed(n.key, { label: e.target.value })}
                    placeholder={n.kind === 'other' ? 'What is it for? Picnic, lab charges, a fine…' : preset?.label}
                    aria-label={n.kind === 'other' ? 'What this due is for' : `Name of the ${preset?.label ?? 'due'}`}
                    className={`${BOX} min-w-0 flex-1 basis-full sm:basis-auto`}
                  />
                  <span className="text-xs text-slate-400" aria-hidden="true">Rs</span>
                  <input
                    id={`${idPrefix}-${n.key}-amount`}
                    value={n.amount} inputMode="decimal" placeholder="0"
                    onChange={(e) => setNamed(n.key, { amount: e.target.value })}
                    aria-label={`Amount owed for ${n.label || preset?.label || 'this due'}`}
                    className={`${BOX} w-28 text-right tabular-nums`}
                  />
                  <button
                    type="button" onClick={() => removeNamed(n.key)}
                    aria-label={`Remove ${n.label || preset?.label || 'this due'}`}
                    className="ml-auto rounded p-1.5 text-slate-400 hover:bg-slate-100 hover:text-danger-600 sm:ml-0"
                  >
                    <IconTrash />
                  </button>
                </li>
              )
            })}
          </ul>
        )}
      </section>

      {/* ------------------------------------------------------ the total -- */}
      <div className="rounded-lg bg-slate-50 px-3 py-2 text-sm" aria-live="polite">
        {check.total > 0 ? (
          <span className="text-slate-700">
            Previous dues: <span className="font-semibold tabular-nums text-due-800">{duesSummary(check)}</span>
          </span>
        ) : (
          <span className="text-slate-500">No previous dues entered.</span>
        )}
        {check.problems.length > 0 && (
          <ul className="mt-1.5 space-y-0.5 text-xs text-danger-700">
            {check.problems.map((p) => (
              <li key={p} className="flex items-start gap-1"><IconAlert />{p}</li>
            ))}
          </ul>
        )}
      </div>
    </div>
  )
}

/**
 * The editor in a dialog, for the class grid (one row's dues) and the child's
 * own page (a child already entered). Escape and Cancel leave without saving;
 * nothing is sent until the confirm button.
 */
export function DuesDialog({
  title, intro, initial, sessionStart, monthlyFee, confirmLabel, busy, error,
  onCancel, onSubmit, footer,
}: {
  title: string
  intro?: ReactNode
  initial: DuesDraft
  sessionStart: string | null
  monthlyFee?: number | null
  confirmLabel: string
  busy?: boolean
  error?: string | null
  onCancel: () => void
  onSubmit: (d: DuesDraft) => void
  footer?: ReactNode
}) {
  const [draft, setDraft] = useState<DuesDraft>(initial)
  const check = useMemo(() => checkDues(draft, fmtMonth), [draft])
  const panel = useRef<HTMLDivElement>(null)

  useEffect(() => {
    const prev = document.activeElement as HTMLElement | null
    panel.current?.querySelector<HTMLElement>('button, input, select')?.focus()
    function onKey(e: KeyboardEvent) { if (e.key === 'Escape') onCancel() }
    document.addEventListener('keydown', onKey)
    return () => {
      document.removeEventListener('keydown', onKey)
      prev?.focus?.()
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [])

  return (
    <div
      className="fixed inset-0 z-50 flex items-start justify-center overflow-y-auto bg-slate-900/40 p-2 sm:items-center sm:p-4"
      role="dialog" aria-modal="true" aria-label={title}
    >
      <div ref={panel} className="w-full max-w-xl rounded-xl bg-white p-3 shadow-xl sm:p-5">
        <h3 className="text-base font-semibold text-slate-900">{title}</h3>
        {intro && <div className="mt-1 text-sm text-slate-600">{intro}</div>}
        <div className="mt-3">
          <DuesEditor value={draft} onChange={setDraft} sessionStart={sessionStart}
            monthlyFee={monthlyFee} idPrefix="dlg" />
        </div>
        {error && (
          <p className="mt-3 flex items-start gap-1.5 text-sm text-danger-700"><IconAlert />{error}</p>
        )}
        {footer}
        {/* Kept in reach on a phone, where the list runs past the bottom of the screen. */}
        <div className="sticky bottom-0 -mx-3 mt-4 flex flex-wrap justify-end gap-2 border-t border-slate-100 bg-white px-3 py-2 sm:static sm:mx-0 sm:border-0 sm:p-0">
          <button type="button" onClick={onCancel}
            className="rounded-lg px-3.5 py-2 text-sm font-medium text-slate-600 hover:bg-slate-100">
            Cancel
          </button>
          <button
            type="button" disabled={busy || check.problems.length > 0}
            onClick={() => onSubmit(draft)}
            className="rounded-lg bg-brand-600 px-3.5 py-2 text-sm font-medium text-white shadow-card hover:brightness-110 disabled:cursor-not-allowed disabled:opacity-50"
          >
            {busy ? 'Saving…' : confirmLabel}
          </button>
        </div>
      </div>
    </div>
  )
}

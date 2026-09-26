import { useEffect, useRef, type ReactNode } from 'react'
import { useLocation, useNavigate } from 'react-router-dom'
import { useIsDesktop } from '@/hooks/useIsDesktop'

/**
 * A module with many screens: Reports (eighteen) and Settings (fourteen).
 *
 * WIDE SCREENS get a rail down the left, grouped by the kind of question each
 * screen answers, and the chosen screen beside it.
 *
 * PHONES AND TABLETS get what a phone's own Settings app does: the grouped list
 * of screens, each with the one sentence that says what it is for, and a tap
 * opens that screen full width with "‹ All settings" above it. The phone's
 * own Back button returns to the list too. This replaced a dropdown at the top
 * of every screen: fourteen names in a native picker, no sentence to say which
 * one does what, and the chosen screen's first field pushed below the fold by
 * the picker itself.
 */
export interface SectionItem<K extends string> {
  key: K
  label: string
  /** One sentence: what this screen is for. */
  ask?: string
}
export interface SectionGroup<K extends string> {
  title: string
  items: readonly SectionItem<K>[]
}

export function SectionLayout<K extends string>({
  groups, value, onChange, label, children, hideHeader = false, picked, onPick, onIndex, indexLabel,
}: {
  groups: readonly SectionGroup<K>[]
  value: K
  onChange: (k: K) => void
  /** What the list switches between, for a screen reader: "Reports". */
  label: string
  children: ReactNode
  hideHeader?: boolean
  /** Whether the address names a screen. On a phone, no screen named means
   *  the list. Omitted, the phone shows the chosen screen as before. */
  picked?: boolean
  /** A phone opening a screen from the list. */
  onPick?: (k: K) => void
  /** Back to the list. */
  onIndex?: () => void
  /** "All settings" */
  indexLabel?: string
}) {
  const wide = useIsDesktop()
  const location = useLocation()
  const navigate = useNavigate()
  const top = useRef<HTMLDivElement>(null)
  const items = groups.flatMap((g) => g.items)
  const item = items.find((i) => i.key === value) ?? items[0]
  const phoneList = !wide && picked === false

  // A new screen on a phone starts at its top, not wherever the list was
  // scrolled to.
  const first = useRef(true)
  useEffect(() => {
    if (first.current) { first.current = false; return }
    const el = top.current
    if (!wide && el && typeof el.scrollIntoView === 'function') el.scrollIntoView({ block: 'start' })
  }, [value, phoneList, wide])

  function back() {
    // Came from the list in this visit: step back, so the history stays tidy.
    // Arrived from a link (the dashboard's "Open Year Rollover"): there is no
    // list behind it, so go to the list.
    if ((location.state as { fromIndex?: boolean } | null)?.fromIndex) navigate(-1)
    else onIndex?.()
  }

  if (phoneList) {
    return (
      <div ref={top} className="mt-4 scroll-mt-4 space-y-5 print:hidden">
        {groups.map((g) => (
          <section key={g.title} aria-label={g.title}>
            <h2 className="px-1 text-[11px] font-semibold uppercase tracking-wide text-slate-500">{g.title}</h2>
            <ul className="mt-1.5 divide-y divide-slate-100 overflow-hidden rounded-2xl border border-slate-200 bg-white shadow-card">
              {g.items.map((i) => (
                <li key={i.key}>
                  <button type="button" onClick={() => (onPick ?? onChange)(i.key)}
                    className="flex w-full items-center gap-3 px-4 py-3.5 text-left transition hover:bg-brand-50 active:bg-brand-100"
                    style={{ touchAction: 'manipulation' }}>
                    <span className="min-w-0 flex-1">
                      <span className="block text-sm font-medium text-slate-900">{i.label}</span>
                      {i.ask && <span className="mt-0.5 block text-xs leading-snug text-slate-500">{i.ask}</span>}
                    </span>
                    <span className="flex h-7 w-7 shrink-0 items-center justify-center rounded-full bg-brand-50 text-brand-600" aria-hidden="true">
                      <svg viewBox="0 0 20 20" className="h-4 w-4" fill="none" stroke="currentColor" strokeWidth="2.25"><path d="m7 4 6 6-6 6" /></svg>
                    </span>
                  </button>
                </li>
              ))}
            </ul>
          </section>
        ))}
      </div>
    )
  }

  return (
    <div ref={top} className="mt-4 scroll-mt-4 lg:grid lg:grid-cols-[14rem,minmax(0,1fr)] lg:gap-6">
      {/* THE RAIL IS A MENU OF BUTTONS. It was plain words down the left, and
          schools read the list as a table of contents rather than something to
          press. Each group is now a card, each screen a full-width row that
          lights up under the pointer, and the open one is solid. */}
      <nav aria-label={label} className="hidden lg:block print:hidden">
        <div className="sticky top-4 space-y-3">
          {groups.map((g) => (
            <div key={g.title} className="rounded-2xl border border-slate-200 bg-white p-1.5 shadow-card">
              <div className="px-2.5 pb-1 pt-1.5 text-[11px] font-semibold uppercase tracking-wide text-slate-500">{g.title}</div>
              <ul className="space-y-0.5">
                {g.items.map((i) => {
                  const on = i.key === value
                  return (
                    <li key={i.key}>
                      <button type="button" onClick={() => onChange(i.key)} aria-current={on ? 'page' : undefined}
                        className={`group flex w-full items-center justify-between gap-2 rounded-xl px-2.5 py-2 text-left text-sm font-medium transition focus:outline-none focus-visible:ring-2 focus-visible:ring-brand-500 ${
                          on ? 'bg-brand-600 text-white shadow-sm'
                            : 'text-slate-700 hover:bg-brand-50 hover:text-brand-800'}`}>
                        <span className="truncate">{i.label}</span>
                        <svg viewBox="0 0 20 20" className={`h-3.5 w-3.5 shrink-0 ${on ? 'text-white/80' : 'text-slate-300 group-hover:text-brand-500'}`}
                          fill="none" stroke="currentColor" strokeWidth="2.25" aria-hidden="true"><path d="m7 4 6 6-6 6" /></svg>
                      </button>
                    </li>
                  )
                })}
              </ul>
            </div>
          ))}
        </div>
      </nav>

      <div className="min-w-0">
        {/* Below lg: the way back to the list, where the rail would be. */}
        {!wide && picked !== undefined && (
          <button type="button" onClick={back}
            className="mb-3 inline-flex items-center gap-1 rounded-full bg-white px-3 py-1.5 text-sm font-medium text-brand-700 shadow-sm ring-1 ring-brand-200 hover:bg-brand-50 print:hidden">
            <svg viewBox="0 0 20 20" className="h-4 w-4" fill="none" stroke="currentColor" strokeWidth="2" aria-hidden="true"><path d="m13 4-6 6 6 6" /></svg>
            {indexLabel ?? 'All'}
          </button>
        )}

        {!hideHeader && item && (
          <div className="mb-4 print:hidden">
            <h2 className="text-lg font-semibold text-slate-900">{item.label}</h2>
            {item.ask && <p className="text-sm text-slate-500">{item.ask}</p>}
          </div>
        )}
        {children}
      </div>
    </div>
  )
}

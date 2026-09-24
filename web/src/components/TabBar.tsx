import { useEffect, useRef, type ReactNode } from 'react'

/**
 * The tab row every multi-tab module uses (Fees, Accounts, Exams).
 *
 * WHY THIS EXISTS. Fees and Accounts each hand-rolled the same row with
 * `overflow-x-auto` on the strip and `-mb-px` on each tab so the active
 * underline sat on the strip's border. `overflow-x-auto` makes the other axis
 * scroll too, and the 1px each tab hung below the strip was exactly enough to
 * give Windows a VERTICAL scrollbar: two little arrows under the tab names on
 * every screen of the module, visible in the screenshots the school sent.
 *
 * So there is no negative margin here. The strip draws its hairline as an inset
 * shadow and the active tab draws its underline the same way, both inside their
 * own boxes, and the strip clips vertically. Nothing can overflow downwards.
 *
 * ON A PHONE THE ROW SCROLLS SIDEWAYS with its scrollbar hidden, rather than
 * turning into a <select>: the fee counter flips between Collect and Pending
 * all day, and a count badge ("Pending 3") has to be visible without opening
 * anything. Each label appears once in the page, so a test or a screen reader
 * finding "Pending" finds one thing.
 */
export interface TabDef<K extends string> {
  key: K
  label: string
  /** A count shown beside the label: something is waiting here. */
  count?: number | null
  /** Amber for work waiting, grey for a plain count. */
  countTone?: 'due' | 'neutral'
  icon?: ReactNode
}

export function TabBar<K extends string>({
  tabs, value, onChange, label, className = '',
}: {
  tabs: TabDef<K>[]
  value: K
  onChange: (k: K) => void
  /** What the row switches between, for a screen reader. */
  label: string
  className?: string
}) {
  // The active tab is scrolled into the strip. On a phone a link to
  // /exams?tab=results opened with Setup, Streams and Marks Entry showing and
  // the tab that was actually open hidden off the right edge. Only the strip
  // scrolls, never the page.
  const strip = useRef<HTMLElement>(null)
  useEffect(() => {
    const el = strip.current
    const on = el?.querySelector<HTMLElement>('[aria-current="page"]')
    if (!el || !on) return
    const left = on.offsetLeft - el.offsetLeft
    if (left < el.scrollLeft || left + on.offsetWidth > el.scrollLeft + el.clientWidth) {
      el.scrollLeft = Math.max(0, left - 16)
    }
  }, [value])
  return (
    <nav
      ref={strip}
      aria-label={label}
      className={`mb-5 flex gap-1 overflow-x-auto overflow-y-hidden shadow-[inset_0_-1px_0_#e2e8f0] [scrollbar-width:none] [&::-webkit-scrollbar]:hidden ${className}`}
    >
      {tabs.map((t) => {
        const on = t.key === value
        return (
          <button
            key={t.key}
            type="button"
            onClick={() => onChange(t.key)}
            aria-current={on ? 'page' : undefined}
            className={`flex shrink-0 items-center gap-1.5 whitespace-nowrap px-3 py-2.5 text-sm transition sm:px-4 ${
              on
                ? 'font-semibold text-brand-700 shadow-[inset_0_-2px_0_#4f46e5]'
                : 'text-slate-500 hover:text-slate-800 hover:shadow-[inset_0_-2px_0_#cbd5e1]'
            }`}
          >
            {t.icon && <span className="shrink-0" aria-hidden>{t.icon}</span>}
            {t.label}
            {t.count != null && t.count > 0 && (
              <span
                className={`rounded-full px-1.5 py-px text-[11px] font-semibold tabular-nums ${
                  t.countTone === 'neutral' ? 'bg-slate-100 text-slate-600' : 'bg-due-100 text-due-800'
                }`}
                aria-label={`${t.count} waiting`}
              >
                {t.count}
              </span>
            )}
          </button>
        )
      })}
    </nav>
  )
}

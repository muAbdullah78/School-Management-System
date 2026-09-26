import type { ReactNode } from 'react'

/**
 * The row of screens inside a module (Fees, Staff, Exams, Accounts, Attendance,
 * a pupil's profile, Enquiries).
 *
 * THEY ARE BUTTONS AND NOW LOOK IT. The row used to be plain words with a thin
 * underline under the open one, and schools read it as a heading: "Bulk
 * collect" and "Deposits" were pressed by nobody who had not been shown. Each
 * screen is now a pill with a border and a fill: the open one solid in the
 * brand colour, the others white with an outline that darkens under a finger
 * or a pointer.
 *
 * THE ROW WRAPS, ON A PHONE TOO. It used to scroll sideways with its scrollbar
 * hidden, and on a phone that hid "Pending 43" off the right edge: the one
 * badge that says work is waiting was the one nobody could see. Seven pills
 * wrap into three short rows, and every screen of the module, with its count,
 * is in sight without knowing to swipe.
 *
 * Each label appears once in the page, so a test or a screen reader finding
 * "Pending" finds one thing.
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
  return (
    <nav aria-label={label} className={`mb-5 flex flex-wrap gap-2 print:hidden ${className}`}>
      {tabs.map((t) => {
        const on = t.key === value
        return (
          <button
            key={t.key}
            type="button"
            onClick={() => onChange(t.key)}
            aria-current={on ? 'page' : undefined}
            className={`inline-flex items-center gap-1.5 whitespace-nowrap rounded-full px-3.5 py-2 text-sm sm:px-4 font-medium ring-1 transition focus:outline-none focus-visible:ring-2 focus-visible:ring-brand-500 focus-visible:ring-offset-1 active:scale-[0.98] ${
              on
                ? 'bg-brand-600 text-white shadow-sm ring-brand-600'
                : 'bg-white text-slate-700 shadow-sm ring-slate-200 hover:bg-brand-50 hover:text-brand-800 hover:ring-brand-300'
            }`}
            style={{ touchAction: 'manipulation' }}
          >
            {t.icon && <span className="shrink-0" aria-hidden>{t.icon}</span>}
            {t.label}
            {t.count != null && t.count > 0 && (
              <span
                className={`rounded-full px-1.5 py-px text-[11px] font-semibold tabular-nums ${
                  on ? 'bg-white/25 text-white'
                    : t.countTone === 'neutral' ? 'bg-slate-100 text-slate-600' : 'bg-due-100 text-due-800'
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

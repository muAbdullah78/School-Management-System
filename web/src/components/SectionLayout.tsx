import type { ReactNode } from 'react'
import { inputClass } from '@/components/ui'

/**
 * A module with many screens: Reports (nineteen) and Settings (fourteen).
 *
 * Both used to be one flat row of tabs that wrapped into two rows, in the order
 * the screens happened to be written, so Balance Sheet sat between Children Who
 * Left and Mark Changes and Backup was the fourteenth thing to read along. On a
 * wide screen the screens now sit in a rail, grouped by the kind of question
 * they answer. On a phone and a tablet they are one grouped list, because a
 * wall of wrapped tabs pushed the first field below the fold.
 *
 * Each screen carries one sentence saying what it is for, shown under its name.
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
  groups, value, onChange, label, children, hideHeader = false,
}: {
  groups: readonly SectionGroup<K>[]
  value: K
  onChange: (k: K) => void
  /** What the list switches between, for a screen reader: "Reports". */
  label: string
  children: ReactNode
  hideHeader?: boolean
}) {
  const items = groups.flatMap((g) => g.items)
  const item = items.find((i) => i.key === value) ?? items[0]
  return (
    <div className="mt-4 lg:grid lg:grid-cols-[14rem,minmax(0,1fr)] lg:gap-6">
      <nav aria-label={label} className="hidden lg:block print:hidden">
        <div className="sticky top-4 space-y-4">
          {groups.map((g) => (
            <div key={g.title}>
              <div className="px-3 text-[11px] font-semibold uppercase tracking-wide text-slate-400">{g.title}</div>
              <ul className="mt-1 space-y-0.5">
                {g.items.map((i) => {
                  const on = i.key === value
                  return (
                    <li key={i.key}>
                      <button type="button" onClick={() => onChange(i.key)} aria-current={on ? 'page' : undefined}
                        className={`w-full rounded-lg px-3 py-1.5 text-left text-sm transition ${
                          on ? 'bg-brand-50 font-semibold text-brand-800 ring-1 ring-brand-100'
                            : 'text-slate-600 hover:bg-white hover:text-slate-900'}`}>
                        {i.label}
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
        <label className="mb-4 block lg:hidden print:hidden">
          <span className="mb-1 block text-xs font-medium uppercase tracking-wide text-slate-500">{label}</span>
          <select value={value} onChange={(e) => onChange(e.target.value as K)} className={inputClass}>
            {groups.map((g) => (
              <optgroup key={g.title} label={g.title}>
                {g.items.map((i) => <option key={i.key} value={i.key}>{i.label}</option>)}
              </optgroup>
            ))}
          </select>
        </label>

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

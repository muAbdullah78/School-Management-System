/**
 * "Search a module…" in the sidebar.
 *
 * Their sidebar has one, and with twenty-odd modules it is how staff actually
 * navigate — faster than reading the list, and it survives the list growing.
 *
 * Entirely client-side over the nav items the current user can already see, so
 * it cannot reveal a module their role does not have: the filtering happens over
 * `visibleNav(role)`, not over the full list.
 */
import { useState } from 'react'
import type { NavItem } from '@/navigation'

export function ModuleSearch({
  items, onFilter,
}: {
  items: NavItem[]
  onFilter: (filtered: NavItem[]) => void
}) {
  const [term, setTerm] = useState('')

  function apply(next: string) {
    setTerm(next)
    const t = next.trim().toLowerCase()
    if (!t) { onFilter(items); return }
    onFilter(items.filter((i) =>
      i.label.toLowerCase().includes(t) ||
      // The blurb is searched too, so "voucher" finds Fees and "leaving"
      // finds Certificates without the user knowing our names for things.
      i.blurb.toLowerCase().includes(t) ||
      i.path.toLowerCase().includes(t)))
  }

  return (
    <div className="px-2 pb-1 pt-2 print:hidden">
      <input
        value={term}
        onChange={(e) => apply(e.target.value)}
        placeholder="Search a module…"
        aria-label="Search modules"
        className="w-full rounded-lg border border-white/10 bg-white/5 px-3 py-1.5 text-sm text-white placeholder:text-brand-200/50 focus:border-white/25 focus:bg-white/10 focus:outline-none"
      />
    </div>
  )
}

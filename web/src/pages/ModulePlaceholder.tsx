import { useLocation } from 'react-router-dom'
import { NAV } from '@/navigation'

/** Generic placeholder for modules not yet built (Phase 0). */
export function ModulePlaceholder() {
  const { pathname } = useLocation()
  const item = NAV.find((n) => n.path === pathname)

  return (
    <div>
      <h1 className="text-xl font-semibold text-slate-800">{item?.label ?? 'Module'}</h1>
      <p className="mt-2 max-w-2xl text-sm text-slate-600">{item?.blurb}</p>
      <div className="mt-5 rounded-lg border border-dashed border-slate-300 bg-white/50 p-5 text-sm text-slate-500">
        This module is scaffolded and scheduled. Its screens are being built phase by phase.
        See <code>docs/05-ROADMAP.md</code> for the order of work.
      </div>
    </div>
  )
}

import { useAuth } from '@/auth/AuthProvider'
import { ROLE_LABELS } from '@/auth/roles'

/**
 * The owner's daily landing screen. In Phase 0 it shows placeholders for the
 * trust-and-money tiles; these are wired to live data once the Fees and
 * Attendance modules land (see docs/05-ROADMAP.md).
 */
export function Dashboard() {
  const { profile } = useAuth()

  const tiles = [
    { label: "Today's attendance", value: '—', hint: 'wired in Attendance phase' },
    { label: 'Fees collected today', value: '—', hint: 'wired in Fees phase' },
    { label: 'Outstanding / defaulters', value: '—', hint: 'wired in Fees phase' },
    { label: 'Cash in drawer', value: '—', hint: 'wired in Fees phase' },
  ]

  return (
    <div>
      <h1 className="text-xl font-semibold text-slate-800">Dashboard</h1>
      <p className="mt-1 text-sm text-slate-500">
        Signed in as {profile?.full_name ?? 'user'} · {profile ? ROLE_LABELS[profile.role] : ''}
      </p>

      <div className="mt-5 grid grid-cols-1 gap-4 sm:grid-cols-2 lg:grid-cols-4">
        {tiles.map((t) => (
          <div key={t.label} className="rounded-lg bg-white p-4 shadow-sm ring-1 ring-slate-200">
            <div className="text-xs font-medium uppercase tracking-wide text-slate-500">{t.label}</div>
            <div className="mt-2 text-2xl font-semibold text-slate-800">{t.value}</div>
            <div className="mt-1 text-xs text-slate-400">{t.hint}</div>
          </div>
        ))}
      </div>

      <div className="mt-6 rounded-lg border border-dashed border-slate-300 bg-white/50 p-5 text-sm text-slate-600">
        <p className="font-medium text-slate-700">Phase 0 foundation is in place.</p>
        <p className="mt-1">
          Authentication, role-based navigation, the school-branded shell, and the full database schema
          are ready. Modules are being built one by one — see the roadmap in <code>docs/05-ROADMAP.md</code>.
        </p>
      </div>
    </div>
  )
}

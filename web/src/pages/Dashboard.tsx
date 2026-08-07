import { Link } from 'react-router-dom'
import { useQuery } from '@tanstack/react-query'
import { useAuth } from '@/auth/AuthProvider'
import { ROLE_LABELS, isTeacher } from '@/auth/roles'
import { MyClass } from './MyClass'
import { getDashboardSummary } from '@/lib/db'
import { isConfigured } from '@/lib/config'
import { fmtPKR } from '@/lib/format'

function Tile({ label, value, hint, tone = 'default', to }: {
  label: string; value: string; hint?: string; tone?: 'default' | 'warn' | 'good'; to?: string
}) {
  const toneCls = tone === 'warn' ? 'text-amber-600' : tone === 'good' ? 'text-emerald-600' : 'text-slate-800'
  const body = (
    <div className="h-full rounded-lg bg-white p-4 shadow-sm ring-1 ring-slate-200 transition hover:ring-brand-300">
      <div className="text-xs font-medium uppercase tracking-wide text-slate-500">{label}</div>
      <div className={`mt-2 text-2xl font-semibold ${toneCls}`}>{value}</div>
      {hint && <div className="mt-1 text-xs text-slate-400">{hint}</div>}
    </div>
  )
  return to ? <Link to={to} className="block">{body}</Link> : body
}

export function Dashboard() {
  const { profile } = useAuth()
  const configured = isConfigured
  const isTeach = isTeacher(profile?.role)
  const summary = useQuery({ queryKey: ['dashboardSummary'], queryFn: getDashboardSummary, enabled: configured && !isTeach })

  // Teachers get a class-focused home instead of the admin dashboard.
  if (isTeach) return <MyClass />

  const d = summary.data
  const att = d?.attendance
  const pct = att && att.marked > 0 ? Math.round(((att.present + att.half_day) / att.marked) * 100) : null

  return (
    <div>
      <h1 className="text-xl font-semibold text-slate-800">Dashboard</h1>
      <p className="mt-1 text-sm text-slate-500">
        Signed in as {profile?.full_name ?? 'user'} · {profile ? ROLE_LABELS[profile.role] : ''}
      </p>

      {!configured && (
        <div className="mt-5 rounded-lg border border-dashed border-slate-300 bg-white/50 p-5 text-sm text-slate-600">
          Supabase isn’t configured yet, so live figures are unavailable. Set the connection details to see today’s numbers.
        </div>
      )}

      {configured && (
        <>
          {summary.isError && (
            <div className="mt-5 rounded-lg border border-red-200 bg-red-50 p-4 text-sm text-red-700">
              Couldn’t load today’s figures: {(summary.error as Error).message}
            </div>
          )}

          <div className="mt-5 grid grid-cols-1 gap-4 sm:grid-cols-2 lg:grid-cols-4">
            <Tile
              label="Today's attendance"
              value={summary.isLoading ? '…' : att && att.marked > 0 ? `${pct}%` : '—'}
              hint={att && att.marked > 0
                ? `${att.present + att.half_day} present of ${att.marked} marked · ${att.absent} absent`
                : 'Not marked yet today'}
              tone={pct !== null && pct < 75 ? 'warn' : 'default'}
              to="/attendance"
            />
            <Tile
              label="Active students"
              value={summary.isLoading ? '…' : String(d?.active_students ?? '—')}
              hint={d ? `${d.new_admissions_month} admitted this month` : undefined}
              to="/students"
            />
            {d?.finance_visible && (
              <>
                <Tile
                  label="Fees collected today"
                  value={summary.isLoading ? '…' : fmtPKR(d?.collected_today)}
                  hint={d ? `${fmtPKR(d.collected_month)} this month` : undefined}
                  tone="good"
                  to="/fees"
                />
                <Tile
                  label="Outstanding / defaulters"
                  value={summary.isLoading ? '…' : fmtPKR(d?.outstanding)}
                  hint={d ? `${d.defaulters ?? 0} student${d.defaulters === 1 ? '' : 's'} with dues` : undefined}
                  tone={(d?.outstanding ?? 0) > 0 ? 'warn' : 'default'}
                  to="/fees"
                />
              </>
            )}
          </div>

          {d && !d.finance_visible && (
            <p className="mt-4 text-xs text-slate-400">Fee figures are visible to admin and accounts staff.</p>
          )}
        </>
      )}
    </div>
  )
}

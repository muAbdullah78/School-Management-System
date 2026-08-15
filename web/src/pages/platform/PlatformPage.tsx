import { useMemo, useState } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useAuth } from '@/auth/AuthProvider'
import {
  activateSubscription, actionNeeded, amPlatformAdmin, extendTrial, listPlans,
  listPlatformSchools, refreshAllCounts, sortByAction,
  type PlatformSchool,
} from '@/lib/platform'
import { formatPkr } from '@/lib/licence'

const STATUS_STYLE: Record<PlatformSchool['status'], string> = {
  trialing: 'bg-sky-100 text-sky-800',
  active: 'bg-emerald-100 text-emerald-800',
  grace: 'bg-amber-100 text-amber-800',
  locked: 'bg-red-100 text-red-800',
  cancelled: 'bg-slate-200 text-slate-700',
}

/**
 * The product owner's console: every school, what they owe, and what needs
 * doing today.
 *
 * Ordered by what needs action rather than alphabetically — the whole point is
 * to answer "who do I call this morning?" without reading the list.
 */
export function PlatformPage() {
  const { signOut, session } = useAuth()
  const qc = useQueryClient()
  const [msg, setMsg] = useState<string | null>(null)
  const [err, setErr] = useState<string | null>(null)

  const isAdmin = useQuery({ queryKey: ['amPlatformAdmin', session?.user?.id], queryFn: amPlatformAdmin })
  const schools = useQuery({
    queryKey: ['platformSchools'], queryFn: listPlatformSchools, enabled: isAdmin.data === true,
  })
  const plans = useQuery({ queryKey: ['plans'], queryFn: listPlans, enabled: isAdmin.data === true })

  const rows = useMemo(() => sortByAction(schools.data ?? []), [schools.data])

  const act = useMutation({
    mutationFn: async (fn: () => Promise<unknown>) => fn(),
    onSuccess: () => { void qc.invalidateQueries({ queryKey: ['platformSchools'] }) },
    onError: (e) => setErr((e as Error).message),
  })

  function run(label: string, fn: () => Promise<unknown>) {
    setErr(null); setMsg(null)
    act.mutate(fn, { onSuccess: () => setMsg(label) })
  }

  if (isAdmin.isLoading) return <div className="p-8 text-slate-500">Loading…</div>

  if (isAdmin.data !== true) {
    return (
      <div className="flex min-h-full items-center justify-center bg-slate-100 p-4">
        <div className="w-full max-w-sm rounded-lg bg-white p-6 text-center shadow">
          <h1 className="text-lg font-semibold text-slate-800">Not available</h1>
          <p className="mt-2 text-sm text-slate-600">This area is for the system operator.</p>
          <button onClick={() => void signOut()} className="mt-4 text-sm text-brand-700 hover:underline">
            Sign out
          </button>
        </div>
      </div>
    )
  }

  const counts = {
    total: rows.length,
    paying: rows.filter((s) => s.status === 'active').length,
    trial: rows.filter((s) => s.status === 'trialing').length,
    attention: rows.filter((s) => actionNeeded(s) !== null).length,
  }

  return (
    <div className="min-h-full bg-slate-100 p-4">
      <div className="mx-auto max-w-6xl space-y-4">
        <header className="flex flex-wrap items-center justify-between gap-3">
          <div>
            <h1 className="text-lg font-semibold text-slate-800">Schools</h1>
            <p className="text-sm text-slate-500">
              {counts.total} total · {counts.paying} paying · {counts.trial} on trial ·{' '}
              <span className={counts.attention ? 'font-medium text-amber-700' : ''}>
                {counts.attention} need attention
              </span>
            </p>
          </div>
          <div className="flex gap-2">
            <button
              onClick={() => run('Student counts refreshed.', refreshAllCounts)}
              disabled={act.isPending}
              className="rounded border border-slate-300 bg-white px-3 py-1.5 text-sm text-slate-700 hover:bg-slate-50 disabled:opacity-60"
            >
              Refresh counts
            </button>
            <button onClick={() => void signOut()} className="rounded px-3 py-1.5 text-sm text-slate-600 hover:bg-slate-200">
              Sign out
            </button>
          </div>
        </header>

        {msg && <div className="rounded border border-emerald-200 bg-emerald-50 p-2 text-sm text-emerald-800">{msg}</div>}
        {err && <div className="rounded border border-red-200 bg-red-50 p-2 text-sm text-red-700">{err}</div>}

        {schools.isLoading && <div className="text-sm text-slate-500">Loading schools…</div>}
        {schools.error && <div className="text-sm text-red-600">{(schools.error as Error).message}</div>}

        {rows.length === 0 && !schools.isLoading && (
          <div className="rounded-lg border border-slate-200 bg-white p-6 text-center text-sm text-slate-500">
            No schools yet. They appear here as soon as someone signs up.
          </div>
        )}

        <div className="space-y-2">
          {rows.map((s) => {
            const todo = actionNeeded(s)
            return (
              <div key={s.school_id} className="rounded-lg border border-slate-200 bg-white p-3">
                <div className="flex flex-wrap items-start justify-between gap-3">
                  <div className="min-w-0">
                    <div className="flex items-center gap-2">
                      <span className="font-medium text-slate-800">{s.school_name}</span>
                      <span className={`rounded px-1.5 py-0.5 text-xs font-medium ${STATUS_STYLE[s.status]}`}>
                        {s.status}
                      </span>
                    </div>
                    <div className="mt-0.5 text-xs text-slate-500">
                      {[s.city, s.contact_name, s.contact_phone].filter(Boolean).join(' · ') || 'No contact details'}
                    </div>
                    <div className="mt-1 text-sm text-slate-600">
                      {s.student_count.toLocaleString()} students
                      {s.student_limit !== null && <span className="text-slate-400"> / {s.student_limit.toLocaleString()}</span>}
                      {s.limit_state === 'over' && (
                        <span className="ml-2 rounded bg-amber-100 px-1.5 py-0.5 text-xs font-medium text-amber-800">
                          over limit
                        </span>
                      )}
                      {s.limit_state === 'within_margin' && (
                        <span className="ml-2 rounded bg-slate-100 px-1.5 py-0.5 text-xs text-slate-600">
                          in margin
                        </span>
                      )}
                      <span className="ml-2 text-slate-400">
                        {s.plan_code}
                        {s.expires_on && ` · ${s.days_left !== null && s.days_left >= 0
                          ? `${s.days_left}d left`
                          : `expired ${Math.abs(s.days_left ?? 0)}d ago`}`}
                      </span>
                    </div>
                    {todo && <div className="mt-1 text-sm font-medium text-amber-700">{todo}</div>}
                  </div>

                  <SchoolActions
                    school={s}
                    plans={plans.data ?? []}
                    busy={act.isPending}
                    onActivate={(plan, months) =>
                      run(
                        `${s.school_name} activated on ${plan} for ${months} month(s).`,
                        () => activateSubscription(s.school_id, plan, months),
                      )}
                    onExtend={() =>
                      run(`${s.school_name} trial extended by 14 days.`, () => extendTrial(s.school_id, 14))}
                  />
                </div>
              </div>
            )
          })}
        </div>
      </div>
    </div>
  )
}

function SchoolActions({
  school, plans, busy, onActivate, onExtend,
}: {
  school: PlatformSchool
  plans: { code: string; name: string; price_yearly: number; price_monthly: number }[]
  busy: boolean
  onActivate: (plan: string, months: number) => void
  onExtend: () => void
}) {
  // Default to the plan their real headcount says they should be on, so the
  // common case is one click and the size question is already answered.
  const [plan, setPlan] = useState(school.suggested_plan || school.plan_code)
  const [months, setMonths] = useState(12)
  const chosen = plans.find((p) => p.code === plan)
  const price = chosen ? (months >= 12 ? chosen.price_yearly : chosen.price_monthly * months) : null

  return (
    <div className="flex shrink-0 flex-wrap items-center gap-2">
      <select
        value={plan} onChange={(e) => setPlan(e.target.value)}
        className="rounded border border-slate-300 px-2 py-1.5 text-sm"
      >
        {plans.map((p) => <option key={p.code} value={p.code}>{p.code}</option>)}
      </select>
      <select
        value={months} onChange={(e) => setMonths(Number(e.target.value))}
        className="rounded border border-slate-300 px-2 py-1.5 text-sm"
      >
        <option value={1}>1 month</option>
        <option value={3}>3 months</option>
        <option value={6}>6 months</option>
        <option value={12}>1 year</option>
      </select>
      {price !== null && <span className="text-sm text-slate-500">{formatPkr(price)}</span>}
      <button
        onClick={() => onActivate(plan, months)}
        disabled={busy}
        className="rounded bg-brand-600 px-3 py-1.5 text-sm font-medium text-white hover:bg-brand-700 disabled:opacity-60"
      >
        {school.status === 'active' ? 'Renew' : 'Activate'}
      </button>
      {(school.status === 'trialing' || school.status === 'locked') && (
        <button
          onClick={onExtend}
          disabled={busy}
          className="rounded border border-slate-300 px-3 py-1.5 text-sm text-slate-700 hover:bg-slate-50 disabled:opacity-60"
        >
          +14d trial
        </button>
      )}
    </div>
  )
}

import { useQuery } from '@tanstack/react-query'
import { listSupportVisits } from '@/lib/db'
import { useAuth } from '@/auth/AuthProvider'
import { fmtDateTime } from '@/lib/format'

/**
 * When did the software company look at our records, and why?
 *
 * This screen is the mitigation the operator's access is paid for with. They can
 * enter any school at any time without asking. That was the owner's decision,
 * against my recommendation, and docs/SUPER-ADMIN-DESIGN.md §2.1 carries the
 * argument. What this screen changes is that they cannot do it invisibly.
 *
 * It is worth being clear about why that is in the vendor's own interest rather
 * than a concession. A principal is being asked to put every child's name,
 * father's name, B-Form, home address and fee history into a database somebody
 * else controls. Sooner or later: probably from a competitor. They will hear
 * that the vendor can read all of it. "We would never look" is the answer
 * everybody gives. Being able to say "we can look when you call us, every single
 * time is recorded, and here is the page where you read that record yourself" is
 * a different conversation.
 *
 * Owner and principal only. A clerk can do nothing about it, and the fact belongs
 * to whoever signed the contract.
 */
export function SupportVisits() {
  const { profile } = useAuth()
  const isLeadership = profile?.role === 'owner' || profile?.role === 'principal'

  const visits = useQuery({
    queryKey: ['supportVisits'],
    queryFn: () => listSupportVisits(),
    enabled: isLeadership,
  })

  if (!isLeadership) {
    return (
      <p className="max-w-2xl text-sm text-slate-600">
        Only the school owner or principal can see this.
      </p>
    )
  }

  const rows = visits.data ?? []
  const open = rows.filter((v) => v.ended_at === null).length
  const minutes = rows.reduce((t, v) => t + (v.minutes ?? 0), 0)

  return (
    <div className="max-w-3xl space-y-4">
      <div className="rounded-2xl border border-brand-100 bg-brand-50 p-4 text-sm text-brand-900">
        <div className="font-semibold">Our support team can enter your account to help you</div>
        <p className="mt-1.5 text-brand-800">
          When you call us about a problem, we can open your account and see exactly what you are seeing. We{' '}
          <b>cannot change anything</b> while we are in there: not a fee, not a mark, not a payment. The software
          refuses it. Every visit is listed below, with the reason. If you see one you did not expect, ask us about it.
        </p>
      </div>

      {visits.isLoading && <p className="text-sm text-slate-500">Loading…</p>}
      {visits.error && <p className="rounded-xl bg-danger-50 px-3 py-2 text-sm text-danger-700">{(visits.error as Error).message}</p>}

      {!visits.isLoading && !visits.error && (
        <div className="grid grid-cols-3 gap-3">
          <div className="rounded-2xl border border-slate-200 bg-white px-4 py-3"><div className="text-2xl font-semibold tabular-nums text-slate-900">{rows.length}</div><div className="text-xs text-slate-500">visits</div></div>
          <div className="rounded-2xl border border-slate-200 bg-white px-4 py-3"><div className="text-2xl font-semibold tabular-nums text-slate-900">{minutes}</div><div className="text-xs text-slate-500">minutes in all</div></div>
          <div className={`rounded-2xl border px-4 py-3 ${open ? 'border-due-200 bg-due-50' : 'border-slate-200 bg-white'}`}><div className={`text-2xl font-semibold tabular-nums ${open ? 'text-due-800' : 'text-slate-900'}`}>{open}</div><div className="text-xs text-slate-500">happening now</div></div>
        </div>
      )}

      {!visits.isLoading && rows.length === 0 && !visits.error && (
        <p className="rounded-xl border border-dashed border-slate-300 bg-white px-4 py-6 text-center text-sm text-slate-500">
          Nobody from our team has ever opened your account.
        </p>
      )}

      {rows.length > 0 && (
        <ul className="divide-y divide-slate-100 rounded-2xl border border-slate-200 bg-white shadow-card">
          {rows.map((v, i) => (
            <li key={i} className="flex flex-wrap items-start justify-between gap-2 px-4 py-3">
              <div className="min-w-0">
                <div className="text-sm text-slate-900">{v.reason}</div>
                <div className="text-xs text-slate-500">{fmtDateTime(v.started_at)}</div>
              </div>
              {/* A visit still open reads as such rather than as zero minutes,
                  which would look like nothing happened. */}
              {v.ended_at === null
                ? <span className="rounded-full bg-due-50 px-2 py-0.5 text-xs font-medium text-due-800 ring-1 ring-due-200">in progress</span>
                : <span className="text-xs tabular-nums text-slate-600">{v.minutes} min</span>}
            </li>
          ))}
        </ul>
      )}
    </div>
  )
}

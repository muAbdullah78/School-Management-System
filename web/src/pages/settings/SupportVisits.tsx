import { useQuery } from '@tanstack/react-query'
import { listSupportVisits } from '@/lib/db'
import { useAuth } from '@/auth/AuthProvider'
import { fmtDateTime } from '@/lib/format'

/**
 * When did the software company look at our records, and why?
 *
 * This screen is the mitigation the operator's access is paid for with. They can
 * enter any school at any time without asking — that was the owner's decision,
 * against my recommendation, and docs/SUPER-ADMIN-DESIGN.md §2.1 carries the
 * argument. What this screen changes is that they cannot do it invisibly.
 *
 * It is worth being clear about why that is in the vendor's own interest rather
 * than a concession. A principal is being asked to put every child's name,
 * father's name, B-Form, home address and fee history into a database somebody
 * else controls. Sooner or later — probably from a competitor — they will hear
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

  return (
    <div className="max-w-3xl space-y-4">
      <div className="rounded-lg border border-slate-200 bg-white p-4 text-sm text-slate-700">
        <div className="font-medium text-slate-800">
          Our support team can enter your account to help you
        </div>
        <p className="mt-1.5 text-slate-600">
          When you call us about a problem, we can open your account and see exactly
          what you are seeing. We <span className="font-medium">cannot change anything</span>{' '}
          while we are in there — not a fee, not a mark, not a payment. The software
          refuses it.
        </p>
        <p className="mt-1.5 text-slate-600">
          Every visit is listed below, with the reason. If you ever see a visit here
          that you did not expect, ask us about it.
        </p>
      </div>

      {visits.isLoading && <p className="text-sm text-slate-500">Loading…</p>}
      {visits.error && (
        <p className="text-sm text-red-600">{(visits.error as Error).message}</p>
      )}

      {!visits.isLoading && rows.length === 0 && (
        <div className="rounded-lg border border-slate-200 bg-white p-6 text-center text-sm text-slate-500">
          Nobody from our team has ever opened your account.
        </div>
      )}

      {rows.length > 0 && (
        <div className="overflow-hidden rounded-lg border border-slate-200 bg-white">
          <table className="w-full text-sm">
            <thead className="bg-slate-50 text-left text-xs uppercase tracking-wide text-slate-500">
              <tr>
                <th className="px-3 py-2 w-52">When</th>
                <th className="px-3 py-2 w-24">How long</th>
                <th className="px-3 py-2">Reason given</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-slate-100">
              {rows.map((v, i) => (
                <tr key={i}>
                  <td className="px-3 py-2 text-slate-600">{fmtDateTime(v.started_at)}</td>
                  <td className="px-3 py-2 text-slate-600">
                    {/* A visit still open reads as such rather than as zero
                        minutes, which would look like nothing happened. */}
                    {v.ended_at === null
                      ? <span className="font-medium text-amber-700">in progress</span>
                      : `${v.minutes} min`}
                  </td>
                  <td className="px-3 py-2 text-slate-800">{v.reason}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </div>
  )
}

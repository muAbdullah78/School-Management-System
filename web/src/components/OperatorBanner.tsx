import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { operatorCurrent, operatorLeave } from '@/lib/platform'

/**
 * The strip that says "you are not looking at your own data".
 *
 * Shown whenever the operator has an open support session, on every screen, and
 * NOT DISMISSABLE. That is the whole design: the failure mode of impersonation is
 * not a leak, it is forgetting: reading a school's records for twenty minutes
 * while believing you are looking at a demo, or worse, telling a principal
 * something about another school's figures.
 *
 * It says READ ONLY in as many words because that is the promise being kept, and
 * a banner that only named the school would leave the operator wondering whether
 * a Save would go through. It would: it would be refused by the database. The
 * banner saying so up front is cheaper than finding out.
 *
 * Polled rather than pushed. A session expires on its own: 60 minutes by
 * default, and when it does the reach ends whether anybody pressed Leave or
 * not, so the banner has to stop on its own too. A stale banner claiming access
 * that has lapsed is its own small lie.
 */
export function OperatorBanner() {
  const qc = useQueryClient()
  const session = useQuery({
    queryKey: ['operatorCurrent'],
    queryFn: operatorCurrent,
    // Every 60s. The expiry is measured in minutes, so this is fine-grained
    // enough, and it costs one tiny indexed query.
    refetchInterval: 60_000,
    refetchOnWindowFocus: true,
  })

  const leave = useMutation({
    mutationFn: operatorLeave,
    onSuccess: () => {
      // Everything on screen was read through the session, so all of it is now
      // wrong. Clearing the whole cache rather than invalidating keys one by one:
      // a half-cleared cache would leave another school's pupil names sitting in
      // a list while the banner said the visit had ended.
      qc.clear()
      window.location.assign('/platform')
    },
  })

  const s = session.data
  if (!s) return null

  const minsLeft = Math.max(
    0, Math.round((new Date(s.expires_at).getTime() - Date.now()) / 60000),
  )

  return (
    <div className="border-b-2 border-red-700 bg-red-600 px-4 py-2 text-sm text-white print:hidden">
      <div className="mx-auto flex max-w-7xl flex-wrap items-center justify-between gap-2">
        <div className="min-w-0">
          <span className="font-semibold">
            Support visit. You are viewing {s.school_name}
          </span>
          <span className="ml-2 rounded bg-white/20 px-1.5 py-0.5 text-xs font-medium uppercase tracking-wide">
            read only
          </span>
          <div className="mt-0.5 text-xs text-red-50">
            This is not your data. Nothing you do here can change it. The database
            refuses every write from a support visit.
            {' '}Reason on record: “{s.reason}”.
            {' '}Ends in {minsLeft} minute{minsLeft === 1 ? '' : 's'}, and the school
            can see this visit in its own settings.
          </div>
        </div>
        <button
          onClick={() => leave.mutate()}
          disabled={leave.isPending}
          className="shrink-0 rounded bg-white px-3 py-1.5 text-sm font-semibold text-red-700 hover:bg-red-50 disabled:opacity-60"
        >
          {leave.isPending ? 'Leaving…' : 'Leave this school'}
        </button>
      </div>
    </div>
  )
}

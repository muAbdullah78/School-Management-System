import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { attachLogin, unattachedLogins, type UnattachedLogin } from '@/lib/platform'

/**
 * Logins that can sign in and belong to no school.
 *
 * WHY THIS PANEL EXISTS AT ALL
 *
 * Because the state it describes was invisible from every other screen in the
 * console, and it happened twice to real schools.
 *
 * A school signs up. The school row, the trial and the login are all created.
 * The profile that attaches the login to the school is not, because the auth
 * service writes app metadata in a second statement and the trigger that reads
 * it only fired on the first. Everything then looks correct from the outside:
 * the school is in the list, on trial, fourteen days left, nought pupils. That
 * is indistinguishable from a school that signed up this morning and has not
 * opened the app yet, and the difference between those two is a customer who
 * gave up in silence.
 *
 * WHY IT IS NOT JUST A REPORT
 *
 * Because the operator would then have to fix it in the SQL editor, on a live
 * customer's tenancy, by hand, with the school on the telephone. The button
 * calls the same function the signup trigger calls, so there is exactly one
 * rule deciding which school and which role a login gets, and it writes the act
 * to the school's own audit trail.
 *
 * This list is meant to be empty for ever. The tab only appears when it is not,
 * because a permanently empty tab teaches people to stop reading the nav.
 */
export function UnattachedLogins() {
  const qc = useQueryClient()
  const q = useQuery({
    queryKey: ['unattachedLogins'],
    queryFn: unattachedLogins,
    retry: false,
  })

  const rows = q.data ?? []

  if (q.isLoading) return <p className="text-sm text-slate-500">Checking…</p>
  if (q.error) {
    return (
      <p className="rounded border border-rose-200 bg-rose-50 p-3 text-sm text-rose-800">
        {(q.error as Error).message}
      </p>
    )
  }

  return (
    <div className="space-y-3">
      <div className="rounded-lg border border-slate-200 bg-white p-3">
        <h2 className="text-sm font-semibold text-slate-800">Logins with no school</h2>
        <p className="mt-1 text-sm text-slate-600">
          These people can sign in with the right password and there is no school
          against their login, so the app has nothing to open for them. Their
          school exists and is in the list above, which is why this is invisible
          everywhere else in this console.
        </p>
        <p className="mt-2 text-sm text-slate-600">
          Attaching one uses the same rule a signup uses: the first account of a
          school becomes its owner. It is recorded in that school's own activity
          log.
        </p>
        {rows.length === 0 && (
          <p className="mt-2 rounded bg-emerald-50 px-2 py-1.5 text-sm text-emerald-800">
            Nothing stranded. Every login on the platform either belongs to a
            school or is ours.
          </p>
        )}
      </div>

      {rows.length > 0 && (
        <div className="overflow-x-auto rounded-lg border border-slate-200 bg-white">
          <table className="w-full text-sm">
            <thead className="border-b border-slate-200 bg-slate-50 text-left text-xs uppercase tracking-wide text-slate-500">
              <tr>
                <th className="px-3 py-2 font-medium">Login</th>
                <th className="px-3 py-2 font-medium">School</th>
                <th className="px-3 py-2 font-medium">Should be</th>
                <th className="px-3 py-2 font-medium">Created</th>
                <th className="px-3 py-2" />
              </tr>
            </thead>
            <tbody>
              {rows.map((r) => (
                <Row key={r.user_id} row={r}
                  onDone={() => void qc.invalidateQueries()} />
              ))}
            </tbody>
          </table>
        </div>
      )}
    </div>
  )
}

function Row({ row, onDone }: { row: UnattachedLogin; onDone: () => void }) {
  const fix = useMutation({
    mutationFn: () => attachLogin(row.user_id),
    onSuccess: onDone,
  })

  return (
    <tr className="border-b border-slate-100 last:border-0 align-top">
      <td className="px-3 py-2 text-slate-800">{row.email ?? 'no address'}</td>
      <td className="px-3 py-2 text-slate-700">{row.school_name}</td>
      <td className="px-3 py-2 text-slate-600">
        {row.asked_role
          ? row.asked_role.replace(/_/g, ' ')
          : 'the school owner'}
      </td>
      <td className="px-3 py-2 text-slate-500">
        {new Date(row.created_at).toLocaleDateString('en-GB', {
          day: 'numeric', month: 'short', year: 'numeric',
        })}
      </td>
      <td className="px-3 py-2 text-right">
        <button
          onClick={() => fix.mutate()}
          disabled={fix.isPending}
          className="rounded bg-brand-600 px-3 py-1.5 text-xs font-medium text-white hover:bg-brand-700 disabled:opacity-60"
        >
          {fix.isPending ? 'Attaching…' : 'Attach to their school'}
        </button>
        {fix.error && (
          <p className="mt-1 text-xs text-rose-700">{(fix.error as Error).message}</p>
        )}
        {fix.data && (
          <p className="mt-1 text-xs text-money-700">{fix.data.outcome}</p>
        )}
      </td>
    </tr>
  )
}

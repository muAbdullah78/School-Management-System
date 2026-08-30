import { useState } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { orphanReport, purgeOrphanData, type OrphanRow } from '@/lib/platform'

const FIELD = 'w-full rounded border border-slate-300 px-2 py-1.5 text-sm'

/**
 * Records belonging to a school whose row is gone.
 *
 * This screen should be empty forever, and the fact that it is reachable at all
 * is the point: the state it describes is invisible from every other screen in
 * the console. A school with no `schools` row does not appear in the school
 * list, has no detail page and no purge button, so before this panel there was
 * no way to see the records or to remove them — only a subscription count that
 * quietly disagreed with the number of schools.
 *
 * WHY THE OPERATOR IS TOLD SO MUCH HERE
 *
 * Because the safe answer and the tidy answer are different, and only the person
 * reading this can tell which applies. An id with a subscription and nothing
 * else is an abandoned signup. An id with students and payments is a school that
 * somebody was billed for, and clearing it destroys the only remaining copy of
 * their records. The panel therefore shows every table and every count BEFORE
 * offering the button, and the button asks for the id to be typed back.
 */
export function LeftBehind() {
  const qc = useQueryClient()
  const q = useQuery({ queryKey: ['orphanReport'], queryFn: orphanReport, retry: false })

  const rows = q.data ?? []
  const ids = [...new Set(rows.map((r) => r.school_id))]

  if (q.isLoading) {
    return <p className="text-sm text-slate-500">Checking…</p>
  }
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
        <h2 className="text-sm font-semibold text-slate-800">
          Records with no school
        </h2>
        <p className="mt-1 text-sm text-slate-600">
          Deleting a school through this console removes everything it owns first.
          Rows show up here when a school was removed some other way — a database
          restore, or a delete run with foreign keys switched off — which leaves
          its settings, its fee records and its licence behind with nothing to
          attach them to.
        </p>
        {ids.length === 0 && (
          <p className="mt-2 rounded bg-emerald-50 px-2 py-1.5 text-sm text-emerald-800">
            Nothing left behind. Every record on the platform belongs to a school
            that exists.
          </p>
        )}
      </div>

      {ids.map((id) => (
        <OrphanCard key={id} schoolId={id}
          rows={rows.filter((r) => r.school_id === id)}
          onDone={() => qc.invalidateQueries({ queryKey: ['orphanReport'] })} />
      ))}
    </div>
  )
}

function OrphanCard({ schoolId, rows, onDone }: {
  schoolId: string; rows: OrphanRow[]; onDone: () => void
}) {
  const [confirm, setConfirm] = useState('')
  const [err, setErr] = useState<string | null>(null)
  const [done, setDone] = useState<Awaited<ReturnType<typeof purgeOrphanData>> | null>(null)

  const toDelete = rows.filter((r) => r.treatment === 'delete')
  const toUnlink = rows.filter((r) => r.treatment === 'unlink')
  const total = toDelete.reduce((n, r) => n + Number(r.row_count), 0)

  // The tables that mean a real school was operating here rather than an
  // abandoned signup. Named explicitly, because "26 rows" reads the same whether
  // it is 26 message templates or 26 children.
  const substantial = rows.filter(
    (r) => ['students', 'staff', 'payments', 'invoices', 'families'].includes(r.table_name)
      && Number(r.row_count) > 0,
  )

  const run = useMutation({
    mutationFn: () => purgeOrphanData(schoolId),
    onSuccess: (d) => { setDone(d); onDone() },
    onError: (e: Error) => setErr(e.message),
  })

  if (done) {
    return (
      <div className="rounded-lg border border-emerald-200 bg-emerald-50 p-3 text-sm">
        <p className="font-medium text-emerald-900">Cleared {schoolId}</p>
        <p className="mt-1 text-emerald-800">
          {done.rows_deleted ?? 0} row(s) removed, {done.rows_unlinked ?? 0} kept and
          unlinked. {done.kept}
        </p>
        {done.orphan_logins && done.orphan_logins.length > 0 && (
          <p className="mt-2 rounded bg-white/70 px-2 py-1.5 text-emerald-900">
            <span className="font-medium">{done.logins_note}</span>
            <br />
            {done.orphan_logins.join(', ')}
          </p>
        )}
      </div>
    )
  }

  return (
    <div className="rounded-lg border border-amber-300 bg-white p-3">
      <div className="flex flex-wrap items-baseline justify-between gap-2">
        <h3 className="font-mono text-sm font-semibold text-slate-800">{schoolId}</h3>
        <span className="text-sm text-slate-500">
          {total.toLocaleString()} row(s) across {toDelete.length} table(s)
        </span>
      </div>

      {substantial.length > 0 && (
        <p className="mt-2 rounded border border-rose-300 bg-rose-50 px-2 py-1.5 text-sm text-rose-900">
          <span className="font-semibold">This was a school somebody used.</span>{' '}
          It still holds {substantial.map((r) => `${r.row_count} ${r.table_name}`).join(', ')}.
          Clearing it destroys the last copy of those records. If there is any chance
          this school is owed an export, take it out of the database first.
        </p>
      )}

      <div className="mt-2 grid gap-3 sm:grid-cols-2">
        <div>
          <div className="text-xs font-semibold uppercase tracking-wide text-slate-500">
            Will be deleted
          </div>
          <ul className="mt-1 space-y-0.5 text-sm text-slate-700">
            {toDelete.map((r) => (
              <li key={r.table_name} className="flex justify-between gap-2">
                <span className="font-mono text-xs">{r.table_name}</span>
                <span>{Number(r.row_count).toLocaleString()}</span>
              </li>
            ))}
          </ul>
        </div>
        <div>
          <div className="text-xs font-semibold uppercase tracking-wide text-slate-500">
            Kept, with the link removed
          </div>
          {toUnlink.length === 0
            ? <p className="mt-1 text-sm text-slate-500">Nothing of ours refers to it.</p>
            : (
              <ul className="mt-1 space-y-0.5 text-sm text-slate-700">
                {toUnlink.map((r) => (
                  <li key={r.table_name} className="flex justify-between gap-2">
                    <span className="font-mono text-xs">{r.table_name}</span>
                    <span>{Number(r.row_count).toLocaleString()}</span>
                  </li>
                ))}
              </ul>
            )}
          <p className="mt-1 text-xs text-slate-500">
            Your invoices, receipts and the record of what this console did are
            business records. They stay, with the school id taken off them.
          </p>
        </div>
      </div>

      <div className="mt-3 border-t border-slate-200 pt-3">
        <label className="block text-sm text-slate-700">
          To clear it, type the id above:
          <input value={confirm} onChange={(e) => { setConfirm(e.target.value); setErr(null) }}
            className={`${FIELD} mt-1 font-mono`} placeholder={schoolId} spellCheck={false} />
        </label>
        {err && <p className="mt-2 text-sm text-rose-700">{err}</p>}
        <button
          disabled={confirm.trim() !== schoolId || run.isPending}
          onClick={() => run.mutate()}
          className="mt-2 rounded bg-rose-600 px-3 py-1.5 text-sm font-medium text-white
                     hover:bg-rose-700 disabled:cursor-not-allowed disabled:bg-slate-300">
          {run.isPending ? 'Clearing…' : 'Clear these records'}
        </button>
        <p className="mt-1 text-xs text-slate-500">
          This cannot be undone. It is recorded in the console's own history with
          the table counts as they were before it ran.
        </p>
      </div>
    </div>
  )
}

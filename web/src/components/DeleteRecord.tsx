import { useState } from 'react'
import { useMutation, useQuery } from '@tanstack/react-query'
import type { DeleteBlocker, DeleteResult } from '@/lib/db'

/**
 * The one dialog for removing a person from the school's records.
 *
 * WHAT IT IS TRYING TO GET RIGHT
 *
 * There are two completely different situations behind the same button, and
 * software normally handles them badly in opposite directions. Either it
 * deletes anything, and a school discovers in April that removing a leaver
 * quietly changed February's income; or it deletes nothing, which is what this
 * app did, and a name typed in wrong sits on the roster for ever.
 *
 * So this asks the DATABASE which situation it is in before it offers
 * anything, and the two cases look different on purpose:
 *
 *   nothing attached   a plain confirmation, and the record goes
 *   something attached NOT an error. The list of what is in the way, in the
 *                      words a school office uses, and the archive action
 *                      instead, which is almost always what they wanted
 *
 * The second case is the one that decides whether people trust the product. A
 * refusal that says only "cannot delete" is why nobody believes software. A
 * refusal that says "3 payments received, 42 days of attendance" is a fact
 * about their own school that they can check, and it makes the archive offer
 * next to it read as help rather than as an obstacle.
 *
 * WHY IT ASKS FIRST RATHER THAN ON PRESS
 *
 * Being told after you have committed feels like being caught out. Being told
 * while you are still deciding feels like being helped. It costs one small
 * query at the moment the dialog opens.
 */
export function DeleteRecord({
  kind, name, blockers, remove, onDeleted, onCancel, archive,
}: {
  /** "student", "staff member", "login": used in the sentences below. */
  kind: string
  name: string
  blockers: () => Promise<DeleteBlocker[]>
  remove: () => Promise<DeleteResult>
  onDeleted: (r: DeleteResult) => void
  onCancel: () => void
  /** The honest alternative when deletion is refused. */
  archive?: { label: string; explain: string; run: () => void }
}) {
  const [confirmText, setConfirmText] = useState('')
  const check = useQuery({
    queryKey: ['deleteBlockers', kind, name],
    queryFn: blockers,
    retry: false,
    gcTime: 0,
    staleTime: 0,
  })

  const go = useMutation({
    mutationFn: remove,
    onSuccess: (r) => { if (r.deleted) onDeleted(r) },
  })

  const blocked = (check.data?.length ?? 0) > 0
  // The typed name is only asked for when the record really is about to go.
  // Asking for it when the answer is going to be "no" is theatre.
  const typedOk = confirmText.trim().toLowerCase() === name.trim().toLowerCase()

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-slate-900/40 p-4">
      <div className="w-full max-w-lg rounded-xl bg-white p-5 shadow-xl">
        <h3 className="text-base font-semibold text-slate-900">
          Remove {name}?
        </h3>

        {check.isLoading && (
          <p className="mt-3 text-sm text-slate-500">
            Checking what is attached to this {kind}…
          </p>
        )}

        {check.isError && (
          <p className="mt-3 text-sm text-danger-700">
            Could not check: {(check.error as Error).message}
          </p>
        )}

        {check.data && !blocked && (
          <>
            <p className="mt-3 text-sm text-slate-700">
              Nothing is attached to this {kind}: no money, no attendance, no marks,
              no documents issued. It can be removed completely and nothing else in
              the school&rsquo;s records changes.
            </p>
            <p className="mt-2 text-sm text-slate-700">
              This cannot be undone. Type <b>{name}</b> to confirm.
            </p>
            <input
              value={confirmText}
              onChange={(e) => setConfirmText(e.target.value)}
              placeholder={name}
              autoFocus
              className="mt-2 w-full rounded-lg border border-slate-300 px-3 py-2 text-sm focus:border-brand-500 focus:outline-none"
            />
          </>
        )}

        {check.data && blocked && (
          <>
            <p className="mt-3 text-sm text-slate-700">
              This {kind} cannot be removed, because the school&rsquo;s records
              already refer to them:
            </p>
            <ul className="mt-2 space-y-1 rounded-lg bg-slate-50 px-3 py-2.5">
              {check.data.map((b, i) => (
                <li key={i} className="text-sm text-slate-800">
                  <span className="tabular-nums font-semibold">{b.count}</span>{' '}
                  <span className="text-slate-700">{b.what}</span>
                </li>
              ))}
            </ul>
            <p className="mt-2 text-sm text-slate-600">
              Deleting them would change figures the school has already reported and
              documents it has already handed out. That is why this is refused rather
              than offered with a warning.
            </p>
            {archive && (
              <div className="mt-3 rounded-lg border border-brand-200 bg-brand-50 px-3 py-2.5">
                <p className="text-sm font-medium text-brand-900">{archive.label}</p>
                <p className="mt-0.5 text-sm text-brand-800">{archive.explain}</p>
              </div>
            )}
          </>
        )}

        {go.isError && (
          <p className="mt-3 text-sm text-danger-700">{(go.error as Error).message}</p>
        )}
        {/* The database re-checks on its own authority, so it can refuse even
            though the check above was clear: somebody else may have taken a
            payment in the seconds between. That is not an error, it is the
            answer, and it belongs on screen rather than in a console. */}
        {go.data && !go.data.deleted && (
          <div className="mt-3 rounded-lg border border-amber-200 bg-amber-50 px-3 py-2.5 text-sm">
            <p className="font-medium text-amber-900">Not removed</p>
            <ul className="mt-1 space-y-0.5">
              {go.data.blockers.map((b, i) => (
                <li key={i} className="text-amber-800">
                  <span className="tabular-nums font-semibold">{b.count}</span> {b.what}
                </li>
              ))}
            </ul>
          </div>
        )}

        <div className="mt-5 flex flex-wrap justify-end gap-2">
          <button
            onClick={onCancel}
            className="rounded-lg border border-slate-300 bg-white px-4 py-2 text-sm font-medium text-slate-700 hover:bg-slate-50"
          >
            Cancel
          </button>
          {blocked && archive && (
            <button
              onClick={archive.run}
              className="rounded-lg bg-brand-600 px-4 py-2 text-sm font-medium text-white hover:bg-brand-700"
            >
              {archive.label}
            </button>
          )}
          {check.data && !blocked && (
            <button
              onClick={() => go.mutate()}
              disabled={!typedOk || go.isPending}
              className="rounded-lg bg-danger-600 px-4 py-2 text-sm font-medium text-white hover:bg-danger-700 disabled:cursor-not-allowed disabled:opacity-50"
            >
              {go.isPending ? 'Removing…' : `Remove this ${kind}`}
            </button>
          )}
        </div>
      </div>
    </div>
  )
}

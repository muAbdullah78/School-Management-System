import { useState } from 'react'
import { useMutation, useQueryClient } from '@tanstack/react-query'
import {
  archiveSchool, cancelSubscription, setGrace, suspendSchool,
  unarchiveSchool, unsuspendSchool, type PlatformSchool,
} from '@/lib/platform'
import { formatPkr } from '@/lib/licence'

const FIELD = 'w-full rounded border border-slate-300 px-2 py-1.5 text-sm'

/**
 * The things you can do to a school short of destroying it.
 *
 * Four verbs that are easy to confuse and must not be, so each one says on the
 * screen what it actually does:
 *
 *   SUSPEND   stop them working NOW, whatever the licence dates say. The school
 *             is shown the reason. Reversible in one click.
 *   CANCEL    end the commercial relationship. Data untouched, still visible in
 *             the console, and it does NOT write off what they owe.
 *   ARCHIVE   out of the console and off the renewal list. Data untouched.
 *             Reversible, and the required step before offboarding.
 *   GRACE     a different post-expiry window for this school only.
 *
 * Nothing here deletes anything. That is Offboard, and it is a different screen
 * with a different colour and a name to type.
 */
type Action = 'suspend' | 'unsuspend' | 'cancel' | 'archive' | 'unarchive' | 'grace'

export function LifecycleDialog({ school, onClose, onDone }: {
  school: PlatformSchool
  onClose: () => void
  onDone: (message: string) => void
}) {
  const [action, setAction] = useState<Action | null>(null)
  return (
    <div className="fixed inset-0 z-50 flex items-start justify-center overflow-y-auto bg-black/40 p-4">
      <div className="w-full max-w-lg rounded-lg bg-white p-5 shadow-lg">
        <div className="flex items-start justify-between gap-3">
          <div>
            <h2 className="text-base font-semibold text-slate-800">{school.school_name}</h2>
            <p className="text-sm text-slate-500">
              {school.plan_code} · {school.status}
              {school.suspended && <span className="text-red-700"> · suspended by us</span>}
              {school.archived && <span className="text-slate-400"> · archived</span>}
              {school.outstanding > 0 && (
                <span className="text-amber-800"> · owes {formatPkr(school.outstanding)}</span>
              )}
            </p>
            {school.suspended && school.suspend_reason && (
              <p className="mt-1 rounded bg-red-50 px-2 py-1 text-xs text-red-800">
                They are being shown: &ldquo;{school.suspend_reason}&rdquo;
              </p>
            )}
          </div>
          <button onClick={onClose} className="text-sm text-slate-500 hover:underline">Close</button>
        </div>

        {action === null ? (
          <div className="mt-4 space-y-2">
            {school.suspended ? (
              <Choice onClick={() => setAction('unsuspend')} title="Let them work again"
                body="Lifts the suspension. They go back to whatever their licence dates say." />
            ) : (
              <Choice onClick={() => setAction('suspend')} title="Suspend — stop new entries now"
                body="Takes effect immediately whatever the licence says. They can still read,
                      print and export. They are shown the reason you type, so make it one you
                      would say on the phone."
                tone="warn" />
            )}
            <Choice onClick={() => setAction('grace')}
              title="Change their grace period"
              body="How long after expiry they keep working while a payment is in flight. For
                    the school that always pays late and always pays — or the one that needs
                    chasing every quarter." />
            {school.status !== 'cancelled' && (
              <Choice onClick={() => setAction('cancel')} title="Cancel the subscription"
                body="Ends the relationship. Nothing is deleted, they stay in this list, and
                      anything they owe is still owed."
                tone="warn" />
            )}
            {school.archived ? (
              <Choice onClick={() => setAction('unarchive')} title="Bring them back into the list"
                body="Makes them visible again. Does not give them a licence — that is a
                      separate, priced decision." />
            ) : (
              <Choice onClick={() => setAction('archive')} title="Archive — hide them"
                body="Out of this list and off the renewal worklist. Data completely intact,
                      and reversible. Required before you can export or delete them."
                tone="warn" />
            )}
          </div>
        ) : (
          <ActionForm school={school} action={action}
            onBack={() => setAction(null)} onDone={onDone} />
        )}
      </div>
    </div>
  )
}

function Choice({ title, body, onClick, tone }: {
  title: string; body: string; onClick: () => void; tone?: 'warn'
}) {
  return (
    <button onClick={onClick}
      className={`block w-full rounded border p-3 text-left hover:bg-slate-50 ${
        tone === 'warn' ? 'border-amber-300 bg-amber-50/40' : 'border-slate-200'}`}>
      <div className="text-sm font-medium text-slate-800">{title}</div>
      <div className="mt-0.5 text-xs text-slate-500">{body}</div>
    </button>
  )
}

function ActionForm({ school, action, onBack, onDone }: {
  school: PlatformSchool; action: Action; onBack: () => void
  onDone: (message: string) => void
}) {
  const qc = useQueryClient()
  const [reason, setReason] = useState('')
  const [days, setDays] = useState('')
  const [err, setErr] = useState<string | null>(null)
  const [result, setResult] = useState<{ title: string; lines: string[] } | null>(null)

  const needsReason = action === 'suspend' || action === 'cancel' || action === 'archive'
  const isGraceOverride = action === 'grace' && days.trim() !== ''

  const run = useMutation({
    mutationFn: async (): Promise<{ title: string; lines: string[] }> => {
      switch (action) {
        case 'suspend': {
          const r = await suspendSchool(school.school_id, reason)
          return {
            title: `${school.school_name} is suspended.`,
            lines: [r.what_still_works,
                    'They are now being shown your reason on their own screen.'],
          }
        }
        case 'unsuspend': {
          const r = await unsuspendSchool(school.school_id, reason.trim() || null)
          return {
            title: 'Suspension lifted.',
            lines: [`Their licence now reads: ${r.status}.`],
          }
        }
        case 'cancel': {
          const r = await cancelSubscription(school.school_id, reason)
          return { title: 'Subscription cancelled.', lines: [r.note, r.data] }
        }
        case 'archive': {
          const r = await archiveSchool(school.school_id, reason)
          return {
            title: `${school.school_name} archived.`,
            lines: [...r.what_this_did,
                    r.outstanding > 0
                      ? `They still owe ${formatPkr(r.outstanding)} — archiving does not write that off.`
                      : 'Nothing outstanding.'],
          }
        }
        case 'unarchive': {
          const r = await unarchiveSchool(school.school_id)
          return { title: 'Back in the list.', lines: [r.note] }
        }
        case 'grace': {
          const n = days.trim() === '' ? null : Number(days)
          const r = await setGrace(school.school_id, n, reason.trim() || null)
          return {
            title: r.is_override
              ? `${school.school_name} now gets ${r.grace_days} days of grace.`
              : `Back to the standard ${r.grace_days} days.`,
            lines: [`Their licence now reads: ${r.status}.`],
          }
        }
      }
    },
    onSuccess: (r) => {
      setErr(null); setResult(r)
      void qc.invalidateQueries({ queryKey: ['platformSchools'] })
      void qc.invalidateQueries({ queryKey: ['dueSoon'] })
      void qc.invalidateQueries({ queryKey: ['schoolDetail'] })
      void qc.invalidateQueries({ queryKey: ['platformRevenue'] })
    },
    onError: (e) => setErr((e as Error).message),
  })

  if (result) {
    return (
      <div className="mt-4">
        <h3 className="text-sm font-semibold text-slate-800">{result.title}</h3>
        {/* Every consequence spelled out. Each of these is something somebody
            would otherwise assume happened, or assume did not. */}
        <ul className="mt-2 space-y-1 text-sm text-slate-600">
          {result.lines.filter(Boolean).map((l, i) => (
            <li key={i} className="flex gap-2"><span className="text-slate-300">·</span>{l}</li>
          ))}
        </ul>
        <button onClick={() => onDone(result.title)}
          className="mt-4 w-full rounded bg-brand-600 px-3 py-2 text-sm font-medium text-white hover:bg-brand-700">
          Done
        </button>
      </div>
    )
  }

  return (
    <div className="mt-4">
      <button onClick={onBack} className="text-xs text-slate-500 hover:underline">
        ← back
      </button>

      {err && <p className="mt-2 rounded bg-red-50 px-3 py-2 text-sm text-red-700">{err}</p>}

      {action === 'grace' && (
        <label className="mt-3 block">
          <span className="text-xs font-medium text-slate-600">
            Days of grace after expiry
          </span>
          <input type="number" min={0} max={180} className={FIELD} value={days}
            onChange={(e) => setDays(e.target.value)} placeholder="leave blank for the standard window" />
          <span className="mt-0.5 block text-xs text-slate-400">
            Blank puts them back on the standard window and needs no reason.
          </span>
        </label>
      )}

      {(needsReason || isGraceOverride || action === 'unsuspend') && (
        <label className="mt-3 block">
          <span className="text-xs font-medium text-slate-600">
            {action === 'suspend'
              ? 'Reason — THE SCHOOL IS SHOWN THIS'
              : action === 'unsuspend'
                ? 'Note (optional)'
                : 'Reason'}
          </span>
          <textarea rows={2} className={FIELD} value={reason}
            onChange={(e) => setReason(e.target.value)}
            placeholder={PLACEHOLDER[action]} />
          <span className="mt-0.5 block text-xs text-slate-400">{HINT[action]}</span>
        </label>
      )}

      <button
        onClick={() => run.mutate()}
        disabled={run.isPending
          || ((needsReason || isGraceOverride) && reason.trim().length === 0)}
        className={`mt-4 w-full rounded px-3 py-2 text-sm font-medium text-white disabled:opacity-60 ${
          action === 'suspend' || action === 'cancel' || action === 'archive'
            ? 'bg-amber-600 hover:bg-amber-700'
            : 'bg-brand-600 hover:bg-brand-700'}`}>
        {run.isPending ? 'Saving…' : LABEL[action]}
      </button>
    </div>
  )
}

const LABEL: Record<Action, string> = {
  suspend: 'Suspend them',
  unsuspend: 'Lift the suspension',
  cancel: 'Cancel the subscription',
  archive: 'Archive them',
  unarchive: 'Bring them back',
  grace: 'Set the grace period',
}

const PLACEHOLDER: Record<Action, string> = {
  suspend: 'Three months unpaid and not answering the phone',
  unsuspend: 'Paid in full on the 14th',
  cancel: 'Moved to a competitor on price',
  archive: 'Left in August, keeping their data for a year',
  unarchive: '',
  grace: 'Pays every year, their accountant is slow',
}

const HINT: Record<Action, string> = {
  suspend: 'This exact sentence appears on their screen. Write it as you would say '
    + 'it to the principal, because that is who will read it.',
  unsuspend: 'Kept in the history beside the reason they were suspended.',
  cancel: 'The only churn data this business will ever have. "Too expensive" and '
    + '"we closed" are different problems.',
  archive: 'Recorded, and reversible.',
  unarchive: '',
  grace: 'A longer window is a favour and a shorter one is pressure. Both should '
    + 'be explainable a year from now.',
}

import { useState } from 'react'
import { useMutation, useQueryClient } from '@tanstack/react-query'
import {
  archiveSchool, cancelSubscription, reinstateSubscription, setGrace, suspendSchool,
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
 *             the console, and it does NOT write off what they owe. Since 0106
 *             it also shuts the software immediately, whatever the dates say.
 *   REINSTATE undo a cancellation. Puts back whatever the DATES say and raises
 *             no invoice.
 *   ARCHIVE   out of the console and off the renewal list. Data untouched.
 *             Reversible, and the required step before offboarding.
 *   GRACE     a different post-expiry window for this school only.
 *
 * Nothing here deletes anything. That is Offboard, and it is a different screen
 * with a different colour and a name to type.
 *
 * WHY REINSTATE EXISTS
 *
 * Suspend had Unsuspend and Archive had Unarchive. Cancel had NOTHING, and 0106
 * had just made cancelling throw every teacher and parent out of the software
 * the same second - so the cheapest mis-click on this screen was also the only
 * irreversible one, on a dialog whose heading promises the things you can do
 * SHORT of destroying a school. The only route back was Activate/Renew, which
 * raises an invoice, so undoing it meant billing a school that had already paid.
 */
type Action = 'suspend' | 'unsuspend' | 'cancel' | 'reinstate' | 'archive' | 'unarchive' | 'grace'

export function LifecycleDialog({ school, onClose, onDone }: {
  school: PlatformSchool
  onClose: () => void
  onDone: (message: string) => void
}) {
  const [action, setAction] = useState<Action | null>(null)
  // THE NUMBER THE OLD SCREEN NEVER SHOWED. fn_effective_status tests
  // `status = 'cancelled'` above it tests the dates, so cancelling a school in
  // September that has paid through June ends June this afternoon. The dialog
  // said only that the relationship was ending and the debt still stood.
  const paidDaysLeft = Math.max(0, school.days_left ?? 0)
  return (
    <div className="fixed inset-0 z-50 flex items-start justify-center overflow-y-auto bg-black/40 p-4">
      <div className="w-full max-w-lg rounded-lg bg-white p-5 shadow-lg">
        <div className="flex items-start justify-between gap-3">
          <div>
            <h2 className="text-base font-semibold text-slate-800">{school.school_name}</h2>
            <p className="text-sm text-slate-500">
              {school.plan_code} · {school.status}
              {school.suspended && <span className="text-danger-700"> · suspended by us</span>}
              {school.archived && <span className="text-slate-400"> · archived</span>}
              {school.outstanding > 0 && (
                <span className="text-due-800"> · owes {formatPkr(school.outstanding)}</span>
              )}
            </p>
            {school.suspended && school.suspend_reason && (
              <p className="mt-1 rounded bg-danger-50 px-2 py-1 text-xs text-danger-800">
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
              <Choice onClick={() => setAction('suspend')} title="Suspend: stop new entries now"
                body="Takes effect immediately whatever the licence says. They can still read,
                      print and export. They are shown the reason you type, so make it one you
                      would say on the phone."
                tone="warn" />
            )}
            <Choice onClick={() => setAction('grace')}
              title="Change their grace period"
              body="How long after expiry they keep working while a payment is in flight. For
                    the school that always pays late and always pays, or the one that needs
                    chasing every quarter." />
            {school.status !== 'cancelled' ? (
              <Choice onClick={() => setAction('cancel')} title="Cancel the subscription"
                body={`Ends the relationship today, whatever their dates say. Nothing is
                      deleted and anything they owe is still owed, but the owner drops to
                      an export screen and teachers and parents are shown a closed sign${
                        paidDaysLeft > 0
                          ? `. They have paid to ${school.expires_on}: cancelling throws away ${paidDaysLeft} day(s) of that`
                          : ''}.`}
                tone="warn" />
            ) : (
              <Choice onClick={() => setAction('reinstate')} title="Reinstate the subscription"
                body="For a cancellation that was a mistake. Puts back whatever their dates
                      say and raises no invoice. If their dates have run out they stay
                      locked, and renewing is what opens the software." />
            )}
            {school.archived ? (
              <Choice onClick={() => setAction('unarchive')} title="Bring them back into the list"
                body="Makes them visible again. Does not give them a licence. That is a
                      separate, priced decision." />
            ) : (
              <Choice onClick={() => setAction('archive')} title="Archive: hide them"
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
        tone === 'warn' ? 'border-due-300 bg-due-50/40' : 'border-slate-200'}`}>
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
  const graceProblem = !isGraceOverride ? null
    : !Number.isInteger(Number(days))
      ? 'Whole days only.'
    : Number(days) < 0 || Number(days) > 180
      ? 'Between 0 and 180 days. Leave it blank to put them back on the standard window.'
    : null

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
          // r.data used to read "their data is untouched and they keep read and
          // export access", which 0106 made false and 0108 rewrote. r.gave_up
          // and r.reversible are new, and both are things the operator would
          // otherwise find out from a phone call.
          return {
            title: 'Subscription cancelled.',
            lines: [r.note, r.data, r.gave_up ?? '', r.reversible],
          }
        }
        case 'reinstate': {
          const r = await reinstateSubscription(school.school_id, reason.trim() || null)
          return {
            title: r.back_in ? 'Back in.' : 'Reinstated, and still locked.',
            lines: [r.note, 'No invoice was raised.'],
          }
        }
        case 'archive': {
          const r = await archiveSchool(school.school_id, reason)
          return {
            title: `${school.school_name} archived.`,
            lines: [...r.what_this_did,
                    r.outstanding > 0
                      ? `They still owe ${formatPkr(r.outstanding)}: archiving does not write that off.`
                      : 'Nothing outstanding.'],
          }
        }
        case 'unarchive': {
          const r = await unarchiveSchool(school.school_id)
          return { title: 'Back in the list.', lines: [r.note] }
        }
        case 'grace': {
          // `min` and `max` on a number input are enforced by form validation
          // and there is no form here, so both were decoration: -5 and 9999 were
          // typeable, and Number('') is 0 rather than null, which silently means
          // something different from "leave it standard". graceProblem below
          // stops all three before they reach the database.
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

      {err && <p className="mt-2 rounded bg-danger-50 px-3 py-2 text-sm text-danger-700">{err}</p>}
      {graceProblem && (
        <p className="mt-2 rounded border border-due-200 bg-due-50 px-3 py-2 text-xs text-due-900">
          {graceProblem}
        </p>
      )}

      {/* WHAT CANCELLING ACTUALLY COSTS, ON THE SCREEN WHERE IT IS DECIDED.
          The reason box was the only thing here, so the last thing the operator
          read before pressing was a prompt for churn data. Since 0106 this
          action ends a paid period on the spot and takes every teacher and
          parent offline with it, and neither fact appeared anywhere. */}
      {action === 'cancel' && (
        <div className="mt-3 rounded border border-due-300 bg-due-50 px-3 py-2 text-xs text-due-900">
          <p className="font-medium">This takes effect today, not at the end of their term.</p>
          <ul className="mt-1 space-y-0.5">
            {(school.days_left ?? 0) > 0 && school.expires_on && (
              <li>
                They have paid to {school.expires_on}. Those {school.days_left} day(s) end
                the moment you press this.
              </li>
            )}
            <li>The owner and principal keep a screen that downloads everything.</li>
            <li>Teachers and parents are shown a closed sign when they sign in.</li>
            <li>Nothing is deleted, and Reinstate puts it all back without an invoice.</li>
          </ul>
        </div>
      )}

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

      {(needsReason || isGraceOverride || action === 'unsuspend' || action === 'reinstate') && (
        <label className="mt-3 block">
          <span className="text-xs font-medium text-slate-600">
            {action === 'suspend'
              ? 'Reason: THE SCHOOL IS SHOWN THIS'
              : action === 'unsuspend' || action === 'reinstate'
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
        disabled={run.isPending || graceProblem !== null
          || ((needsReason || isGraceOverride) && reason.trim().length === 0)}
        className={`mt-4 w-full rounded px-3 py-2 text-sm font-medium text-white disabled:opacity-60 ${
          action === 'suspend' || action === 'cancel' || action === 'archive'
            ? 'bg-due-600 hover:bg-due-700'
            : 'bg-brand-600 hover:bg-brand-700'}`}>
        {run.isPending ? 'Saving…' : LABEL[action]}
      </button>
    </div>
  )
}

const LABEL: Record<Action, string> = {
  reinstate: 'Reinstate them',
  suspend: 'Suspend them',
  unsuspend: 'Lift the suspension',
  cancel: 'Cancel the subscription',
  archive: 'Archive them',
  unarchive: 'Bring them back',
  grace: 'Set the grace period',
}

const PLACEHOLDER: Record<Action, string> = {
  reinstate: 'Cancelled the wrong row',
  suspend: 'Three months unpaid and not answering the phone',
  unsuspend: 'Paid in full on the 14th',
  cancel: 'Moved to a competitor on price',
  archive: 'Left in August, keeping their data for a year',
  unarchive: '',
  grace: 'Pays every year, their accountant is slow',
}

const HINT: Record<Action, string> = {
  reinstate: 'Optional, and kept in the history beside the cancellation it undoes.',
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

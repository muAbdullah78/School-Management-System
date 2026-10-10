import { useState } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import {
  limitRequests, grantStudentLimit, declineStudentLimit, type LimitRequest,
} from '@/lib/platform'
import { fmtDate, fmtDateTime } from '@/lib/format'
import { ChangePlanDialog } from './SchoolDetail'

const FIELD = 'w-full rounded border border-slate-300 px-2 py-1.5 text-sm'

/**
 * Schools asking for room for more pupils than their plan covers.
 *
 * Migration 0128 made the plan's student limit real: at the limit, an admission
 * is refused, and the refusal tells the school to ask for room from Settings,
 * Subscription. This screen is the other end of that sentence. Without it the
 * refusal would be a lie, which is why the two shipped together.
 *
 * WHY "MOVE UP A PLAN" IS THE DEFAULT ANSWER AND AN ALLOWANCE IS THE EXCEPTION
 *
 * Almost every request here is a school that has outgrown its plan, and the
 * honest answer to that is the next plan up, not a permanent exception that
 * quietly makes our pricing mean nothing. So the worklist computes the cheapest
 * plan on sale that would cover what they asked for, and the decline dialog
 * offers that sentence pre-written and editable. The allowance is still one
 * click away, because the real reasons to grant one exist: a school mid-term
 * that cannot move money until April, a group we are courting, a school we have
 * quoted a price to that is not on the price list.
 *
 * WHAT 0155 CHANGED. The two answers are now two different acts, and each kind
 * of request gets its own:
 *   move_up    goes through Change plan, which moves them now and suggests a
 *              pro-rata charge for the rest of their paid time that we accept,
 *              change or drop. It answers the request in the same breath.
 *   more_room  extra room on their plan, which ends at their next renewal (the
 *              end of what covers them today) and ends at once if they change
 *              plan. It used to be permanent, which is how a price list stops
 *              meaning anything.
 *
 * WHAT THE OPERATOR IS SHOWN, AND WHY EACH PIECE
 *
 * A request is decided days or weeks after it was written, and three numbers can
 * all be different by then: what the roll was when they asked, what it is now,
 * and what their plan covers. So all three are on the card, and when the roll
 * has since fallen back under the limit the card says so outright, because in
 * that case the right answer is usually to ask them whether they still need it.
 */
export function RoomRequests({ onOpenSchool }: { onOpenSchool?: (id: string) => void }) {
  const [status, setStatus] =
    useState<'pending' | 'granted' | 'declined' | 'withdrawn' | 'all'>('pending')
  const [acting, setActing] =
    useState<{ req: LimitRequest; mode: 'grant' | 'decline' | 'move' } | null>(null)
  const q = useQuery({
    queryKey: ['limitRequests', status], queryFn: () => limitRequests(status), retry: false,
  })

  const rows = q.data ?? []
  const pending = rows.filter((r) => r.status === 'pending')

  return (
    <div className="space-y-4">
      <div className="flex flex-wrap items-center justify-between gap-3">
        <div>
          <h2 className="text-sm font-semibold text-slate-800">
            {rows.length} request(s) for more room
          </h2>
          <p className="text-xs text-slate-500">
            A school reaches the number of pupils its plan covers and cannot admit
            the next child until this is answered. Every one of these is a school
            with a parent standing at the desk.
          </p>
        </div>
        <div className="flex gap-1 rounded border border-slate-300 bg-white p-0.5 text-sm">
          {(['pending', 'granted', 'declined', 'withdrawn', 'all'] as const).map((s) => (
            <button key={s} onClick={() => setStatus(s)}
              className={`rounded px-2 py-1 ${
                status === s ? 'bg-brand-600 text-white' : 'text-slate-600 hover:bg-slate-100'}`}>
              {s === 'all' ? 'All' : s[0].toUpperCase() + s.slice(1)}
            </button>
          ))}
        </div>
      </div>

      {q.error && (
        <p className="rounded border border-rose-200 bg-rose-50 px-3 py-2 text-sm text-rose-800">
          {(q.error as Error).message}
        </p>
      )}
      {q.isLoading && <p className="text-sm text-slate-500">Loading…</p>}

      {/* Not a count of work outstanding but a count of schools currently
          turning families away. Worth saying in words, because "3" on a tab
          reads the same whether it is three invoices or three closed doors. */}
      {status === 'pending' && pending.length > 0 && (
        <div className="rounded border border-amber-200 bg-amber-50 px-3 py-2 text-sm text-amber-900">
          {pending.filter((r) => r.effective_limit !== null
            && r.students_now >= r.effective_limit).length} of these{' '}
          {pending.length} school(s) are at their limit right now and cannot admit
          anybody until you answer.
        </div>
      )}

      {!q.isLoading && !q.error && rows.length === 0 && (
        <p className="rounded-lg border border-slate-200 bg-white px-3 py-2 text-sm text-slate-500">
          {status === 'pending'
            ? 'Nothing waiting. No school is being held up by us.'
            : 'Nothing here.'}
        </p>
      )}

      <div className="space-y-2">
        {rows.map((r) => (
          <RequestCard key={r.id} r={r} onOpenSchool={onOpenSchool}
            onAct={(mode) => setActing({ req: r, mode })} />
        ))}
      </div>

      {acting && acting.mode === 'move' && (
        <ChangePlanDialog
          schoolId={acting.req.school_id} schoolName={acting.req.school_name}
          initialPlan={acting.req.suggested_plan}
          initialReason={`They asked on ${fmtDate(acting.req.requested_at)} to move up: ${acting.req.reason}`}
          onClose={() => setActing(null)} />
      )}
      {acting && acting.mode !== 'move' && (
        <ActDialog req={acting.req} mode={acting.mode} onClose={() => setActing(null)} />
      )}
    </div>
  )
}

function RequestCard({ r, onAct, onOpenSchool }: {
  r: LimitRequest
  onAct: (mode: 'grant' | 'decline' | 'move') => void
  onOpenSchool?: (id: string) => void
}) {
  // Their plan already has an allowance on it. Worth flagging on the card,
  // because "grant 400" means something different when the last operator
  // already granted 300 against the plan's 150.
  const hasOverride = r.effective_limit !== null && r.effective_limit !== r.plan_covers
  const atLimit = r.effective_limit !== null && r.students_now >= r.effective_limit
  const rollFell = r.effective_limit !== null && r.students_now < r.effective_limit
    && r.count_at_request >= r.effective_limit
  const moved = r.students_now !== r.count_at_request

  return (
    <div className={`rounded border bg-white px-3 py-2 ${
      r.status === 'pending' && atLimit ? 'border-amber-300' : 'border-slate-200'}`}>
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div className="min-w-0">
          <div className="text-sm font-medium text-slate-800">
            {onOpenSchool ? (
              <button onClick={() => onOpenSchool(r.school_id)}
                className="text-brand-700 underline-offset-2 hover:underline">
                {r.school_name}
              </button>
            ) : r.school_name}
            <span className="ml-1.5 font-normal text-slate-500">
              on {r.plan_code}
            </span>
          </div>
          <div className="text-xs text-slate-500">
            {r.contact_name || 'No contact name'}
            {r.contact_phone && <> · <span className="font-mono">{r.contact_phone}</span></>}
          </div>
          <div className="mt-1 text-sm text-slate-700">
            {r.wants === 'move_up'
              ? <>Asking to be <span className="font-semibold">moved up</span> to a
                  plan that covers {r.requested_limit} pupils.</>
              : <>Asking for room for <span className="font-semibold">
                  {r.requested_limit}</span> pupils on their current plan.</>}
          </div>
          <div className="text-xs text-slate-500">
            {r.students_now} on the roll now
            {moved && <> (was {r.count_at_request} when they asked)</>}
            {' · '}
            {r.plan_covers === null
              ? 'their plan has no limit'
              : <>their {r.plan_code} plan covers {r.plan_covers}</>}
            {hasOverride && (
              <span className="text-slate-700">
                {' · '}already allowed {r.effective_limit}
              </span>
            )}
          </div>
          <div className="mt-1 text-xs text-slate-600">“{r.reason}”</div>
          <div className="mt-0.5 text-xs text-slate-400">
            Asked {fmtDateTime(r.requested_at)}
          </div>

          {/* The case where the honest answer is a question. They asked at the
              limit, admitted nobody, and somebody has since left or been struck
              off, so they have room again without us doing anything. */}
          {r.status === 'pending' && rollFell && (
            <div className="mt-1.5 rounded bg-slate-50 px-2 py-1 text-xs text-slate-600">
              Their roll has since fallen to {r.students_now}, under the{' '}
              {r.effective_limit} they are allowed, so nothing is stopping them
              today. Worth asking whether they still need this before you grant it.
            </div>
          )}

          {r.status === 'pending' && (
            r.suggested_plan === null ? (
              <div className="mt-1.5 rounded bg-rose-50 px-2 py-1 text-xs text-rose-800">
                No plan on the price list covers {r.requested_limit} pupils. This one
                needs a conversation and a price, not a button.
              </div>
            ) : r.wants === 'move_up' ? (
              /* They have already said they will pay more. This is a sale, not a
                 favour. Move them up opens Change plan with the plan that fits
                 already chosen: it moves them now, suggests what to charge for
                 the rest of their paid time, and answers this request. */
              <div className="mt-1.5 rounded bg-money-50 px-2 py-1 text-xs text-money-900">
                They have asked to move up, so this is a sale rather than a
                favour. <span className="font-medium">{r.suggested_plan}</span>{' '}
                ({r.suggested_plan_covers === null
                  ? 'no pupil limit, priced with them'
                  : `${r.suggested_plan_covers} pupils`}) fits. Move them up suggests
                what to charge for the rest of their paid time; you decide.
              </div>
            ) : r.suggested_plan !== r.plan_code ? (
              <div className="mt-1.5 rounded bg-sky-50 px-2 py-1 text-xs text-sky-900">
                Our <span className="font-medium">{r.suggested_plan}</span> plan covers{' '}
                {r.suggested_plan_covers} pupils, which would cover this. They asked
                for an exception rather than an upgrade, so if the answer is
                &ldquo;move up&rdquo;, say it in the note: they have not agreed to
                pay more.
              </div>
            ) : null
          )}

          {r.status !== 'pending' && (
            <div className={`mt-1 text-xs ${
              r.status === 'granted' ? 'text-emerald-700'
                : r.status === 'declined' ? 'text-rose-700' : 'text-slate-500'}`}>
              {r.status === 'granted'
                ? `Granted ${r.granted_limit ?? '?'}`
                : r.status === 'declined' ? 'Declined' : 'Withdrawn by the school'}
              {r.decided_at && ` ${fmtDate(r.decided_at)}`}
              {r.decision_note && `: ${r.decision_note}`}
              {r.status === 'granted' && r.granted_limit !== null
                && r.granted_limit < r.requested_limit
                && <> (less than the {r.requested_limit} they asked for)</>}
            </div>
          )}
        </div>

        {r.status === 'pending' && (
          <div className="shrink-0 space-y-1 text-right">
            {atLimit && (
              <div className="text-xs font-medium text-amber-700">
                At their limit now
              </div>
            )}
            <div className="flex gap-2">
              {r.wants === 'move_up' ? (
                <button onClick={() => onAct('move')}
                  className="rounded bg-brand-600 px-2 py-1 text-xs font-medium text-white hover:bg-brand-700">
                  Move them up
                </button>
              ) : r.plan_covers !== null && (
                <button onClick={() => onAct('grant')}
                  className="rounded bg-brand-600 px-2 py-1 text-xs font-medium text-white hover:bg-brand-700">
                  Give them room
                </button>
              )}
              <button onClick={() => onAct('decline')}
                className="rounded border border-slate-300 px-2 py-1 text-xs text-slate-600 hover:bg-slate-50">
                Answer no
              </button>
            </div>
          </div>
        )}
      </div>
    </div>
  )
}

function ActDialog({ req, mode, onClose }: {
  req: LimitRequest; mode: 'grant' | 'decline'; onClose: () => void
}) {
  const qc = useQueryClient()
  const [limit, setLimit] = useState(String(req.requested_limit))
  const [note, setNote] = useState(
    // The decline reason pre-written, because the sentence that helps the school
    // is the one naming the plan that solves their problem, and an operator
    // answering nine of these will not type it nine times. Editable, and empty
    // when there is no plan to name so nobody sends a school a sentence about
    // a plan that does not exist.
    //
    // IT DOES NOT TELL THEM TO MOVE THEMSELVES UP. Nothing in this product lets
    // a school change its own plan: plans move only by us. It tells them to ask,
    // which they can do from Settings, Subscription.
    mode === 'decline' && req.suggested_plan && req.suggested_plan !== req.plan_code
      ? `Our ${req.suggested_plan} plan `
        + (req.suggested_plan_covers === null
          ? 'has no pupil limit '
          : `covers ${req.suggested_plan_covers} pupils `)
        + `and is the right fit for a school your size. Ask us to move you up from `
        + `Settings, Subscription, or call us, and we will tell you what it costs `
        + `for the rest of your paid time.`
      : '',
  )
  const [err, setErr] = useState<string | null>(null)
  const [granted, setGranted] = useState<{ limit: number; until: string } | null>(null)

  const asked = req.requested_limit
  const want = Number(limit)
  const covers = req.plan_covers
  // Extra room is MORE than the plan covers; the database refuses anything at
  // or below it, because holding a school to fewer is a plan move, not room.
  const valid = Number.isInteger(want) && covers !== null && want > covers
  // Below what they asked is a PARTIAL grant, and the school reads the note as
  // the answer to "why did we get 200 when we asked for 400".
  const partial = valid && want < asked
  const noteOk = note.trim().length >= 8

  const act = useMutation({
    mutationFn: async () => {
      if (mode === 'decline') {
        await declineStudentLimit(req.id, note.trim())
        return null
      }
      const r = await grantStudentLimit(req.school_id, want, note.trim())
      return { limit: r.limit, until: r.until }
    },
    onSuccess: (r) => {
      void qc.invalidateQueries({ queryKey: ['limitRequests'] })
      void qc.invalidateQueries({ queryKey: ['platformSchools'] })
      void qc.invalidateQueries({ queryKey: ['schoolDetail'] })
      if (r) setGranted(r)
      else onClose()
    },
    onError: (e) => setErr((e as Error).message),
  })

  if (granted) {
    return (
      <div className="fixed inset-0 z-50 flex items-start justify-center overflow-y-auto bg-black/40 p-4 sm:items-center">
        <div role="dialog" aria-modal="true" aria-label="Room given"
          className="w-full max-w-md rounded-lg bg-white p-4 shadow-lg">
          <h3 className="text-sm font-semibold text-slate-800">{req.school_name} has room</h3>
          <p className="mt-2 text-sm text-slate-700">
            Room for <span className="font-medium">{granted.limit.toLocaleString()}</span> pupils
            until <span className="font-medium">{fmtDate(granted.until)}</span>, then their{' '}
            {req.plan_code} plan&rsquo;s limit of {covers?.toLocaleString()} applies again. Their
            request is answered with your note.
          </p>
          <button onClick={onClose}
            className="mt-4 w-full rounded bg-brand-600 px-3 py-2 text-sm font-medium text-white hover:bg-brand-700">
            Done
          </button>
        </div>
      </div>
    )
  }

  return (
    <div className="fixed inset-0 z-50 flex items-start justify-center overflow-y-auto bg-black/40 p-4 sm:items-center">
      <div role="dialog" aria-modal="true"
        aria-label={mode === 'grant' ? `Give ${req.school_name} room` : `Answer ${req.school_name} no`}
        className="w-full max-w-md rounded-lg bg-white p-4 shadow-lg">
        <h3 className="text-sm font-semibold text-slate-800">
          {mode === 'grant' ? 'Give' : 'Answer'} {req.school_name}
          {mode === 'grant' ? ' room' : ' no'}
        </h3>
        <p className="mt-0.5 text-xs text-slate-500">
          They asked {req.wants === 'move_up'
            ? `to be moved up to a plan covering ${asked} pupils`
            : `for room for ${asked} pupils on ${req.plan_code}`}, have{' '}
          {req.students_now} on the roll, and are {covers === null
            ? 'on a plan with no limit'
            : `allowed ${req.effective_limit ?? covers}`}.
        </p>

        {err && <p className="mt-3 rounded bg-danger-50 px-3 py-2 text-sm text-danger-800">{err}</p>}

        {mode === 'grant' && (
          <div className="mt-3 space-y-3">
            <label className="block">
              <span className="text-xs font-medium text-slate-600">
                Pupils they may have
              </span>
              <input type="number" min={(covers ?? 0) + 1} step={1} className={FIELD} value={limit}
                onChange={(e) => setLimit(e.target.value)} />
              <span className="mt-0.5 block text-xs text-slate-400">
                Until their next renewal, the end of what covers them today, then their{' '}
                {req.plan_code} plan&rsquo;s limit of {covers?.toLocaleString()} applies again.
                It bills them nothing, and moving them to another plan ends it at once.
              </span>
            </label>

            {!valid && limit.trim() !== '' && (
              <p className="rounded bg-due-50 px-2 py-1.5 text-xs text-due-900">
                Extra room is more than the {covers?.toLocaleString()} pupils their plan already
                covers. To hold a school to fewer, move it to a smaller plan from its page.
              </p>
            )}
            {partial && (
              <p className="rounded bg-due-50 px-2 py-1.5 text-xs text-due-900">
                Less than the {asked} they asked for. They will see the note below as
                the answer to why, so say what it would take to get the rest.
              </p>
            )}
          </div>
        )}

        <label className="mt-3 block">
          <span className="text-xs font-medium text-slate-600">
            {mode === 'decline' ? 'Why, in a sentence they will read' : 'Why they get it'}
            <span className="text-danger-600"> *</span>
          </span>
          <textarea rows={3} className={FIELD} value={note}
            onChange={(e) => setNote(e.target.value)} />
          <span className="mt-0.5 block text-xs text-slate-400">
            {mode === 'decline'
              ? 'This is shown to the school on their subscription screen. A request that comes back with nothing on it produces a phone call.'
              : 'Kept with the allowance and shown beside it on their page until it ends, with your name against it.'}
          </span>
        </label>

        <div className="mt-4 flex justify-end gap-2">
          <button onClick={onClose}
            className="rounded border border-slate-300 px-3 py-1.5 text-sm text-slate-600 hover:bg-slate-50">
            Cancel
          </button>
          <button
            disabled={act.isPending || (mode === 'grant' && !valid) || !noteOk}
            onClick={() => { setErr(null); act.mutate() }}
            className={`rounded px-3 py-1.5 text-sm font-medium text-white disabled:opacity-50 ${
              mode === 'grant' ? 'bg-brand-600 hover:bg-brand-700'
                : 'bg-slate-700 hover:bg-slate-800'}`}>
            {act.isPending ? 'Saving…'
              : mode === 'grant' ? `Allow ${valid ? want : '…'} pupils` : 'Send this answer'}
          </button>
        </div>
        {!noteOk && (
          <p className="mt-1 text-right text-xs text-slate-400">
            A reason is required here, and eight characters is the floor.
          </p>
        )}
      </div>
    </div>
  )
}

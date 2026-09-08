import { useState } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import {
  myStudentLimit, requestStudentLimit, withdrawStudentLimitRequest,
  type LimitWants, type MyStudentLimit,
} from '@/lib/db'
import { formatPkr } from '@/lib/licence'
import { termSentence } from '@/lib/plans'
import { fmtDate } from '@/lib/format'

const FIELD = 'w-full rounded border border-slate-300 px-2 py-1.5 text-sm'

/**
 * How many pupils the school may have, and how to ask for more.
 *
 * THE OTHER END OF A REFUSAL. Migration 0128 made the plan's student limit
 * real: at the limit, Admit is refused, and the message says to ask for more
 * room from Settings then Subscription. This panel is that box. Shipping the
 * block without it would have made the product's own error message a lie.
 *
 * WHY IT IS QUIET UNTIL IT MATTERS
 *
 * A school 40% into its plan does not need a panel about its limit, and a
 * banner a school sees every day is a banner it stops reading. So below 90% of
 * the limit this is one grey line with a link on it, and it opens into the full
 * thing on a click. From 90% it is amber and open, because that is the point
 * where somebody should be thinking about it. At 100% it leads with what has
 * stopped, since a school reading this screen at that moment came here from a
 * refusal.
 *
 * WHY IT ASKS WHICH OF THE TWO THINGS THEY WANT
 *
 * "We need room for 200 pupils" can mean let us past our limit on the plan we
 * pay for, or put us on the plan that covers 200. The school does not much care
 * which; it cares what the next child costs. We care a great deal: one is a
 * permanent hole in the price list and the other is a school agreeing to pay
 * more. Reading which one out of a sentence is a guess, and a guess here is a
 * phone call on every request. So the box asks, prices the answer, and sends
 * the choice through as a value.
 *
 * AND IT NEVER OFFERS A BUTTON THAT DOES NOT EXIST. Nothing in this product
 * lets a school change its own plan: activation is operator-only and every
 * renewal is a bank transfer confirmed by hand. "Move us up" is therefore a
 * REQUEST, and the wording says so.
 */
export function RoomForPupils() {
  const q = useQuery({ queryKey: ['myStudentLimit'], queryFn: myStudentLimit, retry: false })
  // Quiet on failure, like NextPaymentPanel above it. This sits on a screen
  // that works without it, and a red box over a read that may simply not be
  // applied yet would alarm a school for no reason.
  if (q.isLoading || q.error || !q.data) return null
  return <Body d={q.data} />
}

function Body({ d }: { d: MyStudentLimit }) {
  const [open, setOpen] = useState(false)

  // A plan with no limit at all, which is the by-arrangement one. There is
  // nothing to say and nothing to ask for.
  if (d.limit === null) {
    return (
      <section className="rounded-lg border border-slate-200 bg-white p-4">
        <div className="text-xs uppercase tracking-wide text-slate-500">Your roll</div>
        <p className="mt-1 text-sm text-slate-700">
          {d.students.toLocaleString()} pupils. Your plan has no limit on how many
          you may have.
        </p>
      </section>
    )
  }

  const req = d.request
  const waiting = req?.status === 'pending'
  // An answer they may not have seen yet. Shown whatever the roll is doing,
  // because a request that goes quiet is the thing that produces a phone call,
  // and this screen is where they were told the answer would appear.
  const answered = req && (req.status === 'granted' || req.status === 'declined')
  // The quiet form: nothing is close, nothing is in flight, nothing to read.
  const quiet = !d.warn && !waiting && !answered && !open

  if (quiet) {
    return (
      <section className="rounded-lg border border-slate-200 bg-white px-4 py-2.5">
        <div className="flex flex-wrap items-baseline justify-between gap-2 text-sm">
          <span className="text-slate-600">
            <span className="font-medium text-slate-800">
              {d.students.toLocaleString()}
            </span>{' '}
            of the {d.limit.toLocaleString()} pupils your plan covers
            {d.granted_extra && d.plan_covers !== null && (
              <span className="text-slate-500">
                {' '}({d.plan_covers.toLocaleString()} on the plan plus{' '}
                {(d.limit - d.plan_covers).toLocaleString()} we granted you)
              </span>
            )}
          </span>
          <button onClick={() => setOpen(true)}
            className="text-xs text-brand-700 hover:underline">
            Need room for more?
          </button>
        </div>
      </section>
    )
  }

  return (
    <section className={`rounded-lg border p-4 ${
      d.at_limit ? 'border-amber-300 bg-amber-50'
        : d.warn ? 'border-amber-200 bg-white' : 'border-slate-200 bg-white'}`}>
      <div className="text-xs font-semibold uppercase tracking-wide text-slate-500">
        {d.at_limit ? 'Your roll is full' : 'Room on your roll'}
      </div>

      <p className="mt-1 text-sm text-slate-800">
        <span className="text-lg font-semibold">{d.students.toLocaleString()}</span>{' '}
        of {d.limit.toLocaleString()} places used
        {d.room !== null && d.room > 0 && (
          <span className="text-slate-600">
            , {d.room.toLocaleString()} left
          </span>
        )}
        {d.granted_extra && d.plan_covers !== null && (
          <span className="text-slate-500">
            {' '}· {d.plan_covers.toLocaleString()} covered by your plan and{' '}
            {(d.limit - d.plan_covers).toLocaleString()} we granted you on top
          </span>
        )}
      </p>

      {/* WHAT HAS STOPPED AND WHAT HAS NOT, in that order, because a school
          reading this arrived from a refused admission and will not take in
          anything else until it knows how bad this is. */}
      {d.at_limit ? (
        <p className="mt-2 text-sm text-amber-900">
          <span className="font-medium">New admissions are paused</span> until
          there is room. Everything else is untouched: the register, the fees,
          the marks, the reports and every child already on the roll carry on
          exactly as before, and nothing has been deleted.
        </p>
      ) : (
        <p className="mt-2 text-sm text-slate-600">
          When the last place goes, new admissions pause until there is room.
          Asking now takes a minute and costs nothing.
        </p>
      )}

      {answered && req && <Answer req={req} />}

      {waiting && req ? <Waiting req={req} /> : <AskForm d={d} />}
    </section>
  )
}

function Answer({ req }: { req: NonNullable<MyStudentLimit['request']> }) {
  const granted = req.status === 'granted'
  return (
    <div className={`mt-3 rounded border px-3 py-2 text-sm ${
      granted ? 'border-emerald-200 bg-emerald-50 text-emerald-900'
        : 'border-slate-200 bg-white text-slate-700'}`}>
      <p className="font-medium">
        {granted
          ? `We gave you room for ${(req.granted_limit ?? 0).toLocaleString()} pupils`
          : 'We could not do this one'}
        {req.decided_at && (
          <span className="font-normal opacity-80"> · {fmtDate(req.decided_at)}</span>
        )}
      </p>
      {/* The reason verbatim, exactly as the rejected-payment note is shown a
          few sections down. A school that cannot see why is a school that
          phones. */}
      {req.decision_note && <p className="mt-0.5">{req.decision_note}</p>}
      {granted && req.granted_limit !== null && req.granted_limit < req.requested_limit && (
        <p className="mt-0.5 opacity-80">
          You asked for {req.requested_limit.toLocaleString()}. Ask again if you
          still need the rest.
        </p>
      )}
    </div>
  )
}

function Waiting({ req }: { req: NonNullable<MyStudentLimit['request']> }) {
  const qc = useQueryClient()
  const [err, setErr] = useState<string | null>(null)
  const drop = useMutation({
    mutationFn: withdrawStudentLimitRequest,
    onSuccess: () => {
      void qc.invalidateQueries({ queryKey: ['myStudentLimit'] })
    },
    onError: (e) => setErr((e as Error).message),
  })

  return (
    <div className="mt-3 rounded border border-slate-200 bg-white px-3 py-2 text-sm">
      <p className="font-medium text-slate-800">
        {req.wants === 'move_up'
          ? `You asked us to move you up to a plan covering ${req.requested_limit.toLocaleString()} pupils`
          : `You asked for room for ${req.requested_limit.toLocaleString()} pupils`}
      </p>
      <p className="mt-0.5 text-slate-600">
        Sent {fmtDate(req.requested_at)}. We will answer here.
      </p>
      <p className="mt-1 text-xs text-slate-500">You told us: “{req.reason}”</p>
      {err && <p className="mt-1 text-xs text-rose-700">{err}</p>}
      <button onClick={() => { setErr(null); drop.mutate() }} disabled={drop.isPending}
        className="mt-1.5 text-xs text-slate-400 hover:text-slate-700 hover:underline disabled:opacity-60">
        {drop.isPending ? 'Taking it back…' : 'Take this request back'}
      </button>
    </div>
  )
}

function AskForm({ d }: { d: MyStudentLimit }) {
  const qc = useQueryClient()
  const next = d.next_plan
  const [wants, setWants] = useState<LimitWants>('more_room')
  // A round number above what they have, not a blank box. A school that has to
  // invent a figure invents the smallest one that solves today, and is back
  // here in a month.
  const [howMany, setHowMany] = useState(String(roundUpRoom(d.limit ?? d.students)))
  const [reason, setReason] = useState('')
  const [err, setErr] = useState<string | null>(null)
  const [done, setDone] = useState<string | null>(null)

  // For an upgrade there is no number to type: the plan decides it. Deriving it
  // rather than syncing it into the input on a radio change, because a field
  // that rewrites itself when you press something else is a field people stop
  // trusting.
  const asking = wants === 'move_up' && next ? next.covers : Number(howMany)
  const validNumber = Number.isInteger(asking) && asking > (d.limit ?? 0)
  const reasonOk = reason.trim().length >= 8

  const send = useMutation({
    mutationFn: () => requestStudentLimit(asking, reason.trim(), wants),
    onSuccess: (r) => {
      setErr(null); setDone(r.what_next)
      void qc.invalidateQueries({ queryKey: ['myStudentLimit'] })
      void qc.invalidateQueries({ queryKey: ['licence'] })
    },
    onError: (e) => setErr((e as Error).message),
  })

  if (done) {
    return (
      <div className="mt-3 rounded border border-emerald-200 bg-emerald-50 px-3 py-2 text-sm text-emerald-900">
        <p className="font-medium">Sent. Thank you.</p>
        <p className="mt-0.5">{done}</p>
      </div>
    )
  }

  return (
    <div className="mt-3 rounded border border-slate-200 bg-white p-3">
      <p className="text-sm font-medium text-slate-800">Ask us for more room</p>

      {err && <p className="mt-2 rounded bg-rose-50 px-2 py-1.5 text-sm text-rose-800">{err}</p>}

      <div className="mt-2 space-y-2">
        <Choice
          on={wants === 'more_room'} onPick={() => setWants('more_room')}
          title="Give us room on the plan we have"
          detail={`Keep paying what you pay now, with room for more pupils than ${
            (d.plan_covers ?? d.limit ?? 0).toLocaleString()}. We do this for a school growing mid-term, and we will ask why.`}
        />
        {/* Only offered when there IS a bigger plan. A school already on the
            largest has nothing to move up to, and an option that leads nowhere
            is worse than no option. */}
        {next && (
          <Choice
            on={wants === 'move_up'} onPick={() => setWants('move_up')}
            title={`Move us up to ${next.name}`}
            detail={`Covers ${next.covers.toLocaleString()} pupils, at ${
              formatPkr(next.price)} ${termSentence(next.term_months)
              } instead of what you pay now. We will send you the price for the rest of your term first, and nothing changes until you are happy with it.`}
          />
        )}
      </div>

      {wants === 'more_room' && (
        <label className="mt-3 block">
          <span className="text-xs font-medium text-slate-600">
            How many pupils you need room for
          </span>
          <input type="number" min={(d.limit ?? 0) + 1} step={1} className={FIELD}
            value={howMany} onChange={(e) => setHowMany(e.target.value)} />
          <span className="mt-0.5 block text-xs text-slate-400">
            More than the {(d.limit ?? 0).toLocaleString()} you have now. Ask for
            the roll you expect by the end of the year, not by Friday: asking
            twice takes twice as long.
          </span>
        </label>
      )}

      <label className="mt-3 block">
        <span className="text-xs font-medium text-slate-600">Why you need it</span>
        <textarea rows={3} className={FIELD} value={reason}
          onChange={(e) => setReason(e.target.value)}
          placeholder="e.g. we are opening a second campus in April and expect 60 more children" />
        <span className="mt-0.5 block text-xs text-slate-400">
          This is what we read when we decide. We cannot see inside your school,
          so a line about what is happening is the whole difference between a yes
          and a phone call.
        </span>
      </label>

      <button
        onClick={() => { setErr(null); send.mutate() }}
        disabled={send.isPending || !validNumber || !reasonOk}
        className="mt-3 rounded bg-brand-600 px-3 py-2 text-sm font-medium text-white hover:bg-brand-700 disabled:opacity-60">
        {send.isPending ? 'Sending…'
          : wants === 'move_up' && next ? `Ask to move up to ${next.name}`
          : 'Send this request'}
      </button>
      {!validNumber && wants === 'more_room' && (
        <p className="mt-1 text-xs text-slate-400">
          Ask for more than the {(d.limit ?? 0).toLocaleString()} you already have.
        </p>
      )}
      {validNumber && !reasonOk && (
        <p className="mt-1 text-xs text-slate-400">
          A line about why, please. Eight characters is the floor.
        </p>
      )}
    </div>
  )
}

function Choice({ on, onPick, title, detail }: {
  on: boolean; onPick: () => void; title: string; detail: string
}) {
  return (
    <button type="button" onClick={onPick}
      className={`block w-full rounded border p-2.5 text-left ${
        on ? 'border-brand-500 bg-brand-50' : 'border-slate-200 hover:bg-slate-50'}`}>
      <div className="flex items-start gap-2">
        <span className={`mt-0.5 h-3.5 w-3.5 shrink-0 rounded-full border-2 ${
          on ? 'border-brand-600 bg-brand-600' : 'border-slate-300'}`} />
        <span className="min-w-0">
          <span className="block text-sm font-medium text-slate-800">{title}</span>
          <span className="block text-xs text-slate-600">{detail}</span>
        </span>
      </div>
    </button>
  )
}

/**
 * A sensible number to put in the box: the next round figure above the limit.
 *
 * Fifty up to 500 and a hundred beyond it, so a school on 150 is offered 200
 * and one on 600 is offered 700 rather than 650. Exported for its test: this is
 * arithmetic, and arithmetic in a component is arithmetic nothing checks.
 */
export function roundUpRoom(limit: number): number {
  const step = limit < 500 ? 50 : 100
  return (Math.floor(limit / step) + 1) * step
}

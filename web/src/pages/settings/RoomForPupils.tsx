import { useState } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import {
  myStudentLimit, requestStudentLimit, withdrawStudentLimitRequest,
  type LimitWants, type MyStudentLimit,
} from '@/lib/db'
import { formatPkr } from '@/lib/licence'
import { termSentence } from '@/lib/plans'
import type { SubscriptionView } from '@/lib/subscription'
import { fmtDate } from '@/lib/format'
import { buttonClass } from '@/components/ui'

const FIELD = 'mt-1 w-full rounded-lg border border-slate-300 bg-white px-3 py-2 text-sm focus:border-brand-500 focus:outline-none focus:ring-2 focus:ring-brand-100'

/**
 * What fn_my_student_limit actually returns since 0155, which is a little more
 * than MyStudentLimit in lib/db.ts says: when extra room ends, and a next plan
 * that may be Enterprise, with no pupil count and no list price. Read through
 * this wider shape so an Enterprise next plan cannot print "Rs 0" or crash on
 * a missing number.
 */
type NextPlan = {
  code: string; name: string; covers: number | null
  price: number | null; term_months: number; by_arrangement?: boolean
}
type Limit = Omit<MyStudentLimit, 'next_plan'> & {
  extra_until?: string | null
  next_plan: NextPlan | null
}

/**
 * The roll against the limit, as a bar, for the top of Subscription.
 *
 * THE COLOURS ARE THE DATABASE'S LINES, not this file's. `warn` (90%), `full`
 * (100%) and `over` come from fn__subscription_view, the same flags that
 * decide when an admission is refused, so the bar turns amber and red on
 * exactly the days the school's experience changes. The limit printed here
 * is the number at which Admit stops, nothing hidden beyond it.
 */
export function PupilMeter({ students, planName }: {
  students: SubscriptionView['students']; planName: string
}) {
  const { count, limit, plan_limit: planLimit } = students
  if (limit === null) {
    return (
      <div>
        <div className="text-xs font-semibold uppercase tracking-wide text-slate-500">Pupils</div>
        <p className="mt-0.5 text-sm text-slate-800">
          <span className="font-semibold tabular-nums">{count.toLocaleString()}</span> on the roll.{' '}
          <span className="text-slate-600">No pupil limit on {planName}.</span>
        </p>
      </div>
    )
  }
  const pct = limit > 0 ? Math.min(100, Math.round((100 * count) / limit)) : 100
  const tone = students.full || students.over ? 'danger' : students.warn ? 'due' : 'brand'
  const bar = { danger: 'bg-danger-500', due: 'bg-due-500', brand: 'bg-brand-500' }[tone]
  const over = Math.max(count - limit, 0)
  // Extra room is ours, it ends on a date, and the school is told both, so a
  // roll that fits today is not a surprise at the next renewal.
  const extra = students.extra_until && planLimit !== null && limit > planLimit ? limit - planLimit : null
  return (
    <div>
      <div className="flex flex-wrap items-baseline justify-between gap-2">
        <div className="text-xs font-semibold uppercase tracking-wide text-slate-500">Pupils</div>
        <div className="text-sm text-slate-800">
          <span className="font-semibold tabular-nums">{count.toLocaleString()}</span>
          <span className="text-slate-600"> of {limit.toLocaleString()}</span>
        </div>
      </div>
      <div className="mt-1.5 h-2 overflow-hidden rounded-full bg-slate-100" role="meter"
        aria-label="Pupils on the roll against your limit" aria-valuemin={0} aria-valuemax={limit}
        aria-valuenow={Math.min(count, limit)} aria-valuetext={`${count} of ${limit} pupils`}>
        <div className={`h-full rounded-full ${bar}`} style={{ width: `${count > 0 ? Math.max(pct, 2) : 0}%` }} />
      </div>
      <p className={`mt-1 text-xs ${tone === 'danger' ? 'text-danger-800' : tone === 'due' ? 'text-due-800' : 'text-slate-500'}`}>
        {over > 0
          ? `${over.toLocaleString()} more than your limit. New admissions are paused until there is room.`
          : students.full
            ? 'Your roll is full. New admissions are paused until there is room.'
            : students.warn
              ? `${(students.room ?? 0).toLocaleString()} places left. Ask us for room before the last one goes.`
              : `${(students.room ?? 0).toLocaleString()} places left.`}
      </p>
      {extra !== null && (
        <p className="mt-1 text-xs text-slate-600">
          Extra room for {extra.toLocaleString()} pupils until {fmtDate(students.extra_until)} ({limit.toLocaleString()} in
          all), then your plan&apos;s limit of {planLimit!.toLocaleString()} applies.
        </p>
      )}
    </div>
  )
}

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
 * which; it cares what the next child costs. We care a great deal: one is room
 * that ends at the next renewal and the other is a school agreeing to pay
 * more. Reading which one out of a sentence is a guess, and a guess here is a
 * phone call on every request. So the box asks, prices the answer, and sends
 * the choice through as a value.
 *
 * AND IT NEVER OFFERS A BUTTON THAT DOES NOT EXIST. Since 0155 only we move a
 * school between plans, from the console. "Move us up" is therefore a REQUEST,
 * and the wording says so and says what happens next.
 */
export function RoomForPupils() {
  const q = useQuery({ queryKey: ['myStudentLimit'], queryFn: myStudentLimit, retry: false })
  // Quiet on failure, like NextPaymentPanel above it. This sits on a screen
  // that works without it, and a red box over a read that may simply not be
  // applied yet would alarm a school for no reason.
  if (q.isLoading || q.error || !q.data) return null
  return <Body d={q.data} />
}

function Body({ d }: { d: Limit }) {
  const [open, setOpen] = useState(false)

  // Enterprise has no limit at all. There is nothing to ask for, so there is
  // no form: a box that can only be refused is worse than no box.
  if (d.limit === null) {
    return (
      <section className="rounded-2xl border border-slate-200 bg-white px-4 py-3 shadow-card">
        <p className="text-sm text-slate-700">
          {d.students.toLocaleString()} pupils. Your plan has no pupil limit, so there is nothing to ask for here.
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
  const extra = d.granted_extra && d.plan_covers !== null ? d.limit - d.plan_covers : null

  if (quiet) {
    return (
      <section className="rounded-2xl border border-slate-200 bg-white px-4 py-3 shadow-card">
        <div className="flex flex-wrap items-baseline justify-between gap-2 text-sm">
          <span className="text-slate-600">
            <span className="font-medium text-slate-800">
              {d.students.toLocaleString()}
            </span>{' '}
            of the {d.limit.toLocaleString()} pupils your plan covers
            {extra !== null && extra > 0 && (
              <span className="text-slate-500">
                {' '}({d.plan_covers!.toLocaleString()} on the plan and {extra.toLocaleString()} extra
                {d.extra_until ? ` until ${fmtDate(d.extra_until)}` : ''})
              </span>
            )}
          </span>
          <button type="button" onClick={() => setOpen(true)}
            className={buttonClass({ variant: 'soft', size: 'sm' })}>
            Need room for more?
          </button>
        </div>
      </section>
    )
  }

  // OVER, not just full. A school can be above its limit (a plan changed under
  // it, extra room that ended at a renewal), and "238 of 150 places used" read
  // as a typo. It says how far over, because that is the number the request
  // has to cover.
  const over = Math.max(d.students - d.limit, 0)
  return (
    <section className={`rounded-2xl border p-4 shadow-card ${
      over > 0 ? 'border-danger-200 bg-danger-50/60'
        : d.at_limit ? 'border-due-300 bg-due-50'
          : d.warn ? 'border-due-200 bg-white' : 'border-slate-200 bg-white'}`}>
      <h2 className="text-xs font-semibold uppercase tracking-wide text-slate-500">
        {over > 0 ? 'Your roll is over your limit' : d.at_limit ? 'Your roll is full' : 'Room on your roll'}
      </h2>

      <p className="mt-1 text-sm text-slate-800">
        <span className="text-lg font-semibold tabular-nums">{d.students.toLocaleString()}</span>{' '}
        {over > 0 ? (
          <>pupils, <span className="font-semibold text-danger-800">{over.toLocaleString()} more</span> than the {d.limit.toLocaleString()} your plan covers</>
        ) : (
          <>of {d.limit.toLocaleString()} places used</>
        )}
        {d.room !== null && d.room > 0 && (
          <span className="text-slate-600">
            , {d.room.toLocaleString()} left
          </span>
        )}
      </p>
      {extra !== null && extra > 0 && (
        <p className="mt-0.5 text-xs text-slate-600">
          Extra room for {extra.toLocaleString()} pupils{d.extra_until ? ` until ${fmtDate(d.extra_until)}` : ''},
          then your plan&apos;s limit of {d.plan_covers!.toLocaleString()} applies.
        </p>
      )}

      {/* WHAT HAS STOPPED AND WHAT HAS NOT, in that order, because a school
          reading this arrived from a refused admission and will not take in
          anything else until it knows how bad this is. */}
      {d.at_limit ? (
        <p className={`mt-2 text-sm ${over > 0 ? 'text-danger-900' : 'text-due-900'}`}>
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
    <div className={`mt-3 rounded-xl border px-3 py-2 text-sm ${
      granted ? 'border-brand-200 bg-brand-50 text-brand-900'
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
    <div className="mt-3 rounded-xl border border-slate-200 bg-white px-3 py-2 text-sm">
      <p className="font-medium text-slate-800">
        {req.wants === 'move_up'
          ? `You asked us to move you up to a plan with room for ${req.requested_limit.toLocaleString()} pupils`
          : `You asked for room for ${req.requested_limit.toLocaleString()} pupils`}
      </p>
      <p className="mt-0.5 text-slate-600">
        Sent {fmtDate(req.requested_at)}. We will answer here, usually the same working day.
      </p>
      {/* What happens next, so a school waiting knows what it is waiting for. */}
      <p className="mt-0.5 text-slate-600">
        {req.wants === 'move_up'
          ? 'We will work out what the bigger plan costs for the rest of the period you have paid for and tell you before anything changes.'
          : 'If we give you extra room, it lasts until your next renewal. After that your plan’s limit applies again.'}
      </p>
      <p className="mt-1 text-xs text-slate-500">You told us: “{req.reason}”</p>
      {err && <p className="mt-1 text-xs text-danger-700">{err}</p>}
      <button type="button" onClick={() => { setErr(null); drop.mutate() }} disabled={drop.isPending}
        className={buttonClass({ variant: 'soft', tone: 'neutral', size: 'sm', className: 'mt-2' })}>
        {drop.isPending ? 'Taking it back…' : 'Take this request back'}
      </button>
    </div>
  )
}

function AskForm({ d }: { d: Limit }) {
  const qc = useQueryClient()
  const next = d.next_plan
  // Enterprise has no pupil count to move up TO, so the school still says how
  // many it expects, and that number is what we read when we price it.
  const nextCovers = next && !next.by_arrangement ? next.covers : null
  const [wants, setWants] = useState<LimitWants>('more_room')
  // A round number above what they have, not a blank box. A school that has to
  // invent a figure invents the smallest one that solves today, and is back
  // here in a month.
  // Above the ROLL as well as the limit. A school with 238 pupils on a 150
  // plan was offered "room for 200", which the database took, and which would
  // have left every admission refused after it was granted.
  const floor = Math.max(d.limit ?? 0, d.students)
  const [howMany, setHowMany] = useState(String(roundUpRoom(floor)))
  const [reason, setReason] = useState('')
  const [err, setErr] = useState<string | null>(null)
  const [done, setDone] = useState<string | null>(null)

  // For a move up to a plan with a limit there is no number to type: the plan
  // decides it. Deriving it rather than syncing it into the input on a radio
  // change, because a field that rewrites itself when you press something
  // else is a field people stop trusting.
  const typed = wants === 'more_room' || nextCovers === null
  const asking = typed || nextCovers === null ? Number(howMany) : nextCovers
  const validNumber = Number.isInteger(asking) && asking > floor
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
      <div className="mt-3 rounded-xl border border-brand-200 bg-brand-50 px-3 py-2 text-sm text-brand-900" role="status">
        <p className="font-medium">Sent. Thank you.</p>
        <p className="mt-0.5">{done}</p>
      </div>
    )
  }

  return (
    <div className="mt-3 rounded-xl border border-slate-200 bg-white p-3">
      <p className="text-sm font-medium text-slate-800">Ask us for more room</p>
      <p className="mt-0.5 text-xs text-slate-600">
        Plans are changed by us, not from this screen. Tell us what you need and we answer here, usually the same
        working day. Nothing changes, and nothing you have entered is touched, until we do.
      </p>

      {err && <p className="mt-2 rounded-lg bg-danger-50 px-2 py-1.5 text-sm text-danger-800">{err}</p>}

      <div className="mt-2 space-y-2" role="radiogroup" aria-label="What you are asking for">
        <Choice
          on={wants === 'more_room'} onPick={() => setWants('more_room')}
          title="Give us room on the plan we have"
          detail={`Keep paying what you pay now, with room for more than ${
            (d.plan_covers ?? d.limit ?? 0).toLocaleString()} pupils until your next renewal. We do this for a school growing mid-term, and we will ask why.`}
        />
        {/* Only offered when there IS a bigger plan. A school already on the
            largest has nothing to move up to, and an option that leads nowhere
            is worse than no option. */}
        {next && (
          <Choice
            on={wants === 'move_up'} onPick={() => setWants('move_up')}
            title={`Move us up to ${next.name}`}
            detail={moveUpDetail(next)}
          />
        )}
      </div>

      {typed && (
        <label className="mt-3 block">
          <span className="text-xs font-medium text-slate-600">
            How many pupils you need room for
          </span>
          <input type="number" inputMode="numeric" min={floor + 1} step={1} className={FIELD}
            value={howMany} onChange={(e) => setHowMany(e.target.value)} />
          <span className="mt-0.5 block text-xs text-slate-500">
            More than the {floor.toLocaleString()} {d.students > (d.limit ?? 0) ? 'pupils on your roll now' : 'your plan covers now'}. Ask for
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
        <span className="mt-0.5 block text-xs text-slate-500">
          This is what we read when we decide. We cannot see inside your school,
          so a line about what is happening is the whole difference between a yes
          and a phone call.
        </span>
      </label>

      <button type="button"
        onClick={() => { setErr(null); send.mutate() }}
        disabled={send.isPending || !validNumber || !reasonOk}
        className={buttonClass({ className: 'mt-3 w-full sm:w-auto' })}>
        {send.isPending ? 'Sending…'
          : wants === 'move_up' && next ? `Ask to move up to ${next.name}`
          : 'Send this request'}
      </button>
      {!validNumber && typed && (
        <p className="mt-1 text-xs text-slate-500">
          Ask for more than {floor.toLocaleString()}.
        </p>
      )}
      {validNumber && !reasonOk && (
        <p className="mt-1 text-xs text-slate-500">
          A line about why, please. Eight characters is the floor.
        </p>
      )}
    </div>
  )
}

/** What moving up means, priced only from what the database sent. */
function moveUpDetail(next: NextPlan): string {
  if (next.by_arrangement || next.covers === null) {
    return `No pupil limit. ${next.name} is priced with each school, so we will call you to agree yours, `
      + 'and nothing changes until you are happy with it.'
  }
  const price = next.price !== null && next.price > 0
    ? `, at ${formatPkr(next.price)} ${termSentence(next.term_months)} instead of what you pay now` : ''
  return `Covers up to ${next.covers.toLocaleString()} pupils${price}. We will work out what the move costs for the rest `
    + 'of the period you have paid for and tell you first. Nothing changes until you are happy with it.'
}

function Choice({ on, onPick, title, detail }: {
  on: boolean; onPick: () => void; title: string; detail: string
}) {
  return (
    <button type="button" onClick={onPick} role="radio" aria-checked={on}
      className={`block w-full rounded-xl border p-2.5 text-left focus:outline-none focus-visible:ring-2 focus-visible:ring-brand-500 ${
        on ? 'border-brand-500 bg-brand-50' : 'border-slate-200 hover:bg-slate-50'}`}>
      <div className="flex items-start gap-2">
        <span aria-hidden="true" className={`mt-0.5 h-3.5 w-3.5 shrink-0 rounded-full border-2 ${
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

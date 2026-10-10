import { useEffect, useState } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import {
  changeSchoolPlan, clearStudentLimit, grantStudentLimit, planChangeQuote, schoolDetail,
  setSchoolPrice,
  type ReadinessItem, type SchoolDetail as Detail,
} from '@/lib/platform'
import { listSignupPlans, termSentence } from '@/lib/plans'
import type { SubscriptionView } from '@/lib/subscription'
import { formatPkr } from '@/lib/licence'
import { fmtDate, fmtDateTime } from '@/lib/format'
import { today } from '@/lib/dates'
import { money, statusWords, wholeRupees } from './status'

const FIELD = 'w-full rounded border border-slate-300 px-2 py-1.5 text-sm'

/**
 * One school, everything the operator can know without opening it.
 *
 * The console used to hold eight fields per school. This answers the question a
 * list cannot: is this a customer, or a name that paid once?
 *
 * The order on the page is the order the questions get asked in a real morning:
 *
 *   1. Are they LIVE?      the readiness checklist, first, because a school
 *                          stuck at "no fee heads" is the one call worth making
 *                          today and nothing else on the page tells you that.
 *   2. Are they USING it?  activity dates. A school whose last attendance was in
 *                          April is not using attendance, whatever the roll says.
 *   3. Who ARE they?       subscription, pupils, money.
 *   4. Who can sign in?    and has the accountant you set up ever bothered.
 *
 * Nothing here names a child, a guardian or a family: see the note at the foot
 * of the page, which says so to the operator as well, because a screen that
 * quietly omits something reads as a screen that is missing it.
 */
/**
 * The Overview tab of the school workspace.
 *
 * This used to be its own centered modal, reachable only by clicking the
 * school's NAME on the card - a plain-looking link beside five other plain
 * links, which is why the richest screen in the console was also the least
 * discovered. It is now what you get by clicking the row, and the identity, the
 * status chips, Close and View as school all belong to the drawer around it
 * rather than being repeated here.
 */
export function OverviewTab({ schoolId }: { schoolId: string }) {
  const q = useQuery({
    queryKey: ['schoolDetail', schoolId],
    queryFn: () => schoolDetail(schoolId),
  })
  if (q.isLoading) return <p className="text-sm text-slate-500">Loading…</p>
  if (q.error) return <p className="text-sm text-danger-600">{(q.error as Error).message}</p>
  if (!q.data) return null
  return <Body d={q.data} />
}

function Body({ d }: { d: Detail }) {
  // The first unfinished step. This is the single most useful thing on the page:
  // it turns "they seem quiet" into a sentence you can say on the phone.
  const stuckAt = d.readiness.find((r) => !r.done)
  const done = d.readiness.filter((r) => r.done).length
  const v = d.subscription ?? null

  return (
    <>
      {/* Signed up, and what they call themselves. The name and contact line
          live in the drawer header now; this is the part that does not. */}
      <p className="text-xs text-slate-400">
        Signed up {fmtDate(d.school.created_at)}
        {/* A school that renamed itself in its own settings is worth noticing:
            it means somebody is in there using it. */}
        {d.school.display_name && d.school.display_name !== d.school.name && (
          <> · calls itself &ldquo;{d.school.display_name}&rdquo; in the app</>
        )}
      </p>

      {/* 1. ARE THEY LIVE? */}
      <section className="mt-4">
        <SectionTitle>
          Getting started: {done} of {d.readiness.length} done
        </SectionTitle>
        {stuckAt ? (
          <div className="mt-2 rounded border border-due-200 bg-due-50 px-3 py-2 text-sm text-due-900">
            <span className="font-medium">Stuck at: {stuckAt.label}.</span>{' '}
            {stuckAt.detail || 'Worth a phone call.'}
          </div>
        ) : (
          <div className="mt-2 rounded border border-money-200 bg-money-50 px-3 py-2 text-sm text-money-900">
            Fully set up and billing.
          </div>
        )}
        <ul className="mt-2 grid gap-1 sm:grid-cols-2">
          {d.readiness.map((r) => <ReadyRow key={r.key} r={r} />)}
        </ul>
      </section>

      {/* 2. ARE THEY USING IT? */}
      <section className="mt-4">
        <SectionTitle>Last used</SectionTitle>
        <div className="mt-2 grid gap-x-4 gap-y-1 text-sm sm:grid-cols-2">
          <Since label="Payment taken" at={d.activity.last_payment} />
          <Since label="Challans generated" at={d.activity.last_invoice} />
          <Since label="Attendance marked" at={d.activity.last_attendance} />
          <Since label="Marks entered" at={d.activity.last_mark} />
          <Since label="Certificate issued" at={d.activity.last_certificate} />
          <Since label="Till closed" at={d.activity.last_till_close} />
        </div>
      </section>

      {/* 3. SUBSCRIPTION AND MONEY */}
      <section className="mt-4 grid gap-3 sm:grid-cols-2">
        <div className="rounded border border-slate-200 p-3">
          <SectionTitle>Subscription</SectionTitle>
          {v ? (
            <SubscriptionLines v={v} d={d} />
          ) : d.licence ? (
            // A database without 0155 has no subscription view. Say what the
            // old licence knows rather than render an empty box.
            <div className="mt-1.5 space-y-0.5 text-sm text-slate-700">
              <div>
                <span className="font-medium">{d.licence.plan_name}</span>
                {' · '}{statusWords(d.licence.status)}
              </div>
              <div className="text-xs text-slate-500">
                This database does not describe the subscription in full yet.
              </div>
            </div>
          ) : (
            <p className="mt-1.5 text-sm text-danger-700">
              No subscription row at all. This school cannot use the software.
            </p>
          )}
          {v && <StudentLimitBlock d={d} v={v} />}
        </div>

        <div className="rounded border border-slate-200 p-3">
          <SectionTitle>Money</SectionTitle>
          <div className="mt-1.5 space-y-0.5 text-sm text-slate-700">
            <div>Invoiced {formatPkr(d.money.invoiced)} over {d.money.invoice_count} invoice(s)</div>
            <div>Paid {formatPkr(d.money.paid)}</div>
            <div className={d.money.outstanding > 0 ? 'font-medium text-due-800' : ''}>
              Owed {formatPkr(v ? v.owed : d.money.outstanding)}
            </div>
            {/* Money paid in and not yet against any invoice. It is used on the
                next invoice the moment one is raised, so it is worth knowing
                before raising one. */}
            {v && v.credit > 0 && (
              <div className="text-money-700">
                {formatPkr(v.credit)} in credit: it comes off their next invoice
              </div>
            )}
            {v?.open_invoice && (
              <div className="text-xs text-slate-600">
                Open: {v.open_invoice.doc_no ?? 'an invoice'} for {v.open_invoice.months} month(s)
                from {fmtDate(v.open_invoice.period_start)}, {formatPkr(v.open_invoice.total)},
                {' '}{formatPkr(v.open_invoice.owed)} owed
                {v.open_invoice.due_on && <>, due {fmtDate(v.open_invoice.due_on)}</>}
              </div>
            )}
            <div className="text-xs text-slate-400">
              Last payment {d.money.last_paid_on ? fmtDate(d.money.last_paid_on) : 'never'}
            </div>
            {/* THE DISCOUNT BADGE THAT WAS MISSING. Before 0144 the Discounts
                tab said one school was on SPRING24 and this page said nothing,
                so an operator opening the one school in particular could not
                see the promo attached to the invoice they were reading. */}
            {d.discount && <DiscountBadge d={d.discount} />}
          </div>
        </div>
      </section>

      {/* 4. WHO CAN SIGN IN */}
      <section className="mt-4">
        <SectionTitle>Logins ({d.people.length})</SectionTitle>
        {d.people.length === 0 ? (
          <p className="mt-1.5 text-sm text-danger-700">
            Nobody can sign in. The school was created and never given an owner login.
          </p>
        ) : (
          <table className="mt-1.5 w-full text-sm">
            <tbody className="divide-y divide-slate-100">
              {d.people.map((p, i) => (
                <tr key={i} className={p.active ? '' : 'opacity-60'}>
                  <td className="py-1.5 text-slate-800">{p.name}</td>
                  <td className="py-1.5 text-slate-500">{p.role.replace('_', ' ')}</td>
                  <td className="py-1.5 text-right text-xs">
                    {/* The churn signal nothing in this product could see before:
                        an invited accountant who never signed in is a seat
                        nobody is using and probably does not know about. */}
                    {!p.ever_signed_in
                      ? <span className="font-medium text-due-700">never signed in</span>
                      : <span className="text-slate-400">last in {fmtDate(p.last_sign_in)}</span>}
                    {!p.active && <span className="ml-2 text-slate-400">· switched off</span>}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        )}
      </section>

      <div className="mt-4 border-t border-slate-100 pt-2 text-xs text-slate-400">
        Counts and dates only. Nothing here names a child, a guardian or a family.
        Use <span className="font-medium">View as school</span> for that: it is
        read-only, recorded, and the school can see the visit.
        {d.not_recorded.length > 0 && (
          <> Not recorded anywhere: {d.not_recorded.join('; ')}.</>
        )}
      </div>
    </>
  )
}

/** "Rs 4,000 a month", or what an unpriced Enterprise school is waiting for. */
function priceWords(v: SubscriptionView): string {
  if (v.plan.by_arrangement && !v.price.priced) return 'no price agreed yet'
  if (v.price.month == null) return 'no price'
  return `${formatPkr(v.price.month)} a month`
}

/**
 * Why a locked school is locked, in our words rather than the school's.
 *
 * lockedSentence() in lib/subscription.ts is written TO the school ("Your free
 * trial has ended"). The operator needs the same fact as a decision: what has
 * to happen for them to open again.
 */
function lockedWords(v: SubscriptionView): string | null {
  switch (v.locked_because) {
    case 'unpaid':
      return `Locked: a payment is more than ${v.grace_days} days overdue. Paying it opens them.`
    case 'expired':
      return v.in_trial
        ? `Locked: the trial and its ${v.grace_days} days of grace have ended. Paying the first invoice opens them.`
        : `Locked: their paid time and ${v.grace_days} days of grace have run out. Paying opens them.`
    case 'suspended':
      return `Suspended by us${v.suspend_reason ? `: ${v.suspend_reason}` : ''}.`
    case 'cancelled':
      return 'Cancelled.'
    // needs_price has its own box, because it is our move and not theirs.
    default:
      return null
  }
}

/**
 * The flag for an Enterprise school we have not priced.
 *
 * Its own box, in the colour of a stopped school, because it is the one
 * subscription state where WE are the hold-up: there is no price, so there is
 * nothing to invoice, and the school locks the day after its trial with no
 * grace at all. The date is the deadline for the phone call.
 */
export function NeedsPriceBox({ v }: { v: SubscriptionView }) {
  if (!v.needs_price) return null
  return (
    <div className="mt-2 rounded border border-danger-300 bg-danger-50 px-3 py-2 text-sm text-danger-900">
      <div className="font-medium">No price agreed yet.</div>
      {v.locked_because === 'needs_price' ? (
        <>
          Their trial ended on {fmtDate(v.trial_ends_on)} and they are locked until
          we set their price. Setting it gives them the usual {v.grace_days} days to pay.
        </>
      ) : (
        <>
          {v.plan.name} is priced by us, school by school. With no price there is
          nothing to invoice, and they lock
          {v.locks_on ? <> on {fmtDate(v.locks_on)}</> : <> when their trial ends</>}
          {v.trial_ends_on && <>, the day after their trial ends ({fmtDate(v.trial_ends_on)})</>},
          with no grace. Set it from Billing, Plan and price.
        </>
      )}
    </div>
  )
}

function SubscriptionLines({ v, d }: { v: SubscriptionView; d: Detail }) {
  const locked = lockedWords(v)
  const suggested = d.licence?.suggested_plan ?? null
  return (
    <div className="mt-1.5 space-y-0.5 text-sm text-slate-700">
      <div>
        <span className="font-medium">{v.plan.name}</span>
        {' · '}{priceWords(v)}
        {' · '}{statusWords(v.status)}
      </div>
      <div className="text-xs text-slate-500">
        Pays {termSentence(v.term_months)}
      </div>
      <div>
        {v.paid_through
          ? <>Paid through <span className="font-medium">{fmtDate(v.paid_through)}</span></>
          : v.in_trial && v.trial_ends_on
            ? <>On trial to <span className="font-medium">{fmtDate(v.trial_ends_on)}</span>, nothing paid yet</>
            : 'Nothing paid yet'}
        {/* The date that matters on the phone. Only while they are working:
            for a locked school it is in the past and the sentence below says
            what opens them instead. */}
        {v.locks_on && v.status !== 'locked' && v.status !== 'cancelled' && !v.suspended && (
          <span className="text-slate-500"> · locks on {fmtDate(v.locks_on)} if nothing more is paid</span>
        )}
      </div>
      {locked && <div className="font-medium text-danger-700">{locked}</div>}
      <NeedsPriceBox v={v} />

      <div className="pt-1">
        {v.students.count.toLocaleString()} pupils
        {v.students.limit !== null
          ? <span className="text-slate-400"> of {v.students.limit.toLocaleString()}</span>
          : <span className="text-slate-400"> · no pupil limit</span>}
        {/* What they told us at signup, beside what the roll says. A big gap
            is either a school still loading its pupils or one that chose its
            number to land on the cheaper plan, and both are worth a call. */}
        {v.students.declared != null && v.students.declared !== v.students.count && (
          <span className="ml-1 text-xs text-slate-500">
            (said {v.students.declared.toLocaleString()} at signup)
          </span>
        )}
      </div>
      {v.students.over ? (
        <div className="text-danger-700">
          Over its limit: new admissions are refused right now.
          {suggested && suggested !== v.plan.code && (
            <> <span className="font-medium">{suggested}</span> fits their roll: move them with Change plan on the Billing tab.</>
          )}
        </div>
      ) : v.students.full ? (
        <div className="text-danger-700">Full: the next admission is refused.</div>
      ) : v.students.warn ? (
        <div className="text-due-800">Nearly full: they are warned from 90%.</div>
      ) : null}
      {d.licence?.counted_at && (
        <div className="text-xs text-slate-400">Counted {fmtDateTime(d.licence.counted_at)}</div>
      )}
    </div>
  )
}

function SectionTitle({ children }: { children: React.ReactNode }) {
  return (
    <div className="text-xs font-semibold uppercase tracking-wide text-slate-500">{children}</div>
  )
}

function ReadyRow({ r }: { r: ReadinessItem }) {
  return (
    <li className="flex items-start gap-2 text-sm">
      <span className={`mt-0.5 shrink-0 ${r.done ? 'text-money-600' : 'text-slate-300'}`}>
        {r.done ? '✓' : '○'}
      </span>
      <span className={r.done ? 'text-slate-600' : 'font-medium text-slate-800'}>
        {r.label}
        {r.detail && <span className="ml-1 font-normal text-slate-400">· {r.detail}</span>}
      </span>
    </li>
  )
}

/**
 * "3 days ago" rather than a bare date.
 *
 * A date makes the operator do arithmetic; the point of this block is to spot
 * the module nobody has touched since April, and "128 days ago" says that where
 * "12 Apr 2026" does not.
 */
function Since({ label, at }: { label: string; at: string | null }) {
  if (!at) {
    return (
      <div className="flex justify-between gap-2">
        <span className="text-slate-500">{label}</span>
        <span className="text-slate-400">never</span>
      </div>
    )
  }
  const days = Math.floor((Date.now() - new Date(at).getTime()) / 86_400_000)
  const stale = days > 30
  return (
    <div className="flex justify-between gap-2">
      <span className="text-slate-500">{label}</span>
      <span className={stale ? 'font-medium text-due-700' : 'text-slate-700'}>
        {days <= 0 ? 'today' : days === 1 ? 'yesterday' : `${days} days ago`}
      </span>
    </div>
  )
}

/** Everything that read the subscription is stale after any of these acts. */
function useRefreshSubscription() {
  const qc = useQueryClient()
  return () => {
    for (const key of ['schoolDetail', 'platformSchools', 'platformLedger', 'platformRevenue',
      'dueSoon', 'limitRequests', 'planChangeQuote']) {
      void qc.invalidateQueries({ queryKey: [key] })
    }
  }
}

/**
 * Extra room: how many pupils this school may have beyond its plan, until when,
 * and who said so.
 *
 * WHAT CHANGED IN 0155. An allowance used to be permanent: granted once, it
 * replaced the plan's limit until somebody remembered to take it back, which in
 * practice was never, and the price list quietly stopped meaning anything. Now
 * extra room ends at the next renewal (the end of what covers the school today)
 * and any plan change ends it at once. So the block says the date in the same
 * sentence as the number, because "room for 320" without "until 30 Nov" is the
 * half of the fact that causes the phone call in December.
 *
 * ONLY ABOVE THE PLAN, AND NEVER ON ENTERPRISE. A grant below the plan's own
 * limit used to be allowed with a reason, as a way of holding a school to a
 * smaller plan; the database now refuses it, because moving a school is Change
 * plan's job. Enterprise has no limit, so there is nothing to add.
 */
function StudentLimitBlock({ d, v }: { d: Detail; v: SubscriptionView }) {
  const refresh = useRefreshSubscription()
  const [mode, setMode] = useState<'none' | 'grant' | 'clear'>('none')
  const [granted, setGranted] = useState<{ limit: number; until: string } | null>(null)
  const lic = d.licence
  const req = lic?.limit_request ?? null
  const planLimit = v.students.plan_limit
  const extra = v.students.extra

  // Enterprise, or any plan with no limit: saying so beats an empty block that
  // reads as a feature that failed to load.
  if (planLimit === null) {
    return (
      <p className="mt-2 border-t border-slate-100 pt-2 text-xs text-slate-500">
        {v.plan.name} has no pupil limit, so there is no extra room to give.
      </p>
    )
  }

  return (
    <div className="mt-2 border-t border-slate-100 pt-2">
      <div className="flex flex-wrap items-baseline justify-between gap-2">
        <div className="text-xs font-semibold uppercase tracking-wide text-slate-500">
          Extra room
        </div>
        <div className="flex gap-2 text-xs">
          <button onClick={() => { setGranted(null); setMode(mode === 'grant' ? 'none' : 'grant') }}
            className="text-brand-700 hover:underline">
            {extra == null ? 'Give extra room' : 'Change the extra room'}
          </button>
          {extra != null && (
            <button onClick={() => { setGranted(null); setMode(mode === 'clear' ? 'none' : 'clear') }}
              className="text-slate-500 hover:text-slate-800 hover:underline">
              End it now
            </button>
          )}
        </div>
      </div>

      {extra != null ? (
        <div className="mt-1 rounded bg-info-50 px-2 py-1.5 text-xs text-info-900">
          <div className="font-medium">
            Room for {extra.toLocaleString()} pupils
            {v.students.extra_until && <> until {fmtDate(v.students.extra_until)}</>}, then{' '}
            {v.plan.name}&rsquo;s limit of {planLimit.toLocaleString()} applies.
          </div>
          <div className="text-info-800">
            Given
            {lic?.limit_override_by && <> by {lic.limit_override_by}</>}
            {lic?.limit_override_at && <> on {fmtDate(lic.limit_override_at)}</>}.
            {' '}Any plan change ends it sooner.
          </div>
          {(v.students.extra_reason ?? lic?.limit_override_reason) && (
            <div className="text-info-800">
              Why: &ldquo;{v.students.extra_reason ?? lic?.limit_override_reason}&rdquo;
            </div>
          )}
        </div>
      ) : v.students.extra_expired && lic?.limit_override != null ? (
        <p className="mt-1 text-xs text-slate-600">
          Their extra room for {lic.limit_override.toLocaleString()} pupils ended
          {lic.limit_override_until && <> on {fmtDate(lic.limit_override_until)}</>}.
          {' '}{v.plan.name}&rsquo;s own limit of {planLimit.toLocaleString()} applies again.
        </p>
      ) : (
        <p className="mt-1 text-xs text-slate-500">
          None. {v.plan.name}&rsquo;s own limit applies: {planLimit.toLocaleString()} pupils.
        </p>
      )}

      {granted && (
        <p className="mt-1.5 rounded bg-money-50 px-2 py-1 text-xs text-money-900" role="status">
          Room for {granted.limit.toLocaleString()} pupils until {fmtDate(granted.until)}, then
          the plan&rsquo;s limit applies.
        </p>
      )}

      {/* The request, if one is waiting. An operator granting from this page
          rather than from the queue would otherwise be granting blind: they
          cannot see that the school has already asked, for how many, or why. */}
      {req && (
        <div className="mt-1.5 rounded bg-due-50 px-2 py-1 text-xs text-due-900">
          <span className="font-medium">
            They have asked{req.wants === 'move_up' ? ' to move up' : ' for room'} for{' '}
            {req.requested_limit.toLocaleString()} pupils
          </span>{' '}
          on {fmtDate(req.requested_at)}. &ldquo;{req.reason}&rdquo;
          {req.wants === 'move_up' && (
            <span className="block">
              They asked to move up, so the answer is Change plan on the Billing
              tab, which suggests what to charge for the rest of their paid time.
              Extra room is for a school staying on its plan.
            </span>
          )}
        </div>
      )}

      {mode !== 'none' && (
        <LimitForm
          schoolId={d.school.id} v={v} mode={mode}
          requested={req && req.wants === 'more_room' ? req.requested_limit : null}
          onDone={(g) => {
            setMode('none')
            setGranted(g)
            refresh()
          }}
        />
      )}
    </div>
  )
}

function LimitForm({ schoolId, v, mode, requested, onDone }: {
  schoolId: string
  v: SubscriptionView
  mode: 'grant' | 'clear'
  requested: number | null
  onDone: (granted: { limit: number; until: string } | null) => void
}) {
  const planLimit = v.students.plan_limit ?? 0
  const [limit, setLimit] = useState(String(
    requested && requested > planLimit ? requested : (v.students.extra ?? planLimit + 50)))
  const [note, setNote] = useState('')
  const [err, setErr] = useState<string | null>(null)

  const want = Number(limit)
  const valid = Number.isInteger(want) && want > planLimit
  // Until the next renewal: the end of what covers them today, their paid time
  // or their trial, and never before today. The database works it out the same
  // way when it saves; this is so the date is read BEFORE pressing.
  const now = today()
  const until = v.covered_to && v.covered_to > now ? v.covered_to : now
  // Ending it while they are above the plan's limit stops the next admission
  // the moment it saves. Said as a number, not as a warning about a possibility.
  const cutsThemOff = mode === 'clear' && v.students.count >= planLimit
  const noteOk = note.trim().length >= 8

  const act = useMutation({
    mutationFn: async () => {
      if (mode === 'clear') {
        await clearStudentLimit(schoolId, note.trim())
        return null
      }
      const r = await grantStudentLimit(schoolId, want, note.trim())
      return { limit: r.limit, until: r.until }
    },
    onSuccess: onDone,
    onError: (e) => setErr((e as Error).message),
  })

  return (
    <div className="mt-2 rounded border border-slate-200 bg-slate-50 p-2">
      {err && <p className="mb-1.5 rounded bg-danger-50 px-2 py-1 text-xs text-danger-700">{err}</p>}

      {mode === 'grant' ? (
        <>
          <label className="block">
            <span className="text-xs font-medium text-slate-600">Pupils they may have</span>
            <input type="number" min={planLimit + 1} step={1} className={FIELD} value={limit}
              onChange={(e) => setLimit(e.target.value)} />
          </label>
          <p className="mt-1 text-xs text-slate-600">
            Until <span className="font-medium">{fmtDate(until)}</span>, the end of what
            covers them today, then {v.plan.name}&rsquo;s limit of {planLimit.toLocaleString()}{' '}
            applies again. It bills them nothing. Moving them to another plan ends it at once.
          </p>
          {!valid && limit.trim() !== '' && (
            <p className="mt-1.5 rounded bg-due-50 px-2 py-1 text-xs text-due-900">
              Extra room is more than the {planLimit.toLocaleString()} pupils {v.plan.name}{' '}
              already covers. To hold a school to fewer, move it to a smaller plan.
            </p>
          )}
        </>
      ) : (
        <p className="text-xs text-slate-700">
          {v.plan.name}&rsquo;s limit of {planLimit.toLocaleString()} pupils comes back today.
        </p>
      )}

      {cutsThemOff && (
        <p className="mt-1.5 rounded bg-danger-50 px-2 py-1 text-xs text-danger-700">
          They have {v.students.count.toLocaleString()} on the roll and their plan covers{' '}
          {planLimit.toLocaleString()}, so this stops their next admission the moment you
          save it.
        </p>
      )}

      <label className="mt-1.5 block">
        <span className="text-xs font-medium text-slate-600">
          Reason<span className="text-danger-600"> *</span>
        </span>
        <textarea rows={2} className={FIELD} value={note}
          onChange={(e) => setNote(e.target.value)} />
        <span className="mt-0.5 block text-xs text-slate-400">
          Kept with the allowance and shown beside it here until it ends, with your name.
        </span>
      </label>

      <button
        disabled={act.isPending || (mode === 'grant' && !valid) || !noteOk}
        onClick={() => { setErr(null); act.mutate() }}
        className={`mt-2 rounded px-3 py-1.5 text-xs font-medium text-white disabled:opacity-50 ${
          mode === 'clear' ? 'bg-slate-700 hover:bg-slate-800'
            : 'bg-brand-600 hover:bg-brand-700'}`}>
        {act.isPending ? 'Saving…'
          : mode === 'clear' ? 'End the extra room'
          : `Allow ${valid ? want.toLocaleString() : '…'} pupils until ${fmtDate(until)}`}
      </button>
      {!noteOk && (
        <span className="ml-2 text-xs text-slate-400">
          A reason is required, and eight characters is the floor.
        </span>
      )}
    </div>
  )
}

/**
 * The discount tag on a school's Money block.
 *
 * Highlighted so the operator scanning a list of open profiles cannot miss
 * that this school is on an offer. Names the code and the label the school
 * sees, spells the terms in the words the school itself sees (one source in
 * the database), and says who put it there: since 0156 a code WE gave can only
 * be changed by us, and the school cannot take it off, so "the school used
 * this" and "we gave this" are different promises.
 */
function DiscountBadge({ d }: { d: NonNullable<Detail['discount']> }) {
  const pct = d.kind === 'percent'
  const flat = d.kind === 'flat'
  const trial = d.kind === 'trial_days'
  return (
    <div className="mt-2 rounded-lg bg-money-50 px-2.5 py-1.5 text-xs text-money-900 ring-1 ring-money-100">
      <div className="flex flex-wrap items-baseline justify-between gap-2">
        <span className="font-semibold tracking-wide">
          Discount: {d.label || d.code}
          {d.label && d.label !== d.code && <span className="font-normal"> ({d.code})</span>}
        </span>
        <span className="tabular-nums">
          {pct && `${d.value}% off`}
          {flat && `${formatPkr(d.value)} off a month`}
          {trial && `${d.value} trial day(s)`}
        </span>
      </div>
      <div className="mt-0.5 text-money-800">{d.summary}</div>
      <div className="mt-0.5 text-money-800">
        {d.granted_by_kind === 'platform'
          ? <>Given by us{d.grant_reason ? <>: &ldquo;{d.grant_reason}&rdquo;</> : ''}. Only we can change or remove it.</>
          : <>The school used this code itself.</>}
      </div>
      <div className="mt-0.5 flex flex-wrap justify-between gap-2 text-money-700">
        <span>
          On {d.times_applied} invoice(s)
          {d.months_left !== null && (
            <> · {d.months_left} billed month(s) left{d.months_total !== null && <> of {d.months_total}</>}</>
          )}
          {d.ends_on && ` · ends ${fmtDate(d.ends_on)}`}
        </span>
        <span className="font-medium">Saved {formatPkr(d.total_saved)}</span>
      </div>
    </div>
  )
}

// ---------------------------------------------------------------------------
// Plan and price. 0155: plans move ONLY by us, Enterprise is priced by us one
// school at a time, and every one of these acts needs a reason that is kept
// with it. They live on the school's page because the conversation that
// produces them is about one school.
// ---------------------------------------------------------------------------

/**
 * The plan, what it costs this school, and the two buttons that change it.
 *
 * Rendered on the workspace's Billing tab, beside the money, because a plan
 * move usually comes with a charge and a price is what every invoice reads.
 * Every figure here is the database's: the plan's price list, or the price we
 * agreed with an Enterprise school, with the three-month and yearly figures
 * marked as agreed or as following from the monthly one.
 */
export function PlanPanel({ schoolId, schoolName }: { schoolId: string; schoolName: string }) {
  const q = useQuery({ queryKey: ['schoolDetail', schoolId], queryFn: () => schoolDetail(schoolId) })
  const [dialog, setDialog] = useState<'plan' | 'price' | null>(null)
  const v = q.data?.subscription ?? null

  return (
    <div className="rounded-lg border border-slate-200 bg-white p-4">
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div className="min-w-0">
          <div className="text-xs font-semibold uppercase tracking-wide text-slate-500">
            Plan and price
          </div>
          {q.isLoading && <p className="mt-1 text-sm text-slate-500">Loading…</p>}
          {q.error && <p className="mt-1 text-sm text-danger-600">{(q.error as Error).message}</p>}
          {q.data && !v && (
            <p className="mt-1 text-sm text-slate-500">
              This database does not describe the subscription yet.
            </p>
          )}
          {v && (
            <div className="mt-1 text-sm text-slate-700">
              <div>
                <span className="text-base font-semibold text-slate-800">{v.plan.name}</span>
                <span className="text-slate-500">
                  {' · '}{v.plan.student_limit !== null
                    ? `up to ${v.plan.student_limit.toLocaleString()} pupils`
                    : 'no pupil limit'}
                  {' · '}pays {termSentence(v.term_months)}
                </span>
              </div>
            </div>
          )}
        </div>
        {v && (
          <div className="flex shrink-0 flex-wrap gap-2">
            {v.plan.by_arrangement && (
              <button onClick={() => setDialog('price')}
                className={`rounded px-3 py-1.5 text-sm font-medium ${v.needs_price
                  ? 'bg-brand-600 text-white hover:bg-brand-700'
                  : 'border border-slate-300 bg-white text-slate-700 hover:bg-slate-50'}`}>
                {v.price.agreed ? 'Change the price' : 'Set price'}
              </button>
            )}
            <button onClick={() => setDialog('plan')}
              className="rounded border border-slate-300 bg-white px-3 py-1.5 text-sm font-medium text-slate-700 hover:bg-slate-50">
              Change plan
            </button>
          </div>
        )}
      </div>

      {v && (v.plan.by_arrangement ? <AgreedPrice v={v} /> : <ListPrice v={v} />)}

      {dialog === 'plan' && (
        <ChangePlanDialog schoolId={schoolId} schoolName={schoolName}
          onClose={() => setDialog(null)} />
      )}
      {dialog === 'price' && v && (
        <SetPriceDialog schoolId={schoolId} schoolName={schoolName} v={v}
          onClose={() => setDialog(null)} />
      )}
    </div>
  )
}

function ListPrice({ v }: { v: SubscriptionView }) {
  return (
    <dl className="mt-2 grid grid-cols-3 gap-2 text-sm">
      <PriceCell label="A month" amount={v.price.month} />
      <PriceCell label="Three months" amount={v.price.quarter} />
      <PriceCell label="A year" amount={v.price.year} />
    </dl>
  )
}

/**
 * What we agreed with an Enterprise school, and how.
 *
 * "How it was agreed" is ours alone: who, when, for how many pupils. It is the
 * first question asked about a price six months later, and the database only
 * returns it to the console (agreed_reason is null on every school screen).
 */
function AgreedPrice({ v }: { v: SubscriptionView }) {
  if (!v.price.priced) return <NeedsPriceBox v={v} />
  return (
    <div className="mt-2">
      <dl className="grid grid-cols-3 gap-2 text-sm">
        <PriceCell label="A month" amount={v.price.month} note="agreed" />
        <PriceCell label="Three months" amount={v.price.quarter}
          note={v.price.quarter_set ? 'agreed' : 'follows: 10% off three months'} />
        <PriceCell label="A year" amount={v.price.year}
          note={v.price.year_set ? 'agreed' : 'follows: two months free'} />
      </dl>
      <p className="mt-2 text-xs text-slate-600">
        Agreed{v.price.agreed_at && <> on {fmtDate(v.price.agreed_at)}</>}.
        {v.price.agreed_reason && (
          <> How: &ldquo;{v.price.agreed_reason}&rdquo; <span className="text-slate-400">(only we see this)</span></>
        )}
      </p>
    </div>
  )
}

function PriceCell({ label, amount, note }: { label: string; amount: number | null; note?: string }) {
  return (
    <div className="rounded border border-slate-200 px-2 py-1.5">
      <dt className="text-xs text-slate-500">{label}</dt>
      <dd className="font-medium tabular-nums text-slate-800">
        {amount == null ? '-' : formatPkr(amount)}
      </dd>
      {note && <dd className="text-[11px] text-slate-400">{note}</dd>}
    </div>
  )
}

/**
 * The dialog frame for this page's three acts.
 *
 * Above the workspace (z-40), and Escape closes THIS rather than the drawer
 * behind it: the drawer listens for Escape on the window, so a half-typed
 * reason was one key away from being thrown away with the whole workspace.
 */
export function Modal({ title, onClose, children }: {
  title: string; onClose: () => void; children: React.ReactNode
}) {
  return (
    <div className="fixed inset-0 z-[60] flex items-start justify-center overflow-y-auto bg-black/40 p-4 sm:items-center"
      onKeyDown={(e) => { if (e.key === 'Escape') { e.stopPropagation(); onClose() } }}>
      <div role="dialog" aria-modal="true" aria-label={title}
        className="w-full max-w-lg rounded-lg bg-white p-5 text-left shadow-lg">
        <div className="flex items-start justify-between gap-3">
          <h2 className="text-base font-semibold text-slate-800">{title}</h2>
          <button onClick={onClose} className="text-sm text-slate-500 hover:underline">Close</button>
        </div>
        <div className="mt-3">{children}</div>
      </div>
    </div>
  )
}

/** A value that stops changing for a moment: a quote per keystroke is noise. */
function useSettled<T>(value: T, ms = 350): T {
  const [settled, setSettled] = useState(value)
  useEffect(() => {
    const t = setTimeout(() => setSettled(value), ms)
    return () => clearTimeout(t)
  }, [value, ms])
  return settled
}

type ChargeMode = 'suggested' | 'other' | 'none'

/**
 * Move a school to another plan, now.
 *
 * PLANS MOVE ONLY BY US (0155). A school asks from Settings, Subscription; we
 * move it here. The database prices the rest of the paid period for us
 * (fn_platform_plan_change_quote): the difference between the two plans' term
 * prices, for the days left. That is a SUGGESTION. We may charge it, change it
 * or charge nothing, and the reason is kept with the move either way.
 *
 * WHAT THE DIALOG SAYS BEFORE ANYTHING IS PRESSED, because each one is a phone
 * call if it is learned afterwards:
 *   - a move the roll does not fit is refused, and the quote knows that, so the
 *     button is not offered rather than failing;
 *   - extra room given on the old plan ends with the move;
 *   - Enterprise needs its monthly price, here or already agreed;
 *   - a charge is only possible while a paid period is running.
 */
export function ChangePlanDialog({ schoolId, schoolName, initialPlan, initialReason, onClose, onDone }: {
  schoolId: string
  schoolName: string
  initialPlan?: string | null
  initialReason?: string
  onClose: () => void
  onDone?: (message: string) => void
}) {
  const refresh = useRefreshSubscription()
  const detail = useQuery({ queryKey: ['schoolDetail', schoolId], queryFn: () => schoolDetail(schoolId) })
  const plans = useQuery({ queryKey: ['signupPlans'], queryFn: listSignupPlans, staleTime: 5 * 60_000 })
  const v = detail.data?.subscription ?? null
  const current = v?.plan.code ?? detail.data?.licence?.plan_code ?? null

  const [plan, setPlan] = useState<string>(initialPlan ?? '')
  const [monthly, setMonthly] = useState('')
  const [mode, setMode] = useState<ChargeMode>('suggested')
  const [other, setOther] = useState('')
  const [reason, setReason] = useState(initialReason ?? '')
  const [err, setErr] = useState<string | null>(null)
  const [done, setDone] = useState<Awaited<ReturnType<typeof changeSchoolPlan>> | null>(null)

  const target = plans.data?.find((p) => p.code === plan) ?? null
  const toEnterprise = target?.by_arrangement === true
  const m = money(monthly)
  const monthlyOk = Number.isInteger(m) && m > 0
  const quoteMonthly = useSettled(toEnterprise && monthlyOk ? m : null)

  const quote = useQuery({
    queryKey: ['planChangeQuote', schoolId, plan, quoteMonthly],
    queryFn: () => planChangeQuote(schoolId, plan, quoteMonthly),
    enabled: plan !== '' && plan !== current,
  })
  const qd = quote.data
  // A charge is only possible while a paid period is running: the database
  // refuses one otherwise, and the new price simply applies from the next
  // invoice.
  const canCharge = (qd?.days_in_period ?? 0) > 0 && !(qd?.in_trial ?? false)
  const suggested = qd?.suggested_charge ?? 0
  const effective: ChargeMode = !canCharge ? 'none'
    : mode === 'suggested' && suggested === 0 ? 'none' : mode
  const otherN = money(other)
  const charge = effective === 'suggested' ? suggested : effective === 'other' ? otherN : 0

  const problem = !plan ? 'Choose the plan to move them to.'
    : plan === current ? `${schoolName} is already on ${target?.name ?? plan}.`
    : toEnterprise && !monthlyOk ? `Type the monthly price agreed for ${target?.name}, in whole rupees.`
    : quote.isLoading || !qd ? 'Working out what the move would cost…'
    : !qd.fits ? `${schoolName} has ${qd.students.toLocaleString()} pupils on the roll and ${qd.to.name} covers ${qd.to.limit?.toLocaleString()}. This move is refused: choose a plan that fits.`
    : effective === 'other' && !wholeRupees(otherN) ? 'The charge is a whole number of rupees, zero or more.'
    : reason.trim().length < 8 ? 'Say why they are moving (their request, a call, a count). Eight characters at least.'
    : null

  const save = useMutation({
    mutationFn: () => changeSchoolPlan({
      schoolId, planCode: plan, reason: reason.trim(),
      charge, agreedMonthly: toEnterprise ? m : null,
    }),
    onSuccess: (r) => {
      setErr(null); setDone(r); refresh()
      onDone?.(`${schoolName} moved to ${target?.name ?? r.to}.`)
    },
    onError: (e) => setErr((e as Error).message),
  })

  if (done) {
    return (
      <Modal title={`${schoolName} is on ${target?.name ?? done.to}`} onClose={onClose}>
        <div className="space-y-2 text-sm text-slate-700">
          <p>
            Moved from {plans.data?.find((p) => p.code === done.from)?.name ?? done.from} today.
            {done.student_limit !== null
              ? <> Their limit is now {done.student_limit.toLocaleString()} pupils.</>
              : <> They have no pupil limit now.</>}
            {' '}Any extra room on the old plan has ended.
          </p>
          <p>
            {done.charge > 0
              ? <>{formatPkr(done.charge)} invoiced{done.doc_no && <> as {done.doc_no}</>}, due today.</>
              : <>Nothing was charged. The new price applies from their next invoice.</>}
          </p>
          <p className="text-slate-500">They are {statusWords(done.status).toLowerCase()}.</p>
        </div>
        <button onClick={onClose}
          className="mt-4 w-full rounded bg-brand-600 px-3 py-2 text-sm font-medium text-white hover:bg-brand-700">
          Done
        </button>
      </Modal>
    )
  }

  const extra = v?.students.extra ?? null
  const open = v?.open_invoice ?? null

  return (
    <Modal title={`Change ${schoolName}'s plan`} onClose={onClose}>
      {(detail.error || plans.error) && (
        <p className="mb-2 rounded bg-danger-50 px-3 py-2 text-sm text-danger-700">
          {((detail.error ?? plans.error) as Error).message}
        </p>
      )}
      <p className="text-xs text-slate-500">
        On {v?.plan.name ?? current ?? 'an unknown plan'} now
        {v && <>, {v.students.count.toLocaleString()} pupils on the roll</>}. The move happens
        the moment you save it.
      </p>

      <fieldset className="mt-3">
        <legend className="text-xs font-medium text-slate-600">Move them to</legend>
        <div className="mt-1 grid gap-2 sm:grid-cols-3">
          {(plans.data ?? []).map((p) => {
            const isCurrent = p.code === current
            const on = plan === p.code
            return (
              <label key={p.code}
                className={`block cursor-pointer rounded border px-2.5 py-2 text-sm focus-within:ring-2 focus-within:ring-brand-500 ${
                  on ? 'border-brand-500 bg-brand-50' : 'border-slate-200 bg-white hover:bg-slate-50'}
                  ${isCurrent ? 'cursor-not-allowed opacity-60' : ''}`}>
                <input type="radio" name="plan" value={p.code} checked={on} disabled={isCurrent}
                  onChange={() => { setPlan(p.code); setErr(null) }} className="sr-only" />
                <span className="block font-medium text-slate-800">{p.name}</span>
                <span className="block text-xs text-slate-500">
                  {p.student_limit !== null ? `up to ${p.student_limit.toLocaleString()} pupils` : 'no pupil limit'}
                </span>
                <span className="block text-xs text-slate-500">
                  {p.by_arrangement ? 'priced with each school'
                    : p.month_price != null ? `${formatPkr(p.month_price)} a month` : ''}
                </span>
                {isCurrent && <span className="block text-xs text-slate-400">their plan now</span>}
              </label>
            )
          })}
        </div>
      </fieldset>

      {toEnterprise && (
        <label className="mt-3 block">
          <span className="text-xs font-medium text-slate-600">
            Monthly price agreed with them<span className="text-danger-600"> *</span>
          </span>
          <input value={monthly} onChange={(e) => setMonthly(e.target.value)} inputMode="numeric"
            placeholder="whole rupees" className={FIELD} />
          <span className="mt-0.5 block text-xs text-slate-400">
            Three months and a year follow from it (10% off, two months free) unless you
            set them afterwards with Set price.
          </span>
        </label>
      )}

      {plan && plan !== current && (
        <div className="mt-3 rounded border border-slate-200 bg-slate-50 p-3 text-sm">
          {quote.error && <p className="text-danger-700">{(quote.error as Error).message}</p>}
          {quote.isLoading && <p className="text-slate-500">Working out what the move would cost…</p>}
          {qd && !qd.fits && (
            <p className="rounded bg-danger-50 px-2 py-1.5 text-danger-800">
              {schoolName} has {qd.students.toLocaleString()} pupils on the roll and{' '}
              {qd.to.name} covers {qd.to.limit?.toLocaleString()}. This move is refused:
              choose a plan that fits.
            </p>
          )}
          {qd && qd.fits && (
            <>
              <div className="text-slate-700">
                {qd.days_in_period > 0 && !qd.in_trial ? (
                  <>
                    Paid from {fmtDate(qd.paid_from)} to {fmtDate(qd.paid_to)}:{' '}
                    <span className="font-medium">{qd.days_left} of {qd.days_in_period} days left</span>.
                  </>
                ) : (
                  <>No paid period is running.</>
                )}
                {qd.from.term_price != null && qd.to.term_price != null && (
                  <span className="block text-xs text-slate-500">
                    A {qd.term_months}-month term costs {formatPkr(qd.from.term_price)} on{' '}
                    {qd.from.name} and {formatPkr(qd.to.term_price)} on {qd.to.name}.
                  </span>
                )}
              </div>
              <div className="mt-2">
                <span className="text-slate-500">Suggested charge </span>
                <span className="font-semibold text-slate-800">{formatPkr(suggested)}</span>
                <span className="block text-xs text-slate-500">{qd.explain}</span>
              </div>
            </>
          )}
        </div>
      )}

      {qd && qd.fits && canCharge && (
        <fieldset className="mt-3">
          <legend className="text-xs font-medium text-slate-600">What to charge now</legend>
          <div className="mt-1 space-y-1 text-sm">
            {suggested > 0 && (
              <label className="flex items-center gap-2">
                <input type="radio" name="charge" checked={effective === 'suggested'}
                  onChange={() => setMode('suggested')} />
                The suggested {formatPkr(suggested)}, invoiced today
              </label>
            )}
            <label className="flex flex-wrap items-center gap-2">
              <input type="radio" name="charge" checked={effective === 'other'}
                onChange={() => setMode('other')} />
              A different amount
              {effective === 'other' && (
                <input aria-label="Charge in rupees" value={other} inputMode="numeric"
                  onChange={(e) => setOther(e.target.value)} placeholder="whole rupees"
                  className="w-32 rounded border border-slate-300 px-2 py-1 text-sm" />
              )}
            </label>
            <label className="flex items-center gap-2">
              <input type="radio" name="charge" checked={effective === 'none'}
                onChange={() => setMode('none')} />
              Nothing now: the new price applies from their next invoice
            </label>
          </div>
        </fieldset>
      )}

      <label className="mt-3 block">
        <span className="text-xs font-medium text-slate-600">
          Why they are moving<span className="text-danger-600"> *</span>
        </span>
        <textarea rows={2} className={FIELD} value={reason} onChange={(e) => setReason(e.target.value)}
          placeholder="e.g. principal called: 320 pupils after the new wing opened" />
        <span className="mt-0.5 block text-xs text-slate-400">
          Kept with the move, with your name. A charge prints it on the invoice.
        </span>
      </label>

      <ul className="mt-3 list-disc space-y-0.5 pl-5 text-xs text-slate-600">
        <li>
          {extra != null
            ? <>Their extra room for {extra.toLocaleString()} pupils
                {v?.students.extra_until && <> (until {fmtDate(v.students.extra_until)})</>} ends
                with the move. The new plan&rsquo;s limit applies at once.</>
            : <>Any extra room on the old plan ends with the move.</>}
        </li>
        {open && (
          <li>
            {open.paid > 0
              ? <>Their open invoice {open.doc_no} has money on it, so it stays as it is.</>
              : <>Their open invoice {open.doc_no} has nothing paid on it, so it is voided and
                  raised again on the new plan.</>}
          </li>
        )}
      </ul>

      {err && <p className="mt-3 text-sm text-danger-700">{err}</p>}
      {problem && !save.isPending && (
        <p className="mt-3 rounded border border-due-200 bg-due-50 px-3 py-2 text-xs text-due-900">
          {problem}
        </p>
      )}

      <div className="mt-4 flex gap-2">
        <button onClick={() => { setErr(null); save.mutate() }}
          disabled={save.isPending || problem !== null}
          className="flex-1 rounded bg-brand-600 px-3 py-2 text-sm font-medium text-white hover:bg-brand-700 disabled:opacity-60">
          {save.isPending ? 'Moving…'
            : `Move to ${target?.name ?? 'the plan'}${charge > 0 ? ` and charge ${formatPkr(charge)}` : ''}`}
        </button>
        <button onClick={onClose}
          className="flex-1 rounded border border-slate-300 px-3 py-2 text-sm hover:bg-slate-50">
          Cancel
        </button>
      </div>
    </Modal>
  )
}

/**
 * The price we agreed with one Enterprise school.
 *
 * Monthly is the figure agreed on the phone. Three months and a year follow
 * from it (three months less 10%, a year as ten months) unless we agreed those
 * too, and the database caps them at three and twelve times the monthly price,
 * because a longer term must never cost more than paying month by month. The
 * figures that follow are worked out by the database and shown after saving;
 * this dialog never invents a price.
 *
 * Starter and Growth have no button for this at all: their price is the price
 * list, and the only way to lower it for one school is a discount code.
 */
export function SetPriceDialog({ schoolId, schoolName, v, onClose }: {
  schoolId: string; schoolName: string; v: SubscriptionView; onClose: () => void
}) {
  const refresh = useRefreshSubscription()
  const [monthly, setMonthly] = useState(v.price.agreed && v.price.month != null ? String(v.price.month) : '')
  const [quarterly, setQuarterly] = useState(v.price.quarter_set && v.price.quarter != null ? String(v.price.quarter) : '')
  const [yearly, setYearly] = useState(v.price.year_set && v.price.year != null ? String(v.price.year) : '')
  const [reason, setReason] = useState('')
  const [err, setErr] = useState<string | null>(null)
  const [done, setDone] = useState<Awaited<ReturnType<typeof setSchoolPrice>> | null>(null)

  const m = money(monthly)
  const q = quarterly.trim() === '' ? null : money(quarterly)
  const y = yearly.trim() === '' ? null : money(yearly)
  const problem = !(Number.isInteger(m) && m > 0) ? 'The monthly price is a whole number of rupees above zero.'
    : q !== null && !(Number.isInteger(q) && q > 0) ? 'Three months is a whole number of rupees above zero, or left empty.'
    : q !== null && q > 3 * m ? `Three months can be no more than three times the monthly price (${formatPkr(3 * m)}).`
    : y !== null && !(Number.isInteger(y) && y > 0) ? 'A year is a whole number of rupees above zero, or left empty.'
    : y !== null && y > 12 * m ? `A year can be no more than twelve times the monthly price (${formatPkr(12 * m)}).`
    : reason.trim().length < 8 ? 'Say how this price was agreed: who, when, for how many pupils. Eight characters at least.'
    : null

  const save = useMutation({
    mutationFn: () => setSchoolPrice({ schoolId, monthly: m, quarterly: q, yearly: y, reason: reason.trim() }),
    onSuccess: (r) => { setErr(null); setDone(r); refresh() },
    onError: (e) => setErr((e as Error).message),
  })

  if (done) {
    const inv = done.invoice
    return (
      <Modal title={`${schoolName}'s price is set`} onClose={onClose}>
        <dl className="grid grid-cols-3 gap-2 text-sm">
          <PriceCell label="A month" amount={done.monthly} note="agreed" />
          <PriceCell label="Three months" amount={done.quarterly}
            note={done.quarterly_is_derived ? 'follows from the monthly' : 'agreed'} />
          <PriceCell label="A year" amount={done.yearly}
            note={done.yearly_is_derived ? 'follows from the monthly' : 'agreed'} />
        </dl>
        {inv && (
          <p className="mt-3 text-sm text-slate-700">
            {inv.voided && <>Their open invoice {inv.voided} was voided </>}
            {inv.raised && <>and {inv.raised.doc_no ?? 'a new one'} raised at {formatPkr(inv.raised.amount)}.</>}
            {inv.kept && <>Their open invoice {inv.kept} stays as it is: {inv.why}.</>}
          </p>
        )}
        <p className="mt-2 text-sm text-slate-500">They are {statusWords(done.status).toLowerCase()}.</p>
        <button onClick={onClose}
          className="mt-4 w-full rounded bg-brand-600 px-3 py-2 text-sm font-medium text-white hover:bg-brand-700">
          Done
        </button>
      </Modal>
    )
  }

  return (
    <Modal title={`${v.price.agreed ? 'Change' : 'Set'} ${schoolName}'s price`} onClose={onClose}>
      <p className="text-xs text-slate-500">
        {v.plan.name} is priced with each school. {v.students.count.toLocaleString()} pupils on the roll
        {v.students.declared != null && <>, {v.students.declared.toLocaleString()} declared at signup</>}.
      </p>

      <div className="mt-3 grid gap-3 sm:grid-cols-3">
        <label className="block">
          <span className="text-xs font-medium text-slate-600">
            A month<span className="text-danger-600"> *</span>
          </span>
          <input value={monthly} onChange={(e) => setMonthly(e.target.value)} inputMode="numeric"
            placeholder="whole rupees" className={FIELD} />
        </label>
        <label className="block">
          <span className="text-xs font-medium text-slate-600">Three months</span>
          <input value={quarterly} onChange={(e) => setQuarterly(e.target.value)} inputMode="numeric"
            placeholder="follows" className={FIELD} />
        </label>
        <label className="block">
          <span className="text-xs font-medium text-slate-600">A year</span>
          <input value={yearly} onChange={(e) => setYearly(e.target.value)} inputMode="numeric"
            placeholder="follows" className={FIELD} />
        </label>
      </div>
      <p className="mt-1.5 text-xs text-slate-500">
        Leave three months and a year empty and they follow from the monthly price: three
        months at 10% off, a year as ten months. Type them only if you agreed them too. Three
        months can be no more than three times the monthly price, and a year no more than
        twelve times it, so a longer term never costs more than paying month by month.
      </p>

      <label className="mt-3 block">
        <span className="text-xs font-medium text-slate-600">
          How it was agreed<span className="text-danger-600"> *</span>
        </span>
        <textarea rows={2} className={FIELD} value={reason} onChange={(e) => setReason(e.target.value)}
          placeholder="e.g. agreed with the principal on 3 Oct for 1,400 pupils" />
        <span className="mt-0.5 block text-xs text-slate-400">
          Kept with the price, with your name. Only we see it; the school sees the price.
        </span>
      </label>

      <ul className="mt-3 list-disc space-y-0.5 pl-5 text-xs text-slate-600">
        {v.open_invoice && (
          <li>
            {v.open_invoice.paid > 0
              ? <>Their open invoice {v.open_invoice.doc_no} has money on it, so it stays; the new
                  price applies from the next one.</>
              : <>Their open invoice {v.open_invoice.doc_no} has nothing paid on it, so it is raised
                  again at this price.</>}
          </li>
        )}
        {v.needs_price && (
          <li>
            {v.locked_because === 'needs_price'
              ? <>They are locked waiting for this. Setting it gives them the usual {v.grace_days} days to pay.</>
              : <>Once it is set they can be invoiced, and the usual {v.grace_days} days of grace apply.</>}
          </li>
        )}
      </ul>

      {err && <p className="mt-3 text-sm text-danger-700">{err}</p>}
      {problem && (
        <p className="mt-3 rounded border border-due-200 bg-due-50 px-3 py-2 text-xs text-due-900">
          {problem}
        </p>
      )}

      <div className="mt-4 flex gap-2">
        <button onClick={() => { setErr(null); save.mutate() }}
          disabled={save.isPending || problem !== null}
          className="flex-1 rounded bg-brand-600 px-3 py-2 text-sm font-medium text-white hover:bg-brand-700 disabled:opacity-60">
          {save.isPending ? 'Saving…' : 'Save the price'}
        </button>
        <button onClick={onClose}
          className="flex-1 rounded border border-slate-300 px-3 py-2 text-sm hover:bg-slate-50">
          Cancel
        </button>
      </div>
    </Modal>
  )
}

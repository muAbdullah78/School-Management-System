import { useState } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import {
  clearStudentLimit, grantStudentLimit, schoolDetail,
  type ReadinessItem, type SchoolDetail as Detail,
} from '@/lib/platform'
import { formatPkr } from '@/lib/licence'
import { fmtDate, fmtDateTime } from '@/lib/format'

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
 *   3. Who ARE they?       contact, licence, money.
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

      {/* 3. LICENCE AND MONEY */}
      <section className="mt-4 grid gap-3 sm:grid-cols-2">
        <div className="rounded border border-slate-200 p-3">
          <SectionTitle>Licence</SectionTitle>
          {d.licence ? (
            <div className="mt-1.5 space-y-0.5 text-sm text-slate-700">
              <div>
                <span className="font-medium">{d.licence.plan_code}</span>
                {' · '}{d.licence.status}
                {d.licence.days_left !== null && (
                  <span className="text-slate-500">
                    {' · '}{d.licence.days_left >= 0
                      ? `${d.licence.days_left}d left`
                      : `expired ${Math.abs(d.licence.days_left)}d ago`}
                  </span>
                )}
              </div>
              <div>
                {d.licence.student_count.toLocaleString()} students
                {d.licence.student_limit !== null && (
                  <span className="text-slate-400"> / {d.licence.student_limit.toLocaleString()}</span>
                )}
                {/* The plan's own number, only when it differs, so the chip
                    above reads as an allowance rather than as a licence that
                    disagrees with the price list. */}
                {d.licence.limit_override != null
                  && d.licence.plan_student_limit != null && (
                  <span className="ml-1 text-xs text-slate-500">
                    ({d.licence.plan_student_limit.toLocaleString()} on{' '}
                    {d.licence.plan_code}, plus{' '}
                    {(d.licence.limit_override - d.licence.plan_student_limit).toLocaleString()}{' '}
                    granted)
                  </span>
                )}
                {d.licence.limit_state === 'over' && (
                  <span className="ml-2 rounded bg-due-100 px-1.5 py-0.5 text-xs font-medium text-due-800">
                    over limit
                    {d.licence.over_limit_since && ` since ${fmtDate(d.licence.over_limit_since)}`}
                  </span>
                )}
              </div>
              {/* THIS USED TO SAY "Move them to growth at renewal", which was
                  fine while the limit was advisory and became wrong the day
                  0128 made it real: nothing waits for a renewal any more, the
                  school is refusing admissions today. The Student limit block
                  below is what an operator does about it. */}
              {d.licence.limit_state === 'over'
                && d.licence.suggested_plan
                && d.licence.suggested_plan !== d.licence.plan_code && (
                <div className="text-due-800">
                  New admissions are refused right now.{' '}
                  <span className="font-medium">{d.licence.suggested_plan}</span>{' '}
                  is the plan that fits their roll.
                </div>
              )}
              <div className="text-xs text-slate-400">
                Counted {d.licence.counted_at ? fmtDateTime(d.licence.counted_at) : 'never'}
              </div>
            </div>
          ) : (
            <p className="mt-1.5 text-sm text-danger-700">
              No subscription row at all. This school cannot use the software.
            </p>
          )}
          {d.licence && <StudentLimitBlock schoolId={d.school.id} lic={d.licence} />}
        </div>

        <div className="rounded border border-slate-200 p-3">
          <SectionTitle>Money</SectionTitle>
          <div className="mt-1.5 space-y-0.5 text-sm text-slate-700">
            <div>Invoiced {formatPkr(d.money.invoiced)} over {d.money.invoice_count} invoice(s)</div>
            <div>Paid {formatPkr(d.money.paid)}</div>
            <div className={d.money.outstanding > 0 ? 'font-medium text-due-800' : ''}>
              Outstanding {formatPkr(d.money.outstanding)}
            </div>
            <div className="text-xs text-slate-400">
              Last payment {d.money.last_paid_on ? fmtDate(d.money.last_paid_on) : 'never'}
            </div>
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

/**
 * How many pupils this school may have, and the two buttons that change it.
 *
 * SEPARATE FROM THE REQUEST QUEUE ON PURPOSE. The queue answers a school that
 * asked; this answers the school that phoned, or the one we are about to
 * refuse without either of us noticing. Most allowances get granted from here,
 * because the conversation that produces one happens on the phone and the
 * operator is looking at the school, not at a list.
 *
 * TAKING ONE BACK IS THE DANGEROUS BUTTON, not granting. Clearing an allowance
 * from a school sitting above its plan's limit stops the next admission the
 * moment it is saved, so the count is spelled out beside it and the reason is
 * mandatory: somebody will ask, and the answer needs to exist.
 */
function StudentLimitBlock({ schoolId, lic }: {
  schoolId: string; lic: NonNullable<Detail['licence']>
}) {
  const qc = useQueryClient()
  const [mode, setMode] = useState<'none' | 'grant' | 'clear'>('none')
  const req = lic.limit_request ?? null
  const plan = lic.plan_student_limit ?? lic.student_limit

  // A by-arrangement plan has no limit and nothing to grant against. Saying so
  // beats an empty block that reads as a feature that failed to load.
  if (plan === null && lic.limit_override == null) {
    return (
      <p className="mt-2 border-t border-slate-100 pt-2 text-xs text-slate-500">
        Their plan has no student limit, so there is nothing to grant.
      </p>
    )
  }

  return (
    <div className="mt-2 border-t border-slate-100 pt-2">
      <div className="flex flex-wrap items-baseline justify-between gap-2">
        <div className="text-xs font-semibold uppercase tracking-wide text-slate-500">
          Student limit
        </div>
        <div className="flex gap-2 text-xs">
          <button onClick={() => setMode(mode === 'grant' ? 'none' : 'grant')}
            className="text-brand-700 hover:underline">
            {lic.limit_override == null ? 'Give them room' : 'Change the allowance'}
          </button>
          {lic.limit_override != null && (
            <button onClick={() => setMode(mode === 'clear' ? 'none' : 'clear')}
              className="text-slate-400 hover:text-slate-700 hover:underline">
              Take it back
            </button>
          )}
        </div>
      </div>

      {lic.limit_override != null ? (
        <p className="mt-1 text-xs text-slate-600">
          Allowed {lic.limit_override.toLocaleString()} by an allowance
          {lic.limit_override_by && <> that {lic.limit_override_by} granted</>}
          {lic.limit_override_at && <> on {fmtDate(lic.limit_override_at)}</>}.
          {lic.limit_override_reason && (
            <span className="block text-slate-500">“{lic.limit_override_reason}”</span>
          )}
        </p>
      ) : (
        <p className="mt-1 text-xs text-slate-500">
          Their {lic.plan_code} plan&rsquo;s own limit applies: {plan?.toLocaleString()} pupils.
        </p>
      )}

      {/* The request, if one is waiting. An operator granting from this page
          rather than from the queue would otherwise be granting blind: they
          cannot see that the school has already asked, for how many, or why. */}
      {req && (
        <div className="mt-1.5 rounded bg-amber-50 px-2 py-1 text-xs text-amber-900">
          <span className="font-medium">
            They have asked{req.wants === 'move_up' ? ' to move up' : ' for room'} for{' '}
            {req.requested_limit.toLocaleString()} pupils
          </span>{' '}
          on {fmtDate(req.requested_at)}. “{req.reason}”
          {req.wants === 'move_up' && (
            <span className="block">
              They asked to move up, so the answer is the Activate dialog on the
              Billing tab, not an allowance. Grant one here only if they need the
              room before the invoice is settled.
            </span>
          )}
        </div>
      )}

      {mode !== 'none' && (
        <LimitForm
          schoolId={schoolId} lic={lic} mode={mode}
          onDone={() => {
            setMode('none')
            void qc.invalidateQueries({ queryKey: ['schoolDetail'] })
            void qc.invalidateQueries({ queryKey: ['platformSchools'] })
            void qc.invalidateQueries({ queryKey: ['limitRequests'] })
          }}
        />
      )}
    </div>
  )
}

function LimitForm({ schoolId, lic, mode, onDone }: {
  schoolId: string
  lic: NonNullable<Detail['licence']>
  mode: 'grant' | 'clear'
  onDone: () => void
}) {
  const plan = lic.plan_student_limit ?? lic.student_limit
  const [limit, setLimit] = useState(
    String(lic.limit_request?.requested_limit ?? lic.limit_override ?? ((plan ?? 0) + 50)),
  )
  const [note, setNote] = useState('')
  const [err, setErr] = useState<string | null>(null)

  const want = Number(limit)
  const valid = Number.isInteger(want) && want >= 1
  // Below the plan's own number is a REDUCTION, which the database refuses
  // without a reason, and is also what a mistyped 15 for 150 looks like.
  const reduction = mode === 'grant' && valid && plan !== null && want < plan
  // Clearing while they are above the plan's limit stops the next admission the
  // moment it saves. Said as a number, not as a warning about a possibility.
  const cutsThemOff = mode === 'clear' && plan !== null
    && lic.student_count >= plan
  const noteNeeded = mode === 'clear' || reduction
  const noteOk = note.trim().length >= 8

  const act = useMutation({
    mutationFn: () => mode === 'clear'
      ? clearStudentLimit(schoolId, note.trim())
      : grantStudentLimit(schoolId, want, note.trim() || null),
    onSuccess: onDone,
    onError: (e) => setErr((e as Error).message),
  })

  return (
    <div className="mt-2 rounded border border-slate-200 bg-slate-50 p-2">
      {err && <p className="mb-1.5 rounded bg-danger-50 px-2 py-1 text-xs text-danger-700">{err}</p>}

      {mode === 'grant' ? (
        <label className="block">
          <span className="text-xs font-medium text-slate-600">Pupils they may have</span>
          <input type="number" min={1} step={1} className={FIELD} value={limit}
            onChange={(e) => setLimit(e.target.value)} />
          <span className="mt-0.5 block text-xs text-slate-400">
            Replaces their plan&rsquo;s limit on whatever plan they are on, and does
            not expire. It bills them nothing on its own.
          </span>
        </label>
      ) : (
        <p className="text-xs text-slate-700">
          Their {lic.plan_code} plan&rsquo;s limit of {plan?.toLocaleString()} pupils
          comes back.
        </p>
      )}

      {reduction && (
        <p className="mt-1.5 rounded bg-danger-50 px-2 py-1 text-xs text-danger-700">
          Their plan already covers {plan?.toLocaleString()}, so {want} is a
          reduction and will stop them admitting anybody the moment you save it.
          Check the number.
        </p>
      )}
      {cutsThemOff && (
        <p className="mt-1.5 rounded bg-danger-50 px-2 py-1 text-xs text-danger-700">
          They have {lic.student_count.toLocaleString()} on the roll and their plan
          covers {plan?.toLocaleString()}, so this stops their next admission the
          moment you save it. They will see your reason on their own screen.
        </p>
      )}

      <label className="mt-1.5 block">
        <span className="text-xs font-medium text-slate-600">
          Reason{noteNeeded && <span className="text-danger-600"> *</span>}
        </span>
        <textarea rows={2} className={FIELD} value={note}
          onChange={(e) => setNote(e.target.value)} />
        <span className="mt-0.5 block text-xs text-slate-400">
          Shown to the school, and kept on their audit trail with your name on it.
        </span>
      </label>

      <button
        disabled={act.isPending || (mode === 'grant' && !valid) || (noteNeeded && !noteOk)}
        onClick={() => { setErr(null); act.mutate() }}
        className={`mt-2 rounded px-3 py-1.5 text-xs font-medium text-white disabled:opacity-50 ${
          mode === 'clear' ? 'bg-slate-700 hover:bg-slate-800'
            : 'bg-emerald-600 hover:bg-emerald-700'}`}>
        {act.isPending ? 'Saving…'
          : mode === 'clear' ? 'Take the allowance back'
          : `Allow ${valid ? want : '…'} pupils`}
      </button>
      {noteNeeded && !noteOk && (
        <span className="ml-2 text-xs text-slate-400">
          A reason is required, and eight characters is the floor.
        </span>
      )}
    </div>
  )
}

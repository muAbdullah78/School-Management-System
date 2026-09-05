import { useQuery } from '@tanstack/react-query'
import { schoolDetail, type ReadinessItem, type SchoolDetail as Detail } from '@/lib/platform'
import { formatPkr } from '@/lib/licence'
import { fmtDate, fmtDateTime } from '@/lib/format'

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
export function SchoolDetailPanel({ schoolId, onClose, onVisit }: {
  schoolId: string
  onClose: () => void
  onVisit: () => void
}) {
  const q = useQuery({
    queryKey: ['schoolDetail', schoolId],
    queryFn: () => schoolDetail(schoolId),
  })

  return (
    <div className="fixed inset-0 z-50 flex items-start justify-center overflow-y-auto bg-black/40 p-4">
      <div className="w-full max-w-3xl rounded-lg bg-white p-5 shadow-lg">
        {q.isLoading && <p className="text-sm text-slate-500">Loading…</p>}
        {q.error && <p className="text-sm text-red-600">{(q.error as Error).message}</p>}
        {q.data && <Body d={q.data} onClose={onClose} onVisit={onVisit} />}
        {!q.data && (
          <button onClick={onClose} className="mt-3 text-sm text-slate-500 hover:underline">
            Close
          </button>
        )}
      </div>
    </div>
  )
}

function Body({ d, onClose, onVisit }: { d: Detail; onClose: () => void; onVisit: () => void }) {
  // The first unfinished step. This is the single most useful thing on the page:
  // it turns "they seem quiet" into a sentence you can say on the phone.
  const stuckAt = d.readiness.find((r) => !r.done)
  const done = d.readiness.filter((r) => r.done).length

  return (
    <>
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div className="min-w-0">
          <h2 className="text-base font-semibold text-slate-800">{d.school.name}</h2>
          <p className="text-sm text-slate-500">
            {[d.school.city, d.school.contact_name, d.school.contact_phone]
              .filter(Boolean).join(' · ') || 'No contact details'}
          </p>
          <p className="text-xs text-slate-400">
            Signed up {fmtDate(d.school.created_at)}
            {/* A school that renamed itself in its own settings is worth
                noticing: it means somebody is in there using it. */}
            {d.school.display_name && d.school.display_name !== d.school.name && (
              <> · calls itself &ldquo;{d.school.display_name}&rdquo; in the app</>
            )}
          </p>
        </div>
        <div className="flex shrink-0 items-center gap-2">
          <button onClick={onVisit}
            className="rounded bg-red-600 px-3 py-1.5 text-sm font-medium text-white hover:bg-red-700">
            View as school
          </button>
          <button onClick={onClose} className="text-sm text-slate-500 hover:underline">Close</button>
        </div>
      </div>

      {/* 1. ARE THEY LIVE? */}
      <section className="mt-4">
        <SectionTitle>
          Getting started: {done} of {d.readiness.length} done
        </SectionTitle>
        {stuckAt ? (
          <div className="mt-2 rounded border border-amber-300 bg-amber-50 px-3 py-2 text-sm text-amber-900">
            <span className="font-medium">Stuck at: {stuckAt.label}.</span>{' '}
            {stuckAt.detail || 'Worth a phone call.'}
          </div>
        ) : (
          <div className="mt-2 rounded border border-emerald-200 bg-emerald-50 px-3 py-2 text-sm text-emerald-900">
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
                {d.licence.limit_state === 'over' && (
                  <span className="ml-2 rounded bg-amber-100 px-1.5 py-0.5 text-xs font-medium text-amber-800">
                    over limit
                    {d.licence.over_limit_since && ` since ${fmtDate(d.licence.over_limit_since)}`}
                  </span>
                )}
              </div>
              {d.licence.limit_state === 'over'
                && d.licence.suggested_plan
                && d.licence.suggested_plan !== d.licence.plan_code && (
                <div className="text-amber-800">
                  Move them to <span className="font-medium">{d.licence.suggested_plan}</span> at renewal.
                </div>
              )}
              <div className="text-xs text-slate-400">
                Counted {d.licence.counted_at ? fmtDateTime(d.licence.counted_at) : 'never'}
              </div>
            </div>
          ) : (
            <p className="mt-1.5 text-sm text-red-700">
              No subscription row at all. This school cannot use the software.
            </p>
          )}
        </div>

        <div className="rounded border border-slate-200 p-3">
          <SectionTitle>Money</SectionTitle>
          <div className="mt-1.5 space-y-0.5 text-sm text-slate-700">
            <div>Invoiced {formatPkr(d.money.invoiced)} over {d.money.invoice_count} invoice(s)</div>
            <div>Paid {formatPkr(d.money.paid)}</div>
            <div className={d.money.outstanding > 0 ? 'font-medium text-amber-800' : ''}>
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
          <p className="mt-1.5 text-sm text-red-700">
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
                      ? <span className="font-medium text-amber-700">never signed in</span>
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
      <span className={`mt-0.5 shrink-0 ${r.done ? 'text-emerald-600' : 'text-slate-300'}`}>
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
      <span className={stale ? 'font-medium text-amber-700' : 'text-slate-700'}>
        {days <= 0 ? 'today' : days === 1 ? 'yesterday' : `${days} days ago`}
      </span>
    </div>
  )
}

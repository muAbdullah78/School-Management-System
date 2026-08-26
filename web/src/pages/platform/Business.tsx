import { useState } from 'react'
import { useQuery } from '@tanstack/react-query'
import { platformGrowth, platformMetrics, type GrowthPoint } from '@/lib/platform'
import { formatPkr } from '@/lib/licence'

/**
 * What the business is worth.
 *
 * TWO RULES THIS SCREEN FOLLOWS, and both come from the same place: a number on
 * a dashboard with no definition becomes whatever the person reading it assumes.
 *
 *   1. EVERY FIGURE SAYS WHAT IT MEASURES. The definitions come from the
 *      database, not from this file, so the screen and the function cannot drift.
 *
 *   2. "WE DO NOT KNOW" IS RENDERED AS ITSELF. Churn on a database with no dated
 *      history is unknown, and a confident 0% is the most misleading thing this
 *      screen could show. fn_platform_metrics returns `measurable: false` with a
 *      reason and this renders the reason.
 *
 * The growth chart is inline SVG rather than a charting library: three numbers a
 * month for a year is 36 numbers, and a 90KB dependency to draw them would be
 * the largest thing in the bundle.
 */
export function Business() {
  const [months, setMonths] = useState(12)
  const m = useQuery({ queryKey: ['platformMetrics'], queryFn: () => platformMetrics() })
  const g = useQuery({
    queryKey: ['platformGrowth', months],
    queryFn: () => platformGrowth(months),
  })

  if (m.isLoading) return <p className="text-sm text-slate-500">Loading…</p>
  if (m.error) return <p className="text-sm text-red-600">{(m.error as Error).message}</p>
  const d = m.data!

  const givenAway = d.by_plan.reduce((s, p) => s + Math.max(0, p.list_mrr - p.mrr), 0)

  return (
    <div className="space-y-4">
      {/* --- the money ------------------------------------------------------ */}
      <section className="rounded-lg border border-slate-200 bg-white p-4">
        <div className="text-xs font-semibold uppercase tracking-wide text-slate-500">
          Recurring revenue
        </div>
        <div className="mt-3 grid grid-cols-2 gap-3 sm:grid-cols-4">
          <Big label="MRR" value={formatPkr(d.recurring.mrr)} />
          <Big label="ARR" value={formatPkr(d.recurring.arr)} />
          <Big label="Paying schools"
            value={String(d.recurring.paying_schools + d.recurring.in_grace)}
            hint={d.recurring.in_grace > 0
              ? `${d.recurring.in_grace} of them in grace` : undefined} />
          <Big label="Per school" value={formatPkr(d.recurring.arps)} />
        </div>
        {/* The definition, from the database. */}
        <p className="mt-3 text-xs text-slate-500">{d.recurring.basis}</p>
        {d.unbilled.schools > 0 && (
          <p className="mt-2 rounded border border-amber-200 bg-amber-50 px-3 py-2 text-sm text-amber-900">
            {d.unbilled.note}
          </p>
        )}
      </section>

      {/* --- where the schools are ----------------------------------------- */}
      <section className="rounded-lg border border-slate-200 bg-white p-4">
        <div className="text-xs font-semibold uppercase tracking-wide text-slate-500">
          The book
        </div>
        <div className="mt-3 grid grid-cols-2 gap-2 text-sm sm:grid-cols-3 lg:grid-cols-6">
          <Small label="Paying" value={d.counts.paying} tone="good" />
          <Small label="In grace" value={d.counts.in_grace}
            tone={d.counts.in_grace > 0 ? 'warn' : undefined} />
          <Small label="On trial" value={d.counts.on_trial} />
          <Small label="Stopped" value={d.counts.locked}
            tone={d.counts.locked > 0 ? 'warn' : undefined} />
          <Small label="Cancelled" value={d.counts.cancelled} />
          <Small label="Archived" value={d.counts.archived} />
        </div>
        <p className="mt-2 text-xs text-slate-500">
          {d.counts.students_at_paying_schools.toLocaleString()} pupils inside the paying
          schools. That is the number your plan limits are about, and the number that
          decides who should be moved up at renewal.
        </p>
      </section>

      {/* --- the two rates -------------------------------------------------- */}
      <div className="grid gap-4 sm:grid-cols-2">
        <section className="rounded-lg border border-slate-200 bg-white p-4">
          <div className="text-xs font-semibold uppercase tracking-wide text-slate-500">
            Trials that became customers
          </div>
          {d.conversion.measurable ? (
            <>
              <div className="mt-2 text-2xl font-semibold text-slate-800">
                {d.conversion.rate_pct}%
              </div>
              <div className="text-sm text-slate-600">
                {d.conversion.converted} of {d.conversion.trials_finished} finished trials
              </div>
              <p className="mt-2 text-xs text-slate-500">{d.conversion.basis}</p>
            </>
          ) : (
            <Unknown why={d.conversion.why} />
          )}
        </section>

        <section className="rounded-lg border border-slate-200 bg-white p-4">
          <div className="text-xs font-semibold uppercase tracking-wide text-slate-500">
            Customers lost, last 12 months
          </div>
          {d.churn.measurable ? (
            <>
              <div className={`mt-2 text-2xl font-semibold ${
                d.churn.rate_pct > 15 ? 'text-amber-800' : 'text-slate-800'}`}>
                {d.churn.rate_pct}%
              </div>
              <div className="text-sm text-slate-600">
                {d.churn.lost_12m} school(s)
              </div>
              <p className="mt-2 text-xs text-slate-500">{d.churn.basis}</p>
            </>
          ) : (
            <Unknown why={d.churn.why} />
          )}
        </section>
      </div>

      {/* --- by plan -------------------------------------------------------- */}
      <section className="rounded-lg border border-slate-200 bg-white p-4">
        <div className="text-xs font-semibold uppercase tracking-wide text-slate-500">
          By plan
        </div>
        {/* SCROLLS rather than squeezing. `w-full` inside an overflow-x-auto
            wrapper compresses to the container instead of overflowing, so on a
            phone the last column was cut off and every plan name wrapped to four
            lines. A min-width is what makes the wrapper do its job. */}
        <div className="mt-2 overflow-x-auto">
          <table className="w-full min-w-[34rem] text-sm">
            <thead>
              <tr className="border-b border-slate-200 text-left text-xs uppercase tracking-wide text-slate-500">
                <th className="py-1.5">Plan</th>
                <th className="py-1.5 text-right">Schools</th>
                <th className="py-1.5 text-right">Pupils</th>
                <th className="py-1.5 text-right">MRR</th>
                <th className="py-1.5 text-right">At list</th>
                <th className="py-1.5 text-right">Given away</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-slate-100">
              {d.by_plan.map((p) => {
                const gap = Math.max(0, p.list_mrr - p.mrr)
                return (
                  <tr key={p.plan_code} className={p.schools === 0 ? 'text-slate-400' : ''}>
                    <td className="py-1.5">{p.plan_name}</td>
                    <td className="py-1.5 text-right tabular-nums">{p.schools}</td>
                    <td className="py-1.5 text-right tabular-nums">
                      {p.students.toLocaleString()}
                    </td>
                    <td className="py-1.5 text-right tabular-nums">{formatPkr(p.mrr)}</td>
                    <td className="py-1.5 text-right tabular-nums text-slate-400">
                      {formatPkr(p.list_mrr)}
                    </td>
                    {/* The gap between the two. 0064 exists because discounts
                        left no trace anywhere; this is that number, monthly. */}
                    <td className={`py-1.5 text-right tabular-nums ${
                      gap > 0 ? 'font-medium text-amber-800' : 'text-slate-300'}`}>
                      {gap > 0 ? formatPkr(gap) : '—'}
                    </td>
                  </tr>
                )
              })}
            </tbody>
          </table>
        </div>
        {givenAway > 0 && (
          <p className="mt-2 text-xs text-amber-800">
            {formatPkr(givenAway)} a month below list — {formatPkr(givenAway * 12)} a year.
            Every rupee of it was a decision somebody made with a reason recorded on the
            invoice.
          </p>
        )}
      </section>

      {/* --- growth --------------------------------------------------------- */}
      <section className="rounded-lg border border-slate-200 bg-white p-4">
        <div className="flex flex-wrap items-center justify-between gap-2">
          <div className="text-xs font-semibold uppercase tracking-wide text-slate-500">
            Pupils across all your schools
          </div>
          <select value={months} onChange={(e) => setMonths(Number(e.target.value))}
            className="rounded border border-slate-300 px-2 py-1 text-sm">
            <option value={6}>6 months</option>
            <option value={12}>12 months</option>
            <option value={24}>24 months</option>
          </select>
        </div>
        {g.error && <p className="mt-2 text-sm text-red-600">{(g.error as Error).message}</p>}
        {g.data && <Growth points={g.data} />}
        <p className="mt-2 text-xs text-slate-500">
          The last count recorded in each month, per school. Your customers&rsquo; growth is
          your own: a school that doubles its roll outgrows its plan, and this is where
          you see it coming.
        </p>
      </section>
    </div>
  )
}

function Unknown({ why }: { why: string }) {
  return (
    <div className="mt-2">
      {/* Rendered as an answer, not as an error. "We cannot know this yet" is a
          true statement about the business and the operator should read it as
          one. */}
      <div className="text-2xl font-semibold text-slate-300">not yet</div>
      <p className="mt-1 text-xs text-slate-500">{why}</p>
    </div>
  )
}

/**
 * Inline SVG, no charting library.
 *
 * A line for pupils and bars for schools, on one baseline. The y-axis starts at
 * ZERO rather than at the minimum: an axis that starts at the lowest value makes
 * a 2% rise look like a boom, which is the single most common way a growth chart
 * lies.
 */
function Growth({ points }: { points: GrowthPoint[] }) {
  if (points.length === 0) {
    return (
      <p className="mt-3 rounded border border-slate-200 bg-slate-50 px-3 py-2 text-sm text-slate-500">
        No counts recorded yet. Pupil counts are written whenever a child is admitted or
        the console refreshes them, so this fills in as the schools are used.
      </p>
    )
  }

  const W = 720, H = 160, PAD = 28
  const maxStudents = Math.max(...points.map((p) => p.students), 1)
  const maxSchools = Math.max(...points.map((p) => p.schools), 1)
  const x = (i: number) => PAD + (points.length === 1 ? (W - 2 * PAD) / 2
    : (i * (W - 2 * PAD)) / (points.length - 1))
  const y = (v: number) => H - PAD - ((H - 2 * PAD) * v) / maxStudents

  const line = points.map((p, i) => `${i === 0 ? 'M' : 'L'}${x(i)},${y(p.students)}`).join(' ')
  const barW = Math.max(4, (W - 2 * PAD) / Math.max(points.length, 1) * 0.35)

  return (
    <div className="mt-3 overflow-x-auto">
      <svg viewBox={`0 0 ${W} ${H}`} className="h-44 w-full min-w-[32rem]"
        role="img" aria-label="Pupils and schools by month">
        <line x1={PAD} y1={H - PAD} x2={W - PAD} y2={H - PAD}
          stroke="#cbd5e1" strokeWidth="1" />
        {points.map((p, i) => (
          <rect key={`b${i}`} x={x(i) - barW / 2}
            y={H - PAD - ((H - 2 * PAD) * p.schools) / maxSchools}
            width={barW}
            height={((H - 2 * PAD) * p.schools) / maxSchools}
            fill="#e2e8f0" />
        ))}
        <path d={line} fill="none" stroke="#0f766e" strokeWidth="2" />
        {points.map((p, i) => (
          <g key={`p${i}`}>
            <circle cx={x(i)} cy={y(p.students)} r="3" fill="#0f766e" />
            <title>
              {p.month} — {p.students.toLocaleString()} pupils across {p.schools} school(s)
            </title>
          </g>
        ))}
        {points.map((p, i) => (
          // Every third label on a long series, so a 24-month chart does not
          // turn its axis into a grey smear.
          (points.length <= 8 || i % 3 === 0) && (
            <text key={`t${i}`} x={x(i)} y={H - PAD + 12} textAnchor="middle"
              fontSize="10" fill="#94a3b8">
              {p.month.slice(0, 7)}
            </text>
          )
        ))}
        <text x={PAD} y={14} fontSize="10" fill="#0f766e">
          {maxStudents.toLocaleString()} pupils
        </text>
        <text x={W - PAD} y={14} fontSize="10" fill="#94a3b8" textAnchor="end">
          bars: schools (max {maxSchools})
        </text>
      </svg>
    </div>
  )
}

function Big({ label, value, hint }: { label: string; value: string; hint?: string }) {
  return (
    <div className="rounded border border-slate-200 p-3">
      <div className="text-xs uppercase tracking-wide text-slate-500">{label}</div>
      <div className="text-xl font-semibold text-slate-800">{value}</div>
      {hint && <div className="text-xs text-amber-700">{hint}</div>}
    </div>
  )
}

function Small({ label, value, tone }: {
  label: string; value: number; tone?: 'good' | 'warn'
}) {
  return (
    <div className={`rounded border px-2 py-1.5 ${
      tone === 'warn' ? 'border-amber-200 bg-amber-50'
        : tone === 'good' ? 'border-emerald-200 bg-emerald-50'
        : 'border-slate-200'}`}>
      <div className="text-xs text-slate-500">{label}</div>
      <div className="text-base font-semibold text-slate-800">{value}</div>
    </div>
  )
}

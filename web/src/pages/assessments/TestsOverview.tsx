import { useState } from 'react'
import { useQuery } from '@tanstack/react-query'
import { testsOverview, type TestOverviewRow, type TestState } from '@/lib/db'
import { fmtDate, todayISO } from '@/lib/format'
import { LoadError, EmptyState, inputClass } from '@/components/ui'

/**
 * What a head sees under Tests.
 *
 * Before 0135 this screen offered them a "New test" form, which is a thing a
 * head should not be doing, and offered them nothing at all for the thing they
 * should: knowing what their teachers have set and whether it has been marked.
 *
 * THE CALENDAR IS THE POINT, not decoration. A head auditing the week gone by
 * and a head checking what is coming on Saturday are asking the same question
 * of a different pair of dates, so one control serves both and the quick
 * ranges are the ones a school actually uses.
 *
 * `state` is computed in the database, not here, so that this screen, a future
 * report and anybody reading the tables by hand cannot disagree about what
 * "marked" means.
 */

const STATE: Record<TestState, { label: string; cls: string }> = {
  scheduled: { label: 'Scheduled', cls: 'bg-sky-100 text-sky-800' },
  unmarked: { label: 'Not marked', cls: 'bg-red-100 text-red-800' },
  partial: { label: 'Part marked', cls: 'bg-amber-100 text-amber-800' },
  marked: { label: 'Marked', cls: 'bg-emerald-100 text-emerald-800' },
  locked: { label: 'Finished', cls: 'bg-slate-200 text-slate-700' },
  undated: { label: 'No date', cls: 'bg-slate-100 text-slate-600' },
}

function shift(iso: string, days: number): string {
  const d = new Date(`${iso}T00:00:00`)
  d.setDate(d.getDate() + days)
  return d.toISOString().slice(0, 10)
}

type Range = { from: string; to: string }

/**
 * The quick ranges, worked out from TODAY rather than stored.
 *
 * "This week" is deliberately the last seven days and the next seven rather
 * than a calendar week: on a Monday morning a calendar week has almost nothing
 * in it, and the head's actual question is "recently, and soon".
 */
function quickRanges(today: string): { key: string; label: string; range: Range }[] {
  return [
    { key: 'week', label: 'Around now', range: { from: shift(today, -7), to: shift(today, 7) } },
    { key: 'back', label: 'Last 30 days', range: { from: shift(today, -30), to: today } },
    { key: 'ahead', label: 'Coming up', range: { from: today, to: shift(today, 30) } },
  ]
}

export function TestsOverview({ sessionId }: { sessionId: string }) {
  const today = todayISO()
  const ranges = quickRanges(today)
  const [range, setRange] = useState<Range>(ranges[0].range)

  const tests = useQuery({
    queryKey: ['testsOverview', sessionId, range.from, range.to],
    queryFn: () => testsOverview(sessionId, range.from, range.to),
  })
  const rows = tests.data ?? []

  const outstanding = rows.filter((r) => r.state === 'unmarked' || r.state === 'partial')
  const upcoming = rows.filter((r) => r.state === 'scheduled')

  return (
    <div>
      <LoadError of={[tests]} what="The tests overview" />

      <h1 className="text-xl font-semibold text-slate-800">Tests</h1>
      <p className="mt-1 text-sm text-slate-500">
        {fmtDate(today)} · tests are set and marked by the class and subject
        teachers. This is what they have set.
      </p>

      <div className="mt-4 grid gap-3 sm:grid-cols-2">
        <div className={
          'rounded-xl border px-4 py-3 '
          + (outstanding.length > 0 ? 'border-amber-200 bg-amber-50' : 'border-slate-200 bg-white')
        }>
          <div className="text-2xl font-semibold text-slate-800">{outstanding.length}</div>
          <div className="text-sm font-medium text-slate-700">Waiting to be marked</div>
          <div className="mt-0.5 text-xs text-slate-500">Sat, and not every pupil has a mark yet.</div>
        </div>
        <div className="rounded-xl border border-slate-200 bg-white px-4 py-3">
          <div className="text-2xl font-semibold text-slate-800">{upcoming.length}</div>
          <div className="text-sm font-medium text-slate-700">Scheduled</div>
          <div className="mt-0.5 text-xs text-slate-500">Set for a day that has not come.</div>
        </div>
      </div>

      {/* The calendar filter. Quick ranges first, because they are what gets
          used, with the exact dates underneath for an audit of one day. */}
      <div className="mt-5 flex flex-wrap items-end gap-3">
        <div className="flex flex-wrap gap-1">
          {ranges.map((r) => {
            const on = range.from === r.range.from && range.to === r.range.to
            return (
              <button key={r.key} onClick={() => setRange(r.range)}
                className={
                  'rounded-full px-3 py-1 text-sm font-medium ring-1 '
                  + (on ? 'bg-brand-600 text-white ring-brand-600'
                        : 'bg-white text-slate-600 ring-slate-300 hover:bg-slate-50')
                }>
                {r.label}
              </button>
            )
          })}
        </div>
        <label className="block">
          <span className="text-sm text-slate-600">From</span>
          <input type="date" value={range.from} className={inputClass}
            onChange={(e) => setRange((r) => ({ ...r, from: e.target.value }))} />
        </label>
        <label className="block">
          <span className="text-sm text-slate-600">To</span>
          <input type="date" value={range.to} className={inputClass}
            onChange={(e) => setRange((r) => ({ ...r, to: e.target.value }))} />
        </label>
      </div>

      {tests.isLoading && <p className="mt-6 text-sm text-slate-500">Loading…</p>}

      {!tests.isLoading && rows.length === 0 && (
        <div className="mt-6">
          <EmptyState
            title="No tests in these dates"
            message="Widen the dates, or wait for a teacher to set one. Tests are created by the class and subject teachers on their own Tests screen."
          />
        </div>
      )}

      {rows.length > 0 && <TestTable rows={rows} today={today} />}
    </div>
  )
}

function TestTable({ rows, today }: { rows: TestOverviewRow[]; today: string }) {
  return (
    <div className="mt-5 overflow-x-auto rounded-lg border border-slate-200 bg-white">
      <table className="w-full text-sm">
        <thead className="bg-slate-50 text-left text-xs uppercase tracking-wide text-slate-500">
          <tr>
            <th className="px-3 py-2 w-28">Date</th>
            <th className="px-3 py-2">Test</th>
            <th className="px-3 py-2">Class</th>
            <th className="px-3 py-2">Set by</th>
            <th className="px-3 py-2 w-28">Marked</th>
            <th className="px-3 py-2 w-28">Status</th>
          </tr>
        </thead>
        <tbody className="divide-y divide-slate-100">
          {rows.map((r) => {
            const s = STATE[r.state] ?? STATE.undated
            return (
              <tr key={r.assessment_id} className={r.assessment_date === today ? 'bg-brand-50/40' : ''}>
                <td className="px-3 py-1.5 text-slate-600">{fmtDate(r.assessment_date)}</td>
                <td className="px-3 py-1.5 text-slate-800">
                  {r.title}
                  <span className="text-slate-400"> · out of {r.max_marks}</span>
                </td>
                <td className="px-3 py-1.5 text-slate-600">
                  {r.class_name}{r.section_name ? ` · ${r.section_name}` : ''}
                  {r.subject_name ? <span className="text-slate-400"> · {r.subject_name}</span> : null}
                </td>
                <td className="px-3 py-1.5 text-slate-600">{r.set_by_name}</td>
                <td className="px-3 py-1.5 text-slate-600">
                  {/* Shown for every state except a test that has not been sat,
                      where "0 of 34" would read as a failure rather than as a
                      day that has not arrived. */}
                  {r.state === 'scheduled' ? '-' : `${r.marked} of ${r.pupils}`}
                </td>
                <td className="px-3 py-1.5">
                  <span className={`inline-flex rounded-full px-2 py-0.5 text-xs font-medium ${s.cls}`}>
                    {s.label}
                  </span>
                </td>
              </tr>
            )
          })}
        </tbody>
      </table>
    </div>
  )
}

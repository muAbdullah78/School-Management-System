import { useMemo, useState } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import {
  testsOverview, listTestsMarks, unlockAssessment,
  type TestOverviewRow, type TestState, type TestMarks,
} from '@/lib/db'
import { fmtDate, todayISO, shiftDate } from '@/lib/format'
import { LoadError, EmptyState, inputClass } from '@/components/ui'
import { C, ChartCard, HBars, MiniTable, StackBar, type Segment } from '@/components/viz'
import { ChartUnavailable } from '@/components/ChartUnavailable'
import { AskDialog } from '@/components/AskDialog'
import { useAuth } from '@/auth/AuthProvider'
import { APPROVER_ROLES, canWrite, type Role } from '@/auth/roles'

/**
 * What a head sees under Tests.
 *
 * Before 0135 this screen offered them a "New test" form, which is a thing a
 * head should not be doing, and nothing for the thing they should: knowing
 * what their teachers have set and whether it has been marked.
 *
 * THE CALENDAR IS THE POINT, not decoration. A head auditing the week gone by
 * and a head checking what is coming on Saturday are asking the same question
 * of a different pair of dates, so one control serves both.
 *
 * `state` is computed in the database, not here, so that this screen, a future
 * report and anybody reading the tables by hand cannot disagree about what
 * "marked" means.
 *
 * WHAT 0147 ADDED. The list said whether a test was marked and nothing about
 * how it went: a class where half the children failed read exactly like one
 * where nobody did. Each test now carries its class average and how many fell
 * below the school's pass mark, the range has a marking-progress bar and a
 * class-by-class average, and a locked test can be reopened by the owner or the
 * principal, with a reason, which until now nobody could do at all.
 *
 * THE QUICK RANGES WERE A DAY OUT IN PAKISTAN. shift() built local midnight and
 * read the date back in UTC, which in Karachi is 19:00 the day before, so
 * "Coming up" started yesterday and "Around now" was eight days back, not
 * seven. It now counts whole days in UTC, where a plain date has no clock.
 */

const STATE: Record<TestState, { label: string; cls: string; color: string }> = {
  scheduled: { label: 'Scheduled', cls: 'bg-info-50 text-info-800 ring-1 ring-info-100', color: C.info },
  unmarked: { label: 'Not marked', cls: 'bg-danger-50 text-danger-800 ring-1 ring-danger-100', color: C.bad },
  partial: { label: 'Part marked', cls: 'bg-due-50 text-due-800 ring-1 ring-due-100', color: C.warn },
  marked: { label: 'Marked, not locked', cls: 'bg-brand-50 text-brand-800 ring-1 ring-brand-100', color: C.series },
  locked: { label: 'Finished', cls: 'bg-slate-100 text-slate-700 ring-1 ring-slate-200', color: '#94a3b8' },
  undated: { label: 'No date', cls: 'bg-slate-100 text-slate-600 ring-1 ring-slate-200', color: C.none },
}

/** A plain date moved by whole days, in UTC, where a date has no clock. */
// Moved to lib/format, where the staff register uses it too. Re-exported so
// nothing that imported it from here breaks.
export { shiftDate }

type Range = { from: string; to: string }

/**
 * The quick ranges, worked out from TODAY rather than stored.
 *
 * "Around now" is deliberately the last seven days and the next seven rather
 * than a calendar week: on a Monday morning a calendar week has almost nothing
 * in it, and the head's actual question is "recently, and soon".
 */
export function quickRanges(today: string): { key: string; label: string; range: Range }[] {
  return [
    { key: 'week', label: 'Around now', range: { from: shiftDate(today, -7), to: shiftDate(today, 7) } },
    { key: 'back', label: 'Last 30 days', range: { from: shiftDate(today, -30), to: today } },
    { key: 'ahead', label: 'Coming up', range: { from: today, to: shiftDate(today, 30) } },
  ]
}

function daysBetween(a: string, b: string): number {
  const [ya, ma, da] = a.split('-').map(Number)
  const [yb, mb, db] = b.split('-').map(Number)
  return Math.round((Date.UTC(yb, mb - 1, db) - Date.UTC(ya, ma - 1, da)) / 86_400_000)
}

export function TestsOverview({ sessionId }: { sessionId: string }) {
  const today = todayISO()
  const ranges = quickRanges(today)
  const [range, setRange] = useState<Range>(ranges[0].range)
  const { profile } = useAuth()
  const mayReopen = !!profile && canWrite(profile.role) && APPROVER_ROLES.includes(profile.role as Role)

  // Refused here rather than by the database, so a head who types the dates
  // the wrong way round is told which box to fix instead of seeing an error.
  const rangeProblem = !range.from || !range.to
    ? 'Give both dates.'
    : range.to < range.from
      ? 'The end date is before the start date.'
      : daysBetween(range.from, range.to) > 400
        ? 'Ask for a year at a time or less.'
        : null

  const tests = useQuery({
    queryKey: ['testsOverview', sessionId, range.from, range.to],
    queryFn: () => testsOverview(sessionId, range.from, range.to),
    enabled: !rangeProblem,
  })
  const marks = useQuery({
    queryKey: ['testsMarks', sessionId, range.from, range.to],
    queryFn: () => listTestsMarks(sessionId, range.from, range.to),
    enabled: !rangeProblem,
    retry: false,
  })
  const rows = tests.data ?? []
  const byId = useMemo(() => {
    const m = new Map<string, TestMarks>()
    for (const r of marks.data ?? []) m.set(r.assessment_id, r)
    return m
  }, [marks.data])

  const outstanding = rows.filter((r) => r.state === 'unmarked' || r.state === 'partial')
  const upcoming = rows.filter((r) => r.state === 'scheduled')
  const gaps = rows.filter((r) => r.state === 'locked' && r.marked < r.pupils)
  const [reopening, setReopening] = useState<TestOverviewRow | null>(null)

  return (
    <div>
      <LoadError of={[tests]} what="The tests overview" />

      <h1 className="text-xl font-semibold text-slate-800">Tests</h1>
      <p className="mt-1 text-sm text-slate-500">
        {fmtDate(today)} · tests are set and marked by the class and subject
        teachers. This is what they have set, and how it went.
      </p>

      <div className="mt-4 grid grid-cols-2 gap-3 lg:grid-cols-4">
        <Tile n={outstanding.length} title="Waiting to be marked" blurb="Sat, and not every pupil has a mark yet."
          tone={outstanding.length > 0 ? 'due' : 'quiet'} />
        <Tile n={upcoming.length} title="Scheduled" blurb="Set for a day that has not come." tone="info" />
        <Tile n={rows.filter((r) => r.state === 'marked').length} title="Marked, not locked"
          blurb="Every pupil has a mark. The teacher can still change them." tone="brand" />
        <Tile n={rows.filter((r) => r.state === 'locked').length} title="Finished"
          blurb={gaps.length ? `${gaps.length} locked with children unmarked.` : 'Locked by the teacher.'}
          tone={gaps.length ? 'due' : 'quiet'} />
      </div>

      {/* The calendar filter. Quick ranges first, because they are what gets
          used, with the exact dates underneath for an audit of one day. */}
      <div className="mt-5 flex flex-wrap items-end gap-3">
        <div className="flex flex-wrap gap-1">
          {ranges.map((r) => {
            const on = range.from === r.range.from && range.to === r.range.to
            return (
              <button key={r.key} type="button" onClick={() => setRange(r.range)} aria-pressed={on}
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
      {rangeProblem && <p className="mt-2 text-sm text-danger-600">{rangeProblem}</p>}

      {!rangeProblem && tests.isLoading && <p className="mt-6 text-sm text-slate-500">Loading…</p>}

      {!rangeProblem && !tests.isLoading && !tests.isError && rows.length === 0 && (
        <div className="mt-6">
          <EmptyState
            title="No tests in these dates"
            message="Widen the dates, or wait for a teacher to set one. Tests are created by the class and subject teachers on their own Tests screen."
          />
        </div>
      )}

      {rows.length > 0 && (
        <>
          <div className="mt-5 grid grid-cols-1 gap-4 lg:grid-cols-2">
            <Progress rows={rows} fetching={tests.isFetching} />
            {marks.isError
              ? <ChartUnavailable error={marks.error} what="Test results" />
              : <ClassAverages rows={rows} byId={byId} fetching={marks.isFetching} />}
          </div>
          <TestList rows={rows} today={today} byId={byId} mayReopen={mayReopen}
            onReopen={(r) => setReopening(r)} />
        </>
      )}

      {reopening && (
        <Reopen row={reopening} sessionId={sessionId} onClose={() => setReopening(null)} />
      )}
    </div>
  )
}

function Tile({ n, title, blurb, tone }: {
  n: number; title: string; blurb: string; tone: 'due' | 'info' | 'brand' | 'quiet'
}) {
  const skin = tone === 'due' ? 'border-due-200 bg-due-50 text-due-900'
    : tone === 'info' ? 'border-info-200 bg-info-50 text-info-900'
    : tone === 'brand' ? 'border-brand-200 bg-brand-50 text-brand-900'
    : 'border-slate-200 bg-white text-slate-800'
  return (
    <div className={`rounded-2xl border px-4 py-3 ${skin}`}>
      <div className="text-2xl font-semibold tabular-nums">{n}</div>
      <div className="text-sm font-medium">{title}</div>
      <div className="mt-0.5 text-xs opacity-75">{blurb}</div>
    </div>
  )
}

/* ------------------------------------------------------ marking progress --- */

const ORDER: TestState[] = ['locked', 'marked', 'partial', 'unmarked', 'scheduled']

function Progress({ rows, fetching }: { rows: TestOverviewRow[]; fetching: boolean }) {
  const parts: Segment[] = ORDER.map((k) => ({
    key: k, label: STATE[k].label, value: rows.filter((r) => r.state === k).length, color: STATE[k].color,
  }))
  const sat = rows.filter((r) => r.state !== 'scheduled')
  const done = sat.filter((r) => r.state === 'marked' || r.state === 'locked').length
  return (
    <ChartCard
      fetching={fetching}
      title="Where the marking stands"
      subtitle={sat.length ? `${done} of ${sat.length} tests already sat are fully marked` : 'Nothing sat yet in these dates'}
      table={<MiniTable head={['', 'Tests']} align={['l', 'r']} rows={parts.map((p) => [p.label, p.value])} />}
    >
      <StackBar parts={parts} total={rows.length} height={14}
        label={`Tests in these dates: ${parts.map((p) => `${p.label} ${p.value}`).join(', ')}`} />
      <ul className="mt-3 grid grid-cols-1 gap-x-4 gap-y-1.5 text-sm sm:grid-cols-2">
        {parts.map((p) => (
          <li key={p.key} className="flex items-center gap-2">
            <span className="h-2.5 w-2.5 shrink-0 rounded-sm" style={{ background: p.color }} aria-hidden />
            <span className="min-w-0 flex-1 text-slate-600">{p.label}</span>
            <span className="font-medium tabular-nums text-slate-900">{p.value}</span>
          </li>
        ))}
      </ul>
    </ChartCard>
  )
}

/* ----------------------------------------------------- class by class --- */

function ClassAverages({
  rows, byId, fetching,
}: { rows: TestOverviewRow[]; byId: Map<string, TestMarks>; fetching: boolean }) {
  // One figure per class: the average of its tests' averages, so a class with
  // one 50-mark paper and four 10-mark quizzes is not decided by the paper.
  const per = new Map<string, { label: string; order: number; sum: number; n: number; below: number; sat: number }>()
  for (const r of rows) {
    const m = byId.get(r.assessment_id)
    if (!m || m.avg_pct == null) continue
    const k = r.class_id
    const cur = per.get(k) ?? { label: r.class_name, order: r.level_order, sum: 0, n: 0, below: 0, sat: 0 }
    cur.sum += m.avg_pct; cur.n += 1; cur.below += m.below_pass; cur.sat += m.sat
    per.set(k, cur)
  }
  const list = [...per.entries()]
    .map(([key, v]) => ({ key, ...v, avg: Math.round((10 * v.sum) / v.n) / 10 }))
    .sort((a, b) => a.order - b.order || a.label.localeCompare(b.label))
  const pass = [...byId.values()][0]?.pass_pct ?? 33
  if (list.length === 0) {
    return (
      <ChartCard title="Average mark, class by class">
        <p className="text-sm text-slate-500">Appears once a test in these dates has marks in it.</p>
      </ChartCard>
    )
  }
  return (
    <ChartCard
      fetching={fetching}
      title="Average mark, class by class"
      subtitle={`Across the marked tests in these dates · pass mark ${pass}%`}
      table={
        <MiniTable head={['Class', 'Tests', 'Average', 'Below pass']} align={['l', 'r', 'r', 'r']}
          rows={list.map((c) => [c.label, c.n, `${c.avg}%`, `${c.below} of ${c.sat}`])} />
      }
      footer="Each class's figure is the average of its tests' averages. Absent children are left out, not counted as zero."
    >
      <HBars
        label="Average mark by class"
        format={(n) => `${n}%`}
        rows={list.map((c) => ({
          key: c.key, label: c.label, value: c.avg,
          sub: c.below ? `${c.below} below pass` : undefined,
        }))}
      />
    </ChartCard>
  )
}

/* ------------------------------------------------------------ the list --- */

function Result({ m }: { m?: TestMarks }) {
  if (!m || m.avg_pct == null) return <span className="text-slate-400">-</span>
  const low = m.avg_pct < m.pass_pct
  return (
    <span className="inline-flex flex-col items-end">
      <span className={`font-semibold tabular-nums ${low ? 'text-danger-700' : 'text-slate-900'}`}>
        {m.avg_pct}%
        <span className="ml-1 text-xs font-normal text-slate-400">class average</span>
      </span>
      <span className="text-xs text-slate-500">
        {m.below_pass > 0
          ? <span className="text-danger-700">{m.below_pass} below pass</span>
          : 'nobody below pass'}
        {m.absent > 0 ? ` · ${m.absent} absent` : ''}
      </span>
    </span>
  )
}

function SetBy({ name }: { name: string }) {
  // Tests set before 0147 have no author on record, and the screen says so
  // rather than naming a person called "Unknown".
  return name === 'Unknown'
    ? <span className="italic text-slate-400">Not recorded</span>
    : <span>{name}</span>
}

function StatePill({ r }: { r: TestOverviewRow }) {
  const s = STATE[r.state] ?? STATE.undated
  const gappy = r.state === 'locked' && r.marked < r.pupils
  return (
    <span className={`inline-flex rounded-full px-2 py-0.5 text-xs font-medium ${gappy ? STATE.partial.cls : s.cls}`}>
      {gappy ? 'Locked with gaps' : s.label}
    </span>
  )
}

function TestList({
  rows, today, byId, mayReopen, onReopen,
}: {
  rows: TestOverviewRow[]; today: string; byId: Map<string, TestMarks>
  mayReopen: boolean; onReopen: (r: TestOverviewRow) => void
}) {
  return (
    <div className="mt-5 overflow-hidden rounded-2xl border border-slate-200 bg-white shadow-card">
      {/* Phone: one card a test. */}
      <ul className="divide-y divide-slate-100 sm:hidden">
        {rows.map((r) => (
          <li key={r.assessment_id} className={`px-3 py-3 ${r.assessment_date === today ? 'bg-brand-50/40' : ''}`}>
            <div className="flex items-start justify-between gap-2">
              <div className="min-w-0">
                <div className="font-medium text-slate-800">{r.title}</div>
                <div className="text-xs text-slate-500">
                  {r.class_name}{r.section_name ? ` · ${r.section_name}` : ''}
                  {r.subject_name ? ` · ${r.subject_name}` : ''} · out of {r.max_marks}
                </div>
                <div className="text-xs text-slate-500">
                  {fmtDate(r.assessment_date)} · <SetBy name={r.set_by_name} />
                </div>
              </div>
              <StatePill r={r} />
            </div>
            <div className="mt-2 flex items-end justify-between gap-2 text-sm">
              <span className="text-xs text-slate-600">
                {r.state === 'scheduled' ? 'Not sat yet' : `${r.marked} of ${r.pupils} marked`}
              </span>
              <Result m={byId.get(r.assessment_id)} />
            </div>
            {mayReopen && r.state === 'locked' && (
              <button type="button" onClick={() => onReopen(r)}
                className="mt-2 text-xs font-medium text-brand-700 hover:underline">
                Reopen for corrections
              </button>
            )}
          </li>
        ))}
      </ul>

      <table className="hidden w-full text-sm sm:table">
        <thead className="bg-slate-50 text-left text-xs uppercase tracking-wide text-slate-500">
          <tr>
            <th className="w-28 px-3 py-2">Date</th>
            <th className="px-3 py-2">Test</th>
            <th className="px-3 py-2">Class</th>
            <th className="px-3 py-2">Set by</th>
            <th className="w-28 px-3 py-2">Marked</th>
            <th className="px-3 py-2 text-right">How it went</th>
            <th className="w-40 px-3 py-2">Status</th>
          </tr>
        </thead>
        <tbody className="divide-y divide-slate-100">
          {rows.map((r) => (
            <tr key={r.assessment_id} className={r.assessment_date === today ? 'bg-brand-50/40' : ''}>
              <td className="px-3 py-2 text-slate-600">{fmtDate(r.assessment_date)}</td>
              <td className="px-3 py-2 text-slate-800">
                {r.title}
                <span className="text-slate-400"> · out of {r.max_marks}</span>
              </td>
              <td className="px-3 py-2 text-slate-600">
                {r.class_name}{r.section_name ? ` · ${r.section_name}` : ''}
                {r.subject_name ? <span className="text-slate-400"> · {r.subject_name}</span> : null}
              </td>
              <td className="px-3 py-2 text-slate-600"><SetBy name={r.set_by_name} /></td>
              <td className="px-3 py-2 text-slate-600">
                {/* Not for a test that has not been sat, where "0 of 34" would
                    read as a failure rather than as a day not yet arrived. */}
                {r.state === 'scheduled' ? '-' : `${r.marked} of ${r.pupils}`}
              </td>
              <td className="px-3 py-2 text-right"><Result m={byId.get(r.assessment_id)} /></td>
              <td className="px-3 py-2">
                <StatePill r={r} />
                {mayReopen && r.state === 'locked' && (
                  <button type="button" onClick={() => onReopen(r)}
                    className="ml-2 text-xs font-medium text-brand-700 hover:underline">
                    Reopen
                  </button>
                )}
              </td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  )
}

/* -------------------------------------------------------------- reopen --- */

function Reopen({ row, sessionId, onClose }: { row: TestOverviewRow; sessionId: string; onClose: () => void }) {
  const qc = useQueryClient()
  const m = useMutation({
    mutationFn: (reason: string) => unlockAssessment(row.assessment_id, reason),
    onSuccess: () => {
      void qc.invalidateQueries({ queryKey: ['testsOverview', sessionId] })
      void qc.invalidateQueries({ queryKey: ['testsMarks', sessionId] })
      void qc.invalidateQueries({ queryKey: ['assessments'] })
      onClose()
    },
  })
  return (
    <AskDialog
      title="Reopen this test?"
      intro={<>
        <b>{row.title}</b>, {row.class_name}{row.section_name ? ` ${row.section_name}` : ''}
        {row.subject_name ? `, ${row.subject_name}` : ''}, {fmtDate(row.assessment_date)}. The teacher
        can change its marks again until it is locked once more. Your reason is kept on the
        school&rsquo;s history with your name.
      </>}
      reason={{
        label: 'Why is it being reopened?', required: true, minLength: 4,
        placeholder: 'e.g. two papers were marked out of 10, not 20',
      }}
      confirmLabel="Reopen the test"
      busy={m.isPending}
      error={m.error ? (m.error as Error).message : null}
      onCancel={onClose}
      onSubmit={(v) => m.mutate(v.reason)}
    />
  )
}

import { useMemo, useState } from 'react'
import { Link } from 'react-router-dom'
import { useQuery } from '@tanstack/react-query'
import {
  attendanceDay, subjectAttendanceDay, getRoster, getAttendanceOverview,
  type AttendanceDayRow, type SubjectAttendanceDayRow, type AttendanceTally,
  type AttendanceDay, type AttendanceWatch,
} from '@/lib/db'
import { todayISO, fmtDate, grLabel } from '@/lib/format'
import { ATTENDANCE_STATUSES } from '@/lib/constants'
import { Button, Card, CardTitle, EmptyState, LoadError, inputClass, buttonClass } from '@/components/ui'
import {
  C, ChartCard, Donut, Legend, MiniTable, StackBar, TrendLine, attendanceParts, severity,
} from '@/components/viz'
import { ChartUnavailable } from '@/components/ChartUnavailable'
import { IconAlert, IconCheck, IconClock } from '@/components/icons'
import { attendancePct } from '@/pages/Dashboard'

/**
 * What a head sees when they open Attendance.
 *
 * WHY THIS SCREEN EXISTS AND THE OLD ONE DID NOT SERVE
 *
 * Before 0134 a principal opening Attendance got a class picker and a list of
 * pupils: a tool for marking ONE section, which is now a thing they may not do.
 * The question a head actually has at 9.40 in the morning is the opposite
 * shape:
 *
 *   which classes have marked, which have not, and which said they were done
 *   and never locked it?
 *
 * THE THREE PILES, AND WHY A PARTLY MARKED CLASS IS IN THE AMBER ONE
 *
 * "Done but unlocked" means every pupil has a mark and the teacher has not
 * finalised. "Not done" covers both nothing at all AND 12 of 34, because from
 * the head's chair those are the same problem: the register for that class is
 * not a register yet. The count is on the card so the difference is visible.
 *
 * WHAT 0147 ADDED. The piles said who had marked and nothing about what they
 * marked: a class with nine children away looked exactly like a full one. Each
 * card now carries its own tally bar, the day has one ring for the whole
 * school, the last twenty school days are a line, and the children below the
 * 75 per cent board-exam line are named. All of it comes from
 * fn_attendance_overview, which counts the same roll fn_attendance_day does, so
 * "12 of 30 marked" and the bar beside it are one set of children.
 *
 * A database without bundle 48 still gets the piles and the cards: the charts
 * say they are not switched on, and nothing else changes.
 */

type Pile = 'todo' | 'unlocked' | 'locked'

/** The three piles, in the order a head wants to see them: problems first. */
const PILES: { key: Pile; title: string; blurb: string }[] = [
  { key: 'todo', title: 'Not done', blurb: 'No register yet, or only part of one.' },
  { key: 'unlocked', title: 'Done, not locked', blurb: 'Every pupil marked. The teacher has not finalised it.' },
  { key: 'locked', title: 'Done and locked', blurb: 'Finalised. Reopen one from the class if it needs a correction.' },
]

const PILE_SKIN: Record<Pile, { tile: string; icon: JSX.Element }> = {
  todo: { tile: 'border-due-200 bg-due-50 text-due-900', icon: <IconAlert /> },
  unlocked: { tile: 'border-brand-200 bg-brand-50 text-brand-900', icon: <IconClock /> },
  locked: { tile: 'border-slate-200 bg-white text-slate-800', icon: <IconCheck /> },
}

function pileOf(r: AttendanceDayRow): Pile {
  if (r.state === 'locked') return 'locked'
  if (r.state === 'unlocked') return 'unlocked'
  return 'todo'
}

function rowKey(r: { class_id: string; section_id: string | null }) {
  return `${r.class_id}|${r.section_id ?? ''}`
}

function rowLabel(r: AttendanceDayRow) {
  return r.section_name ? `${r.class_name} · ${r.section_name}` : r.class_name
}

/** A plain date moved by whole days, without the browser's timezone. */
function shiftDay(iso: string, by: number): string {
  const [y, m, d] = iso.split('-').map(Number)
  const t = new Date(Date.UTC(y, m - 1, d + by))
  return t.toISOString().slice(0, 10)
}

function dayLabel(iso: string, long = false): string {
  const [y, m, d] = iso.split('-').map(Number)
  if (!y || !m || !d) return iso
  return new Date(Date.UTC(y, m - 1, d)).toLocaleDateString('en-GB', {
    ...(long ? { weekday: 'short' as const } : {}), day: 'numeric', month: 'short', timeZone: 'UTC',
  })
}

function weekday(iso: string): string {
  const [y, m, d] = iso.split('-').map(Number)
  return new Date(Date.UTC(y, m - 1, d)).toLocaleDateString('en-GB', { weekday: 'long', timeZone: 'UTC' })
}

export function AttendanceOverview({ sessionId }: { sessionId: string }) {
  const today = todayISO()
  const [date, setDate] = useState(today)
  const [open, setOpen] = useState<AttendanceDayRow | null>(null)

  const day = useQuery({
    queryKey: ['attendanceDay', sessionId, date],
    queryFn: () => attendanceDay(sessionId, date),
  })
  const subjects = useQuery({
    queryKey: ['subjectAttendanceDay', sessionId, date],
    queryFn: () => subjectAttendanceDay(sessionId, date),
  })
  const overview = useQuery({
    queryKey: ['attendanceOverview', sessionId, date],
    queryFn: () => getAttendanceOverview(sessionId, date),
    retry: false,
  })

  const rows = day.data ?? []
  const counts = {
    todo: rows.filter((r) => pileOf(r) === 'todo').length,
    unlocked: rows.filter((r) => pileOf(r) === 'unlocked').length,
    locked: rows.filter((r) => pileOf(r) === 'locked').length,
  }
  const tallies = useMemo(() => {
    const m = new Map<string, AttendanceTally>()
    for (const t of overview.data?.sections ?? []) m.set(rowKey(t), t)
    return m
  }, [overview.data])

  function go(next: string) {
    setDate(next > today ? today : next)
    setOpen(null)
  }

  return (
    <div>
      <LoadError of={[day, subjects]} what="The register overview" />

      <div className="flex flex-wrap items-end justify-between gap-3">
        <div>
          <h1 className="text-xl font-semibold text-slate-800">Attendance</h1>
          {/* The date in words as well as in the picker. A head auditing last
              Tuesday needs to be sure which day they are looking at. */}
          <p className="mt-1 text-sm text-slate-500">
            {weekday(date)}, {fmtDate(date)}
            {date === today ? ' · today' : ''} · {rows.length} class{rows.length === 1 ? '' : 'es'} on the roll
          </p>
        </div>
        <div className="flex flex-wrap items-end gap-2">
          <Button variant="soft" tone="neutral" onClick={() => go(shiftDay(date, -1))} aria-label="The day before">
            ←<span className="hidden sm:inline"> Day before</span>
          </Button>
          <label className="block">
            <span className="sr-only">Day</span>
            <input type="date" value={date} max={today} className={inputClass}
              onChange={(e) => { if (e.target.value) go(e.target.value) }} />
          </label>
          <Button variant="soft" tone="neutral" disabled={date >= today}
            onClick={() => go(shiftDay(date, 1))} aria-label="The day after">
            <span className="hidden sm:inline">Day after </span>→
          </Button>
          {date !== today && (
            <Button variant="soft" tone="brand" onClick={() => go(today)}>Today</Button>
          )}
        </div>
      </div>

      {/* ------------------------------------------------ the three piles -- */}
      {/* Three across on a phone too: they are three counts of one thing, and
          stacked they pushed the first class card below the fold. */}
      <div className="mt-4 grid grid-cols-3 gap-2 sm:gap-3">
        {PILES.map((p) => {
          const quiet = p.key === 'todo' && counts.todo === 0
          const skin = quiet ? PILE_SKIN.locked : PILE_SKIN[p.key]
          return (
            <div key={p.key} className={`flex items-start gap-3 rounded-2xl border px-3 py-2.5 sm:px-4 sm:py-3 ${skin.tile}`}>
              <span className="mt-1 hidden shrink-0 opacity-70 sm:block" aria-hidden>{PILE_SKIN[p.key].icon}</span>
              <div className="min-w-0">
                <div className="text-xl font-semibold tabular-nums sm:text-2xl">{counts[p.key]}</div>
                <div className="text-xs font-medium leading-tight sm:text-sm">{p.title}</div>
                <div className="mt-0.5 hidden text-xs opacity-75 sm:block">{p.blurb}</div>
              </div>
            </div>
          )
        })}
      </div>

      {/* ------------------------------------------- the day, and the trend -- */}
      {overview.isError ? (
        <ChartUnavailable error={overview.error} what="The attendance charts" className="mt-5" />
      ) : overview.data && rows.length > 0 ? (
        <div className="mt-5 grid grid-cols-1 gap-4 lg:grid-cols-3">
          <SchoolDay sections={overview.data.sections} date={date} fetching={overview.isFetching} />
          <Trend trend={overview.data.trend} date={date} fetching={overview.isFetching} className="lg:col-span-2" />
        </div>
      ) : null}

      {day.isLoading && <p className="mt-6 text-sm text-slate-500">Loading…</p>}

      {!day.isLoading && !day.isError && rows.length === 0 && (
        <div className="mt-6">
          <EmptyState
            title="No classes on the roll"
            message="Add classes and enrol pupils, and this screen will show one card for each class every morning."
          />
        </div>
      )}

      {/* ------------------------------------------------- one card a class -- */}
      {PILES.map((p) => {
        const inPile = rows.filter((r) => pileOf(r) === p.key)
        if (inPile.length === 0) return null
        return (
          <div key={p.key} className="mt-6">
            <h2 className="text-xs font-semibold uppercase tracking-wide text-slate-500">
              {p.title} <span className="font-normal normal-case tracking-normal text-slate-400">· {inPile.length}</span>
            </h2>
            <div className="mt-2 grid gap-2 sm:grid-cols-2 lg:grid-cols-3">
              {inPile.map((r) => (
                <ClassCard
                  key={rowKey(r)}
                  row={r}
                  tally={tallies.get(rowKey(r))}
                  open={!!open && rowKey(open) === rowKey(r)}
                  onClick={() => setOpen(open && rowKey(open) === rowKey(r) ? null : r)}
                />
              ))}
            </div>
          </div>
        )
      })}

      {open && (
        <ReadOnlyRegister
          sessionId={sessionId}
          row={open}
          date={date}
          onClose={() => setOpen(null)}
        />
      )}

      {overview.data && <Watchlist rows={overview.data.watchlist} date={date} />}

      <SubjectPanel rows={subjects.data ?? []} loading={subjects.isLoading} />
    </div>
  )
}

/* ------------------------------------------------------------- the day --- */

function SchoolDay({
  sections, date, fetching,
}: { sections: AttendanceTally[]; date: string; fetching: boolean }) {
  const tot = sections.reduce(
    (a, s) => ({
      pupils: a.pupils + s.pupils, marked: a.marked + s.marked,
      present: a.present + s.present, late: a.late + s.late, half_day: a.half_day + s.half_day,
      leave: a.leave + s.leave, absent: a.absent + s.absent,
    }),
    { pupils: 0, marked: 0, present: 0, late: 0, half_day: 0, leave: 0, absent: 0 },
  )
  const parts = attendanceParts(tot, tot.pupils)
  const pct = attendancePct(tot)
  return (
    <ChartCard
      fetching={fetching}
      title={`The school on ${dayLabel(date, true)}`}
      subtitle={`${tot.marked} of ${tot.pupils} children marked`}
      table={
        <MiniTable head={['', 'Children']} align={['l', 'r']}
          rows={parts.map((p) => [p.label, p.value])} />
      }
    >
      <div className="flex flex-col items-center gap-4 sm:flex-row lg:flex-col">
        <Donut
          segments={parts}
          label={`Attendance on ${dayLabel(date, true)}`}
          center={
            tot.marked === 0 ? (
              <span className="text-xs text-slate-500">No register marked yet</span>
            ) : (
              <>
                <span className="text-2xl font-semibold text-slate-900">{pct == null ? '-' : `${Math.round(pct)}%`}</span>
                <span className="text-[11px] text-slate-500">attended</span>
              </>
            )
          }
        />
        <div className="w-full min-w-0 flex-1">
          <Legend items={parts} total={tot.pupils} />
        </div>
      </div>
    </ChartCard>
  )
}

function Trend({
  trend, date, fetching, className = '',
}: { trend: AttendanceDay[]; date: string; fetching: boolean; className?: string }) {
  if (!trend.length) {
    return (
      <ChartCard title="Attendance, school day by school day" className={className}>
        <p className="text-sm text-slate-500">
          The line starts on the first day a register is marked. Sundays and holidays have no register, so
          they are left out rather than drawn as zero.
        </p>
      </ChartCard>
    )
  }
  const tot = trend.reduce(
    (a, r) => ({ present: a.present + r.present, late: a.late + r.late, half_day: a.half_day + r.half_day, marked: a.marked + r.marked }),
    { present: 0, late: 0, half_day: 0, marked: 0 },
  )
  const avg = attendancePct(tot)
  const withPct = trend.filter((r) => r.pct != null)
  const low = withPct.reduce<AttendanceDay | null>((m, r) => (m == null || (r.pct as number) < (m.pct as number) ? r : m), null)
  const floor = withPct.every((r) => (r.pct as number) >= 55) ? 50 : 0
  return (
    <ChartCard
      fetching={fetching}
      className={className}
      title={`Attendance, the ${trend.length} school day${trend.length === 1 ? '' : 's'} up to ${dayLabel(date)}`}
      subtitle={
        avg == null ? undefined
          : `${avg}% across the period${low && trend.length > 1 ? ` · lowest ${Math.round(low.pct as number)}% on ${dayLabel(low.date, true)}` : ''}`
      }
      table={
        <MiniTable
          head={['Day', 'Marked', 'Present', 'Late or half', 'Leave', 'Absent', '%']}
          align={['l', 'r', 'r', 'r', 'r', 'r', 'r']}
          rows={[...trend].reverse().map((r) => [
            dayLabel(r.date, true), r.marked, r.present, r.late + r.half_day, r.leave, r.absent,
            r.pct == null ? '-' : `${Math.round(r.pct)}%`,
          ])}
        />
      }
      footer="A day counts once any register is marked. The line is the whole school; open a class card for one class."
    >
      <TrendLine
        label={`Attendance by school day, ${trend.length} days`}
        yMin={floor}
        yTicks={floor ? [50, 75, 100] : [0, 25, 50, 75, 100]}
        reference={{ value: 75, label: '75%, the board-exam line' }}
        points={trend.map((r) => ({
          key: r.date,
          label: dayLabel(r.date),
          value: r.pct,
          tipTitle: dayLabel(r.date, true),
          tipRows: [
            { label: 'attended', value: r.pct == null ? '-' : `${Math.round(r.pct)}%`, color: C.series },
            { label: 'absent', value: String(r.absent) },
            { label: 'on leave', value: String(r.leave) },
            { label: 'marked', value: String(r.marked) },
          ],
        }))}
      />
    </ChartCard>
  )
}

/* -------------------------------------------------------- one class card --- */

function ClassCard({
  row, tally, open, onClick,
}: { row: AttendanceDayRow; tally?: AttendanceTally; open: boolean; onClick: () => void }) {
  const pct = tally && tally.marked > 0 ? tally.pct : null
  const sev = severity(pct)
  const parts = tally ? attendanceParts(tally, tally.pupils) : null
  return (
    <button
      type="button"
      onClick={onClick}
      aria-expanded={open}
      className={`rounded-xl border bg-white px-3 py-2.5 text-left shadow-card transition hover:shadow-raised ${
        open ? 'border-brand-400 ring-1 ring-brand-300' : 'border-slate-200'
      }`}
    >
      <div className="flex items-start justify-between gap-2">
        <div className="min-w-0">
          <div className="truncate font-medium text-slate-800">{rowLabel(row)}</div>
          <div className="mt-0.5 text-xs text-slate-500">
            {row.marked} of {row.pupils} marked
            {row.state === 'locked' ? ' · locked' : ''}
          </div>
        </div>
        {pct != null && (
          <span
            className="shrink-0 rounded-full px-2 py-0.5 text-xs font-semibold tabular-nums"
            style={{ background: sev.track, color: '#0f172a' }}
            title={`${sev.word}: ${Math.round(pct)}% attended`}
          >
            {Math.round(pct)}%
          </span>
        )}
      </div>
      {parts && (
        <div className="mt-2">
          <StackBar parts={parts} total={tally!.pupils} height={8}
            label={`${rowLabel(row)}: ${parts.map((p) => `${p.label} ${p.value}`).join(', ')}`} />
          {tally!.marked > 0 && (tally!.absent > 0 || tally!.leave > 0 || tally!.late + tally!.half_day > 0) && (
            <div className="mt-1.5 flex flex-wrap gap-x-3 text-[11px] text-slate-500">
              {tally!.absent > 0 && <span><b className="font-semibold text-danger-700">{tally!.absent}</b> absent</span>}
              {tally!.late + tally!.half_day > 0 && <span><b className="font-semibold text-due-800">{tally!.late + tally!.half_day}</b> late or half day</span>}
              {tally!.leave > 0 && <span><b className="font-semibold text-info-700">{tally!.leave}</b> on leave</span>}
            </div>
          )}
        </div>
      )}
    </button>
  )
}

/* ------------------------------------------------------------ watchlist --- */

/**
 * The children below 75 per cent this session. The number that decides who may
 * sit a board exam, so the list is the one a head calls parents from. Ten
 * marked days at least, or one absence in the first week names a child.
 */
function Watchlist({ rows, date }: { rows: AttendanceWatch[]; date: string }) {
  return (
    <ChartCard
      className="mt-6"
      title="Below 75% this session"
      subtitle={
        rows.length === 0
          ? `Nobody, up to ${dayLabel(date, true)}. Children with fewer than ten marked days are not counted yet.`
          : `${rows.length}${rows.length === 50 ? ' or more' : ''} child${rows.length === 1 ? '' : 'ren'}, lowest first, up to ${dayLabel(date, true)}`
      }
      footer="75% is the line a board exam draws. Open a child for their whole register."
    >
      {rows.length === 0 ? (
        <p className="rounded-xl border border-money-200 bg-money-50 px-3 py-2.5 text-sm text-money-800">
          Every child with ten or more marked days is at 75% or above.
        </p>
      ) : (
        <ul className="divide-y divide-slate-100">
          {rows.map((w) => (
            <li key={w.student_id} className="flex items-center gap-3 py-2">
              <div className="min-w-0 flex-1">
                <Link to={`/students?student=${w.student_id}`}
                  className="block truncate text-sm font-medium text-slate-800 hover:underline">
                  {w.full_name}
                </Link>
                <div className="text-xs text-slate-500">
                  {w.class_name}{w.section_name ? ` · ${w.section_name}` : ''}
                  {w.gr_no ? ` · ${grLabel(w.gr_no)}` : ''}
                  <span className="block sm:inline">
                    <span className="hidden sm:inline"> · </span>
                    {w.absent} absent, {w.leave} on leave, of {w.marked} days
                  </span>
                </div>
              </div>
              <div className="hidden w-28 shrink-0 sm:block">
                <div className="h-2 rounded-full bg-danger-100">
                  <div className="h-2 rounded-full" style={{ width: `${Math.max(3, Math.min(100, w.pct))}%`, background: C.bad }} />
                </div>
              </div>
              <span className="w-14 shrink-0 text-right text-sm font-semibold tabular-nums text-danger-700">
                {Math.round(w.pct)}%
              </span>
            </li>
          ))}
        </ul>
      )}
    </ChartCard>
  )
}

/* -------------------------------------------------------- one register --- */

/**
 * The register itself, read only.
 *
 * No marking controls at all, for anybody who reaches this screen. The head
 * reading a class they are worried about is the whole use, and a Save button
 * here would be the thing 0134 removed growing back in a different place.
 */
const STATUS_TEXT: Record<string, string> = {
  present: 'text-money-700', absent: 'text-danger-700', leave: 'text-info-700',
  late: 'text-due-800', half_day: 'text-due-800',
}

function ReadOnlyRegister({
  sessionId, row, date, onClose,
}: { sessionId: string; row: AttendanceDayRow; date: string; onClose: () => void }) {
  const roster = useQuery({
    queryKey: ['roster', sessionId, row.class_id, row.section_id ?? 'none', date],
    queryFn: () => getRoster(sessionId, row.class_id, row.section_id, date),
  })
  const rows = roster.data ?? []
  const count = (s: string) => rows.filter((r) => r.status === s).length
  const tally = {
    present: count('present'), late: count('late'), half_day: count('half_day'),
    leave: count('leave'), absent: count('absent'),
    marked: rows.filter((r) => r.status).length,
  }
  const parts = attendanceParts(tally, rows.length)

  return (
    <Card className="mt-6">
      <CardTitle right={
        <button onClick={onClose} className={buttonClass({ variant: 'soft', tone: 'neutral', size: 'sm', className: 'normal-case tracking-normal' })}>
          Close
        </button>
      }>
        {rowLabel(row)} · {fmtDate(date)}
      </CardTitle>
      <LoadError of={[roster]} what="That class's register" />
      {rows.length > 0 && (
        <div className="mt-2">
          <StackBar parts={parts} total={rows.length} height={10}
            label={`${rowLabel(row)}: ${parts.map((p) => `${p.label} ${p.value}`).join(', ')}`} />
          <div className="mt-2 flex flex-wrap gap-x-4 gap-y-1 text-xs text-slate-600">
            {parts.map((p) => (
              <span key={p.key} className="inline-flex items-center gap-1.5">
                <span className="h-2 w-2 rounded-sm" style={{ background: p.color }} aria-hidden />
                {p.label} <b className="font-semibold tabular-nums text-slate-900">{p.value}</b>
              </span>
            ))}
          </div>
        </div>
      )}

      {roster.isLoading && <p className="mt-3 text-sm text-slate-500">Loading…</p>}
      {!roster.isLoading && rows.length > 0 && (
        <ul className="mt-3 divide-y divide-slate-100 rounded-xl border border-slate-200">
          {rows.map((r) => (
            <li key={r.enrollment_id} className="flex items-center gap-3 px-3 py-1.5 text-sm">
              <span className="w-8 shrink-0 text-right text-xs tabular-nums text-slate-400">{r.roll_no ?? '-'}</span>
              <span className="min-w-0 flex-1 truncate text-slate-800">{r.full_name}</span>
              {r.status
                ? <span className={`shrink-0 font-medium ${STATUS_TEXT[r.status] ?? 'text-slate-700'}`}>
                    {ATTENDANCE_STATUSES.find((s) => s.value === r.status)?.label ?? r.status}
                  </span>
                : <span className="shrink-0 text-due-800">Not marked</span>}
            </li>
          ))}
        </ul>
      )}
    </Card>
  )
}

/**
 * Subject attendance, which is a DIFFERENT QUESTION and is presented as one.
 *
 * Only subjects that were actually marked appear. There is no "not done" here
 * and there must not be: nobody is asked to keep this register, so listing
 * every unmarked subject would put forty rows on this screen every morning and
 * teach the head to stop reading the panel above it as well.
 */
function SubjectPanel({
  rows, loading,
}: { rows: SubjectAttendanceDayRow[]; loading: boolean }) {
  return (
    <div className="mt-8">
      <h2 className="text-xs font-semibold uppercase tracking-wide text-slate-500">
        Subject attendance
      </h2>
      <p className="mt-1 text-sm text-slate-500">
        Kept by subject teachers when they choose to. It is separate from the daily
        register above and does not change any attendance percentage.
      </p>
      {loading && <p className="mt-3 text-sm text-slate-500">Loading…</p>}
      {!loading && rows.length === 0 && (
        <p className="mt-3 rounded-lg border border-dashed border-slate-300 bg-slate-50/60 px-4 py-6 text-center text-sm text-slate-500">
          No subject teacher marked a subject on this day.
        </p>
      )}
      {rows.length > 0 && (
        <ul className="mt-3 divide-y divide-slate-100 rounded-xl border border-slate-200 bg-white">
          {rows.map((r) => {
            const total = r.present + r.absent + r.other
            return (
              <li key={`${r.class_id}|${r.section_id ?? ''}|${r.subject_id}`}
                className="flex flex-wrap items-center gap-x-4 gap-y-1 px-3 py-2 text-sm">
                <div className="min-w-0 flex-1">
                  <div className="font-medium text-slate-800">
                    {r.subject_name}
                    <span className="font-normal text-slate-500">
                      {' · '}{r.section_name ? `${r.class_name} · ${r.section_name}` : r.class_name}
                    </span>
                  </div>
                  <div className="text-xs text-slate-500">Marked by {r.marked_by_name}</div>
                </div>
                <div className="flex shrink-0 gap-3 text-xs tabular-nums">
                  <span className="text-money-700"><b className="font-semibold">{r.present}</b> present</span>
                  <span className="text-danger-700"><b className="font-semibold">{r.absent}</b> absent</span>
                  {r.other > 0 && <span className="text-slate-600"><b className="font-semibold">{r.other}</b> other</span>}
                  <span className="text-slate-400">of {total}</span>
                </div>
              </li>
            )
          })}
        </ul>
      )}
    </div>
  )
}

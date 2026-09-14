import { useState } from 'react'
import { useQuery } from '@tanstack/react-query'
import {
  attendanceDay, subjectAttendanceDay, getRoster,
  type AttendanceDayRow, type SubjectAttendanceDayRow,
} from '@/lib/db'
import { todayISO, fmtDate } from '@/lib/format'
import { ATTENDANCE_STATUSES } from '@/lib/constants'
import { Badge, Card, CardTitle, EmptyState, LoadError, inputClass } from '@/components/ui'

/**
 * What a head sees when they open Attendance.
 *
 * WHY THIS SCREEN EXISTS AND THE OLD ONE DID NOT SERVE
 *
 * Before 0134 a principal opening Attendance got a class picker and a list of
 * pupils: a tool for marking ONE section, which is now a thing they may not do.
 * The question a head actually has at 9.40 in the morning is the opposite
 * shape, and this software could not answer it for anybody:
 *
 *   which classes have marked, which have not, and which said they were done
 *   and never locked it?
 *
 * THE THREE PILES, AND WHY A PARTLY MARKED CLASS IS IN THE RED ONE
 *
 * "Done but unlocked" means every pupil has a mark and the teacher has not
 * finalised. "Not done" covers both nothing at all AND 12 of 34, because from
 * the head's chair those are the same problem: the register for that class is
 * not a register yet. The count is shown on the card so the difference is
 * visible without being a fourth pile nobody has a word for.
 *
 * The counting happens in the database, against the ROLL rather than against
 * attendance rows. An unmarked child is not a row, so counting rows would make
 * an empty register look complete.
 */

/** The three piles, in the order a head wants to see them: problems first. */
const PILES: { key: 'todo' | 'unlocked' | 'locked'; title: string; blurb: string }[] = [
  { key: 'todo', title: 'Not done', blurb: 'No register yet, or only part of one.' },
  { key: 'unlocked', title: 'Done, not locked', blurb: 'Every pupil marked. The teacher has not finalised it.' },
  { key: 'locked', title: 'Done and locked', blurb: 'Finalised. Reopen one from the class if it needs a correction.' },
]

function pileOf(r: AttendanceDayRow): 'todo' | 'unlocked' | 'locked' {
  if (r.state === 'locked') return 'locked'
  if (r.state === 'unlocked') return 'unlocked'
  return 'todo'
}

function rowKey(r: AttendanceDayRow) {
  return `${r.class_id}|${r.section_id ?? ''}`
}

function rowLabel(r: AttendanceDayRow) {
  return r.section_name ? `${r.class_name} · ${r.section_name}` : r.class_name
}

export function AttendanceOverview({ sessionId }: { sessionId: string }) {
  const [date, setDate] = useState(todayISO())
  const [open, setOpen] = useState<AttendanceDayRow | null>(null)

  const day = useQuery({
    queryKey: ['attendanceDay', sessionId, date],
    queryFn: () => attendanceDay(sessionId, date),
  })
  const subjects = useQuery({
    queryKey: ['subjectAttendanceDay', sessionId, date],
    queryFn: () => subjectAttendanceDay(sessionId, date),
  })

  const rows = day.data ?? []
  const counts = {
    todo: rows.filter((r) => pileOf(r) === 'todo').length,
    unlocked: rows.filter((r) => pileOf(r) === 'unlocked').length,
    locked: rows.filter((r) => pileOf(r) === 'locked').length,
  }

  return (
    <div>
      <LoadError of={[day, subjects]} what="The register overview" />

      <div className="flex flex-wrap items-end justify-between gap-3">
        <div>
          <h1 className="text-xl font-semibold text-slate-800">Attendance</h1>
          {/* The date in words as well as in the picker. A head auditing last
              Tuesday needs to be sure which day they are looking at, and
              "2026-09-08" is not a day anybody reads as Tuesday. */}
          <p className="mt-1 text-sm text-slate-500">
            {fmtDate(date)} · {rows.length} class{rows.length === 1 ? '' : 'es'} on the roll
          </p>
        </div>
        <label className="block">
          <span className="text-sm text-slate-600">Day</span>
          <input type="date" value={date} max={todayISO()} className={inputClass}
            onChange={(e) => { setDate(e.target.value); setOpen(null) }} />
        </label>
      </div>

      <div className="mt-4 grid gap-3 sm:grid-cols-3">
        {PILES.map((p) => (
          <div key={p.key}
            className={
              'rounded-xl border px-4 py-3 '
              + (p.key === 'todo' && counts.todo > 0
                ? 'border-amber-200 bg-amber-50'
                : 'border-slate-200 bg-white')
            }>
            <div className="text-2xl font-semibold text-slate-800">{counts[p.key]}</div>
            <div className="text-sm font-medium text-slate-700">{p.title}</div>
            <div className="mt-0.5 text-xs text-slate-500">{p.blurb}</div>
          </div>
        ))}
      </div>

      {day.isLoading && <p className="mt-6 text-sm text-slate-500">Loading…</p>}

      {!day.isLoading && rows.length === 0 && (
        <div className="mt-6">
          <EmptyState
            title="No classes on the roll"
            message="Add classes and enrol pupils, and this screen will show one card for each class every morning."
          />
        </div>
      )}

      {PILES.map((p) => {
        const inPile = rows.filter((r) => pileOf(r) === p.key)
        if (inPile.length === 0) return null
        return (
          <div key={p.key} className="mt-6">
            <div className="text-xs font-semibold uppercase tracking-wide text-slate-500">
              {p.title}
            </div>
            <div className="mt-2 grid gap-2 sm:grid-cols-2 lg:grid-cols-3">
              {inPile.map((r) => (
                <button key={rowKey(r)} onClick={() => setOpen(open && rowKey(open) === rowKey(r) ? null : r)}
                  className={
                    'rounded-lg border bg-white px-3 py-2 text-left hover:ring-1 hover:ring-brand-300 '
                    + (open && rowKey(open) === rowKey(r) ? 'border-brand-400 ring-1 ring-brand-300' : 'border-slate-200')
                  }>
                  <div className="font-medium text-slate-800">{rowLabel(r)}</div>
                  <div className="mt-0.5 text-xs text-slate-500">
                    {r.marked} of {r.pupils} marked
                    {r.state === 'locked' ? ' · locked' : ''}
                  </div>
                </button>
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

      <SubjectPanel rows={subjects.data ?? []} loading={subjects.isLoading} />
    </div>
  )
}

/**
 * The register itself, read only.
 *
 * No marking controls at all, for anybody who reaches this screen. The head
 * reading a class they are worried about is the whole use, and a Save button
 * here would be the thing 0134 removed growing back in a different place.
 */
function ReadOnlyRegister({
  sessionId, row, date, onClose,
}: { sessionId: string; row: AttendanceDayRow; date: string; onClose: () => void }) {
  const roster = useQuery({
    queryKey: ['roster', sessionId, row.class_id, row.section_id ?? 'none', date],
    queryFn: () => getRoster(sessionId, row.class_id, row.section_id, date),
  })
  const rows = roster.data ?? []
  const tally: Record<string, number> = {}
  for (const r of rows) if (r.status) tally[r.status] = (tally[r.status] ?? 0) + 1
  const unmarked = rows.filter((r) => !r.status).length

  return (
    <Card className="mt-6">
      <CardTitle right={
        <button onClick={onClose} className="text-sm font-normal normal-case text-brand-700 hover:underline">
          Close
        </button>
      }>
        {rowLabel(row)} · {fmtDate(date)}
      </CardTitle>
      <LoadError of={[roster]} what="That class's register" />
      <div className="mt-2 flex flex-wrap gap-2">
        {ATTENDANCE_STATUSES.map((s) => (
          <Badge key={s.value} tone={s.value === 'present' ? 'money' : s.value === 'absent' ? 'danger' : 'neutral'}>
            {s.label} {tally[s.value] ?? 0}
          </Badge>
        ))}
        {unmarked > 0 && <Badge tone="due">Not marked {unmarked}</Badge>}
      </div>

      {roster.isLoading && <p className="mt-3 text-sm text-slate-500">Loading…</p>}
      {!roster.isLoading && rows.length > 0 && (
        <div className="mt-3 overflow-x-auto">
          <table className="w-full text-sm">
            <thead className="bg-slate-50 text-left text-xs uppercase tracking-wide text-slate-500">
              <tr>
                <th className="px-3 py-2 w-14">Roll</th>
                <th className="px-3 py-2">Pupil</th>
                <th className="px-3 py-2 w-32">Status</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-slate-100">
              {rows.map((r) => (
                <tr key={r.enrollment_id}>
                  <td className="px-3 py-1.5 text-slate-500">{r.roll_no ?? '-'}</td>
                  <td className="px-3 py-1.5 text-slate-800">{r.full_name}</td>
                  <td className="px-3 py-1.5">
                    {r.status
                      ? (ATTENDANCE_STATUSES.find((s) => s.value === r.status)?.label ?? r.status)
                      : <span className="text-amber-700">Not marked</span>}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </Card>
  )
}

/**
 * Subject attendance, which is a DIFFERENT QUESTION and is presented as one.
 *
 * Only subjects that were actually marked appear. There is no "not done" here
 * and there must not be: nobody is asked to keep this register, so listing
 * every unmarked subject would put forty red rows on this screen every morning
 * and teach the head to stop reading the panel above it as well.
 */
function SubjectPanel({
  rows, loading,
}: { rows: SubjectAttendanceDayRow[]; loading: boolean }) {
  return (
    <div className="mt-8">
      <div className="text-xs font-semibold uppercase tracking-wide text-slate-500">
        Subject attendance
      </div>
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
        <div className="mt-3 overflow-x-auto rounded-lg border border-slate-200 bg-white">
          <table className="w-full text-sm">
            <thead className="bg-slate-50 text-left text-xs uppercase tracking-wide text-slate-500">
              <tr>
                <th className="px-3 py-2">Class</th>
                <th className="px-3 py-2">Subject</th>
                <th className="px-3 py-2">Marked by</th>
                <th className="px-3 py-2 w-20">Present</th>
                <th className="px-3 py-2 w-20">Absent</th>
                <th className="px-3 py-2 w-20">Other</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-slate-100">
              {rows.map((r) => (
                <tr key={`${r.class_id}|${r.section_id ?? ''}|${r.subject_id}`}>
                  <td className="px-3 py-1.5 text-slate-800">
                    {r.section_name ? `${r.class_name} · ${r.section_name}` : r.class_name}
                  </td>
                  <td className="px-3 py-1.5 text-slate-800">{r.subject_name}</td>
                  <td className="px-3 py-1.5 text-slate-600">{r.marked_by_name}</td>
                  <td className="px-3 py-1.5 text-slate-600">{r.present}</td>
                  <td className="px-3 py-1.5 text-slate-600">{r.absent}</td>
                  <td className="px-3 py-1.5 text-slate-600">{r.other}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </div>
  )
}

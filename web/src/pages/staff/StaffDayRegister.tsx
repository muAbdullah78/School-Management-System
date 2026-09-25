import { useState } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import {
  getStaffAttendanceDay, setStaffAttendance, getSchoolSettings, markRestOfStaffPresent,
  type StaffDayRow, type AttendanceStatus,
} from '@/lib/db'
import { fmtDate, todayISO, shiftDate } from '@/lib/format'
import { useAuth } from '@/auth/AuthProvider'
import { canWrite } from '@/auth/roles'
import { ObserverNotice } from '@/components/ObserverNotice'
import { LoadError, Button, inputClass } from '@/components/ui'
import { AskDialog } from '@/components/AskDialog'
import { StackBar, attendanceParts } from '@/components/viz'
import { isMissingFunction } from '@/lib/notInstalled'

const STATUSES: { value: AttendanceStatus; label: string }[] = [
  { value: 'present', label: 'Present' },
  { value: 'late', label: 'Late' },
  { value: 'half_day', label: 'Half day' },
  { value: 'leave', label: 'Leave' },
  { value: 'absent', label: 'Absent' },
]

function hhmm(ts: string | null): string {
  if (!ts) return '-'
  return new Date(ts).toLocaleTimeString('en-GB', {
    hour: '2-digit', minute: '2-digit', timeZone: 'Asia/Karachi',
  })
}

function hours(mins: number | null): string {
  if (mins == null) return '-'
  const h = Math.floor(mins / 60)
  const m = mins % 60
  return h > 0 ? `${h}h ${String(m).padStart(2, '0')}m` : `${m}m`
}

/** The arrival time, only when a scan recorded it. A row the office typed used
 *  to carry the moment it was TYPED as its "In" time, so a day marked from the
 *  office three days later showed the teacher arriving at 14:05. */
function arrived(r: StaffDayRow): string { return r.scanned ? hhmm(r.checked_at) : '-' }

/**
 * The day's staff register.
 *
 * This screen is the reason the check-in mechanism is worth anything. The old
 * loophole (a teacher writing her own row with `source = 'qr'` and no code)
 * survived because NOTHING displayed whether a code had actually been presented.
 * So the "How" column is not decoration: it is the audit.
 */
export function StaffDayRegister() {
  const qc = useQueryClient()
  const today = todayISO()
  const [date, setDate] = useState(today)
  const [editing, setEditing] = useState<StaffDayRow | null>(null)
  const [bulk, setBulk] = useState(false)
  const [flash, setFlash] = useState<string | null>(null)
  const { profile } = useAuth()
  const mayWrite = canWrite(profile?.role)

  const rows = useQuery({ queryKey: ['staffDay', date], queryFn: () => getStaffAttendanceDay(date) })
  const settings = useQuery({ queryKey: ['schoolSettings'], queryFn: getSchoolSettings })

  const all = rows.data ?? []
  const count = (s: string) => all.filter((r) => r.status === s).length
  const notMarked = all.filter((r) => r.status === 'not marked')
  const inToday = count('present') + count('late') + count('half_day')
  const typed = all.filter((r) => r.status !== 'not marked' && !r.scanned)
  const parts = attendanceParts({
    present: count('present'), late: count('late'), half_day: count('half_day'),
    leave: count('leave'), absent: count('absent'), marked: all.length - notMarked.length,
  }, all.length)

  const rest = useMutation({
    mutationFn: () => markRestOfStaffPresent(date),
    onSuccess: (n) => {
      setBulk(false)
      setFlash(n === 1 ? 'One person marked present.' : `${n} people marked present.`)
      qc.invalidateQueries({ queryKey: ['staffDay'] })
    },
  })
  const restMissing = rest.isError && isMissingFunction(rest.error)

  return (
    <div className="space-y-4">
      {!mayWrite && <ObserverNotice what="the staff attendance register" />}
      <LoadError of={[rows]} what="The staff register" />

      {/* ------------------------------------------------------- the day -- */}
      <div className="flex flex-wrap items-center gap-2">
        <Button variant="soft" tone="neutral" aria-label="The day before" onClick={() => setDate(shiftDate(date, -1))}>‹</Button>
        <input type="date" max={today} value={date} aria-label="Date"
          onChange={(e) => e.target.value && setDate(e.target.value > today ? today : e.target.value)}
          className={`${inputClass} w-auto`} />
        <Button variant="soft" tone="neutral" aria-label="The day after" disabled={date >= today}
          onClick={() => setDate(shiftDate(date, 1) > today ? today : shiftDate(date, 1))}>›</Button>
        {date !== today && <Button variant="ghost" onClick={() => setDate(today)}>Today</Button>}
        <span className="text-sm font-medium text-slate-700">{date === today ? 'Today, ' : ''}{fmtDate(date)}</span>
      </div>

      {/* ---------------------------------------------------- the numbers -- */}
      {all.length > 0 && (
        <div className="rounded-2xl border border-slate-200 bg-white p-4 shadow-card">
          <div className="grid grid-cols-2 gap-3 sm:grid-cols-5">
            <DayTile n={inToday} of={all.length} label="In" skin="text-money-700" />
            <DayTile n={count('late') + count('half_day')} label="Late or half day" skin="text-due-700" />
            <DayTile n={count('absent')} label="Absent" skin="text-danger-700" />
            <DayTile n={count('leave')} label="On leave" skin="text-info-700" />
            <DayTile n={notMarked.length} label="Not marked yet" skin="text-slate-500" />
          </div>
          <div className="mt-3">
            <StackBar parts={parts} total={all.length} height={10}
              label={`Staff today: ${parts.map((p) => `${p.label} ${p.value}`).join(', ')}`} />
          </div>
          <div className="mt-3 flex flex-wrap items-center justify-between gap-2">
            <p className="text-xs text-slate-500">
              {typed.length === 0
                ? 'Every mark today came from a check-in scan.'
                : `${typed.length} ${typed.length === 1 ? 'mark was' : 'marks were'} typed by the office, not scanned.`}
            </p>
            {mayWrite && notMarked.length > 0 && (
              <Button size="sm" variant="soft" tone="brand" onClick={() => { rest.reset(); setBulk(true) }}>
                Mark the {notMarked.length} not marked as present
              </Button>
            )}
          </div>
        </div>
      )}

      {flash && (
        <div className="flex items-start justify-between gap-3 rounded-xl border border-brand-200 bg-brand-50 px-4 py-3 text-sm text-brand-800">
          <span>{flash}</span>
          <button onClick={() => setFlash(null)} className="shrink-0 text-brand-700 hover:underline">Dismiss</button>
        </div>
      )}

      {/* With no start time set nothing can ever be late, and a school looking at
          an all-'Present' register deserves to know why rather than assume
          everybody is punctual. */}
      {settings.data && !settings.data.day_starts_at && (
        <p className="rounded-xl border border-slate-200 bg-slate-50 px-3 py-2 text-xs text-slate-600">
          No school start time is set, so nobody is marked late. Set one under
          Settings, Staff check-in, School day.
        </p>
      )}

      {rows.isLoading && <p className="text-sm text-slate-500">Loading…</p>}
      {rows.data?.length === 0 && (
        <p className="rounded-xl border border-dashed border-slate-300 bg-white px-4 py-6 text-center text-sm text-slate-500">
          Nobody is on the staff list yet.
        </p>
      )}

      {/* ------------------------------------------------ phone: cards ---- */}
      {all.length > 0 && (
        <ul className="space-y-2 sm:hidden">
          {all.map((r) => (
            <li key={r.staff_id} className="rounded-2xl border border-slate-200 bg-white p-3 shadow-card">
              <div className="flex items-start justify-between gap-2">
                <div className="min-w-0">
                  <div className={`font-medium ${r.status === 'not marked' ? 'text-slate-500' : 'text-slate-900'}`}>{r.full_name}</div>
                  {r.designation && <div className="text-xs text-slate-500">{r.designation}</div>}
                </div>
                <StatusChip status={r.status} />
              </div>
              {r.status !== 'not marked' && (
                <div className="mt-2 flex flex-wrap gap-x-4 gap-y-1 text-xs text-slate-600">
                  <span>In <b className="tabular-nums">{arrived(r)}</b></span>
                  <span>Out <b className="tabular-nums">{r.scanned ? hhmm(r.checked_out_at) : '-'}</b></span>
                  {r.late_minutes != null && r.late_minutes > 0 && <span className="text-due-800">{r.late_minutes}m late</span>}
                  {r.worked_minutes != null && <span>Worked {hours(r.worked_minutes)}</span>}
                </div>
              )}
              {r.status !== 'not marked' && <How r={r} />}
              {r.reason && <div className="mt-1 text-xs text-slate-500">{r.reason}</div>}
              {mayWrite && (
                <div className="mt-2 border-t border-slate-100 pt-2">
                  <Button size="sm" variant="soft" tone="neutral" onClick={() => setEditing(r)}>
                    {r.status === 'not marked' ? 'Mark' : 'Change'}
                  </Button>
                </div>
              )}
            </li>
          ))}
        </ul>
      )}

      {/* ----------------------------------------------- wider: table ---- */}
      {all.length > 0 && (
        <div className="hidden overflow-x-auto rounded-2xl border border-slate-200 bg-white shadow-card sm:block">
          <table className="w-full text-sm">
            <thead className="bg-slate-50 text-left text-xs uppercase tracking-wide text-slate-500">
              <tr>
                <th className="px-3 py-2">Name</th>
                <th className="px-3 py-2">Status</th>
                <th className="w-20 px-3 py-2">In</th>
                <th className="w-20 px-3 py-2">Out</th>
                <th className="w-20 px-3 py-2">Late</th>
                <th className="w-24 px-3 py-2">Worked</th>
                <th className="px-3 py-2">How</th>
                {mayWrite && <th className="w-20 px-3 py-2"><span className="sr-only">Mark</span></th>}
              </tr>
            </thead>
            <tbody className="divide-y divide-slate-100">
              {all.map((r) => (
                <tr key={r.staff_id} className={r.status === 'not marked' ? 'text-slate-400' : ''}>
                  <td className="px-3 py-2">
                    <span className={r.status === 'not marked' ? '' : 'font-medium text-slate-800'}>{r.full_name}</span>
                    {r.designation && <span className="text-slate-400"> · {r.designation}</span>}
                  </td>
                  <td className="px-3 py-2">
                    <StatusChip status={r.status} />
                    {r.reason && <div className="mt-0.5 text-xs text-slate-500">{r.reason}</div>}
                  </td>
                  <td className="px-3 py-2 tabular-nums text-slate-600">{arrived(r)}</td>
                  <td className="px-3 py-2 tabular-nums text-slate-600">{r.scanned ? hhmm(r.checked_out_at) : '-'}</td>
                  <td className="px-3 py-2 tabular-nums text-slate-600">
                    {r.late_minutes != null && r.late_minutes > 0 ? <span className="text-due-800">{r.late_minutes}m</span> : '-'}
                  </td>
                  <td className="px-3 py-2 tabular-nums text-slate-600">{r.scanned ? hours(r.worked_minutes) : '-'}</td>
                  <td className="px-3 py-2 text-xs">{r.status === 'not marked' ? <span className="text-slate-400">-</span> : <How r={r} />}</td>
                  {mayWrite && (
                    <td className="px-3 py-2 text-right">
                      <Button size="sm" variant="soft" tone="neutral" onClick={() => setEditing(r)}>
                        {r.status === 'not marked' ? 'Mark' : 'Change'}
                      </Button>
                    </td>
                  )}
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}

      {editing && (
        <MarkDialog
          row={editing} date={date}
          onClose={() => setEditing(null)}
          onSaved={() => { qc.invalidateQueries({ queryKey: ['staffDay'] }); setEditing(null) }}
        />
      )}
      {bulk && (
        <AskDialog
          title={`Mark ${notMarked.length} ${notMarked.length === 1 ? 'person' : 'people'} present for ${fmtDate(date)}?`}
          intro={
            <>
              Everybody not marked yet becomes <b>Present</b>, typed by you:{' '}
              {notMarked.slice(0, 6).map((r) => r.full_name).join(', ')}
              {notMarked.length > 6 ? ` and ${notMarked.length - 6} more` : ''}. Anyone already marked, or who
              scanned in, is left exactly as they are. Change any one of them afterwards with its own button.
            </>
          }
          confirmLabel="Mark them present"
          busy={rest.isPending}
          error={rest.isError
            ? restMissing ? 'This needs the latest database update (bundle 49). Mark each person with their own button until then.'
              : (rest.error as Error).message
            : null}
          onCancel={() => setBulk(false)}
          onSubmit={() => rest.mutate()}
        />
      )}
    </div>
  )
}

function DayTile({ n, of, label, skin }: { n: number; of?: number; label: string; skin: string }) {
  return (
    <div>
      <div className={`text-2xl font-semibold tabular-nums ${skin}`}>
        {n}{of != null && <span className="text-sm font-normal text-slate-400"> / {of}</span>}
      </div>
      <div className="text-xs text-slate-600">{label}</div>
    </div>
  )
}

function How({ r }: { r: StaffDayRow }) {
  return (
    <div className="text-xs">
      {r.scanned ? (
        <span className="text-slate-600">
          Scanned{r.code_label ? ` · ${r.code_label}` : ''}
          {r.source === 'manual' && (
            <span className="text-due-800"> · status changed by {r.marked_by_name ?? 'the office'}</span>
          )}
        </span>
      ) : (
        <span className="text-due-800">Typed by {r.marked_by_name ?? 'the office'}</span>
      )}
      {r.device && <div className="max-w-[16rem] truncate text-slate-400">{r.device}</div>}
    </div>
  )
}

const CHIP: Record<string, string> = {
  present: 'bg-money-50 text-money-800 ring-money-200',
  late: 'bg-due-50 text-due-800 ring-due-200',
  half_day: 'bg-due-50 text-due-800 ring-due-200',
  leave: 'bg-info-50 text-info-800 ring-info-200',
  absent: 'bg-danger-50 text-danger-800 ring-danger-200',
  'not marked': 'bg-slate-50 text-slate-500 ring-slate-200',
}
const CHIP_LABEL: Record<string, string> = {
  present: 'Present', late: 'Late', half_day: 'Half day', leave: 'On leave', absent: 'Absent', 'not marked': 'Not marked',
}

function StatusChip({ status }: { status: string }) {
  return (
    <span className={`inline-block shrink-0 rounded-full px-2 py-0.5 text-xs font-medium ring-1 ${CHIP[status] ?? 'bg-slate-50 text-slate-600 ring-slate-200'}`}>
      {CHIP_LABEL[status] ?? status}
    </span>
  )
}

function MarkDialog({
  row, date, onClose, onSaved,
}: {
  row: StaffDayRow; date: string; onClose: () => void; onSaved: () => void
}) {
  const [status, setStatus] = useState<AttendanceStatus>(
    row.status === 'not marked' ? 'present' : (row.status as AttendanceStatus))
  const [reason, setReason] = useState(row.reason ?? '')

  const save = useMutation({
    mutationFn: () => setStaffAttendance(row.staff_id, date, status, reason.trim()),
    onSuccess: onSaved,
  })

  // The database refuses without a reason when the day was recorded by a scan, so
  // the button has to refuse too rather than surfacing that as a database error.
  const overridingAScan = row.scanned
  const needReason = overridingAScan && !reason.trim()

  return (
    <div className="fixed inset-0 z-50 flex items-start justify-center overflow-y-auto bg-slate-900/40 p-4 sm:items-center"
      role="dialog" aria-modal="true" aria-label={`Mark ${row.full_name}`}>
      <div className="w-full max-w-md rounded-2xl bg-white p-5 shadow-pop">
        <h2 className="text-base font-semibold text-slate-800">{row.full_name}</h2>
        <p className="mt-0.5 text-sm text-slate-500">{fmtDate(date)}</p>

        {overridingAScan && (
          <p className="mt-3 rounded-xl border border-due-200 bg-due-50 px-3 py-2 text-xs text-due-900">
            This day was recorded by a check-in at {hhmm(row.checked_at)}. You can change the status: a
            principal who knows somebody left at nine outranks the machine. The reason is required and
            goes in the audit log, and the arrival time is kept.
          </p>
        )}

        <fieldset className="mt-4">
          <legend className="text-sm text-slate-600">Status</legend>
          <div className="mt-1.5 flex flex-wrap gap-1.5">
            {STATUSES.map((s) => {
              const on = s.value === status
              return (
                <button key={s.value} type="button" aria-pressed={on} onClick={() => setStatus(s.value)}
                  className={`rounded-full px-3 py-1.5 text-sm font-medium ring-1 transition ${on ? `${CHIP[s.value]} ring-2` : 'bg-white text-slate-600 ring-slate-300 hover:bg-slate-50'}`}>
                  {s.label}
                </button>
              )
            })}
          </div>
        </fieldset>
        <label className="mt-4 block">
          <span className="text-sm text-slate-600">
            Reason {overridingAScan ? <span className="text-danger-600">(required)</span> : <span className="text-slate-400">(optional)</span>}
          </span>
          <input value={reason} onChange={(e) => setReason(e.target.value)}
            className={`mt-1 ${inputClass}`} placeholder="e.g. left early, confirmed by phone" />
        </label>

        {save.isError && <p className="mt-3 rounded-lg bg-danger-50 px-3 py-2 text-sm text-danger-700">{(save.error as Error).message}</p>}
        <div className="mt-4 flex gap-2">
          <Button className="flex-1" onClick={() => save.mutate()} disabled={save.isPending || needReason}>
            {save.isPending ? 'Saving…' : 'Save'}
          </Button>
          <Button className="flex-1" variant="soft" tone="neutral" onClick={onClose}>Cancel</Button>
        </div>
      </div>
    </div>
  )
}

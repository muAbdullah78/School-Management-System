import { useState } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import {
  getStaffAttendanceDay, setStaffAttendance, getSchoolSettings,
  type StaffDayRow, type AttendanceStatus,
} from '@/lib/db'
import { todayISO } from '@/lib/format'
import { useAuth } from '@/auth/AuthProvider'
import { canWrite } from '@/auth/roles'
import { ObserverNotice } from '@/components/ObserverNotice'

const FIELD = 'rounded border border-slate-300 px-2 py-1 text-sm focus:border-brand-500 focus:outline-none focus:ring-1 focus:ring-brand-500'
const STATUSES: { value: AttendanceStatus; label: string }[] = [
  { value: 'present', label: 'Present' },
  { value: 'late', label: 'Late' },
  { value: 'half_day', label: 'Half day' },
  { value: 'leave', label: 'Leave' },
  { value: 'absent', label: 'Absent' },
]

function hhmm(ts: string | null): string {
  if (!ts) return '—'
  return new Date(ts).toLocaleTimeString('en-GB', {
    hour: '2-digit', minute: '2-digit', timeZone: 'Asia/Karachi',
  })
}

function hours(mins: number | null): string {
  if (mins == null) return '—'
  const h = Math.floor(mins / 60)
  const m = mins % 60
  return h > 0 ? `${h}h ${String(m).padStart(2, '0')}m` : `${m}m`
}

/**
 * The day's staff register.
 *
 * This screen is the reason the check-in mechanism is worth anything. The old
 * loophole — a teacher writing her own row with `source = 'qr'` and no code —
 * survived because NOTHING displayed whether a code had actually been presented.
 * So the "How" column is not decoration: it is the audit.
 */
export function StaffDayRegister() {
  const qc = useQueryClient()
  const [date, setDate] = useState(todayISO())
  const [editing, setEditing] = useState<StaffDayRow | null>(null)
  const { profile } = useAuth()
  const mayWrite = canWrite(profile?.role)

  const rows = useQuery({ queryKey: ['staffDay', date], queryFn: () => getStaffAttendanceDay(date) })
  const settings = useQuery({ queryKey: ['schoolSettings'], queryFn: getSchoolSettings })

  const marked = rows.data?.filter((r) => r.status !== 'not marked') ?? []
  const present = marked.filter((r) => r.status === 'present' || r.status === 'late' || r.status === 'half_day')
  const late = marked.filter((r) => r.status === 'late')
  const typed = marked.filter((r) => !r.scanned)

  return (
    <div>
      {!mayWrite && <ObserverNotice what="the staff attendance register" />}

      <div className="flex flex-wrap items-end gap-3">
        <label className="block">
          <span className="text-sm text-slate-600">Date</span>
          <input type="date" max={todayISO()} value={date} onChange={(e) => setDate(e.target.value)}
            className={`mt-1 block ${FIELD}`} />
        </label>
        <div className="flex flex-wrap gap-2 text-sm">
          <Tile label="On the register" value={`${present.length} of ${rows.data?.length ?? 0}`} />
          <Tile label="Late" value={String(late.length)} />
          <Tile label="Typed, not scanned" value={String(typed.length)} />
        </div>
      </div>

      {/* With no start time set nothing can ever be late, and a school looking at
          an all-'Present' register deserves to know why rather than assume
          everybody is punctual. */}
      {settings.data && !settings.data.day_starts_at && (
        <p className="mt-3 rounded border border-slate-200 bg-slate-50 px-3 py-2 text-xs text-slate-600">
          No school start time is set, so nobody is marked late. Set one under
          Settings → Staff check-in → School day.
        </p>
      )}

      <div className="mt-4 overflow-x-auto rounded-lg border border-slate-200 bg-white">
        <table className="w-full text-sm">
          <thead className="bg-slate-50 text-left text-xs uppercase tracking-wide text-slate-500">
            <tr>
              <th className="px-3 py-2">Name</th>
              <th className="px-3 py-2">Status</th>
              <th className="px-3 py-2 w-20">In</th>
              <th className="px-3 py-2 w-20">Out</th>
              <th className="px-3 py-2 w-20">Late</th>
              <th className="px-3 py-2 w-24">Worked</th>
              <th className="px-3 py-2">How</th>
              {mayWrite && <th className="px-3 py-2 w-16"></th>}
            </tr>
          </thead>
          <tbody className="divide-y divide-slate-100">
            {rows.isLoading && <tr><td colSpan={8} className="px-3 py-3 text-slate-500">Loading…</td></tr>}
            {rows.data?.length === 0 && (
              <tr><td colSpan={8} className="px-3 py-3 text-slate-500">No active staff.</td></tr>
            )}
            {rows.data?.map((r) => (
              <tr key={r.staff_id} className={r.status === 'not marked' ? 'text-slate-400' : ''}>
                <td className="px-3 py-2">
                  <span className={r.status === 'not marked' ? '' : 'font-medium text-slate-800'}>{r.full_name}</span>
                  {r.designation && <span className="text-slate-400"> · {r.designation}</span>}
                </td>
                <td className="px-3 py-2">
                  <StatusChip status={r.status} />
                  {r.reason && <div className="text-xs text-slate-500">{r.reason}</div>}
                </td>
                <td className="px-3 py-2 text-slate-600">{hhmm(r.checked_at)}</td>
                <td className="px-3 py-2 text-slate-600">{hhmm(r.checked_out_at)}</td>
                <td className="px-3 py-2 text-slate-600">
                  {r.late_minutes == null ? '—' : r.late_minutes > 0 ? `${r.late_minutes}m` : '—'}
                </td>
                <td className="px-3 py-2 text-slate-600">{hours(r.worked_minutes)}</td>
                <td className="px-3 py-2 text-xs">
                  {r.status === 'not marked' ? (
                    <span className="text-slate-400">—</span>
                  ) : r.scanned ? (
                    <span className="text-slate-600">
                      Scanned{r.code_label ? ` · ${r.code_label}` : ''}
                      {r.source === 'manual' && (
                        <span className="text-amber-700"> · status changed by {r.marked_by_name ?? 'the office'}</span>
                      )}
                    </span>
                  ) : (
                    <span className="text-amber-700">
                      Typed by {r.marked_by_name ?? 'the office'}
                    </span>
                  )}
                  {r.device && <div className="max-w-[16rem] truncate text-slate-300">{r.device}</div>}
                </td>
                {mayWrite && (
                  <td className="px-3 py-2 text-right">
                    <button onClick={() => setEditing(r)}
                      className="rounded border border-slate-300 px-2 py-0.5 text-xs font-medium text-slate-700 hover:bg-slate-50">
                      Mark
                    </button>
                  </td>
                )}
              </tr>
            ))}
          </tbody>
        </table>
      </div>

      {editing && (
        <MarkDialog
          row={editing} date={date}
          onClose={() => setEditing(null)}
          onSaved={() => { qc.invalidateQueries({ queryKey: ['staffDay'] }); setEditing(null) }}
        />
      )}
    </div>
  )
}

function Tile({ label, value }: { label: string; value: string }) {
  return (
    <div className="rounded border border-slate-200 bg-white px-3 py-1.5">
      <div className="text-[10px] uppercase tracking-wide text-slate-400">{label}</div>
      <div className="font-semibold text-slate-800">{value}</div>
    </div>
  )
}

function StatusChip({ status }: { status: string }) {
  const map: Record<string, string> = {
    present: 'bg-emerald-100 text-emerald-800',
    late: 'bg-amber-100 text-amber-800',
    half_day: 'bg-amber-100 text-amber-800',
    leave: 'bg-sky-100 text-sky-800',
    absent: 'bg-red-100 text-red-800',
    'not marked': 'bg-slate-100 text-slate-500',
  }
  const label = status === 'half_day' ? 'half day' : status
  return (
    <span className={`rounded px-1.5 py-0.5 text-xs font-medium capitalize ${map[status] ?? 'bg-slate-100 text-slate-600'}`}>
      {label}
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
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/40 p-4">
      <div className="w-full max-w-md rounded-lg bg-white p-5 shadow-lg">
        <h2 className="text-base font-semibold text-slate-800">{row.full_name}</h2>
        <p className="mt-0.5 text-sm text-slate-500">{date}</p>

        {overridingAScan && (
          <p className="mt-2 rounded border border-amber-300 bg-amber-50 px-3 py-2 text-xs text-amber-900">
            This day was recorded by a check-in at {hhmm(row.checked_at)}. You can change the status — a
            principal who knows somebody left at nine outranks the machine — but the reason is required and
            goes in the audit log. The arrival time itself is kept.
          </p>
        )}

        <label className="mt-3 block">
          <span className="text-sm text-slate-600">Status</span>
          <select value={status} onChange={(e) => setStatus(e.target.value as AttendanceStatus)}
            className={`mt-1 w-full ${FIELD}`}>
            {STATUSES.map((s) => <option key={s.value} value={s.value}>{s.label}</option>)}
          </select>
        </label>
        <label className="mt-3 block">
          <span className="text-sm text-slate-600">
            Reason {overridingAScan ? <span className="text-red-500">*</span> : <span className="text-slate-400">(optional)</span>}
          </span>
          <input autoFocus value={reason} onChange={(e) => setReason(e.target.value)}
            className={`mt-1 w-full ${FIELD}`} placeholder="e.g. left early, confirmed by phone" />
        </label>

        {save.isError && <p className="mt-2 text-sm text-red-600">{(save.error as Error).message}</p>}
        <div className="mt-4 flex gap-2">
          <button onClick={() => save.mutate()} disabled={save.isPending || needReason}
            className="flex-1 rounded bg-brand-600 px-3 py-2 text-sm font-medium text-white hover:bg-brand-700 disabled:opacity-60">
            {save.isPending ? 'Saving…' : 'Save'}
          </button>
          <button onClick={onClose} className="flex-1 rounded border border-slate-300 px-3 py-2 text-sm hover:bg-slate-50">
            Cancel
          </button>
        </div>
      </div>
    </div>
  )
}

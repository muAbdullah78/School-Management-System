import { useState } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useNavigate } from 'react-router-dom'
import {
  getMyAssignments, getMyTodayCheckin, getMyStaffAttendance, staffCheckIn,
  type MyAttendanceRow,
} from '@/lib/db'
import { useAuth } from '@/auth/AuthProvider'
import { LoadError } from '@/components/ui'
import { fmtDate } from '@/lib/format'

/** The teacher's home: their assigned class(es), a fast path to mark attendance
 *  and open their tests, today's own check-in, and their attendance record. */
export function MyClass() {
  const { profile } = useAuth()
  const navigate = useNavigate()
  const assignments = useQuery({ queryKey: ['myAssignments'], queryFn: getMyAssignments })
  const checkin = useQuery({ queryKey: ['myTodayCheckin'], queryFn: getMyTodayCheckin })

  const linked = !!profile?.staff_id

  return (
    <div className="space-y-5">
      <div>
        <h1 className="text-xl font-semibold text-slate-800">Welcome{profile?.full_name ? `, ${profile.full_name}` : ''}</h1>
        <p className="mt-0.5 text-sm text-slate-500">Your classes for the current session.</p>
      </div>

      <LoadError of={[assignments, checkin]} what="Your home screen" />

      {/* Check-in status + the two ways in: scan the wall QR, or type today's code. */}
      <div className="rounded-lg bg-white p-4 shadow-sm ring-1 ring-slate-200">
        <div className="text-xs uppercase tracking-wide text-slate-500">Today’s check-in</div>
        {!linked ? (
          <p className="mt-1 text-sm text-amber-600">Your login isn’t linked to a staff record yet: ask the principal to link it in Staff.</p>
        ) : checkin.isLoading ? (
          <p className="mt-1 text-sm text-slate-400">…</p>
        ) : checkin.data ? (
          <p className="mt-1 text-sm text-emerald-700">
            ✓ Checked in{checkin.data.checked_at ? ` at ${new Date(checkin.data.checked_at).toLocaleTimeString('en-PK', { hour: '2-digit', minute: '2-digit' })}` : ''} · {fmtDate(checkin.data.attendance_date)}
          </p>
        ) : (
          <CheckInBox />
        )}
      </div>

      {/* The teacher's own attendance record. Nothing in the portal showed this
          before: a teacher could not see their own present/absent history, only
          today's tick. */}
      {linked && <MyAttendance />}

      {/* Assigned classes */}
      <div>
        <div className="text-xs uppercase tracking-wide text-slate-500">My classes</div>
        {assignments.isLoading ? (
          <p className="mt-2 text-sm text-slate-400">Loading…</p>
        ) : (assignments.data?.length ?? 0) === 0 ? (
          <p className="mt-2 rounded bg-slate-50 p-3 text-sm text-slate-500">
            You have no class assigned yet. The principal assigns your class in Staff → Class teachers.
          </p>
        ) : (
          <div className="mt-2 grid gap-3 sm:grid-cols-2">
            {assignments.data?.map((a) => (
              <div key={`${a.class_id}-${a.section_id ?? 'all'}`} className="rounded-lg bg-white p-4 shadow-sm ring-1 ring-slate-200">
                <div className="text-base font-semibold text-slate-800">
                  {a.class_name}{a.section_name ? ` · Section ${a.section_name}` : ''}
                </div>
                <div className="mt-3 flex flex-wrap gap-2">
                  <button onClick={() => navigate('/attendance')}
                    className="rounded bg-brand-600 px-3 py-1.5 text-sm font-medium text-white hover:bg-brand-700">Mark attendance</button>
                  <button onClick={() => navigate('/assessments')}
                    className="rounded border border-slate-300 px-3 py-1.5 text-sm font-medium text-slate-700 hover:bg-slate-50">Tests</button>
                </div>
              </div>
            ))}
          </div>
        )}
      </div>
    </div>
  )
}

/**
 * Mark myself present by typing today's code, when scanning is not an option.
 *
 * The wall QR opens /checkin?c=CODE and submits automatically; this is the
 * fallback for a camera that will not focus, or a school that reads the poster
 * code out. Location is sent best-effort, exactly as the QR path does, so a
 * school using the geofence gets the same check either way. A ROTATING code
 * cannot be typed (it is a token that changes every 30 seconds) and the server
 * says so plainly, so this box is honest about being for the static code.
 */
function CheckInBox() {
  const qc = useQueryClient()
  const [code, setCode] = useState('')
  const [msg, setMsg] = useState<string | null>(null)
  const [err, setErr] = useState<string | null>(null)

  async function coords(): Promise<{ lat: number | null; lng: number | null }> {
    if (typeof navigator === 'undefined' || !navigator.geolocation) return { lat: null, lng: null }
    return new Promise((resolve) => {
      navigator.geolocation.getCurrentPosition(
        (p) => resolve({ lat: p.coords.latitude, lng: p.coords.longitude }),
        () => resolve({ lat: null, lng: null }),
        { enableHighAccuracy: true, timeout: 8000, maximumAge: 60000 },
      )
    })
  }

  const go = useMutation({
    mutationFn: async () => {
      const { lat, lng } = await coords()
      const device = typeof navigator !== 'undefined' ? navigator.userAgent.slice(0, 120) : null
      return staffCheckIn(code.trim(), lat, lng, device)
    },
    onSuccess: (r) => {
      // staffCheckIn throws on a refusal, so anything that resolves is a real
      // record: a check-in, a second-scan check-out, or an already-marked day.
      setErr(null)
      setMsg(
        r.status === 'out' ? 'Checked out.'
          : r.status === 'already' ? 'You were already checked in today.'
            : r.status === 'office_marked' ? 'The office already marked you present today.'
              : 'Checked in.')
      void qc.invalidateQueries({ queryKey: ['myTodayCheckin'] })
      void qc.invalidateQueries({ queryKey: ['myAttendance'] })
    },
    onError: (e) => setErr((e as Error).message),
  })

  return (
    <div className="mt-1">
      <p className="text-sm text-slate-600">
        Not checked in yet. Scan the school’s check-in QR with your phone camera, or type
        today’s code:
      </p>
      <form className="mt-2 flex flex-wrap items-center gap-2"
        onSubmit={(e) => { e.preventDefault(); if (code.trim()) go.mutate() }}>
        <input value={code} onChange={(e) => { setCode(e.target.value); setErr(null); setMsg(null) }}
          placeholder="Today’s code"
          className="w-40 rounded border border-slate-300 px-3 py-2 text-sm focus:border-brand-500 focus:outline-none focus:ring-1 focus:ring-brand-500" />
        <button type="submit" disabled={!code.trim() || go.isPending}
          className="rounded bg-brand-600 px-3 py-2 text-sm font-medium text-white hover:bg-brand-700 disabled:opacity-60">
          {go.isPending ? 'Checking in…' : 'Check in'}
        </button>
      </form>
      {msg && <p className="mt-1 text-sm text-emerald-700">{msg}</p>}
      {err && <p className="mt-1 text-sm text-red-600">{err}</p>}
    </div>
  )
}

const STATUS_STYLE: Record<string, string> = {
  present: 'text-emerald-700',
  late: 'text-amber-700',
  absent: 'text-red-600',
  leave: 'text-slate-500',
}

function hhmm(iso: string | null): string {
  if (!iso) return '-'
  return new Date(iso).toLocaleTimeString('en-PK', { hour: '2-digit', minute: '2-digit' })
}

/** The teacher's own month of attendance, newest first. */
function MyAttendance() {
  // First of a month, in local terms; shifted by the arrows.
  const [anchor, setAnchor] = useState(() => {
    const d = new Date()
    return new Date(d.getFullYear(), d.getMonth(), 1)
  })
  const monthIso = `${anchor.getFullYear()}-${String(anchor.getMonth() + 1).padStart(2, '0')}-01`
  const q = useQuery({
    queryKey: ['myAttendance', monthIso],
    queryFn: () => getMyStaffAttendance(monthIso),
  })
  const rows = q.data ?? []
  const present = rows.filter((r) => r.status === 'present' || r.status === 'late').length
  const label = anchor.toLocaleDateString('en-GB', { month: 'long', year: 'numeric' })
  const thisMonth = new Date().getFullYear() === anchor.getFullYear()
    && new Date().getMonth() === anchor.getMonth()

  const shift = (n: number) => setAnchor((a) => new Date(a.getFullYear(), a.getMonth() + n, 1))

  return (
    <div className="rounded-lg bg-white p-4 shadow-sm ring-1 ring-slate-200">
      <div className="flex flex-wrap items-center justify-between gap-2">
        <div className="text-xs uppercase tracking-wide text-slate-500">My attendance</div>
        <div className="flex items-center gap-2 text-sm">
          <button onClick={() => shift(-1)} className="rounded border border-slate-300 px-2 py-0.5 text-slate-600 hover:bg-slate-50">‹</button>
          <span className="min-w-[7.5rem] text-center font-medium text-slate-700">{label}</span>
          <button onClick={() => shift(1)} disabled={thisMonth}
            className="rounded border border-slate-300 px-2 py-0.5 text-slate-600 hover:bg-slate-50 disabled:opacity-40">›</button>
        </div>
      </div>

      {q.isLoading ? (
        <p className="mt-2 text-sm text-slate-400">…</p>
      ) : rows.length === 0 ? (
        <p className="mt-2 text-sm text-slate-500">No attendance recorded this month yet.</p>
      ) : (
        <>
          <div className="mt-1 text-sm text-slate-600">{present} day{present === 1 ? '' : 's'} present this month.</div>
          <div className="mt-2 overflow-x-auto">
            <table className="w-full text-sm">
              <thead className="text-left text-xs uppercase tracking-wide text-slate-400">
                <tr><th className="py-1">Date</th><th className="py-1">Status</th><th className="py-1">In</th><th className="py-1">Out</th></tr>
              </thead>
              <tbody className="divide-y divide-slate-100">
                {rows.map((r: MyAttendanceRow) => (
                  <tr key={r.attendance_date}>
                    <td className="py-1.5 text-slate-700">{fmtDate(r.attendance_date)}</td>
                    <td className={`py-1.5 font-medium capitalize ${STATUS_STYLE[r.status] ?? 'text-slate-600'}`}>{r.status}</td>
                    <td className="py-1.5 tabular-nums text-slate-600">{hhmm(r.checked_at)}</td>
                    <td className="py-1.5 tabular-nums text-slate-600">{hhmm(r.checked_out_at)}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </>
      )}
    </div>
  )
}

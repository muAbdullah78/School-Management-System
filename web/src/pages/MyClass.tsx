import { useQuery } from '@tanstack/react-query'
import { useNavigate } from 'react-router-dom'
import { getMyAssignments, getMyTodayCheckin } from '@/lib/db'
import { useAuth } from '@/auth/AuthProvider'
import { fmtDate } from '@/lib/format'

/** The teacher's home: their assigned class(es), a fast path to mark attendance
 *  and open their tests, and today's own check-in status. */
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

      {/* Check-in status */}
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
          <p className="mt-1 text-sm text-slate-600">Not checked in yet. Scan the school’s check-in QR with your phone camera to mark your attendance.</p>
        )}
      </div>

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

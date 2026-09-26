import { useEffect, useState } from 'react'
import { useQuery, useQueryClient } from '@tanstack/react-query'
import { useNavigate } from 'react-router-dom'
import {
  getMyAssignments, getMyCheckin, getMyStaffDays, pkToday,
  type CheckInResult, type MyAttendanceRow, type MyCheckin,
} from '@/lib/db'
import { useAuth } from '@/auth/AuthProvider'
import { LoadError } from '@/components/ui'
import { useTableChanges } from '@/lib/live'
import { shiftDate } from '@/lib/format'
import { CheckInPanel } from '@/components/checkin/CheckInPanel'
import { STATUS_WORD, hoursWorked, pkTime, resultHeadline } from '@/components/checkin/checkinKit'

/** The teacher's home: today's own check-in first, then their week and month,
 *  then their classes with the fast path to the register and their tests. */
export function MyClass() {
  const { profile } = useAuth()
  const navigate = useNavigate()
  const qc = useQueryClient()
  const assignments = useQuery({ queryKey: ['myAssignments'], queryFn: getMyAssignments })
  // Polled as well as live: the office marking a teacher from their desk has to
  // reach the teacher's phone without the teacher knowing to reload.
  const me = useQuery({ queryKey: ['myCheckin'], queryFn: getMyCheckin, refetchInterval: 60_000 })
  const staffId = profile?.staff_id ?? null
  useTableChanges('staff_attendance', staffId ? `staff_id=eq.${staffId}` : null, () => {
    void qc.invalidateQueries({ queryKey: ['myCheckin'] })
    void qc.invalidateQueries({ queryKey: ['myDays'] })
  }, !!staffId)

  const linked = me.data ? me.data.linked : !!staffId

  return (
    <div className="space-y-5">
      <div>
        <h1 className="text-xl font-semibold text-slate-800">Welcome{profile?.full_name ? `, ${profile.full_name}` : ''}</h1>
        <p className="mt-0.5 text-sm text-slate-500">Your day, your attendance, and your classes.</p>
      </div>

      <LoadError of={[assignments]} what="Your classes" />

      <TodayCard me={me.data} loading={me.isLoading} error={me.error as Error | null}
        onRetry={() => void me.refetch()} />

      {linked && <MyDays />}

      <div>
        <div className="text-xs font-semibold uppercase tracking-wide text-slate-500">My classes</div>
        {assignments.isLoading ? (
          <p className="mt-2 text-sm text-slate-400">Loading…</p>
        ) : (assignments.data?.length ?? 0) === 0 ? (
          <p className="mt-2 rounded-xl bg-slate-50 p-3 text-sm text-slate-500">
            You have no class assigned yet. The principal assigns your class in Staff, Class teachers.
          </p>
        ) : (
          <div className="mt-2 grid gap-3 sm:grid-cols-2">
            {assignments.data?.map((a) => (
              <div key={`${a.class_id}-${a.section_id ?? 'all'}`} className="rounded-2xl bg-white p-4 shadow-card ring-1 ring-slate-200">
                <div className="text-base font-semibold text-slate-800">
                  {a.class_name}{a.section_name ? ` · Section ${a.section_name}` : ''}
                </div>
                <div className="mt-3 grid grid-cols-2 gap-2">
                  <button onClick={() => navigate('/attendance')}
                    className="rounded-xl bg-brand-600 px-3 py-2.5 text-sm font-medium text-white hover:bg-brand-700">Mark attendance</button>
                  <button onClick={() => navigate('/assessments')}
                    className="rounded-xl border border-slate-300 px-3 py-2.5 text-sm font-medium text-slate-700 hover:bg-slate-50">Tests</button>
                </div>
              </div>
            ))}
          </div>
        )}
      </div>
    </div>
  )
}

/** The time now, refreshed every half minute, so "check-out opens at 08:07"
 *  turns into a button by itself. */
function useNow(stepMs = 30_000): number {
  const [now, setNow] = useState(() => Date.now())
  useEffect(() => {
    const t = window.setInterval(() => setNow(Date.now()), stepMs)
    return () => window.clearInterval(t)
  }, [stepMs])
  return now
}

const CARD = 'rounded-2xl bg-white p-4 shadow-card ring-1 ring-slate-200'

function TodayCard({ me, loading, error, onRetry }: {
  me: MyCheckin | undefined; loading: boolean; error: Error | null; onRetry: () => void
}) {
  const qc = useQueryClient()
  const now = useNow()
  const [panel, setPanel] = useState<'in' | 'out' | null>(null)
  const [outcome, setOutcome] = useState<CheckInResult | null>(null)

  function done(r: CheckInResult) {
    setOutcome(r)
    setPanel(null)
    void qc.invalidateQueries({ queryKey: ['myCheckin'] })
    void qc.invalidateQueries({ queryKey: ['myDays'] })
  }

  const head = <div className="text-xs font-semibold uppercase tracking-wide text-slate-500">Today’s check-in</div>

  if (loading) {
    return <div className={CARD}>{head}<div className="mt-3 h-16 animate-pulse rounded-xl bg-slate-100" /></div>
  }
  if (error || !me) {
    return (
      <div className={CARD}>
        {head}
        <p className="mt-2 text-sm text-danger-700">Your check-in could not be loaded. {error?.message}</p>
        <button onClick={onRetry} className="mt-2 text-sm font-medium text-brand-700 hover:underline">Try again</button>
      </div>
    )
  }
  if (!me.linked) {
    return (
      <div className={CARD}>
        {head}
        <p className="mt-2 text-sm text-due-800">
          Your login is not linked to a staff record yet, so you cannot check in. Ask the principal to link it
          in Staff, on your name, with the Login button.
        </p>
      </div>
    )
  }
  if (!me.active) {
    return (
      <div className={CARD}>
        {head}
        <p className="mt-2 text-sm text-slate-700">Your staff record is marked as left, so check-in is closed. Speak to the office if that is wrong.</p>
      </div>
    )
  }

  const rec = me.record
  const officeTyped = !!rec && !rec.scanned
  const outOpens = me.out_opens_at ? new Date(me.out_opens_at).getTime() : null
  const outReady = me.can_check_out && (outOpens == null || now >= outOpens)

  return (
    <div className={CARD}>
      <div className="flex items-start justify-between gap-2">
        {head}
        <span className="text-xs text-slate-400">{new Date(`${me.today}T00:00:00`).toLocaleDateString('en-GB', { weekday: 'short', day: 'numeric', month: 'short' })}</span>
      </div>

      {outcome && <Outcome r={outcome} onClose={() => setOutcome(null)} />}

      {/* ---- recorded already ------------------------------------------ */}
      {rec && (
        <div className="mt-3">
          <div className="flex flex-wrap items-center gap-2">
            <DayChip status={rec.status} />
            {officeTyped && <span className="text-sm text-slate-600">marked by the office</span>}
            {!officeTyped && rec.method && (
              <span className="text-xs text-slate-500">{rec.method === 'pin' ? 'with the PIN' : 'by QR'}</span>
            )}
          </div>
          {!officeTyped && (
            <dl className="mt-3 grid grid-cols-3 gap-2 text-center">
              <Fact k="In" v={pkTime(rec.checked_at)} />
              <Fact k="Out" v={rec.checked_out_at ? pkTime(rec.checked_out_at) : 'Not yet'} />
              <Fact k="At school" v={rec.worked_minutes != null ? hoursWorked(rec.worked_minutes) : '-'} />
            </dl>
          )}
          {rec.late_minutes != null && rec.late_minutes > 0 && (
            <p className="mt-2 text-xs text-due-800">{rec.late_minutes} minutes after the start of the day.</p>
          )}
          {rec.reason && <p className="mt-2 text-xs text-slate-600">Note from the office: {rec.reason}</p>}

          {/* The check-out, when the database would take one. */}
          {me.can_check_out && panel !== 'out' && (
            <div className="mt-3 border-t border-slate-100 pt-3">
              {outReady ? (
                <button onClick={() => { setOutcome(null); setPanel('out') }}
                  className="w-full rounded-xl bg-brand-600 px-4 py-3 text-sm font-semibold text-white hover:bg-brand-700 sm:w-auto">
                  {rec.checked_out_at ? 'Check out again (moves your leaving time)' : 'Check out'}
                </button>
              ) : (
                <p className="text-sm text-slate-500">Check-out opens at {pkTime(me.out_opens_at)}, so a double scan on arrival does not check you out.</p>
              )}
            </div>
          )}
          {officeTyped && (
            <p className="mt-2 text-xs text-slate-500">The office recorded today, so there is nothing to scan. Speak to them if it is wrong.</p>
          )}
        </div>
      )}

      {/* ---- nothing recorded yet ------------------------------------- */}
      {!rec && me.full && me.mode === null && (
        <p className="mt-3 text-sm text-slate-600">
          Your school has not switched on self check-in, so the office marks your attendance. You will see it
          here once they do.
        </p>
      )}
      {!rec && (me.mode !== null || !me.full) && (
        <div className="mt-3">
          <p className="mb-3 text-sm text-slate-700">You have not checked in today.</p>
          <CheckInPanel intent="in" mode={me.mode} geofence={me.geofence} known={me.full} onResult={done} />
        </div>
      )}

      {rec && panel === 'out' && (
        <div className="mt-3 border-t border-slate-100 pt-3">
          <div className="mb-3 flex items-center justify-between">
            <p className="text-sm font-medium text-slate-800">Check out</p>
            <button onClick={() => setPanel(null)} className="text-sm text-slate-500 hover:underline">Cancel</button>
          </div>
          <CheckInPanel intent="out" mode={me.mode} geofence={me.geofence} known={me.full} onResult={done} />
        </div>
      )}
    </div>
  )
}

function Fact({ k, v }: { k: string; v: string }) {
  return (
    <div className="rounded-xl bg-slate-50 px-2 py-2">
      <dt className="text-[11px] uppercase tracking-wide text-slate-500">{k}</dt>
      <dd className="mt-0.5 text-base font-semibold tabular-nums text-slate-900">{v}</dd>
    </div>
  )
}

function Outcome({ r, onClose }: { r: CheckInResult; onClose: () => void }) {
  const good = r.status === 'ok' || r.status === 'out'
  const skin = r.status === 'office_marked' || r.status === 'already'
    ? 'bg-info-50 text-info-900 ring-info-100'
    : r.attendance_status === 'late' && r.status === 'ok'
      ? 'bg-due-50 text-due-900 ring-due-100'
      : 'bg-money-50 text-money-900 ring-money-100'
  return (
    <div role="status" className={`mt-3 flex items-start justify-between gap-3 rounded-xl px-3 py-2 text-sm ring-1 ${skin}`}>
      <div>
        <p className="font-medium">{resultHeadline(r)}</p>
        {good && r.status === 'out' && r.worked_minutes != null && (
          <p className="text-xs opacity-90">{hoursWorked(r.worked_minutes)} at school today.</p>
        )}
        {r.status === 'office_marked' && (
          <p className="text-xs opacity-90">
            Recorded as {STATUS_WORD[r.attendance_status ?? ''] ?? r.attendance_status}{r.reason ? `: ${r.reason}` : ''}.
          </p>
        )}
      </div>
      <button onClick={onClose} className="shrink-0 text-xs underline opacity-80">Close</button>
    </div>
  )
}

// ---------------------------------------------------------------------------
// The teacher's own days
// ---------------------------------------------------------------------------

/** One colour and one letter per kind of day. The letter is there so the
 *  record is not colour alone, for a colour-blind teacher and for a printout. */
const DAY_SKIN: Record<string, { cell: string; letter: string; label: string }> = {
  present: { cell: 'bg-money-500 text-white', letter: 'P', label: 'Present' },
  late: { cell: 'bg-due-400 text-slate-900', letter: 'L', label: 'Late' },
  half_day: { cell: 'bg-due-200 text-due-900', letter: 'H', label: 'Half day' },
  leave: { cell: 'bg-info-200 text-info-900', letter: 'Lv', label: 'Leave' },
  absent: { cell: 'bg-danger-500 text-white', letter: 'A', label: 'Absent' },
}
const NONE = { cell: 'border border-dashed border-slate-300 bg-white text-slate-400', letter: '-', label: 'Not recorded' }

function DayChip({ status }: { status: string }) {
  const s = DAY_SKIN[status]
  return (
    <span className={`inline-flex items-center gap-1.5 rounded-full px-2.5 py-1 text-sm font-semibold ${s ? s.cell : 'bg-slate-100 text-slate-700'}`}>
      {s?.label ?? status}
    </span>
  )
}

function monthBounds(ym: string, today: string): { from: string; to: string; last: string } {
  const [y, m] = ym.split('-').map(Number)
  const lastDay = new Date(Date.UTC(y, m, 0)).getUTCDate()
  const last = `${ym}-${String(lastDay).padStart(2, '0')}`
  return { from: `${ym}-01`, to: last < today ? last : today, last }
}

function weekdayOf(iso: string): number {
  const [y, m, d] = iso.split('-').map(Number)
  return new Date(Date.UTC(y, m - 1, d)).getUTCDay() // 0 Sunday
}

function MyDays() {
  const today = pkToday()
  const weekFrom = shiftDate(today, -6)
  const week = useQuery({
    queryKey: ['myDays', weekFrom, today], queryFn: () => getMyStaffDays(weekFrom, today),
  })
  const [ym, setYm] = useState(today.slice(0, 7))
  const mb = monthBounds(ym, today)
  const month = useQuery({
    queryKey: ['myDays', mb.from, mb.to], queryFn: () => getMyStaffDays(mb.from, mb.to),
    enabled: mb.from <= today,
  })
  const [picked, setPicked] = useState<string | null>(null)

  const byDate = (rows: MyAttendanceRow[] | undefined) => new Map((rows ?? []).map((r) => [r.attendance_date, r]))
  const wk = byDate(week.data)
  const mo = byDate(month.data)
  const days7 = Array.from({ length: 7 }, (_, i) => shiftDate(weekFrom, i))

  const tally = (rows: MyAttendanceRow[]) => ({
    in: rows.filter((r) => r.status === 'present' || r.status === 'late' || r.status === 'half_day').length,
    late: rows.filter((r) => r.status === 'late').length,
    absent: rows.filter((r) => r.status === 'absent').length,
    leave: rows.filter((r) => r.status === 'leave').length,
  })
  const w = tally(week.data ?? [])
  const m = tally(month.data ?? [])
  const shift = (n: number) => {
    const [y, mm] = ym.split('-').map(Number)
    const d = new Date(Date.UTC(y, mm - 1 + n, 1))
    setYm(`${d.getUTCFullYear()}-${String(d.getUTCMonth() + 1).padStart(2, '0')}`)
    setPicked(null)
  }
  const monthLabel = new Date(`${ym}-01T00:00:00`).toLocaleDateString('en-GB', { month: 'long', year: 'numeric' })
  const thisMonth = ym === today.slice(0, 7)

  // Mondays first, as a Pakistani school week runs.
  const lead = (weekdayOf(`${ym}-01`) + 6) % 7
  const nDays = Number(mb.last.slice(8, 10))
  const cells: (string | null)[] = [
    ...Array.from({ length: lead }, () => null),
    ...Array.from({ length: nDays }, (_, i) => `${ym}-${String(i + 1).padStart(2, '0')}`),
  ]
  const pickedRow = picked ? mo.get(picked) ?? null : null

  return (
    <div className={CARD}>
      <div className="text-xs font-semibold uppercase tracking-wide text-slate-500">My attendance</div>

      {/* ---- the last seven days ------------------------------------- */}
      <div className="mt-3">
        <div className="flex flex-col gap-0.5 sm:flex-row sm:items-baseline sm:justify-between sm:gap-2">
          <p className="text-sm font-medium text-slate-800">The last 7 days</p>
          {week.data && (
            <p className="text-xs text-slate-500">
              {w.in} in{w.late ? ` · ${w.late} late` : ''}{w.absent ? ` · ${w.absent} absent` : ''}{w.leave ? ` · ${w.leave} leave` : ''}
            </p>
          )}
        </div>
        {week.error ? (
          <Failed onRetry={() => void week.refetch()} />
        ) : (
          <ol className="mt-2 grid grid-cols-7 gap-1.5">
            {days7.map((d) => {
              const r = wk.get(d)
              const s = r ? DAY_SKIN[r.status] ?? NONE : NONE
              const isToday = d === today
              return (
                <li key={d} className="text-center">
                  <div className={`text-[11px] ${isToday ? 'font-semibold text-brand-700' : 'text-slate-500'}`}>
                    {isToday ? 'Today' : new Date(`${d}T00:00:00`).toLocaleDateString('en-GB', { weekday: 'short' })}
                  </div>
                  <div title={`${d}: ${s.label}`} aria-label={`${d}: ${s.label}`}
                    className={`mt-1 flex h-11 items-center justify-center rounded-xl text-sm font-bold ${week.isLoading ? 'animate-pulse bg-slate-100 text-transparent' : s.cell}`}>
                    {week.isLoading ? '' : s.letter}
                  </div>
                  <div className="mt-0.5 text-[11px] tabular-nums text-slate-400">{Number(d.slice(8, 10))}</div>
                </li>
              )
            })}
          </ol>
        )}
        {week.data && week.data.length === 0 && (
          <p className="mt-2 text-xs text-slate-500">Nothing recorded in the last seven days. A day appears here the moment you check in or the office marks you.</p>
        )}
      </div>

      {/* ---- the month ---------------------------------------------- */}
      <div className="mt-5 border-t border-slate-100 pt-4">
        <div className="flex items-center justify-between gap-2">
          <button onClick={() => shift(-1)} aria-label="The month before"
            className="flex h-9 w-9 items-center justify-center rounded-lg border border-slate-300 text-slate-600 hover:bg-slate-50">‹</button>
          <p className="text-sm font-semibold text-slate-800">{monthLabel}</p>
          <button onClick={() => shift(1)} disabled={thisMonth} aria-label="The month after"
            className="flex h-9 w-9 items-center justify-center rounded-lg border border-slate-300 text-slate-600 hover:bg-slate-50 disabled:opacity-40">›</button>
        </div>

        {month.error ? (
          <Failed onRetry={() => void month.refetch()} />
        ) : (
          <>
            <div className="mt-3 grid grid-cols-4 gap-2 text-center">
              <Count n={m.in} label="Days in" skin="text-money-700" />
              <Count n={m.late} label="Late" skin="text-due-700" />
              <Count n={m.absent} label="Absent" skin="text-danger-700" />
              <Count n={m.leave} label="Leave" skin="text-info-700" />
            </div>

            <div className="mt-3 grid grid-cols-7 gap-1 text-center text-[11px] text-slate-400">
              {['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'].map((d) => <div key={d}>{d}</div>)}
            </div>
            <div className="mt-1 grid grid-cols-7 gap-1">
              {cells.map((d, i) => {
                if (!d) return <div key={`b${i}`} />
                const future = d > today
                const r = mo.get(d)
                const s = r ? DAY_SKIN[r.status] ?? NONE : NONE
                const on = picked === d
                return (
                  <button key={d} type="button" disabled={future} onClick={() => setPicked(on ? null : d)}
                    aria-label={`${d}: ${future ? 'not yet' : s.label}`} aria-pressed={on}
                    className={`flex aspect-square flex-col items-center justify-center rounded-lg text-xs tabular-nums transition ${
                      future ? 'text-slate-300' : month.isLoading ? 'animate-pulse bg-slate-100 text-transparent' : s.cell} ${
                      on ? 'ring-2 ring-brand-600 ring-offset-1' : ''}`}>
                    <span className="font-semibold">{Number(d.slice(8, 10))}</span>
                  </button>
                )
              })}
            </div>

            {picked && (
              <div className="mt-3 rounded-xl bg-slate-50 px-3 py-2 text-sm text-slate-700">
                <span className="font-medium">
                  {new Date(`${picked}T00:00:00`).toLocaleDateString('en-GB', { weekday: 'long', day: 'numeric', month: 'long' })}:
                </span>{' '}
                {pickedRow ? (
                  <>
                    {DAY_SKIN[pickedRow.status]?.label ?? pickedRow.status}
                    {pickedRow.checked_at && pickedRow.method && `, in ${pkTime(pickedRow.checked_at)}`}
                    {pickedRow.checked_out_at && `, out ${pkTime(pickedRow.checked_out_at)}`}
                    {pickedRow.worked_minutes != null && ` (${hoursWorked(pickedRow.worked_minutes)})`}
                    {pickedRow.method === 'pin' ? ', with the PIN' : pickedRow.method === 'qr' ? ', by QR' : ', marked by the office'}
                    {pickedRow.reason && <span className="block text-xs text-slate-500">{pickedRow.reason}</span>}
                  </>
                ) : 'nothing recorded.'}
              </div>
            )}
            {month.data && month.data.length === 0 && (
              <p className="mt-2 text-xs text-slate-500">Nothing recorded in {monthLabel}.</p>
            )}
          </>
        )}

        {/* The key, so no colour has to be guessed. */}
        <ul className="mt-3 flex flex-wrap gap-x-3 gap-y-1 text-[11px] text-slate-600">
          {[...Object.values(DAY_SKIN), NONE].map((s) => (
            <li key={s.label} className="inline-flex items-center gap-1">
              <span className={`inline-flex h-4 min-w-4 items-center justify-center rounded px-0.5 text-[9px] font-bold ${s.cell}`}>{s.letter}</span>
              {s.label}
            </li>
          ))}
        </ul>
      </div>
    </div>
  )
}

function Count({ n, label, skin }: { n: number; label: string; skin: string }) {
  return (
    <div className="rounded-xl bg-slate-50 px-1 py-2">
      <div className={`text-lg font-semibold tabular-nums ${skin}`}>{n}</div>
      <div className="text-[11px] text-slate-500">{label}</div>
    </div>
  )
}

function Failed({ onRetry }: { onRetry: () => void }) {
  return (
    <p className="mt-2 text-sm text-danger-700">
      Your attendance could not be loaded.{' '}
      <button onClick={onRetry} className="font-medium text-brand-700 hover:underline">Try again</button>
    </p>
  )
}

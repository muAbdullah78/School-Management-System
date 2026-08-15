import { useEffect, useMemo, useRef, useState } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import {
  getCurrentSession, listClasses, listSections, getRoster,
  markAttendance, finalizeAttendance, getMyAssignments,
  type AttendanceStatus, type RosterRow,
} from '@/lib/db'
import { ATTENDANCE_STATUSES } from '@/lib/constants'
import { todayISO } from '@/lib/format'
import { useAuth } from '@/auth/AuthProvider'
import { isTeacher } from '@/auth/roles'
import { enqueueAttendance, isNetworkError, attendanceKey, cachedSchoolId } from '@/lib/offlineQueue'
import { offlineFirst } from '@/lib/offlineCache'
import { AttendanceSheet, type AttendanceSheetData } from './AttendanceSheet'

type Marks = Record<string, AttendanceStatus>

export function AttendancePage() {
  const qc = useQueryClient()
  // These reads are wrapped in offlineFirst so the pickers + roster still work on
  // a cold start with no connection (served from the last cached copy).
  const { profile } = useAuth()
  const isTeach = isTeacher(profile?.role)
  const session = useQuery({ queryKey: ['currentSession'], queryFn: () => offlineFirst('currentSession', getCurrentSession) })
  const classes = useQuery({ queryKey: ['classes'], queryFn: () => offlineFirst('classes', listClasses) })
  const myAssign = useQuery({ queryKey: ['myAssignments'], queryFn: getMyAssignments, enabled: isTeach })

  const [classId, setClassId] = useState('')
  const [sectionChoice, setSectionChoice] = useState('')
  const [date, setDate] = useState(todayISO())

  // A teacher only sees classes/sections they are assigned to (mirrors the RLS).
  const allowedClassIds = isTeach ? new Set((myAssign.data ?? []).map((a) => a.class_id)) : null
  const classOptions = (classes.data ?? []).filter((c) => !allowedClassIds || allowedClassIds.has(c.id))

  const sections = useQuery({
    queryKey: ['sections', classId],
    queryFn: () => offlineFirst(`sections.${classId}`, () => listSections(classId)),
    enabled: !!classId,
  })
  const myClassAssign = isTeach ? (myAssign.data ?? []).filter((a) => a.class_id === classId) : []
  const teacherWholeClass = myClassAssign.some((a) => a.section_id === null)
  const allowedSectionIds = isTeach && !teacherWholeClass
    ? new Set(myClassAssign.map((a) => a.section_id).filter(Boolean) as string[])
    : null
  const sectionOptions = (sections.data ?? []).filter((s) => !allowedSectionIds || allowedSectionIds.has(s.id))
  const hasSections = sectionOptions.length > 0
  const sectionId: string | null = hasSections ? (sectionChoice || null) : null

  // Auto-select the teacher's class/section when they have exactly one assignment.
  useEffect(() => {
    if (!isTeach || classId || !myAssign.data || myAssign.data.length !== 1) return
    const a = myAssign.data[0]
    setClassId(a.class_id)
    if (a.section_id) setSectionChoice(a.section_id)
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [isTeach, myAssign.data])

  const sessionId = session.data?.id
  const ready =
    !!sessionId && !!classId && !!date && sections.isSuccess && (!hasSections || !!sectionChoice)

  const roster = useQuery({
    queryKey: ['roster', sessionId, classId, sectionId ?? 'none', date],
    queryFn: () => offlineFirst(
      `roster.${sessionId}.${classId}.${sectionId ?? 'none'}.${date}`,
      () => getRoster(sessionId!, classId, sectionId, date),
    ),
    enabled: ready,
  })

  // Local, optimistic marking state — reset whenever a fresh roster loads.
  const [marks, setMarks] = useState<Marks>({})
  const [activeIdx, setActiveIdx] = useState(0)
  const [sheet, setSheet] = useState<AttendanceSheetData | null>(null)
  const [saveMsg, setSaveMsg] = useState<string | null>(null)

  const rows: RosterRow[] = roster.data ?? []
  const dayLocked = rows.length > 0 && rows.every((r) => r.is_locked)

  useEffect(() => {
    if (!roster.data) return
    const next: Marks = {}
    for (const r of roster.data) next[r.enrollment_id] = r.status ?? 'present'
    setMarks(next)
    setActiveIdx(0)
    setSaveMsg(null)
  }, [roster.data])

  // Dirty = any row whose current mark differs from what the server has stored
  // (an unmarked row counts as changed, since defaulting it to Present is real).
  const dirty = useMemo(
    () => rows.some((r) => marks[r.enrollment_id] !== (r.status ?? null)),
    [rows, marks],
  )

  const tally = useMemo(() => {
    const t: Record<string, number> = {}
    for (const r of rows) {
      const s = marks[r.enrollment_id]
      if (s) t[s] = (t[s] ?? 0) + 1
    }
    return t
  }, [rows, marks])

  function setOne(enrollmentId: string, status: AttendanceStatus) {
    if (dayLocked) return
    setMarks((m) => ({ ...m, [enrollmentId]: status }))
  }
  function setAll(status: AttendanceStatus) {
    if (dayLocked) return
    setMarks(() => Object.fromEntries(rows.map((r) => [r.enrollment_id, status])))
  }

  // Keyboard-driven marking: p/a/l/t/h (or 1–5) sets the active row and advances.
  const rowsRef = useRef(rows)
  rowsRef.current = rows
  const activeRef = useRef(activeIdx)
  activeRef.current = activeIdx
  useEffect(() => {
    if (!ready || dayLocked) return
    function onKey(e: KeyboardEvent) {
      const el = e.target as HTMLElement
      if (['INPUT', 'SELECT', 'TEXTAREA'].includes(el?.tagName)) return
      const list = rowsRef.current
      if (list.length === 0) return
      const idx = Math.min(activeRef.current, list.length - 1)
      const byKey = ATTENDANCE_STATUSES.find((s) => s.key === e.key.toLowerCase())
      const byNum = /^[1-5]$/.test(e.key) ? ATTENDANCE_STATUSES[Number(e.key) - 1] : undefined
      const pick = byKey ?? byNum
      if (pick) {
        e.preventDefault()
        setOne(list[idx].enrollment_id, pick.value)
        setActiveIdx(Math.min(idx + 1, list.length - 1))
      } else if (e.key === 'ArrowDown') {
        e.preventDefault(); setActiveIdx(Math.min(idx + 1, list.length - 1))
      } else if (e.key === 'ArrowUp') {
        e.preventDefault(); setActiveIdx(Math.max(idx - 1, 0))
      }
    }
    window.addEventListener('keydown', onKey)
    return () => window.removeEventListener('keydown', onKey)
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [ready, dayLocked])

  function queueOffline(payload: { enrollment_id: string; status: AttendanceStatus }[]) {
    const cls = classes.data?.find((c) => c.id === classId)?.name ?? '—'
    const sec = sections.data?.find((s) => s.id === sectionId)?.name
    enqueueAttendance({
      key: attendanceKey(date, classId, sectionId),
      date,
      label: `${cls}${sec ? ' · ' + sec : ''} · ${date}`,
      marks: payload,
      queued_at: new Date().toISOString(),
      school_id: cachedSchoolId() ?? undefined,
    })
  }

  const save = useMutation({
    mutationFn: async (): Promise<{ queued: boolean; marked?: number; skipped?: number }> => {
      const payload = rows.map((r) => ({ enrollment_id: r.enrollment_id, status: marks[r.enrollment_id] ?? 'present' }))
      // Offline (or the network drops mid-save) → queue locally and sync later.
      if (typeof navigator !== 'undefined' && !navigator.onLine) {
        queueOffline(payload); return { queued: true }
      }
      try {
        const res = await markAttendance(date, payload)
        return { queued: false, marked: res.marked, skipped: res.skipped }
      } catch (e) {
        if (isNetworkError(e)) { queueOffline(payload); return { queued: true } }
        throw e
      }
    },
    onSuccess: (res) => {
      if (res.queued) {
        setSaveMsg('Saved offline — will sync automatically when you’re back online.')
      } else {
        setSaveMsg(`Saved ${res.marked}${res.skipped ? ` · ${res.skipped} locked, skipped` : ''}.`)
        qc.invalidateQueries({ queryKey: ['roster', sessionId, classId, sectionId ?? 'none', date] })
      }
    },
  })

  const finalize = useMutation({
    mutationFn: () => finalizeAttendance(sessionId!, classId, sectionId, date),
    onSuccess: (n) => {
      setSaveMsg(`Finalized & locked ${n} row${n === 1 ? '' : 's'}.`)
      qc.invalidateQueries({ queryKey: ['roster', sessionId, classId, sectionId ?? 'none', date] })
    },
  })

  function openSheet() {
    const cls = classes.data?.find((c) => c.id === classId)
    const sec = sections.data?.find((s) => s.id === sectionId)
    setSheet({
      className: cls?.name ?? '—',
      sectionName: sec?.name ?? null,
      date,
      rows: rows.map((r) => ({ roll_no: r.roll_no, full_name: r.full_name, status: marks[r.enrollment_id] ?? 'present' })),
    })
  }

  function doFinalize() {
    if (typeof navigator !== 'undefined' && !navigator.onLine) {
      window.alert('You’re offline. Finalizing locks the day on the server — reconnect first.'); return
    }
    if (dirty) { window.alert('Save your changes before finalizing.'); return }
    if (!window.confirm('Finalize this day? Attendance will be locked and can no longer be edited.')) return
    finalize.mutate()
  }

  const [online, setOnline] = useState(typeof navigator === 'undefined' ? true : navigator.onLine)
  useEffect(() => {
    const on = () => setOnline(true)
    const off = () => setOnline(false)
    window.addEventListener('online', on)
    window.addEventListener('offline', off)
    return () => { window.removeEventListener('online', on); window.removeEventListener('offline', off) }
  }, [])

  const selectCls =
    'mt-1 w-full rounded border border-slate-300 px-3 py-2 text-sm focus:border-brand-500 focus:outline-none'

  return (
    <div>
      <div className="flex flex-wrap items-end justify-between gap-3">
        <h1 className="text-xl font-semibold text-slate-800">Attendance</h1>
        {rows.length > 0 && (
          <div className="flex items-center gap-2 text-sm">
            {dayLocked ? (
              <span className="rounded-full bg-slate-200 px-2.5 py-0.5 text-xs font-medium text-slate-600">🔒 Locked</span>
            ) : dirty ? (
              <span className="rounded-full bg-amber-100 px-2.5 py-0.5 text-xs font-medium text-amber-700">Unsaved changes</span>
            ) : (
              <span className="rounded-full bg-emerald-100 px-2.5 py-0.5 text-xs font-medium text-emerald-700">All saved</span>
            )}
          </div>
        )}
      </div>

      {!session.data && !session.isLoading && (
        <p className="mt-4 rounded bg-amber-50 p-3 text-sm text-amber-700">
          No current academic session is set. Create one in Settings first.
        </p>
      )}

      {/* Pickers */}
      <div className="mt-4 grid gap-3 sm:grid-cols-3">
        <label className="block">
          <span className="text-sm text-slate-600">Class</span>
          <select value={classId} className={selectCls}
            onChange={(e) => { setClassId(e.target.value); setSectionChoice('') }}>
            <option value="">Select class…</option>
            {classOptions.map((c) => <option key={c.id} value={c.id}>{c.name}</option>)}
          </select>
        </label>
        <label className="block">
          <span className="text-sm text-slate-600">Section</span>
          <select value={sectionChoice} className={selectCls}
            disabled={!classId || !hasSections}
            onChange={(e) => setSectionChoice(e.target.value)}>
            {!classId ? (
              <option value="">Pick a class first</option>
            ) : !hasSections ? (
              <option value="">(no sections)</option>
            ) : (
              <>
                <option value="">Select section…</option>
                {sectionOptions.map((s) => <option key={s.id} value={s.id}>{s.name}</option>)}
              </>
            )}
          </select>
        </label>
        <label className="block">
          <span className="text-sm text-slate-600">Date</span>
          <input type="date" value={date} max={todayISO()} className={selectCls}
            onChange={(e) => setDate(e.target.value)} />
        </label>
      </div>

      {/* Roster */}
      <div className="mt-5">
        {!online && rows.length > 0 && (
          <p className="mb-3 rounded bg-amber-50 px-3 py-2 text-sm text-amber-800">
            You’re offline — showing your saved copy of this class. Marks you save will sync when you reconnect.
          </p>
        )}
        {!ready && (
          <p className="text-sm text-slate-500">Pick a class{hasSections ? ', section' : ''} and date to load the roster.</p>
        )}
        {ready && roster.isLoading && <p className="text-sm text-slate-500">Loading roster…</p>}
        {ready && roster.isError && <p className="text-sm text-red-600">{(roster.error as Error).message}</p>}
        {ready && roster.data && rows.length === 0 && (
          <p className="rounded bg-slate-50 p-3 text-sm text-slate-500">No active students found for this selection.</p>
        )}

        {ready && rows.length > 0 && (
          <>
            {/* Toolbar */}
            <div className="flex flex-wrap items-center gap-2 rounded-t-lg border border-b-0 border-slate-200 bg-slate-50 px-3 py-2">
              <button onClick={() => setAll('present')} disabled={dayLocked}
                className="rounded border border-slate-300 bg-white px-2.5 py-1 text-xs font-medium text-slate-700 hover:bg-slate-50 disabled:opacity-50">
                Mark all present
              </button>
              <button onClick={() => setAll('absent')} disabled={dayLocked}
                className="rounded border border-slate-300 bg-white px-2.5 py-1 text-xs font-medium text-slate-700 hover:bg-slate-50 disabled:opacity-50">
                Mark all absent
              </button>
              <div className="ml-auto flex flex-wrap gap-x-3 gap-y-1 text-xs text-slate-600">
                {ATTENDANCE_STATUSES.map((s) => (
                  <span key={s.value}><span className="font-semibold">{s.short}</span> {tally[s.value] ?? 0}</span>
                ))}
              </div>
            </div>

            {dayLocked && (
              <div className="border-x border-slate-200 bg-slate-100 px-3 py-1.5 text-xs text-slate-500">
                This day is finalized and locked. It is read-only.
              </div>
            )}

            {/* Grid */}
            <div className="divide-y divide-slate-100 rounded-b-lg border border-slate-200 bg-white">
              {rows.map((r, i) => (
                <div
                  key={r.enrollment_id}
                  onMouseDown={() => setActiveIdx(i)}
                  className={`flex flex-wrap items-center gap-3 px-3 py-2 ${i === activeIdx && !dayLocked ? 'bg-brand-50/60' : ''}`}
                >
                  <div className="w-8 text-right text-xs text-slate-400">{r.roll_no ?? '—'}</div>
                  <div className="min-w-0 flex-1">
                    <div className="truncate text-sm font-medium text-slate-800">
                      {r.full_name}
                      {r.is_locked && !dayLocked && <span className="ml-1 text-xs text-slate-400" title="Locked">🔒</span>}
                    </div>
                    {r.father_name && <div className="truncate text-xs text-slate-400">{r.father_name}</div>}
                  </div>
                  <StatusChips
                    value={marks[r.enrollment_id]}
                    disabled={dayLocked || r.is_locked}
                    onChange={(s) => { setActiveIdx(i); setOne(r.enrollment_id, s) }}
                  />
                </div>
              ))}
            </div>

            {/* Actions */}
            <div className="mt-4 flex flex-wrap items-center gap-2">
              {!dayLocked && (
                <button onClick={() => save.mutate()} disabled={save.isPending || !dirty}
                  className="rounded bg-brand-600 px-4 py-2 text-sm font-medium text-white hover:bg-brand-700 disabled:opacity-60">
                  {save.isPending ? 'Saving…' : 'Save attendance'}
                </button>
              )}
              <button onClick={openSheet}
                className="rounded border border-slate-300 px-4 py-2 text-sm font-medium text-slate-700 hover:bg-slate-50">
                Print sheet
              </button>
              {!dayLocked && (
                <button onClick={doFinalize} disabled={finalize.isPending}
                  className="rounded border border-slate-300 px-4 py-2 text-sm font-medium text-slate-700 hover:bg-slate-50 disabled:opacity-60">
                  {finalize.isPending ? 'Finalizing…' : 'Finalize & lock'}
                </button>
              )}
              {saveMsg && <span className="text-sm text-emerald-700">{saveMsg}</span>}
              {(save.isError || finalize.isError) && (
                <span className="text-sm text-red-600">
                  {((save.error ?? finalize.error) as Error)?.message}
                </span>
              )}
            </div>

            <p className="mt-3 text-xs text-slate-500">
              Tip: click a row, then press <kbd className="rounded border px-1">P</kbd>/<kbd className="rounded border px-1">A</kbd>/<kbd className="rounded border px-1">L</kbd>/<kbd className="rounded border px-1">T</kbd>/<kbd className="rounded border px-1">H</kbd> (or 1–5) to mark and jump to the next student.
            </p>
          </>
        )}
      </div>

      {sheet && <AttendanceSheet data={sheet} onClose={() => setSheet(null)} />}
    </div>
  )
}

function StatusChips({
  value, onChange, disabled,
}: { value: AttendanceStatus | undefined; onChange: (s: AttendanceStatus) => void; disabled?: boolean }) {
  return (
    <div className="flex gap-1">
      {ATTENDANCE_STATUSES.map((s) => {
        const on = value === s.value
        return (
          <button
            key={s.value}
            type="button"
            disabled={disabled}
            title={s.label}
            onClick={() => onChange(s.value)}
            className={`h-8 w-9 rounded text-xs font-semibold ring-1 transition ${on ? s.on : `bg-white ${s.off}`} ${disabled ? 'opacity-60' : ''}`}
          >
            {s.short}
          </button>
        )
      })}
    </div>
  )
}

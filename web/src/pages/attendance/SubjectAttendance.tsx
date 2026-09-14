import { useEffect, useMemo, useState } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import {
  listClasses, listSections, listSubjects, getMyAssignments,
  subjectRoster, markSubjectAttendance,
  type AttendanceStatus,
} from '@/lib/db'
import { ATTENDANCE_STATUSES } from '@/lib/constants'
import { todayISO } from '@/lib/format'
import { LoadError, inputClass } from '@/components/ui'

/**
 * A subject teacher's own register, for their own subject.
 *
 * DELIBERATELY WEAKER THAN THE DAILY REGISTER, and every difference is a
 * decision rather than an omission:
 *
 *   * nothing is locked or finalised. There is no lock to break and no
 *     approval to chase.
 *   * it feeds no attendance percentage, nothing on a result card, and nothing
 *     a parent sees. Two answers to "was this child present today" is the
 *     failure 0097 and 0100 were written to end.
 *   * nobody is asked to keep it. A subject nobody marks does not appear on
 *     the head's screen as outstanding.
 *
 * The day's register is shown beside each pupil as CONTEXT. A teacher about to
 * mark a child absent from chemistry wants to know first whether the child is
 * in school at all, and without that they will mark absences for children who
 * were never on the premises.
 */
export function SubjectAttendance({ sessionId }: { sessionId: string }) {
  const qc = useQueryClient()
  const classes = useQuery({ queryKey: ['classes'], queryFn: listClasses })
  const mine = useQuery({ queryKey: ['myAssignments'], queryFn: getMyAssignments })

  const [classId, setClassId] = useState('')
  const [sectionChoice, setSectionChoice] = useState('')
  const [subjectId, setSubjectId] = useState('')
  const [date, setDate] = useState(todayISO())
  const [marks, setMarks] = useState<Record<string, AttendanceStatus>>({})
  const [msg, setMsg] = useState<string | null>(null)

  const allowedClassIds = new Set((mine.data ?? []).map((a) => a.class_id))
  const classOptions = (classes.data ?? []).filter((c) => allowedClassIds.has(c.id))

  const sections = useQuery({
    queryKey: ['sections', classId],
    queryFn: () => listSections(classId),
    enabled: !!classId,
  })
  const subjects = useQuery({
    queryKey: ['subjects', classId],
    queryFn: () => listSubjects(classId),
    enabled: !!classId,
  })

  const myClassAssign = (mine.data ?? []).filter((a) => a.class_id === classId)
  const wholeClass = myClassAssign.some((a) => a.section_id === null)
  const allowedSectionIds = wholeClass
    ? null
    : new Set(myClassAssign.map((a) => a.section_id).filter(Boolean) as string[])
  const sectionOptions = (sections.data ?? []).filter((s) => !allowedSectionIds || allowedSectionIds.has(s.id))
  const hasSections = sectionOptions.length > 0
  const sectionId: string | null = hasSections ? (sectionChoice || null) : null

  // One class, one section: fill them in rather than making a teacher pick from
  // a list of one. Same behaviour as the daily register.
  useEffect(() => {
    if (classId || !mine.data || mine.data.length !== 1) return
    setClassId(mine.data[0].class_id)
    if (mine.data[0].section_id) setSectionChoice(mine.data[0].section_id)
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [mine.data])

  const ready = !!classId && !!subjectId && (!hasSections || !!sectionChoice)
  const roster = useQuery({
    queryKey: ['subjectRoster', sessionId, classId, sectionId ?? 'none', subjectId, date],
    queryFn: () => subjectRoster(sessionId, classId, sectionId, subjectId, date),
    enabled: ready,
  })
  const rows = roster.data ?? []

  useEffect(() => {
    if (!roster.data) return
    const next: Record<string, AttendanceStatus> = {}
    // Defaults to what the CLASS TEACHER recorded, not to "present". A child
    // absent from school is absent from every subject, and starting from the
    // day's register means the teacher confirms rather than retypes it.
    for (const r of roster.data) next[r.enrollment_id] = r.status ?? r.day_status ?? 'present'
    setMarks(next)
    setMsg(null)
  }, [roster.data])

  const tally = useMemo(() => {
    const t: Record<string, number> = {}
    for (const r of rows) {
      const s = marks[r.enrollment_id]
      if (s) t[s] = (t[s] ?? 0) + 1
    }
    return t
  }, [rows, marks])

  const save = useMutation({
    mutationFn: () => markSubjectAttendance(
      sessionId, classId, sectionId, subjectId, date,
      rows.map((r) => ({ enrollment_id: r.enrollment_id, status: marks[r.enrollment_id] ?? 'present' })),
    ),
    onSuccess: (res) => {
      setMsg(`Saved ${res.marked}.`)
      qc.invalidateQueries({ queryKey: ['subjectRoster'] })
    },
  })

  return (
    <div>
      <LoadError of={[classes, mine, sections, subjects, roster]} what="Subject attendance" />
      <p className="text-sm text-slate-500">
        Optional. This is your own record for your subject: it is not the daily
        register, it is not locked, and it does not change any attendance
        percentage. Only the head sees it.
      </p>

      <div className="mt-4 grid gap-3 sm:grid-cols-4">
        <label className="block">
          <span className="text-sm text-slate-600">Class</span>
          <select value={classId} className={inputClass}
            onChange={(e) => { setClassId(e.target.value); setSectionChoice(''); setSubjectId('') }}>
            <option value="">Select class…</option>
            {classOptions.map((c) => <option key={c.id} value={c.id}>{c.name}</option>)}
          </select>
        </label>
        <label className="block">
          <span className="text-sm text-slate-600">Section</span>
          <select value={sectionChoice} className={inputClass} disabled={!classId || !hasSections}
            onChange={(e) => setSectionChoice(e.target.value)}>
            {!classId ? <option value="">Pick a class first</option>
              : !hasSections ? <option value="">(no sections)</option>
              : <>
                  <option value="">Select section…</option>
                  {sectionOptions.map((s) => <option key={s.id} value={s.id}>{s.name}</option>)}
                </>}
          </select>
        </label>
        <label className="block">
          <span className="text-sm text-slate-600">Subject</span>
          <select value={subjectId} className={inputClass} disabled={!classId}
            onChange={(e) => setSubjectId(e.target.value)}>
            <option value="">Select subject…</option>
            {(subjects.data ?? []).map((s) => <option key={s.id} value={s.id}>{s.name}</option>)}
          </select>
        </label>
        <label className="block">
          <span className="text-sm text-slate-600">Date</span>
          <input type="date" value={date} max={todayISO()} className={inputClass}
            onChange={(e) => setDate(e.target.value)} />
        </label>
      </div>

      {classOptions.length === 0 && !mine.isLoading && (
        <p className="mt-4 rounded bg-amber-50 p-3 text-sm text-amber-700">
          You are not assigned to any class yet. Ask the office to add you under
          Settings, Staff, Subject Teachers.
        </p>
      )}

      {ready && roster.isLoading && <p className="mt-4 text-sm text-slate-500">Loading…</p>}

      {ready && !roster.isLoading && rows.length === 0 && (
        <p className="mt-4 text-sm text-slate-500">No pupils on this class roll.</p>
      )}

      {rows.length > 0 && (
        <>
          <div className="mt-4 flex flex-wrap gap-2 text-sm">
            {ATTENDANCE_STATUSES.map((s) => (
              <span key={s.value} className="rounded-full bg-slate-100 px-2.5 py-0.5 text-xs text-slate-600">
                {s.label} {tally[s.value] ?? 0}
              </span>
            ))}
          </div>

          <div className="mt-3 overflow-x-auto rounded-lg border border-slate-200 bg-white">
            <table className="w-full text-sm">
              <thead className="bg-slate-50 text-left text-xs uppercase tracking-wide text-slate-500">
                <tr>
                  <th className="px-3 py-2 w-14">Roll</th>
                  <th className="px-3 py-2">Pupil</th>
                  <th className="px-3 py-2 w-28">Day register</th>
                  <th className="px-3 py-2">This subject</th>
                </tr>
              </thead>
              <tbody className="divide-y divide-slate-100">
                {rows.map((r) => (
                  <tr key={r.enrollment_id}>
                    <td className="px-3 py-1.5 text-slate-500">{r.roll_no ?? '-'}</td>
                    <td className="px-3 py-1.5 text-slate-800">{r.full_name}</td>
                    <td className="px-3 py-1.5 text-xs text-slate-500">
                      {r.day_status
                        ? (ATTENDANCE_STATUSES.find((s) => s.value === r.day_status)?.label ?? r.day_status)
                        : 'Not marked'}
                    </td>
                    <td className="px-3 py-1.5">
                      <div className="flex flex-wrap gap-1">
                        {ATTENDANCE_STATUSES.map((s) => {
                          const on = marks[r.enrollment_id] === s.value
                          return (
                            <button key={s.value} type="button"
                              onClick={() => setMarks((m) => ({ ...m, [r.enrollment_id]: s.value }))}
                              className={`rounded px-2 py-0.5 text-xs font-medium ring-1 ${on ? s.on : s.off}`}>
                              {s.short}
                            </button>
                          )
                        })}
                      </div>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>

          <div className="mt-4 flex flex-wrap items-center gap-3">
            <button onClick={() => save.mutate()} disabled={save.isPending}
              className="rounded bg-brand-600 px-4 py-2 text-sm font-medium text-white hover:bg-brand-700 disabled:opacity-60">
              {save.isPending ? 'Saving…' : 'Save subject attendance'}
            </button>
            {msg && <span className="text-sm text-emerald-700">{msg}</span>}
            {save.isError && <span className="text-sm text-red-600">{(save.error as Error).message}</span>}
          </div>
        </>
      )}
    </div>
  )
}

import { useEffect, useMemo, useState } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useSearchParams } from 'react-router-dom'
import {
  listSections, listSubjects, getMyTeaching,
  subjectRoster, markSubjectAttendance,
  type AttendanceStatus,
} from '@/lib/db'
import { ATTENDANCE_STATUSES } from '@/lib/constants'
import { todayISO } from '@/lib/format'
import { LoadError, inputClass } from '@/components/ui'
import { AskDialog } from '@/components/AskDialog'
import { sectionScope, subjectScope, taughtClasses } from '@/lib/teaching'

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
  /* THE CLASSES A TEACHER TEACHES, NOT THE ONES THEY ARE CLASS TEACHER OF.
     This screen read fn_my_assignments, the class teacher's table, so the
     subject teachers it exists for were offered no class at all (0151). */
  const mine = useQuery({ queryKey: ['myTeaching'], queryFn: getMyTeaching })
  const teaching = mine.data ?? []

  // A link from the teacher's home names the class (and section).
  const [params] = useSearchParams()
  const [classId, setClassId] = useState(() => params.get('classId') ?? '')
  const [sectionChoice, setSectionChoice] = useState(() => params.get('sectionId') ?? '')
  const [subjectId, setSubjectId] = useState('')
  const [date, setDate] = useState(todayISO())
  const [marks, setMarks] = useState<Record<string, AttendanceStatus>>({})
  const [msg, setMsg] = useState<string | null>(null)
  /* Marks changed on the screen since the list loaded. Changing the class,
     section, subject or date threw them away without a word; now it asks. */
  const [touched, setTouched] = useState(false)
  const [pendingPick, setPendingPick] = useState<null | { what: string; run: () => void }>(null)
  const guard = (what: string, run: () => void) => { if (touched) setPendingPick({ what, run }); else run() }

  const classOptions = taughtClasses(teaching).map((c) => ({ id: c.class_id, name: c.class_name }))

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

  const scope = sectionScope(teaching, classId)
  const sectionOptions = (sections.data ?? []).filter((s) => !scope.ids || scope.ids.has(s.id))
  const hasSections = sectionOptions.length > 0
  const sectionId: string | null = hasSections ? (sectionChoice || null) : null
  // Only the subjects this teacher teaches here: all of them for the class
  // teacher, their own for a subject teacher. The database refuses the rest,
  // and a picker that offers them is a refusal waiting to happen.
  const subj = subjectScope(teaching, classId, sectionId)
  const subjectOptions = (subjects.data ?? []).filter((s) => subj.any || subj.ids.has(s.id))

  // One class, one section, one subject: fill them in rather than making a
  // teacher pick from a list of one.
  useEffect(() => {
    if (classId || classOptions.length !== 1) return
    setClassId(classOptions[0].id)
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [classOptions.length])
  useEffect(() => {
    if (!classId || !sections.isSuccess) return
    if (sectionChoice && !sectionOptions.some((x) => x.id === sectionChoice)) setSectionChoice('')
    else if (!sectionChoice && sectionOptions.length === 1) setSectionChoice(sectionOptions[0].id)
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [classId, sections.isSuccess, sections.data, mine.data, sectionChoice])
  useEffect(() => {
    if (!classId || !subjects.isSuccess) return
    if (subjectId && !subjectOptions.some((x) => x.id === subjectId)) setSubjectId('')
    else if (!subjectId && subjectOptions.length === 1) setSubjectId(subjectOptions[0].id)
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [classId, sectionId, subjects.isSuccess, subjects.data, mine.data, subjectId])
  // A class from a link that this teacher does not teach is dropped once the
  // list has loaded, instead of opening a roster the picker does not show.
  useEffect(() => {
    if (classId && mine.data && !classOptions.some((c) => c.id === classId)) { setClassId(''); setSectionChoice('') }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [classId, mine.data])

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
    setTouched(false)
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
      setTouched(false)
      qc.invalidateQueries({ queryKey: ['subjectRoster'] })
    },
  })

  return (
    <div>
      <LoadError of={[mine, sections, subjects, roster]} what="Subject attendance" />
      <p className="text-sm text-slate-500">
        Optional. This is your own record for your subject: it is not the daily
        register, it is not locked, and it does not change any attendance
        percentage. Only the head sees it.
      </p>

      <div className="mt-4 grid gap-3 sm:grid-cols-4">
        <label className="block">
          <span className="text-sm text-slate-600">Class</span>
          <select value={classId} className={inputClass}
            onChange={(e) => { const v = e.target.value; guard('another class', () => { setClassId(v); setSectionChoice(''); setSubjectId('') }) }}>
            <option value="">Select class…</option>
            {classOptions.map((c) => <option key={c.id} value={c.id}>{c.name}</option>)}
          </select>
        </label>
        <label className="block">
          <span className="text-sm text-slate-600">Section</span>
          <select value={sectionChoice} className={inputClass} disabled={!classId || !hasSections}
            onChange={(e) => { const v = e.target.value; guard('another section', () => setSectionChoice(v)) }}>
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
            onChange={(e) => { const v = e.target.value; guard('another subject', () => setSubjectId(v)) }}>
            <option value="">Select subject…</option>
            {subjectOptions.map((s) => <option key={s.id} value={s.id}>{s.name}</option>)}
          </select>
        </label>
        <label className="block">
          <span className="text-sm text-slate-600">Date</span>
          <input type="date" value={date} max={todayISO()} className={inputClass}
            onChange={(e) => { const v = e.target.value; if (v) guard('another day', () => setDate(v)) }} />
        </label>
      </div>

      {classOptions.length === 0 && !mine.isLoading && (
        <p className="mt-4 rounded-2xl bg-due-50 p-3 text-sm text-due-800 ring-1 ring-due-200">
          No class or subject is assigned to you yet. Ask the office to add you under
          Staff: Subject teachers.
        </p>
      )}
      {classId && subjects.isSuccess && subjectOptions.length === 0 && (
        <p className="mt-4 rounded-2xl bg-due-50 p-3 text-sm text-due-800 ring-1 ring-due-200">
          {(subjects.data ?? []).length === 0
            ? 'This class has no subjects yet. The office adds them in Settings: Classes and sections.'
            : 'None of this class\'s subjects is assigned to you. Ask the office to add you under Staff: Subject teachers.'}
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

          {/* One card per pupil on a phone, with status buttons a thumb can
              hit. The table's buttons were twenty pixels tall. */}
          <ul className="mt-3 space-y-2 sm:hidden">
            {rows.map((r) => (
              <li key={r.enrollment_id} className="rounded-xl border border-slate-200 bg-white p-3">
                <div className="flex items-baseline justify-between gap-2">
                  <div className="min-w-0 text-sm font-medium text-slate-900">
                    {r.roll_no != null && <span className="mr-1.5 tabular-nums text-slate-400">{r.roll_no}</span>}{r.full_name}
                  </div>
                  <span className="shrink-0 text-[11px] text-slate-500">
                    Day: {r.day_status ? (ATTENDANCE_STATUSES.find((s) => s.value === r.day_status)?.label ?? r.day_status) : 'not marked'}
                  </span>
                </div>
                <div className="mt-2 grid grid-cols-5 gap-1.5">
                  {ATTENDANCE_STATUSES.map((s) => {
                    const on = marks[r.enrollment_id] === s.value
                    return (
                      <button key={s.value} type="button" aria-pressed={on} aria-label={`${r.full_name}: ${s.label}`}
                        onClick={() => { setMarks((m) => ({ ...m, [r.enrollment_id]: s.value })); setTouched(true); setMsg(null) }}
                        className={`h-10 rounded-lg text-sm font-semibold ring-1 transition ${on ? s.on : s.off}`}
                        style={{ touchAction: 'manipulation' }}>
                        {s.short}
                      </button>
                    )
                  })}
                </div>
              </li>
            ))}
          </ul>
          <div className="mt-3 hidden overflow-x-auto rounded-lg border border-slate-200 bg-white sm:block">
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
                              onClick={() => { setMarks((m) => ({ ...m, [r.enrollment_id]: s.value })); setTouched(true); setMsg(null) }}
                              aria-pressed={on}
                              className={`rounded-lg px-2.5 py-1 text-xs font-medium ring-1 ${on ? s.on : s.off}`}>
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
              className="w-full rounded-lg bg-brand-600 px-4 py-2.5 text-sm font-medium text-white shadow-card hover:bg-brand-700 disabled:opacity-60 sm:w-auto">
              {save.isPending ? 'Saving…' : 'Save subject attendance'}
            </button>
            {msg && <span className="text-sm text-brand-700">{msg}</span>}
            {save.isError && <span className="text-sm text-danger-700">{(save.error as Error).message}</span>}
          </div>
        </>
      )}

      {pendingPick && (
        <AskDialog
          title="Leave without saving?"
          intro={<>
            The marks on this list have not been saved. Opening {pendingPick.what} throws
            them away. Press <b>Stay</b> and then <b>Save subject attendance</b> to keep them.
          </>}
          confirmLabel="Discard the marks"
          cancelLabel="Stay"
          tone="danger"
          onCancel={() => setPendingPick(null)}
          onSubmit={() => { const run = pendingPick.run; setPendingPick(null); setTouched(false); run() }}
        />
      )}
    </div>
  )
}

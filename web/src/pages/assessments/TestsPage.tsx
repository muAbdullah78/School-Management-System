import { useEffect, useState } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import {
  getCurrentSession, listClasses, listSections, listSubjects,
  listAssessments, createAssessment, getAssessmentMarksheet, enterAssessmentMarks, lockAssessment,
  getMyAssignments,
  type AssessmentRow,
} from '@/lib/db'
import { fmtDate, todayISO } from '@/lib/format'
import { useAuth } from '@/auth/AuthProvider'
import { isTeacher } from '@/auth/roles'

const FIELD = 'mt-1 w-full rounded border border-slate-300 px-3 py-2 text-sm focus:border-brand-500 focus:outline-none focus:ring-1 focus:ring-brand-500'
type Entry = { marks: string; is_absent: boolean }

export function TestsPage() {
  const { profile } = useAuth()
  const isTeach = isTeacher(profile?.role)
  const session = useQuery({ queryKey: ['currentSession'], queryFn: getCurrentSession })
  const sessionId = session.data?.id
  const classes = useQuery({ queryKey: ['classes'], queryFn: listClasses })
  const myAssign = useQuery({ queryKey: ['myAssignments'], queryFn: getMyAssignments, enabled: isTeach })
  const [classId, setClassId] = useState('')
  const [selected, setSelected] = useState<AssessmentRow | null>(null)

  const allowedClassIds = isTeach ? new Set((myAssign.data ?? []).map((a) => a.class_id)) : null
  const classOptions = (classes.data ?? []).filter((c) => !allowedClassIds || allowedClassIds.has(c.id))
  const myClassAssign = isTeach ? (myAssign.data ?? []).filter((a) => a.class_id === classId) : []
  const teacherWholeClass = myClassAssign.some((a) => a.section_id === null)
  const forcedSectionIds = isTeach && !teacherWholeClass
    ? (myClassAssign.map((a) => a.section_id).filter(Boolean) as string[])
    : null

  useEffect(() => {
    if (!isTeach || classId || !myAssign.data || myAssign.data.length !== 1) return
    setClassId(myAssign.data[0].class_id)
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [isTeach, myAssign.data])

  const tests = useQuery({
    queryKey: ['assessments', sessionId, classId],
    queryFn: () => listAssessments(sessionId!, classId), enabled: !!sessionId && !!classId,
  })

  return (
    <div>
      <h1 className="text-xl font-semibold text-slate-800">Tests</h1>
      <p className="mt-1 text-sm text-slate-500">Daily, weekly and monthly class tests. Separate from formal exams.</p>

      <label className="mt-4 block max-w-xs">
        <span className="text-sm text-slate-600">Class</span>
        <select value={classId} onChange={(e) => { setClassId(e.target.value); setSelected(null) }} className={FIELD}>
          <option value="">Select class…</option>
          {classOptions.map((c) => <option key={c.id} value={c.id}>{c.name}</option>)}
        </select>
      </label>

      {classId && !selected && (
        <div className="mt-5 grid gap-5 lg:grid-cols-[1fr_20rem]">
          <div>
            <div className="text-xs font-semibold uppercase tracking-wide text-slate-500">Tests in this class</div>
            <div className="mt-2 space-y-2">
              {tests.isLoading && <p className="text-sm text-slate-500">Loading…</p>}
              {tests.data?.length === 0 && <p className="text-sm text-slate-500">No tests yet. Create one on the right.</p>}
              {tests.data?.map((t) => (
                <button key={t.id} onClick={() => setSelected(t)}
                  className="flex w-full items-center justify-between rounded-lg border border-slate-200 bg-white px-3 py-2 text-left hover:ring-1 hover:ring-brand-300">
                  <span>
                    <span className="font-medium text-slate-800">{t.title}</span>
                    <span className="text-sm text-slate-500">
                      {t.subject_name ? ` · ${t.subject_name}` : ''}{t.section_name ? ` · Sec ${t.section_name}` : ''} · /{t.max_marks}
                    </span>
                    <span className="block text-xs text-slate-400">{fmtDate(t.assessment_date)}</span>
                  </span>
                  {t.is_locked && <span className="text-xs text-slate-500">🔒 locked</span>}
                </button>
              ))}
            </div>
          </div>
          <NewTest key={classId} sessionId={sessionId!} classId={classId} forcedSectionIds={forcedSectionIds} />
        </div>
      )}

      {selected && (
        <MarksGrid test={selected} onBack={() => setSelected(null)} />
      )}
    </div>
  )
}

function NewTest({ sessionId, classId, forcedSectionIds }: { sessionId: string; classId: string; forcedSectionIds: string[] | null }) {
  const qc = useQueryClient()
  const subjects = useQuery({ queryKey: ['subjects', classId], queryFn: () => listSubjects(classId) })
  const sections = useQuery({ queryKey: ['sections', classId], queryFn: () => listSections(classId) })
  const [title, setTitle] = useState('')
  const [subjectId, setSubjectId] = useState('')
  const [sectionId, setSectionId] = useState('')
  const [date, setDate] = useState(todayISO())
  const [maxMarks, setMaxMarks] = useState('20')

  // A section-scoped teacher must pick one of their sections (never "All").
  const sectionChoices = forcedSectionIds
    ? (sections.data ?? []).filter((s) => forcedSectionIds.includes(s.id))
    : (sections.data ?? [])
  useEffect(() => {
    if (forcedSectionIds && forcedSectionIds.length && !sectionId) setSectionId(forcedSectionIds[0])
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [forcedSectionIds, sections.data])

  const create = useMutation({
    mutationFn: () => createAssessment({
      sessionId, classId, subjectId: subjectId || null, sectionId: sectionId || null,
      title: title.trim(), assessmentDate: date, maxMarks: Number(maxMarks),
    }),
    onSuccess: () => { setTitle(''); qc.invalidateQueries({ queryKey: ['assessments', sessionId, classId] }) },
  })

  const valid = title.trim() !== '' && Number(maxMarks) > 0

  return (
    <form className="h-fit rounded-lg border border-slate-200 bg-white p-4"
      onSubmit={(e) => { e.preventDefault(); if (valid) create.mutate() }}>
      <div className="text-xs font-semibold uppercase tracking-wide text-slate-500">New test</div>
      <label className="mt-2 block">
        <span className="text-sm text-slate-600">Title</span>
        <input value={title} onChange={(e) => setTitle(e.target.value)} className={FIELD} placeholder="e.g. Weekly Test 3" />
      </label>
      <div className="mt-2 grid grid-cols-2 gap-2">
        <label className="block">
          <span className="text-sm text-slate-600">Subject</span>
          <select value={subjectId} onChange={(e) => setSubjectId(e.target.value)} className={FIELD}>
            <option value="">-</option>
            {subjects.data?.map((s) => <option key={s.id} value={s.id}>{s.name}</option>)}
          </select>
        </label>
        <label className="block">
          <span className="text-sm text-slate-600">Section</span>
          <select value={sectionId} onChange={(e) => setSectionId(e.target.value)} className={FIELD}>
            {!forcedSectionIds && <option value="">All</option>}
            {sectionChoices.map((s) => <option key={s.id} value={s.id}>{s.name}</option>)}
          </select>
        </label>
        <label className="block">
          <span className="text-sm text-slate-600">Date</span>
          <input type="date" value={date} onChange={(e) => setDate(e.target.value)} className={FIELD} />
        </label>
        <label className="block">
          <span className="text-sm text-slate-600">Total marks</span>
          <input type="number" min="1" value={maxMarks} onChange={(e) => setMaxMarks(e.target.value)} className={FIELD} />
        </label>
      </div>
      {create.isError && <p className="mt-2 text-sm text-red-600">{(create.error as Error).message}</p>}
      <button type="submit" disabled={!valid || create.isPending}
        className="mt-3 w-full rounded bg-brand-600 px-4 py-2 text-sm font-medium text-white hover:bg-brand-700 disabled:opacity-60">
        {create.isPending ? 'Creating…' : 'Create test'}
      </button>
    </form>
  )
}

function MarksGrid({ test, onBack }: { test: AssessmentRow; onBack: () => void }) {
  const qc = useQueryClient()
  const marksheet = useQuery({ queryKey: ['assessmentMarks', test.id], queryFn: () => getAssessmentMarksheet(test.id) })
  const [entries, setEntries] = useState<Record<string, Entry>>({})
  const [msg, setMsg] = useState<string | null>(null)
  const rows = marksheet.data ?? []
  const locked = test.is_locked

  useEffect(() => {
    if (!marksheet.data) return
    const next: Record<string, Entry> = {}
    for (const r of marksheet.data) next[r.enrollment_id] = { marks: r.marks == null ? '' : String(r.marks), is_absent: r.is_absent }
    setEntries(next); setMsg(null)
  }, [marksheet.data])

  const save = useMutation({
    mutationFn: () => enterAssessmentMarks(test.id, rows.map((r) => {
      const e = entries[r.enrollment_id]
      return { enrollment_id: r.enrollment_id, marks: e?.is_absent || e?.marks === '' ? null : Number(e.marks), is_absent: !!e?.is_absent }
    })),
    onSuccess: (res) => { setMsg(`Saved ${res.marked}${res.skipped ? ` · ${res.skipped} skipped` : ''}.`); qc.invalidateQueries({ queryKey: ['assessmentMarks', test.id] }) },
  })
  const lock = useMutation({
    mutationFn: () => lockAssessment(test.id),
    onSuccess: () => { qc.invalidateQueries({ queryKey: ['assessments'] }); onBack() },
  })

  function upd(id: string, patch: Partial<Entry>) { setEntries((m) => ({ ...m, [id]: { ...m[id], ...patch } })) }
  const overMax = rows.some((r) => { const e = entries[r.enrollment_id]; return e && !e.is_absent && e.marks !== '' && (Number(e.marks) < 0 || Number(e.marks) > r.max_marks) })

  return (
    <div className="mt-5">
      <button onClick={onBack} className="text-sm text-brand-700 hover:underline">← Back to tests</button>
      <div className="mt-2 flex items-baseline justify-between">
        <h2 className="text-lg font-medium text-slate-800">
          {test.title}
          <span className="ml-2 text-sm font-normal text-slate-500">
            {test.subject_name ?? ''}{test.section_name ? ` · Sec ${test.section_name}` : ''} · out of {test.max_marks}
          </span>
        </h2>
        {locked && <span className="text-sm text-slate-500">🔒 locked</span>}
      </div>

      {marksheet.isLoading && <p className="mt-4 text-sm text-slate-500">Loading marksheet…</p>}
      {rows.length === 0 && !marksheet.isLoading && <p className="mt-4 text-sm text-slate-500">No active students for this test.</p>}
      {rows.length > 0 && (
        <>
          <div className="mt-3 overflow-hidden rounded-lg border border-slate-200 bg-white">
            <table className="w-full text-sm">
              <thead className="bg-slate-50 text-left text-xs uppercase tracking-wide text-slate-500">
                <tr><th className="px-3 py-2 w-14">Roll</th><th className="px-3 py-2">Student</th><th className="px-3 py-2 w-32">Marks (/{test.max_marks})</th><th className="px-3 py-2 w-24">Absent</th></tr>
              </thead>
              <tbody className="divide-y divide-slate-100">
                {rows.map((r) => {
                  const e = entries[r.enrollment_id] ?? { marks: '', is_absent: false }
                  const bad = !e.is_absent && e.marks !== '' && (Number(e.marks) < 0 || Number(e.marks) > r.max_marks)
                  const dis = e.is_absent || r.is_locked || locked
                  return (
                    <tr key={r.enrollment_id} className={r.is_locked ? 'opacity-60' : ''}>
                      <td className="px-3 py-2 text-slate-500">{r.roll_no ?? '-'}</td>
                      <td className="px-3 py-2 text-slate-800">{r.full_name}{r.section_name ? <span className="text-slate-400"> · {r.section_name}</span> : ''}{r.is_locked && <span className="ml-1 text-xs">🔒</span>}</td>
                      <td className="px-3 py-2">
                        <input type="number" min="0" max={r.max_marks} step="0.5" disabled={dis}
                          value={e.is_absent ? '' : e.marks} onChange={(ev) => upd(r.enrollment_id, { marks: ev.target.value })}
                          className={`w-24 rounded border px-2 py-1 text-sm ${bad ? 'border-red-400' : 'border-slate-300'} disabled:bg-slate-100`} />
                      </td>
                      <td className="px-3 py-2">
                        <input type="checkbox" checked={e.is_absent} disabled={r.is_locked || locked}
                          onChange={(ev) => upd(r.enrollment_id, { is_absent: ev.target.checked })} className="h-4 w-4" />
                      </td>
                    </tr>
                  )
                })}
              </tbody>
            </table>
          </div>
          {!locked && (
            <div className="mt-4 flex flex-wrap items-center gap-3">
              <button onClick={() => save.mutate()} disabled={save.isPending || overMax}
                className="rounded bg-brand-600 px-4 py-2 text-sm font-medium text-white hover:bg-brand-700 disabled:opacity-60">
                {save.isPending ? 'Saving…' : 'Save marks'}
              </button>
              <button onClick={() => { if (confirm('Lock this test? Marks can no longer be edited.')) lock.mutate() }}
                disabled={lock.isPending}
                className="rounded border border-slate-300 px-4 py-2 text-sm font-medium text-slate-700 hover:bg-slate-50 disabled:opacity-60">
                Lock test
              </button>
              {overMax && <span className="text-sm text-red-600">Some marks exceed the maximum.</span>}
              {msg && <span className="text-sm text-emerald-700">{msg}</span>}
              {save.isError && <span className="text-sm text-red-600">{(save.error as Error).message}</span>}
              {lock.isError && <span className="text-sm text-red-600">{(lock.error as Error).message}</span>}
            </div>
          )}
        </>
      )}
    </div>
  )
}

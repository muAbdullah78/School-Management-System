import { useEffect, useState } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import {
  getCurrentSession, listClasses, listSections, listSubjects,
  listAssessments, createAssessment, getAssessmentMarksheet, enterAssessmentMarks, lockAssessment,
  getMyAssignments, myUnmarkedTests, getSchoolSettings,
  type AssessmentRow,
} from '@/lib/db'
import { fmtDate, todayISO } from '@/lib/format'
import { useAuth } from '@/auth/AuthProvider'
import { isTeacher } from '@/auth/roles'
import { TestsOverview } from './TestsOverview'
import { LoadError } from '@/components/ui'
import { AskDialog } from '@/components/AskDialog'

const FIELD = 'mt-1 w-full rounded border border-slate-300 px-3 py-2 text-sm focus:border-brand-500 focus:outline-none focus:ring-1 focus:ring-brand-500'
type Entry = { marks: string; is_absent: boolean }

/**
 * WHO SEES WHAT.
 *
 * Migration 0135 took test creation, marking and locking away from the
 * principal. As with the register in 0134, the answer is not a disabled button
 * on the same screen: the head's question is a different question, and it now
 * has a screen of its own.
 *
 *   class_teacher, subject_teacher  set, schedule and mark their own tests
 *   principal, readonly             the oversight screen with the calendar
 *   owner                           the oversight screen, and may still set a
 *                                   test from it. See 0134 for why the owner
 *                                   keeps the hatch and where to close it.
 */
export function TestsPage() {
  const { profile } = useAuth()
  const role = profile?.role
  const overseer = role === 'principal' || role === 'readonly' || role === 'owner'
  const session = useQuery({ queryKey: ['currentSession'], queryFn: getCurrentSession })
  const [setting, setSetting] = useState(false)

  if (overseer && !(role === 'owner' && setting)) {
    if (!session.data) {
      return (
        <div>
          {/* The failed read is shown rather than translated into "no session
              set": a head told to create an academic year they already have
              will go and create a second one. */}
          <LoadError of={[session]} what="The tests overview" />
          <h1 className="text-xl font-semibold text-slate-800">Tests</h1>
          {!session.isError && (
            <p className="mt-4 rounded-xl border border-due-200 bg-due-50 p-3 text-sm text-due-800">
              {session.isLoading
                ? 'Loading…'
                : 'No current academic session is set. Create one in Settings first.'}
            </p>
          )}
        </div>
      )
    }
    return (
      <div>
        <TestsOverview sessionId={session.data.id} />
        {role === 'owner' && (
          <div className="mt-8 rounded-lg border border-slate-200 bg-slate-50 px-4 py-3">
            <p className="text-sm text-slate-600">
              Tests are set and marked by the teachers. As the owner you can still
              set one yourself if you have to.
            </p>
            <button onClick={() => setSetting(true)}
              className="mt-2 rounded border border-slate-300 bg-white px-3 py-1.5 text-sm font-medium text-slate-700 hover:bg-slate-100">
              Set a test
            </button>
          </div>
        )}
      </div>
    )
  }

  return (
    <div>
      {role === 'owner' && (
        <button onClick={() => setSetting(false)} className="text-sm text-brand-700 hover:underline">
          &larr; Back to the overview
        </button>
      )}
      <TeacherTests />
    </div>
  )
}

function TeacherTests() {
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

  // Split on the DATE, not on whether marks exist. A test dated today counts as
  // sat: the paper may be collected at lunchtime and marked in the afternoon,
  // and the database allows marks from the day itself.
  const today = todayISO()
  const all = tests.data ?? []
  const scheduled = all.filter((t) => t.assessment_date != null && t.assessment_date > today)
  const sat = all.filter((t) => t.assessment_date == null || t.assessment_date <= today)

  return (
    <div>
      <LoadError of={[session, classes, tests]} what="Your tests" />
      <h1 className="text-xl font-semibold text-slate-800">Tests</h1>
      <p className="mt-1 text-sm text-slate-500">Daily, weekly and monthly class tests. Separate from formal exams.</p>

      {sessionId && (
        <UnmarkedReminder
          sessionId={sessionId}
          onPick={(id) => { setClassId(id); setSelected(null) }}
        />
      )}

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
            {tests.isLoading && <p className="text-sm text-slate-500">Loading…</p>}
            {tests.data?.length === 0 && (
              <p className="text-sm text-slate-500">No tests yet. Create one on the right.</p>
            )}

            {/*
              * SCHEDULED TESTS ARE LISTED SEPARATELY, and it is not decoration.
              * A paper set for Saturday and a paper sat last Tuesday were in
              * one list with nothing but a date to tell them apart, and both
              * opened the same marks grid. Since 0135 the database refuses
              * marks before the day, so an undivided list would mean a teacher
              * tapping a test and being refused with no way to have known.
              */}
            {scheduled.length > 0 && (
              <>
                <div className="text-xs font-semibold uppercase tracking-wide text-slate-500">
                  Scheduled
                </div>
                <div className="mt-2 space-y-2">
                  {scheduled.map((t) => (
                    <div key={t.id}
                      className="rounded-lg border border-info-200 bg-info-50/60 px-3 py-2">
                      <span className="font-medium text-slate-800">{t.title}</span>
                      <span className="text-sm text-slate-500">
                        {t.subject_name ? ` · ${t.subject_name}` : ''}
                        {t.section_name ? ` · Sec ${t.section_name}` : ''} · /{t.max_marks}
                      </span>
                      <span className="block text-xs text-info-800">
                        {fmtDate(t.assessment_date)} · marks can be entered from that day
                      </span>
                    </div>
                  ))}
                </div>
              </>
            )}

            {sat.length > 0 && (
              <>
                <div className={`text-xs font-semibold uppercase tracking-wide text-slate-500 ${scheduled.length ? 'mt-5' : ''}`}>
                  Sat
                </div>
                <div className="mt-2 space-y-2">
                  {sat.map((t) => (
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
              </>
            )}
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

/**
 * Papers you set, that have been sat, that you have not finished marking.
 *
 * WHY IT IS ON THIS SCREEN AND NOT ONLY IN A NOTIFICATION. A test is marked at
 * the teacher's own pace on their own phone, days after the paper is collected,
 * and the thing that actually loses marks is not forgetting that the test
 * happened: it is marking twenty of thirty-four, being interrupted, and never
 * coming back. So "unmarked" here means AT LEAST ONE pupil with neither a mark
 * nor an absence, which is the case a reminder that only fires on a blank test
 * would miss entirely.
 *
 * A test dated TODAY is not chased. The paper may be sat this afternoon.
 *
 * Silent when there is nothing outstanding. A panel that says "nothing to do"
 * every day is a panel people stop reading on the day it says something else.
 */
function UnmarkedReminder({
  sessionId, onPick,
}: { sessionId: string; onPick: (classId: string) => void }) {
  const late = useQuery({
    queryKey: ['myUnmarkedTests', sessionId],
    queryFn: () => myUnmarkedTests(sessionId),
  })
  const rows = late.data ?? []
  if (rows.length === 0) return null

  return (
    <div className="mt-4 rounded-xl border border-due-200 bg-due-50 px-4 py-3">
      <div className="text-sm font-medium text-due-900">
        {rows.length === 1
          ? 'One test is still waiting to be marked'
          : `${rows.length} tests are still waiting to be marked`}
      </div>
      <ul className="mt-2 space-y-1">
        {rows.map((r) => (
          <li key={r.assessment_id}>
            <button type="button" onClick={() => onPick(r.class_id)}
              className="text-left text-sm text-due-900 hover:underline">
              <span className="font-medium">{r.title}</span>
              <span className="text-due-800">
                {' · '}{r.class_name}{r.section_name ? ` ${r.section_name}` : ''}
                {r.subject_name ? ` · ${r.subject_name}` : ''}
                {' · '}{fmtDate(r.assessment_date)}
                {' · '}{r.marked} of {r.pupils} marked
                {' · '}{r.days_late} day{r.days_late === 1 ? '' : 's'} ago
              </span>
            </button>
          </li>
        ))}
      </ul>
      <p className="mt-2 text-xs text-due-800">
        Tap one to open its class. It stops appearing here once every pupil has
        a mark or is recorded absent.
      </p>
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

  // A date is required: the database refuses a test with none, and saying so
  // after the press loses what was typed.
  const valid = title.trim() !== '' && Number(maxMarks) > 0 && /^\d{4}-\d{2}-\d{2}$/.test(date)

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
          {/*
            * NO `max`. A future date is the scheduling feature: "next Saturday"
            * is exactly what a teacher wants to enter on a Wednesday. The
            * database bounds it to the academic year and to a year ahead, which
            * catches the realistic error (a mistyped year) without refusing the
            * realistic use.
            */}
          <input type="date" value={date} onChange={(e) => setDate(e.target.value)} className={FIELD} />
          {date > todayISO() && (
            <span className="mt-1 block text-xs text-info-700">
              Scheduled. Marks can be entered from {fmtDate(date)}.
            </span>
          )}
        </label>
        <label className="block">
          <span className="text-sm text-slate-600">Total marks</span>
          <input type="number" min="1" value={maxMarks} onChange={(e) => setMaxMarks(e.target.value)} className={FIELD} />
        </label>
      </div>
      {create.isError && <p className="mt-2 text-sm text-danger-600">{(create.error as Error).message}</p>}
      {create.isSuccess && !title && <p className="mt-2 text-sm font-medium text-brand-700">Test created. It is in the list.</p>}
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
  const [locking, setLocking] = useState(false)
  const rows = marksheet.data ?? []
  const locked = test.is_locked

  useEffect(() => {
    if (!marksheet.data) return
    const next: Record<string, Entry> = {}
    for (const r of marksheet.data) next[r.enrollment_id] = { marks: r.marks == null ? '' : String(r.marks), is_absent: r.is_absent }
    // NOT setMsg(null) here. Saving refetches the marksheet, so clearing the
    // message on every load wiped "Saved 25" the instant it appeared. A new
    // edit clears it instead (upd).
    setEntries(next)
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
    onSuccess: () => { setLocking(false); qc.invalidateQueries({ queryKey: ['assessments'] }); onBack() },
  })

  function upd(id: string, patch: Partial<Entry>) { setEntries((m) => ({ ...m, [id]: { ...m[id], ...patch } })); setMsg(null) }
  const overMax = rows.some((r) => { const e = entries[r.enrollment_id]; return e && !e.is_absent && e.marks !== '' && (Number(e.marks) < 0 || Number(e.marks) > r.max_marks) })

  // What the grid says NOW, as it is typed, so a teacher sees the class
  // average move and knows whether anybody is below the pass mark before
  // saving. The pass mark is the school's own (Settings), 33 if unreadable.
  const settings = useQuery({ queryKey: ['schoolSettings'], queryFn: getSchoolSettings, staleTime: 5 * 60_000 })
  const passPct = Number(settings.data?.pass_percent ?? 33) || 33
  const typed = rows.map((r) => ({ r, e: entries[r.enrollment_id] ?? { marks: '', is_absent: false } }))
  const scored = typed.filter(({ e }) => !e.is_absent && e.marks !== '' && Number.isFinite(Number(e.marks)))
  const absentN = typed.filter(({ e }) => e.is_absent).length
  const blankN = rows.length - scored.length - absentN
  const pcts = scored.map(({ r, e }) => (r.max_marks > 0 ? (100 * Number(e.marks)) / r.max_marks : 0))
  const avg = pcts.length ? Math.round((10 * pcts.reduce((a, b) => a + b, 0)) / pcts.length) / 10 : null
  const below = pcts.filter((p) => p < passPct).length
  const top = pcts.length ? Math.round(10 * Math.max(...pcts)) / 10 : null

  // Unsaved edits, and children with nothing SAVED. Locking refuses both: the
  // database locks what is stored, not what is on screen, and since 0147 it
  // refuses a test with any child neither marked nor absent.
  const dirty = rows.some((r) => {
    const e = entries[r.enrollment_id]
    if (!e) return false
    return e.is_absent !== r.is_absent || (e.is_absent ? false : e.marks !== (r.marks == null ? '' : String(r.marks)))
  })
  const unsavedBlank = rows.filter((r) => r.marks == null && !r.is_absent).length
  const lockBlocked = dirty
    ? 'Save the marks first. Locking keeps what is saved, not what is on the screen.'
    : unsavedBlank > 0
      ? `${unsavedBlank} child${unsavedBlank === 1 ? ' has' : 'ren have'} no mark and ${unsavedBlank === 1 ? 'is' : 'are'} not marked absent. Give each a mark or tick Absent, save, then lock.`
      : null

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
          <div className="mt-3 grid grid-cols-2 gap-2 sm:grid-cols-4">
            <GridStat label="Marked" value={`${scored.length + absentN} of ${rows.length}`}
              sub={blankN > 0 ? `${blankN} still blank` : 'everyone done'} tone={blankN > 0 ? 'due' : 'brand'} />
            <GridStat label="Class average" value={avg == null ? '-' : `${avg}%`}
              sub={absentN ? `${absentN} absent, left out` : 'of those marked'} tone="brand" />
            <GridStat label="Top mark" value={top == null ? '-' : `${top}%`} sub="highest in the class" tone="brand" />
            <GridStat label={`Below ${passPct}%`} value={String(below)}
              sub={below ? 'below the pass mark' : 'nobody below pass'} tone={below ? 'danger' : 'brand'} />
          </div>
          <div className="mt-3 overflow-hidden rounded-lg border border-slate-200 bg-white">
            <table className="w-full text-sm">
              <thead className="bg-slate-50 text-left text-xs uppercase tracking-wide text-slate-500">
                <tr><th className="w-10 px-2 py-2 sm:w-14 sm:px-3">Roll</th><th className="px-2 py-2 sm:px-3">Student</th><th className="w-24 px-2 py-2 sm:w-32 sm:px-3">Marks (/{test.max_marks})</th><th className="w-16 px-2 py-2 sm:w-24 sm:px-3">Absent</th></tr>
              </thead>
              <tbody className="divide-y divide-slate-100">
                {rows.map((r) => {
                  const e = entries[r.enrollment_id] ?? { marks: '', is_absent: false }
                  const bad = !e.is_absent && e.marks !== '' && (Number(e.marks) < 0 || Number(e.marks) > r.max_marks)
                  const dis = e.is_absent || r.is_locked || locked
                  return (
                    <tr key={r.enrollment_id} className={r.is_locked ? 'opacity-60' : ''}>
                      <td className="px-2 py-2 text-slate-500 sm:px-3">{r.roll_no ?? '-'}</td>
                      <td className="px-2 py-2 text-slate-800 sm:px-3">{r.full_name}{r.section_name ? <span className="hidden text-slate-400 sm:inline"> · {r.section_name}</span> : ''}{r.is_locked && <span className="ml-1 text-xs">🔒</span>}</td>
                      <td className="px-2 py-2 sm:px-3">
                        <input type="number" min="0" max={r.max_marks} step="0.5" disabled={dis}
                          value={e.is_absent ? '' : e.marks} onChange={(ev) => upd(r.enrollment_id, { marks: ev.target.value })}
                          inputMode="decimal"
                          className={`w-20 rounded border px-2 py-1.5 text-sm tabular-nums sm:w-24 ${bad ? 'border-danger-400 bg-danger-50' : 'border-slate-300'} disabled:bg-slate-100`} />
                      </td>
                      <td className="px-2 py-2 sm:px-3">
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
              {/* NOT confirm(). Locking a test freezes a class's marks for
                  good, and a browser that has been told to stop showing dialogs
                  from this page returns false from confirm() for ever, so the
                  button would quietly do nothing with no error anywhere. */}
              <button onClick={() => setLocking(true)}
                disabled={lock.isPending || !!lockBlocked}
                title={lockBlocked ?? undefined}
                className="rounded border border-slate-300 px-4 py-2 text-sm font-medium text-slate-700 hover:bg-slate-50 disabled:opacity-60">
                Lock test
              </button>
              {locking && (
                <AskDialog
                  title="Lock this test?"
                  intro={
                    <>
                      Marks for <span className="font-medium">{test.title}</span> can no longer be
                      changed by a teacher. If one turns out to be wrong, the owner or the principal
                      can reopen the test, with a reason that is kept on the school&rsquo;s history.
                    </>
                  }
                  confirmLabel="Lock it"
                  tone="danger"
                  busy={lock.isPending}
                  error={lock.error ? (lock.error as Error).message : null}
                  onCancel={() => setLocking(false)}
                  onSubmit={() => lock.mutate()}
                />
              )}
              {overMax && <span className="text-sm text-danger-600">Some marks are below 0 or above {test.max_marks}.</span>}
              {msg && <span className="text-sm font-medium text-brand-700">{msg}</span>}
              {save.isError && <span className="text-sm text-danger-600">{(save.error as Error).message}</span>}
              {lock.isError && <span className="text-sm text-danger-600">{(lock.error as Error).message}</span>}
            </div>
          )}
          {!locked && lockBlocked && (
            <p className="mt-2 text-xs text-slate-500">To lock: {lockBlocked}</p>
          )}
        </>
      )}
    </div>
  )
}

function GridStat({ label, value, sub, tone }: {
  label: string; value: string; sub: string; tone: 'brand' | 'due' | 'danger'
}) {
  const skin = tone === 'due' ? 'border-due-200 bg-due-50 text-due-900'
    : tone === 'danger' ? 'border-danger-200 bg-danger-50 text-danger-900'
    : 'border-slate-200 bg-white text-slate-900'
  return (
    <div className={`rounded-xl border px-3 py-2 ${skin}`}>
      <div className="text-[11px] font-medium uppercase tracking-wide opacity-70">{label}</div>
      <div className="text-lg font-semibold tabular-nums">{value}</div>
      <div className="text-xs opacity-75">{sub}</div>
    </div>
  )
}

import { useEffect, useState, type ReactNode } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useSearchParams } from 'react-router-dom'
import {
  getCurrentSession, listClasses, listSections, listSubjects,
  listAssessments, createAssessment, getAssessmentMarksheet, enterAssessmentMarks, lockAssessment,
  getMyTeaching, myUnmarkedTests, getSchoolSettings, updateAssessment, deleteMyTest,
  type AssessmentRow, type MyTeachingRow, type UnmarkedTestRow,
} from '@/lib/db'
import { sectionScope, subjectScope, taughtClasses } from '@/lib/teaching'
import { DateChip, SubjectChip } from '@/components/chips'
import { Avatar } from '@/components/Avatar'
import { IconTests } from '@/components/icons'
import { fmtDate, todayISO } from '@/lib/format'
import { useAuth } from '@/auth/AuthProvider'
import { isTeacher } from '@/auth/roles'
import { TestsOverview } from './TestsOverview'
import { LoadError, buttonClass } from '@/components/ui'
import { AskDialog } from '@/components/AskDialog'

const FIELD = 'mt-1 w-full rounded-xl border border-slate-300 bg-white px-3 py-2.5 text-sm focus:border-brand-500 focus:outline-none focus:ring-2 focus:ring-brand-100'
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
        <button onClick={() => setSetting(false)} className={buttonClass({ variant: 'soft', tone: 'neutral', size: 'sm', className: 'mb-3' })}>
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
  const classes = useQuery({ queryKey: ['classes'], queryFn: listClasses, enabled: !isTeach })
  /* WHAT THIS TEACHER TEACHES, NOT ONLY WHAT THEY ARE CLASS TEACHER OF. The
     class list came from fn_my_assignments, the class teacher's table, so a
     subject teacher could not pick a class to set a test for (0151). */
  const teaching = useQuery({ queryKey: ['myTeaching'], queryFn: getMyTeaching, enabled: isTeach })
  const rows = teaching.data ?? []
  const classOptions: { id: string; name: string }[] = isTeach
    ? taughtClasses(rows).map((c) => ({ id: c.class_id, name: c.class_name }))
    : (classes.data ?? []).map((c) => ({ id: c.id, name: c.name }))

  // A link from the teacher's home names the class.
  const [params, setParams] = useSearchParams()
  const [classId, setClassIdState] = useState(() => params.get('classId') ?? '')
  const [selected, setSelected] = useState<AssessmentRow | null>(null)
  const [openId, setOpenId] = useState<string | null>(null)
  const setClassId = (id: string) => {
    setClassIdState(id); setSelected(null)
    const next = new URLSearchParams(params)
    if (id) next.set('classId', id); else next.delete('classId')
    setParams(next, { replace: true })
  }

  useEffect(() => {
    if (classId || classOptions.length !== 1) return
    setClassIdState(classOptions[0].id)
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [classOptions.length])
  // A class from a link that is not in the list is dropped once it has loaded.
  const listLoaded = isTeach ? !!teaching.data : !!classes.data
  useEffect(() => {
    if (classId && listLoaded && !classOptions.some((c) => c.id === classId)) setClassIdState('')
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [classId, listLoaded])

  const tests = useQuery({
    queryKey: ['assessments', sessionId, classId],
    queryFn: () => listAssessments(sessionId!, classId), enabled: !!sessionId && !!classId,
    refetchOnWindowFocus: true,
  })
  const late = useQuery({
    queryKey: ['myUnmarkedTests', sessionId],
    queryFn: () => myUnmarkedTests(sessionId!),
    enabled: !!sessionId && isTeach,
    refetchOnWindowFocus: true,
  })
  const lateById = new Map((late.data ?? []).map((r) => [r.assessment_id, r]))

  // A reminder opens its test once the class's list has loaded.
  useEffect(() => {
    if (!openId || !tests.data) return
    const t = tests.data.find((x) => x.id === openId)
    if (t) { setSelected(t); setOpenId(null) }
  }, [openId, tests.data])

  // Split on the DATE, not on whether marks exist. A test dated today counts
  // as sat: the paper may be collected at lunchtime and marked the same day,
  // and the database allows marks from the day itself.
  const today = todayISO()
  const all = tests.data ?? []
  const coming = all.filter((t) => t.assessment_date != null && t.assessment_date > today)
    .sort((a, b) => (a.assessment_date ?? '').localeCompare(b.assessment_date ?? ''))
  const open = all.filter((t) => !t.is_locked && (t.assessment_date == null || t.assessment_date <= today))
  const locked = all.filter((t) => t.is_locked)
  const [allLocked, setAllLocked] = useState(false)

  if (selected) {
    return (
      <MarksGrid test={selected} onBack={() => { setSelected(null); void late.refetch() }} />
    )
  }

  return (
    <div>
      <LoadError of={[session, classes, teaching, tests]} what="Your tests" />
      <div className="flex flex-wrap items-end justify-between gap-3">
        <div>
          <h1 className="text-xl font-bold text-slate-900">Tests</h1>
          <p className="mt-0.5 text-sm text-slate-500">Daily, weekly and monthly class tests. Separate from formal exams.</p>
        </div>
      </div>

      {isTeach && (late.data?.length ?? 0) > 0 && (
        <UnmarkedReminder rows={late.data ?? []}
          onPick={(r) => { setClassId(r.class_id); setOpenId(r.assessment_id) }} />
      )}

      {/* Buttons, not a dropdown: a teacher has two or three classes, and a
          row of them is one tap where a select was two. */}
      <div className="mt-4">
        {classOptions.length === 0 && listLoaded ? (
          <p className="rounded-2xl bg-due-50 p-3 text-sm text-due-800 ring-1 ring-due-200">
            No class or subject is assigned to you yet. The office assigns them in Staff.
          </p>
        ) : classOptions.length > 10 ? (
          <label className="block max-w-xs">
            <span className="text-sm text-slate-600">Class</span>
            <select value={classId} onChange={(e) => setClassId(e.target.value)} className={FIELD}>
              <option value="">Select class…</option>
              {classOptions.map((c) => <option key={c.id} value={c.id}>{c.name}</option>)}
            </select>
          </label>
        ) : (
          <div className="flex flex-wrap gap-2" role="group" aria-label="Class">
            {classOptions.map((c) => {
              const on = c.id === classId
              return (
                <button key={c.id} type="button" onClick={() => setClassId(c.id)} aria-pressed={on}
                  style={{ touchAction: 'manipulation' }}
                  className={`rounded-full px-4 py-2 text-sm font-semibold ring-1 transition active:scale-[0.98] ${
                    on ? 'bg-brand-600 text-white shadow-sm ring-brand-600' : 'bg-white text-slate-700 shadow-sm ring-slate-200 hover:bg-brand-50 hover:text-brand-800'}`}>
                  {c.name}
                </button>
              )
            })}
          </div>
        )}
      </div>

      {classId && sessionId && (
        <div className="mt-5 grid grid-cols-1 gap-5 lg:grid-cols-[minmax(0,1fr)_21rem] lg:items-start">
          <div className="min-w-0 space-y-5">
            {tests.isLoading && <div className="h-32 animate-pulse rounded-3xl bg-white shadow-card ring-1 ring-slate-200/70" />}
            {tests.data?.length === 0 && (
              <div className="rounded-3xl border border-dashed border-slate-300 bg-white/60 p-6 text-center text-sm text-slate-500">
                No tests yet for this class. Set one with the form{' '}
                <span className="hidden lg:inline">on the right</span><span className="lg:hidden">below</span>.
              </div>
            )}

            {/* SCHEDULED TESTS ARE LISTED SEPARATELY, and it is not decoration.
                Since 0135 the database refuses marks before the day, so a test
                set for Saturday in the same list as last Tuesday's meant a
                teacher tapping it and being refused with no way to have known. */}
            {coming.length > 0 && (
              <TestGroup title="Coming up" hint="Marks can be entered from the day of the test.">
                {coming.map((t) => (
                  <TestCard key={t.id} t={t} today={today} late={lateById.get(t.id)} isTeach={isTeach} />
                ))}
              </TestGroup>
            )}

            {open.length > 0 && (
              <TestGroup title="To mark and lock" hint="Tap a test to enter its marks. Lock it when every child has a mark or is absent.">
                {open.map((t) => (
                  <TestCard key={t.id} t={t} today={today} late={lateById.get(t.id)} isTeach={isTeach}
                    onOpen={() => setSelected(t)} />
                ))}
              </TestGroup>
            )}

            {locked.length > 0 && (
              <TestGroup title="Locked" hint="Finished. The owner or the principal can reopen one if a mark is wrong.">
                {(allLocked ? locked : locked.slice(0, 5)).map((t) => (
                  <TestCard key={t.id} t={t} today={today} isTeach={isTeach} onOpen={() => setSelected(t)} />
                ))}
                {locked.length > 5 && (
                  <button type="button" onClick={() => setAllLocked((v) => !v)}
                    className={buttonClass({ variant: 'soft', tone: 'neutral', size: 'sm', className: 'w-full' })}>
                    {allLocked ? 'Show fewer' : `Show all ${locked.length} locked tests`}
                  </button>
                )}
              </TestGroup>
            )}
          </div>
          <NewTest key={classId} sessionId={sessionId} classId={classId} isTeach={isTeach} teaching={rows}
            onOpen={(t) => setSelected(t)} />
        </div>
      )}
    </div>
  )
}

function TestGroup({ title, hint, children }: { title: string; hint: string; children: ReactNode }) {
  return (
    <section>
      <h2 className="text-sm font-semibold text-slate-900">{title}</h2>
      <p className="mb-2 text-xs text-slate-500">{hint}</p>
      <ul className="space-y-2">{children}</ul>
    </section>
  )
}

/**
 * One test in the list, with the state it is in. Each state has its own
 * colour and word, so the list reads as a to-do list rather than a log.
 */
function TestCard({ t, today, late, isTeach, onOpen }: {
  t: AssessmentRow; today: string; late?: UnmarkedTestRow; isTeach: boolean; onOpen?: () => void
}) {
  const qc = useQueryClient()
  const [editing, setEditing] = useState(false)
  const scheduled = t.assessment_date != null && t.assessment_date > today
  const days = t.assessment_date ? daysBetweenISO(today, t.assessment_date) : 0
  const state = t.is_locked ? { word: 'Locked', skin: 'bg-slate-100 text-slate-700 ring-slate-200' }
    : scheduled ? { word: days === 1 ? 'Tomorrow' : `In ${days} days`, skin: 'bg-sky-50 text-sky-800 ring-sky-200' }
      : late ? { word: `${late.marked} of ${late.pupils} marked`, skin: 'bg-due-50 text-due-800 ring-due-200' }
        : t.assessment_date === today ? { word: 'Today', skin: 'bg-brand-600 text-white ring-brand-600' }
          : { word: 'Marked, not locked', skin: 'bg-brand-50 text-brand-800 ring-brand-200' }

  return (
    <li className="rounded-2xl bg-white shadow-card ring-1 ring-slate-200/70">
      <div className="flex items-start gap-3 p-3">
        <DateChip date={t.assessment_date} tone={t.is_locked ? 'slate' : late ? 'due' : 'brand'} />
        <button type="button" onClick={onOpen} disabled={!onOpen}
          className="min-w-0 flex-1 text-left disabled:cursor-default">
          <span className="block break-words text-sm font-semibold text-slate-900">{t.title}</span>
          <span className="mt-1 flex flex-wrap items-center gap-1.5 text-xs text-slate-500">
            {t.subject_name ? <SubjectChip name={t.subject_name} /> : <span className="rounded-full bg-slate-100 px-2 py-0.5 font-medium text-slate-600">General</span>}
            {t.section_name && <span>Section {t.section_name}</span>}
            <span>out of {t.max_marks}</span>
          </span>
        </button>
        <div className="flex shrink-0 flex-col items-end gap-1.5">
          <span className={`rounded-full px-2.5 py-0.5 text-[11px] font-semibold ring-1 ${state.skin}`}>{state.word}</span>
          {!t.is_locked && isTeach && (
            <button type="button" onClick={() => setEditing((v) => !v)} aria-expanded={editing}
              className="rounded-full px-2 py-0.5 text-[11px] font-semibold text-brand-700 ring-1 ring-brand-200 hover:bg-brand-50">
              {editing ? 'Close' : 'Edit'}
            </button>
          )}
        </div>
      </div>
      {editing && (
        <EditTest t={t} onDone={() => { setEditing(false); void qc.invalidateQueries({ queryKey: ['assessments'] }); void qc.invalidateQueries({ queryKey: ['myUnmarkedTests'] }); void qc.invalidateQueries({ queryKey: ['myDay'] }) }} />
      )}
    </li>
  )
}

function daysBetweenISO(from: string, to: string): number {
  const a = Date.UTC(+from.slice(0, 4), +from.slice(5, 7) - 1, +from.slice(8, 10))
  const b = Date.UTC(+to.slice(0, 4), +to.slice(5, 7) - 1, +to.slice(8, 10))
  return Math.round((b - a) / 86400000)
}

/**
 * Correct a test, or remove one set by mistake (0151).
 *
 * The database decides what is allowed and says why: a locked test cannot
 * change, the total cannot change once a mark has been saved out of it, and a
 * test with a mark or an absence in it cannot be removed. So the form offers
 * every field and shows the database's own sentence if it refuses.
 */
function EditTest({ t, onDone }: { t: AssessmentRow; onDone: () => void }) {
  const [title, setTitle] = useState(t.title)
  const [date, setDate] = useState(t.assessment_date ?? todayISO())
  const [maxMarks, setMaxMarks] = useState(String(t.max_marks))
  const [removing, setRemoving] = useState(false)
  const save = useMutation({
    mutationFn: () => updateAssessment(t.id, {
      title: title.trim(), assessmentDate: date,
      maxMarks: Number(maxMarks) !== t.max_marks ? Number(maxMarks) : undefined,
    }),
    onSuccess: onDone,
  })
  const remove = useMutation({ mutationFn: () => deleteMyTest(t.id), onSuccess: () => { setRemoving(false); onDone() } })
  const valid = title.trim() !== '' && Number(maxMarks) > 0 && /^\d{4}-\d{2}-\d{2}$/.test(date)

  // The confirm dialog is a form of its own, so it is drawn OUTSIDE this one.
  // Inside it, confirming "Remove it" submitted both forms, since a submit
  // event bubbles through React's tree: the removal also fired Save changes.
  return (
    <>
    <form className="border-t border-slate-100 p-3" onSubmit={(e) => { e.preventDefault(); if (valid) save.mutate() }}>
      <div className="grid grid-cols-2 gap-2 sm:grid-cols-4">
        <label className="col-span-2 block">
          <span className="text-xs text-slate-600">Title</span>
          <input value={title} onChange={(e) => setTitle(e.target.value)} className={FIELD} />
        </label>
        <label className="block">
          <span className="text-xs text-slate-600">Date</span>
          <input type="date" value={date} onChange={(e) => setDate(e.target.value)} className={FIELD} />
        </label>
        <label className="block">
          <span className="text-xs text-slate-600">Total marks</span>
          <input type="number" min="1" inputMode="numeric" value={maxMarks} onChange={(e) => setMaxMarks(e.target.value)} className={FIELD} />
        </label>
      </div>
      {(save.error || remove.error) && (
        <p className="mt-2 text-sm text-danger-700">{((save.error ?? remove.error) as Error).message}</p>
      )}
      <div className="mt-3 flex flex-wrap items-center gap-2">
        <button type="submit" disabled={!valid || save.isPending} className={buttonClass({ size: 'sm' })}>
          {save.isPending ? 'Saving…' : 'Save changes'}
        </button>
        <button type="button" onClick={() => setRemoving(true)} className={buttonClass({ variant: 'soft', tone: 'danger', size: 'sm' })}>
          Remove this test
        </button>
      </div>
    </form>
      {removing && (
        <AskDialog
          title="Remove this test?"
          intro={<>
            <span className="font-medium">{t.title}</span> is taken off the list for good. This is only
            allowed while it has no marks and is not locked, so nothing a parent can see is lost.
          </>}
          confirmLabel="Remove it" tone="danger"
          busy={remove.isPending}
          error={remove.error ? (remove.error as Error).message : null}
          onCancel={() => setRemoving(false)}
          onSubmit={() => remove.mutate()}
        />
      )}
    </>
  )
}

/**
 * Papers you set, that have been sat, that you have not finished marking.
 *
 * WHY IT IS ON THIS SCREEN AND NOT ONLY IN A NOTIFICATION. A test is marked at
 * the teacher's own pace, days after the paper is collected, and what loses
 * marks is marking twenty of thirty-four, being interrupted and never coming
 * back. So "unmarked" means AT LEAST ONE pupil with neither a mark nor an
 * absence. A test dated TODAY is not chased: the paper may be sat this
 * afternoon. Silent when there is nothing outstanding.
 *
 * Each row now opens its test, not just its class.
 */
function UnmarkedReminder({ rows, onPick }: { rows: UnmarkedTestRow[]; onPick: (r: UnmarkedTestRow) => void }) {
  return (
    <div className="mt-4 rounded-3xl bg-gradient-to-br from-due-50 via-white to-white p-4 shadow-card ring-1 ring-due-200">
      <p className="text-sm font-semibold text-due-900">
        {rows.length === 1 ? 'One test is waiting for marks' : `${rows.length} tests are waiting for marks`}
      </p>
      <ul className="mt-2 space-y-1.5">
        {rows.map((r) => (
          <li key={r.assessment_id}>
            <button type="button" onClick={() => onPick(r)}
              className="flex w-full items-center gap-3 rounded-2xl bg-white px-3 py-2 text-left ring-1 ring-due-100 hover:bg-due-50">
              <span className="min-w-0 flex-1">
                <span className="block truncate text-sm font-semibold text-slate-900">{r.title}</span>
                <span className="block text-xs text-slate-500">
                  {r.class_name}{r.section_name ? ` ${r.section_name}` : ''}{r.subject_name ? ` · ${r.subject_name}` : ''}
                  {' · '}{fmtDate(r.assessment_date)} · {r.days_late} day{r.days_late === 1 ? '' : 's'} ago
                </span>
              </span>
              <span className="shrink-0 rounded-full bg-due-100 px-2.5 py-0.5 text-[11px] font-semibold text-due-900">
                {r.marked} of {r.pupils}
              </span>
            </button>
          </li>
        ))}
      </ul>
    </div>
  )
}

function NewTest({ sessionId, classId, isTeach, teaching, onOpen }: {
  sessionId: string; classId: string; isTeach: boolean; teaching: MyTeachingRow[]; onOpen: (t: AssessmentRow) => void
}) {
  const qc = useQueryClient()
  const subjects = useQuery({ queryKey: ['subjects', classId], queryFn: () => listSubjects(classId) })
  const sections = useQuery({ queryKey: ['sections', classId], queryFn: () => listSections(classId) })
  const [title, setTitle] = useState('')
  const [subjectId, setSubjectId] = useState('')
  const [sectionId, setSectionId] = useState('')
  const [date, setDate] = useState(todayISO())
  const [maxMarks, setMaxMarks] = useState('20')
  const [made, setMade] = useState<AssessmentRow | null>(null)

  /* The same rule as the database (lib/teaching.ts): a section's teacher picks
     their section and never "All"; a subject teacher picks their subject; only
     a class teacher may leave the subject empty. */
  const sScope = isTeach ? sectionScope(teaching, classId) : { whole: true, ids: null }
  const sectionChoices = (sections.data ?? []).filter((x) => !sScope.ids || sScope.ids.has(x.id))
  const hasSections = (sections.data ?? []).length > 0
  const mustPickSection = hasSections && !sScope.whole
  const subj = isTeach ? subjectScope(teaching, classId, sectionId || null) : { any: true, ids: new Set<string>() }
  const subjectChoices = (subjects.data ?? []).filter((x) => subj.any || subj.ids.has(x.id))

  // Re-run when the teacher's list arrives, not only when the sections do: the
  // form can load before it, and a section picked from an empty list was
  // never picked at all, so a class teacher was told no subject was theirs.
  useEffect(() => {
    if (sectionId && !sectionChoices.some((x) => x.id === sectionId)) setSectionId('')
    else if (mustPickSection && !sectionId && sectionChoices.length) setSectionId(sectionChoices[0].id)
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [mustPickSection, sections.data, teaching, sectionId])
  useEffect(() => {
    if (subjectId && !subjectChoices.some((x) => x.id === subjectId)) setSubjectId('')
    else if (!subj.any && !subjectId && subjectChoices.length === 1) setSubjectId(subjectChoices[0].id)
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [sectionId, subjects.data, teaching])

  const create = useMutation({
    mutationFn: () => createAssessment({
      sessionId, classId, subjectId: subjectId || null, sectionId: sectionId || null,
      title: title.trim(), assessmentDate: date, maxMarks: Number(maxMarks),
    }),
    onSuccess: (id) => {
      const subject = (subjects.data ?? []).find((x) => x.id === subjectId)
      const section = (sections.data ?? []).find((x) => x.id === sectionId)
      setMade({
        id, title: title.trim(), assessment_date: date, max_marks: Number(maxMarks),
        section_id: sectionId || null, section_name: section?.name ?? null,
        subject_id: subjectId || null, subject_name: subject?.name ?? null, is_locked: false,
      })
      setTitle('')
      void qc.invalidateQueries({ queryKey: ['assessments', sessionId, classId] })
      void qc.invalidateQueries({ queryKey: ['myDay'] })
    },
  })

  // A date is required: the database refuses a test with none, and saying so
  // after the press loses what was typed. A subject teacher must pick their
  // subject: "no subject" is a class teacher's test.
  const valid = title.trim() !== '' && Number(maxMarks) > 0 && /^\d{4}-\d{2}-\d{2}$/.test(date)
    && (subj.any || !!subjectId) && (!mustPickSection || !!sectionId)

  return (
    <form className="h-fit rounded-3xl bg-white p-4 shadow-card ring-1 ring-slate-200/70 sm:p-5"
      onSubmit={(e) => { e.preventDefault(); if (valid) { setMade(null); create.mutate() } }}>
      <h2 className="flex items-center gap-2.5 text-base font-semibold text-slate-900">
        <span className="flex h-8 w-8 items-center justify-center rounded-xl bg-brand-50 text-brand-600"><IconTests /></span>
        Set a new test
      </h2>
      <label className="mt-3 block">
        <span className="text-sm text-slate-600">Title</span>
        <input value={title} onChange={(e) => { setTitle(e.target.value); setMade(null) }} className={FIELD} placeholder="e.g. Weekly Test 3" />
      </label>
      <div className="mt-2 grid grid-cols-2 gap-2">
        <label className="block">
          <span className="text-sm text-slate-600">Subject</span>
          <select value={subjectId} onChange={(e) => setSubjectId(e.target.value)} className={FIELD}>
            {subj.any ? <option value="">General</option> : <option value="">Select…</option>}
            {subjectChoices.map((x) => <option key={x.id} value={x.id}>{x.name}</option>)}
          </select>
        </label>
        {hasSections ? (
          <label className="block">
            <span className="text-sm text-slate-600">Section</span>
            <select value={sectionId} onChange={(e) => setSectionId(e.target.value)} className={FIELD}>
              {!mustPickSection && <option value="">All sections</option>}
              {sectionChoices.map((x) => <option key={x.id} value={x.id}>{x.name}</option>)}
            </select>
          </label>
        ) : (
          <div className="block">
            <span className="text-sm text-slate-600">Section</span>
            <p className="mt-1 rounded-lg bg-slate-50 px-3 py-2 text-sm text-slate-500">Whole class</p>
          </div>
        )}
        <label className="block">
          <span className="text-sm text-slate-600">Date</span>
          {/* NO `max`. A future date is the scheduling feature; the database
              bounds it to the academic year and a year ahead, which catches a
              mistyped year without refusing "next Saturday". */}
          <input type="date" value={date} onChange={(e) => setDate(e.target.value)} className={FIELD} />
        </label>
        <label className="block">
          <span className="text-sm text-slate-600">Total marks</span>
          <input type="number" min="1" inputMode="numeric" value={maxMarks} onChange={(e) => setMaxMarks(e.target.value)} className={FIELD} />
        </label>
      </div>
      {date > todayISO() && (
        <p className="mt-2 rounded-xl bg-sky-50 px-3 py-2 text-xs text-sky-900 ring-1 ring-sky-100">
          Scheduled. Marks can be entered from {fmtDate(date)}.
        </p>
      )}
      {!subj.any && subjectChoices.length === 0 && subjects.isSuccess && (
        <p className="mt-2 text-xs text-due-800">None of this class&rsquo;s subjects is assigned to you here. Ask the office.</p>
      )}
      {create.isError && <p className="mt-2 text-sm text-danger-600">{(create.error as Error).message}</p>}
      <button type="submit" disabled={!valid || create.isPending}
        className={buttonClass({ className: 'mt-3 w-full py-2.5' })}>
        {create.isPending ? 'Setting…' : 'Set the test'}
      </button>
      {made && (
        <div className="mt-3 rounded-2xl bg-money-50 px-3 py-2.5 text-sm text-money-900 ring-1 ring-money-200">
          <p className="font-semibold">{made.title} is set.</p>
          {made.assessment_date && made.assessment_date <= todayISO() ? (
            <button type="button" onClick={() => onOpen(made)} className={buttonClass({ size: 'sm', className: 'mt-2' })}>
              Enter the marks now
            </button>
          ) : (
            <p className="text-xs">It is under Coming up until {fmtDate(made.assessment_date)}.</p>
          )}
        </div>
      )}
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
    // message on every load wiped "Saved 25" the instant it appeared.
    setEntries(next)
  }, [marksheet.data])

  const save = useMutation({
    mutationFn: () => enterAssessmentMarks(test.id, rows.map((r) => {
      const e = entries[r.enrollment_id]
      return { enrollment_id: r.enrollment_id, marks: e?.is_absent || e?.marks === '' ? null : Number(e.marks), is_absent: !!e?.is_absent }
    })),
    onSuccess: (res) => {
      setMsg(`Saved ${res.marked}${res.skipped ? ` · ${res.skipped} skipped` : ''}.`)
      void qc.invalidateQueries({ queryKey: ['assessmentMarks', test.id] })
      void qc.invalidateQueries({ queryKey: ['myUnmarkedTests'] })
      void qc.invalidateQueries({ queryKey: ['myDay'] })
    },
  })
  const lock = useMutation({
    mutationFn: () => lockAssessment(test.id),
    onSuccess: () => {
      setLocking(false)
      void qc.invalidateQueries({ queryKey: ['assessments'] })
      void qc.invalidateQueries({ queryKey: ['myUnmarkedTests'] })
      void qc.invalidateQueries({ queryKey: ['myDay'] })
      onBack()
    },
  })

  function upd(id: string, patch: Partial<Entry>) { setEntries((m) => ({ ...m, [id]: { ...m[id], ...patch } })); setMsg(null) }
  const overMax = rows.some((r) => { const e = entries[r.enrollment_id]; return e && !e.is_absent && e.marks !== '' && (Number(e.marks) < 0 || Number(e.marks) > r.max_marks) })

  // What the grid says NOW, as it is typed. The pass mark is the school's own
  // (Settings), 33 if unreadable.
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
  // database locks what is stored, and since 0147 refuses any child unmarked.
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

  // Enter moves to the next child's mark, the way a teacher reads down a pile
  // of papers, instead of reaching for the next box with a thumb.
  function nextOnEnter(e: React.KeyboardEvent<HTMLInputElement>, i: number) {
    if (e.key !== 'Enter') return
    e.preventDefault()
    const next = document.querySelector<HTMLInputElement>(`[data-mark-idx="${i + 1}"]:not([disabled])`)
    if (next) next.focus(); else (e.target as HTMLInputElement).blur()
  }
  // Finishing a test means every child has a mark or an absence. After the
  // marks are in, the blanks are nearly always the children who were away.
  function blanksAbsent() {
    setEntries((m) => {
      const out = { ...m }
      for (const r of rows) {
        const e = out[r.enrollment_id] ?? { marks: '', is_absent: false }
        if (!r.is_locked && !e.is_absent && e.marks === '') out[r.enrollment_id] = { marks: '', is_absent: true }
      }
      return out
    })
    setMsg(null)
  }

  return (
    <div>
      <button onClick={onBack} className={buttonClass({ variant: 'soft', tone: 'neutral', size: 'sm' })}>&larr; Back to tests</button>

      <div className="mt-3 flex flex-wrap items-start justify-between gap-3 rounded-3xl bg-gradient-to-br from-brand-700 via-brand-600 to-violet-600 p-4 text-white shadow-card sm:p-5">
        <div className="min-w-0">
          <h1 className="break-words text-xl font-bold">{test.title}</h1>
          <p className="mt-1 flex flex-wrap items-center gap-1.5 text-sm text-white/85">
            {test.subject_name && <span className="rounded-full bg-white/20 px-2 py-0.5 text-xs font-semibold">{test.subject_name}</span>}
            {test.section_name && <span>Section {test.section_name}</span>}
            <span>out of {test.max_marks}</span>
            {test.assessment_date && <span>{fmtDate(test.assessment_date)}</span>}
          </p>
        </div>
        {locked && <span className="rounded-full bg-white/20 px-3 py-1 text-xs font-semibold">Locked</span>}
      </div>

      {marksheet.isLoading && <div className="mt-4 h-40 animate-pulse rounded-3xl bg-white shadow-card ring-1 ring-slate-200/70" />}
      {rows.length === 0 && !marksheet.isLoading && <p className="mt-4 text-sm text-slate-500">No active pupils for this test.</p>}
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

          {!locked && blankN > 0 && scored.length > 0 && (
            <button type="button" onClick={blanksAbsent} className={buttonClass({ variant: 'soft', tone: 'neutral', size: 'sm', className: 'mt-3' })}>
              Mark the {blankN} blank{blankN === 1 ? '' : 's'} as absent
            </button>
          )}

          {/* One card per pupil on a phone, with a big box and an Absent button a
              thumb can hit; a table from sm up. */}
          <ul className="mt-3 space-y-2 sm:hidden">
            {rows.map((r, i) => {
              const e = entries[r.enrollment_id] ?? { marks: '', is_absent: false }
              const bad = !e.is_absent && e.marks !== '' && (Number(e.marks) < 0 || Number(e.marks) > r.max_marks)
              const dis = r.is_locked || locked
              return (
                <li key={r.enrollment_id} className={`rounded-2xl bg-white p-3 shadow-card ring-1 ring-slate-200/70 ${dis ? 'opacity-70' : ''}`}>
                  <div className="flex items-center gap-2.5">
                    <Avatar name={r.full_name} size="sm" />
                    <div className="min-w-0 flex-1">
                      <p className="truncate text-sm font-semibold text-slate-900">
                        {r.roll_no != null && <span className="mr-1.5 tabular-nums text-slate-400">{r.roll_no}</span>}{r.full_name}
                      </p>
                      {r.section_name && <p className="text-xs text-slate-400">Section {r.section_name}</p>}
                    </div>
                  </div>
                  <div className="mt-2.5 flex items-center gap-2">
                    <input type="number" min="0" max={r.max_marks} step="0.5" disabled={e.is_absent || dis}
                      data-mark-idx={i} enterKeyHint="next" onKeyDown={(ev) => nextOnEnter(ev, i)}
                      value={e.is_absent ? '' : e.marks} onChange={(ev) => upd(r.enrollment_id, { marks: ev.target.value })}
                      inputMode="decimal" aria-label={`${r.full_name}: marks out of ${r.max_marks}`}
                      placeholder={e.is_absent ? 'Absent' : `out of ${r.max_marks}`}
                      className={`w-full min-w-0 flex-1 rounded-xl border px-3 py-2.5 text-base tabular-nums ${bad ? 'border-danger-400 bg-danger-50' : 'border-slate-300'} disabled:bg-slate-100`} />
                    <button type="button" disabled={dis} aria-pressed={e.is_absent}
                      onClick={() => upd(r.enrollment_id, { is_absent: !e.is_absent })}
                      style={{ touchAction: 'manipulation' }}
                      className={`shrink-0 rounded-xl px-3.5 py-2.5 text-sm font-semibold ring-1 transition ${
                        e.is_absent ? 'bg-danger-600 text-white ring-danger-600' : 'bg-white text-danger-700 ring-danger-200 hover:bg-danger-50'}`}>
                      Absent
                    </button>
                  </div>
                  {bad && <p className="mt-1 text-xs text-danger-700">Between 0 and {r.max_marks}.</p>}
                </li>
              )
            })}
          </ul>

          <div className="mt-3 hidden overflow-hidden rounded-3xl border border-slate-200 bg-white sm:block">
            <table className="w-full text-sm">
              <thead className="bg-slate-50 text-left text-xs uppercase tracking-wide text-slate-500">
                <tr><th className="w-14 px-3 py-2">Roll</th><th className="px-3 py-2">Pupil</th><th className="w-36 px-3 py-2">Marks (/{test.max_marks})</th><th className="w-28 px-3 py-2">Absent</th></tr>
              </thead>
              <tbody className="divide-y divide-slate-100">
                {rows.map((r, i) => {
                  const e = entries[r.enrollment_id] ?? { marks: '', is_absent: false }
                  const bad = !e.is_absent && e.marks !== '' && (Number(e.marks) < 0 || Number(e.marks) > r.max_marks)
                  const dis = e.is_absent || r.is_locked || locked
                  return (
                    <tr key={r.enrollment_id} className={r.is_locked ? 'opacity-60' : ''}>
                      <td className="px-3 py-2 tabular-nums text-slate-500">{r.roll_no ?? '-'}</td>
                      <td className="px-3 py-2">
                        <span className="flex items-center gap-2.5">
                          <Avatar name={r.full_name} size="sm" />
                          <span className="text-slate-800">{r.full_name}{r.section_name ? <span className="text-slate-400"> · {r.section_name}</span> : ''}</span>
                        </span>
                      </td>
                      <td className="px-3 py-2">
                        <input type="number" min="0" max={r.max_marks} step="0.5" disabled={dis}
                          data-mark-idx={i + 10000} onKeyDown={(ev) => {
                            if (ev.key !== 'Enter') return
                            ev.preventDefault()
                            const next = document.querySelector<HTMLInputElement>(`[data-mark-idx="${i + 10001}"]:not([disabled])`)
                            if (next) next.focus(); else (ev.target as HTMLInputElement).blur()
                          }}
                          value={e.is_absent ? '' : e.marks} onChange={(ev) => upd(r.enrollment_id, { marks: ev.target.value })}
                          inputMode="decimal" aria-label={`${r.full_name}: marks out of ${r.max_marks}`}
                          className={`w-24 rounded-xl border px-3 py-1.5 text-sm tabular-nums ${bad ? 'border-danger-400 bg-danger-50' : 'border-slate-300'} disabled:bg-slate-100`} />
                      </td>
                      <td className="px-3 py-2">
                        <button type="button" disabled={r.is_locked || locked} aria-pressed={e.is_absent}
                          aria-label={`${r.full_name}: absent`}
                          onClick={() => upd(r.enrollment_id, { is_absent: !e.is_absent })}
                          className={`rounded-full px-3 py-1 text-xs font-semibold ring-1 transition ${
                            e.is_absent ? 'bg-danger-600 text-white ring-danger-600' : 'bg-white text-danger-700 ring-danger-200 hover:bg-danger-50'} disabled:opacity-60`}>
                          Absent
                        </button>
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
                className={buttonClass({ className: 'w-full py-2.5 sm:w-auto' })}>
                {save.isPending ? 'Saving…' : 'Save marks'}
              </button>
              {/* NOT confirm(). A browser told to stop showing dialogs returns
                  false from confirm() for ever, so the button would quietly do
                  nothing with no error anywhere. */}
              <button onClick={() => setLocking(true)}
                disabled={lock.isPending || !!lockBlocked}
                title={lockBlocked ?? undefined}
                className={buttonClass({ variant: 'soft', tone: 'neutral', className: 'w-full py-2.5 sm:w-auto' })}>
                Lock test
              </button>
              {locking && (
                <AskDialog
                  title="Lock this test?"
                  intro={
                    <>
                      Marks for <span className="font-medium">{test.title}</span> can no longer be
                      changed by a teacher, and parents see them in the portal. If one turns out to be
                      wrong, the owner or the principal can reopen the test, with a reason that is kept
                      on the school&rsquo;s history.
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
  const skin = tone === 'due' ? 'bg-due-50 text-due-900 ring-due-200'
    : tone === 'danger' ? 'bg-danger-50 text-danger-900 ring-danger-200'
    : 'bg-white text-slate-900 ring-slate-200'
  return (
    <div className={`rounded-2xl px-3 py-2.5 shadow-card ring-1 ${skin}`}>
      <div className="text-[11px] font-medium uppercase tracking-wide opacity-70">{label}</div>
      <div className="text-lg font-bold tabular-nums">{value}</div>
      <div className="text-xs opacity-75">{sub}</div>
    </div>
  )
}

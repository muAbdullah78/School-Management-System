import { useEffect, useMemo, useRef, useState } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import {
  listExamSubjects, getMarksheet, enterMarks, getExamPaperProgress, getExamTermOverview,
  type ExamSubjectRow, type MarksheetRow, type MyTeachingRow,
} from '@/lib/db'
import { taughtClasses, paperReach, inReach, type SectionReach } from '@/lib/teaching'
import { fmtDate } from '@/lib/format'
import { Avatar } from '@/components/Avatar'
import { IconLock, IconSearch, IconCheck, IconExams } from '@/components/icons'
import {
  Chip, Panel, PanelHead, Pills, Stat, examRole, useExamBasics, useExamPick, useTeaching, useUnsaved,
  type PillItem,
} from './examKit'
import { useAuth } from '@/auth/AuthProvider'

type Entry = { marks: string; practical: string; is_absent: boolean }

export function MarksEntry() {
  const { profile } = useAuth()
  const who = examRole(profile?.role)
  const teacher = who === 'class_teacher' || who === 'subject_teacher'
  const { terms, classes } = useExamBasics()
  const { termId, classId, setClass } = useExamPick()
  const teaching = useTeaching(teacher)
  const guard = useUnsaved(false, 'marks-shell')

  const term = (terms.data ?? []).find((t) => t.id === termId) ?? null
  // A teacher's classes are the ones they teach anything in; the office has all.
  const classList = teacher
    ? taughtClasses(teaching.data ?? []).map((c) => ({ id: c.class_id, name: c.class_name }))
    : (classes.data ?? []).map((c) => ({ id: c.id, name: c.name }))
  const cls = classList.find((c) => c.id === classId) ?? null

  // One class to choose from is chosen, once the term is in place.
  useEffect(() => {
    if (termId && !cls && classList.length === 1) setClass(classList[0].id)
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [termId, classList.length, cls?.id])

  const overview = useQuery({
    queryKey: ['examOverview', termId], queryFn: () => getExamTermOverview(termId),
    enabled: !!termId && who === 'office',
  })
  const byClass = new Map((overview.data ?? []).map((o) => [o.class_id, o]))

  if (!term) {
    return (
      <Panel><p className="py-6 text-center text-sm text-slate-500">
        Choose an exam term at the top. {who === 'office' ? 'Create one under Setup if there is none.' : ''}
      </p></Panel>
    )
  }

  const classItems: PillItem[] = classList.map((c) => {
    const o = byClass.get(c.id)
    return {
      id: c.id, label: c.name,
      sub: o ? (o.marks_expected ? `${o.marks_entered}/${o.marks_expected} marks` : 'no papers') : undefined,
      dot: o ? (!o.marks_expected ? 'slate' : o.marks_entered >= o.marks_expected ? 'brand' : 'due') : undefined,
    }
  })

  return (
    <div className="space-y-4">
      <Panel>
        <PanelHead icon={<IconExams />} title="Enter marks"
          sub={teacher
            ? 'Your classes and the papers you teach. You see and save only your own sections.'
            : 'Choose a class and a paper. A blank box means not marked yet; Absent scores zero.'} />
        {teacher && teaching.isLoading && <div className="h-10 animate-pulse rounded-2xl bg-slate-100" />}
        {teacher && teaching.isFetched && classList.length === 0 && (
          <p className="rounded-2xl bg-due-50 px-3 py-2 text-sm text-due-800 ring-1 ring-due-200">
            You are not assigned to any class this year. Ask the office to add you under Settings, Staff.
          </p>
        )}
        {classList.length > 0 && (
          <Pills label="Class" value={cls?.id ?? ''} items={classItems}
            onPick={(id) => guard(() => setClass(id))} />
        )}
      </Panel>

      {cls && (
        <PaperPicker key={`${termId}:${cls.id}`} termId={termId} classId={cls.id} className={cls.name}
          teaching={teacher ? (teaching.data ?? []) : null} />
      )}
    </div>
  )
}

function PaperPicker({ termId, classId, className, teaching }: {
  termId: string; classId: string; className: string
  /** null for the office, who marks every paper and every section. */
  teaching: MyTeachingRow[] | null
}) {
  const guard = useUnsaved(false, 'marks-papers')
  const papers = useQuery({
    queryKey: ['examSubjects', termId, classId], queryFn: () => listExamSubjects(termId, classId),
  })
  const progress = useQuery({
    queryKey: ['paperProgress', termId, classId], queryFn: () => getExamPaperProgress(termId, classId),
  })
  const [paperId, setPaperId] = useState('')

  const mine = (papers.data ?? []).map((p) => ({
    paper: p,
    reach: teaching ? paperReach(teaching, classId, p.subject_id) : null,
  })).filter((x) => !x.reach || !x.reach.none)

  // The paper's progress over the sections this person marks.
  const counts = useMemo(() => {
    const m = new Map<string, { pupils: number; entered: number; locked: number }>()
    for (const x of mine) {
      const rows = (progress.data ?? []).filter((r) => r.exam_subject_id === x.paper.id
        && (!x.reach || inReach(x.reach, r.section_id)))
      m.set(x.paper.id, {
        pupils: rows.reduce((a, r) => a + r.pupils, 0),
        entered: rows.reduce((a, r) => a + r.entered, 0),
        locked: rows.reduce((a, r) => a + r.locked, 0),
      })
    }
    return m
  }, [mine, progress.data])

  useEffect(() => {
    if (!paperId && mine.length === 1) setPaperId(mine[0].paper.id)
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [mine.length])

  if (papers.isLoading) return <div className="h-24 animate-pulse rounded-3xl bg-slate-100" />
  if (papers.isError) return <p className="text-sm text-danger-700">{(papers.error as Error).message}</p>
  if (mine.length === 0) {
    return (
      <Panel><p className="py-4 text-center text-sm text-slate-500">
        {(papers.data ?? []).length === 0
          ? `No papers are set up for ${className} in this term yet.${teaching ? ' The office sets them up under Setup.' : ' Add them under Setup.'}`
          : 'None of this class\'s papers is a subject you teach.'}
      </p></Panel>
    )
  }

  const picked = mine.find((x) => x.paper.id === paperId) ?? null
  return (
    <>
      <Panel>
        <div className="mb-2 text-xs font-semibold uppercase tracking-wide text-slate-500">Paper</div>
        <Pills label="Paper" value={paperId}
          onPick={(id) => guard(() => setPaperId(id))}
          items={mine.map(({ paper }) => {
            const c = counts.get(paper.id)
            const done = !!c && c.pupils > 0 && c.entered >= c.pupils
            return {
              id: paper.id,
              label: paper.subject_name + (paper.subject_stream ? ` · ${paper.subject_stream}` : ''),
              sub: c ? (c.locked > 0 ? 'released, locked' : `${c.entered}/${c.pupils}${done ? ' · done' : ''}`) : `out of ${paper.max_marks + paper.practical_max}`,
              dot: !c ? undefined : c.locked > 0 ? 'violet' : done ? 'brand' : c.entered > 0 ? 'due' : 'slate',
            }
          })} />
      </Panel>
      {picked && (
        <MarksSheet key={picked.paper.id} paper={picked.paper} reach={picked.reach}
          teaching={teaching} classId={classId} className={className} termId={termId} />
      )}
    </>
  )
}

function MarksSheet({ paper, reach, teaching, classId, className, termId }: {
  paper: ExamSubjectRow; reach: SectionReach | null; teaching: MyTeachingRow[] | null
  classId: string; className: string; termId: string
}) {
  const qc = useQueryClient()
  const sheet = useQuery({ queryKey: ['marksheet', paper.id], queryFn: () => getMarksheet(paper.id) })

  // A section's teacher sees their own pupils. Before bundle 53 the marksheet
  // carries no section id, so the section's NAME stands in for it.
  const names = useMemo(() => new Set((teaching ?? [])
    .filter((r) => r.class_id === classId && (r.is_class_teacher || r.subject_id === paper.subject_id) && r.section_name)
    .map((r) => r.section_name as string)), [teaching, classId, paper.subject_id])
  const rows = useMemo(() => (sheet.data ?? []).filter((r) => {
    if (!reach) return true
    if (r.section_id !== undefined) return inReach(reach, r.section_id)
    return reach.whole || !r.section_name || names.has(r.section_name)
  }), [sheet.data, reach, names])

  const [entries, setEntries] = useState<Record<string, Entry>>({})
  const [reason, setReason] = useState('')
  const [msg, setMsg] = useState<string | null>(null)
  const [query, setQuery] = useState('')
  const [onlyBlank, setOnlyBlank] = useState(false)
  const maxMarks = paper.max_marks
  const practicalMax = rows[0]?.practical_max ?? paper.practical_max ?? 0
  const hasPractical = practicalMax > 0
  const outOf = maxMarks + practicalMax

  useEffect(() => {
    if (!sheet.data) return
    const next: Record<string, Entry> = {}
    for (const r of sheet.data) {
      next[r.enrollment_id] = {
        marks: r.marks == null ? '' : String(r.marks),
        practical: r.practical_marks == null ? '' : String(r.practical_marks),
        is_absent: r.is_absent,
      }
    }
    // NOT setMsg(null): saving refetches the sheet, and clearing the message
    // here wiped "Saved" the moment it appeared.
    setEntries(next)
    setReason('')
  }, [sheet.data])

  const loaded = (r: MarksheetRow): Entry => ({
    marks: r.marks == null ? '' : String(r.marks),
    practical: r.practical_marks == null ? '' : String(r.practical_marks),
    is_absent: r.is_absent,
  })
  const e = (r: MarksheetRow): Entry => entries[r.enrollment_id] ?? loaded(r)
  const same = (a: Entry, b: Entry) => a.is_absent === b.is_absent
    && (a.is_absent || (a.marks === b.marks && (!hasPractical || a.practical === b.practical)))
  const dirtyRows = rows.filter((r) => !r.is_locked && !same(e(r), loaded(r)))
  const dirty = dirtyRows.length > 0
  useUnsaved(dirty, 'marks-sheet')

  // A correction is a change to a mark that was already there, theory or
  // practical or absence. A first entry is not, and asking for a reason for one
  // would train teachers to type anything to get past the box.
  const hadMark = (r: MarksheetRow) => r.is_absent || r.marks != null || r.practical_marks != null
  const changed = dirtyRows.filter(hadMark)

  const isBlank = (x: Entry) => !x.is_absent && x.marks === '' && (!hasPractical || x.practical === '')
  const bad = (x: Entry, r: MarksheetRow) => !x.is_absent && (
    (x.marks !== '' && (Number(x.marks) < 0 || Number(x.marks) > r.max_marks || Number.isNaN(Number(x.marks))))
    || (hasPractical && x.practical !== '' && (Number(x.practical) < 0 || Number(x.practical) > practicalMax || Number.isNaN(Number(x.practical)))))
  const total = (x: Entry) => x.is_absent ? 0 : Number(x.marks || 0) + (hasPractical ? Number(x.practical || 0) : 0)

  const marked = rows.filter((r) => !isBlank(e(r)))
  const absentN = rows.filter((r) => e(r).is_absent).length
  const scored = marked.filter((r) => !e(r).is_absent)
  const blankN = rows.length - marked.length
  const avg = scored.length && outOf > 0
    ? Math.round((1000 * scored.reduce((a, r) => a + total(e(r)), 0)) / scored.length / outOf) / 10 : null
  const belowPass = marked.filter((r) => total(e(r)) < paper.pass_marks).length
  const anyBad = rows.some((r) => bad(e(r), r))
  const allLocked = rows.length > 0 && rows.every((r) => r.is_locked)

  const shown = rows.filter((r) => {
    if (onlyBlank && !isBlank(e(r))) return false
    const q = query.trim().toLowerCase()
    return !q || r.full_name.toLowerCase().includes(q) || (r.roll_no ?? '').toLowerCase() === q
  })

  function upd(id: string, patch: Partial<Entry>) {
    setMsg(null)
    setEntries((m) => ({ ...m, [id]: { ...(m[id] ?? { marks: '', practical: '', is_absent: false }), ...patch } }))
  }

  const save = useMutation({
    // ONLY THE ROWS THIS PERSON CHANGED. A blank sent now clears a mark (0152),
    // so sending the whole sheet would let a copy opened an hour ago wipe the
    // marks a colleague has entered since: their boxes are blank on the old
    // copy. A row nobody touched here is not sent, and keeps whatever it has.
    mutationFn: () => enterMarks(paper.id, dirtyRows.map((r) => {
      const x = e(r)
      return {
        enrollment_id: r.enrollment_id,
        marks: x.is_absent || x.marks === '' ? null : Number(x.marks),
        practical_marks: hasPractical && !x.is_absent && x.practical !== '' ? Number(x.practical) : null,
        is_absent: x.is_absent,
      }
    }), reason.trim() || null),
    onSuccess: (res) => {
      const blankLeft = rows.filter((r) => !r.is_locked && isBlank(e(r))).length
      const saved = res.written ?? res.marked
      setMsg(`Saved ${saved} mark${saved === 1 ? '' : 's'}${res.cleared ? `, cleared ${res.cleared}` : ''}${blankLeft ? `; ${blankLeft} still blank` : ''}${res.skipped ? `; ${res.skipped} locked, not changed` : ''}.`)
      void qc.invalidateQueries({ queryKey: ['marksheet', paper.id] })
      void qc.invalidateQueries({ queryKey: ['paperProgress', termId, classId] })
      void qc.invalidateQueries({ queryKey: ['examOverview', termId] })
      void qc.invalidateQueries({ queryKey: ['resultReadiness'] })
    },
  })

  // Enter moves down the sheet, which is how marks are read off a pile of
  // papers. The phone and the desktop layouts number their boxes apart.
  const refs = useRef<Record<string, HTMLInputElement | null>>({})
  function next(layout: 'p' | 'd', idx: number) {
    for (let i = idx + 1; i < shown.length + 1; i++) {
      const el = refs.current[`${layout}:${i}`]
      if (el && !el.disabled) { el.focus(); el.select(); return }
    }
  }
  const onKey = (layout: 'p' | 'd', idx: number) => (ev: React.KeyboardEvent<HTMLInputElement>) => {
    if (ev.key === 'Enter') { ev.preventDefault(); next(layout, idx) }
  }

  if (sheet.isLoading) return <div className="h-64 animate-pulse rounded-3xl bg-slate-100" />
  if (sheet.isError) return <Panel><p className="text-sm text-danger-700">{(sheet.error as Error).message}</p></Panel>

  return (
    <section className="overflow-hidden rounded-3xl bg-white shadow-card ring-1 ring-slate-200/70">
      <div className="bg-gradient-to-r from-brand-700 to-violet-700 px-4 py-4 text-white sm:px-5">
        <div className="flex flex-wrap items-start justify-between gap-2">
          <div className="min-w-0">
            <h3 className="text-lg font-semibold">{paper.subject_name}{paper.subject_stream ? ` · ${paper.subject_stream}` : ''}</h3>
            <p className="text-sm text-white/80">
              {className} · out of {maxMarks}{hasPractical ? ` + ${practicalMax} practical` : ''} · pass {paper.pass_marks}
              {paper.exam_date ? ` · ${fmtDate(paper.exam_date)}` : ''}
            </p>
          </div>
          {reach && !reach.whole && (
            <span className="rounded-full bg-white/15 px-2.5 py-1 text-xs font-semibold ring-1 ring-white/25">Your sections only</span>
          )}
        </div>
      </div>

      <div className="p-4 sm:p-5">
        {rows.length === 0 ? (
          <p className="py-6 text-center text-sm text-slate-500">No pupil on this paper{reach ? ' in your sections' : ''}.</p>
        ) : (
          <>
            {allLocked && (
              <p className="mb-3 flex items-start gap-2 rounded-2xl bg-violet-50 px-3 py-2 text-sm text-violet-800 ring-1 ring-violet-200">
                <IconLock className="mt-0.5 h-4 w-4 shrink-0" />
                These results have been released to parents, so the marks are locked. The owner or principal can
                withdraw them under Result Cards to correct one.
              </p>
            )}
            <div className="grid grid-cols-2 gap-2 lg:grid-cols-4">
              <Stat label="Marked" value={`${marked.length}/${rows.length}`}
                sub={blankN ? `${blankN} still blank` : 'everyone done'} tone={blankN ? 'due' : 'brand'} />
              <Stat label="Class average" value={avg == null ? '-' : `${avg}%`}
                sub={absentN ? `${absentN} absent, left out` : `out of ${outOf}`} />
              <Stat label="Below pass" value={belowPass}
                sub={belowPass ? `under ${paper.pass_marks} of ${outOf}` : 'nobody so far'} tone={belowPass ? 'danger' : 'plain'} />
              <Stat label="Absent" value={absentN} sub="scores zero, counts" />
            </div>

            <div className="mt-4 flex flex-wrap items-center gap-2">
              <label className="relative min-w-0 flex-1 sm:max-w-xs">
                <span className="sr-only">Find a pupil</span>
                <IconSearch className="pointer-events-none absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-slate-400" />
                <input value={query} onChange={(ev) => setQuery(ev.target.value)} placeholder="Find by name or roll"
                  className="w-full rounded-xl border border-slate-300 py-2 pl-9 pr-3 text-sm focus:border-brand-500 focus:outline-none focus:ring-2 focus:ring-brand-100" />
              </label>
              <button type="button" aria-pressed={onlyBlank} onClick={() => setOnlyBlank((b) => !b)}
                className={`rounded-xl px-3 py-2 text-xs font-semibold ring-1 transition ${onlyBlank ? 'bg-due-500 text-white ring-due-500' : 'bg-white text-slate-700 ring-slate-300 hover:bg-slate-50'}`}>
                Blanks only{blankN ? ` (${blankN})` : ''}
              </button>
              {blankN > 0 && !allLocked && (
                <button type="button"
                  onClick={() => { for (const r of rows) if (!r.is_locked && isBlank(e(r))) upd(r.enrollment_id, { is_absent: true }) }}
                  className="rounded-xl bg-white px-3 py-2 text-xs font-semibold text-slate-700 ring-1 ring-slate-300 hover:bg-slate-50">
                  Mark the {blankN} blank{blankN === 1 ? '' : 's'} absent
                </button>
              )}
            </div>

            {/* PHONE: one card a pupil, a big box and a big Absent toggle. */}
            <ul className="mt-3 space-y-2 md:hidden">
              {shown.map((r, i) => {
                const x = e(r)
                const wrong = bad(x, r)
                const box = `w-full rounded-xl border px-3 py-2.5 text-base tabular-nums focus:outline-none focus:ring-2 focus:ring-brand-100 disabled:bg-slate-50 disabled:text-slate-400 ${wrong ? 'border-danger-400 bg-danger-50' : 'border-slate-300 focus:border-brand-500'}`
                return (
                  <li key={r.enrollment_id} className={`rounded-2xl p-3 ring-1 ${!same(x, loaded(r)) ? 'bg-due-50/50 ring-due-200' : 'bg-white ring-slate-200'}`}>
                    <div className="flex items-center gap-2.5">
                      <Avatar name={r.full_name} size="sm" />
                      <div className="min-w-0 flex-1">
                        <div className="truncate text-sm font-semibold text-slate-900">{r.full_name}</div>
                        <div className="text-xs text-slate-500">
                          {r.roll_no ? `Roll ${r.roll_no}` : 'No roll'}{r.section_name ? ` · ${r.section_name}` : ''}
                          {r.is_locked && ' · locked'}
                        </div>
                      </div>
                      <button type="button" disabled={r.is_locked} aria-pressed={x.is_absent}
                        onClick={() => upd(r.enrollment_id, { is_absent: !x.is_absent })}
                        style={{ touchAction: 'manipulation' }}
                        className={`shrink-0 rounded-full px-3 py-1.5 text-xs font-semibold ring-1 transition disabled:opacity-50 ${x.is_absent ? 'bg-danger-600 text-white ring-danger-600' : 'bg-white text-slate-600 ring-slate-300'}`}>
                        Absent
                      </button>
                    </div>
                    <div className={`mt-2 grid gap-2 ${hasPractical ? 'grid-cols-3' : 'grid-cols-1'}`}>
                      <label className="block">
                        <span className="text-[11px] font-medium text-slate-500">{hasPractical ? 'Theory' : 'Marks'} / {r.max_marks}</span>
                        <input ref={(el) => { refs.current[`p:${i}`] = el }} type="number" inputMode="decimal" min="0" max={r.max_marks} step="0.5"
                          disabled={x.is_absent || r.is_locked} value={x.is_absent ? '' : x.marks}
                          onChange={(ev) => upd(r.enrollment_id, { marks: ev.target.value })} onKeyDown={onKey('p', i)}
                          aria-label={`${r.full_name}: ${hasPractical ? 'theory' : 'marks'}`} className={box} />
                      </label>
                      {hasPractical && (
                        <label className="block">
                          <span className="text-[11px] font-medium text-slate-500">Practical / {practicalMax}</span>
                          <input type="number" inputMode="decimal" min="0" max={practicalMax} step="0.5"
                            disabled={x.is_absent || r.is_locked} value={x.is_absent ? '' : x.practical}
                            onChange={(ev) => upd(r.enrollment_id, { practical: ev.target.value })}
                            aria-label={`${r.full_name}: practical`} className={box} />
                        </label>
                      )}
                      {hasPractical && (
                        <div>
                          <span className="text-[11px] font-medium text-slate-500">Total</span>
                          <div className="px-1 py-2.5 text-base font-bold tabular-nums text-slate-800">
                            {isBlank(x) ? '-' : total(x)}
                          </div>
                        </div>
                      )}
                    </div>
                    {wrong && <p className="mt-1 text-xs text-danger-700">More than the paper allows, or below zero.</p>}
                  </li>
                )
              })}
            </ul>

            {/* DESKTOP: a table that reads down like the pile of papers. */}
            <div className="mt-3 hidden overflow-x-auto rounded-2xl ring-1 ring-slate-200 md:block">
              <table className="w-full text-sm">
                <thead className="bg-slate-50 text-left text-[11px] font-semibold uppercase tracking-wide text-slate-500">
                  <tr>
                    <th className="w-14 px-3 py-2">Roll</th>
                    <th className="px-3 py-2">Pupil</th>
                    <th className="w-32 px-3 py-2">{hasPractical ? 'Theory' : 'Marks'} / {maxMarks}</th>
                    {hasPractical && <th className="w-32 px-3 py-2">Practical / {practicalMax}</th>}
                    {hasPractical && <th className="w-20 px-3 py-2 text-right">Total</th>}
                    <th className="w-28 px-3 py-2">Absent</th>
                    <th className="w-24 px-3 py-2 text-right">Result</th>
                  </tr>
                </thead>
                <tbody className="divide-y divide-slate-100">
                  {shown.map((r, i) => {
                    const x = e(r)
                    const wrong = bad(x, r)
                    const cell = `w-24 rounded-lg border px-2 py-1.5 text-sm tabular-nums focus:outline-none focus:ring-2 focus:ring-brand-100 disabled:bg-slate-50 disabled:text-slate-400 ${wrong ? 'border-danger-400 bg-danger-50' : 'border-slate-300 focus:border-brand-500'}`
                    const t = total(x)
                    return (
                      <tr key={r.enrollment_id} className={!same(x, loaded(r)) ? 'bg-due-50/40' : r.is_locked ? 'bg-slate-50/60' : ''}>
                        <td className="px-3 py-2 tabular-nums text-slate-500">{r.roll_no ?? '-'}</td>
                        <td className="px-3 py-2">
                          <div className="flex items-center gap-2.5">
                            <Avatar name={r.full_name} size="sm" />
                            <span className="font-medium text-slate-800">{r.full_name}</span>
                            {r.section_name && <span className="text-xs text-slate-400">{r.section_name}</span>}
                            {r.is_locked && <IconLock className="h-3.5 w-3.5 text-violet-500" title="Locked" />}
                          </div>
                        </td>
                        <td className="px-3 py-2">
                          <input ref={(el) => { refs.current[`d:${i}`] = el }} type="number" inputMode="decimal" min="0" max={r.max_marks} step="0.5"
                            disabled={x.is_absent || r.is_locked} value={x.is_absent ? '' : x.marks}
                            onChange={(ev) => upd(r.enrollment_id, { marks: ev.target.value })} onKeyDown={onKey('d', i)}
                            aria-label={`${r.full_name}: ${hasPractical ? 'theory' : 'marks'}`} className={cell} />
                        </td>
                        {hasPractical && (
                          <td className="px-3 py-2">
                            <input type="number" inputMode="decimal" min="0" max={practicalMax} step="0.5"
                              disabled={x.is_absent || r.is_locked} value={x.is_absent ? '' : x.practical}
                              onChange={(ev) => upd(r.enrollment_id, { practical: ev.target.value })}
                              aria-label={`${r.full_name}: practical`} className={cell} />
                          </td>
                        )}
                        {hasPractical && (
                          <td className="px-3 py-2 text-right font-semibold tabular-nums text-slate-700">{isBlank(x) ? '-' : t}</td>
                        )}
                        <td className="px-3 py-2">
                          {/* An explicit control, not "leave it blank": since 0058 a
                              blank means NOT MARKED, and absence is a fact. */}
                          <button type="button" disabled={r.is_locked} aria-pressed={x.is_absent}
                            onClick={() => upd(r.enrollment_id, { is_absent: !x.is_absent })}
                            className={`rounded-full px-3 py-1 text-xs font-semibold ring-1 transition disabled:opacity-50 ${x.is_absent ? 'bg-danger-600 text-white ring-danger-600' : 'bg-white text-slate-600 ring-slate-300 hover:bg-slate-50'}`}>
                            Absent
                          </button>
                        </td>
                        <td className="whitespace-nowrap px-3 py-2 text-right text-xs font-semibold">
                          {isBlank(x) ? <span className="text-slate-400">not marked</span>
                            : t < paper.pass_marks ? <span className="text-danger-600">below pass</span>
                            : <span className="text-brand-700">pass</span>}
                        </td>
                      </tr>
                    )
                  })}
                </tbody>
              </table>
            </div>
            {shown.length === 0 && (
              <p className="mt-3 text-center text-sm text-slate-500">{onlyBlank ? 'No blank boxes left.' : 'No pupil matches that.'}</p>
            )}

            {changed.length > 0 && (
              <div className="mt-4 rounded-2xl bg-due-50 p-3 ring-1 ring-due-200">
                <label className="block text-sm">
                  <span className="font-semibold text-due-900">
                    {changed.length === 1 ? `Correcting ${changed[0].full_name}'s mark` : `Correcting ${changed.length} marks that were already entered`}
                  </span>
                  <span className="mt-1 block text-xs text-due-800">
                    {changed.slice(0, 4).map((r) => {
                      const was = r.is_absent ? 'absent' : `${r.marks ?? '-'}${hasPractical ? ` + ${r.practical_marks ?? '-'}` : ''}`
                      const x = e(r)
                      const now = x.is_absent ? 'absent' : isBlank(x) ? 'blank' : `${x.marks || '-'}${hasPractical ? ` + ${x.practical || '-'}` : ''}`
                      return `${r.full_name}: ${was} → ${now}`
                    }).join(' · ')}
                    {changed.length > 4 && ` · and ${changed.length - 4} more`}
                  </span>
                  <input value={reason} onChange={(ev) => setReason(ev.target.value)} maxLength={200}
                    placeholder="Why? e.g. re-totalled question 7, paper re-checked on request"
                    className="mt-2 block w-full rounded-xl border border-due-300 bg-white px-3 py-2 text-sm focus:border-due-500 focus:outline-none" />
                  <span className="mt-1 block text-xs text-due-700">
                    Recorded against these marks and shown in Reports, Mark Changes. Blank is allowed and is recorded as none given.
                  </span>
                </label>
              </div>
            )}

            {!allLocked && (
              <div className={`mt-4 ${dirty ? 'sticky bottom-0 z-10 -mx-4 border-t border-slate-200 bg-white/95 px-4 py-3 backdrop-blur sm:static sm:mx-0 sm:border-0 sm:bg-transparent sm:p-0' : ''}`}>
                <div className="flex flex-wrap items-center gap-3">
                  <button type="button" onClick={() => save.mutate()} disabled={save.isPending || anyBad || !dirty}
                    className="inline-flex flex-1 items-center justify-center gap-1.5 rounded-xl bg-brand-600 px-5 py-2.5 text-sm font-semibold text-white shadow-sm hover:bg-brand-700 disabled:opacity-50 sm:flex-none">
                    <IconCheck /> {save.isPending ? 'Saving…' : dirty ? `Save ${dirtyRows.length} change${dirtyRows.length === 1 ? '' : 's'}` : 'All saved'}
                  </button>
                  {anyBad && <span className="text-sm text-danger-700">Some marks are below zero or above the paper&rsquo;s total.</span>}
                  {msg && !dirty && <Chip tone="brand">{msg}</Chip>}
                  {save.isError && <span className="text-sm text-danger-700">{(save.error as Error).message}</span>}
                </div>
                <p className="mt-2 hidden text-xs text-slate-500 sm:block">
                  A blank box is <b>not marked yet</b> and keeps the paper out of the pupil&rsquo;s total; emptying a box
                  clears the mark. <b>Absent</b> scores zero and counts. Press Enter to move to the next pupil.
                </p>
              </div>
            )}
          </>
        )}
      </div>
    </section>
  )
}

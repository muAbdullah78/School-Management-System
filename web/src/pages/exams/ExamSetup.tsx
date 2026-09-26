import { useEffect, useMemo, useState } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import {
  listSubjects, createSubject, listExamSubjects, upsertExamSubject, removeExamSubject,
  listClassRoster, setSubjectDetails, getPaperMarksCount, getSchoolSettings,
  saveExamTerm, deleteExamTerm, getExamTermOverview, getExamPaperProgress,
  type ExamSubjectRow, type SubjectRow, type ExamTerm,
} from '@/lib/db'
import { TERM_TYPES } from '@/lib/constants'
import { fmtDate } from '@/lib/format'
import { AskDialog } from '@/components/AskDialog'
import { isMissingFunction } from '@/lib/notInstalled'
import { IconCopy, IconPencil, IconPlus, IconPrint, IconTrash, IconLock, IconExams } from '@/components/icons'
import { DateSheet } from './DateSheet'
import { AdmitCards } from './AdmitCards'
import {
  Chip, FIELD, Meter, Panel, PanelHead, Pills, useExamBasics, useExamPick, useUnsaved,
} from './examKit'

export function ExamSetup() {
  const { session, sessionId, terms, classes } = useExamBasics()
  const { termId, classId, setClass } = useExamPick()
  const term = (terms.data ?? []).find((t) => t.id === termId) ?? null
  const overview = useQuery({
    queryKey: ['examOverview', termId], queryFn: () => getExamTermOverview(termId), enabled: !!termId,
  })
  const byClass = new Map((overview.data ?? []).map((o) => [o.class_id, o]))
  const guard = useUnsaved(false, 'setup-shell')

  return (
    <div className="space-y-5">
      <TermsPanel sessionId={sessionId} session={session.data ?? null} terms={terms.data ?? []} />

      {term && (
        <Panel>
          <PanelHead icon={<IconExams />} title={`Papers for ${term.name}`}
            sub="Choose a class, then include each subject it sits, with its marks, pass mark, date and time." />
          <Pills label="Class" value={classId}
            onPick={(id) => guard(() => setClass(id))}
            items={(classes.data ?? []).map((c) => {
              const o = byClass.get(c.id)
              return {
                id: c.id, label: c.name,
                sub: o ? (o.papers ? `${o.papers} paper${o.papers === 1 ? '' : 's'}` : 'no papers yet') : undefined,
                dot: o ? (o.papers ? 'brand' : 'slate') : undefined,
              }
            })} />
          {classId && (classes.data ?? []).some((c) => c.id === classId) ? (
            // KEYED BY TERM AND CLASS. Without the key the rows kept their state
            // across a term switch, so First Term's numbers sat in Mid Term's
            // boxes, and "Update" wrote them there.
            <PaperSetup key={`${termId}:${classId}`}
              termId={termId} classId={classId} sessionId={sessionId}
              terms={terms.data ?? []}
              termName={term.name}
              className={(classes.data ?? []).find((c) => c.id === classId)?.name ?? '-'}
              released={!!byClass.get(classId) && ((byClass.get(classId)!.released + byClass.get(classId)!.older_released) > 0)} />
          ) : (
            <p className="mt-4 rounded-2xl bg-slate-50 px-3 py-6 text-center text-sm text-slate-500 ring-1 ring-slate-200">
              Pick a class above to set up its papers.
            </p>
          )}
        </Panel>
      )}
    </div>
  )
}

/* ================================================================ terms === */

function TermsPanel({ sessionId, session, terms }: {
  sessionId: string | undefined
  session: { name: string; starts_on?: string | null; ends_on?: string | null } | null
  terms: ExamTerm[]
}) {
  const qc = useQueryClient()
  const { termId, set } = useExamPick()
  const [editing, setEditing] = useState<ExamTerm | 'new' | null>(null)
  const [deleting, setDeleting] = useState<ExamTerm | null>(null)
  const remove = useMutation({
    mutationFn: (id: string) => deleteExamTerm(id),
    onSuccess: (_d, id) => {
      setDeleting(null)
      if (id === termId) set({ term: null, class: null })
      void qc.invalidateQueries({ queryKey: ['examTerms', sessionId] })
    },
  })

  return (
    <Panel>
      <PanelHead icon={<IconExams />} title="Exam terms"
        sub={session ? `The exams of ${session.name}. Pick one above to work in it.` : undefined}
        action={sessionId && editing !== 'new' && (
          <button type="button" onClick={() => setEditing('new')}
            className="inline-flex items-center gap-1.5 rounded-xl bg-brand-600 px-3.5 py-2 text-sm font-medium text-white shadow-sm hover:bg-brand-700">
            <IconPlus /> New term
          </button>
        )} />

      {editing === 'new' && sessionId && (
        <TermForm sessionId={sessionId} session={session} terms={terms} onDone={(id) => {
          setEditing(null)
          if (id) set({ term: id })
        }} />
      )}

      {terms.length === 0 && editing !== 'new' && (
        <p className="rounded-2xl border border-dashed border-slate-300 bg-slate-50 px-4 py-6 text-center text-sm text-slate-500">
          No exam terms yet. Press <b>New term</b> to add First Term, Mid Term or Final Term.
        </p>
      )}

      <ul className="mt-3 grid gap-3 sm:grid-cols-2 xl:grid-cols-3">
        {terms.map((t) => (
          <li key={t.id}>
            {editing !== 'new' && editing?.id === t.id ? (
              <TermForm sessionId={sessionId!} session={session} terms={terms} term={t}
                onDone={() => setEditing(null)} />
            ) : (
              <div className={`flex h-full flex-col rounded-2xl p-3.5 ring-1 transition ${
                t.id === termId ? 'bg-brand-50/60 ring-2 ring-brand-400' : 'bg-white ring-slate-200'}`}>
                <div className="flex items-start justify-between gap-2">
                  <button type="button" onClick={() => set({ term: t.id })}
                    className="min-w-0 text-left focus:outline-none focus-visible:underline">
                    <div className="truncate font-semibold text-slate-900">{t.name}</div>
                    <div className="text-xs text-slate-500">
                      {TERM_TYPES.find((x) => x.value === t.term_type)?.label ?? 'Term'}
                      {' · '}
                      {t.starts_on ? `${fmtDate(t.starts_on)} to ${fmtDate(t.ends_on)}` : 'no dates'}
                    </div>
                  </button>
                  <div className="flex shrink-0 gap-1">
                    <button type="button" onClick={() => setEditing(t)} aria-label={`Edit ${t.name}`}
                      className="flex h-8 w-8 items-center justify-center rounded-lg text-slate-500 hover:bg-slate-100 hover:text-slate-800">
                      <IconPencil />
                    </button>
                    <button type="button" onClick={() => { remove.reset(); setDeleting(t) }} aria-label={`Delete ${t.name}`}
                      className="flex h-8 w-8 items-center justify-center rounded-lg text-slate-500 hover:bg-danger-50 hover:text-danger-700">
                      <IconTrash />
                    </button>
                  </div>
                </div>
                <div className="mt-2.5 flex flex-wrap gap-1.5">
                  {t.id === termId && <Chip tone="solid">Open</Chip>}
                  {t.result_withheld_for_defaulters
                    ? <Chip tone="due" title="A pupil with unpaid fees gets a withheld result card">Withholds over unpaid fees</Chip>
                    : <Chip tone="slate">Does not withhold</Chip>}
                </div>
              </div>
            )}
          </li>
        ))}
      </ul>

      {deleting && (
        <AskDialog
          title={`Delete ${deleting.name}?`}
          intro={<>Only an empty term can be deleted: one with no marks, no result cards and no remarks.
            If it has any, you will be told what to clear first. Nothing is deleted until you press the button.</>}
          confirmLabel="Delete the term" tone="danger"
          busy={remove.isPending}
          error={remove.error ? (remove.error as Error).message : null}
          onCancel={() => setDeleting(null)}
          onSubmit={() => remove.mutate(deleting.id)}
        />
      )}
    </Panel>
  )
}

function TermForm({ sessionId, session, terms, term, onDone }: {
  sessionId: string
  session: { starts_on?: string | null; ends_on?: string | null } | null
  terms: ExamTerm[]
  term?: ExamTerm
  onDone: (id: string | null) => void
}) {
  const qc = useQueryClient()
  // A new term opens on the first type this year does not have yet, already
  // named: after First Term the next one offered is Mid Term, not a blank box.
  const used = new Set(terms.map((t) => t.name.trim().toLowerCase()))
  const suggested = TERM_TYPES.find((x) => x.value !== 'other' && !used.has(x.label.toLowerCase())) ?? TERM_TYPES[TERM_TYPES.length - 1]
  const [name, setName] = useState(term?.name ?? (suggested.value === 'other' ? '' : suggested.label))
  const [named, setNamed] = useState(!!term)
  const [type, setType] = useState(term?.term_type ?? suggested.value)
  const [starts, setStarts] = useState(term?.starts_on ?? '')
  const [ends, setEnds] = useState(term?.ends_on ?? '')
  const [withhold, setWithhold] = useState(term?.result_withheld_for_defaulters ?? true)

  // THE END DATE HAD max={today}, so a term could only be created once it was
  // over. The rules that matter are the order of the dates, that both or neither
  // are given, that they fall inside the year, and one name per year. The
  // database makes the same checks (0152); saying them here says them sooner.
  const clash = terms.some((t) => t.id !== term?.id && t.name.trim().toLowerCase() === name.trim().toLowerCase())
  const yearFrom = session?.starts_on ?? undefined
  const yearTo = session?.ends_on ?? undefined
  const problem = !name.trim() ? null
    : clash ? `This year already has a term called ${name.trim()}.`
    : (!!starts) !== (!!ends) ? 'Give both the start and the end date, or neither.'
    : starts && ends && ends < starts ? 'The term cannot end before it starts.'
    : (yearFrom && starts && starts < yearFrom) || (yearTo && ends && ends > yearTo)
      ? `The dates must fall inside the academic year (${fmtDate(yearFrom)} to ${fmtDate(yearTo)}).`
    : null

  const save = useMutation({
    mutationFn: () => saveExamTerm({
      id: term?.id ?? null, sessionId, name: name.trim(), termType: type,
      startsOn: starts || null, endsOn: ends || null, withhold,
    }),
    onSuccess: (id) => {
      void qc.invalidateQueries({ queryKey: ['examTerms', sessionId] })
      onDone(id)
    },
  })

  return (
    <form className="rounded-2xl bg-slate-50 p-3.5 ring-1 ring-slate-200"
      onSubmit={(e) => { e.preventDefault(); if (name.trim() && !problem) save.mutate() }}>
      <div className="text-sm font-semibold text-slate-800">{term ? `Edit ${term.name}` : 'New exam term'}</div>
      <div className="mt-2 grid gap-3 sm:grid-cols-2">
        <label className="block">
          <span className="text-xs font-medium text-slate-600">Type</span>
          <select value={type} className={FIELD} onChange={(e) => {
            const v = e.target.value
            setType(v)
            // Named after its type until somebody types a name of their own.
            if (!named) setName(TERM_TYPES.find((x) => x.value === v)?.label ?? '')
          }}>
            {TERM_TYPES.map((t) => <option key={t.value} value={t.value}>{t.label}</option>)}
          </select>
        </label>
        <label className="block">
          <span className="text-xs font-medium text-slate-600">Name</span>
          <input value={name} maxLength={80} placeholder="e.g. First Term" className={FIELD}
            onChange={(e) => { setName(e.target.value); setNamed(true) }} />
        </label>
        <label className="block">
          <span className="text-xs font-medium text-slate-600">Starts</span>
          <input type="date" value={starts} min={yearFrom} max={yearTo} className={FIELD}
            onChange={(e) => setStarts(e.target.value)} />
        </label>
        <label className="block">
          <span className="text-xs font-medium text-slate-600">Ends</span>
          <input type="date" value={ends} min={starts || yearFrom} max={yearTo} className={FIELD}
            onChange={(e) => setEnds(e.target.value)} />
        </label>
      </div>
      <label className="mt-3 flex items-start gap-2.5 rounded-xl bg-white p-3 ring-1 ring-slate-200">
        <input type="checkbox" checked={withhold} onChange={(e) => setWithhold(e.target.checked)} className="mt-0.5 h-4 w-4 accent-brand-600" />
        <span className="text-sm">
          <span className="font-medium text-slate-800">Withhold the result of a pupil with unpaid fees</span>
          <span className="block text-xs text-slate-500">
            Their card prints RESULT WITHHELD and the parent portal hides the marks until the fees are
            cleared. Changing this affects cards made from now on.
          </span>
        </span>
      </label>
      {problem && <p className="mt-2 text-sm text-danger-700">{problem}</p>}
      {save.isError && <p className="mt-2 text-sm text-danger-700">{(save.error as Error).message}</p>}
      <div className="mt-3 flex gap-2">
        <button type="submit" disabled={!name.trim() || !!problem || save.isPending}
          className="rounded-xl bg-brand-600 px-4 py-2 text-sm font-medium text-white shadow-sm hover:bg-brand-700 disabled:opacity-50">
          {save.isPending ? 'Saving…' : term ? 'Save changes' : 'Add term'}
        </button>
        <button type="button" onClick={() => onDone(null)}
          className="rounded-xl bg-white px-4 py-2 text-sm font-medium text-slate-700 ring-1 ring-slate-300 hover:bg-slate-50">
          Cancel
        </button>
      </div>
    </form>
  )
}

/* =============================================================== papers === */

function PaperSetup({
  termId, classId, sessionId, terms, termName, className, released,
}: {
  termId: string; classId: string; sessionId?: string; terms: ExamTerm[]
  termName: string; className: string; released: boolean
}) {
  const qc = useQueryClient()
  const subjects = useQuery({ queryKey: ['subjects', classId], queryFn: () => listSubjects(classId) })
  const examSubjects = useQuery({ queryKey: ['examSubjects', termId, classId], queryFn: () => listExamSubjects(termId, classId) })
  const progress = useQuery({
    queryKey: ['paperProgress', termId, classId], queryFn: () => getExamPaperProgress(termId, classId),
  })
  const settings = useQuery({ queryKey: ['schoolSettings'], queryFn: getSchoolSettings })
  const passPct = Number(settings.data?.pass_percent ?? 33) || 33
  const roster = useQuery({
    queryKey: ['classRoster', sessionId, classId], queryFn: () => listClassRoster(sessionId!, classId), enabled: !!sessionId,
  })
  const [newSubj, setNewSubj] = useState('')
  const [show, setShow] = useState<'date' | 'admit' | null>(null)
  const [dirtyRows, setDirtyRows] = useState<Set<string>>(() => new Set())
  useUnsaved(dirtyRows.size > 0, 'papers')
  const [bulkMsg, setBulkMsg] = useState<string | null>(null)
  const [copyFrom, setCopyFrom] = useState('')

  const invalidate = () => {
    void qc.invalidateQueries({ queryKey: ['examSubjects', termId, classId] })
    void qc.invalidateQueries({ queryKey: ['paperProgress', termId, classId] })
    void qc.invalidateQueries({ queryKey: ['examOverview', termId] })
    void qc.invalidateQueries({ queryKey: ['resultReadiness'] })
  }

  const addSubj = useMutation({
    mutationFn: () => createSubject(newSubj.trim(), classId, subjects.data?.length ?? 0),
    onSuccess: () => { setNewSubj(''); void qc.invalidateQueries({ queryKey: ['subjects', classId] }) },
  })

  const papers = examSubjects.data ?? []
  const byId = new Map(papers.map((es) => [es.subject_id, es]))
  const notIn = (subjects.data ?? []).filter((s) => !byId.has(s.id))
  const defaultPass = (total: number) => Math.ceil((total * passPct) / 100)

  // ONE PRESS FOR THE COMMON CASE. A new term meant pressing Include eight
  // times; every subject now goes in at 100 marks with the school's own pass
  // mark, and anything different is changed in its row afterwards.
  const includeAll = useMutation({
    mutationFn: async () => {
      let n = 0
      for (const s of notIn) {
        await upsertExamSubject(termId, classId, s.id, 100, defaultPass(100), 0, null, null)
        n += 1
      }
      return n
    },
    onSuccess: (n) => setBulkMsg(`${n} subject${n === 1 ? '' : 's'} included at 100 marks, pass ${defaultPass(100)}.`),
    onSettled: invalidate,
  })

  // Copy another term's marks and pass marks (not its dates) for the subjects
  // not yet in this one. A subject already set up here is left as it is.
  const copy = useMutation({
    mutationFn: async (fromTerm: string) => {
      const src = await listExamSubjects(fromTerm, classId)
      let copied = 0; let kept = 0
      for (const p of src) {
        if (byId.has(p.subject_id)) { kept += 1; continue }
        await upsertExamSubject(termId, classId, p.subject_id, p.max_marks, p.pass_marks, p.practical_max, null, null)
        copied += 1
      }
      return { copied, kept, found: src.length }
    },
    onSuccess: (r) => {
      setCopyFrom('')
      setBulkMsg(r.found === 0
        ? 'That term has no papers for this class to copy.'
        : `${r.copied} paper${r.copied === 1 ? '' : 's'} copied${r.kept ? `; ${r.kept} already set up here and left as they are` : ''}. Dates were not copied.`)
    },
    onSettled: invalidate,
  })

  const marksOf = useMemo(() => {
    const m = new Map<string, { pupils: number; entered: number }>()
    for (const r of progress.data ?? []) {
      const cur = m.get(r.exam_subject_id) ?? { pupils: 0, entered: 0 }
      cur.pupils += r.pupils; cur.entered += r.entered
      m.set(r.exam_subject_id, cur)
    }
    return m
  }, [progress.data])

  // Both reads before any row: a row built before the papers arrived started
  // from the defaults (100, 33, no date) and pressing Update wrote them over
  // the real paper.
  if (subjects.isLoading || examSubjects.isLoading) {
    return <div className="mt-4 h-40 animate-pulse rounded-2xl bg-slate-100" />
  }
  if (subjects.isError || examSubjects.isError) {
    return <p className="mt-4 text-sm text-danger-700">{((subjects.error ?? examSubjects.error) as Error).message}</p>
  }

  const setRowDirty = (id: string, d: boolean) => setDirtyRows((prev) => {
    if (prev.has(id) === d) return prev
    const next = new Set(prev)
    if (d) next.add(id)
    else next.delete(id)
    return next
  })
  const otherTerms = terms.filter((t) => t.id !== termId)
  const busy = includeAll.isPending || copy.isPending

  return (
    <div className="mt-5">
      {released && (
        <p className="mb-3 flex items-start gap-2 rounded-2xl bg-violet-50 px-3 py-2 text-sm text-violet-800 ring-1 ring-violet-200">
          <IconLock className="mt-0.5 h-4 w-4 shrink-0" />
          These results have been released to parents, so this class&rsquo;s papers are locked. The owner or
          principal can withdraw them under Result Cards to make a change.
        </p>
      )}

      <div className="mb-3 flex flex-wrap items-center gap-2">
        <span className="text-sm font-semibold text-slate-800">{className}</span>
        <Chip tone="brand">{papers.length} of {(subjects.data ?? []).length} subjects in this term</Chip>
        <div className="ml-auto flex flex-wrap gap-2">
          {!released && notIn.length > 0 && (
            <button type="button" disabled={busy} onClick={() => { setBulkMsg(null); includeAll.mutate() }}
              className="inline-flex items-center gap-1.5 rounded-xl bg-brand-600 px-3 py-2 text-xs font-medium text-white shadow-sm hover:bg-brand-700 disabled:opacity-50">
              <IconPlus /> {includeAll.isPending ? 'Including…' : `Include all ${notIn.length}`}
            </button>
          )}
          {!released && otherTerms.length > 0 && notIn.length > 0 && (
            <label className="inline-flex items-center gap-1.5 rounded-xl bg-white px-2 py-1 text-xs text-slate-700 ring-1 ring-slate-300">
              <IconCopy />
              <select value={copyFrom} disabled={busy} aria-label="Copy papers from another term"
                onChange={(e) => { const v = e.target.value; setCopyFrom(v); if (v) { setBulkMsg(null); copy.mutate(v) } }}
                className="bg-transparent py-1 pr-1 text-xs font-medium focus:outline-none">
                <option value="">{copy.isPending ? 'Copying…' : 'Copy from a term…'}</option>
                {otherTerms.map((t) => <option key={t.id} value={t.id}>{t.name}</option>)}
              </select>
            </label>
          )}
          <button type="button" onClick={() => setShow('date')} disabled={papers.length === 0}
            className="inline-flex items-center gap-1.5 rounded-xl bg-white px-3 py-2 text-xs font-medium text-slate-700 ring-1 ring-slate-300 hover:bg-slate-50 disabled:opacity-50">
            <IconPrint /> Date sheet
          </button>
          <button type="button" onClick={() => setShow('admit')} disabled={papers.length === 0 || (roster.data?.length ?? 0) === 0}
            className="inline-flex items-center gap-1.5 rounded-xl bg-white px-3 py-2 text-xs font-medium text-slate-700 ring-1 ring-slate-300 hover:bg-slate-50 disabled:opacity-50">
            <IconPrint /> Admit cards
          </button>
        </div>
      </div>
      {bulkMsg && <p className="mb-3 rounded-xl bg-brand-50 px-3 py-2 text-sm text-brand-800 ring-1 ring-brand-200">{bulkMsg}</p>}
      {(includeAll.isError || copy.isError) && (
        <p className="mb-3 text-sm text-danger-700">{((includeAll.error ?? copy.error) as Error).message}</p>
      )}

      {/* A grid, not a table: on a phone every paper is a card with its fields
          named, on a laptop it lines up in columns under one header. */}
      <div className="hidden grid-cols-[minmax(0,1.7fr)_5.5rem_5.5rem_6.5rem_9.5rem_6.5rem_minmax(0,1.3fr)] gap-3 px-3 pb-1.5 text-[11px] font-semibold uppercase tracking-wide text-slate-500 lg:grid">
        <span>Subject</span><span>Theory</span><span>Practical</span><span>Pass mark</span><span>Date</span><span>Time</span><span className="text-right">In this term</span>
      </div>
      {(subjects.data ?? []).length === 0 && (
        <p className="rounded-2xl bg-slate-50 px-3 py-6 text-center text-sm text-slate-500 ring-1 ring-slate-200">
          This class has no subjects yet. Add one below.
        </p>
      )}
      <ul className="space-y-2">
        {(subjects.data ?? []).map((s) => (
          <PaperRow key={`${s.id}:${byId.get(s.id)?.id ?? 'new'}`} subject={s} termId={termId} classId={classId}
            existing={byId.get(s.id)} marks={byId.get(s.id) ? marksOf.get(byId.get(s.id)!.id) : undefined}
            passPct={passPct} locked={released} onDirty={setRowDirty} onChanged={invalidate} />
        ))}
      </ul>

      <form className="mt-3 flex w-full gap-2 sm:max-w-md"
        onSubmit={(e) => { e.preventDefault(); if (newSubj.trim()) addSubj.mutate() }}>
        <input value={newSubj} onChange={(e) => setNewSubj(e.target.value)} placeholder="Add a subject, e.g. Computer"
          className="min-w-0 flex-1 rounded-xl border border-slate-300 px-3 py-2 text-sm focus:border-brand-500 focus:outline-none focus:ring-2 focus:ring-brand-100" />
        <button type="submit" disabled={!newSubj.trim() || addSubj.isPending}
          className="shrink-0 rounded-xl bg-white px-3 py-2 text-sm font-medium text-slate-700 ring-1 ring-slate-300 hover:bg-slate-50 disabled:opacity-50">
          {addSubj.isPending ? 'Adding…' : 'Add subject'}
        </button>
      </form>
      {addSubj.isError && <p className="mt-1 text-sm text-danger-700">{(addSubj.error as Error).message}</p>}

      {show === 'date' && (
        <DateSheet papers={papers} termName={termName} className={className} onClose={() => setShow(null)} />
      )}
      {show === 'admit' && (
        <AdmitCards roster={roster.data ?? []} papers={papers} termName={termName} className={className} onClose={() => setShow(null)} />
      )}
    </div>
  )
}

function PaperRow({ subject, termId, classId, existing, marks, passPct, locked, onDirty, onChanged }: {
  subject: SubjectRow; termId: string; classId: string; existing?: ExamSubjectRow
  marks?: { pupils: number; entered: number }
  passPct: number; locked: boolean
  onDirty: (id: string, dirty: boolean) => void
  onChanged: () => void
}) {
  const qc = useQueryClient()
  const defaultPass = (total: number) => Math.ceil((total * passPct) / 100)
  const init = () => ({
    max: String(existing?.max_marks ?? 100),
    pmax: String(existing?.practical_max ?? 0),
    pass: String(existing?.pass_marks ?? defaultPass(100)),
    date: existing?.exam_date ?? '',
    time: existing?.paper_time ?? '',
  })
  const [v, setV] = useState(init)
  const [stream, setStream] = useState(subject.stream ?? '')
  const [saved, setSaved] = useState(false)
  const [asking, setAsking] = useState<null | { marks: number; locked: number; unknown: boolean }>(null)
  const included = !!existing
  const dirty = included && (
    v.max !== String(existing!.max_marks) || v.pmax !== String(existing!.practical_max)
    || v.pass !== String(existing!.pass_marks) || v.date !== (existing!.exam_date ?? '')
    || v.time !== (existing!.paper_time ?? ''))
  useEffect(() => { onDirty(subject.id, dirty) }, [dirty, onDirty, subject.id])
  useEffect(() => () => onDirty(subject.id, false), [onDirty, subject.id])

  // A refetch with new numbers (another tab, another person) is shown when
  // nothing here is being typed, and never overwrites what is.
  const serverKey = JSON.stringify([existing?.max_marks, existing?.practical_max, existing?.pass_marks, existing?.exam_date, existing?.paper_time])
  useEffect(() => { if (!dirty) setV(init()) }, [serverKey]) // eslint-disable-line react-hooks/exhaustive-deps

  const total = Number(v.max) + (subject.is_practical ? Number(v.pmax) || 0 : 0)
  // Theory or practical changed: a pass mark that was the school's percentage of
  // the old total follows it to the new one. One that somebody typed stays.
  function setTotal(field: 'max' | 'pmax', value: string) {
    setSaved(false)
    setV((cur) => {
      const oldTotal = Number(cur.max) + (subject.is_practical ? Number(cur.pmax) || 0 : 0)
      const next = { ...cur, [field]: value }
      const newTotal = Number(next.max) + (subject.is_practical ? Number(next.pmax) || 0 : 0)
      if (Number(cur.pass) === defaultPass(oldTotal) && newTotal > 0) next.pass = String(defaultPass(newTotal))
      return next
    })
  }

  const problem = !(Number(v.max) > 0) ? 'The theory paper needs a total above zero.'
    : subject.is_practical && Number(v.pmax) < 0 ? 'The practical cannot be out of less than zero.'
    : !(Number(v.pass) >= 0) ? 'The pass mark cannot be below zero.'
    : Number(v.pass) > total ? `The pass mark (${v.pass}) is more than the paper is out of (${total}), so nobody could pass.`
    : null

  const save = useMutation({
    mutationFn: () => upsertExamSubject(termId, classId, subject.id, Number(v.max), Number(v.pass),
      subject.is_practical ? Number(v.pmax) : 0, v.date || null, v.time || null),
    onSuccess: () => { setSaved(true); onChanged() },
  })
  const remove = useMutation({
    mutationFn: () => removeExamSubject(existing!.id),
    onSuccess: () => { setAsking(null); onChanged() },
  })
  // Ask what Remove would delete BEFORE offering the button that deletes it.
  const count = useMutation({
    mutationFn: () => getPaperMarksCount(existing!.id),
    onSuccess: (c) => setAsking({ ...c, unknown: false }),
    onError: (e) => { if (isMissingFunction(e)) setAsking({ marks: 0, locked: 0, unknown: true }) },
  })
  // Stream and the practical flag belong to the SUBJECT: the same every term.
  const details = useMutation({
    mutationFn: (d: { stream: string; practical: boolean }) => setSubjectDetails(subject.id, d.stream.trim() || null, d.practical),
    onSuccess: () => {
      void qc.invalidateQueries({ queryKey: ['subjects', classId] })
      onChanged()
    },
  })

  const err = (details.isError && (details.error as Error).message)
    || (save.isError && (save.error as Error).message)
    || (remove.isError && !asking && (remove.error as Error).message)
    || (count.isError && !isMissingFunction(count.error) && (count.error as Error).message)
    || (included || dirty ? problem : null)
  const box = (bad = false) => `w-full rounded-lg border px-2.5 py-2 text-sm tabular-nums shadow-sm focus:outline-none focus:ring-2 focus:ring-brand-100 disabled:bg-slate-50 disabled:text-slate-400 lg:py-1.5 ${bad ? 'border-danger-400 bg-danger-50' : 'border-slate-300 focus:border-brand-500'}`
  const off = locked || save.isPending

  return (
    <li className={`rounded-2xl p-3 transition lg:grid lg:grid-cols-[minmax(0,1.7fr)_5.5rem_5.5rem_6.5rem_9.5rem_6.5rem_minmax(0,1.3fr)] lg:items-center lg:gap-3 ${
      !included ? 'border border-dashed border-slate-300 bg-slate-50/70'
        : dirty ? 'bg-white ring-2 ring-due-300' : 'bg-white ring-1 ring-slate-200'}`}>
      <div className="min-w-0">
        <div className="flex items-center gap-2">
          <span className="truncate font-semibold text-slate-900">{subject.name}</span>
          {!included && <Chip tone="slate">not in this term</Chip>}
        </div>
        <div className="mt-1.5 flex flex-wrap items-center gap-x-3 gap-y-1.5">
          <label className="inline-flex items-center gap-1.5 text-xs text-slate-600">
            <input type="checkbox" checked={subject.is_practical} disabled={details.isPending || locked}
              onChange={(e) => details.mutate({ stream, practical: e.target.checked })}
              className="h-3.5 w-3.5 accent-brand-600" />
            has a practical
          </label>
          {/* Blank = every pupil takes it; a value = only that stream's pupils,
              compared without case. */}
          <label className="inline-flex items-center gap-1.5 text-xs text-slate-600">
            Stream
            <input value={stream} disabled={locked} onChange={(e) => setStream(e.target.value)}
              onBlur={() => {
                if ((stream.trim() || null) !== (subject.stream ?? null)) details.mutate({ stream, practical: subject.is_practical })
              }}
              placeholder="all pupils"
              className="w-24 rounded-md border border-slate-300 px-2 py-1 text-xs focus:border-brand-500 focus:outline-none" />
          </label>
        </div>
      </div>

      <div className="mt-3 grid grid-cols-2 gap-2 sm:grid-cols-5 lg:contents">
        <label className="block lg:contents">
          <span className="mb-0.5 block text-[11px] font-medium text-slate-500 lg:hidden">Theory out of</span>
          <input type="number" inputMode="numeric" min="1" value={v.max} disabled={off}
            aria-label={`${subject.name}: theory out of`}
            onChange={(e) => setTotal('max', e.target.value)} className={box()} />
        </label>
        <label className="block lg:contents">
          <span className="mb-0.5 block text-[11px] font-medium text-slate-500 lg:hidden">Practical out of</span>
          {subject.is_practical
            ? <input type="number" inputMode="numeric" min="0" value={v.pmax} disabled={off}
                aria-label={`${subject.name}: practical out of`}
                onChange={(e) => setTotal('pmax', e.target.value)} className={box()} />
            : <span className="block py-2 text-xs text-slate-400 lg:py-0">none</span>}
        </label>
        <label className="block lg:contents">
          <span className="mb-0.5 block text-[11px] font-medium text-slate-500 lg:hidden">Pass mark</span>
          <span className="relative block">
            <input type="number" inputMode="numeric" min="0" max={total || undefined} value={v.pass} disabled={off}
              aria-label={`${subject.name}: pass mark`}
              onChange={(e) => { setV((c) => ({ ...c, pass: e.target.value })); setSaved(false) }}
              className={box(!!problem && (included || dirty))} />
            <span className="mt-0.5 block text-[10px] text-slate-400 lg:absolute lg:left-0 lg:top-full">
              {total > 0 && Number(v.pass) >= 0 ? `${Math.round((100 * Number(v.pass)) / total)}% of ${total}` : ''}
            </span>
          </span>
        </label>
        <label className="block lg:contents">
          <span className="mb-0.5 block text-[11px] font-medium text-slate-500 lg:hidden">Date</span>
          <input type="date" value={v.date} disabled={off} aria-label={`${subject.name}: date`}
            onChange={(e) => { setV((c) => ({ ...c, date: e.target.value })); setSaved(false) }} className={box()} />
        </label>
        <label className="block lg:contents">
          <span className="mb-0.5 block text-[11px] font-medium text-slate-500 lg:hidden">Time</span>
          <input value={v.time} disabled={off} placeholder="9:00 AM" maxLength={20} aria-label={`${subject.name}: time`}
            onChange={(e) => { setV((c) => ({ ...c, time: e.target.value })); setSaved(false) }} className={box()} />
        </label>
      </div>

      <div className="mt-3 flex flex-wrap items-center justify-end gap-2 lg:mt-0">
        {included && marks && (
          <span className="mr-auto w-full text-xs text-slate-500 lg:mr-0 lg:w-auto lg:text-right">
            {marks.entered}/{marks.pupils} marked
            <Meter value={marks.entered} max={marks.pupils} className="mt-1 lg:w-24" />
          </span>
        )}
        {dirty && <Chip tone="due">Unsaved</Chip>}
        {saved && !dirty && !save.isPending && <Chip tone="brand">Saved</Chip>}
        {!locked && (!included || dirty) && (
          <button type="button" onClick={() => save.mutate()} disabled={save.isPending || !!problem}
            className="rounded-xl bg-brand-600 px-3 py-1.5 text-xs font-semibold text-white shadow-sm hover:bg-brand-700 disabled:opacity-50">
            {save.isPending ? 'Saving…' : included ? 'Save' : 'Include'}
          </button>
        )}
        {!locked && included && (
          <button type="button" onClick={() => count.mutate()} disabled={remove.isPending || count.isPending}
            aria-label={`Remove ${subject.name} from this term`}
            className="flex h-8 w-8 items-center justify-center rounded-lg text-slate-500 ring-1 ring-slate-200 hover:bg-danger-50 hover:text-danger-700 disabled:opacity-50">
            <IconTrash />
          </button>
        )}
      </div>

      {err && <p className="mt-2 text-xs text-danger-700 lg:col-span-7">{err}</p>}

      {asking && (
        <AskDialog
          title={`Remove ${subject.name} from this term?`}
          intro={
            asking.locked > 0 ? (
              <>This paper has <b>{asking.locked}</b> locked mark{asking.locked === 1 ? '' : 's'}, because its
                results have been released. Withdraw the results under Result Cards first.</>
            ) : asking.unknown ? (
              <>Any marks already entered on this paper are deleted with it, and cannot be brought back.</>
            ) : asking.marks > 0 ? (
              <><b>{asking.marks}</b> mark{asking.marks === 1 ? ' has' : 's have'} already been entered on this paper.
                Removing it deletes {asking.marks === 1 ? 'that mark' : 'all of them'}, and they cannot be brought
                back. Result cards already made keep their copy.</>
            ) : (
              <>No marks have been entered on it yet, so nothing else is lost.</>
            )
          }
          confirmLabel={asking.locked > 0 ? 'Close' : asking.marks > 0 ? `Remove it and delete ${asking.marks} mark${asking.marks === 1 ? '' : 's'}` : 'Remove it'}
          tone={asking.locked > 0 ? 'brand' : 'danger'}
          busy={remove.isPending}
          error={remove.error ? (remove.error as Error).message : null}
          onCancel={() => setAsking(null)}
          onSubmit={() => (asking.locked > 0 ? setAsking(null) : remove.mutate())}
        />
      )}
    </li>
  )
}

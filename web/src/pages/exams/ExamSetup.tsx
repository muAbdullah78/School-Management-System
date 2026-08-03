import { useState } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import {
  getCurrentSession, listClasses, listExamTerms, createExamTerm,
  listSubjects, createSubject, listExamSubjects, upsertExamSubject, removeExamSubject,
  listClassRoster,
  type ExamSubjectRow, type SubjectRow,
} from '@/lib/db'
import { TERM_TYPES } from '@/lib/constants'
import { fmtDate, todayISO } from '@/lib/format'
import { DateSheet } from './DateSheet'
import { AdmitCards } from './AdmitCards'

const FIELD = 'mt-1 w-full rounded border border-slate-300 px-3 py-2 text-sm focus:border-brand-500 focus:outline-none focus:ring-1 focus:ring-brand-500'

export function ExamSetup() {
  const qc = useQueryClient()
  const session = useQuery({ queryKey: ['currentSession'], queryFn: getCurrentSession })
  const sessionId = session.data?.id
  const terms = useQuery({ queryKey: ['examTerms', sessionId], queryFn: () => listExamTerms(sessionId!), enabled: !!sessionId })
  const classes = useQuery({ queryKey: ['classes'], queryFn: listClasses })

  const [name, setName] = useState('')
  const [type, setType] = useState('first')
  const [starts, setStarts] = useState('')
  const [ends, setEnds] = useState('')
  const addTerm = useMutation({
    mutationFn: () => createExamTerm(sessionId!, name.trim(), type, starts, ends),
    onSuccess: () => { setName(''); setStarts(''); setEnds(''); qc.invalidateQueries({ queryKey: ['examTerms', sessionId] }) },
  })

  const [termId, setTermId] = useState('')
  const [classId, setClassId] = useState('')

  return (
    <div className="space-y-8">
      {!session.data && !session.isLoading && (
        <p className="rounded bg-amber-50 p-3 text-sm text-amber-700">No current academic session. Create one in Settings first.</p>
      )}

      {/* Terms */}
      <section>
        <h2 className="text-sm font-semibold uppercase tracking-wide text-slate-500">Exam terms</h2>
        <div className="mt-2 overflow-hidden rounded-lg border border-slate-200 bg-white">
          {terms.data?.length === 0 && <div className="p-3 text-sm text-slate-500">No terms yet.</div>}
          <ul className="divide-y divide-slate-100">
            {terms.data?.map((t) => (
              <li key={t.id} className="flex items-center justify-between px-3 py-2 text-sm">
                <span className="font-medium text-slate-800">{t.name}</span>
                <span className="text-slate-500">{fmtDate(t.starts_on)} – {fmtDate(t.ends_on)}{t.result_withheld_for_defaulters ? ' · withholds for defaulters' : ''}</span>
              </li>
            ))}
          </ul>
        </div>
        <form className="mt-3 grid gap-3 sm:grid-cols-4" onSubmit={(e) => { e.preventDefault(); if (sessionId && name.trim()) addTerm.mutate() }}>
          <label className="block sm:col-span-2">
            <span className="text-sm text-slate-600">Term name</span>
            <input value={name} onChange={(e) => setName(e.target.value)} className={FIELD} placeholder="e.g. First Term 2025" />
          </label>
          <label className="block">
            <span className="text-sm text-slate-600">Type</span>
            <select value={type} onChange={(e) => setType(e.target.value)} className={FIELD}>
              {TERM_TYPES.map((t) => <option key={t.value} value={t.value}>{t.label}</option>)}
            </select>
          </label>
          <div className="flex items-end">
            <button type="submit" disabled={!sessionId || !name.trim() || addTerm.isPending}
              className="w-full rounded bg-brand-600 px-3 py-2 text-sm font-medium text-white hover:bg-brand-700 disabled:opacity-60">
              {addTerm.isPending ? 'Adding…' : 'Add term'}
            </button>
          </div>
          <label className="block">
            <span className="text-sm text-slate-600">Starts</span>
            <input type="date" value={starts} onChange={(e) => setStarts(e.target.value)} className={FIELD} />
          </label>
          <label className="block">
            <span className="text-sm text-slate-600">Ends</span>
            <input type="date" max={todayISO()} value={ends} onChange={(e) => setEnds(e.target.value)} className={FIELD} />
          </label>
          {addTerm.isError && <p className="text-sm text-red-600 sm:col-span-4">{(addTerm.error as Error).message}</p>}
        </form>
      </section>

      {/* Paper setup */}
      <section>
        <h2 className="text-sm font-semibold uppercase tracking-wide text-slate-500">Subjects & papers</h2>
        <div className="mt-2 grid gap-3 sm:grid-cols-2">
          <label className="block">
            <span className="text-sm text-slate-600">Term</span>
            <select value={termId} onChange={(e) => setTermId(e.target.value)} className={FIELD}>
              <option value="">Select term…</option>
              {terms.data?.map((t) => <option key={t.id} value={t.id}>{t.name}</option>)}
            </select>
          </label>
          <label className="block">
            <span className="text-sm text-slate-600">Class</span>
            <select value={classId} onChange={(e) => setClassId(e.target.value)} className={FIELD}>
              <option value="">Select class…</option>
              {classes.data?.map((c) => <option key={c.id} value={c.id}>{c.name}</option>)}
            </select>
          </label>
        </div>

        {termId && classId && (
          <PaperSetup
            termId={termId} classId={classId} sessionId={sessionId}
            termName={terms.data?.find((t) => t.id === termId)?.name ?? '—'}
            className={classes.data?.find((c) => c.id === classId)?.name ?? '—'}
          />
        )}
      </section>
    </div>
  )
}

function PaperSetup({
  termId, classId, sessionId, termName, className,
}: { termId: string; classId: string; sessionId?: string; termName: string; className: string }) {
  const qc = useQueryClient()
  const subjects = useQuery({ queryKey: ['subjects', classId], queryFn: () => listSubjects(classId) })
  const examSubjects = useQuery({ queryKey: ['examSubjects', termId, classId], queryFn: () => listExamSubjects(termId, classId) })
  const roster = useQuery({
    queryKey: ['classRoster', sessionId, classId], queryFn: () => listClassRoster(sessionId!, classId), enabled: !!sessionId,
  })
  const [newSubj, setNewSubj] = useState('')
  const [show, setShow] = useState<'date' | 'admit' | null>(null)

  const addSubj = useMutation({
    mutationFn: () => createSubject(newSubj.trim(), classId, subjects.data?.length ?? 0),
    onSuccess: () => { setNewSubj(''); qc.invalidateQueries({ queryKey: ['subjects', classId] }) },
  })

  if (subjects.isLoading) return <p className="mt-3 text-sm text-slate-500">Loading subjects…</p>
  const byId = new Map((examSubjects.data ?? []).map((es) => [es.subject_id, es]))
  const papers = examSubjects.data ?? []

  return (
    <div className="mt-4">
      <div className="overflow-hidden rounded-lg border border-slate-200 bg-white">
        <table className="w-full text-sm">
          <thead className="bg-slate-50 text-left text-xs uppercase tracking-wide text-slate-500">
            <tr><th className="px-3 py-2">Subject</th><th className="px-3 py-2 w-24">Max</th><th className="px-3 py-2 w-24">Pass</th><th className="px-3 py-2 w-36">Date</th><th className="px-3 py-2 w-28">Time</th><th className="px-3 py-2 w-40">In this term</th></tr>
          </thead>
          <tbody className="divide-y divide-slate-100">
            {subjects.data?.length === 0 && <tr><td colSpan={6} className="px-3 py-3 text-slate-500">No subjects for this class yet — add one below.</td></tr>}
            {subjects.data?.map((s) => (
              <PaperRow key={s.id} subject={s} termId={termId} classId={classId} existing={byId.get(s.id)} />
            ))}
          </tbody>
        </table>
      </div>

      <div className="mt-3 flex flex-wrap items-center gap-2">
        <form className="flex gap-2" onSubmit={(e) => { e.preventDefault(); if (newSubj.trim()) addSubj.mutate() }}>
          <input value={newSubj} onChange={(e) => setNewSubj(e.target.value)} placeholder="Add subject (e.g. Mathematics)"
            className="w-56 rounded border border-slate-300 px-3 py-2 text-sm focus:border-brand-500 focus:outline-none" />
          <button type="submit" disabled={!newSubj.trim() || addSubj.isPending}
            className="rounded border border-slate-300 px-3 py-2 text-sm font-medium text-slate-700 hover:bg-slate-50 disabled:opacity-60">
            {addSubj.isPending ? 'Adding…' : 'Add subject'}
          </button>
        </form>
        <div className="ml-auto flex gap-2">
          <button onClick={() => setShow('date')} disabled={papers.length === 0}
            className="rounded border border-slate-300 px-3 py-2 text-sm font-medium text-slate-700 hover:bg-slate-50 disabled:opacity-50">
            Print date sheet
          </button>
          <button onClick={() => setShow('admit')} disabled={papers.length === 0 || (roster.data?.length ?? 0) === 0}
            className="rounded border border-slate-300 px-3 py-2 text-sm font-medium text-slate-700 hover:bg-slate-50 disabled:opacity-50">
            Print admit cards
          </button>
        </div>
        {addSubj.isError && <span className="w-full text-sm text-red-600">{(addSubj.error as Error).message}</span>}
      </div>

      {show === 'date' && (
        <DateSheet papers={papers} termName={termName} className={className} onClose={() => setShow(null)} />
      )}
      {show === 'admit' && (
        <AdmitCards roster={roster.data ?? []} papers={papers} termName={termName} className={className} onClose={() => setShow(null)} />
      )}
    </div>
  )
}

function PaperRow({ subject, termId, classId, existing }: { subject: SubjectRow; termId: string; classId: string; existing?: ExamSubjectRow }) {
  const qc = useQueryClient()
  const [max, setMax] = useState(String(existing?.max_marks ?? 100))
  const [pass, setPass] = useState(String(existing?.pass_marks ?? 33))
  const [pdate, setPdate] = useState(existing?.exam_date ?? '')
  const [ptime, setPtime] = useState(existing?.paper_time ?? '')
  const included = !!existing

  const save = useMutation({
    mutationFn: () => upsertExamSubject(termId, classId, subject.id, Number(max), Number(pass), pdate || null, ptime || null),
    onSuccess: () => qc.invalidateQueries({ queryKey: ['examSubjects', termId, classId] }),
  })
  const remove = useMutation({
    mutationFn: () => removeExamSubject(existing!.id),
    onSuccess: () => qc.invalidateQueries({ queryKey: ['examSubjects', termId, classId] }),
  })

  return (
    <tr>
      <td className="px-3 py-2 font-medium text-slate-800">{subject.name}</td>
      <td className="px-3 py-2"><input type="number" min="1" value={max} onChange={(e) => setMax(e.target.value)} className="w-16 rounded border border-slate-300 px-2 py-1 text-sm" /></td>
      <td className="px-3 py-2"><input type="number" min="0" value={pass} onChange={(e) => setPass(e.target.value)} className="w-16 rounded border border-slate-300 px-2 py-1 text-sm" /></td>
      <td className="px-3 py-2"><input type="date" value={pdate} onChange={(e) => setPdate(e.target.value)} className="rounded border border-slate-300 px-2 py-1 text-sm" /></td>
      <td className="px-3 py-2"><input value={ptime} onChange={(e) => setPtime(e.target.value)} placeholder="09:00 AM" className="w-24 rounded border border-slate-300 px-2 py-1 text-sm" /></td>
      <td className="px-3 py-2">
        <div className="flex gap-2">
          <button onClick={() => save.mutate()} disabled={save.isPending}
            className={`rounded px-2.5 py-1 text-xs font-medium ${included ? 'border border-slate-300 text-slate-700 hover:bg-slate-50' : 'bg-brand-600 text-white hover:bg-brand-700'} disabled:opacity-60`}>
            {included ? 'Update' : 'Include'}
          </button>
          {included && (
            <button onClick={() => remove.mutate()} disabled={remove.isPending}
              className="rounded border border-red-300 px-2.5 py-1 text-xs font-medium text-red-700 hover:bg-red-50 disabled:opacity-60">
              Remove
            </button>
          )}
        </div>
      </td>
    </tr>
  )
}

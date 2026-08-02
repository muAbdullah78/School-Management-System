import { useState } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import {
  getCurrentSession, listClasses, listExamTerms, createExamTerm,
  listSubjects, createSubject, listExamSubjects, upsertExamSubject, removeExamSubject,
  type ExamSubjectRow, type SubjectRow,
} from '@/lib/db'
import { TERM_TYPES } from '@/lib/constants'
import { fmtDate, todayISO } from '@/lib/format'

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

        {termId && classId && <PaperSetup termId={termId} classId={classId} />}
      </section>
    </div>
  )
}

function PaperSetup({ termId, classId }: { termId: string; classId: string }) {
  const qc = useQueryClient()
  const subjects = useQuery({ queryKey: ['subjects', classId], queryFn: () => listSubjects(classId) })
  const examSubjects = useQuery({ queryKey: ['examSubjects', termId, classId], queryFn: () => listExamSubjects(termId, classId) })
  const [newSubj, setNewSubj] = useState('')

  const addSubj = useMutation({
    mutationFn: () => createSubject(newSubj.trim(), classId, subjects.data?.length ?? 0),
    onSuccess: () => { setNewSubj(''); qc.invalidateQueries({ queryKey: ['subjects', classId] }) },
  })

  if (subjects.isLoading) return <p className="mt-3 text-sm text-slate-500">Loading subjects…</p>
  const byId = new Map((examSubjects.data ?? []).map((es) => [es.subject_id, es]))

  return (
    <div className="mt-4">
      <div className="overflow-hidden rounded-lg border border-slate-200 bg-white">
        <table className="w-full text-sm">
          <thead className="bg-slate-50 text-left text-xs uppercase tracking-wide text-slate-500">
            <tr><th className="px-3 py-2">Subject</th><th className="px-3 py-2 w-28">Max marks</th><th className="px-3 py-2 w-28">Pass marks</th><th className="px-3 py-2 w-40">In this term</th></tr>
          </thead>
          <tbody className="divide-y divide-slate-100">
            {subjects.data?.length === 0 && <tr><td colSpan={4} className="px-3 py-3 text-slate-500">No subjects for this class yet — add one below.</td></tr>}
            {subjects.data?.map((s) => (
              <PaperRow key={s.id} subject={s} termId={termId} classId={classId} existing={byId.get(s.id)} />
            ))}
          </tbody>
        </table>
      </div>
      <form className="mt-3 flex gap-2" onSubmit={(e) => { e.preventDefault(); if (newSubj.trim()) addSubj.mutate() }}>
        <input value={newSubj} onChange={(e) => setNewSubj(e.target.value)} placeholder="Add subject (e.g. Mathematics)"
          className="w-64 rounded border border-slate-300 px-3 py-2 text-sm focus:border-brand-500 focus:outline-none" />
        <button type="submit" disabled={!newSubj.trim() || addSubj.isPending}
          className="rounded border border-slate-300 px-3 py-2 text-sm font-medium text-slate-700 hover:bg-slate-50 disabled:opacity-60">
          {addSubj.isPending ? 'Adding…' : 'Add subject'}
        </button>
        {addSubj.isError && <span className="self-center text-sm text-red-600">{(addSubj.error as Error).message}</span>}
      </form>
    </div>
  )
}

function PaperRow({ subject, termId, classId, existing }: { subject: SubjectRow; termId: string; classId: string; existing?: ExamSubjectRow }) {
  const qc = useQueryClient()
  const [max, setMax] = useState(String(existing?.max_marks ?? 100))
  const [pass, setPass] = useState(String(existing?.pass_marks ?? 33))
  const included = !!existing

  const save = useMutation({
    mutationFn: () => upsertExamSubject(termId, classId, subject.id, Number(max), Number(pass)),
    onSuccess: () => qc.invalidateQueries({ queryKey: ['examSubjects', termId, classId] }),
  })
  const remove = useMutation({
    mutationFn: () => removeExamSubject(existing!.id),
    onSuccess: () => qc.invalidateQueries({ queryKey: ['examSubjects', termId, classId] }),
  })

  return (
    <tr>
      <td className="px-3 py-2 font-medium text-slate-800">{subject.name}</td>
      <td className="px-3 py-2"><input type="number" min="1" value={max} onChange={(e) => setMax(e.target.value)} className="w-20 rounded border border-slate-300 px-2 py-1 text-sm" /></td>
      <td className="px-3 py-2"><input type="number" min="0" value={pass} onChange={(e) => setPass(e.target.value)} className="w-20 rounded border border-slate-300 px-2 py-1 text-sm" /></td>
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

import { useEffect, useState } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import {
  getCurrentSession, listClasses, listExamTerms, listExamSubjects, getMarksheet, enterMarks,
} from '@/lib/db'

const FIELD = 'mt-1 w-full rounded border border-slate-300 px-3 py-2 text-sm focus:border-brand-500 focus:outline-none focus:ring-1 focus:ring-brand-500'
type Entry = { marks: string; is_absent: boolean }

export function MarksEntry() {
  const qc = useQueryClient()
  const session = useQuery({ queryKey: ['currentSession'], queryFn: getCurrentSession })
  const sessionId = session.data?.id
  const terms = useQuery({ queryKey: ['examTerms', sessionId], queryFn: () => listExamTerms(sessionId!), enabled: !!sessionId })
  const classes = useQuery({ queryKey: ['classes'], queryFn: listClasses })

  const [termId, setTermId] = useState('')
  const [classId, setClassId] = useState('')
  const [examSubjectId, setExamSubjectId] = useState('')

  const examSubjects = useQuery({
    queryKey: ['examSubjects', termId, classId], queryFn: () => listExamSubjects(termId, classId), enabled: !!termId && !!classId,
  })
  const marksheet = useQuery({
    queryKey: ['marksheet', examSubjectId], queryFn: () => getMarksheet(examSubjectId), enabled: !!examSubjectId,
  })

  const [entries, setEntries] = useState<Record<string, Entry>>({})
  const [msg, setMsg] = useState<string | null>(null)
  const rows = marksheet.data ?? []
  const maxMarks = rows[0]?.max_marks

  useEffect(() => {
    if (!marksheet.data) return
    const next: Record<string, Entry> = {}
    for (const r of marksheet.data) next[r.enrollment_id] = { marks: r.marks == null ? '' : String(r.marks), is_absent: r.is_absent }
    setEntries(next)
    setMsg(null)
  }, [marksheet.data])

  const save = useMutation({
    mutationFn: () => enterMarks(examSubjectId, rows.map((r) => {
      const e = entries[r.enrollment_id]
      return { enrollment_id: r.enrollment_id, marks: e?.is_absent || e?.marks === '' ? null : Number(e.marks), is_absent: !!e?.is_absent }
    })),
    onSuccess: (res) => {
      setMsg(`Saved ${res.marked}${res.skipped ? ` · ${res.skipped} locked, skipped` : ''}.`)
      qc.invalidateQueries({ queryKey: ['marksheet', examSubjectId] })
    },
  })

  function upd(id: string, patch: Partial<Entry>) {
    setEntries((m) => ({ ...m, [id]: { ...m[id], ...patch } }))
  }

  const overMax = rows.some((r) => {
    const e = entries[r.enrollment_id]
    return e && !e.is_absent && e.marks !== '' && (Number(e.marks) < 0 || Number(e.marks) > r.max_marks)
  })

  return (
    <div>
      <div className="grid gap-3 sm:grid-cols-3">
        <label className="block">
          <span className="text-sm text-slate-600">Term</span>
          <select value={termId} onChange={(e) => { setTermId(e.target.value); setExamSubjectId('') }} className={FIELD}>
            <option value="">Select term…</option>
            {terms.data?.map((t) => <option key={t.id} value={t.id}>{t.name}</option>)}
          </select>
        </label>
        <label className="block">
          <span className="text-sm text-slate-600">Class</span>
          <select value={classId} onChange={(e) => { setClassId(e.target.value); setExamSubjectId('') }} className={FIELD}>
            <option value="">Select class…</option>
            {classes.data?.map((c) => <option key={c.id} value={c.id}>{c.name}</option>)}
          </select>
        </label>
        <label className="block">
          <span className="text-sm text-slate-600">Subject</span>
          <select value={examSubjectId} onChange={(e) => setExamSubjectId(e.target.value)} className={FIELD} disabled={!termId || !classId}>
            <option value="">{!termId || !classId ? 'Pick term & class' : 'Select subject…'}</option>
            {examSubjects.data?.map((es) => <option key={es.id} value={es.id}>{es.subject_name} (max {es.max_marks})</option>)}
          </select>
        </label>
      </div>

      {examSubjectId && examSubjects.data?.length === 0 && (
        <p className="mt-4 text-sm text-slate-500">No subjects set up for this term/class. Add them in the Setup tab.</p>
      )}

      {examSubjectId && (
        <div className="mt-5">
          {marksheet.isLoading && <p className="text-sm text-slate-500">Loading marksheet…</p>}
          {rows.length === 0 && !marksheet.isLoading && <p className="text-sm text-slate-500">No active students in this class.</p>}
          {rows.length > 0 && (
            <>
              <div className="overflow-hidden rounded-lg border border-slate-200 bg-white">
                <table className="w-full text-sm">
                  <thead className="bg-slate-50 text-left text-xs uppercase tracking-wide text-slate-500">
                    <tr><th className="px-3 py-2 w-14">Roll</th><th className="px-3 py-2">Student</th><th className="px-3 py-2 w-32">Marks (/{maxMarks})</th><th className="px-3 py-2 w-24">Absent</th></tr>
                  </thead>
                  <tbody className="divide-y divide-slate-100">
                    {rows.map((r) => {
                      const e = entries[r.enrollment_id] ?? { marks: '', is_absent: false }
                      const bad = !e.is_absent && e.marks !== '' && (Number(e.marks) < 0 || Number(e.marks) > r.max_marks)
                      return (
                        <tr key={r.enrollment_id} className={r.is_locked ? 'opacity-60' : ''}>
                          <td className="px-3 py-2 text-slate-500">{r.roll_no ?? '—'}</td>
                          <td className="px-3 py-2 text-slate-800">{r.full_name}{r.section_name ? <span className="text-slate-400"> · {r.section_name}</span> : ''}{r.is_locked && <span className="ml-1 text-xs">🔒</span>}</td>
                          <td className="px-3 py-2">
                            <input type="number" min="0" max={r.max_marks} step="0.5" disabled={e.is_absent || r.is_locked}
                              value={e.is_absent ? '' : e.marks} onChange={(ev) => upd(r.enrollment_id, { marks: ev.target.value })}
                              className={`w-24 rounded border px-2 py-1 text-sm ${bad ? 'border-red-400' : 'border-slate-300'} disabled:bg-slate-100`} />
                          </td>
                          <td className="px-3 py-2">
                            <input type="checkbox" checked={e.is_absent} disabled={r.is_locked}
                              onChange={(ev) => upd(r.enrollment_id, { is_absent: ev.target.checked })} className="h-4 w-4" />
                          </td>
                        </tr>
                      )
                    })}
                  </tbody>
                </table>
              </div>
              <div className="mt-4 flex items-center gap-3">
                <button onClick={() => save.mutate()} disabled={save.isPending || overMax}
                  className="rounded bg-brand-600 px-4 py-2 text-sm font-medium text-white hover:bg-brand-700 disabled:opacity-60">
                  {save.isPending ? 'Saving…' : 'Save marks'}
                </button>
                {overMax && <span className="text-sm text-red-600">Some marks exceed the maximum.</span>}
                {msg && <span className="text-sm text-emerald-700">{msg}</span>}
                {save.isError && <span className="text-sm text-red-600">{(save.error as Error).message}</span>}
              </div>
            </>
          )}
        </div>
      )}
    </div>
  )
}

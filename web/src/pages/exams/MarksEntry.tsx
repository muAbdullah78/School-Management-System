import { useEffect, useState } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import {
  getCurrentSession, listClasses, listExamTerms, listExamSubjects, getMarksheet, enterMarks,
} from '@/lib/db'

const FIELD = 'mt-1 w-full rounded border border-slate-300 px-3 py-2 text-sm focus:border-brand-500 focus:outline-none focus:ring-1 focus:ring-brand-500'
type Entry = { marks: string; practical: string; is_absent: boolean }

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
  const [reason, setReason] = useState('')
  const [msg, setMsg] = useState<string | null>(null)
  const rows = marksheet.data ?? []
  const maxMarks = rows[0]?.max_marks
  // Comes from the marksheet rather than being looked up separately, so the
  // screen and the server cannot disagree about whether this paper has a
  // practical at all.
  const practicalMax = rows[0]?.practical_max ?? 0
  const hasPractical = practicalMax > 0

  useEffect(() => {
    if (!marksheet.data) return
    const next: Record<string, Entry> = {}
    for (const r of marksheet.data) {
      next[r.enrollment_id] = {
        marks: r.marks == null ? '' : String(r.marks),
        practical: r.practical_marks == null ? '' : String(r.practical_marks),
        is_absent: r.is_absent,
      }
    }
    setEntries(next)
    setReason('')
    setMsg(null)
  }, [marksheet.data])

  // How many marks differ from what was loaded, and only counting rows that
  // ALREADY had a mark. Typing a mark into an empty box is a first entry, not a
  // correction, and asking a teacher to justify it would train them to ignore
  // the box.
  const changed = rows.filter((r) => {
    if (r.marks == null) return false
    const e = entries[r.enrollment_id]
    if (!e) return false
    const now = e.is_absent || e.marks === '' ? null : Number(e.marks)
    return now !== Number(r.marks)
  })

  const save = useMutation({
    mutationFn: () => enterMarks(examSubjectId, rows.map((r) => {
      const e = entries[r.enrollment_id]
      return {
        enrollment_id: r.enrollment_id,
        marks: e?.is_absent || e?.marks === '' ? null : Number(e.marks),
        // Sent only when the paper HAS a practical. Sending a value against a
        // paper with practical_max 0 is refused server-side, and rightly — but
        // the screen should never provoke that refusal.
        practical_marks: hasPractical && !e?.is_absent && e?.practical !== ''
          ? Number(e?.practical) : null,
        is_absent: !!e?.is_absent,
      }
    }), reason.trim() || null),
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
    if (!e || e.is_absent) return false
    const theoryBad = e.marks !== '' && (Number(e.marks) < 0 || Number(e.marks) > r.max_marks)
    // Checked against the PRACTICAL maximum, not the theory paper's. Checking
    // both against max_marks would let a 25-mark practical be typed as 70
    // whenever the theory paper happened to be out of 75.
    const pracBad = hasPractical && e.practical !== ''
      && (Number(e.practical) < 0 || Number(e.practical) > practicalMax)
    return theoryBad || pracBad
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
            {examSubjects.data?.map((es) => (
              <option key={es.id} value={es.id}>
                {es.subject_name}
                {es.subject_stream ? ` · ${es.subject_stream}` : ''}
                {' '}(max {es.max_marks}{es.practical_max > 0 ? ` + ${es.practical_max} practical` : ''})
              </option>
            ))}
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
                    <tr>
                      <th className="px-3 py-2 w-14">Roll</th>
                      <th className="px-3 py-2">Student</th>
                      <th className="px-3 py-2 w-32">{hasPractical ? 'Theory' : 'Marks'} (/{maxMarks})</th>
                      {hasPractical && <th className="px-3 py-2 w-32">Practical (/{practicalMax})</th>}
                      {hasPractical && <th className="px-3 py-2 w-20 text-right">Total</th>}
                      <th className="px-3 py-2 w-24">Absent</th>
                    </tr>
                  </thead>
                  <tbody className="divide-y divide-slate-100">
                    {rows.map((r) => {
                      const e = entries[r.enrollment_id] ?? { marks: '', practical: '', is_absent: false }
                      const bad = !e.is_absent && e.marks !== '' && (Number(e.marks) < 0 || Number(e.marks) > r.max_marks)
                      const pbad = hasPractical && !e.is_absent && e.practical !== ''
                        && (Number(e.practical) < 0 || Number(e.practical) > practicalMax)
                      return (
                        <tr key={r.enrollment_id} className={r.is_locked ? 'opacity-60' : ''}>
                          <td className="px-3 py-2 text-slate-500">{r.roll_no ?? '—'}</td>
                          <td className="px-3 py-2 text-slate-800">{r.full_name}{r.section_name ? <span className="text-slate-400"> · {r.section_name}</span> : ''}{r.is_locked && <span className="ml-1 text-xs">🔒</span>}</td>
                          <td className="px-3 py-2">
                            <input type="number" min="0" max={r.max_marks} step="0.5" disabled={e.is_absent || r.is_locked}
                              value={e.is_absent ? '' : e.marks} onChange={(ev) => upd(r.enrollment_id, { marks: ev.target.value })}
                              className={`w-24 rounded border px-2 py-1 text-sm ${bad ? 'border-red-400' : 'border-slate-300'} disabled:bg-slate-100`} />
                          </td>
                          {hasPractical && (
                            <td className="px-3 py-2">
                              <input type="number" min="0" max={practicalMax} step="0.5"
                                disabled={e.is_absent || r.is_locked}
                                value={e.is_absent ? '' : e.practical}
                                onChange={(ev) => upd(r.enrollment_id, { practical: ev.target.value })}
                                className={`w-24 rounded border px-2 py-1 text-sm ${pbad ? 'border-red-400' : 'border-slate-300'} disabled:bg-slate-100`} />
                            </td>
                          )}
                          {hasPractical && (
                            <td className="px-3 py-2 text-right text-slate-600">
                              {/* The combined figure, live, because the pass mark
                                  applies to it and a teacher should see the number
                                  the card will carry. */}
                              {e.is_absent
                                ? <span className="text-slate-400">0</span>
                                : (e.marks === '' && e.practical === ''
                                    ? <span className="text-slate-400">—</span>
                                    : (Number(e.marks || 0) + Number(e.practical || 0)))}
                            </td>
                          )}
                          <td className="px-3 py-2">
                            {/* An explicit control, not "leave it blank". Since
                                0058 a blank box means NOT MARKED and keeps the
                                paper out of the pupil's total; absence is a fact
                                that has to be recorded, and it scores zero. */}
                            <input type="checkbox" checked={e.is_absent} disabled={r.is_locked}
                              onChange={(ev) => upd(r.enrollment_id, { is_absent: ev.target.checked })} className="h-4 w-4" />
                          </td>
                        </tr>
                      )
                    })}
                  </tbody>
                </table>
              </div>
              {/* Only when a mark that ALREADY had a value is being changed. A
                  first entry is not a correction, and demanding a reason for
                  one would train teachers to type anything to get past it. */}
              {changed.length > 0 && (
                <div className="mt-4 rounded border border-amber-300 bg-amber-50 p-3">
                  <label className="block text-sm">
                    <span className="font-medium text-amber-900">
                      {changed.length === 1
                        ? `Changing ${changed[0].full_name}'s mark`
                        : `Changing ${changed.length} marks that were already entered`}
                    </span>
                    <span className="mt-1 block text-xs text-amber-800">
                      {changed.slice(0, 4).map((r) => {
                        const e = entries[r.enrollment_id]
                        const now = e?.is_absent || e?.marks === '' ? '—' : e?.marks
                        return `${r.full_name}: ${r.marks} → ${now}`
                      }).join(' · ')}
                      {changed.length > 4 && ` · and ${changed.length - 4} more`}
                    </span>
                    <input
                      value={reason}
                      onChange={(ev) => setReason(ev.target.value)}
                      placeholder="Why? e.g. re-totalled question 7, paper remarked on appeal"
                      className="mt-2 block w-full rounded border border-amber-300 px-3 py-2 text-sm focus:border-amber-500 focus:outline-none"
                    />
                    <span className="mt-1 block text-xs text-amber-700">
                      Recorded against these marks only, and shown in Reports → Mark Changes.
                      Leaving it blank is allowed, and the change is still recorded as
                      &ldquo;none given&rdquo;.
                    </span>
                  </label>
                </div>
              )}

              <div className="mt-4 flex items-center gap-3">
                <button onClick={() => save.mutate()} disabled={save.isPending || overMax}
                  className="rounded bg-brand-600 px-4 py-2 text-sm font-medium text-white hover:bg-brand-700 disabled:opacity-60">
                  {save.isPending ? 'Saving…' : 'Save marks'}
                </button>
                {overMax && <span className="text-sm text-red-600">Some marks exceed the maximum.</span>}
                <span className="text-xs text-slate-500">
                  A blank box means <strong>not marked yet</strong> and keeps that paper out of the
                  pupil&rsquo;s total. Tick <strong>Absent</strong> for a pupil who did not sit it —
                  that scores zero and counts.
                </span>
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

import { useEffect, useState } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import {
  getCurrentSession, listClasses, listExamTerms, listExamSubjects, getMarksheet, enterMarks,
} from '@/lib/db'
import { AskDialog } from '@/components/AskDialog'

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
    // NOT setMsg(null): saving refetches the marksheet, and clearing the
    // message on every load wiped "Saved 34" the moment it appeared.
    setEntries(next)
    setReason('')
  }, [marksheet.data])

  // How many marks differ from what was loaded, and only counting rows that
  // ALREADY had a mark. Typing a mark into an empty box is a first entry, not a
  // correction, and asking a teacher to justify it would train them to ignore
  // the box.
  const changed = rows.filter((r) => {
    if (r.marks == null && r.practical_marks == null) return false
    const e = entries[r.enrollment_id]
    if (!e) return false
    const now = e.is_absent || e.marks === '' ? null : Number(e.marks)
    const nowP = e.is_absent || e.practical === '' ? null : Number(e.practical)
    // A practical re-marked is a correction too: the pass mark applies to the
    // combined figure, so it can turn a PASS into a FAIL.
    return (r.marks != null && now !== Number(r.marks))
      || (hasPractical && r.practical_marks != null && nowP !== Number(r.practical_marks))
  })

  // Anything typed that is not saved yet, first entries included. Switching
  // term, class or subject used to throw it away without a word.
  const dirty = rows.some((r) => {
    const e = entries[r.enrollment_id]
    if (!e) return false
    return e.is_absent !== r.is_absent
      || (!e.is_absent && e.marks !== (r.marks == null ? '' : String(r.marks)))
      || (hasPractical && !e.is_absent && e.practical !== (r.practical_marks == null ? '' : String(r.practical_marks)))
  })
  const [pendingPick, setPendingPick] = useState<null | (() => void)>(null)
  const guard = (run: () => void) => (dirty ? setPendingPick(() => run) : run())

  // The paper's own pass mark, against theory plus practical, which is the
  // figure the card will judge. Live, as marks are typed.
  const paper = (examSubjects.data ?? []).find((es) => es.id === examSubjectId)
  const outOf = (maxMarks ?? 0) + practicalMax
  const typedTotals = rows.flatMap((r) => {
    const e = entries[r.enrollment_id]
    if (!e || e.is_absent || (e.marks === '' && e.practical === '')) return []
    const t = Number(e.marks || 0) + (hasPractical ? Number(e.practical || 0) : 0)
    return Number.isFinite(t) ? [t] : []
  })
  const absentN = rows.filter((r) => entries[r.enrollment_id]?.is_absent).length
  const blankN = rows.length - typedTotals.length - absentN
  const avgPct = typedTotals.length && outOf > 0
    ? Math.round((1000 * typedTotals.reduce((a, b) => a + b, 0)) / typedTotals.length / outOf) / 10
    : null
  const belowPass = paper ? typedTotals.filter((t) => t < paper.pass_marks).length : 0

  const save = useMutation({
    mutationFn: () => enterMarks(examSubjectId, rows.map((r) => {
      const e = entries[r.enrollment_id]
      return {
        enrollment_id: r.enrollment_id,
        marks: e?.is_absent || e?.marks === '' ? null : Number(e.marks),
        // Sent only when the paper HAS a practical. Sending a value against a
        // paper with practical_max 0 is refused server-side, and rightly, but
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
          <select value={termId} onChange={(e) => { const v = e.target.value; guard(() => { setTermId(v); setExamSubjectId(''); setMsg(null) }) }} className={FIELD}>
            <option value="">Select term…</option>
            {terms.data?.map((t) => <option key={t.id} value={t.id}>{t.name}</option>)}
          </select>
        </label>
        <label className="block">
          <span className="text-sm text-slate-600">Class</span>
          <select value={classId} onChange={(e) => { const v = e.target.value; guard(() => { setClassId(v); setExamSubjectId(''); setMsg(null) }) }} className={FIELD}>
            <option value="">Select class…</option>
            {classes.data?.map((c) => <option key={c.id} value={c.id}>{c.name}</option>)}
          </select>
        </label>
        <label className="block">
          <span className="text-sm text-slate-600">Subject</span>
          <select value={examSubjectId} onChange={(e) => { const v = e.target.value; guard(() => { setExamSubjectId(v); setMsg(null) }) }} className={FIELD} disabled={!termId || !classId}>
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
              <div className="mb-3 grid grid-cols-2 gap-2 sm:grid-cols-4">
                <Stat label="Marked" value={`${typedTotals.length + absentN} of ${rows.length}`}
                  sub={blankN > 0 ? `${blankN} still blank` : 'everyone done'} tone={blankN > 0 ? 'due' : 'plain'} />
                <Stat label="Class average" value={avgPct == null ? '-' : `${avgPct}%`}
                  sub={`out of ${outOf}${absentN ? `, ${absentN} absent left out` : ''}`} tone="plain" />
                <Stat label="Pass mark" value={paper ? String(paper.pass_marks) : '-'} sub={`of ${outOf}`} tone="plain" />
                <Stat label="Below pass" value={String(belowPass)}
                  sub={belowPass ? 'would fail this paper' : 'nobody below the pass mark'} tone={belowPass ? 'danger' : 'plain'} />
              </div>
              {/* A PHONE GETS ONE CARD PER PUPIL. The table squeezed the name to
                  a sliver beside two boxes and a checkbox, scrolled sideways when
                  the paper had a practical, and "Absent" was a 16 pixel box.
                  The boxes and the toggle here are the same state as the table. */}
              <ul className="space-y-2 sm:hidden">
                {rows.map((r) => {
                  const e = entries[r.enrollment_id] ?? { marks: '', practical: '', is_absent: false }
                  const bad = !e.is_absent && e.marks !== '' && (Number(e.marks) < 0 || Number(e.marks) > r.max_marks)
                  const pbad = hasPractical && !e.is_absent && e.practical !== ''
                    && (Number(e.practical) < 0 || Number(e.practical) > practicalMax)
                  const box = (isBad: boolean) => `w-full rounded-lg border px-3 py-2.5 text-base tabular-nums ${isBad ? 'border-danger-400 bg-danger-50' : 'border-slate-300'} disabled:bg-slate-100`
                  return (
                    <li key={r.enrollment_id} className={`rounded-xl border border-slate-200 bg-white p-3 ${r.is_locked ? 'opacity-60' : ''}`}>
                      <div className="flex items-start justify-between gap-2">
                        <div className="min-w-0 text-sm font-medium text-slate-900">
                          {r.roll_no != null && <span className="mr-1.5 tabular-nums text-slate-400">{r.roll_no}</span>}
                          {r.full_name}{r.section_name ? <span className="font-normal text-slate-400"> · {r.section_name}</span> : ''}
                          {r.is_locked && <span className="ml-1 text-xs font-normal text-slate-500">locked</span>}
                        </div>
                        <button type="button" disabled={r.is_locked} aria-pressed={e.is_absent}
                          onClick={() => upd(r.enrollment_id, { is_absent: !e.is_absent })}
                          className={`shrink-0 rounded-full px-3 py-1 text-xs font-medium ring-1 transition ${
                            e.is_absent ? 'bg-danger-600 text-white ring-danger-600' : 'bg-white text-slate-600 ring-slate-300'}`}
                          style={{ touchAction: 'manipulation' }}>
                          Absent
                        </button>
                      </div>
                      <div className={`mt-2 grid gap-2 ${hasPractical ? 'grid-cols-3' : 'grid-cols-1'}`}>
                        <label className="block">
                          <span className="text-[11px] text-slate-500">{hasPractical ? 'Theory' : 'Marks'} /{r.max_marks}</span>
                          <input type="number" min="0" max={r.max_marks} step="0.5" disabled={e.is_absent || r.is_locked}
                            value={e.is_absent ? '' : e.marks} onChange={(ev) => upd(r.enrollment_id, { marks: ev.target.value })}
                            inputMode="decimal" aria-label={`${r.full_name}, ${hasPractical ? 'theory' : 'marks'}`} className={box(bad)} />
                        </label>
                        {hasPractical && (
                          <label className="block">
                            <span className="text-[11px] text-slate-500">Practical /{practicalMax}</span>
                            <input type="number" min="0" max={practicalMax} step="0.5" disabled={e.is_absent || r.is_locked}
                              value={e.is_absent ? '' : e.practical} onChange={(ev) => upd(r.enrollment_id, { practical: ev.target.value })}
                              inputMode="decimal" aria-label={`${r.full_name}, practical`} className={box(pbad)} />
                          </label>
                        )}
                        {hasPractical && (
                          <div>
                            <span className="text-[11px] text-slate-500">Total</span>
                            <div className="px-1 py-2.5 text-base font-semibold tabular-nums text-slate-800">
                              {e.is_absent ? '0' : (e.marks === '' && e.practical === '' ? '-' : Number(e.marks || 0) + Number(e.practical || 0))}
                            </div>
                          </div>
                        )}
                      </div>
                      {(bad || pbad) && <p className="mt-1 text-xs text-danger-700">More than the paper allows.</p>}
                    </li>
                  )
                })}
              </ul>
              <div className="hidden overflow-x-auto rounded-lg border border-slate-200 bg-white sm:block">
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
                          <td className="px-3 py-2 text-slate-500">{r.roll_no ?? '-'}</td>
                          <td className="px-3 py-2 text-slate-800">{r.full_name}{r.section_name ? <span className="text-slate-400"> · {r.section_name}</span> : ''}{r.is_locked && <span className="ml-1 text-xs">🔒</span>}</td>
                          <td className="px-3 py-2">
                            <input type="number" min="0" max={r.max_marks} step="0.5" disabled={e.is_absent || r.is_locked}
                              value={e.is_absent ? '' : e.marks} onChange={(ev) => upd(r.enrollment_id, { marks: ev.target.value })}
                              inputMode="decimal"
                              className={`w-20 rounded border px-2 py-1.5 text-sm tabular-nums sm:w-24 ${bad ? 'border-danger-400 bg-danger-50' : 'border-slate-300'} disabled:bg-slate-100`} />
                          </td>
                          {hasPractical && (
                            <td className="px-3 py-2">
                              <input type="number" min="0" max={practicalMax} step="0.5"
                                disabled={e.is_absent || r.is_locked}
                                value={e.is_absent ? '' : e.practical}
                                onChange={(ev) => upd(r.enrollment_id, { practical: ev.target.value })}
                                inputMode="decimal"
                                className={`w-20 rounded border px-2 py-1.5 text-sm tabular-nums sm:w-24 ${pbad ? 'border-danger-400 bg-danger-50' : 'border-slate-300'} disabled:bg-slate-100`} />
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
                                    ? <span className="text-slate-400">-</span>
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
                <div className="mt-4 rounded-xl border border-due-300 bg-due-50 p-3">
                  <label className="block text-sm">
                    <span className="font-medium text-due-900">
                      {changed.length === 1
                        ? `Changing ${changed[0].full_name}'s mark`
                        : `Changing ${changed.length} marks that were already entered`}
                    </span>
                    <span className="mt-1 block text-xs text-due-800">
                      {changed.slice(0, 4).map((r) => {
                        const e = entries[r.enrollment_id]
                        const now = e?.is_absent || e?.marks === '' ? '-' : e?.marks
                        return `${r.full_name}: ${r.marks} → ${now}`
                      }).join(' · ')}
                      {changed.length > 4 && ` · and ${changed.length - 4} more`}
                    </span>
                    <input
                      value={reason}
                      onChange={(ev) => setReason(ev.target.value)}
                      placeholder="Why? e.g. re-totalled question 7, paper remarked on appeal"
                      className="mt-2 block w-full rounded border border-due-300 px-3 py-2 text-sm focus:border-due-500 focus:outline-none"
                    />
                    <span className="mt-1 block text-xs text-due-700">
                      Recorded against these marks only, and shown in Reports → Mark Changes.
                      Leaving it blank is allowed, and the change is still recorded as
                      &ldquo;none given&rdquo;.
                    </span>
                  </label>
                </div>
              )}

              <div className="mt-4 flex flex-wrap items-center gap-3">
                <button onClick={() => save.mutate()} disabled={save.isPending || overMax}
                  className="rounded bg-brand-600 px-4 py-2 text-sm font-medium text-white hover:bg-brand-700 disabled:opacity-60">
                  {save.isPending ? 'Saving…' : 'Save marks'}
                </button>
                {overMax && <span className="text-sm text-danger-600">Some marks are below 0 or above the paper&rsquo;s maximum.</span>}
                <span className="text-xs text-slate-500">
                  A blank box means <strong>not marked yet</strong> and keeps that paper out of the
                  pupil&rsquo;s total. Tick <strong>Absent</strong> for a pupil who did not sit it:
                  that scores zero and counts.
                </span>
                {msg && <span className="text-sm font-medium text-brand-700">{msg}</span>}
                {save.isError && <span className="text-sm text-danger-600">{(save.error as Error).message}</span>}
              </div>
            </>
          )}
        </div>
      )}

      {pendingPick && (
        <AskDialog
          title="Leave without saving?"
          intro={<>The marks typed on this sheet have not been saved. Opening another paper throws them away.
            Press <b>Stay</b>, then <b>Save marks</b>, to keep them.</>}
          confirmLabel="Discard the marks" cancelLabel="Stay" tone="danger"
          onCancel={() => setPendingPick(null)}
          onSubmit={() => { const run = pendingPick; setPendingPick(null); run() }}
        />
      )}
    </div>
  )
}

function Stat({ label, value, sub, tone }: { label: string; value: string; sub: string; tone: 'plain' | 'due' | 'danger' }) {
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

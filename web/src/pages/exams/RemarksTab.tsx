/**
 * Teacher remarks, and the position-holders list.
 *
 * Both were missing entirely. Remarks had nowhere in the schema to live at all;
 * position was computed and printed on the result card but there was no "top
 * three in each class" view, which is what a prize distribution and the notice
 * board actually need.
 *
 * The remark sheet shows the WHOLE class, with each child's own result beside
 * the box. A remark written without seeing the result is a remark about
 * nothing, and a screen listing only the remarks already written gives a
 * teacher no way to find who is left.
 */
import { useState } from 'react'
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import {
  listExamTerms, listClasses, listExamRemarks, setExamRemark, getPositionHolders,
  getCurrentSession,
  type ExamRemarkRow, type PositionHolder,
} from '@/lib/db'

const FIELD =
  'rounded border border-slate-300 px-3 py-2 text-sm focus:border-brand-500 focus:outline-none focus:ring-1 focus:ring-brand-500'

export function RemarksTab() {
  const [view, setView] = useState<'remarks' | 'positions'>('remarks')
  const [termId, setTermId] = useState('')
  const [classId, setClassId] = useState('')
  const [top, setTop] = useState(3)

  const session = useQuery({ queryKey: ['currentSession'], queryFn: getCurrentSession })
  const terms = useQuery({
    queryKey: ['examTerms', session.data?.id],
    queryFn: () => listExamTerms(session.data!.id),
    enabled: !!session.data?.id,
  })
  const classes = useQuery({ queryKey: ['classes'], queryFn: listClasses })

  return (
    <div>
      <div className="mb-4 flex flex-wrap items-end gap-3">
        <label className="block text-sm">
          <span className="text-slate-600">Exam term</span>
          <select value={termId} onChange={(e) => setTermId(e.target.value)}
                  className={`mt-1 block ${FIELD}`}>
            <option value="">Select term…</option>
            {(terms.data ?? []).map((t) => (
              <option key={t.id} value={t.id}>{t.name}</option>
            ))}
          </select>
        </label>

        {view === 'remarks' ? (
          <label className="block text-sm">
            <span className="text-slate-600">Class</span>
            <select value={classId} onChange={(e) => setClassId(e.target.value)}
                    className={`mt-1 block ${FIELD}`}>
              <option value="">Select class…</option>
              {(classes.data ?? []).map((c) => (
                <option key={c.id} value={c.id}>{c.name}</option>
              ))}
            </select>
          </label>
        ) : (
          <label className="block text-sm">
            <span className="text-slate-600">How many per class</span>
            <select value={top} onChange={(e) => setTop(Number(e.target.value))}
                    className={`mt-1 block ${FIELD}`}>
              <option value={1}>First only</option>
              <option value={3}>Top three</option>
              <option value={5}>Top five</option>
              <option value={10}>Top ten</option>
            </select>
          </label>
        )}

        <div className="ml-auto flex gap-1 rounded border border-slate-200 p-0.5">
          {([['remarks', 'Write remarks'], ['positions', 'Position holders']] as const)
            .map(([k, label]) => (
              <button key={k} onClick={() => setView(k)}
                className={`rounded px-3 py-1.5 text-sm ${view === k ? 'bg-brand-600 text-white' : 'text-slate-600 hover:bg-slate-50'}`}>
                {label}
              </button>
            ))}
        </div>
      </div>

      {!termId ? (
        <p className="rounded border border-slate-200 p-8 text-center text-sm text-slate-500">
          Choose an exam term to begin.
        </p>
      ) : view === 'remarks' ? (
        classId
          ? <RemarkSheet termId={termId} classId={classId} />
          : <p className="rounded border border-slate-200 p-8 text-center text-sm text-slate-500">
              Choose a class.
            </p>
      ) : (
        <PositionHolders termId={termId} top={top} />
      )}
    </div>
  )
}

function RemarkSheet({ termId, classId }: { termId: string; classId: string }) {
  const qc = useQueryClient()
  const [drafts, setDrafts] = useState<Record<string, string>>({})
  const [saved, setSaved] = useState<Record<string, boolean>>({})
  const [err, setErr] = useState<string | null>(null)

  const q = useQuery({
    queryKey: ['examRemarks', termId, classId],
    queryFn: () => listExamRemarks(termId, classId),
  })

  const save = useMutation({
    mutationFn: (v: { studentId: string; text: string }) =>
      setExamRemark(termId, v.studentId, v.text),
    onSuccess: (_d, v) => {
      setSaved((m) => ({ ...m, [v.studentId]: true }))
      setErr(null)
      void qc.invalidateQueries({ queryKey: ['examRemarks', termId, classId] })
    },
    onError: (e) => setErr((e as Error).message),
  })

  const rows = q.data ?? []
  const written = rows.filter((r) => r.remark?.trim()).length

  if (q.isLoading) return <p className="py-8 text-center text-sm text-slate-500">Loading…</p>
  if (q.isError) {
    return (
      <div className="rounded border border-danger-200 bg-danger-50 p-4 text-sm text-danger-700">
        {(q.error as Error).message}
      </div>
    )
  }

  const value = (r: ExamRemarkRow) => drafts[r.student_id] ?? r.remark ?? ''
  const unsaved = rows.filter((r) => value(r) !== (r.remark ?? ''))

  // ALL AT ONCE. A class teacher writing thirty remarks had to press thirty
  // Save buttons, and one missed was a card printed without its remark. They
  // go one at a time underneath (there is no batch function), in order, and
  // stop at the first refusal so the message names the child it was about.
  const saveAll = useMutation({
    mutationFn: async () => {
      let n = 0
      for (const r of unsaved) {
        try {
          await setExamRemark(termId, r.student_id, value(r))
        } catch (e) {
          throw new Error(`${r.student_name}: ${(e as Error).message}${n ? ` (${n} saved before this one)` : ''}`)
        }
        setSaved((m) => ({ ...m, [r.student_id]: true }))
        n += 1
      }
      return n
    },
    onSuccess: () => setErr(null),
    onError: (e) => setErr((e as Error).message),
    onSettled: () => { void qc.invalidateQueries({ queryKey: ['examRemarks', termId, classId] }) },
  })

  return (
    <div>
      <div className="mb-3 flex flex-wrap items-center justify-between gap-2">
        <p className="text-sm text-slate-500">
          <span className="font-medium text-slate-800">{written} of {rows.length}</span> written.{' '}
          {written < rows.length && (
            <span className="text-slate-400">
              Blank is fine. An empty remark simply prints nothing.
            </span>
          )}
        </p>
        <button
          type="button"
          disabled={unsaved.length === 0 || saveAll.isPending || save.isPending}
          onClick={() => saveAll.mutate()}
          className="rounded bg-brand-600 px-3 py-1.5 text-sm font-medium text-white hover:bg-brand-700 disabled:opacity-50"
        >
          {saveAll.isPending ? 'Saving…' : unsaved.length ? `Save all ${unsaved.length} changed` : 'All saved'}
        </button>
      </div>
      {err && <p className="mb-3 rounded-xl border border-danger-200 bg-danger-50 px-3 py-2 text-sm text-danger-700">{err}</p>}
      <div className="mb-3 h-1.5 overflow-hidden rounded-full bg-slate-100" aria-hidden>
        <div className="h-full rounded-full bg-brand-500" style={{ width: `${rows.length ? (100 * written) / rows.length : 0}%` }} />
      </div>

      {/* One card a pupil at every width: the remark box needs the width more
          than the table needed its columns, and on a phone the old table left
          the box about eight characters wide. */}
      <ul className="divide-y divide-slate-100 rounded-2xl border border-slate-200 bg-white">
        {rows.map((r) => {
          const dirty = value(r) !== (r.remark ?? '')
          return (
            <li key={r.student_id} className="p-3">
              <div className="flex flex-wrap items-baseline justify-between gap-x-3 gap-y-1">
                <div className="min-w-0">
                  <span className="mr-2 text-xs tabular-nums text-slate-400">{r.roll_no ?? '-'}</span>
                  <span className="font-medium text-slate-800">{r.student_name}</span>
                  <span className="ml-1.5 text-xs text-slate-400">{r.gr_no ?? ''}</span>
                </div>
                {/* The child's own result, beside the box. A remark written
                    without it is a remark about nothing. */}
                <div className="text-xs text-slate-500">
                  {r.percentage == null ? 'No result yet' : (
                    <>
                      <b className="font-semibold tabular-nums text-slate-800">{r.percentage}%</b>
                      {' · '}{r.grade ?? '-'}
                      {r.class_position != null && ` · position ${r.class_position}`}
                    </>
                  )}
                </div>
              </div>
              <textarea
                rows={2}
                value={value(r)}
                onChange={(e) => {
                  setDrafts((m) => ({ ...m, [r.student_id]: e.target.value }))
                  setSaved((m) => ({ ...m, [r.student_id]: false }))
                }}
                placeholder="A hardworking and well-mannered student."
                className={`mt-2 block w-full ${FIELD} ${dirty ? 'border-due-300 bg-due-50/40' : ''}`}
              />
              <div className="mt-1.5 flex items-center justify-between gap-2">
                <span className="text-xs text-slate-400">
                  {dirty ? <span className="text-due-800">Not saved yet</span>
                    : saved[r.student_id] ? <span className="text-brand-700">Saved</span>
                    : r.remark?.trim() && r.remark_by_name !== '-' ? `by ${r.remark_by_name}` : ''}
                </span>
                <button
                  type="button"
                  disabled={save.isPending || saveAll.isPending || !dirty}
                  onClick={() => save.mutate({ studentId: r.student_id, text: value(r) })}
                  className="rounded border border-slate-300 px-3 py-1.5 text-xs text-slate-700 hover:bg-slate-50 disabled:opacity-40"
                >
                  Save
                </button>
              </div>
            </li>
          )
        })}
      </ul>

      <p className="mt-3 text-xs leading-relaxed text-slate-500">
        Remarks are kept per exam term, not per printed card, so regenerating the result cards
        never loses them. Only the class teacher (and the office) may write one. A subject teacher
        sees a single subject, and this is a judgement about the whole child.
      </p>
    </div>
  )
}

function PositionHolders({ termId, top }: { termId: string; top: number }) {
  const q = useQuery({
    queryKey: ['positionHolders', termId, top],
    queryFn: () => getPositionHolders(termId, top),
  })

  if (q.isLoading) return <p className="py-8 text-center text-sm text-slate-500">Working it out…</p>
  if (q.isError) {
    return (
      <div className="rounded border border-danger-200 bg-danger-50 p-4 text-sm text-danger-700">
        {(q.error as Error).message}
      </div>
    )
  }

  const rows = q.data ?? []
  if (!rows.length) {
    return (
      <p className="rounded border border-slate-200 p-8 text-center text-sm text-slate-500">
        No position holders yet. Result cards have to be generated for a class before its
        positions exist.
      </p>
    )
  }

  // Group by class, preserving the order SQL already put them in.
  const byClass: { name: string; rows: PositionHolder[] }[] = []
  for (const r of rows) {
    const last = byClass[byClass.length - 1]
    if (last && last.name === r.class_name) last.rows.push(r)
    else byClass.push({ name: r.class_name, rows: [r] })
  }

  const withheld = rows.filter((r) => r.withheld).length

  return (
    <div id="report">
      {/* Announcing a prize for a child whose result is being held back over
          unpaid fees is a mistake you want to catch beforehand. */}
      {withheld > 0 && (
        <div className="mb-4 rounded border border-amber-300 bg-amber-50 p-3 text-sm text-amber-900">
          <strong>{withheld} of these {withheld === 1 ? 'results is' : 'results are'} withheld</strong>{' '}
          over unpaid fees. Settle the account or lift the withholding before announcing.
        </div>
      )}

      <div className="grid gap-4 lg:grid-cols-2">
        {byClass.map((g) => (
          <div key={g.name} className="rounded border border-slate-200 p-4">
            <h3 className="mb-2 text-sm font-semibold text-slate-700">{g.name}</h3>
            <ol className="space-y-1.5">
              {g.rows.map((r) => (
                <li key={r.student_id} className="flex items-baseline gap-2 text-sm">
                  <span className={`w-7 shrink-0 text-right font-semibold tabular-nums ${
                    r.class_position === 1 ? 'text-money-700' : 'text-slate-500'}`}>
                    {r.class_position}
                  </span>
                  <span className="flex-1">
                    <span className="text-slate-800">{r.student_name}</span>
                    {r.section_name && (
                      <span className="ml-1 text-xs text-slate-400">{r.section_name}</span>
                    )}
                    {/* A shared position is stated, not hidden. Two children on
                        the same percentage are both first. */}
                    {r.tied_with > 1 && (
                      <span className="ml-1 text-xs text-amber-700">
                        (tied, {r.tied_with} children)
                      </span>
                    )}
                    {r.withheld && (
                      <span className="ml-1 text-xs text-danger-600">withheld</span>
                    )}
                    {r.remark?.trim() && (
                      <span className="block text-xs italic text-slate-400">{r.remark}</span>
                    )}
                  </span>
                  <span className="shrink-0 tabular-nums text-slate-600">
                    {r.percentage == null ? '-' : `${r.percentage}%`}
                    {r.grade && <span className="ml-1 text-xs text-slate-400">{r.grade}</span>}
                  </span>
                </li>
              ))}
            </ol>
          </div>
        ))}
      </div>

      <div className="mt-4 flex items-center justify-between print:hidden">
        <p className="text-xs leading-relaxed text-slate-500">
          Positions come from the result cards themselves, so this list and the printed card can
          never disagree. Children on the same percentage <strong>share</strong> a position. Two
          firsts means there is no second. A child with no marks entered is not listed.
        </p>
        <button type="button" onClick={() => window.print()}
          className="ml-4 shrink-0 rounded border border-slate-300 px-3 py-2 text-sm text-slate-600 hover:bg-slate-50">
          Print
        </button>
      </div>
    </div>
  )
}

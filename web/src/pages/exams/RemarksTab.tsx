/**
 * Teacher remarks, and the position holders.
 *
 * The remark sheet shows the WHOLE class (or, for a class teacher, their own
 * section of it), with each child's own result beside the box. A remark written
 * without seeing the result is a remark about nothing.
 *
 * WHAT WAS WRONG HERE:
 *   * the typed remarks were kept by child across a TERM switch, so First
 *     Term's drafts reappeared in Mid Term's boxes and "Save all" wrote them
 *     there. The sheet is now keyed by term and class, and a switch asks first;
 *   * a class teacher could not reach this screen at all;
 *   * the remark printed on no card and reached no parent. It does both now,
 *     and is frozen once the result is released (0152);
 *   * position 1 was drawn in money green, which this app keeps for money.
 */
import { useMemo, useState } from 'react'
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import {
  listExamRemarks, setExamRemark, getPositionHolders, getClassReleased,
  type ExamRemarkRow, type PositionHolder,
} from '@/lib/db'
import { useAuth } from '@/auth/AuthProvider'
import { taughtClasses, classTeacherReach, inReachByName } from '@/lib/teaching'
import { Avatar } from '@/components/Avatar'
import { IconLock, IconPrint, IconTrophy, IconExams, IconCheck } from '@/components/icons'
import {
  Chip, Panel, PanelHead, Pills, examRole, useExamBasics, useExamPick, useTeaching, useUnsaved,
} from './examKit'

const MAX = 500

export function RemarksTab() {
  const { profile } = useAuth()
  const who = examRole(profile?.role)
  const office = who === 'office'
  const [view, setView] = useState<'remarks' | 'positions'>('remarks')
  const { terms, classes } = useExamBasics()
  const { termId, classId, setClass } = useExamPick()
  const teaching = useTeaching(who === 'class_teacher')
  const guard = useUnsaved(false, 'remarks-shell')
  const term = (terms.data ?? []).find((t) => t.id === termId) ?? null

  const classList = who === 'class_teacher'
    ? taughtClasses((teaching.data ?? []).filter((r) => r.is_class_teacher)).map((c) => ({ id: c.class_id, name: c.class_name }))
    : (classes.data ?? []).map((c) => ({ id: c.id, name: c.name }))
  const cls = classList.find((c) => c.id === classId) ?? null

  if (!term) return <Panel><p className="py-6 text-center text-sm text-slate-500">Choose an exam term at the top.</p></Panel>

  return (
    <div className="space-y-4">
      <Panel>
        <PanelHead icon={view === 'remarks' ? <IconExams /> : <IconTrophy />}
          title={view === 'remarks' ? 'Report-card remarks' : 'Position holders'}
          sub={view === 'remarks'
            ? 'One line about each child, printed on the card and shown to the parent with the result.'
            : 'The top of every class for this term, ready for the notice board and prize day.'}
          action={office && (
            <div className="flex rounded-xl bg-slate-100 p-1" role="group" aria-label="What to show">
              {([['remarks', 'Remarks'], ['positions', 'Positions']] as const).map(([k, label]) => (
                <button key={k} type="button" aria-pressed={view === k} onClick={() => guard(() => setView(k))}
                  className={`rounded-lg px-3 py-1.5 text-sm font-medium transition ${view === k ? 'bg-white text-brand-700 shadow-sm' : 'text-slate-600 hover:text-slate-900'}`}>
                  {label}
                </button>
              ))}
            </div>
          )} />
        {view === 'remarks' && (
          classList.length > 0
            ? <Pills label="Class" value={cls?.id ?? ''} onPick={(id) => guard(() => setClass(id))}
                items={classList.map((c) => ({ id: c.id, label: c.name }))} />
            : who === 'class_teacher' && teaching.isFetched
              ? <p className="text-sm text-slate-500">You are not the class teacher of any class this year.</p>
              : null
        )}
      </Panel>

      {view === 'remarks'
        ? (cls
            ? <RemarkSheet key={`${termId}:${cls.id}`} termId={termId} classId={cls.id} className={cls.name}
                reach={who === 'class_teacher' ? classTeacherReach(teaching.data ?? [], cls.id) : null} />
            : <Panel><p className="py-4 text-center text-sm text-slate-500">Pick a class above.</p></Panel>)
        : <PositionHolders termId={termId} termName={term.name} />}
    </div>
  )
}

/** A few lines to start from, chosen by the child's own result. A teacher with
 *  forty cards to finish writes better remarks from a good first line than from
 *  an empty box, and every one can be edited. */
function suggestions(r: ExamRemarkRow): string[] {
  const p = r.percentage
  const byResult = p == null ? []
    : p >= 80 ? ['Excellent result. Keep up the hard work.', 'A bright pupil who works with great care.']
    : p >= 60 ? ['Good effort. Regular revision will bring even better results.', 'Works well and is keen to learn.']
    : p >= 40 ? ['Satisfactory. Needs more regular revision at home.', 'Can do better with steady practice.']
    : ['Needs serious attention. Please meet the class teacher.', 'Must work much harder next term.']
  return [...byResult, 'Well-mannered and attentive in class.', 'Regular and punctual.']
}

function RemarkSheet({ termId, classId, className, reach }: {
  termId: string; classId: string; className: string
  reach: ReturnType<typeof classTeacherReach> | null
}) {
  const qc = useQueryClient()
  const [drafts, setDrafts] = useState<Record<string, string>>({})
  const [err, setErr] = useState<string | null>(null)
  const [savedN, setSavedN] = useState<number | null>(null)
  const [open, setOpen] = useState<string | null>(null)

  const q = useQuery({ queryKey: ['examRemarks', termId, classId], queryFn: () => listExamRemarks(termId, classId) })
  const releasedQ = useQuery({ queryKey: ['classReleased', termId, classId], queryFn: () => getClassReleased(termId, classId) })
  // A class teacher of one section writes for that section; the list carries
  // each pupil's section by name, which is unique within the class.
  const rows = useMemo(() => (q.data ?? []).filter((r) => !reach || inReachByName(reach, r.section_name)), [q.data, reach])
  const released = releasedQ.data === true

  const value = (r: ExamRemarkRow) => drafts[r.student_id] ?? r.remark ?? ''
  const unsaved = rows.filter((r) => value(r).trim() !== (r.remark ?? '').trim())
  useUnsaved(unsaved.length > 0, 'remarks-sheet')
  const written = rows.filter((r) => value(r).trim()).length
  const tooLong = rows.some((r) => value(r).trim().length > MAX)

  // ALL AT ONCE, in order, stopping at the first refusal so the message names
  // the child it was about. There is one writer per remark, not a batch.
  const saveAll = useMutation({
    mutationFn: async (only?: ExamRemarkRow) => {
      let n = 0
      for (const r of only ? [only] : unsaved) {
        try {
          await setExamRemark(termId, r.student_id, value(r).trim())
        } catch (e) {
          throw new Error(`${r.student_name}: ${(e as Error).message}${n ? ` (${n} saved before this one)` : ''}`)
        }
        n += 1
      }
      return n
    },
    onSuccess: (n, only) => {
      setErr(null)
      setSavedN(n)
      setDrafts((d) => {
        if (!only) return {}
        const next = { ...d }; delete next[only.student_id]; return next
      })
    },
    onError: (e) => setErr((e as Error).message),
    onSettled: () => { void qc.invalidateQueries({ queryKey: ['examRemarks', termId, classId] }) },
  })

  if (q.isLoading) return <div className="h-48 animate-pulse rounded-3xl bg-slate-100" />
  if (q.isError) return <Panel><p className="text-sm text-danger-700">{(q.error as Error).message}</p></Panel>

  const set = (id: string, text: string) => { setSavedN(null); setDrafts((m) => ({ ...m, [id]: text })) }

  return (
    <Panel>
      <div className="flex flex-wrap items-center justify-between gap-3">
        <div>
          <h3 className="text-base font-semibold text-slate-900">{className}</h3>
          <p className="text-sm text-slate-500">
            <b className="text-slate-800">{written} of {rows.length}</b> written{reach && !reach.whole ? ' in your section' : ''}.
            {written < rows.length && ' Blank prints nothing.'}
          </p>
        </div>
        {!released && (
          <button type="button" disabled={unsaved.length === 0 || saveAll.isPending || tooLong} onClick={() => saveAll.mutate(undefined)}
            className="inline-flex items-center gap-1.5 rounded-xl bg-brand-600 px-4 py-2 text-sm font-semibold text-white shadow-sm hover:bg-brand-700 disabled:opacity-50">
            <IconCheck /> {saveAll.isPending ? 'Saving…' : unsaved.length ? `Save ${unsaved.length} change${unsaved.length === 1 ? '' : 's'}` : 'All saved'}
          </button>
        )}
      </div>
      <div className="mt-3 h-2 overflow-hidden rounded-full bg-slate-100" aria-hidden>
        <div className="h-full rounded-full bg-gradient-to-r from-brand-500 to-violet-500 transition-all"
          style={{ width: `${rows.length ? (100 * written) / rows.length : 0}%` }} />
      </div>

      {released && (
        <p className="mt-3 flex items-start gap-2 rounded-2xl bg-violet-50 px-3 py-2 text-sm text-violet-800 ring-1 ring-violet-200">
          <IconLock className="mt-0.5 h-4 w-4 shrink-0" />
          This class&rsquo;s results have been released, so its remarks are what parents were shown and cannot change.
          The owner or principal can withdraw the results under Result Cards first.
        </p>
      )}
      {err && <p className="mt-3 rounded-2xl bg-danger-50 px-3 py-2 text-sm text-danger-700 ring-1 ring-danger-200">{err}</p>}
      {savedN != null && !err && unsaved.length === 0 && (
        <p className="mt-3 rounded-2xl bg-brand-50 px-3 py-2 text-sm text-brand-800 ring-1 ring-brand-200">Saved {savedN} remark{savedN === 1 ? '' : 's'}.</p>
      )}

      {rows.length === 0 && <p className="mt-4 text-center text-sm text-slate-500">No pupil in this class{reach ? ' in your section' : ''}.</p>}

      <ul className="mt-4 grid gap-3 lg:grid-cols-2">
        {rows.map((r) => {
          const text = value(r)
          const dirty = text.trim() !== (r.remark ?? '').trim()
          const long = text.trim().length > MAX
          return (
            <li key={r.student_id} className={`rounded-2xl p-3 ring-1 ${dirty ? 'bg-due-50/40 ring-due-200' : 'bg-white ring-slate-200'}`}>
              <div className="flex items-center gap-2.5">
                <Avatar name={r.student_name} size="sm" />
                <div className="min-w-0 flex-1">
                  <div className="truncate text-sm font-semibold text-slate-900">{r.student_name}</div>
                  <div className="text-xs text-slate-500">
                    {r.roll_no ? `Roll ${r.roll_no}` : 'No roll'}{r.section_name ? ` · ${r.section_name}` : ''}
                  </div>
                </div>
                {/* The child's own result, beside the box. */}
                {r.percentage == null
                  ? <Chip tone="slate">no card yet</Chip>
                  : <Chip tone={r.percentage >= 40 ? 'brand' : 'danger'}>
                      {r.percentage}% · {r.grade ?? '-'}{r.class_position != null ? ` · #${r.class_position}` : ''}
                    </Chip>}
              </div>
              <textarea rows={2} value={text} disabled={released}
                onChange={(e) => set(r.student_id, e.target.value)}
                onFocus={() => setOpen(r.student_id)}
                placeholder="A hardworking and well-mannered pupil."
                aria-label={`Remark for ${r.student_name}`}
                className={`mt-2 block w-full resize-y rounded-xl border px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-brand-100 disabled:bg-slate-50 disabled:text-slate-500 ${long ? 'border-danger-400' : 'border-slate-300 focus:border-brand-500'}`} />
              {!released && open === r.student_id && (
                <div className="mt-2 flex flex-wrap gap-1.5">
                  {suggestions(r).map((s) => (
                    <button key={s} type="button"
                      onMouseDown={(e) => e.preventDefault()}
                      onClick={() => set(r.student_id, text.trim() ? `${text.trim()} ${s}` : s)}
                      className="rounded-full bg-violet-50 px-2.5 py-1 text-[11px] font-medium text-violet-700 ring-1 ring-violet-200 hover:bg-violet-100">
                      + {s}
                    </button>
                  ))}
                </div>
              )}
              <div className="mt-1.5 flex items-center justify-between gap-2">
                <span className="text-xs text-slate-400">
                  {long ? <span className="text-danger-700">{text.trim().length}/{MAX}: too long for the card</span>
                    : dirty ? <span className="font-medium text-due-800">Not saved yet</span>
                    : r.remark?.trim() && r.remark_by_name !== '-' ? `by ${r.remark_by_name}` : ''}
                </span>
                {!released && (
                  <button type="button" disabled={saveAll.isPending || !dirty || long}
                    onClick={() => saveAll.mutate(r)}
                    className="rounded-lg bg-white px-3 py-1.5 text-xs font-semibold text-slate-700 ring-1 ring-slate-300 hover:bg-slate-50 disabled:opacity-40">
                    Save
                  </button>
                )}
              </div>
            </li>
          )
        })}
      </ul>
    </Panel>
  )
}

function PositionHolders({ termId, termName }: { termId: string; termName: string }) {
  const [top, setTop] = useState(3)
  const q = useQuery({ queryKey: ['positionHolders', termId, top], queryFn: () => getPositionHolders(termId, top) })

  const byClass = useMemo(() => {
    const out: { name: string; rows: PositionHolder[] }[] = []
    for (const r of q.data ?? []) {
      const last = out[out.length - 1]
      if (last && last.name === r.class_name) last.rows.push(r)
      else out.push({ name: r.class_name, rows: [r] })
    }
    return out
  }, [q.data])
  const withheld = (q.data ?? []).filter((r) => r.withheld).length

  return (
    <Panel>
      <div className="flex flex-wrap items-center justify-between gap-3 print:hidden">
        <div className="flex rounded-xl bg-slate-100 p-1" role="group" aria-label="How many per class">
          {[1, 3, 5, 10].map((n) => (
            <button key={n} type="button" aria-pressed={top === n} onClick={() => setTop(n)}
              className={`rounded-lg px-3 py-1.5 text-sm font-medium transition ${top === n ? 'bg-white text-brand-700 shadow-sm' : 'text-slate-600 hover:text-slate-900'}`}>
              {n === 1 ? 'First' : `Top ${n}`}
            </button>
          ))}
        </div>
        {byClass.length > 0 && (
          <button type="button" onClick={() => window.print()}
            className="inline-flex items-center gap-1.5 rounded-xl bg-white px-3 py-2 text-sm font-semibold text-slate-700 ring-1 ring-slate-300 hover:bg-slate-50">
            <IconPrint /> Print
          </button>
        )}
      </div>

      {q.isLoading && <div className="mt-4 h-40 animate-pulse rounded-2xl bg-slate-100" />}
      {q.isError && <p className="mt-4 text-sm text-danger-700">{(q.error as Error).message}</p>}
      {q.isFetched && !q.isError && byClass.length === 0 && (
        <p className="mt-4 rounded-2xl bg-slate-50 px-3 py-8 text-center text-sm text-slate-500 ring-1 ring-slate-200">
          No position holders yet. A class&rsquo;s positions exist once its result cards are made.
        </p>
      )}

      <div id="report" className="mt-4">
        <h3 className="mb-3 hidden text-center text-lg font-bold print:block">Position holders · {termName}</h3>
        {/* A prize announced for a child whose result is held back over unpaid
            fees is a mistake worth catching first. */}
        {withheld > 0 && (
          <p className="mb-3 rounded-2xl bg-due-50 px-3 py-2 text-sm text-due-900 ring-1 ring-due-200 print:hidden">
            <b>{withheld} of these {withheld === 1 ? 'results is' : 'results are'} withheld</b> over unpaid fees.
            Settle the account or lift the withholding before announcing.
          </p>
        )}
        <div className="grid gap-3 lg:grid-cols-2">
          {byClass.map((g) => (
            <div key={g.name} className="break-inside-avoid rounded-2xl p-4 ring-1 ring-slate-200">
              <h4 className="mb-2 flex items-center gap-2 text-sm font-bold text-slate-800">
                <IconTrophy className="h-4 w-4 text-violet-600" /> {g.name}
              </h4>
              <ol className="space-y-2">
                {g.rows.map((r) => (
                  <li key={r.student_id} className="flex items-start gap-2.5 text-sm">
                    <span className={`flex h-7 w-7 shrink-0 items-center justify-center rounded-full text-xs font-bold tabular-nums ${
                      r.class_position === 1 ? 'bg-gradient-to-br from-violet-500 to-fuchsia-500 text-white'
                        : r.class_position === 2 ? 'bg-brand-500 text-white'
                        : r.class_position === 3 ? 'bg-sky-500 text-white' : 'bg-slate-100 text-slate-600'}`}>
                      {r.class_position}
                    </span>
                    <span className="min-w-0 flex-1">
                      <span className="font-semibold text-slate-800">{r.student_name}</span>
                      {r.section_name && <span className="ml-1 text-xs text-slate-400">{r.section_name}</span>}
                      {/* A shared position is stated: two on the same percentage are both first. */}
                      {r.tied_with > 1 && <span className="ml-1 text-xs text-due-700">(tied, {r.tied_with} pupils)</span>}
                      {r.withheld && <span className="ml-1 text-xs font-semibold text-danger-600">withheld</span>}
                      {r.remark?.trim() && <span className="block text-xs italic text-slate-400">{r.remark}</span>}
                    </span>
                    <span className="shrink-0 text-right tabular-nums">
                      <b className="text-slate-800">{r.percentage == null ? '-' : `${r.percentage}%`}</b>
                      {r.grade && <span className="ml-1 text-xs text-slate-400">{r.grade}</span>}
                    </span>
                  </li>
                ))}
              </ol>
            </div>
          ))}
        </div>
        {byClass.length > 0 && (
          <p className="mt-3 text-xs leading-relaxed text-slate-500 print:hidden">
            Positions come from the result cards themselves, so this list and the printed card cannot disagree. Pupils on
            the same percentage <b>share</b> a position; two firsts means there is no second. A pupil with no marks is not listed.
          </p>
        )}
      </div>
    </Panel>
  )
}

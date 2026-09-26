/**
 * Streams and board registration numbers.
 *
 * `enrollments.stream` and `enrollments.bise_reg_no` existed from the first
 * migration and no screen could set either. Without a stream a class-9 card was
 * computed over every paper in the class, so a Science pupil was marked out of
 * the Arts syllabus too (docs/EXAM-COMPUTATION-DESIGN.md). So this is ONE LIST
 * the school works down, not a field buried in each pupil's profile.
 *
 * Added in this pass: the class is chosen once with the other Exams tabs, a
 * class switch with unsaved edits asks first, and two pupils given the same
 * board number are flagged before the list goes to the board.
 */
import { useEffect, useMemo, useState } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { getClassStreams, listSubjects, setEnrollmentStream, type ClassStreamRow } from '@/lib/db'
import { useAuth } from '@/auth/AuthProvider'
import { toCSV, downloadCSV } from '@/lib/csv'
import { Avatar } from '@/components/Avatar'
import { IconCheck, IconStudents } from '@/components/icons'
import { Chip, Panel, PanelHead, Pills, examRole, useExamBasics, useExamPick, useUnsaved } from './examKit'

type Edit = { stream: string; bise: string }

export function StreamsTab() {
  const { classes } = useExamBasics()
  const { classId, setClass } = useExamPick()
  const guard = useUnsaved(false, 'streams-shell')
  const cls = (classes.data ?? []).find((c) => c.id === classId) ?? null
  return (
    <div className="space-y-4">
      <Panel>
        <PanelHead icon={<IconStudents />} title="Streams & board numbers"
          sub="Who is Science and who is Arts, and each pupil's board registration number. Matters for classes 9 to 12." />
        <Pills label="Class" value={cls?.id ?? ''} onPick={(id) => guard(() => setClass(id))}
          items={(classes.data ?? []).map((c) => ({ id: c.id, label: c.name }))} />
      </Panel>
      {cls
        ? <StreamSheet key={cls.id} classId={cls.id} className={cls.name} />
        : <Panel><p className="py-4 text-center text-sm text-slate-500">
            Pick a class. A pupil with no stream in a class whose subjects have streams cannot have a result card
            made at all, on purpose.
          </p></Panel>}
    </div>
  )
}

function StreamSheet({ classId, className }: { classId: string; className: string }) {
  const qc = useQueryClient()
  const { profile } = useAuth()
  const canEdit = examRole(profile?.role) === 'office'
  const pupils = useQuery({ queryKey: ['classStreams', classId], queryFn: () => getClassStreams(classId) })
  // The streams this class's subjects use, offered so the school reuses the
  // exact spelling: 'Science' and 'Sciences' are two streams to a computer.
  const subjects = useQuery({ queryKey: ['subjects', classId], queryFn: () => listSubjects(classId) })
  const knownStreams = [...new Set((subjects.data ?? []).map((s) => s.stream).filter((x): x is string => !!x))].sort()

  const [edits, setEdits] = useState<Record<string, Edit>>({})
  const [saved, setSaved] = useState<string | null>(null)
  useEffect(() => {
    const next: Record<string, Edit> = {}
    for (const p of pupils.data ?? []) next[p.enrollment_id] = { stream: p.stream ?? '', bise: p.bise_reg_no ?? '' }
    setEdits(next)
  }, [pupils.data])

  const rows = pupils.data ?? []
  const ed = (p: ClassStreamRow) => edits[p.enrollment_id] ?? { stream: p.stream ?? '', bise: p.bise_reg_no ?? '' }
  const isChanged = (p: ClassStreamRow) => (ed(p).stream.trim() || null) !== (p.stream ?? null)
    || (ed(p).bise.trim() || null) !== (p.bise_reg_no ?? null)
  const changed = rows.filter(isChanged)
  useUnsaved(changed.length > 0, 'streams')

  const known = new Set(knownStreams.map((x) => x.toLowerCase()))
  const noStream = knownStreams.length ? rows.filter((p) => !ed(p).stream.trim()).length : 0
  const strays = knownStreams.length ? rows.filter((p) => { const v = ed(p).stream.trim().toLowerCase(); return v !== '' && !known.has(v) }).length : 0
  // Two pupils with one board number is a real problem in March, and it is
  // easy to type: flagged here, before the list goes to the board.
  const dupes = useMemo(() => {
    const seen = new Map<string, number>()
    for (const p of rows) { const v = ed(p).bise.trim().toLowerCase(); if (v) seen.set(v, (seen.get(v) ?? 0) + 1) }
    return new Set([...seen.entries()].filter(([, n]) => n > 1).map(([v]) => v))
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [rows, edits])

  const save = useMutation({
    mutationFn: async () => {
      // Only the rows that changed, one at a time: a failure half way keeps the
      // first half, and the re-read below shows exactly which went in.
      let n = 0
      for (const p of changed) {
        const e = ed(p)
        await setEnrollmentStream(p.enrollment_id, e.stream.trim() || null, e.bise.trim() || null)
        n += 1
      }
      return n
    },
    onSuccess: (n) => setSaved(`Saved ${n} pupil${n === 1 ? '' : 's'}.`),
    onSettled: () => {
      void qc.invalidateQueries({ queryKey: ['classStreams', classId] })
      void qc.invalidateQueries({ queryKey: ['resultReadiness'] })
      void qc.invalidateQueries({ queryKey: ['examOverview'] })
    },
  })

  const setOne = (id: string, patch: Partial<Edit>) => {
    setSaved(null)
    setEdits((m) => ({ ...m, [id]: { ...(m[id] ?? { stream: '', bise: '' }), ...patch } }))
  }
  const applyToAllBlank = (stream: string) => {
    setSaved(null)
    setEdits((m) => {
      const next = { ...m }
      for (const p of rows) if (!ed(p).stream.trim()) next[p.enrollment_id] = { ...ed(p), stream }
      return next
    })
  }

  // The SAVED values, not the unsaved edits: a board form must agree with the
  // school's own records.
  const exportCsv = () => downloadCSV(`board-list-${className.replace(/\s+/g, '-')}`, toCSV(
    ['Roll', 'GR No', 'Name', "Father's name", 'Section', 'Stream', 'Board Reg No'],
    rows.map((p) => [p.roll_no ?? '', p.gr_no ?? '', p.full_name, p.father_name ?? '', p.section_name ?? '', p.stream ?? '', p.bise_reg_no ?? '']),
  ))

  if (pupils.isLoading) return <div className="h-48 animate-pulse rounded-3xl bg-slate-100" />
  if (pupils.isError) return <Panel><p className="text-sm text-danger-700">{(pupils.error as Error).message}</p></Panel>

  return (
    <Panel>
      <div className="flex flex-wrap items-center justify-between gap-3">
        <div>
          <h3 className="text-base font-semibold text-slate-900">{className}</h3>
          <div className="mt-1 flex flex-wrap gap-1.5">
            <Chip tone="slate">{rows.length} pupil{rows.length === 1 ? '' : 's'}</Chip>
            {knownStreams.length > 0 && <Chip tone={noStream ? 'due' : 'brand'}>{noStream ? `${noStream} without a stream` : 'every pupil has a stream'}</Chip>}
            {dupes.size > 0 && <Chip tone="danger">{dupes.size} board number{dupes.size === 1 ? '' : 's'} used twice</Chip>}
          </div>
        </div>
        {rows.length > 0 && (
          <button type="button" onClick={exportCsv}
            className="rounded-xl bg-white px-3 py-2 text-xs font-semibold text-slate-700 ring-1 ring-slate-300 hover:bg-slate-50">
            Export board list (CSV)
          </button>
        )}
      </div>

      {knownStreams.length === 0 ? (
        <p className="mt-4 rounded-2xl bg-slate-50 px-3 py-2 text-sm text-slate-600 ring-1 ring-slate-200">
          None of this class&rsquo;s subjects belongs to a stream, so every pupil takes every subject and no stream is
          needed. Give a subject a stream under <b>Setup</b> first if this class splits into Science and Arts. Board
          numbers can still be entered below.
        </p>
      ) : noStream > 0 && canEdit ? (
        <div className="mt-4 flex flex-wrap items-center gap-2 rounded-2xl bg-due-50 px-3 py-2 ring-1 ring-due-200">
          <span className="text-sm text-due-900">Set the {noStream} without a stream to:</span>
          {knownStreams.map((st) => (
            <button key={st} type="button" onClick={() => applyToAllBlank(st)}
              className="rounded-full bg-white px-3 py-1 text-xs font-semibold text-slate-700 ring-1 ring-slate-300 hover:bg-slate-50">
              {st}
            </button>
          ))}
        </div>
      ) : null}
      {strays > 0 && (
        <p className="mt-3 rounded-2xl bg-due-50 px-3 py-2 text-sm text-due-900 ring-1 ring-due-200">
          {strays} pupil{strays === 1 ? ' has' : 's have'} a stream none of this class&rsquo;s subjects uses
          ({knownStreams.join(', ')} are). Their card would carry only the subjects every pupil takes. Check the spelling.
        </p>
      )}

      <datalist id="known-streams">{knownStreams.map((st) => <option key={st} value={st} />)}</datalist>

      {rows.length === 0 ? (
        <p className="mt-4 text-center text-sm text-slate-500">Nobody is enrolled in this class this year.</p>
      ) : (
        <ul className="mt-4 divide-y divide-slate-100 overflow-hidden rounded-2xl ring-1 ring-slate-200">
          <li className="hidden grid-cols-[minmax(0,1fr)_11rem_14rem] gap-3 bg-slate-50 px-3 py-2 text-[11px] font-semibold uppercase tracking-wide text-slate-500 md:grid">
            <span>Pupil</span><span>Stream</span><span>Board registration no</span>
          </li>
          {rows.map((p) => {
            const e = ed(p)
            const missing = knownStreams.length > 0 && !e.stream.trim()
            const stray = knownStreams.length > 0 && !!e.stream.trim() && !known.has(e.stream.trim().toLowerCase())
            const dupe = !!e.bise.trim() && dupes.has(e.bise.trim().toLowerCase())
            return (
              <li key={p.enrollment_id} className={`grid gap-2 px-3 py-2.5 md:grid-cols-[minmax(0,1fr)_11rem_14rem] md:items-center md:gap-3 ${isChanged(p) ? 'bg-due-50/40' : ''}`}>
                <div className="flex min-w-0 items-center gap-2.5">
                  <Avatar name={p.full_name} size="sm" />
                  <div className="min-w-0">
                    <div className="truncate text-sm font-semibold text-slate-800">{p.full_name}</div>
                    <div className="text-xs text-slate-400">
                      {p.roll_no ? `Roll ${p.roll_no}` : 'No roll'}{p.gr_no ? ` · ${p.gr_no}` : ''}{p.section_name ? ` · ${p.section_name}` : ''}
                    </div>
                  </div>
                </div>
                <label className="block">
                  <span className="mb-0.5 block text-[11px] font-medium text-slate-500 md:hidden">Stream</span>
                  <input list="known-streams" value={e.stream} disabled={!canEdit}
                    onChange={(ev) => setOne(p.enrollment_id, { stream: ev.target.value })}
                    placeholder={knownStreams.length ? 'required' : 'none'} aria-label={`${p.full_name}: stream`}
                    className={`w-full rounded-xl border px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-brand-100 disabled:bg-slate-50 md:py-1.5 ${missing || stray ? 'border-due-400 bg-due-50/50' : 'border-slate-300 focus:border-brand-500'}`} />
                </label>
                <label className="block">
                  <span className="mb-0.5 block text-[11px] font-medium text-slate-500 md:hidden">Board registration no</span>
                  <input value={e.bise} disabled={!canEdit} maxLength={40}
                    onChange={(ev) => setOne(p.enrollment_id, { bise: ev.target.value })}
                    placeholder="e.g. 2026-BISE-01234" aria-label={`${p.full_name}: board registration number`}
                    className={`w-full rounded-xl border px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-brand-100 disabled:bg-slate-50 md:py-1.5 ${dupe ? 'border-danger-400 bg-danger-50' : 'border-slate-300 focus:border-brand-500'}`} />
                  {dupe && <span className="mt-0.5 block text-[11px] text-danger-700">Another pupil has this number.</span>}
                </label>
              </li>
            )
          })}
        </ul>
      )}

      {canEdit && rows.length > 0 && (
        <div className={`mt-4 flex flex-wrap items-center gap-3 ${changed.length ? 'sticky bottom-0 z-10 -mx-4 border-t border-slate-200 bg-white/95 px-4 py-3 backdrop-blur sm:static sm:mx-0 sm:border-0 sm:bg-transparent sm:p-0' : ''}`}>
          <button type="button" onClick={() => save.mutate()} disabled={changed.length === 0 || save.isPending}
            className="inline-flex flex-1 items-center justify-center gap-1.5 rounded-xl bg-brand-600 px-5 py-2.5 text-sm font-semibold text-white shadow-sm hover:bg-brand-700 disabled:opacity-50 sm:flex-none">
            <IconCheck /> {save.isPending ? 'Saving…' : changed.length ? `Save ${changed.length} change${changed.length === 1 ? '' : 's'}` : 'All saved'}
          </button>
          {saved && changed.length === 0 && <Chip tone="brand">{saved}</Chip>}
          {save.isError && <span className="text-sm text-danger-700">{(save.error as Error).message}</span>}
        </div>
      )}
      {!canEdit && <p className="mt-3 text-xs text-slate-500">Only the office can change a stream.</p>}
    </Panel>
  )
}

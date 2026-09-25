import { useState } from 'react'
import { useMutation, useQueries, useQuery, useQueryClient } from '@tanstack/react-query'
import { getCurrentSession, getFeeStructure, listClasses, setFeeAmount, type FeeStructureRow } from '@/lib/db'
import { fmtDate, fmtPKR } from '@/lib/format'
import { useAuth } from '@/auth/AuthProvider'
import { canWrite } from '@/auth/roles'
import { Button } from '@/components/ui'
import { ObserverNotice } from '@/components/ObserverNotice'

const key = (c: string, h: string) => `${c}:${h}`

/**
 * What every class pays, on one sheet.
 *
 * WHAT WAS WRONG. It showed ONE class at a time behind a "Select class…"
 * dropdown, so setting up a school of twelve classes meant twelve trips and no
 * way to see that Class 7 had been left on last year's tuition. Clearing a box
 * did nothing and said nothing, so a school trying to stop charging transport
 * to one class believed it had. A negative amount went to the database to be
 * refused there. Nothing added a class's charges up, which is the one number a
 * parent asks: "what is the monthly fee for Class 5?".
 *
 * Now it is one grid, classes down and fee heads across, with each class's
 * monthly total at the end, every change marked until it is saved, and one Save
 * that says exactly which boxes went through if any did not.
 */
export function FeeStructure({ onSetUpHeads }: { onSetUpHeads?: () => void }) {
  const qc = useQueryClient()
  const { profile } = useAuth()
  const mayWrite = canWrite(profile?.role)
  const session = useQuery({ queryKey: ['currentSession'], queryFn: getCurrentSession })
  const sessionId = session.data?.id
  const classes = useQuery({ queryKey: ['classes'], queryFn: listClasses })
  const list = classes.data ?? []

  // Reads fn_fee_structure per class: the amount in force TODAY plus any change
  // already scheduled. Selecting fee_structures directly returned every dated
  // row, so once a school had used Fee increase the grid showed an arbitrary one.
  const grids = useQueries({
    queries: list.map((c) => ({
      queryKey: ['feeStructure', sessionId, c.id],
      queryFn: () => getFeeStructure(sessionId!, c.id),
      enabled: !!sessionId,
    })),
  })
  const byClass = new Map<string, FeeStructureRow[]>()
  list.forEach((c, i) => { if (grids[i]?.data) byClass.set(c.id, grids[i].data!) })
  const loading = classes.isLoading || session.isLoading || grids.some((g) => g.isLoading)
  const failed = grids.find((g) => g.isError)

  // The heads, in the order the first class returned them, monthly ones first.
  const heads = [...([...byClass.values()][0] ?? [])]
    .sort((a, b) => Number(b.is_recurring) - Number(a.is_recurring))
    .map((r) => ({ id: r.fee_head_id, name: r.fee_head, monthly: r.is_recurring }))

  const [edits, setEdits] = useState<Record<string, string>>({})
  const [result, setResult] = useState<{ ok: number; failed: { cell: string; message: string }[] } | null>(null)

  const cellOf = (classId: string, headId: string) => byClass.get(classId)?.find((r) => r.fee_head_id === headId)
  const shown = (classId: string, headId: string) => {
    const k = key(classId, headId)
    if (k in edits) return edits[k]
    const a = cellOf(classId, headId)?.amount
    return a == null ? '' : String(a)
  }
  const problem = (classId: string, headId: string): string | null => {
    const k = key(classId, headId)
    if (!(k in edits)) return null
    const raw = edits[k].trim()
    const had = cellOf(classId, headId)?.amount
    if (raw === '') return had != null ? 'Enter 0 to stop charging it' : null
    const n = Number(raw)
    if (!Number.isFinite(n) || n < 0) return 'A whole number, 0 or more'
    if (!Number.isInteger(n)) return 'Whole rupees'
    return null
  }
  const changed = Object.keys(edits).filter((k) => {
    const [c, h] = k.split(':')
    const raw = edits[k].trim()
    const had = cellOf(c, h)?.amount
    if (raw === '' && had == null) return false
    return had == null || Number(raw) !== Number(had)
  })
  const bad = changed.filter((k) => { const [c, h] = k.split(':'); return !!problem(c, h) })
  const monthly = (classId: string) => heads.filter((h) => h.monthly)
    .reduce((t, h) => t + (Number(shown(classId, h.id)) || 0), 0)

  const save = useMutation({
    mutationFn: async () => {
      let ok = 0
      const failedCells: { cell: string; message: string }[] = []
      for (const k of changed) {
        const [c, h] = k.split(':')
        try {
          await setFeeAmount(sessionId!, c, h, Number(edits[k]))
          ok++
        } catch (e) {
          const cn = list.find((x) => x.id === c)?.name ?? 'A class'
          const hn = heads.find((x) => x.id === h)?.name ?? 'a fee head'
          failedCells.push({ cell: k, message: `${cn}, ${hn}: ${(e as Error).message}` })
        }
      }
      return { ok, failed: failedCells }
    },
    onSuccess: (r) => {
      setResult(r)
      // Keep the boxes that did not save, so the school can see and retry them.
      setEdits((e) => Object.fromEntries(Object.entries(e).filter(([k]) => r.failed.some((f) => f.cell === k))))
      qc.invalidateQueries({ queryKey: ['feeStructure'] })
    },
  })

  function copyFromAbove(i: number) {
    const above = list[i - 1]; const me = list[i]
    if (!above || !me) return
    const next = { ...edits }
    for (const h of heads) next[key(me.id, h.id)] = shown(above.id, h.id)
    setEdits(next); setResult(null)
  }
  const edit = (c: string, h: string, v: string) => { setEdits((e) => ({ ...e, [key(c, h)]: v })); setResult(null) }

  if (!sessionId && !session.isLoading) {
    return (
      <p className="rounded-xl border border-due-200 bg-due-50 p-3 text-sm text-due-800">
        There is no current school year, so there is nothing to price. Set one under Sessions first.
      </p>
    )
  }

  const noHeads = !loading && list.length > 0 && heads.length === 0

  return (
    <div className="space-y-4">
      {!mayWrite && <ObserverNotice what="the fee structure" />}
      {failed && <p className="rounded-xl bg-danger-50 px-3 py-2 text-sm text-danger-700">{(failed.error as Error).message}</p>}

      {/* The state a brand-new school is actually in. */}
      {noHeads && (
        <div className="rounded-2xl border border-due-200 bg-due-50 p-4 text-sm text-due-900">
          <div className="font-semibold">There are no fee heads yet.</div>
          <div className="mt-1 text-due-800">
            A fee head is a thing you charge for: Tuition, Admission Fee, Exam Fee. Create them first,
            then set an amount for each class here.
          </div>
          {onSetUpHeads && <Button className="mt-2" size="sm" variant="soft" tone="brand" onClick={onSetUpHeads}>Set up fee heads</Button>}
        </div>
      )}
      {!loading && list.length === 0 && (
        <p className="rounded-xl border border-dashed border-slate-300 bg-white px-4 py-6 text-center text-sm text-slate-500">
          No classes yet. Add them under Classes and sections.
        </p>
      )}
      {loading && <p className="text-sm text-slate-500">Loading the fee structure…</p>}

      {heads.length > 0 && (
        <>
          {/* ---------------------------------------------- phone: cards -- */}
          <ul className="space-y-3 md:hidden">
            {list.map((c, i) => (
              <li key={c.id} className="rounded-2xl border border-slate-200 bg-white p-4 shadow-card">
                <div className="flex items-baseline justify-between gap-2">
                  <span className="font-semibold text-slate-900">{c.name}</span>
                  <span className="text-sm text-slate-600">Monthly <b className="tabular-nums text-slate-900">{fmtPKR(monthly(c.id))}</b></span>
                </div>
                <div className="mt-3 space-y-2">
                  {heads.map((h) => (
                    <Cell key={h.id} label={h.name} monthly={h.monthly} value={shown(c.id, h.id)} disabled={!mayWrite}
                      changed={key(c.id, h.id) in edits} problem={problem(c.id, h.id)} next={cellOf(c.id, h.id)}
                      onChange={(v) => edit(c.id, h.id, v)} />
                  ))}
                </div>
                {mayWrite && i > 0 && (
                  <button type="button" onClick={() => copyFromAbove(i)} className="mt-2 text-xs font-medium text-brand-700 hover:underline">
                    Same as {list[i - 1].name}
                  </button>
                )}
              </li>
            ))}
          </ul>

          {/* ---------------------------------------------- wider: grid -- */}
          <div className="hidden overflow-x-auto rounded-2xl border border-slate-200 bg-white shadow-card md:block">
            <table className="w-full text-sm">
              <thead className="bg-slate-50 text-xs text-slate-500">
                <tr>
                  <th className="sticky left-0 z-10 bg-slate-50 px-3 py-2 text-left font-medium uppercase tracking-wide">Class</th>
                  {heads.map((h) => (
                    <th key={h.id} className="min-w-[8.5rem] px-2 py-2 text-left font-medium">
                      <div className="uppercase tracking-wide">{h.name}</div>
                      <div className={`text-[10px] font-normal normal-case ${h.monthly ? 'text-brand-700' : 'text-slate-400'}`}>{h.monthly ? 'every month' : 'once'}</div>
                    </th>
                  ))}
                  <th className="px-3 py-2 text-right font-medium uppercase tracking-wide">Every month</th>
                </tr>
              </thead>
              <tbody className="divide-y divide-slate-100">
                {list.map((c, i) => (
                  <tr key={c.id}>
                    <td className="sticky left-0 z-10 bg-white px-3 py-2 align-top">
                      <div className="font-medium text-slate-900">{c.name}</div>
                      {mayWrite && i > 0 && (
                        <button type="button" onClick={() => copyFromAbove(i)} className="whitespace-nowrap text-[11px] text-brand-700 hover:underline">
                          Same as above
                        </button>
                      )}
                    </td>
                    {heads.map((h) => (
                      <td key={h.id} className="px-2 py-2 align-top">
                        <Cell value={shown(c.id, h.id)} disabled={!mayWrite} changed={key(c.id, h.id) in edits}
                          problem={problem(c.id, h.id)} next={cellOf(c.id, h.id)} label={`${c.name}, ${h.name}`} hideLabel
                          onChange={(v) => edit(c.id, h.id, v)} />
                      </td>
                    ))}
                    <td className="whitespace-nowrap px-3 py-2 text-right align-top font-semibold tabular-nums text-slate-900">{fmtPKR(monthly(c.id))}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>

          {mayWrite && (changed.length > 0 || save.isPending || (result && result.failed.length === 0)) && (
            <div className="sticky bottom-3 z-10 flex flex-wrap items-center gap-3 rounded-2xl border border-slate-200 bg-white/95 px-4 py-3 shadow-raised backdrop-blur">
              <Button onClick={() => save.mutate()} disabled={changed.length === 0 || bad.length > 0 || save.isPending}>
                {save.isPending ? 'Saving…' : changed.length ? `Save ${changed.length} change${changed.length === 1 ? '' : 's'}` : 'No changes to save'}
              </Button>
              {changed.length > 0 && !save.isPending && (
                <button type="button" onClick={() => { setEdits({}); setResult(null) }} className="text-sm text-slate-500 hover:underline">Undo them</button>
              )}
              {bad.length > 0 && <span className="text-sm text-danger-700">Fix the {bad.length} box{bad.length === 1 ? '' : 'es'} in red first.</span>}
              {result && result.failed.length === 0 && <span className="text-sm font-medium text-brand-700">{result.ok} saved. New challans use them from today.</span>}
            </div>
          )}
          {result && result.failed.length > 0 && (
            <div className="rounded-xl border border-danger-200 bg-danger-50 p-3 text-sm text-danger-800">
              <b>{result.ok} saved, {result.failed.length} not.</b> The ones that did not are still marked above.
              <ul className="mt-1 list-disc pl-5">{result.failed.map((f) => <li key={f.cell}>{f.message}</li>)}</ul>
            </div>
          )}
          <p className="text-xs text-slate-500">
            A change here applies from today. Challans already issued keep the amount they were issued at. To raise
            everything at once, from a date you choose, use Fee increase.
          </p>
        </>
      )}
    </div>
  )
}

function Cell({ value, onChange, changed, problem, next, disabled, label, hideLabel, monthly }: {
  value: string; onChange: (v: string) => void; changed: boolean; problem: string | null
  next?: FeeStructureRow; disabled: boolean; label: string; hideLabel?: boolean; monthly?: boolean
}) {
  const ring = problem ? 'border-danger-300 ring-2 ring-danger-100' : changed ? 'border-brand-400 ring-2 ring-brand-100' : 'border-slate-300'
  return (
    <label className={hideLabel ? 'block' : 'flex items-center justify-between gap-3'}>
      <span className={hideLabel ? 'sr-only' : 'min-w-0 text-sm text-slate-700'}>
        {label}{!hideLabel && monthly && <span className="ml-1.5 text-[11px] text-brand-700">monthly</span>}
      </span>
      <span className={hideLabel ? 'block' : 'w-36 shrink-0'}>
        <span className="relative block">
          <span className="pointer-events-none absolute inset-y-0 left-2 flex items-center text-xs text-slate-400">Rs</span>
          <input type="number" inputMode="numeric" min="0" step="1" value={value} disabled={disabled} aria-label={label}
            onChange={(e) => onChange(e.target.value)}
            className={`w-full rounded-lg border bg-white py-1.5 pl-8 pr-2 text-right text-sm tabular-nums outline-none focus:border-brand-500 disabled:bg-slate-50 ${ring}`} />
        </span>
        {problem ? <span className="mt-0.5 block text-[11px] text-danger-700">{problem}</span>
          : next?.next_from ? <span className="mt-0.5 block text-[11px] text-due-800">{fmtPKR(Number(next.next_amount))} from {fmtDate(next.next_from)}</span>
          : null}
      </span>
    </label>
  )
}

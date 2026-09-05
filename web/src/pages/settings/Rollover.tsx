import { useEffect, useMemo, useState } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import {
  getCurrentSession, listSessions, listClasses, runRollover, undoRollover,
  type RolloverResult, type RolloverUndoResult,
} from '@/lib/db'
import { defaultRolloverRules, rulesToPayload, type RolloverAction, type RolloverRule } from '@/lib/rollover'
import { fmtPKR } from '@/lib/format'

const FIELD = 'mt-1 w-full rounded border border-slate-300 px-3 py-2 text-sm focus:border-brand-500 focus:outline-none focus:ring-1 focus:ring-brand-500'
const ACTIONS: { value: RolloverAction; label: string }[] = [
  { value: 'promote', label: 'Promote to' },
  { value: 'retain', label: 'Retain (detain)' },
  { value: 'graduate', label: 'Graduate (alumni)' },
]

export function Rollover() {
  const qc = useQueryClient()
  const current = useQuery({ queryKey: ['currentSession'], queryFn: getCurrentSession })
  const sessions = useQuery({ queryKey: ['sessions'], queryFn: listSessions })
  const classes = useQuery({ queryKey: ['classes'], queryFn: listClasses })

  const [fromId, setFromId] = useState('')
  const [toId, setToId] = useState('')
  const [rules, setRules] = useState<Record<string, RolloverRule>>({})
  const [preview, setPreview] = useState<RolloverResult | null>(null)
  const [committed, setCommitted] = useState<RolloverResult | null>(null)
  const [undo, setUndo] = useState<RolloverUndoResult | null>(null)

  // Default the source to the current session once it loads.
  useEffect(() => { if (current.data && !fromId) setFromId(current.data.id) }, [current.data, fromId])
  // Seed the per-class rules once classes load.
  useEffect(() => {
    if (classes.data && classes.data.length && Object.keys(rules).length === 0) {
      setRules(defaultRolloverRules(classes.data))
    }
  }, [classes.data, rules])

  const resetResults = () => { setPreview(null); setCommitted(null); setUndo(null) }
  function setRule(classId: string, patch: Partial<RolloverRule>) {
    setRules((r) => ({ ...r, [classId]: { ...r[classId], ...patch } }))
    resetResults()
  }

  const otherSessions = useMemo(
    () => (sessions.data ?? []).filter((s) => s.id !== fromId),
    [sessions.data, fromId],
  )

  const preflight = useMutation({
    mutationFn: () => runRollover(fromId, toId, rulesToPayload(rules), false),
    onSuccess: (r) => { setPreview(r); setCommitted(null); setUndo(null) },
  })
  const commit = useMutation({
    mutationFn: () => runRollover(fromId, toId, rulesToPayload(rules), true),
    onSuccess: (r) => {
      setCommitted(r); setPreview(null)
      qc.invalidateQueries({ queryKey: ['students'] })
      qc.invalidateQueries({ queryKey: ['sessions'] })
    },
  })
  const undoMut = useMutation({
    mutationFn: () => undoRollover(toId),
    onSuccess: (r) => { setUndo(r); setCommitted(null); setPreview(null); qc.invalidateQueries({ queryKey: ['students'] }) },
  })

  const ready = !!fromId && !!toId && fromId !== toId && (classes.data?.length ?? 0) > 0
  const toName = sessions.data?.find((s) => s.id === toId)?.name ?? 'the new session'
  const busy = preflight.isPending || commit.isPending || undoMut.isPending

  return (
    <div className="max-w-4xl space-y-5">
      <div className="rounded-lg border border-slate-200 bg-white p-4">
        <div className="text-sm font-medium text-slate-800">Year-end rollover</div>
        <p className="mt-1 text-sm text-slate-600">
          Move the whole roster into a new academic session: promote each class up, detain (retain) students in
          place, or graduate the leaving class to alumni. New roll numbers are assigned, and each student’s
          outstanding <span className="font-medium">arrears carry over automatically</span>. Always
          <span className="font-medium"> Preview</span> first; a rollover can be <span className="font-medium">undone</span> until
          attendance, fees or exams are recorded in the new session.
        </p>
      </div>

      <div className="grid gap-4 sm:grid-cols-2">
        <label className="block">
          <span className="text-sm text-slate-600">From session (the year ending)</span>
          <select value={fromId} onChange={(e) => { setFromId(e.target.value); resetResults() }} className={FIELD}>
            <option value="">Select…</option>
            {sessions.data?.map((s) => <option key={s.id} value={s.id}>{s.name}{s.is_current ? ' (current)' : ''}</option>)}
          </select>
        </label>
        <label className="block">
          <span className="text-sm text-slate-600">To session (the new year)</span>
          <select value={toId} onChange={(e) => { setToId(e.target.value); resetResults() }} className={FIELD}>
            <option value="">Select…</option>
            {otherSessions.map((s) => <option key={s.id} value={s.id}>{s.name}</option>)}
          </select>
        </label>
      </div>
      {otherSessions.length === 0 && (
        <p className="rounded bg-amber-50 p-3 text-sm text-amber-700">
          You need a second session to roll into. Create next year’s session under <span className="font-medium">Sessions</span> first.
        </p>
      )}

      <div className="overflow-hidden rounded-lg border border-slate-200 bg-white">
        <div className="border-b border-slate-100 px-3 py-2 text-sm font-medium text-slate-700">What happens to each class</div>
        <table className="min-w-full text-sm">
          <tbody className="divide-y divide-slate-100">
            {classes.data?.map((c) => {
              const rule = rules[c.id] ?? { action: 'promote', toClassId: null }
              return (
                <tr key={c.id}>
                  <td className="px-3 py-2 font-medium text-slate-800">{c.name}</td>
                  <td className="px-3 py-2">
                    <div className="flex flex-wrap items-center gap-2">
                      <select value={rule.action} onChange={(e) => setRule(c.id, { action: e.target.value as RolloverAction })}
                        className="rounded border border-slate-300 px-2 py-1 text-sm focus:border-brand-500 focus:outline-none">
                        {ACTIONS.map((a) => <option key={a.value} value={a.value}>{a.label}</option>)}
                      </select>
                      {rule.action === 'promote' && (
                        <select value={rule.toClassId ?? ''} onChange={(e) => setRule(c.id, { toClassId: e.target.value || null })}
                          className="rounded border border-slate-300 px-2 py-1 text-sm focus:border-brand-500 focus:outline-none">
                          <option value="">Choose class…</option>
                          {classes.data?.map((t) => <option key={t.id} value={t.id}>{t.name}</option>)}
                        </select>
                      )}
                    </div>
                  </td>
                </tr>
              )
            })}
          </tbody>
        </table>
      </div>

      <div className="flex flex-wrap gap-2">
        <button onClick={() => preflight.mutate()} disabled={!ready || busy}
          className="rounded border border-brand-300 bg-brand-50 px-4 py-2 text-sm font-medium text-brand-700 hover:bg-brand-100 disabled:opacity-60">
          {preflight.isPending ? 'Previewing…' : 'Preview'}
        </button>
        <button
          onClick={() => { if (confirm(`Commit rollover into ${toName}? You can undo this until activity is recorded there.`)) commit.mutate() }}
          disabled={!ready || busy || !preview}
          title={!preview ? 'Run a preview first' : ''}
          className="rounded bg-brand-600 px-4 py-2 text-sm font-medium text-white hover:bg-brand-700 disabled:opacity-60">
          {commit.isPending ? 'Rolling over…' : 'Commit rollover'}
        </button>
        <button
          onClick={() => { if (confirm(`Undo the rollover into ${toName}? This removes the promoted/retained enrolments there.`)) undoMut.mutate() }}
          disabled={!toId || busy}
          className="ml-auto rounded border border-slate-300 bg-white px-4 py-2 text-sm font-medium text-slate-600 hover:bg-slate-50 disabled:opacity-60">
          {undoMut.isPending ? 'Undoing…' : 'Undo rollover'}
        </button>
      </div>
      {(preflight.isError || commit.isError || undoMut.isError) && (
        <p className="text-sm text-red-600">
          {((preflight.error || commit.error || undoMut.error) as Error).message}
        </p>
      )}

      {undo && (
        <div className="rounded-lg border border-slate-200 bg-white p-4 text-sm">
          <span className="rounded bg-slate-100 px-2 py-0.5 text-xs font-medium text-slate-700">Undo complete</span>
          <p className="mt-2 text-slate-700">{undo.undone} enrolment{undo.undone === 1 ? '' : 's'} removed from {toName}. {undo.note}</p>
        </div>
      )}

      {(preview || committed) && <ResultView result={(committed ?? preview)!} committed={!!committed} toName={toName} />}
    </div>
  )
}

function ResultView({ result, committed, toName }: { result: RolloverResult; committed: boolean; toName: string }) {
  return (
    <div className="rounded-lg border border-slate-200 bg-white p-4">
      <div className="flex items-center gap-2">
        <span className={`rounded px-2 py-0.5 text-xs font-medium ${committed ? 'bg-emerald-100 text-emerald-700' : 'bg-sky-100 text-sky-700'}`}>
          {committed ? 'Rollover complete' : 'Preview. Nothing saved yet'}
        </span>
        <span className="text-sm text-slate-600">{result.total} student{result.total === 1 ? '' : 's'}</span>
      </div>
      <div className="mt-3 flex flex-wrap gap-2 text-xs">
        <Chip label="Promoted" value={result.promoted} tone="emerald" />
        <Chip label="Retained" value={result.retained} tone="sky" />
        <Chip label="Graduated" value={result.graduated} tone="violet" />
        {result.unmapped > 0 && <Chip label="No target class" value={result.unmapped} tone="red" />}
        {result.skipped > 0 && <Chip label="Skipped (already in new year)" value={result.skipped} tone="amber" />}
      </div>

      {committed && (
        <p className="mt-3 rounded bg-emerald-50 p-3 text-sm text-emerald-800">
          Done. When you’re ready to start the new year, set <span className="font-medium">{toName}</span> as the current
          session under <span className="font-medium">Sessions</span>.
        </p>
      )}

      <div className="mt-4 overflow-x-auto">
        <table className="min-w-full text-sm">
          <thead>
            <tr className="text-left text-xs uppercase tracking-wide text-slate-400">
              <th className="py-1 pr-3">Student</th>
              <th className="py-1 pr-3">GR</th>
              <th className="py-1 pr-3">From</th>
              <th className="py-1 pr-3">To</th>
              <th className="py-1 pr-3">Roll</th>
              <th className="py-1 pr-3">Arrears</th>
              <th className="py-1">Action</th>
            </tr>
          </thead>
          <tbody>
            {result.rows.slice(0, 300).map((r, i) => (
              <tr key={r.student_id + i} className="border-t border-slate-100">
                <td className="py-1 pr-3 text-slate-700">{r.name}</td>
                <td className="py-1 pr-3 text-slate-500">{r.gr_no ?? '-'}</td>
                <td className="py-1 pr-3 text-slate-600">{r.from_class ?? '-'}</td>
                <td className="py-1 pr-3 text-slate-600">{r.to_class ?? '-'}</td>
                <td className="py-1 pr-3 text-slate-600">{r.roll_no ?? '-'}</td>
                <td className="py-1 pr-3 text-slate-600">{Number(r.balance) > 0 ? fmtPKR(Number(r.balance)) : '-'}</td>
                <td className="py-1">
                  <ActionBadge action={r.action} message={r.message} />
                </td>
              </tr>
            ))}
          </tbody>
        </table>
        {result.rows.length > 300 && <p className="mt-2 text-xs text-slate-400">Showing the first 300 of {result.rows.length}.</p>}
      </div>
    </div>
  )
}

function ActionBadge({ action, message }: { action: string; message: string | null }) {
  const tone: Record<string, string> = {
    promote: 'text-emerald-700', retain: 'text-sky-700', graduate: 'text-violet-700',
    skipped: 'text-amber-700', unmapped: 'text-red-600',
  }
  return <span className={tone[action] ?? 'text-slate-600'} title={message ?? ''}>{action}{message ? ' •' : ''}</span>
}

function Chip({ label, value, tone }: { label: string; value: number; tone: string }) {
  const tones: Record<string, string> = {
    emerald: 'bg-emerald-50 text-emerald-700', sky: 'bg-sky-50 text-sky-700',
    violet: 'bg-violet-50 text-violet-700', amber: 'bg-amber-50 text-amber-700', red: 'bg-red-50 text-red-700',
  }
  return <span className={`rounded px-2 py-1 font-medium ${tones[tone]}`}>{label}: {value}</span>
}

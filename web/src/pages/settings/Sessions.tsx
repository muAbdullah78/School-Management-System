import { useState } from 'react'
import { Link } from 'react-router-dom'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { listSessions, addSession, setSessionDates, setCurrentSession, type SessionFull } from '@/lib/db'
import { fmtDate } from '@/lib/format'
import { today } from '@/lib/dates'
import { useAuth } from '@/auth/AuthProvider'
import { LoadError, Button, inputClass } from '@/components/ui'
import { AskDialog } from '@/components/AskDialog'
import { C } from '@/components/viz'

function daysBetween(a: string, b: string): number {
  const [ya, ma, da] = a.split('-').map(Number)
  const [yb, mb, db] = b.split('-').map(Number)
  return Math.round((Date.UTC(yb, mb - 1, db) - Date.UTC(ya, ma - 1, da)) / 86_400_000)
}

/**
 * The school's academic years.
 *
 * THE TWO DATES ARE REQUIRED, and 0130 derives every date bound in the product
 * from them: without them the software cannot tell whether the year has ended,
 * which year a date belongs to, or that somebody typed 2062 for 2026.
 *
 * WHAT WAS WRONG. A year saved without dates (every school set up through the
 * first-run wizard has one) was told to "add it again below with its first and
 * last day". There was no way to edit a year, so doing as it said made a SECOND
 * year of the same name, with no children in it, beside the one that had them.
 * Dates are now set on the year itself. "Set current" changed the whole
 * school's default year on one tap, with no question; it now asks, and says
 * what changes. And nothing said that adding a year moves nobody into it.
 */
export function Sessions() {
  const qc = useQueryClient()
  const { profile } = useAuth()
  const mayManage = !!profile && ['owner', 'principal'].includes(profile.role)
  const sessions = useQuery({ queryKey: ['sessions'], queryFn: listSessions })
  const [name, setName] = useState('')
  const [starts, setStarts] = useState('')
  const [ends, setEnds] = useState('')
  const [editing, setEditing] = useState<string | null>(null)
  const [switching, setSwitching] = useState<SessionFull | null>(null)

  const invalidate = () => {
    qc.invalidateQueries({ queryKey: ['sessions'] })
    qc.invalidateQueries({ queryKey: ['currentSession'] })
  }

  const add = useMutation({
    mutationFn: () => addSession(name.trim(), starts, ends),
    onSuccess: () => { setName(''); setStarts(''); setEnds(''); invalidate() },
  })
  const makeCurrent = useMutation({
    mutationFn: (id: string) => setCurrentSession(id),
    onSuccess: () => { setSwitching(null); invalidate() },
  })

  const list = sessions.data ?? []
  const current = list.find((s) => s.is_current)
  const nameTaken = !!name.trim() && list.some((s) => s.name.trim().toLowerCase() === name.trim().toLowerCase())
  const ready = !!name.trim() && !!starts && !!ends && ends > starts && !nameTaken
  const noDates = list.filter((s) => !s.starts_on || !s.ends_on)

  return (
    <div className="max-w-3xl space-y-4">
      <LoadError of={[sessions]} what="The school years" />

      {noDates.length > 0 && (
        <div className="rounded-2xl border border-due-200 bg-due-50 p-4 text-sm text-due-900">
          <p className="font-semibold">{noDates.length === 1 ? `${noDates[0].name} has no dates` : `${noDates.length} years have no dates`}</p>
          <p className="mt-1 text-due-800">
            Nothing in a year without dates can be checked: a mistyped date for attendance, a challan
            or an expense lands in it without a word. Press <b>Set its dates</b> on the year below.
          </p>
        </div>
      )}

      {list.length === 0 && !sessions.isLoading && (
        <p className="rounded-xl border border-dashed border-slate-300 bg-white px-4 py-6 text-center text-sm text-slate-500">
          No school years yet. Add the first one below.
        </p>
      )}

      <ul className="space-y-3">
        {list.map((s) => (
          <li key={s.id}>
            <SessionCard s={s} mayManage={mayManage} editing={editing === s.id}
              onEdit={() => setEditing(s.id)} onDone={() => { setEditing(null); invalidate() }} onCancel={() => setEditing(null)}
              onMakeCurrent={() => { makeCurrent.reset(); setSwitching(s) }} />
          </li>
        ))}
      </ul>

      {mayManage && (
        <form className="rounded-2xl border border-slate-200 bg-white p-4 shadow-card sm:p-5" onSubmit={(e) => { e.preventDefault(); if (ready) add.mutate() }}>
          <h3 className="text-sm font-semibold text-slate-900">Add a school year</h3>
          <p className="mt-0.5 text-xs text-slate-500">
            This makes an empty year. It moves nobody into it: at the end of the year,{' '}
            <Link to="/settings?tab=rollover" className="font-medium text-brand-700 hover:underline">Year rollover</Link>{' '}
            moves every class up and carries each child&rsquo;s arrears across.
          </p>
          <div className="mt-3 grid gap-3 sm:grid-cols-4">
            <label className="block sm:col-span-2">
              <span className="mb-1 block text-xs font-medium text-slate-600">Name</span>
              <input value={name} onChange={(e) => setName(e.target.value)} className={inputClass} placeholder="e.g. 2026-2027" />
              {nameTaken && <span className="mt-1 block text-xs text-danger-700">There is already a year called that.</span>}
            </label>
            <label className="block">
              <span className="mb-1 block text-xs font-medium text-slate-600">First day</span>
              <input type="date" value={starts} max={ends || undefined} onChange={(e) => setStarts(e.target.value)} className={inputClass} />
            </label>
            <label className="block">
              <span className="mb-1 block text-xs font-medium text-slate-600">Last day</span>
              <input type="date" value={ends} min={starts || undefined} onChange={(e) => setEnds(e.target.value)} className={inputClass} />
            </label>
          </div>
          {starts && ends && ends <= starts && <p className="mt-2 text-xs text-danger-700">The last day is before the first.</p>}
          {add.isError && <p className="mt-2 rounded-lg bg-danger-50 px-3 py-2 text-sm text-danger-700">{(add.error as Error).message}</p>}
          <div className="mt-3">
            <Button type="submit" disabled={!ready || add.isPending}>{add.isPending ? 'Adding…' : 'Add the year'}</Button>
          </div>
        </form>
      )}

      {switching && (
        <AskDialog
          title={`Make ${switching.name} the current year?`}
          intro={
            <>
              New admissions, challans, the register and every report will default to <b>{switching.name}</b>
              {current ? <> instead of <b>{current.name}</b></> : null}. Nobody is moved: children stay in the
              classes of the year they are in until Year rollover moves them.
              {!switching.starts_on && <><br /><br /><b>This year has no dates yet.</b> Set them first, or nothing in it can be date-checked.</>}
            </>
          }
          confirmLabel={`Make ${switching.name} current`}
          busy={makeCurrent.isPending}
          error={makeCurrent.error ? (makeCurrent.error as Error).message : null}
          onCancel={() => setSwitching(null)}
          onSubmit={() => makeCurrent.mutate(switching.id)}
        />
      )}
    </div>
  )
}

function SessionCard({ s, mayManage, editing, onEdit, onDone, onCancel, onMakeCurrent }: {
  s: SessionFull; mayManage: boolean; editing: boolean
  onEdit: () => void; onDone: () => void; onCancel: () => void; onMakeCurrent: () => void
}) {
  const t = today()
  const dated = !!s.starts_on && !!s.ends_on
  const total = dated ? daysBetween(s.starts_on!, s.ends_on!) + 1 : 0
  const gone = dated ? Math.min(Math.max(daysBetween(s.starts_on!, t) + 1, 0), total) : 0
  const state = !dated ? 'nodates' : t < s.starts_on! ? 'ahead' : t > s.ends_on! ? 'over' : 'running'
  return (
    <div className={`rounded-2xl border bg-white p-4 shadow-card ${s.is_current ? 'border-brand-300 ring-1 ring-brand-200' : 'border-slate-200'}`}>
      <div className="flex flex-wrap items-start justify-between gap-2">
        <div className="min-w-0">
          <div className="flex flex-wrap items-center gap-2">
            <span className="text-base font-semibold text-slate-900">{s.name}</span>
            {s.is_current && <span className="rounded-full bg-brand-600 px-2 py-0.5 text-[11px] font-semibold text-white">Current</span>}
            {s.is_closed && <span className="rounded-full bg-slate-200 px-2 py-0.5 text-[11px] font-medium text-slate-600">Closed</span>}
          </div>
          <div className={`text-sm ${dated ? 'text-slate-600' : 'font-medium text-due-800'}`}>
            {dated ? `${fmtDate(s.starts_on)} to ${fmtDate(s.ends_on)}` : 'No dates set'}
          </div>
        </div>
        {mayManage && !editing && (
          <div className="flex flex-wrap gap-1.5">
            <Button size="sm" variant="soft" tone={dated ? 'neutral' : 'due'} onClick={onEdit}>{dated ? 'Change dates' : 'Set its dates'}</Button>
            {!s.is_current && <Button size="sm" variant="soft" tone="brand" onClick={onMakeCurrent}>Make current</Button>}
          </div>
        )}
      </div>
      {dated && (
        <div className="mt-3">
          <div className="h-2 overflow-hidden rounded-full bg-slate-100" aria-hidden>
            <div className="h-full rounded-full" style={{ width: `${total ? (gone / total) * 100 : 0}%`, background: C.series }} />
          </div>
          <div className="mt-1 text-xs text-slate-500">
            {state === 'running' ? `Day ${gone} of ${total} · ${total - gone} days to go`
              : state === 'ahead' ? `Starts in ${daysBetween(t, s.starts_on!)} days`
              : 'Finished'}
          </div>
        </div>
      )}
      {editing && <DatesForm s={s} onDone={onDone} onCancel={onCancel} />}
    </div>
  )
}

function DatesForm({ s, onDone, onCancel }: { s: SessionFull; onDone: () => void; onCancel: () => void }) {
  const [a, setA] = useState(s.starts_on ?? '')
  const [b, setB] = useState(s.ends_on ?? '')
  const save = useMutation({ mutationFn: () => setSessionDates(s.id, a, b), onSuccess: onDone })
  const ok = !!a && !!b && b > a
  return (
    <form className="mt-3 rounded-xl border border-slate-200 bg-slate-50 p-3" onSubmit={(e) => { e.preventDefault(); if (ok) save.mutate() }}>
      <div className="grid gap-3 sm:grid-cols-2">
        <label className="block">
          <span className="mb-1 block text-xs font-medium text-slate-600">First day</span>
          <input type="date" value={a} max={b || undefined} onChange={(e) => setA(e.target.value)} className={inputClass} />
        </label>
        <label className="block">
          <span className="mb-1 block text-xs font-medium text-slate-600">Last day</span>
          <input type="date" value={b} min={a || undefined} onChange={(e) => setB(e.target.value)} className={inputClass} />
        </label>
      </div>
      <p className="mt-2 text-xs text-slate-500">
        Refused if it would leave attendance or challans already recorded in this year outside it, or
        overlap another year.
      </p>
      {save.isError && <p className="mt-2 rounded-lg bg-danger-50 px-3 py-2 text-sm text-danger-700">{(save.error as Error).message}</p>}
      <div className="mt-3 flex gap-2">
        <Button type="submit" size="sm" disabled={!ok || save.isPending}>{save.isPending ? 'Saving…' : 'Save the dates'}</Button>
        <Button type="button" size="sm" variant="soft" tone="neutral" onClick={onCancel}>Cancel</Button>
      </div>
    </form>
  )
}

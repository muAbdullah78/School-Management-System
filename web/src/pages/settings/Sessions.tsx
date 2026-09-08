import { useState } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { listSessions, createSession, setCurrentSession } from '@/lib/db'
import { fmtDate } from '@/lib/format'

const FIELD = 'mt-1 w-full rounded border border-slate-300 px-3 py-2 text-sm focus:border-brand-500 focus:outline-none focus:ring-1 focus:ring-brand-500'

/**
 * The school's academic years.
 *
 * THE TWO DATES ARE REQUIRED NOW, and they were optional. `createSession`
 * mapped an empty string to null and the database accepted it, so a year could
 * be added with nothing but a name. Migration 0130 derives every date bound in
 * the product from these two fields: without them the software cannot tell
 * whether the year has ended, which year a date belongs to, or that somebody
 * has typed 2062 for 2026.
 *
 * A YEAR ALREADY SAVED WITHOUT THEM IS SHOWN AS SUCH, in the list above the
 * form, rather than rendering as a blank gap. Every school set up through the
 * first-run wizard has one, because that screen never asked, and this is the
 * screen they are sent to in order to fix it.
 */
export function Sessions() {
  const qc = useQueryClient()
  const sessions = useQuery({ queryKey: ['sessions'], queryFn: listSessions })
  const [name, setName] = useState('')
  const [starts, setStarts] = useState('')
  const [ends, setEnds] = useState('')

  const invalidate = () => {
    qc.invalidateQueries({ queryKey: ['sessions'] })
    qc.invalidateQueries({ queryKey: ['currentSession'] })
  }

  const add = useMutation({
    mutationFn: () => createSession(name.trim(), starts, ends),
    onSuccess: () => { setName(''); setStarts(''); setEnds(''); invalidate() },
  })
  // Both dates, and in the right order. Checked here as well as in the database
  // so the button explains itself before it is pressed rather than after.
  const ready = !!name.trim() && !!starts && !!ends && ends > starts
  const missingDates = !!name.trim() && (!starts || !ends)
  const makeCurrent = useMutation({
    mutationFn: (id: string) => setCurrentSession(id),
    onSuccess: invalidate,
  })

  return (
    <div className="max-w-2xl space-y-6">
      <div className="overflow-hidden rounded-lg border border-slate-200 bg-white">
        {sessions.data?.length === 0 && <div className="p-3 text-sm text-slate-500">No sessions yet. Add the first one below.</div>}
        <ul className="divide-y divide-slate-100">
          {sessions.data?.map((s) => (
            <li key={s.id} className="flex items-center justify-between px-3 py-2 text-sm">
              <span>
                <span className="font-medium text-slate-800">{s.name}</span>
                {s.starts_on && s.ends_on ? (
                  <span className="text-slate-500"> · {fmtDate(s.starts_on)} to {fmtDate(s.ends_on)}</span>
                ) : (
                  /* Said outright. This used to render as "· - to -", which
                     reads as a formatting quirk rather than as the thing that
                     stops the software checking any date in this year. */
                  <span className="text-amber-700"> · no dates set, so nothing in
                    this year is date-checked. Add it again below with its first
                    and last day.</span>
                )}
                {s.is_current && <span className="ml-2 rounded-full bg-emerald-100 px-2 py-0.5 text-xs font-medium text-emerald-700">current</span>}
              </span>
              {!s.is_current && (
                <button onClick={() => makeCurrent.mutate(s.id)} disabled={makeCurrent.isPending}
                  className="rounded border border-slate-300 px-2.5 py-1 text-xs font-medium text-slate-700 hover:bg-slate-50 disabled:opacity-60">
                  Set current
                </button>
              )}
            </li>
          ))}
        </ul>
      </div>
      {makeCurrent.isError && <p className="text-sm text-red-600">{(makeCurrent.error as Error).message}</p>}

      <form className="grid gap-3 sm:grid-cols-4" onSubmit={(e) => { e.preventDefault(); if (ready) add.mutate() }}>
        <label className="block sm:col-span-2">
          <span className="text-sm text-slate-600">Session name</span>
          <input value={name} onChange={(e) => setName(e.target.value)} className={FIELD} placeholder="e.g. 2025-2026" />
        </label>
        <label className="block">
          <span className="text-sm text-slate-600">
            Starts <span className="text-rose-600">*</span>
          </span>
          <input required type="date" value={starts} max={ends || undefined}
            onChange={(e) => setStarts(e.target.value)} className={FIELD} />
        </label>
        <label className="block">
          <span className="text-sm text-slate-600">
            Ends <span className="text-rose-600">*</span>
          </span>
          <input required type="date" value={ends} min={starts || undefined}
            onChange={(e) => setEnds(e.target.value)} className={FIELD} />
        </label>
        {add.isError && <p className="text-sm text-red-600 sm:col-span-4">{(add.error as Error).message}</p>}
        {missingDates && (
          <p className="text-xs text-slate-500 sm:col-span-4">
            A school year needs its first and last day. Attendance, challans,
            expenses and fee changes are all checked against them, so a mistyped
            year is caught instead of quietly landing in a year nobody looks at.
          </p>
        )}
        <button type="submit" disabled={!ready || add.isPending}
          className="rounded bg-brand-600 px-4 py-2 text-sm font-medium text-white hover:bg-brand-700 disabled:opacity-60 sm:col-span-1">
          {add.isPending ? 'Adding…' : 'Add session'}
        </button>
      </form>
      <p className="text-xs text-slate-500">
        The current session is the one new admissions, fees and attendance
        default to.
      </p>
    </div>
  )
}

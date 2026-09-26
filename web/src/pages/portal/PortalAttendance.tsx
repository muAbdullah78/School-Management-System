/**
 * The Attendance tab: one month at a time, as a calendar.
 *
 * It was a percentage for three months and a list of dates, newest first, so
 * "was she in on the 12th" meant scrolling a list and "how many days did she
 * miss in August" meant counting badges. A calendar answers both at a glance,
 * and the arrows go back a year.
 */
import { useState } from 'react'
import { useQuery } from '@tanstack/react-query'
import { getPortalChildAttendance } from '@/lib/db'
import { MeterRing } from '@/components/viz'
import { IconAttendance } from '@/components/icons'
import { PCard, PTitle, Problem, dayLabel } from './portalKit'

/** One colour and one letter per kind of day. The letter is there so the
 *  record is not colour alone, for a colour-blind parent and for a printout. */
export const DAY: Record<string, { cell: string; chip: string; letter: string; label: string }> = {
  present: { cell: 'bg-money-500 text-white', chip: 'bg-money-50 text-money-800 ring-money-200', letter: 'P', label: 'Present' },
  late: { cell: 'bg-due-400 text-slate-900', chip: 'bg-due-50 text-due-800 ring-due-200', letter: 'L', label: 'Late' },
  half_day: { cell: 'bg-due-200 text-due-900', chip: 'bg-due-50 text-due-800 ring-due-200', letter: 'H', label: 'Half day' },
  absent: { cell: 'bg-danger-500 text-white', chip: 'bg-danger-50 text-danger-700 ring-danger-200', letter: 'A', label: 'Absent' },
  leave: { cell: 'bg-sky-400 text-white', chip: 'bg-sky-50 text-sky-800 ring-sky-200', letter: 'Lv', label: 'Leave' },
}

export function monthRange(ym: string, today: string): { from: string; to: string; last: string } {
  const [y, m] = ym.split('-').map(Number)
  const lastDay = new Date(Date.UTC(y, m, 0)).getUTCDate()
  const last = `${ym}-${String(lastDay).padStart(2, '0')}`
  return { from: `${ym}-01`, to: last < today ? last : today, last }
}

export function attendanceKey(childId: string | null, ym: string) {
  return ['portalAttMonth', childId, ym] as const
}

function shiftMonth(ym: string, n: number): string {
  const [y, m] = ym.split('-').map(Number)
  const d = new Date(Date.UTC(y, m - 1 + n, 1))
  return `${d.getUTCFullYear()}-${String(d.getUTCMonth() + 1).padStart(2, '0')}`
}

const WEEK = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun']
const GRID = 'grid grid-cols-[repeat(7,minmax(0,3rem))] justify-center gap-1.5'

export function PortalAttendance({ childId, today }: { childId: string; today: string }) {
  const thisMonth = today.slice(0, 7)
  const [ym, setYm] = useState(thisMonth)
  const [picked, setPicked] = useState<string | null>(null)
  const oldest = shiftMonth(thisMonth, -12)
  const range = monthRange(ym, today)

  const att = useQuery({
    queryKey: attendanceKey(childId, ym),
    queryFn: () => getPortalChildAttendance(childId, range.from, range.to),
    refetchOnWindowFocus: true,
  })

  const go = (n: number) => { setYm((v) => shiftMonth(v, n)); setPicked(null) }
  const label = new Date(`${ym}-01T00:00:00`).toLocaleDateString('en-PK', { month: 'long', year: 'numeric' })

  const byDate = new Map((att.data?.days ?? []).map((d) => [d.date, d.status]))
  const lead = (new Date(`${ym}-01T00:00:00`).getDay() + 6) % 7 // Monday first
  const nDays = Number(range.last.slice(8, 10))
  const cells: (string | null)[] = [
    ...Array.from({ length: lead }, () => null),
    ...Array.from({ length: nDays }, (_, i) => `${ym}-${String(i + 1).padStart(2, '0')}`),
  ]
  const away = (att.data?.days ?? []).filter((d) => d.status !== 'present')
  const d = att.data

  const nav = (
    <div className="flex items-center justify-between gap-2">
      <button type="button" onClick={() => go(-1)} disabled={ym <= oldest} aria-label="The month before"
        className="flex h-10 w-10 items-center justify-center rounded-full bg-white text-lg text-slate-700 shadow-sm ring-1 ring-slate-200 hover:bg-brand-50 disabled:opacity-40">‹</button>
      <p className="text-base font-semibold text-slate-900">{label}</p>
      <button type="button" onClick={() => go(1)} disabled={ym >= thisMonth} aria-label="The month after"
        className="flex h-10 w-10 items-center justify-center rounded-full bg-white text-lg text-slate-700 shadow-sm ring-1 ring-slate-200 hover:bg-brand-50 disabled:opacity-40">›</button>
    </div>
  )

  if (att.isError) return <div className="space-y-4"><PCard>{nav}</PCard><Problem error={att.error} onRetry={() => void att.refetch()} /></div>

  return (
    <div className="grid grid-cols-1 gap-4 lg:grid-cols-[minmax(0,20rem)_minmax(0,1fr)] lg:items-start">
      {/* ------------------------------------------------ the month's figure -- */}
      <PCard className="bg-gradient-to-br from-brand-50/60 via-white to-white">
        <PTitle icon={<IconAttendance />}>{ym === thisMonth ? 'This month' : label}</PTitle>
        {!d ? (
          <div className="h-40 animate-pulse rounded-2xl bg-slate-100" />
        ) : (
          <>
            <div className="flex items-center gap-4">
              <MeterRing value={d.percent} size={112} thickness={11}
                sub={d.marked ? `of ${d.marked} day${d.marked === 1 ? '' : 's'}` : 'No days yet'}
                label={`Attendance in ${label}: ${d.percent ?? 'none'} per cent`} />
              <ul className="grid flex-1 grid-cols-2 gap-2">
                {(['present', 'late', 'absent', 'leave'] as const).map((k) => {
                  const n = k === 'present' ? d.present : k === 'late' ? (d.late ?? 0) + (d.half_day ?? 0) : (d[k] ?? 0)
                  return (
                    <li key={k} className={`rounded-2xl px-2.5 py-2 ring-1 ${DAY[k].chip}`}>
                      <div className="text-lg font-bold tabular-nums leading-none">{n}</div>
                      <div className="mt-1 text-[11px] font-medium">{k === 'late' ? 'Late / half' : DAY[k].label}</div>
                    </li>
                  )
                })}
              </ul>
            </div>
            {/* 0105. Leave counts against the percentage, which is right: it has
                to answer "how much of the year was this child here" for the 75%
                rule. But the school GRANTED those days, so the page says so. */}
            {(d.leave ?? 0) > 0 && (
              <p className="mt-3 rounded-2xl bg-sky-50 px-3 py-2 text-xs text-sky-900 ring-1 ring-sky-100">
                The percentage counts every day the school was open, so the {d.leave} day{d.leave === 1 ? '' : 's'} of
                leave the school approved {d.leave === 1 ? 'is' : 'are'} counted as days your child was not present.
              </p>
            )}
          </>
        )}
      </PCard>

      {/* -------------------------------------------------- the calendar -- */}
      <PCard>
        {nav}
        <div className={`mt-4 ${GRID} text-center text-[11px] font-medium text-slate-400`}>
          {WEEK.map((w) => <div key={w}>{w}</div>)}
        </div>
        <div className={`mt-1 ${GRID}`}>
          {cells.map((day, i) => {
            if (!day) return <div key={`b${i}`} />
            const status = byDate.get(day)
            const s = status ? DAY[status] : null
            const future = day > today
            const on = picked === day
            return (
              <button key={day} type="button" disabled={future || !d}
                onClick={() => setPicked(on ? null : day)}
                aria-pressed={on}
                aria-label={`${dayLabel(day)}: ${future ? 'not yet' : s ? s.label : 'not marked'}`}
                className={`relative flex aspect-square w-full flex-col items-center justify-center rounded-xl text-xs font-semibold tabular-nums transition ${
                  !d ? 'animate-pulse bg-slate-100 text-transparent'
                    : future ? 'text-slate-300'
                      : s ? s.cell
                        : 'bg-slate-50 text-slate-400 ring-1 ring-inset ring-slate-200'} ${
                  day === today ? 'ring-2 ring-brand-500 ring-offset-1' : ''} ${on ? 'scale-105 shadow-md' : ''}`}>
                <span>{Number(day.slice(8, 10))}</span>
                {s && <span className="text-[9px] font-bold leading-none opacity-90">{s.letter}</span>}
              </button>
            )
          })}
        </div>
        {picked && (
          <p className="mt-3 rounded-2xl bg-slate-50 px-3 py-2 text-sm text-slate-700" aria-live="polite">
            <b>{dayLabel(picked)}:</b> {byDate.get(picked) ? DAY[byDate.get(picked)!]?.label ?? byDate.get(picked) : 'no register was marked'}
          </p>
        )}
        <ul className="mt-4 flex flex-wrap gap-x-3 gap-y-1.5 text-[11px] text-slate-600">
          {Object.values(DAY).map((s) => (
            <li key={s.label} className="inline-flex items-center gap-1">
              <span className={`inline-flex h-4 min-w-4 items-center justify-center rounded px-0.5 text-[9px] font-bold ${s.cell}`}>{s.letter}</span>
              {s.label}
            </li>
          ))}
        </ul>

        {d && d.marked === 0 && (
          <p className="mt-3 text-sm text-slate-500">No register was marked in {label}.</p>
        )}
        {away.length > 0 && (
          <div className="mt-4 border-t border-slate-100 pt-3">
            <p className="text-sm font-semibold text-slate-800">Days not fully present</p>
            <ul className="mt-2 space-y-1.5">
              {away.map((x) => (
                <li key={x.date} className="flex items-center justify-between gap-3 text-sm">
                  <span className="text-slate-700">{dayLabel(x.date)}</span>
                  <span className={`rounded-full px-2.5 py-0.5 text-xs font-semibold ring-1 ${DAY[x.status]?.chip ?? 'bg-slate-50 text-slate-600 ring-slate-200'}`}>
                    {DAY[x.status]?.label ?? x.status}
                  </span>
                </li>
              ))}
            </ul>
          </div>
        )}
      </PCard>
    </div>
  )
}

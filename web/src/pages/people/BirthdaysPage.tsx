/**
 * Birthdays: children and staff.
 *
 * A small thing that schools care about disproportionately: a card in assembly,
 * a WhatsApp wish to the parent. Their software has separate Student Birthdays
 * and Staff Birthdays screens; one screen with both is the same information
 * without the second click.
 *
 * The WhatsApp link is click-to-chat, consistent with the rest of this product:
 * nothing is sent on the school's behalf without somebody pressing send.
 */
import { useState } from 'react'
import { useQuery } from '@tanstack/react-query'
import { getBirthdays, whatsappLink, type BirthdayRow } from '@/lib/db'
import { useSchoolName } from '@/hooks/useSchoolName'

const RANGES = [
  { days: 0, label: 'Today' },
  { days: 7, label: 'Next 7 days' },
  { days: 30, label: 'Next 30 days' },
] as const

export function BirthdaysPage() {
  const [days, setDays] = useState<number>(0)
  const schoolName = useSchoolName()

  const q = useQuery({
    queryKey: ['birthdays', days],
    queryFn: () => getBirthdays(days),
  })

  const rows = q.data ?? []
  const students = rows.filter((r) => r.kind === 'student')
  const staff = rows.filter((r) => r.kind === 'staff')

  return (
    <div>
      <div className="flex flex-wrap items-center justify-between gap-3">
        <div>
          <h1 className="text-xl font-semibold text-slate-800">Birthdays</h1>
          <p className="text-sm text-slate-500">
            Children and staff, soonest first.
          </p>
        </div>
        <div className="flex gap-1 rounded border border-slate-200 p-0.5">
          {RANGES.map((r) => (
            <button key={r.days} onClick={() => setDays(r.days)}
              className={`rounded px-3 py-1.5 text-sm ${days === r.days ? 'bg-brand-600 text-white' : 'text-slate-600 hover:bg-slate-50'}`}>
              {r.label}
            </button>
          ))}
        </div>
      </div>

      {q.isLoading && (
        <p className="mt-8 text-center text-sm text-slate-500">Loading…</p>
      )}
      {q.isError && (
        <div className="mt-4 rounded border border-danger-200 bg-danger-50 p-4 text-sm text-danger-700">
          {(q.error as Error).message}
        </div>
      )}

      {!q.isLoading && !q.isError && rows.length === 0 && (
        <p className="mt-8 rounded border border-slate-200 p-8 text-center text-sm text-slate-500">
          {days === 0
            ? 'Nobody has a birthday today.'
            : `No birthdays in the next ${days} days.`}
          <span className="mt-1 block text-xs text-slate-400">
            Only people with a date of birth on record can appear here.
          </span>
        </p>
      )}

      {students.length > 0 && (
        <Section title={`Children (${students.length})`} rows={students} schoolName={schoolName} />
      )}
      {staff.length > 0 && (
        <Section title={`Staff (${staff.length})`} rows={staff} schoolName={schoolName} />
      )}
    </div>
  )
}

function Section({ title, rows, schoolName }: {
  title: string; rows: BirthdayRow[]; schoolName: string | null
}) {
  return (
    <div className="mt-6">
      <h2 className="mb-2 text-sm font-semibold text-slate-700">{title}</h2>
      <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-3">
        {rows.map((r) => {
          // Gate on the LINK, not the phone: whatsappLink returns null for a
          // number too short to be valid, and a null href renders a dead link
          // back to the current page rather than showing "no number".
          const wa = whatsappLink(r.phone, r.kind === 'student'
            ? `Assalam-o-Alaikum. Warmest birthday wishes to ${r.full_name} from all of us at ${schoolName ?? 'the school'}.`
            : `Assalam-o-Alaikum ${r.full_name}. Warmest birthday wishes from all of us at ${schoolName ?? 'the school'}.`)
          return (
          <div key={`${r.kind}-${r.id}`}
               className={`rounded border p-3 ${r.days_away === 0
                 ? 'border-amber-300 bg-amber-50' : 'border-slate-200 bg-white'}`}>
            <div className="flex items-start justify-between gap-2">
              <div className="min-w-0">
                <div className="truncate font-medium text-slate-800">{r.full_name}</div>
                <div className="truncate text-xs text-slate-500">
                  {r.class_name}{r.detail ? ` · ${r.detail}` : ''}
                </div>
              </div>
              <span className={`shrink-0 rounded px-1.5 py-0.5 text-xs font-medium ${
                r.days_away === 0 ? 'bg-amber-200 text-amber-900' : 'bg-slate-100 text-slate-600'}`}>
                {r.days_away === 0 ? 'Today' : `${r.days_away}d`}
              </span>
            </div>
            <div className="mt-2 flex items-center justify-between text-sm">
              <span className="text-slate-600">Turning {r.turning}</span>
              {wa ? (
                <a href={wa} target="_blank" rel="noreferrer"
                   className="text-money-700 hover:underline">
                  Wish on WhatsApp
                </a>
              ) : (
                <span className="text-xs text-slate-400">No usable number</span>
              )}
            </div>
          </div>
          )
        })}
      </div>
    </div>
  )
}

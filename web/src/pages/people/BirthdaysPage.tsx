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
import { getBirthdays, getMyTeaching, whatsappLink, type BirthdayRow } from '@/lib/db'
import { useSchoolName } from '@/hooks/useSchoolName'
import { useAuth } from '@/auth/AuthProvider'
import { isTeacher } from '@/auth/roles'
import { buttonClass } from '@/components/ui'
import { Avatar } from '@/components/Avatar'
import { IconBirthday } from '@/components/icons'

const RANGES = [
  { days: 0, label: 'Today' },
  { days: 7, label: 'Next 7 days' },
  { days: 30, label: 'Next 30 days' },
] as const

export function BirthdaysPage() {
  const [days, setDays] = useState<number>(0)
  const schoolName = useSchoolName()
  const { profile } = useAuth()
  const teacher = isTeacher(profile?.role)
  /* A teacher's own classes first. The list is the whole school's, and a
     teacher with Class 4 wants Class 4's birthdays, not four hundred names.
     "Whole school" is one tap away. A convenience, not a permission: which
     pupils a teacher may read is the students table's rule, not this page's. */
  const [mineOnly, setMineOnly] = useState(true)
  const teaching = useQuery({ queryKey: ['myTeaching'], queryFn: getMyTeaching, enabled: teacher })
  const myClasses = new Set((teaching.data ?? []).map((t) => t.class_name))
  const scoped = teacher && mineOnly && myClasses.size > 0

  const q = useQuery({
    queryKey: ['birthdays', days],
    queryFn: () => getBirthdays(days),
  })

  const rows = (q.data ?? []).filter((r) => !scoped || (r.kind === 'student' && myClasses.has(r.class_name)))
  const students = rows.filter((r) => r.kind === 'student')
  const staff = rows.filter((r) => r.kind === 'staff')

  return (
    <div>
      <div className="flex flex-wrap items-center justify-between gap-3">
        <div>
          <h1 className="text-xl font-bold text-slate-900">Birthdays</h1>
          <p className="text-sm text-slate-500">
            {scoped ? 'Children in your classes, soonest first.' : 'Children and staff, soonest first.'}
          </p>
        </div>
        <div className="flex flex-wrap gap-2">
          {teacher && myClasses.size > 0 && (
            <div className="flex gap-1 rounded-full bg-white p-1 shadow-sm ring-1 ring-slate-200" role="group" aria-label="Whose birthdays">
              {([[true, 'My classes'], [false, 'Whole school']] as const).map(([v, label]) => (
                <button key={label} type="button" onClick={() => setMineOnly(v)} aria-pressed={mineOnly === v}
                  className={`whitespace-nowrap rounded-full px-2.5 py-1.5 text-xs font-semibold transition sm:px-3 sm:text-sm ${mineOnly === v ? 'bg-brand-600 text-white shadow-sm' : 'text-slate-600 hover:bg-brand-50'}`}>
                  {label}
                </button>
              ))}
            </div>
          )}
          <div className="flex gap-1 rounded-full bg-white p-1 shadow-sm ring-1 ring-slate-200" role="group" aria-label="When">
            {RANGES.map((r) => (
              <button key={r.days} type="button" onClick={() => setDays(r.days)} aria-pressed={days === r.days}
                className={`whitespace-nowrap rounded-full px-2.5 py-1.5 text-xs font-semibold transition sm:px-3 sm:text-sm ${days === r.days ? 'bg-brand-600 text-white shadow-sm' : 'text-slate-600 hover:bg-brand-50'}`}>
                {r.label}
              </button>
            ))}
          </div>
        </div>
      </div>

      {q.isLoading && (
        <p className="mt-8 text-center text-sm text-slate-500">Loading…</p>
      )}
      {q.isError && (
        <div className="mt-4 rounded-2xl border border-danger-200 bg-danger-50 p-4 text-sm text-danger-700">
          {(q.error as Error).message}
        </div>
      )}

      {!q.isLoading && !q.isError && rows.length === 0 && (
        <p className="mt-6 rounded-3xl border border-dashed border-slate-300 bg-white/60 p-8 text-center text-sm text-slate-500">
          {days === 0
            ? (scoped ? 'Nobody in your classes has a birthday today.' : 'Nobody has a birthday today.')
            : `No birthdays in the next ${days} days${scoped ? ' in your classes' : ''}.`}
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
               className={`relative overflow-hidden rounded-3xl p-4 shadow-card ring-1 ${r.days_away === 0
                 ? 'bg-gradient-to-br from-fuchsia-50 via-white to-violet-50 ring-fuchsia-200' : 'bg-white ring-slate-200/70'}`}>
            <div className="flex items-start gap-3">
              <Avatar name={r.full_name} size="md" />
              <div className="min-w-0 flex-1">
                <div className="truncate font-semibold text-slate-900">{r.full_name}</div>
                <div className="truncate text-xs text-slate-500">
                  {r.class_name}{r.detail ? ` · ${r.detail}` : ''}
                </div>
              </div>
              <span className={`inline-flex shrink-0 items-center gap-1 rounded-full px-2.5 py-0.5 text-xs font-semibold ${
                r.days_away === 0 ? 'bg-fuchsia-500 text-white' : 'bg-slate-100 text-slate-600'}`}>
                {r.days_away === 0 ? <><IconBirthday /> Today</> : r.days_away === 1 ? 'Tomorrow' : `In ${r.days_away} days`}
              </span>
            </div>
            <div className="mt-3 flex items-center justify-between gap-2 text-sm">
              <span className="font-medium text-slate-700">Turning {r.turning}</span>
              {wa ? (
                <a href={wa} target="_blank" rel="noreferrer"
                   className={buttonClass({ variant: 'soft', size: 'sm' })}>
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

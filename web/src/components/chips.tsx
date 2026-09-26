/**
 * Small identity pieces shared by the teacher screens and the parent portal.
 *
 * Subject colours are identity, not status, so they come from hues that mean
 * nothing else in the app (never money green, due amber or danger red), and
 * the same subject is always the same colour for a teacher and a parent.
 */
const SUBJECT_TONES = [
  'bg-violet-50 text-violet-700 ring-violet-200',
  'bg-sky-50 text-sky-700 ring-sky-200',
  'bg-rose-50 text-rose-700 ring-rose-200',
  'bg-teal-50 text-teal-700 ring-teal-200',
  'bg-fuchsia-50 text-fuchsia-700 ring-fuchsia-200',
  'bg-brand-50 text-brand-700 ring-brand-200',
  'bg-cyan-50 text-cyan-700 ring-cyan-200',
]

/** The same subject is always the same colour, on every test and every child. */
export function subjectTone(name: string): string {
  let h = 0
  for (let i = 0; i < name.length; i++) h = (h * 31 + name.toLowerCase().charCodeAt(i)) % 100000
  return SUBJECT_TONES[h % SUBJECT_TONES.length]
}

export function SubjectChip({ name }: { name: string }) {
  return (
    <span className={`inline-flex max-w-full items-center truncate rounded-full px-2 py-0.5 text-[11px] font-semibold ring-1 ${subjectTone(name)}`}>
      {name}
    </span>
  )
}

/** A tear-off calendar leaf: the month on a coloured band, the day under it. */
export function DateChip({ date, tone = 'brand' }: { date: string | null; tone?: 'brand' | 'due' | 'slate' }) {
  const dt = date ? new Date(`${date.slice(0, 10)}T00:00:00`) : null
  const ok = dt && !isNaN(dt.getTime())
  const band = tone === 'due' ? 'bg-due-500' : tone === 'slate' ? 'bg-slate-400' : 'bg-brand-600'
  return (
    <span className="flex w-11 shrink-0 flex-col overflow-hidden rounded-xl bg-white text-center shadow-sm ring-1 ring-slate-200" aria-hidden="true">
      <span className={`${band} py-0.5 text-[9px] font-bold uppercase tracking-wider text-white`}>
        {ok ? dt!.toLocaleDateString('en-PK', { month: 'short' }) : '--'}
      </span>
      <span className="py-1 text-base font-bold leading-none tabular-nums text-slate-900">
        {ok ? dt!.getDate() : '?'}
      </span>
    </span>
  )
}

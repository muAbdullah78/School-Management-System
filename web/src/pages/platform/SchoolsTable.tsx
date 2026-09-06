import { useMemo, useState } from 'react'
import { actionNeeded, sortByAction, type PlatformSchool } from '@/lib/platform'
import { formatPkr } from '@/lib/licence'
import { StatusChip, LimitBar, ExpiryCell } from './status'

/**
 * The school directory.
 *
 * WHAT THIS REPLACED, AND WHY.
 *
 * Every school was a stacked card roughly 130px tall carrying its own name,
 * badges, contact line, student count, a to-do sentence, five text links and an
 * Activate button. That is fine at three schools and unusable at fifty: six and
 * a half thousand pixels of scroll, no search box anywhere on the page, and the
 * only way to find Al Qalam School was to scroll until you saw it.
 *
 * The card was also carrying work the row should not do. Five actions per row
 * times fifty rows is 250 controls on one screen, all of them one mis-click
 * from something that charges a customer.
 *
 * So the row is now a row: dense, sortable, searchable, and it opens one
 * workspace instead of six dialogs. What it keeps is the console's actual
 * purpose, which is not "list our customers" but "who do I call this morning" -
 * so the default order is still what needs doing, and the last column holds THE
 * ONE THING THIS SCHOOL NEEDS TODAY rather than a fixed menu. Rows with a button
 * in the last column are the morning's work; the rest are fine.
 *
 * SEARCH IS THE PART NOBODY ASKS FOR AND EVERYBODY USES. A directory without it
 * is a directory you scroll, and the operator's own description of this screen
 * was "I get lost all the time".
 */

type SortKey = 'action' | 'name' | 'expiry' | 'students' | 'owed'
type Filter = 'all' | 'attention' | 'trial' | 'paying' | 'overdue' | 'archived'

const FILTERS: { key: Filter; label: string }[] = [
  { key: 'all', label: 'All' },
  { key: 'attention', label: 'Needs attention' },
  { key: 'trial', label: 'On trial' },
  { key: 'paying', label: 'Paying' },
  { key: 'overdue', label: 'Overdue or locked' },
  { key: 'archived', label: 'Archived' },
]

function matches(s: PlatformSchool, filter: Filter): boolean {
  switch (filter) {
    case 'attention': return actionNeeded(s) !== null
    case 'trial':     return s.status === 'trialing'
    case 'paying':    return s.status === 'active'
    case 'overdue':   return s.status === 'grace' || s.status === 'locked' || s.suspended
    case 'archived':  return s.archived
    // Archived schools are excluded from every other view. A console that shows
    // last year's departed customers beside this year's is a console whose
    // totals nobody trusts, and the operator has no reason to see them until
    // they ask for them by name.
    default:          return !s.archived
  }
}

/** Everything on the row that a person might type into a search box. */
function haystack(s: PlatformSchool): string {
  return [s.school_name, s.city, s.contact_name, s.contact_phone, s.plan_code]
    .filter(Boolean).join(' ').toLowerCase()
}

export function SchoolsTable({
  schools, loading, error, onOpen, onQuickAction, busy,
}: {
  schools: PlatformSchool[]
  loading: boolean
  error: Error | null
  onOpen: (s: PlatformSchool) => void
  /** The single adaptive action in the last column. */
  onQuickAction: (s: PlatformSchool, kind: QuickKind) => void
  busy: boolean
}) {
  const [q, setQ] = useState('')
  const [filter, setFilter] = useState<Filter>('all')
  const [sort, setSort] = useState<SortKey>('action')
  const [desc, setDesc] = useState(false)

  const counts = useMemo(() => {
    const c = {} as Record<Filter, number>
    for (const f of FILTERS) c[f.key] = schools.filter((s) => matches(s, f.key)).length
    return c
  }, [schools])

  const rows = useMemo(() => {
    const needle = q.trim().toLowerCase()
    const found = schools
      .filter((s) => matches(s, filter))
      .filter((s) => needle === '' || haystack(s).includes(needle))
    // sortByAction is the default because the console exists to answer "who do I
    // call this morning", and alphabetical does not answer it. Every other sort
    // is the operator asking a different question, so it is theirs to choose.
    const sorted = sort === 'action' ? sortByAction(found) : [...found].sort((a, b) => {
      switch (sort) {
        case 'name': return a.school_name.localeCompare(b.school_name)
        // Nulls last in both directions: a school with no end date is not the
        // most urgent thing on the screen and must not sort as though it were.
        case 'expiry': return (a.days_left ?? 1e9) - (b.days_left ?? 1e9)
        case 'students': return b.student_count - a.student_count
        case 'owed': return b.outstanding - a.outstanding
        default: return 0
      }
    })
    return desc ? [...sorted].reverse() : sorted
  }, [schools, filter, q, sort, desc])

  function head(key: SortKey, label: string, className = '') {
    const on = sort === key
    return (
      <th className={`px-3 py-2 font-medium ${className}`}>
        <button
          onClick={() => { if (on) setDesc(!desc); else { setSort(key); setDesc(false) } }}
          // `uppercase` REPEATED HERE ON PURPOSE. Tailwind's preflight sets
          // `button { text-transform: none }`, which beats the inherited
          // uppercase on <thead> - so the four sortable headers rendered as
          // "School" and "Licence" while the two plain ones rendered as
          // "STATUS" and "TODAY", in the same row.
          className={`inline-flex items-center gap-1 uppercase tracking-wide hover:text-slate-800 ${
            on ? 'text-slate-800' : ''}`}
        >
          {label}
          <span aria-hidden className={on ? 'text-slate-500' : 'text-transparent'}>
            {on && desc ? '▾' : '▴'}
          </span>
        </button>
      </th>
    )
  }

  return (
    <div className="rounded-lg border border-slate-200 bg-white">
      <div className="flex flex-wrap items-center gap-2 border-b border-slate-200 p-2">
        <div className="relative min-w-[13rem] flex-1">
          <input
            value={q} onChange={(e) => setQ(e.target.value)}
            placeholder="Search a school, city, contact or phone"
            className="w-full rounded border border-slate-300 py-1.5 pl-3 pr-8 text-sm placeholder:text-slate-400 focus:border-brand-500 focus:outline-none"
          />
          {q !== '' && (
            <button onClick={() => setQ('')} aria-label="Clear the search"
              className="absolute right-1 top-1/2 -translate-y-1/2 rounded px-1.5 text-slate-400 hover:text-slate-700">
              ×
            </button>
          )}
        </div>
        <div className="flex flex-wrap gap-1">
          {FILTERS.map((f) => {
            // A filter that would show nothing is not offered, except All and
            // the one already chosen. A tab that is always empty teaches people
            // to stop reading the row of tabs.
            if (counts[f.key] === 0 && f.key !== 'all' && f.key !== filter) return null
            const on = filter === f.key
            return (
              <button key={f.key} onClick={() => setFilter(f.key)}
                className={`rounded px-2 py-1 text-xs font-medium ${
                  on ? 'bg-slate-800 text-white'
                     : 'bg-slate-100 text-slate-600 hover:bg-slate-200'}`}>
                {f.label}
                <span className={`ml-1 ${on ? 'text-white/70' : 'text-slate-400'}`}>
                  {counts[f.key]}
                </span>
              </button>
            )
          })}
        </div>
      </div>

      {loading && <p className="p-4 text-sm text-slate-500">Loading schools…</p>}
      {error && <p className="p-4 text-sm text-danger-600">{error.message}</p>}

      {!loading && !error && rows.length === 0 && (
        <p className="p-6 text-center text-sm text-slate-500">
          {schools.length === 0
            ? 'No schools yet. They appear here as soon as someone signs up.'
            : q.trim() !== ''
              ? `Nothing matches “${q.trim()}”.`
              : 'Nothing in this filter.'}
        </p>
      )}

      {rows.length > 0 && (
        <div className="overflow-x-auto">
          <table className="w-full text-sm">
            <thead className="border-b border-slate-200 bg-slate-50 text-left text-xs uppercase tracking-wide text-slate-500">
              <tr>
                {head('name', 'School')}
                <th className="px-3 py-2 font-medium">Status</th>
                {head('expiry', 'Licence')}
                {head('students', 'Students')}
                {head('owed', 'Owed', 'text-right')}
                <th className="px-3 py-2 text-right font-medium">
                  {sort === 'action' ? 'Today' : ''}
                </th>
              </tr>
            </thead>
            <tbody className="divide-y divide-slate-100">
              {rows.map((s) => {
                const todo = actionNeeded(s)
                const quick = quickAction(s)
                return (
                  <tr key={s.school_id}
                    onClick={() => onOpen(s)}
                    className="cursor-pointer align-top hover:bg-slate-50">
                    <td className="px-3 py-2">
                      <div className="font-medium text-slate-800">{s.school_name}</div>
                      <div className="text-xs text-slate-500">
                        {[s.city, s.contact_name, s.contact_phone].filter(Boolean).join(' · ')
                          || 'No contact details'}
                      </div>
                      {/* The sentence that says why this row is near the top.
                          It is the whole reason the default sort exists, so it
                          travels with the row rather than living in a tooltip. */}
                      {todo && <div className="mt-0.5 text-xs font-medium text-due-800">{todo}</div>}
                    </td>
                    <td className="px-3 py-2">
                      <div className="flex flex-wrap gap-1">
                        <StatusChip s={s} />
                        {s.archived && (
                          <span className="rounded bg-slate-200 px-1.5 py-0.5 text-xs text-slate-600">
                            archived
                          </span>
                        )}
                      </div>
                      <div className="mt-0.5 text-xs text-slate-400">{s.plan_code}</div>
                    </td>
                    <td className="px-3 py-2 text-xs"><ExpiryCell s={s} /></td>
                    <td className="px-3 py-2 text-xs"><LimitBar s={s} /></td>
                    <td className="px-3 py-2 text-right tabular-nums">
                      {/* A middle dot for "nothing owed", not an em dash: the
                          house rule has no exceptions and
                          scripts/check-no-emdash.py enforces it on every
                          surface a school can read. */}
                      {s.outstanding > 0
                        ? <span className="font-medium text-due-800">{formatPkr(s.outstanding)}</span>
                        : <span className="text-slate-300">·</span>}
                      {s.last_paid_on && (
                        <div className="text-[11px] font-normal text-slate-400">
                          paid {s.last_paid_on}
                        </div>
                      )}
                    </td>
                    <td className="px-3 py-2 text-right"
                      onClick={(e) => e.stopPropagation()}>
                      {quick && (
                        <button
                          disabled={busy}
                          onClick={() => onQuickAction(s, quick)}
                          className="whitespace-nowrap rounded border border-brand-200 bg-brand-50 px-2 py-1 text-xs font-medium text-brand-800 hover:bg-brand-100 disabled:opacity-60">
                          {QUICK_LABEL[quick]}
                        </button>
                      )}
                    </td>
                  </tr>
                )
              })}
            </tbody>
          </table>
        </div>
      )}
    </div>
  )
}

export type QuickKind = 'pay' | 'renew'

const QUICK_LABEL: Record<QuickKind, string> = {
  pay: 'Record payment',
  renew: 'Renew',
}

/**
 * The one thing this school needs today, or nothing.
 *
 * A fixed button on every row is a button nobody reads. Deriving it means the
 * last column is a worklist: money owed is a payment to chase, and a licence
 * running out with nothing owed is a renewal to sell. A school that is paid up
 * and inside its dates needs neither, and gets an empty cell.
 *
 * Money first when both are true, because an unpaid invoice on a school you are
 * about to renew is the conversation, not a footnote to it.
 */
function quickAction(s: PlatformSchool): QuickKind | null {
  if (s.archived) return null
  if (s.outstanding > 0) return 'pay'
  if (s.status === 'cancelled') return null
  if (s.days_left !== null && s.days_left <= 30) return 'renew'
  if (s.status === 'locked' || s.status === 'grace') return 'renew'
  return null
}

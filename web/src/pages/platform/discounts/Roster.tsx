import type { DiscountUse } from '@/lib/platform'
import { formatPkr } from '@/lib/licence'
import { fmtDate } from '@/lib/format'

const STATE: Record<DiscountUse['state'], { word: string; tone: string; title: string }> = {
  active: { word: 'Live', tone: 'bg-money-100 text-money-800', title: 'Still coming off their invoices.' },
  spent: { word: 'Used up', tone: 'bg-slate-100 text-slate-600', title: 'It gave every month it had.' },
  expired: { word: 'Past its date', tone: 'bg-slate-100 text-slate-600', title: 'Its end date has passed.' },
  removed: { word: 'Taken off', tone: 'bg-danger-100 text-danger-700', title: 'Taken off before it ran its course.' },
  trial: { word: 'Trial days', tone: 'bg-info-100 text-info-800', title: 'Added days to their free trial.' },
}

export function StateChip({ state }: { state: DiscountUse['state'] }) {
  const s = STATE[state] ?? STATE.spent
  return (
    <span title={s.title} className={`whitespace-nowrap rounded px-1.5 py-0.5 text-xs font-medium ${s.tone}`}>
      {s.word}
    </span>
  )
}

/** What the code still has to give this school, from its frozen terms. */
function whatIsLeft(u: DiscountUse): string {
  if (u.kind === 'trial_days') return `${u.trial_days_added ?? Number(u.value)} extra trial day(s)`
  if (u.duration === 'months') {
    return `${u.months_left ?? 0} of ${u.months_total ?? 0} billed month(s) left`
  }
  if (u.duration === 'until') return `Billed months that start by ${fmtDate(u.ends_on)}`
  return 'Every billed month, for as long as they subscribe'
}

/**
 * Who has a code, how they got it and what it is still doing.
 *
 * A LIST OF SCHOOLS, NEWEST FIRST, because the question an operator asks is
 * about a school: "is this one still on the ten percent we gave them in April".
 * The state is the database's (fn_platform_discount_usage): "past its date" is
 * a comparison against today in Karachi, and a browser elsewhere would draw a
 * different conclusion from the same row.
 *
 * HOW THEY GOT IT IS SAID OUTRIGHT. A code a school typed and a code we gave
 * them after a phone call are different promises: only we can take ours off,
 * and the reason we gave it is the answer to "why is this school paying less".
 */
export function Roster({ rows, showCode, onTakeOff }: {
  rows: DiscountUse[]
  showCode: boolean
  onTakeOff: (u: DiscountUse) => void
}) {
  return (
    <div className="overflow-x-auto">
      <table className="w-full min-w-[52rem] text-sm">
        <thead className="border-b border-slate-200 bg-slate-50 text-left text-xs uppercase tracking-wide text-slate-500">
          <tr>
            <th scope="col" className="px-3 py-2 font-medium">School</th>
            {showCode && <th scope="col" className="px-3 py-2 font-medium">Code</th>}
            <th scope="col" className="px-3 py-2 font-medium">How they got it</th>
            <th scope="col" className="px-3 py-2 font-medium">Left</th>
            <th scope="col" className="px-3 py-2 text-right font-medium">Saved</th>
            <th scope="col" className="px-3 py-2 font-medium">State</th>
            <th scope="col" className="px-3 py-2"><span className="sr-only">Action</span></th>
          </tr>
        </thead>
        <tbody>
          {rows.map((u) => (
            <tr key={u.redemption_id} className="border-b border-slate-100 align-top last:border-0">
              <td className="px-3 py-2.5">
                <span className="font-medium text-slate-800">{u.school_name}</span>
                {!u.school_id && (
                  <span className="block text-xs text-slate-500">School no longer with us</span>
                )}
                {u.plan_code && <span className="block text-xs text-slate-500">on {u.plan_code}</span>}
              </td>
              {showCode && (
                <td className="px-3 py-2.5">
                  <span className="font-mono text-xs text-slate-700">{u.code}</span>
                  {u.label && <span className="block text-xs text-slate-500">{u.label}</span>}
                </td>
              )}
              <td className="px-3 py-2.5 text-xs text-slate-600">
                <span className="font-medium text-slate-700">
                  {u.granted_by_kind === 'platform' ? 'Given by us' : 'Typed in by the school'}
                </span>
                <span className="block">
                  {fmtDate(u.redeemed_at)}{u.redeemed_by ? `, ${u.redeemed_by}` : ''}
                </span>
                {u.grant_reason && <span className="block">Why: {u.grant_reason}</span>}
              </td>
              <td className="px-3 py-2.5 text-xs text-slate-600">{whatIsLeft(u)}</td>
              <td className="px-3 py-2.5 text-right tabular-nums text-slate-700">
                {u.kind === 'trial_days' ? '-' : formatPkr(Number(u.total_saved) || 0)}
                {u.kind !== 'trial_days' && (
                  <span className="block text-xs text-slate-500">
                    {u.times_applied} invoice{u.times_applied === 1 ? '' : 's'}
                  </span>
                )}
              </td>
              <td className="px-3 py-2.5 text-xs text-slate-600">
                <StateChip state={u.state} />
                {u.removed_at && (
                  <span className="mt-1 block">
                    {u.removed_reason === 'Ran its course'
                      ? `Closed ${fmtDate(u.removed_at)}: it had run its course.`
                      : `Taken off ${fmtDate(u.removed_at)}${u.removed_by ? ` by ${u.removed_by}` : ''}`
                        + (u.removed_reason ? `: ${u.removed_reason}` : '')}
                  </span>
                )}
              </td>
              <td className="px-3 py-2.5 text-right">
                {u.state === 'active' && u.school_id && (
                  <button type="button" onClick={() => onTakeOff(u)}
                    aria-label={`Take ${u.code} off ${u.school_name}`}
                    className="rounded border border-slate-300 px-2 py-1 text-xs font-medium text-slate-700 hover:bg-slate-50 focus:outline-none focus:ring-2 focus:ring-brand-500">
                    Take off
                  </button>
                )}
              </td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  )
}

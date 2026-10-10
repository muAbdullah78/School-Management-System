import type { DiscountEvent } from '@/lib/platform'
import { formatPkr } from '@/lib/licence'
import { fmtDate, fmtDateTime } from '@/lib/format'
import { FIELD_WORDS, changedFields, fieldValue, type PricedPlan } from './rules'

export type LogFilter = 'all' | 'codes' | 'schools' | 'invoices' | 'refused'

export const LOG_FILTERS: Record<LogFilter, { word: string; events: DiscountEvent['event'][] | null }> = {
  all: { word: 'Everything', events: null },
  codes: { word: 'Codes made, changed, retired or deleted', events: ['created', 'edited', 'retired', 'deleted'] },
  schools: {
    word: 'Codes going on and coming off schools',
    events: ['applied', 'given', 'restored', 'replaced', 'removed', 'trial_extended'],
  },
  invoices: { word: 'Invoices', events: ['invoiced', 'reversed'] },
  refused: { word: 'Refused tries', events: ['refused'] },
}

export interface LogCtx {
  plans: PricedPlan[]
  schoolName: (id: string) => string | null
}

export interface LogLine {
  who: string
  what: string
  why: string | null
  changes: { field: string; from: string; to: string }[]
}

const num = (v: unknown) => Number(v ?? 0) || 0
const months = (n: number) => `${n} month${n === 1 ? '' : 's'}`

/**
 * One log entry as a sentence.
 *
 * The log is append-only in the database (discount_events) and records what
 * each event carried, before and after. This turns that into words an
 * operator can read months later: who did it, to which code and school, and,
 * for a change to a code, each field that moved from what to what.
 */
export function describeEvent(e: DiscountEvent, ctx: LogCtx): LogLine {
  const code = e.code ?? 'a code'
  const school = e.school_name ?? 'a school'
  const a = (e.after ?? {}) as Record<string, unknown>
  const b = (e.before ?? {}) as Record<string, unknown>
  const who = e.actor_kind === 'system' ? 'Billing, automatically'
    : e.actor_kind === 'school' ? (e.actor ? `${e.actor}, ${school}` : school)
    : (e.actor ?? 'Us')
  const doc = e.doc_no ?? (a.doc_no as string | undefined) ?? 'an invoice'

  let what: string
  switch (e.event) {
    case 'created':
      what = `Made ${code}${a.label ? `, shown to schools as "${a.label}"` : ''}.`
        + (a.private ? ` Private to ${ctx.schoolName(String(a.school_id ?? '')) ?? 'one school'}.` : '')
      break
    case 'edited': what = `Changed ${code}.`; break
    case 'retired': what = `Retired ${code}. No school can take it up now; those that have it keep it.`; break
    case 'deleted': what = `Deleted ${code}. Nobody had used it.`; break
    case 'applied': what = `${school} typed in ${code} and it went on their subscription.`; break
    case 'given': what = `Gave ${code} to ${school}.`; break
    case 'restored':
      what = `Gave ${code} back to ${school}, as it was`
        + (a.months_left != null ? `, with ${months(num(a.months_left))} left` : '') + '.'
      break
    case 'replaced':
      what = `${code} came off ${school}, replaced by ${String(a.replaced_by ?? 'another code')}`
        + (e.actor_kind === 'school' ? ' at the school\'s request.' : '.')
      break
    case 'removed':
      what = (e.actor_kind === 'school'
        ? `${school} took ${code} off their subscription.`
        : `Took ${code} off ${school}.`)
        + (num(b.total_saved) > 0 ? ` It had saved them ${formatPkr(num(b.total_saved))}.` : '')
      break
    case 'refused':
      what = `${school} typed "${code}" and it was refused.`
      break
    case 'invoiced':
      what = `${code} took ${formatPkr(num(a.amount_off))} off ${doc} for ${school}, `
        + `covering ${months(num(a.months_covered))} of it.`
        + (a.overridden ? ' The price was typed by hand, so the code was used up for those months.' : '')
      break
    case 'reversed':
      what = `${doc} for ${school} was voided, so ${formatPkr(num(b.amount_off))} and `
        + `${months(num(b.months_covered))} went back to ${code}.`
      break
    case 'trial_extended':
      what = `${school}'s free trial was extended with ${code}`
        + (a.value != null ? ` by ${num(a.value)} day(s)` : '')
        + (a.trial_ends_on ? `, to ${fmtDate(String(a.trial_ends_on))}` : '') + '.'
      break
    default:
      what = `${String(e.event)}: ${code}.`
  }

  const fmt = { plans: ctx.plans, schoolName: ctx.schoolName, fmtDate }
  const changes = e.event === 'edited' || e.event === 'retired'
    ? changedFields(e.before, e.after).map((k) => ({
        field: FIELD_WORDS[k] ?? k,
        from: fieldValue(k, b[k], fmt),
        to: fieldValue(k, a[k], fmt),
      }))
    : []

  const why = !e.reason ? null
    : e.event === 'refused' ? `They were told: ${e.reason}`
    : `Why: ${e.reason}`
  return { who, what, why, changes }
}

/** The log, newest first. */
export function Log({ events, ctx }: { events: DiscountEvent[]; ctx: LogCtx }) {
  if (events.length === 0) {
    return <p className="px-4 py-3 text-sm text-slate-500">Nothing has happened here yet.</p>
  }
  return (
    <ol className="divide-y divide-slate-100">
      {events.map((e, i) => {
        const l = describeEvent(e, ctx)
        return (
          <li key={`${e.at}-${e.event}-${e.code}-${i}`} className="px-4 py-2.5 text-sm">
            <div className="flex flex-wrap items-baseline justify-between gap-x-3">
              <span className="text-slate-800">{l.what}</span>
              <span className="whitespace-nowrap text-xs text-slate-400">
                <time dateTime={e.at}>{fmtDateTime(e.at)}</time>
              </span>
            </div>
            <div className="text-xs text-slate-500">{l.who}</div>
            {l.changes.length > 0 && (
              <ul className="mt-1 space-y-0.5 text-xs text-slate-600">
                {l.changes.map((c) => (
                  <li key={c.field}>
                    <span className="font-medium">{c.field}</span>: {c.from} to {c.to}
                  </li>
                ))}
              </ul>
            )}
            {l.why && <div className="mt-0.5 text-xs text-slate-600">{l.why}</div>}
          </li>
        )
      })}
    </ol>
  )
}

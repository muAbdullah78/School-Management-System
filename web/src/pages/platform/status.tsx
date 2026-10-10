import type { PlatformSchool } from '@/lib/platform'
import { formatPkr } from '@/lib/licence'
import { fmtDate } from '@/lib/format'

/**
 * One vocabulary for what a school's row is telling you.
 *
 * WHY THIS FILE EXISTS. tailwind.config.js defines four semantic ramps with the
 * reasoning written above each one, and the best of them reads:
 *
 *     money: Money in. Never used for anything that is not a credit or a
 *            payment, so "green on this screen" always means the same thing.
 *
 * The operator console used NONE of them. A sweep of this folder found 0 uses
 * of money, due, danger or info and over two hundred raw Tailwind utilities:
 * bg-amber-50 thirty-two times, bg-red-50 twenty-five, bg-emerald-50 sixteen,
 * each picked by whoever wrote that component that afternoon. So amber meant
 * "owes money" on the school row, "a discount was given" on the tiles, "tax
 * certificate missing" in the books strip and "you typed something wrong" in
 * three dialogs, and green on this screen did not always mean the same thing.
 *
 * The colours themselves were never the problem, which is the part an outside
 * review of the screenshots got backwards. The palette is good and it was
 * simply not being used. Everything on a school row now comes from here.
 *
 * STATUS IS NOT ONE FACT. `status` reads 'locked' for a school we suspended and
 * for one whose licence quietly ran out, and those are different phone calls, so
 * the chips are computed rather than looked up.
 */

type Tone = 'live' | 'trial' | 'warn' | 'stopped' | 'quiet'

const TONE_CLASS: Record<Tone, string> = {
  live:    'bg-money-100 text-money-800',
  trial:   'bg-info-100 text-info-800',
  warn:    'bg-due-100 text-due-800',
  stopped: 'bg-danger-100 text-danger-800',
  quiet:   'bg-slate-200 text-slate-700',
}

export function Chip({ tone, children, title }: {
  tone: Tone; children: React.ReactNode; title?: string
}) {
  return (
    <span title={title}
      className={`inline-flex shrink-0 items-center rounded px-1.5 py-0.5 text-xs font-medium ${TONE_CLASS[tone]}`}>
      {children}
    </span>
  )
}

const STATUS_TONE: Record<PlatformSchool['status'], Tone> = {
  trialing: 'trial', active: 'live', grace: 'warn', locked: 'stopped', cancelled: 'quiet',
}

/**
 * What a status is called in English.
 *
 * The console printed the database enum: "trialing", "grace", "locked". Those
 * are three words the operator has to translate every time, and "grace" in
 * particular reads as a compliment rather than as "they have not paid and the
 * clock is running".
 */
const STATUS_LABEL: Record<PlatformSchool['status'], string> = {
  trialing: 'On trial', active: 'Paying', grace: 'Payment overdue',
  locked: 'Locked out', cancelled: 'Cancelled',
}

/** The same words for a status string the database hands back after an act
 *  (a payment, a plan move), so a result reads like the chip on the row. */
export function statusWords(status: string | null | undefined): string {
  return status && status in STATUS_LABEL
    ? STATUS_LABEL[status as PlatformSchool['status']]
    : (status ?? 'unknown')
}

export function StatusChip({ s }: { s: PlatformSchool }) {
  // Suspended FIRST, and as its own word. fn_effective_status returns 'locked'
  // for a suspension and for an expiry alike, so without this the operator
  // cannot tell "they did not pay" from "we switched them off".
  if (s.suspended) {
    return <Chip tone="stopped" title={s.suspend_reason ?? undefined}>We suspended them</Chip>
  }
  return <Chip tone={STATUS_TONE[s.status]}>{STATUS_LABEL[s.status]}</Chip>
}

/**
 * A figure a person typed, as a number.
 *
 * `Number('38,000')` is NaN and `Number('Rs 38,000')` is NaN, and both are how a
 * Pakistani bank statement writes a figure. The old code fed the raw string
 * straight to Number and then disabled the Record button when the result was
 * not finite, so pasting the amount out of the statement produced a screen with
 * no error and a button that did nothing. Commas, spaces and a leading Rs are
 * stripped; anything else still fails, and now says so.
 *
 * Here rather than in PlatformPage so the plan, price and invoice dialogs on
 * the school's page can read a typed price the same way without importing the
 * page that imports them.
 */
export function money(v: string): number {
  const cleaned = v.replace(/[\s,]/g, '').replace(/^rs\.?/i, '')
  return cleaned === '' ? NaN : Number(cleaned)
}

/** True for a whole number of rupees, zero or more: the only kind 0155 invoices. */
export function wholeRupees(n: number): boolean {
  return Number.isInteger(n) && n >= 0
}

/** What they owe, or nothing at all. Never a zero: a zero is not news. */
export function OwedChip({ amount }: { amount: number }) {
  if (!(amount > 0)) return null
  return <Chip tone="warn">owes {formatPkr(amount)}</Chip>
}

/**
 * A school's row with what 0155 says about it beyond the old list.
 *
 * OPTIONAL ON PURPOSE. fn_platform_schools does not return these yet (see the
 * note in the report that shipped this): until it does, every one of them is
 * undefined and the row reads exactly as it did. The moment the list carries
 * them, the chip and the dates appear without another change here.
 */
export type SchoolRow = PlatformSchool & {
  /** Enterprise with no price agreed. It locks the day its trial ends. */
  needs_price?: boolean
  paid_through?: string | null
  trial_ends_on?: string | null
}

/**
 * The flag for an Enterprise school we have not priced.
 *
 * Louder than "owes", because it is our move, not theirs: with no price there
 * is nothing to invoice, and the school locks the day its trial ends with no
 * grace at all. The date is the deadline for a phone call.
 */
export function NeedsPriceChip({ trialEndsOn }: { trialEndsOn?: string | null }) {
  return (
    <Chip tone="stopped" title="Enterprise, and no price has been agreed with this school yet">
      price not agreed{trialEndsOn ? ` · trial ends ${fmtDate(trialEndsOn)}` : ''}
    </Chip>
  )
}

/**
 * Pupils against the limit, as a figure and a bar.
 *
 * The bar is the point. "252 / 280" is a number the eye has to do arithmetic
 * on; a bar nine tenths full is read without thinking.
 *
 * NO MARGIN. Until 0155 a school could sit 10% over its plan in a state called
 * "within margin", which the bar drew in amber. That margin is gone: the limit
 * is the limit. The school is warned from 90% and stopped at 100%, and the bar
 * says exactly those two things, in that order.
 */
export function LimitBar({ s }: { s: PlatformSchool }) {
  const limit = s.student_limit
  const pct = limit && limit > 0 ? Math.min(100, (s.student_count / limit) * 100) : null
  const full = limit !== null && s.student_count >= limit
  const warn = limit !== null && !full && s.student_count >= Math.ceil(limit * 0.9)
  const tone = full ? 'bg-danger-500' : warn ? 'bg-due-500' : 'bg-money-500'
  return (
    <div className="min-w-[5.5rem]">
      <div className="whitespace-nowrap tabular-nums text-slate-700">
        {s.student_count.toLocaleString()}
        {limit !== null
          ? <span className="text-slate-400"> / {limit.toLocaleString()}</span>
          : <span className="text-slate-400"> · no limit</span>}
      </div>
      {pct !== null && (
        <div className="mt-1 h-1 w-full overflow-hidden rounded-full bg-slate-200">
          <div className={`h-full rounded-full ${tone}`} style={{ width: `${Math.max(2, pct)}%` }} />
        </div>
      )}
      {s.limit_state === 'over' ? (
        <div className="mt-0.5 text-[11px] font-medium text-danger-700">over the limit</div>
      ) : full ? (
        <div className="mt-0.5 text-[11px] font-medium text-danger-700">full: admissions stop</div>
      ) : warn ? (
        <div className="mt-0.5 text-[11px] text-due-700">nearly full</div>
      ) : null}
    </div>
  )
}

/**
 * How far what they have paid for reaches, said the way a person would say it.
 *
 * `expires_on` is the end of what covers the school today: the paid-through
 * date once anything is paid, the trial's end before that. The two are worded
 * differently because they are different conversations: one is a renewal, the
 * other is a first sale.
 */
export function ExpiryCell({ s }: { s: SchoolRow }) {
  if (!s.expires_on) return <span className="text-slate-400">nothing paid, no trial</span>
  const trial = s.status === 'trialing'
  const d = s.days_left
  const lead = trial ? 'trial to' : 'paid through'
  if (d === null) return <span className="text-slate-600">{lead} {fmtDate(s.expires_on)}</span>
  if (d < 0) {
    return (
      <span className="font-medium text-danger-700">
        {trial ? 'trial ended' : 'ran out'} {Math.abs(d)}d ago
        <span className="block text-[11px] font-normal text-slate-400">
          {lead} {fmtDate(s.expires_on)}
        </span>
      </span>
    )
  }
  return (
    <span className={d <= 14 ? 'font-medium text-due-700' : 'text-slate-600'}>
      {d}d left
      <span className="block text-[11px] font-normal text-slate-400">
        {lead} {fmtDate(s.expires_on)}
      </span>
    </span>
  )
}

/**
 * What recording money actually did, from the database's own answer.
 *
 * WHY THIS IS SHOWN AND NOT JUST "SAVED". Since 0155 a payment does several
 * things in one breath: it goes against what is owed, oldest first; money left
 * over raises the next term invoice and pays it; anything still left is credit;
 * and the school's paid-through date moves only as far as invoices are paid in
 * full. "Rs 30,000 recorded" says none of that, and the next question on the
 * phone is always "so are we open now, and until when?".
 */
export interface Settled {
  /** Rupees this payment put against invoices. Absent from a confirmed report. */
  allocated?: number | null
  raised?: {
    doc_no: string | null; months: number; amount: number
    period_start: string; period_end: string; owed?: number | null
  } | null
  not_raised_because?: string | null
  lapsed_voided?: number | null
  credit?: number | null
  status?: string | null
  paid_through?: string | null
  outstanding?: number | null
}

export function PaymentOutcome({ r }: { r: Settled }) {
  const lines: React.ReactNode[] = []
  if (r.allocated != null) {
    lines.push(Number(r.allocated) > 0
      ? <>{formatPkr(Number(r.allocated))} went against what they owed.</>
      : <>Nothing was owed, so none of it went against an invoice.</>)
  }
  if (Number(r.lapsed_voided ?? 0) > 0) {
    lines.push(<>
      {r.lapsed_voided} unpaid invoice(s) from the time they were locked were voided:
      they start again from today rather than paying for weeks they could not use.
    </>)
  }
  if (r.raised) {
    lines.push(<>
      Their next invoice{r.raised.doc_no ? `, ${r.raised.doc_no},` : ''} was raised for{' '}
      {r.raised.months} month(s), {fmtDate(r.raised.period_start)} to{' '}
      {fmtDate(r.raised.period_end)}, at {formatPkr(Number(r.raised.amount))}, and paid from
      this money
      {Number(r.raised.owed ?? 0) > 0 && <>, with {formatPkr(Number(r.raised.owed))} still owed on it</>}.
    </>)
  } else if (r.not_raised_because) {
    lines.push(<>No new invoice was raised: {r.not_raised_because}</>)
  }
  if (Number(r.credit ?? 0) > 0) {
    lines.push(<>{formatPkr(Number(r.credit))} is left over as credit. It comes off their next invoice.</>)
  }
  return (
    <div className="space-y-2">
      <dl className="grid grid-cols-[auto,1fr] gap-x-4 gap-y-1 rounded border border-money-200 bg-money-50 p-3 text-sm">
        <dt className="text-money-800">They are now</dt>
        <dd className="font-medium text-money-900">{statusWords(r.status)}</dd>
        <dt className="text-money-800">Paid through</dt>
        <dd className="font-medium text-money-900">
          {r.paid_through ? fmtDate(r.paid_through) : 'nothing paid in full yet'}
        </dd>
        {r.outstanding != null && (
          <>
            <dt className="text-money-800">Still owed</dt>
            <dd className={Number(r.outstanding) > 0 ? 'font-medium text-due-800' : 'text-money-900'}>
              {formatPkr(Number(r.outstanding))}
            </dd>
          </>
        )}
      </dl>
      {lines.length > 0 && (
        <ul className="list-disc space-y-1 pl-5 text-sm text-slate-700">
          {lines.map((l, i) => <li key={i}>{l}</li>)}
        </ul>
      )}
    </div>
  )
}

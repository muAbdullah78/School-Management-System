import type { PlatformSchool } from '@/lib/platform'
import { formatPkr } from '@/lib/licence'

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

export function StatusChip({ s }: { s: PlatformSchool }) {
  // Suspended FIRST, and as its own word. fn_effective_status returns 'locked'
  // for a suspension and for an expiry alike, so without this the operator
  // cannot tell "they did not pay" from "we switched them off".
  if (s.suspended) {
    return <Chip tone="stopped" title={s.suspend_reason ?? undefined}>We suspended them</Chip>
  }
  return <Chip tone={STATUS_TONE[s.status]}>{STATUS_LABEL[s.status]}</Chip>
}

/** What they owe, or nothing at all. Never a zero: a zero is not news. */
export function OwedChip({ amount }: { amount: number }) {
  if (!(amount > 0)) return null
  return <Chip tone="warn">owes {formatPkr(amount)}</Chip>
}

/**
 * Students against the tier, as a figure and a bar.
 *
 * The bar is the point. "180 / 200" is a number the eye has to do arithmetic on;
 * a bar nine tenths full is read without thinking, and an upgrade conversation
 * is exactly the thing worth spotting before the school does.
 */
export function LimitBar({ s }: { s: PlatformSchool }) {
  const limit = s.student_limit
  const pct = limit && limit > 0 ? Math.min(100, (s.student_count / limit) * 100) : null
  const tone = s.limit_state === 'over' ? 'bg-danger-500'
    : s.limit_state === 'within_margin' ? 'bg-due-500'
    : 'bg-money-500'
  return (
    <div className="min-w-[5.5rem]">
      <div className="whitespace-nowrap tabular-nums text-slate-700">
        {s.student_count.toLocaleString()}
        {limit !== null && <span className="text-slate-400"> / {limit.toLocaleString()}</span>}
      </div>
      {pct !== null && (
        <div className="mt-1 h-1 w-full overflow-hidden rounded-full bg-slate-200">
          <div className={`h-full rounded-full ${tone}`} style={{ width: `${Math.max(2, pct)}%` }} />
        </div>
      )}
      {s.limit_state === 'over' && (
        <div className="mt-0.5 text-[11px] font-medium text-danger-700">over the tier</div>
      )}
      {s.limit_state === 'within_margin' && (
        <div className="mt-0.5 text-[11px] text-due-700">near the tier</div>
      )}
    </div>
  )
}

/**
 * When their licence runs out, said the way a person would say it.
 *
 * "297d left" is fine on a row you are scanning. "expired 12d ago" is the one
 * that has to be unmissable, so it carries the colour rather than the label.
 */
export function ExpiryCell({ s }: { s: PlatformSchool }) {
  if (!s.expires_on) return <span className="text-slate-400">no end date</span>
  const d = s.days_left
  if (d === null) return <span className="text-slate-600">{s.expires_on}</span>
  if (d < 0) {
    return (
      <span className="font-medium text-danger-700">
        expired {Math.abs(d)}d ago
        <span className="block text-[11px] font-normal text-slate-400">{s.expires_on}</span>
      </span>
    )
  }
  return (
    <span className={d <= 14 ? 'font-medium text-due-700' : 'text-slate-600'}>
      {d}d left
      <span className="block text-[11px] font-normal text-slate-400">{s.expires_on}</span>
    </span>
  )
}

import { useState } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import {
  cancelMySubscription, chooseTerm, myNextPayment, resumeMySubscription,
  setManualPaymentMethod, pkToday,
} from '@/lib/db'
import { formatPkr } from '@/lib/licence'
import {
  requestMyInvoice, type RaisedInvoice, type SubscriptionView, type Term, type TermOption,
} from '@/lib/subscription'
import { TERM_LABEL, termSentence } from '@/lib/plans'
import { fmtDate } from '@/lib/format'
import { Button, inputClass, buttonClass } from '@/components/ui'

const CARD = 'rounded-2xl border border-slate-200 bg-white p-4 shadow-card'
const HEAD = 'text-xs font-semibold uppercase tracking-wide text-slate-500'

/** Everything that changes what the school pays is refreshed together. */
export function useRefreshBilling() {
  const qc = useQueryClient()
  return () => {
    for (const k of ['myNextPayment', 'myBilling', 'licence', 'myCode', 'myStudentLimit']) {
      void qc.invalidateQueries({ queryKey: [k] })
    }
  }
}

/** Whole days from one YYYY-MM-DD to another, counted on the calendar. */
export function dayDiff(from: string, to: string): number {
  const at = (d: string) => Date.UTC(+d.slice(0, 4), +d.slice(5, 7) - 1, +d.slice(8, 10))
  return Math.round((at(to) - at(from)) / 86_400_000)
}

/** A YYYY-MM-DD moved by n days. */
export function addDays(d: string, n: number): string {
  const t = new Date(Date.UTC(+d.slice(0, 4), +d.slice(5, 7) - 1, +d.slice(8, 10) + n))
  return t.toISOString().slice(0, 10)
}

/** "a month", "3 months", "a year", for inside a sentence. */
export function termWords(months: number): string {
  return months === 1 ? 'a month' : months === 12 ? 'a year' : `${months} months`
}

/**
 * When the school locks if nothing more is paid, in one sentence.
 *
 * FROM `locks_on`, THE DATABASE'S DATE, never worked out here. It is the day
 * the write gate starts refusing, so this sentence and the lock cannot drift
 * apart. Null when the school is already locked or cancelled, where the
 * summary says why instead.
 */
export function lockSentence(v: SubscriptionView): string | null {
  if (v.status === 'locked' || v.status === 'cancelled' || !v.locks_on) return null
  if (v.cancel_at_period_end) {
    return `Your subscription ends on ${fmtDate(v.covered_to)}, as you asked. Nothing further will be invoiced.`
  }
  const days = v.days_to_lock
  const when = days !== null && days > 0 ? ` (${days} day${days === 1 ? '' : 's'} from today)` : ''
  if (v.needs_price) {
    return `Your price is not set yet, so the software locks on ${fmtDate(v.locks_on)}${when}, the day after your `
      + 'free trial ends, until it is. Nothing is deleted when it locks.'
  }
  return `If payment has not reached us by ${fmtDate(addDays(v.locks_on, -1))}, the software locks on `
    + `${fmtDate(v.locks_on)}${when}. Nothing is deleted when it locks.`
}

/**
 * What the next invoice is, when it is due, when the school locks without it,
 * and how often the school pays.
 *
 * ONE SOURCE. Every figure here is from the subscription view
 * (fn__subscription_view), the same one the invoice is raised from, so the
 * amount on this card is the amount on the paper. It used to work its own
 * figure out from the price list and a separate discount preview, and showed
 * a school one number while the invoice said another.
 *
 * It never promises a charge nothing can make: for most schools here nothing
 * takes the money automatically, so it says "due on", not "you will be charged".
 *
 * Pass `view` when the screen already has it; on its own it reads
 * fn_my_next_payment.
 */
export function NextPaymentPanel({ view: given, onPrint }: {
  view?: SubscriptionView | null; onPrint?: (invoiceId: string) => void
} = {}) {
  const q = useQuery({ queryKey: ['myNextPayment'], queryFn: myNextPayment, enabled: given === undefined })
  const view = given ?? q.data?.view ?? null
  // Quiet without a view: the rest of the billing screen works without it.
  if (!view) return null
  return <Body v={view} onPrint={onPrint} />
}

function Body({ v, onPrint }: { v: SubscriptionView; onPrint?: (invoiceId: string) => void }) {
  const refresh = useRefreshBilling()
  // Held here, not in the button: once the invoice exists the button goes
  // away, and the answer must not go with it.
  const [raised, setRaised] = useState<RaisedInvoice | null>(null)
  const [askErr, setAskErr] = useState<string | null>(null)
  const ask = useMutation({
    mutationFn: requestMyInvoice,
    onSuccess: (r) => { setAskErr(null); setRaised(r); refresh() },
    onError: (e) => { setRaised(null); setAskErr((e as Error).message) },
  })
  const open = v.open_invoice
  // A school that asked to stop is not invoiced again, though the view still
  // prices the period after the end (it is what restarting would cost). Shown
  // as "Your next invoice" it sat directly above "Nothing further will be
  // invoiced".
  const quote = v.next?.quote?.priced && !v.cancel_at_period_end ? v.next.quote : null
  const lock = lockSentence(v)

  return (
    <section className={CARD} aria-labelledby="next-payment-head">
      <h2 id="next-payment-head" className={HEAD}>Next payment</h2>

      {open ? (
        <OpenInvoice inv={open} />
      ) : quote && v.next ? (
        <NextQuote q={quote} start={v.next.period_start} />
      ) : v.cancel_at_period_end && lock ? null : (
        <p className="mt-1 text-sm text-slate-700">
          {v.needs_price
            ? 'We are agreeing your price with you. Your first invoice follows once it is set.'
            : v.cancel_at_period_end || v.status === 'cancelled'
              ? 'Nothing further will be invoiced.'
              : 'Nothing is due at the moment.'}
        </p>
      )}

      {lock && <p className="mt-3 max-w-prose text-sm font-medium text-slate-800">{lock}</p>}
      {/* Locked for money: the way back, in the same place the lock date sat. */}
      {v.status === 'locked' && (v.locked_because === 'unpaid' || v.locked_because === 'expired') && v.pay_now > 0 && (
        <p className="mt-3 max-w-prose text-sm font-medium text-slate-800">
          Send {formatPkr(v.pay_now)} and tell us with &quot;I have paid&quot;. New entries start again as soon as we confirm it.
        </p>
      )}

      {v.can_request_invoice && (
        <div className="mt-3 grid gap-2 sm:flex sm:items-center">
          <Button size="sm" onClick={() => ask.mutate()} disabled={ask.isPending} className="w-full sm:w-auto">
            {ask.isPending ? 'Raising your invoice…' : 'Get my invoice'}
          </Button>
          <span className="text-xs text-slate-500">
            For your accounts office. Raising it does not change anything: paying it does.
          </span>
        </div>
      )}
      {raised && (
        <div className="mt-3 rounded-xl border border-brand-200 bg-brand-50 px-3 py-2 text-sm text-brand-900" role="status">
          <p>
            {raised.already
              ? `Invoice ${raised.doc_no ?? ''} is already open. It is in your invoices below.`
              : `Invoice ${raised.doc_no ?? ''} is ready: ${formatPkr(raised.amount)} for ${fmtDate(raised.period_start)} `
                + `to ${fmtDate(raised.period_end)}, due on ${fmtDate(raised.due_on)}. It is in your invoices below.`}
          </p>
          {onPrint && raised.invoice_id && (
            <button type="button" onClick={() => onPrint(raised.invoice_id)}
              className={buttonClass({ variant: 'soft', size: 'sm', className: 'mt-2' })}>
              Print it
            </button>
          )}
        </div>
      )}
      {/* The database's own sentence, as plain text: "your next invoice can be
          raised from 01 Nov" is an answer, not a failure. */}
      {askErr && <p className="mt-2 text-sm text-due-900">{askErr}</p>}

      <div className="mt-4 border-t border-slate-100 pt-4">
        {v.cancel_at_period_end || v.status === 'cancelled' ? (
          <>
            <h3 className={HEAD}>How often you pay</h3>
            <p className="mt-2 text-sm text-slate-600">Nothing further is scheduled.</p>
          </>
        ) : (
          <TermChooser v={v} />
        )}
      </div>
    </section>
  )
}

function Row({ k, v, tone }: { k: string; v: string; tone?: 'money' | 'strong' }) {
  return (
    <div className={`flex justify-between gap-3 ${tone === 'money' ? 'text-money-800' : ''} ${
      tone === 'strong' ? 'border-t border-slate-200 pt-1 font-semibold text-slate-900' : ''}`}>
      <dt className="min-w-0">{k}</dt>
      <dd className="shrink-0 tabular-nums">{v}</dd>
    </div>
  )
}

function OpenInvoice({ inv }: { inv: NonNullable<SubscriptionView['open_invoice']> }) {
  return (
    <div className="mt-1">
      <p className="text-sm text-slate-700">
        Invoice <span className="font-semibold text-slate-900">{inv.doc_no ?? '-'}</span>, for{' '}
        {fmtDate(inv.period_start)} to {fmtDate(inv.period_end)} ({termWords(inv.months)}).
      </p>
      <dl className="mt-2 max-w-sm space-y-0.5 text-sm text-slate-700">
        <Row k="Invoice total" v={formatPkr(inv.total)} />
        {inv.discount_code && inv.discount_amount > 0 && (
          <Row k={`Code ${inv.discount_code} took off`} v={formatPkr(inv.discount_amount)} tone="money" />
        )}
        <Row k="Paid so far" v={formatPkr(inv.paid)} />
        <Row k="Still owed" v={formatPkr(inv.owed)} tone="strong" />
      </dl>
      {inv.due_on && (
        <p className="mt-2 text-sm text-slate-700">
          Due on <span className="font-medium">{fmtDate(inv.due_on)}</span>, the first day of the period it pays for.
        </p>
      )}
    </div>
  )
}

/**
 * The next invoice before it exists, itemised the way the invoice will be:
 * the months at the monthly price, what paying for the term at once saves,
 * what the code takes off, and what is left. Shown openly, so a school can
 * check our arithmetic.
 */
function NextQuote({ q, start }: { q: NonNullable<SubscriptionView['next']>['quote']; start: string }) {
  const months = q.months
  return (
    <div className="mt-1">
      <p className="text-sm text-slate-700">
        Your next invoice covers {fmtDate(q.period_start ?? start)} to {fmtDate(q.period_end)} ({termWords(months)}).
        It is due on <span className="font-medium">{fmtDate(q.period_start ?? start)}</span>, the first day of that period.
      </p>
      <dl className="mt-2 max-w-sm space-y-0.5 text-sm text-slate-700">
        <Row k={`${months === 1 ? 'One month' : `${months} months`} at ${formatPkr(q.month_price)} a month`} v={formatPkr(q.list_amount)} />
        {q.term_saving > 0 && (
          <Row k={`Less, for paying ${termWords(months)} at a time`} v={`- ${formatPkr(q.term_saving)}`} tone="money" />
        )}
        {q.discount && q.discount_amount > 0 && (
          <Row k={`Less code ${q.discount.code}${q.discount.label ? ` (${q.discount.label})` : ''}, ${
            q.discount.months_covered} of ${months} month${months === 1 ? '' : 's'}`}
            v={`- ${formatPkr(q.discount_amount)}`} tone="money" />
        )}
        <Row k="Amount" v={formatPkr(q.amount)} tone="strong" />
      </dl>
      {q.discount_note && <p className="mt-1 text-xs text-slate-500">{q.discount_note}</p>}
    </div>
  )
}

/** What chooseTerm says back, with the reissue detail fn_choose_term adds. */
type TermChange = Awaited<ReturnType<typeof chooseTerm>> & {
  invoice?: {
    kept?: string; why?: string; voided?: string
    raised?: (Partial<RaisedInvoice> & { not_raised?: string }) | null
  } | null
}

export function termChangeSentence(r: TermChange, months: Term): string {
  if (r.changed === false) return `You already pay ${termSentence(months)}.`
  const inv = r.invoice
  if (inv?.voided && inv.raised?.doc_no) {
    const n = inv.raised
    return `Done. Invoice ${inv.voided} is cancelled and ${n.doc_no} replaces it: ${formatPkr(n.amount ?? 0)} for `
      + `${fmtDate(n.period_start)} to ${fmtDate(n.period_end)}, due on ${fmtDate(n.due_on)}.`
  }
  if (inv?.voided) {
    return `Done. Invoice ${inv.voided} is cancelled. Use "Get my invoice" when you need the new one.`
  }
  // Kept for the database's own reason, which is not always money paid on it:
  // an invoice we set by hand, or a roll bigger than the plan, keeps it too.
  if (inv?.kept) {
    const base = `Done. You pay ${termSentence(months)} from the invoice after ${inv.kept}`
    if (!inv.why) return `${base}, which stays as it is.`
    return /^[A-Z]/.test(inv.why) ? `${base}. ${inv.why}` : `${base}, which stays as it is: ${inv.why}.`
  }
  return `Done. You now pay ${termSentence(months)}, from ${r.applies_from ?? 'your next invoice'}.`
}

/**
 * Monthly, three months, or a year, as three price boxes.
 *
 * THE FIGURES ARE THE INVOICE'S. Each box is fn__quote for that term, with the
 * school's code already taken off, so the box and the invoice say the same
 * thing. There used to be two sets: these with the list price and a table
 * further down with the discounted one, an inch apart.
 *
 * A TAP ASKS FIRST. It used to switch the term the moment a box was touched,
 * so a thumb brushing "Yearly" on a phone put a monthly school onto a yearly
 * invoice. Now it says what will happen to the invoice (reissued, or from the
 * next one) and waits for a yes.
 */
function TermChooser({ v }: { v: SubscriptionView }) {
  const refresh = useRefreshBilling()
  const [asking, setAsking] = useState<Term | null>(null)
  const [err, setErr] = useState<string | null>(null)
  const [done, setDone] = useState<string | null>(null)
  const rows = v.terms ?? []
  const current = v.term_months

  const pick = useMutation({
    mutationFn: (m: Term) => chooseTerm(m),
    onSuccess: (r, m) => { setErr(null); setAsking(null); setDone(termChangeSentence(r as TermChange, m)); refresh() },
    onError: (e) => setErr((e as Error).message),
  })

  // Enterprise before its price is agreed: there is nothing to choose between,
  // and boxes saying Rs 0 would read as free.
  if (!v.price.priced || rows.length === 0) {
    return (
      <>
        <h3 className={HEAD}>How often you pay</h3>
        <p className="mt-2 text-sm text-slate-600">
          {v.needs_price
            ? 'Once your price is agreed you choose to pay monthly, every 3 months or yearly.'
            : 'Talk to us about how often you pay.'}
        </p>
      </>
    )
  }

  const asked = rows.find((t) => t.months === asking) ?? null
  const open = v.open_invoice
  const label = (m: number) => (TERM_LABEL[m] ?? `${m} months`).toLowerCase()

  return (
    <div>
      <h3 className={HEAD}>How often you pay</h3>
      <div className="mt-2 flex flex-col gap-2 sm:flex-row">
        {rows.map((t) => {
          const on = current === t.months
          return (
            <button key={t.months} type="button" disabled={pick.isPending}
              onClick={() => { if (!on) { setErr(null); setDone(null); setAsking(t.months) } }}
              aria-pressed={on}
              className={`flex items-center justify-between gap-3 rounded-xl border p-3 text-left transition focus:outline-none focus-visible:ring-2 focus-visible:ring-brand-500 sm:flex-1 sm:flex-col sm:items-start sm:justify-start ${
                on ? 'border-brand-500 bg-brand-50 ring-1 ring-brand-200' : 'border-slate-200 bg-white hover:bg-slate-50'}`}>
              <span>
                <span className="block text-sm font-semibold text-slate-900">
                  {TERM_LABEL[t.months] ?? `${t.months} months`}
                  {on && <span className="ml-1.5 text-xs font-medium text-brand-700">· on now</span>}
                </span>
                {t.months > 1 && <span className="block text-xs text-slate-500">{formatPkr(t.per_month)} a month</span>}
                <TermSaving t={t} />
              </span>
              <span className="text-right sm:text-left">
                {t.discount_amount > 0 && (
                  <span className="block whitespace-nowrap text-xs tabular-nums text-slate-400 line-through">{formatPkr(t.term_price)}</span>
                )}
                <span className="block whitespace-nowrap text-lg font-semibold tabular-nums text-slate-900">{formatPkr(t.amount)}</span>
              </span>
            </button>
          )
        })}
      </div>
      {/* Why a code does not come off a term, once, under the boxes. */}
      {Array.from(new Set(rows.map((t) => t.discount_note).filter(Boolean))).map((note) => (
        <p key={note} className="mt-2 text-xs text-slate-500">{note}</p>
      ))}

      {asked && (
        <div className="mt-3 rounded-xl border border-brand-200 bg-brand-50 p-3 text-sm text-brand-900">
          {open && open.paid <= 0 ? (
            <>
              <p className="font-medium">Pay {label(asked.months)} instead?</p>
              <p className="mt-0.5 text-xs">
                Your open invoice {open.doc_no} is cancelled and reissued for {termWords(asked.months)}:{' '}
                {formatPkr(asked.amount)}. Nothing is charged today.
              </p>
            </>
          ) : open ? (
            <>
              <p className="font-medium">Pay {label(asked.months)} from the invoice after {open.doc_no}?</p>
              <p className="mt-0.5 text-xs">
                You have started paying {open.doc_no}, so it stays as it is. The invoice after it will be{' '}
                {formatPkr(asked.amount)}.
              </p>
            </>
          ) : (
            <>
              <p className="font-medium">Pay {label(asked.months)} from your next invoice?</p>
              <p className="mt-0.5 text-xs">
                Your next invoice will be {formatPkr(asked.amount)}. Nothing is charged today, and the period you have
                already paid for does not change.
              </p>
            </>
          )}
          <div className="mt-2 grid grid-cols-2 gap-2 sm:flex">
            <Button size="sm" onClick={() => pick.mutate(asked.months)} disabled={pick.isPending}>
              {pick.isPending ? 'Switching…' : 'Switch'}
            </Button>
            <Button size="sm" variant="soft" tone="neutral" onClick={() => setAsking(null)}>
              Keep {TERM_LABEL[current]?.toLowerCase() ?? 'what I have'}
            </Button>
          </div>
        </div>
      )}
      {done && <p className="mt-2 rounded-xl bg-brand-50 px-3 py-2 text-sm text-brand-900" role="status">{done}</p>}
      {err && <p className="mt-2 text-sm text-danger-700">{err}</p>}
    </div>
  )
}

/**
 * What a term saves, from the view's own figures. On a month there is no term
 * saving to show, only what a code takes off; on longer terms the saving is
 * against paying month by month, code included, and says how much of it the
 * code is.
 */
function TermSaving({ t }: { t: TermOption }) {
  if (t.months === 1) {
    return t.discount_amount > 0
      ? <span className="block text-xs font-medium text-money-700">{formatPkr(t.discount_amount)} off with your code</span>
      : null
  }
  if (t.saving <= 0) return null
  return (
    <span className="block text-xs font-medium text-money-700">
      Save {formatPkr(t.saving)} against monthly
      {t.discount_amount > 0 ? `, ${formatPkr(t.discount_amount)} of it from your code` : ''}
    </span>
  )
}

/**
 * The school's own account: where their transfer will come FROM.
 *
 * It sat beside "How to pay", headed "How you will pay", with the school's own
 * wallet in it. A school that had typed "SadaPay" read that as where to send
 * the money, a few lines from our Meezan account, and did not know which was
 * right. It is now headed as theirs, says what it is for, and sits under our
 * account rather than beside it.
 */
export function YourAccountBlock() {
  const q = useQuery({ queryKey: ['myNextPayment'], queryFn: myNextPayment })
  const refresh = useRefreshBilling()
  const n = q.data
  const [editing, setEditing] = useState(false)
  const [label, setLabel] = useState('')
  const [instr, setInstr] = useState('')
  const [err, setErr] = useState<string | null>(null)
  // What was just saved, shown until the read catches up with it.
  const [saved, setSaved] = useState<{ label: string; instructions: string | null } | null>(null)
  const save = useMutation({
    mutationFn: () => setManualPaymentMethod(label, instr.trim() || null),
    onSuccess: () => {
      setErr(null); setEditing(false)
      setSaved({ label: label.trim(), instructions: instr.trim() || null })
      refresh()
    },
    onError: (e) => setErr((e as Error).message),
  })
  if (!n?.has_subscription) return null
  const m = n.method ?? null
  const shown = m ? { label: m.kind === 'card' && m.last4 ? `${m.brand ?? 'Card'} ending ${m.last4}` : m.label || 'Recorded', instructions: m.instructions } : saved

  function open() {
    setLabel(m?.label ?? saved?.label ?? '')
    setInstr(m?.instructions ?? saved?.instructions ?? '')
    setErr(null)
    setEditing(true)
  }

  return (
    <div className="mt-4 rounded-xl bg-slate-50 p-3">
      <div className="text-xs font-semibold uppercase tracking-wide text-slate-500">Your account (where you send from)</div>
      <p className="mt-0.5 text-xs text-slate-500">Only so we can recognise your transfer. It is not where to pay: that is our account above.</p>
      {!editing && (
        <div className="mt-2 text-sm">
          {shown ? (
            <>
              <div className="font-medium text-slate-800">{shown.label}</div>
              {shown.instructions && <div className="text-xs text-slate-500">{shown.instructions}</div>}
            </>
          ) : (
            <p className="text-slate-600">Not told us yet.</p>
          )}
          {!n.cancel_at_period_end && (
            <p className={`mt-1 text-xs ${n.auto_renew ? 'text-slate-600' : 'text-due-800'}`}>
              {n.auto_renew
                ? 'Renews automatically on the date above.'
                : 'Nothing is taken automatically. You send the payment, we match it to your invoice, and we remind you before it is due.'}
            </p>
          )}
          <button type="button" onClick={open} className={buttonClass({ variant: 'soft', size: 'sm', className: 'mt-2' })}>
            {shown ? 'Change' : 'Tell us where it will come from'}
          </button>
        </div>
      )}
      {editing && (
        <div className="mt-2 space-y-2">
          <label className="block">
            <span className="text-xs text-slate-600">Your bank or wallet</span>
            <input value={label} onChange={(e) => setLabel(e.target.value)} placeholder="e.g. HBL current account, or SadaPay"
              className={`mt-1 ${inputClass}`} />
          </label>
          <label className="block">
            <span className="text-xs text-slate-600">Anything that helps us match it</span>
            <input value={instr} onChange={(e) => setInstr(e.target.value)} placeholder="e.g. sent from 0300-1234567, reference SCHOOL-AQ"
              className={`mt-1 ${inputClass}`} />
          </label>
          <p className="text-xs text-slate-500">Please do not put a card number here. This is only so we can recognise your transfer.</p>
          {err && <p className="text-xs text-danger-700">{err}</p>}
          <div className="grid grid-cols-2 gap-2 sm:flex">
            <Button size="sm" onClick={() => save.mutate()} disabled={save.isPending || label.trim() === ''}>
              {save.isPending ? 'Saving…' : 'Save'}
            </Button>
            <Button size="sm" variant="soft" tone="neutral" onClick={() => { setEditing(false); setErr(null) }}>Cancel</Button>
          </div>
        </div>
      )}
    </div>
  )
}

/**
 * Leaving, and changing your mind. At the bottom, quiet, two presses, and it
 * says what the school KEEPS: nothing is deleted and the software runs to the
 * date already paid for.
 */
export function LeaveOrStayPanel() {
  const q = useQuery({ queryKey: ['myNextPayment'], queryFn: myNextPayment })
  const refresh = useRefreshBilling()
  const [asking, setAsking] = useState(false)
  const [reason, setReason] = useState('')
  const [err, setErr] = useState<string | null>(null)
  const leave = useMutation({
    mutationFn: () => cancelMySubscription(reason.trim() || null),
    onSuccess: () => { setErr(null); setAsking(false); refresh() },
    onError: (e) => setErr((e as Error).message),
  })
  const stay = useMutation({
    mutationFn: () => resumeMySubscription(),
    onSuccess: () => { setErr(null); refresh() },
    onError: (e) => setErr((e as Error).message),
  })
  const n = q.data
  if (!n?.has_subscription) return null
  // What is covered, paid or trial, from the view when there is one.
  const endsOn = n.view?.covered_to ?? n.period_end ?? n.trial_ends_on ?? null

  if (n.cancel_at_period_end) {
    // The Karachi date, not the UTC one: after 7pm in Pakistan the UTC date is
    // already tomorrow's, and "carry on" vanished five hours early.
    const stillRunning = !!endsOn && endsOn >= pkToday()
    return (
      <div className="px-1">
        {err && <p className="mb-1 text-xs text-danger-700">{err}</p>}
        {/* Restarting works after the end as well (the software then opens
            again when the next payment reaches us), so the button is offered
            either side of the date rather than a phone number after it. */}
        <p className="text-sm text-slate-600">
          {stillRunning
            ? <>Your subscription is set to end on {fmtDate(endsOn)}.{' '}</>
            : <>Your subscription has ended. Everything is where you left it, and the software opens again when your next payment reaches us.{' '}</>}
          <button type="button" onClick={() => stay.mutate()} disabled={stay.isPending}
            className={buttonClass({ variant: 'soft', size: 'sm', className: 'ml-1' })}>
            {stay.isPending ? 'Restarting…' : stillRunning ? 'Carry on instead' : 'Start again'}
          </button>
        </p>
      </div>
    )
  }

  if (!asking) {
    return (
      <div className="px-1">
        <button type="button" onClick={() => setAsking(true)} className="text-xs text-slate-500 hover:text-slate-800 hover:underline">
          Cancel my subscription
        </button>
      </div>
    )
  }

  return (
    <div className={CARD}>
      <p className="text-sm font-medium text-slate-800">Stop at the end of what you have already paid for?</p>
      <ul className="mt-1.5 list-disc space-y-0.5 pl-5 text-xs text-slate-600">
        <li>The software keeps working until {endsOn ? <span className="font-medium">{fmtDate(endsOn)}</span> : 'the end of your paid period'}. Nothing stops today.</li>
        <li>An invoice for time after that date, with nothing paid on it, is cancelled.</li>
        <li>Nothing is deleted. Every pupil, payment and result stays exactly as it is.</li>
        <li>You can download all of your records at any time, including afterwards.</li>
        <li>You can carry on instead, from this screen, before that date.</li>
      </ul>
      <label className="mt-2 block">
        <span className="text-xs text-slate-600">If you have a moment, what made you decide? It is optional.</span>
        <input value={reason} onChange={(e) => setReason(e.target.value)} placeholder="e.g. too expensive for our size"
          className={`mt-1 ${inputClass}`} />
      </label>
      {err && <p className="mt-1 text-xs text-danger-700">{err}</p>}
      <div className="mt-3 grid gap-2 sm:flex">
        <Button size="sm" variant="soft" tone="danger" onClick={() => leave.mutate()} disabled={leave.isPending}>
          {leave.isPending ? 'Cancelling…' : 'Yes, cancel at the end'}
        </Button>
        <Button size="sm" variant="soft" tone="neutral" onClick={() => { setAsking(false); setErr(null) }}>Keep my subscription</Button>
      </div>
    </div>
  )
}

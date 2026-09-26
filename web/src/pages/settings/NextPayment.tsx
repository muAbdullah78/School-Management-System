import { useState } from 'react'
import { useMutation, useQueries, useQuery, useQueryClient } from '@tanstack/react-query'
import {
  cancelMySubscription, chooseTerm, myNextPayment, resumeMySubscription,
  setManualPaymentMethod, pkToday, type NextPayment,
} from '@/lib/db'
import { formatPkr } from '@/lib/licence'
import { myDiscount, previewDiscount, TERM_LABEL } from '@/lib/plans'
import { fmtDate } from '@/lib/format'
import { Button, inputClass } from '@/components/ui'

const CARD = 'rounded-2xl border border-slate-200 bg-white p-4 shadow-card'
const HEAD = 'text-xs font-semibold uppercase tracking-wide text-slate-500'

/** Everything that changes what the school pays is refreshed together. */
function useRefreshBilling() {
  const qc = useQueryClient()
  return () => {
    for (const k of ['myNextPayment', 'myBilling', 'licence', 'invoicePreview', 'myDiscount']) {
      void qc.invalidateQueries({ queryKey: [k] })
    }
  }
}

/**
 * What the next invoice will be, when, and how often the school pays.
 *
 * THE SENTENCE COMES FROM THE DATABASE, so this screen and the reminder say the
 * same date in the same words. It never promises a charge nothing can make:
 * for most schools here nothing takes the money automatically, so it says
 * "due by", not "you will be charged".
 *
 * THE THREE TERMS ARE THE PRICE BOXES, with the discount already taken off.
 * There used to be two panels: these buttons with the list price, and an
 * itemised table further down with the discounted one, so the same screen
 * quoted two prices for the same year an inch apart. One set of boxes now, each
 * showing what the invoice will actually say.
 */
export function NextPaymentPanel() {
  const q = useQuery({ queryKey: ['myNextPayment'], queryFn: myNextPayment })
  // Quiet on failure: the rest of the billing screen works without it.
  if (q.isLoading || q.error || !q.data?.has_subscription) return null
  return <Body n={q.data} />
}

function Body({ n }: { n: NextPayment }) {
  const due = n.next_charge_on ?? null
  const amount = n.next_charge_amount ?? null
  const today = pkToday()
  const daysAway = due
    ? Math.round((Date.UTC(+due.slice(0, 4), +due.slice(5, 7) - 1, +due.slice(8, 10))
      - Date.UTC(+today.slice(0, 4), +today.slice(5, 7) - 1, +today.slice(8, 10))) / 86_400_000)
    : null

  return (
    <section className={`${CARD} ${n.in_trial ? 'border-info-200 bg-info-50/40' : ''}`}>
      <div className={HEAD}>{n.in_trial ? 'Your free trial' : 'Next payment'}</div>
      <p className="mt-1 max-w-prose text-sm font-medium text-slate-800">{n.sentence}</p>
      {due && amount !== null && !n.cancel_at_period_end && (
        <div className="mt-2 flex flex-wrap items-baseline gap-x-3 gap-y-1">
          <span className="text-2xl font-semibold tabular-nums text-slate-900">{formatPkr(amount)}</span>
          <span className="text-sm text-slate-600">
            for {n.term_months === 12 ? 'a year' : n.term_months === 1 ? 'one month' : `${n.term_months} months`}
          </span>
          {daysAway !== null && (
            <span className={`rounded-full px-2 py-0.5 text-xs font-medium ${
              daysAway < 0 ? 'bg-danger-50 text-danger-800' : daysAway <= 7 ? 'bg-due-50 text-due-800' : 'bg-slate-100 text-slate-600'}`}>
              {daysAway < 0 ? `${Math.abs(daysAway)} day${daysAway === -1 ? '' : 's'} overdue`
                : daysAway === 0 ? 'due today' : `due in ${daysAway} day${daysAway === 1 ? '' : 's'}`}
            </span>
          )}
        </div>
      )}

      <div className="mt-4 border-t border-slate-100 pt-4">
        {n.cancel_at_period_end ? (
          <>
            <div className={HEAD}>How often you pay</div>
            <p className="mt-2 text-sm text-slate-600">
              Nothing further is scheduled. If you start again, you choose monthly, three months or a year then.
            </p>
          </>
        ) : (
          <TermChooser n={n} />
        )}
      </div>
    </section>
  )
}

/**
 * Monthly, three months, or a year, as three price boxes.
 *
 * A TAP ASKS FIRST. It used to switch the term the moment a box was touched,
 * so a thumb brushing "A year" on a phone put a monthly school onto a yearly
 * invoice. It applies from the next payment either way, and now it says so and
 * waits for a yes.
 */
function TermChooser({ n }: { n: NextPayment }) {
  const refresh = useRefreshBilling()
  const [asking, setAsking] = useState<1 | 3 | 12 | null>(null)
  const [err, setErr] = useState<string | null>(null)
  const disc = useQuery({ queryKey: ['myDiscount'], queryFn: myDiscount, retry: false })
  const code = disc.data?.code ?? null
  const rows = n.terms ?? []
  const current = n.term_months ?? 12
  const previews = useQueries({
    queries: rows.map((t) => ({
      queryKey: ['invoicePreview', n.plan_code, t.months, code],
      queryFn: async () => (code && n.plan_code ? await previewDiscount(code, n.plan_code, t.months) : null),
      enabled: !!code && !!n.plan_code,
      staleTime: 60_000,
    })),
  })

  const pick = useMutation({
    mutationFn: (m: 1 | 3 | 12) => chooseTerm(m),
    onSuccess: () => { setErr(null); setAsking(null); refresh() },
    onError: (e) => setErr((e as Error).message),
  })

  if (rows.length === 0) {
    return (
      <>
        <div className={HEAD}>How often you pay</div>
        <p className="mt-2 text-sm text-slate-600">Your plan is priced by arrangement. Talk to us about the term.</p>
      </>
    )
  }

  const priced = rows.map((t, i) => {
    const pv = previews[i]?.data
    const off = pv?.ok ? Number(pv.discount_amount ?? 0) : 0
    return { ...t, total: Math.max(t.amount - off, 0), off }
  })
  const asked = priced.find((t) => t.months === asking) ?? null

  return (
    <div>
      <div className={HEAD}>How often you pay</div>
      <div className="mt-2 flex flex-col gap-2 sm:flex-row">
        {priced.map((t) => {
          const on = current === t.months
          return (
            <button key={t.months} type="button" disabled={pick.isPending}
              onClick={() => { if (!on) { setErr(null); setAsking(t.months) } }}
              aria-pressed={on}
              className={`flex items-center justify-between gap-3 rounded-xl border p-3 text-left transition sm:flex-1 sm:flex-col sm:items-start sm:justify-start ${
                on ? 'border-brand-500 bg-brand-50 ring-1 ring-brand-200' : 'border-slate-200 bg-white hover:bg-slate-50'}`}>
              <span>
                <span className="block text-sm font-semibold text-slate-900">
                  {TERM_LABEL[t.months] ?? `${t.months} months`}
                  {on && <span className="ml-1.5 text-xs font-medium text-brand-700">· on now</span>}
                </span>
                {t.saving > 0 && <span className="block text-xs font-medium text-money-700">save {formatPkr(t.saving)} against monthly</span>}
              </span>
              <span className="text-right sm:text-left">
                {t.off > 0 && <span className="block whitespace-nowrap text-xs tabular-nums text-slate-400 line-through">{formatPkr(t.amount)}</span>}
                <span className="block whitespace-nowrap text-lg font-semibold tabular-nums text-slate-900">{formatPkr(t.total)}</span>
              </span>
            </button>
          )
        })}
      </div>
      {code && priced.some((t) => t.off > 0) && (
        <p className="mt-2 text-xs text-slate-500">Prices shown after your code {code}.</p>
      )}
      {!rows.some((t) => t.months === current) && (
        <p className="mt-2 text-xs text-slate-600">
          You are on a {current} month term, arranged with us. Choosing one of these moves you onto the price list
          from your next payment.
        </p>
      )}

      {asked && (
        <div className="mt-3 rounded-xl border border-brand-200 bg-brand-50 p-3 text-sm text-brand-900">
          <p className="font-medium">Pay {TERM_LABEL[asked.months]?.toLowerCase() ?? `every ${asked.months} months`} from your next payment?</p>
          <p className="mt-0.5 text-xs">
            Your next invoice will be {formatPkr(asked.total)}. Nothing is charged today, and the period you have already
            paid for does not change.
          </p>
          <div className="mt-2 grid grid-cols-2 gap-2 sm:flex">
            <Button size="sm" onClick={() => pick.mutate(asked.months)} disabled={pick.isPending}>
              {pick.isPending ? 'Switching…' : 'Switch'}
            </Button>
            <Button size="sm" variant="soft" tone="neutral" onClick={() => setAsking(null)}>Keep {TERM_LABEL[current]?.toLowerCase() ?? 'what I have'}</Button>
          </div>
        </div>
      )}
      {err && <p className="mt-2 text-sm text-danger-700">{err}</p>}
    </div>
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
  const save = useMutation({
    mutationFn: () => setManualPaymentMethod(label, instr.trim() || null),
    onSuccess: () => { setErr(null); setEditing(false); refresh() },
    onError: (e) => setErr((e as Error).message),
  })
  if (!n?.has_subscription) return null
  const m = n.method

  function open() {
    setLabel(m?.label ?? '')
    setInstr(m?.instructions ?? '')
    setErr(null)
    setEditing(true)
  }

  return (
    <div className="mt-4 rounded-xl bg-slate-50 p-3">
      <div className="text-xs font-semibold uppercase tracking-wide text-slate-500">Your account (where you send from)</div>
      <p className="mt-0.5 text-xs text-slate-500">Only so we can recognise your transfer. It is not where to pay: that is our account above.</p>
      {!editing && (
        <div className="mt-2 text-sm">
          {m ? (
            <>
              <div className="font-medium text-slate-800">
                {m.kind === 'card' && m.last4 ? `${m.brand ?? 'Card'} ending ${m.last4}` : m.label || 'Recorded'}
              </div>
              {m.instructions && <div className="text-xs text-slate-500">{m.instructions}</div>}
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
          <button onClick={open} className="mt-1.5 text-xs font-medium text-brand-700 hover:underline">
            {m ? 'Change' : 'Tell us where it will come from'}
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
  const endsOn = n.period_end ?? n.trial_ends_on ?? null

  if (n.cancel_at_period_end) {
    // The Karachi date, not the UTC one: after 7pm in Pakistan the UTC date is
    // already tomorrow's, and "carry on" vanished five hours early.
    const stillRunning = !!n.period_end && n.period_end >= pkToday()
    return (
      <div className="px-1">
        {err && <p className="mb-1 text-xs text-danger-700">{err}</p>}
        {stillRunning ? (
          <p className="text-sm text-slate-600">
            Your subscription is set to end on {fmtDate(n.period_end)}.{' '}
            <button onClick={() => stay.mutate()} disabled={stay.isPending}
              className="font-medium text-brand-700 hover:underline disabled:opacity-60">
              {stay.isPending ? 'Restarting…' : 'Carry on instead'}
            </button>
          </p>
        ) : (
          <p className="text-sm text-slate-600">Your subscription has ended. Choose a plan to start again: everything is where you left it.</p>
        )}
      </div>
    )
  }

  if (!asking) {
    return (
      <div className="px-1">
        <button onClick={() => setAsking(true)} className="text-xs text-slate-500 hover:text-slate-800 hover:underline">
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

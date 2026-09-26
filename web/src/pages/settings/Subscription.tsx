import { useEffect, useState } from 'react'
import { Link } from 'react-router-dom'
import { today } from '@/lib/dates'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { myBilling, myNextPayment, myPlatformInvoice, reportSubscriptionPayment } from '@/lib/db'
import type { MyBilling, MyBillingDocument } from '@/lib/db'
import { InvoiceDoc } from '@/components/InvoiceDoc'
import { formatPkr } from '@/lib/licence'
import {
  applyDiscount, myDiscount, previewDiscount, removeMyDiscount, termSentence,
  type DiscountPreview, type MyDiscount,
} from '@/lib/plans'
import { fmtDate, fmtDateTime } from '@/lib/format'
import { Button, inputClass, buttonClass } from '@/components/ui'
import { NextPaymentPanel, YourAccountBlock, LeaveOrStayPanel } from './NextPayment'
import { RoomForPupils } from './RoomForPupils'

const CARD = 'rounded-2xl border border-slate-200 bg-white p-4 shadow-card'
const HEAD = 'text-xs font-semibold uppercase tracking-wide text-slate-500'

/**
 * Your subscription: the school's own view of what it owes us.
 *
 * THE ORDER IS THE ORDER OF THE QUESTIONS. What are we on and what do we owe,
 * then is anything stopping us (the roll), then what is the next bill and how
 * often, then where do we send the money, then the paperwork. It used to open
 * with four panels about the NEXT invoice and put what is owed today, and the
 * bank account to pay it into, fifth and sixth.
 *
 * OWNER AND PRINCIPAL ONLY, enforced in the database.
 *
 * The one thing this screen must never do is look like it took a payment. "I
 * have paid" creates a REPORT we check against our bank statement, and it says
 * so before the button and after it.
 */
export function Subscription() {
  const q = useQuery({ queryKey: ['myBilling'], queryFn: myBilling })
  // A discount that cannot be read is not a reason to break the page.
  const discount = useQuery({ queryKey: ['myDiscount'], queryFn: myDiscount, retry: false })
  const [printing, setPrinting] = useState<string | null>(null)
  const [reporting, setReporting] = useState(false)

  if (q.isLoading) return <div className="h-40 animate-pulse rounded-2xl bg-slate-100" />
  if (q.error) {
    return (
      <div className="rounded-xl border border-danger-200 bg-danger-50 px-3 py-2 text-sm text-danger-800">
        Your subscription could not be loaded. {(q.error as Error).message}
      </div>
    )
  }
  const b = q.data
  if (!b || !b.ok) {
    return <p className="text-sm text-slate-500">No subscription is set up for this school yet. Contact us to start one.</p>
  }

  const owed = Number(b.balance.outstanding || 0)
  const pending = b.reports.filter((r) => r.status === 'pending')

  return (
    <div className="space-y-4">
      <Summary b={b} owed={owed} discount={discount.data ?? null} onPay={() => setReporting(true)} />
      <RoomForPupils />
      <NextPaymentPanel />
      <PayUs b={b} pending={pending} onPay={() => setReporting(true)} />
      <ApplyCodePanel current={discount.data ?? null} />
      <Documents docs={b.documents} onPrint={setPrinting} />
      <Reports reports={b.reports} />
      <LeaveOrStayPanel />

      {printing && <PrintDialog invoiceId={printing} onClose={() => setPrinting(null)} />}
      {reporting && (
        <ReportDialog suggested={owed > 0 ? owed : null} discount={discount.data ?? null}
          pending={pending} onClose={() => setReporting(false)} />
      )}
    </div>
  )
}

const STATUS: Record<string, { word: string; skin: string }> = {
  trialing: { word: 'Free trial', skin: 'bg-info-50 text-info-800 ring-info-200' },
  active: { word: 'Active', skin: 'bg-brand-50 text-brand-800 ring-brand-200' },
  grace: { word: 'Expired: still working while we wait for payment', skin: 'bg-due-50 text-due-800 ring-due-200' },
  locked: { word: 'Expired: new entries are paused', skin: 'bg-danger-50 text-danger-800 ring-danger-200' },
  cancelled: { word: 'Cancelled', skin: 'bg-slate-100 text-slate-700 ring-slate-200' },
}

function Summary({ b, owed, discount, onPay }: {
  b: MyBilling; owed: number; discount: MyDiscount | null; onPay: () => void
}) {
  const lic = b.licence as Record<string, unknown>
  const status = String(lic.status ?? '')
  const daysLeft = lic.days_left == null ? null : Number(lic.days_left)
  const st = STATUS[status]
  return (
    <section className={CARD}>
      <div className="flex flex-col gap-4 sm:flex-row sm:items-start sm:justify-between">
        <div className="min-w-0">
          <div className={HEAD}>Your plan</div>
          <div className="mt-0.5 text-xl font-semibold text-slate-900">{String(lic.plan_name ?? lic.plan_code ?? '-')}</div>
          <div className="mt-1 flex flex-wrap items-center gap-2 text-sm text-slate-600">
            {st && <span className={`rounded-full px-2 py-0.5 text-xs font-medium ring-1 ${st.skin}`}>{st.word}</span>}
            {lic.expires_on ? <span>until {fmtDate(String(lic.expires_on))}</span> : null}
            {daysLeft !== null && (
              <span className={daysLeft < 0 ? 'text-danger-700' : daysLeft <= 7 ? 'text-due-800' : 'text-slate-500'}>
                {daysLeft >= 0 ? `${daysLeft} day${daysLeft === 1 ? '' : 's'} left` : `ended ${Math.abs(daysLeft)} day${daysLeft === -1 ? '' : 's'} ago`}
              </span>
            )}
          </div>
          <div className="mt-1 text-sm text-slate-600">Paid {termSentence(lic.term_months as number | null | undefined)}</div>
          {discount && (
            <p className="mt-2 inline-block rounded-lg bg-money-50 px-2.5 py-1 text-xs text-money-800 ring-1 ring-money-100">
              <span className="font-semibold">{discount.code}</span>: {discount.summary}
              {discount.total_saved > 0 ? `. Saved you ${formatPkr(discount.total_saved)} so far.` : ''}
            </p>
          )}
        </div>
        <div className="rounded-xl bg-slate-50 p-3 sm:min-w-[12rem] sm:text-right">
          <div className={HEAD}>You owe us now</div>
          <div className={`text-2xl font-semibold tabular-nums ${owed > 0 ? 'text-due-800' : 'text-slate-900'}`}>
            {owed > 0 ? formatPkr(owed) : 'Nothing'}
          </div>
          <div className="text-xs text-slate-500">Invoiced {formatPkr(b.balance.billed)} · paid {formatPkr(b.balance.paid)}</div>
        </div>
      </div>

      {(status === 'locked' || status === 'grace') && (
        <div className="mt-3 rounded-xl border border-due-200 bg-due-50 px-3 py-2 text-sm text-due-900">
          <span className="font-medium">Nothing has been deleted.</span> You can open every screen, print and export at any
          time.{status === 'grace' ? ' New entries keep working through the grace period.' : ' Adding new entries resumes as soon as the payment is confirmed.'}
        </div>
      )}

      <div className="mt-4 grid gap-2 sm:flex">
        <Button onClick={onPay} className="w-full sm:w-auto">I have paid: tell you the reference</Button>
        <Link to="/plan"
          className="inline-flex w-full items-center justify-center rounded-lg px-3.5 py-2 text-sm font-medium text-brand-700 ring-1 ring-brand-200 hover:bg-brand-50 sm:w-auto">
          {status === 'trialing' ? 'Choose your plan' : 'Change plan'}
        </Link>
      </div>
    </section>
  )
}

/** Our account, then the school's own, clearly apart. */
function PayUs({ b, pending, onPay }: { b: MyBilling; pending: MyBilling['reports']; onPay: () => void }) {
  const p = b.pay_to
  return (
    <section className={CARD}>
      <div className={HEAD}>Where to send the money</div>
      {p.account ? (
        <dl className="mt-3 divide-y divide-slate-100 rounded-xl border border-slate-200">
          {p.business_name && <PayRow k="Pay to" v={p.business_name} />}
          {p.bank_name && <PayRow k="Bank" v={p.bank_name} />}
          {p.title && <PayRow k="Account title" v={p.title} copy />}
          <PayRow k="Account number" v={p.account} mono copy />
          {p.iban && <PayRow k="IBAN" v={p.iban} mono copy />}
        </dl>
      ) : (
        <p className="mt-2 rounded-xl bg-due-50 px-3 py-2 text-sm text-due-900">
          Our bank details have not been published yet. Please contact us{p.support_phone ? ` on ${p.support_phone}` : ''}.
        </p>
      )}
      <p className="mt-3 text-sm text-slate-700">{b.how_to_pay}</p>

      {pending.length > 0 && (
        <p className="mt-2 rounded-xl bg-info-50 px-3 py-2 text-xs text-info-900">
          {pending.length} payment{pending.length === 1 ? '' : 's'} you reported {pending.length === 1 ? 'is' : 'are'} being
          checked. What you owe will not change until {pending.length === 1 ? 'it is' : 'they are'} confirmed.
        </p>
      )}
      <div className="mt-3 grid gap-2 sm:flex sm:items-center">
        <Button onClick={onPay} className="w-full sm:w-auto">I have paid</Button>
        {(p.support_phone || p.support_email) && (
          <span className="text-xs text-slate-500">
            Any question: {[p.support_phone, p.support_email].filter(Boolean).join(' · ')}
          </span>
        )}
      </div>

      <YourAccountBlock />
    </section>
  )
}

function PayRow({ k, v, mono, copy }: { k: string; v: string; mono?: boolean; copy?: boolean }) {
  const [done, setDone] = useState(false)
  // Copied rather than retyped: one wrong digit in an account number sends the
  // school's money to a stranger, and a phone keyboard makes that easy.
  function doCopy() {
    void navigator.clipboard?.writeText(v).then(() => {
      setDone(true); window.setTimeout(() => setDone(false), 1500)
    }).catch(() => undefined)
  }
  return (
    <div className="flex items-center justify-between gap-3 px-3 py-2">
      <div className="min-w-0">
        <dt className="text-xs text-slate-500">{k}</dt>
        <dd className={`break-all text-sm font-medium text-slate-900 ${mono ? 'font-mono tracking-wide' : ''}`}>{v}</dd>
      </div>
      {copy && typeof navigator !== 'undefined' && navigator.clipboard && (
        <button type="button" onClick={doCopy}
          className="shrink-0 rounded-lg px-2.5 py-1 text-xs font-medium text-brand-700 ring-1 ring-brand-200 hover:bg-brand-50">
          {done ? 'Copied' : 'Copy'}
        </button>
      )}
    </div>
  )
}

function Documents({ docs, onPrint }: { docs: MyBillingDocument[]; onPrint: (id: string) => void }) {
  return (
    <section className={CARD}>
      <div className={HEAD}>Your invoices ({docs.length})</div>
      {docs.length === 0 ? (
        <p className="mt-2 text-sm text-slate-500">Nothing has been invoiced yet.</p>
      ) : (
        <>
          <ul className="mt-2 divide-y divide-slate-100 sm:hidden">
            {docs.map((d) => {
              const credit = d.kind === 'credit_note'
              return (
                <li key={d.id} className={`flex items-center justify-between gap-3 py-2.5 ${d.voided ? 'text-slate-400' : ''}`}>
                  <div className="min-w-0">
                    <div className="text-sm font-medium">
                      <span className={d.voided ? 'line-through' : ''}>{d.doc_no}</span>
                      {credit && <span className="ml-1 text-xs text-money-700">credit</span>}
                      {d.voided && <span className="ml-1 text-xs">cancelled</span>}
                    </div>
                    <div className="text-xs text-slate-500">{fmtDate(d.period_start)} to {fmtDate(d.period_end)}</div>
                    {!credit && !d.voided && <div className="text-xs text-slate-500">Paid {formatPkr(d.paid)}</div>}
                  </div>
                  <div className="shrink-0 text-right">
                    <div className="text-sm font-semibold tabular-nums">{credit ? `− ${formatPkr(d.total)}` : formatPkr(d.total)}</div>
                    <button onClick={() => onPrint(d.id)} className={buttonClass({ variant: 'soft', size: 'sm', className: 'mt-1' })}>Print</button>
                  </div>
                </li>
              )
            })}
          </ul>
          <table className="mt-2 hidden w-full text-sm sm:table">
            <thead>
              <tr className="border-b border-slate-200 text-left text-xs uppercase tracking-wide text-slate-500">
                <th className="py-1.5">Number</th><th className="py-1.5">Date</th><th className="py-1.5">Covers</th>
                <th className="py-1.5 text-right">Total</th><th className="py-1.5 text-right">Paid</th><th className="py-1.5" />
              </tr>
            </thead>
            <tbody className="divide-y divide-slate-100">
              {docs.map((d) => {
                const credit = d.kind === 'credit_note'
                return (
                  <tr key={d.id} className={d.voided ? 'text-slate-400' : ''}>
                    <td className="py-1.5">
                      <span className={d.voided ? 'line-through' : 'font-medium'}>{d.doc_no}</span>
                      {credit && <span className="ml-1 text-xs text-money-700">credit</span>}
                      {d.voided && <span className="ml-1 text-xs">cancelled</span>}
                    </td>
                    <td className="py-1.5">{fmtDate(d.issued_on)}</td>
                    <td className="py-1.5 text-slate-600">{fmtDate(d.period_start)} to {fmtDate(d.period_end)}</td>
                    <td className="py-1.5 text-right tabular-nums">{credit ? `− ${formatPkr(d.total)}` : formatPkr(d.total)}</td>
                    <td className="py-1.5 text-right tabular-nums text-slate-500">{credit || d.voided ? '-' : formatPkr(d.paid)}</td>
                    <td className="py-1.5 text-right"><button onClick={() => onPrint(d.id)} className={buttonClass({ variant: 'soft', size: 'sm' })}>Print</button></td>
                  </tr>
                )
              })}
            </tbody>
          </table>
        </>
      )}
    </section>
  )
}

function Reports({ reports }: { reports: MyBilling['reports'] }) {
  if (reports.length === 0) return null
  return (
    <section className={CARD}>
      <div className={HEAD}>Payments you have reported</div>
      <ul className="mt-2 divide-y divide-slate-100">
        {reports.map((r) => (
          <li key={r.id} className="flex flex-col gap-1 py-2.5 text-sm sm:flex-row sm:items-start sm:justify-between">
            <div>
              <span className="font-semibold tabular-nums">{formatPkr(r.amount)}</span>{' '}
              <span className="text-slate-500">
                {r.method} on {fmtDate(r.paid_on)}
                {r.reference && <> · ref <span className="font-mono">{r.reference}</span></>}
              </span>
              <div className="text-xs text-slate-400">Reported {fmtDateTime(r.claimed_at)}</div>
            </div>
            <div className="text-xs sm:max-w-xs sm:text-right">
              {r.status === 'pending' && <span className="rounded-full bg-info-50 px-2 py-0.5 text-info-800 ring-1 ring-info-100">Being checked</span>}
              {r.status === 'confirmed' && (
                <span className="rounded-full bg-money-50 px-2 py-0.5 text-money-800 ring-1 ring-money-100">
                  Received{r.decided_at ? ` ${fmtDate(r.decided_at)}` : ''}
                </span>
              )}
              {r.status === 'rejected' && (
                <div className="text-danger-800">
                  <span className="rounded-full bg-danger-50 px-2 py-0.5 font-medium ring-1 ring-danger-100">Not found</span>
                  {/* The reason, verbatim: a school that cannot see why phones. */}
                  {r.decision_note && <div className="mt-1">{r.decision_note}</div>}
                </div>
              )}
            </div>
          </li>
        ))}
      </ul>
    </section>
  )
}

function PrintDialog({ invoiceId, onClose }: { invoiceId: string; onClose: () => void }) {
  const q = useQuery({ queryKey: ['myPlatformInvoice', invoiceId], queryFn: () => myPlatformInvoice(invoiceId) })
  return (
    <div className="fixed inset-0 z-50 overflow-y-auto bg-slate-900/50 p-2 sm:p-4">
      <div className="mx-auto max-w-3xl rounded-2xl bg-white p-3 shadow-pop">
        <div className="flex items-center justify-between gap-2 print:hidden">
          <Button size="sm" onClick={() => window.print()}>Print</Button>
          <button onClick={onClose} className={buttonClass({ variant: 'soft', tone: 'neutral', size: 'sm' })}>Close</button>
        </div>
        {q.isLoading && <p className="p-4 text-sm text-slate-500">Loading…</p>}
        {q.error && <p className="p-4 text-sm text-danger-700">{(q.error as Error).message}</p>}
        {q.data && <InvoiceDoc d={q.data} />}
      </div>
    </div>
  )
}

function ReportDialog({ suggested, discount, pending, onClose }: {
  suggested: number | null; discount: MyDiscount | null; pending: MyBilling['reports']; onClose: () => void
}) {
  const qc = useQueryClient()
  const [amount, setAmount] = useState(suggested ? String(suggested) : '')
  const [touched, setTouched] = useState(false)
  const nextq = useQuery({ queryKey: ['myNextPayment'], queryFn: myNextPayment })
  const previewCode = discount?.code ?? null
  const previewPlan = nextq.data?.plan_code
  const previewTerm = nextq.data?.term_months
  const pv = useQuery({
    queryKey: ['invoicePreview', previewPlan, previewTerm, previewCode],
    queryFn: async () => previewCode && previewPlan && previewTerm ? await previewDiscount(previewCode, previewPlan, previewTerm) : null,
    enabled: !!previewCode && !!previewPlan && !!previewTerm,
    staleTime: 60_000,
  })
  const chosen = (nextq.data?.terms ?? []).find((t) => t.months === previewTerm)
  const base = pv.data?.ok ? Number(pv.data.list_amount ?? 0) : Number(chosen?.amount ?? nextq.data?.next_charge_amount ?? 0)
  const off = pv.data?.ok ? Number(pv.data.discount_amount ?? 0) : 0
  const computed = Math.max(base - off, 0)
  // In a trial nothing is invoiced yet, so the box would be empty: drop the
  // upcoming total in, until the school types its own figure.
  useEffect(() => {
    if (touched || amount || suggested) return
    if (computed > 0) setAmount(String(computed))
  }, [computed, touched, amount, suggested])
  const [paidOn, setPaidOn] = useState(today())
  const [method, setMethod] = useState('bank')
  const [reference, setReference] = useState('')
  const [fromBank, setFromBank] = useState('')
  const [note, setNote] = useState('')
  const [err, setErr] = useState<string | null>(null)
  const [done, setDone] = useState<string | null>(null)

  const n = Number(amount)
  const amountProblem = amount.trim() === '' ? 'Enter the amount you sent.'
    : !Number.isFinite(n) || n <= 0 ? 'The amount has to be more than zero.'
      : n > 10_000_000 ? 'That is more than any invoice. Check the amount.'
        : null
  const dateProblem = !paidOn ? 'Enter the date you sent it.' : paidOn > today() ? 'That date is in the future.' : null
  // The same amount already waiting: the commonest duplicate is the principal
  // and the owner each reporting the one transfer.
  const twin = pending.find((r) => Math.abs(Number(r.amount) - n) < 0.5)

  const send = useMutation({
    mutationFn: () => reportSubscriptionPayment({
      amount: n, paidOn, method,
      reference: reference.trim() || null, fromBank: fromBank.trim() || null, note: note.trim() || null,
    }),
    onSuccess: (r) => { setErr(null); setDone(r.message); void qc.invalidateQueries({ queryKey: ['myBilling'] }) },
    onError: (e) => setErr((e as Error).message),
  })

  const shell = 'fixed inset-0 z-50 flex items-start justify-center overflow-y-auto bg-slate-900/50 p-3 sm:items-center sm:p-4'
  if (done) {
    return (
      <div className={shell} role="dialog" aria-modal="true" aria-label="Payment reported">
        <div className="w-full max-w-md rounded-2xl bg-white p-5 shadow-pop">
          <h3 className="text-base font-semibold text-slate-900">Thank you</h3>
          <p className="mt-2 text-sm text-slate-700">{done}</p>
          <Button className="mt-4 w-full" onClick={onClose}>Done</Button>
        </div>
      </div>
    )
  }

  return (
    <div className={shell} role="dialog" aria-modal="true" aria-label="Tell us about your transfer">
      <div className="w-full max-w-md rounded-2xl bg-white p-5 shadow-pop">
        <h3 className="text-base font-semibold text-slate-900">Tell us about your transfer</h3>
        <p className="mt-1 text-xs text-slate-500">
          This does not take a payment and does not change what you owe. It tells us what to look for on our bank
          statement, so we can confirm it without phoning you.
        </p>

        <PaymentContextStrip suggested={suggested} discount={discount} />

        {err && <p className="mt-3 rounded-xl bg-danger-50 px-3 py-2 text-sm text-danger-800">{err}</p>}

        <div className="mt-3 space-y-3">
          <label className="block">
            <span className="text-xs font-medium text-slate-600">How much you sent (Rs)</span>
            <input type="number" inputMode="decimal" step="1" min="1" className={`mt-1 ${inputClass}`} value={amount}
              onChange={(e) => { setTouched(true); setAmount(e.target.value) }} />
            {touched && amountProblem && <span className="mt-1 block text-xs text-danger-700">{amountProblem}</span>}
          </label>
          {twin && !amountProblem && (
            <p className="rounded-xl bg-due-50 px-3 py-2 text-xs text-due-900">
              A payment of {formatPkr(Number(twin.amount))} on {fmtDate(twin.paid_on)} is already being checked. Only send
              this if it is a second, separate transfer.
            </p>
          )}
          <div className="grid grid-cols-2 gap-3">
            <label className="block">
              <span className="text-xs font-medium text-slate-600">On what date</span>
              <input type="date" max={today()} className={`mt-1 ${inputClass}`} value={paidOn} onChange={(e) => setPaidOn(e.target.value)} />
            </label>
            <label className="block">
              <span className="text-xs font-medium text-slate-600">How</span>
              <select className={`mt-1 ${inputClass}`} value={method} onChange={(e) => setMethod(e.target.value)}>
                <option value="bank">Bank transfer</option>
                <option value="online">Online or app</option>
                <option value="cheque">Cheque</option>
                <option value="cash">Cash</option>
                <option value="other">Other</option>
              </select>
            </label>
          </div>
          {dateProblem && <p className="text-xs text-danger-700">{dateProblem}</p>}
          <label className="block">
            <span className="text-xs font-medium text-slate-600">Transaction reference</span>
            <input className={`mt-1 ${inputClass}`} value={reference} onChange={(e) => setReference(e.target.value)}
              placeholder="From your bank slip or app receipt" />
            <span className="mt-1 block text-xs text-slate-500">This is how we find it on our statement. Without it we may not be able to match your transfer.</span>
          </label>
          <label className="block">
            <span className="text-xs font-medium text-slate-600">Which bank or app you sent it from (optional)</span>
            <input className={`mt-1 ${inputClass}`} value={fromBank} onChange={(e) => setFromBank(e.target.value)} />
          </label>
          <label className="block">
            <span className="text-xs font-medium text-slate-600">Anything else (optional)</span>
            <input className={`mt-1 ${inputClass}`} value={note} onChange={(e) => setNote(e.target.value)}
              placeholder="e.g. we deducted 8% withholding tax, CPR to follow" />
          </label>
        </div>

        <div className="mt-4 grid grid-cols-2 gap-2">
          <Button onClick={() => { setTouched(true); if (!amountProblem && !dateProblem) send.mutate() }}
            disabled={send.isPending}>
            {send.isPending ? 'Sending…' : 'Send'}
          </Button>
          <Button variant="soft" tone="neutral" onClick={onClose}>Cancel</Button>
        </div>
      </div>
    </div>
  )
}

/**
 * The discount code box. The input is full width, and on a phone the buttons
 * sit under it rather than squeezing it to a few characters.
 *
 * PREVIEW BEFORE APPLY: a code that will be refused says so here, with the
 * same sentence we see, rather than after it has been applied.
 */
function ApplyCodePanel({ current }: { current: MyDiscount | null }) {
  const qc = useQueryClient()
  const nextq = useQuery({ queryKey: ['myNextPayment'], queryFn: myNextPayment })
  const [code, setCode] = useState('')
  const [preview, setPreview] = useState<DiscountPreview | null>(null)
  const [busy, setBusy] = useState(false)
  const [err, setErr] = useState<string | null>(null)
  const [msg, setMsg] = useState<string | null>(null)
  const [showRemove, setShowRemove] = useState(false)
  const plan = nextq.data?.plan_code
  const term = nextq.data?.term_months

  const refresh = () => {
    for (const k of ['myDiscount', 'myNextPayment', 'myBilling', 'licence', 'invoicePreview']) {
      void qc.invalidateQueries({ queryKey: [k] })
    }
  }
  async function check() {
    const c = code.trim().toUpperCase()
    if (!c || !plan || !term) return
    setBusy(true); setErr(null); setMsg(null)
    try { setPreview(await previewDiscount(c, plan, term)) } catch (e) { setErr((e as Error).message) }
    setBusy(false)
  }
  async function apply() {
    const c = code.trim().toUpperCase()
    if (!c) return
    setBusy(true); setErr(null); setMsg(null)
    try {
      const r = await applyDiscount(c)
      setMsg(`${r.summary}. ${r.what_next}`)
      setPreview(null); setCode('')
      refresh()
    } catch (e) { setErr((e as Error).message) }
    setBusy(false)
  }
  async function remove() {
    setBusy(true); setErr(null); setMsg(null)
    try { await removeMyDiscount(); setMsg('Removed.'); refresh() } catch (e) { setErr((e as Error).message) }
    setBusy(false); setShowRemove(false)
  }

  return (
    <section className={CARD}>
      <div className={HEAD}>Discount code</div>
      {current ? (
        <div className="mt-2 flex flex-wrap items-center justify-between gap-2 rounded-xl bg-money-50 px-3 py-2 text-sm text-money-900 ring-1 ring-money-100">
          <span>
            <span className="font-semibold">{current.code}</span> is on: {current.summary}.
            <span className="block text-xs">
              {current.duration === 'once' ? 'It applies once, to the next invoice.'
                : current.duration === 'forever' ? 'It applies to every invoice from now on.'
                  : current.duration === 'months' ? 'It applies for the months your code covers.'
                    : current.duration === 'until' ? `It applies until ${current.ends_on ? fmtDate(current.ends_on) : 'it expires'}.` : ''}
            </span>
          </span>
          {!showRemove ? (
            <button className={buttonClass({ variant: 'soft', tone: 'neutral', size: 'sm' })} onClick={() => setShowRemove(true)}>Remove</button>
          ) : (
            <span className="flex gap-2">
              <Button size="sm" variant="soft" tone="neutral" onClick={() => setShowRemove(false)} disabled={busy}>Keep</Button>
              <Button size="sm" tone="danger" onClick={() => void remove()} disabled={busy}>Remove for good</Button>
            </span>
          )}
        </div>
      ) : (
        <p className="mt-1 text-sm text-slate-600">If we have sent you a code, enter it here. The price boxes above update the moment it lands.</p>
      )}

      <div className="mt-3 flex flex-col gap-2 sm:flex-row">
        <input value={code}
          onChange={(e) => { setCode(e.target.value.toUpperCase()); setPreview(null); setErr(null); setMsg(null) }}
          onKeyDown={(e) => { if (e.key === 'Enter') { e.preventDefault(); void check() } }}
          placeholder={current ? 'A different code' : 'Type the code you were given'}
          autoCapitalize="characters" spellCheck={false} aria-label="Discount code"
          className={`${inputClass} uppercase tracking-wide sm:flex-1`} />
        <div className="grid grid-cols-2 gap-2 sm:flex">
          <Button variant="soft" tone="neutral" onClick={() => void check()} disabled={!code.trim() || busy || !plan || !term}
            className={preview?.ok ? '' : 'col-span-2'}>
            {busy ? 'Checking…' : 'Check'}
          </Button>
          {preview?.ok && <Button onClick={() => void apply()} disabled={busy}>Apply</Button>}
        </div>
      </div>
      {(!plan || !term) && code.trim() && (
        <p className="mt-2 text-xs text-slate-500">Choose your plan first, so the code can be checked against it.</p>
      )}
      {preview && !preview.ok && <p className="mt-2 rounded-xl bg-due-50 px-3 py-1.5 text-xs text-due-900">{preview.reason}</p>}
      {preview?.ok && (
        <p className="mt-2 rounded-xl bg-money-50 px-3 py-1.5 text-xs text-money-800">
          {preview.summary}. New total for this cycle: <span className="font-semibold">{formatPkr(preview.amount ?? 0)}</span>{' '}
          (was {formatPkr(preview.list_amount ?? 0)}).
        </p>
      )}
      {msg && <p className="mt-2 rounded-xl bg-brand-50 px-3 py-1.5 text-xs text-brand-900">{msg}</p>}
      {err && <p className="mt-2 rounded-xl bg-danger-50 px-3 py-1.5 text-xs text-danger-800">{err}</p>}
    </section>
  )
}

/** What the transfer is for, on the one screen where an amount is required. */
function PaymentContextStrip({ suggested, discount }: { suggested: number | null; discount: MyDiscount | null }) {
  const nextq = useQuery({ queryKey: ['myNextPayment'], queryFn: myNextPayment })
  const n = nextq.data
  const plan = n?.plan_code
  const term = n?.term_months
  const code = discount?.code ?? null
  const pv = useQuery({
    queryKey: ['invoicePreview', plan, term, code],
    queryFn: async () => code && plan && term ? await previewDiscount(code, plan, term) : null,
    enabled: !!code && !!plan && !!term,
    staleTime: 60_000,
  })
  const chosenTerm = (n?.terms ?? []).find((t) => t.months === term)
  const base = pv.data?.ok ? Number(pv.data.list_amount ?? 0) : Number(chosenTerm?.amount ?? n?.next_charge_amount ?? 0)
  const off = pv.data?.ok ? Number(pv.data.discount_amount ?? 0) : 0
  const total = suggested && suggested > 0 ? suggested : Math.max(base - off, 0)
  if (!n?.has_subscription && !suggested) return null

  return (
    <div className="mt-3 rounded-xl border border-slate-200 bg-slate-50 px-3 py-2 text-xs">
      <div className="font-semibold text-slate-700">{suggested && suggested > 0 ? 'What you owe right now' : 'What you are about to pay for'}</div>
      <dl className="mt-1 space-y-0.5 text-slate-700">
        {!(suggested && suggested > 0) && n?.plan_name && (
          <div className="flex justify-between gap-3"><dt>{n.plan_name}</dt><dd className="tabular-nums">{formatPkr(base)}</dd></div>
        )}
        {!(suggested && suggested > 0) && off > 0 && (
          <div className="flex justify-between gap-3 text-money-800"><dt>Discount ({discount?.code})</dt><dd className="tabular-nums">- {formatPkr(off)}</dd></div>
        )}
        <div className="flex justify-between gap-3 border-t border-slate-200 pt-1 font-semibold">
          <dt>Total to send</dt><dd className="tabular-nums">{formatPkr(total)}</dd>
        </div>
      </dl>
    </div>
  )
}

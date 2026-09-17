import { useEffect, useState } from 'react'
import { Link } from 'react-router-dom'
import { today } from '@/lib/dates'
import { useMutation, useQueries, useQuery, useQueryClient } from '@tanstack/react-query'
import { myBilling, myNextPayment, myPlatformInvoice, reportSubscriptionPayment } from '@/lib/db'
import type { MyBillingDocument } from '@/lib/db'
import { InvoiceDoc } from '@/components/InvoiceDoc'
import { formatPkr } from '@/lib/licence'
import {
  applyDiscount, myDiscount, previewDiscount, removeMyDiscount,
  termSentence, TERM_LABEL,
  type DiscountPreview, type MyDiscount,
} from '@/lib/plans'
import { fmtDate, fmtDateTime } from '@/lib/format'
import { NextPaymentPanel } from './NextPayment'
import { RoomForPupils } from './RoomForPupils'

const FIELD = 'w-full rounded border border-slate-300 px-2 py-1.5 text-sm'

/**
 * Your subscription. The school's own view of what it owes us.
 *
 * Every element of this page exists to remove one phone call:
 *
 *   the balance          "how much do we owe you?"
 *   the document list    "can you send us the invoice again?"
 *   Print                "our accountant needs it with your NTN on it"
 *   the bank block       "which account do we transfer to?"
 *   I have paid          "we transferred it, did you get it?"
 *   the reports list     "you said it was rejected, why?"
 *
 * OWNER AND PRINCIPAL ONLY, enforced in the database. Not the accountant: this
 * is a bill between two businesses, and the person who collects the school's own
 * fees has no reason to see what the school pays its software vendor.
 *
 * The one thing this screen must never do is look like it took a payment. The
 * form creates a REPORT the vendor checks against a bank statement, and it says
 * so twice: before the button and after it. A form that looks like it settled
 * the bill and did not is worse than no form at all.
 */
export function Subscription() {
  const q = useQuery({ queryKey: ['myBilling'], queryFn: myBilling })
  // Null when the school is on nothing, which is the ordinary case: the panel
  // below simply does not render that line. A failure is treated the same way
  // rather than shown as an error, because a discount that cannot be read is
  // not a reason to break the page that says when the licence expires.
  const discount = useQuery({
    queryKey: ['myDiscount'], queryFn: myDiscount, retry: false,
  })
  const [printing, setPrinting] = useState<string | null>(null)
  const [reporting, setReporting] = useState(false)

  if (q.isLoading) return <p className="text-sm text-slate-500">Loading…</p>
  if (q.error) {
    return (
      <div className="rounded border border-red-200 bg-red-50 px-3 py-2 text-sm text-red-700">
        {(q.error as Error).message}
      </div>
    )
  }
  // Not `q.data!`. A read that succeeds and returns nothing is a real state,
  // not an impossible one, and the exclamation mark turned it into a crash on
  // the screen a school opens to decide whether to pay us.
  const b = q.data
  if (!b || !b.ok) {
    return <p className="text-sm text-slate-500">No subscription is set up for this school yet.</p>
  }

  const lic = b.licence as Record<string, unknown>
  const status = String(lic.status ?? '')
  const daysLeft = lic.days_left === null || lic.days_left === undefined
    ? null : Number(lic.days_left)
  const owed = Number(b.balance.outstanding || 0)
  const pending = b.reports.filter((r) => r.status === 'pending')

  return (
    <div className="space-y-4">
      <div>
        <h1 className="text-base font-semibold text-slate-800">Your subscription</h1>
        <p className="text-sm text-slate-500">
          What you pay for this software, and how to pay it. Your own fee collection is
          under Fees. This page is only about our invoice to you.
        </p>
      </div>

      {/* WHEN DOES THIS START COSTING MONEY, AND HOW MUCH. The two questions a
          school asks on day one of a trial, and the two this page could not
          answer: the trial simply ended and the software stopped. */}
      <NextPaymentPanel />

      {/* HOW MANY PUPILS THEY MAY HAVE, and the box for asking for more. The
          error a school sees when Admit is refused names this screen, so this
          panel is the difference between that message being true and being a
          lie. Quiet below 90% of the limit; it opens on a click. */}
      <RoomForPupils />

      {/* THE ITEMISED PREVIEW. This is the answer to "what will I actually
          pay for the year", which the "Next payment" sentence gives as a total
          and never as a breakdown. Without this, a school with a 20% code sees
          the promo tag and the new sentence, and has to trust that the two
          agree on the arithmetic. Recalculates the moment the term switcher
          moves, from the same fn_preview_discount the invoice uses. */}
      <InvoicePreviewPanel discount={discount.data ?? null} />

      {/* THE POST-SIGNUP CODE INPUT. Missing until now: a code handed to a
          school after they signed up had nowhere to go. Refreshes the preview
          above the moment a code lands. */}
      <ApplyCodePanel current={discount.data ?? null} />

      {/* --- where the licence stands ---------------------------------------- */}
      <section className="rounded-lg border border-slate-200 bg-white p-4">
        <div className="flex flex-wrap items-start justify-between gap-4">
          <div>
            <div className="text-xs uppercase tracking-wide text-slate-500">Your plan</div>
            <div className="text-lg font-semibold text-slate-800">
              {String(lic.plan_name ?? lic.plan_code ?? '-')}
            </div>
            <div className="text-sm text-slate-600">
              {status === 'trialing' && 'Free trial'}
              {status === 'active' && 'Active'}
              {status === 'grace' && 'Expired: still working while we wait for payment'}
              {status === 'locked' && 'Expired: new entries are paused'}
              {status === 'cancelled' && 'Cancelled'}
              {lic.expires_on ? ` until ${fmtDate(String(lic.expires_on))}` : ''}
              {daysLeft !== null && (
                daysLeft >= 0 ? ` · ${daysLeft} day(s) left` : ` · ${Math.abs(daysLeft)} day(s) ago`
              )}
            </div>
            {/* HOW OFTEN, BESIDE WHAT. This block could say what a year costs
                and could not say whether this school pays yearly, while the
                panel above it knew: fn_my_licence returned the price for all
                three terms and not term_months. Which is how the same screen
                quoted an annual figure to a school on a monthly term, and is
                the complaint that started migration 0127. */}
            <div className="mt-1 text-sm text-slate-600">
              Paid {termSentence(lic.term_months as number | null | undefined)}
            </div>
            {/* THE LINK THAT MAKES THE SIGNUP FORM HONEST. Its closing sentence
                has always read "you can change the plan or the term any time
                from Settings", and until 0132 no function in the product could
                write either field: this screen showed the plan and nothing
                more. The same screen serves the second step of signup, so there
                is one place a plan is chosen rather than two that can disagree.
                What it is allowed to change depends on the subscription and is
                decided by fn_my_choose_plan, not here. */}
            <Link
              to="/plan"
              className="mt-2 inline-flex items-center gap-1 text-sm font-medium text-brand-700 hover:underline"
            >
              {status === 'trialing' ? 'Choose your plan' : 'Change plan or payment term'}
            </Link>
            {discount.data && (
              <p className="mt-2 rounded-lg bg-money-50 px-3 py-2 text-sm text-money-800 ring-1 ring-money-100">
                <span className="font-medium">{discount.data.code}</span>:{' '}
                {discount.data.summary}.
                {discount.data.total_saved > 0
                  ? ` Saved you ${formatPkr(discount.data.total_saved)} so far.`
                  : ''}
              </p>
            )}
            {/* THE ROLL LINE MOVED OUT of this block, into the room panel
                below. It said "148 students of 150 covered" while the panel an
                inch further down says how many places are left, whether any of
                them were granted rather than bought, and what happens when the
                last one goes. Two statements of the same fact, one of which did
                not know about an allowance, is one statement too many. */}
          </div>
          <div className="text-right">
            <div className="text-xs uppercase tracking-wide text-slate-500">Outstanding</div>
            <div className={`text-2xl font-semibold ${
              owed > 0 ? 'text-amber-800' : 'text-emerald-700'}`}>
              {formatPkr(owed)}
            </div>
            <div className="text-xs text-slate-400">
              Invoiced {formatPkr(b.balance.billed)} · paid {formatPkr(b.balance.paid)}
            </div>
          </div>
        </div>

        {/* Reassurance that is also true, and the reason it belongs here: a
            school reading this screen at the moment it is locked needs to know
            its data is safe before it will believe anything else on the page. */}
        {(status === 'locked' || status === 'grace') && (
          <div className="mt-3 rounded border border-amber-200 bg-amber-50 px-3 py-2 text-sm text-amber-900">
            <span className="font-medium">Nothing has been deleted.</span> You can open every
            screen, print and export at any time, in any state.
            {status === 'grace'
              ? ' New entries keep working through the grace period.'
              : ' Adding new entries resumes as soon as the payment is confirmed.'}
          </div>
        )}
      </section>

      {/* --- how to pay ------------------------------------------------------ */}
      <section className="rounded-lg border border-slate-200 bg-white p-4">
        <div className="text-xs uppercase tracking-wide text-slate-500">How to pay</div>
        <p className="mt-1 text-sm text-slate-700">{b.how_to_pay}</p>
        {b.pay_to.account ? (
          <table className="mt-3 text-sm">
            <tbody>
              {b.pay_to.business_name && <PayRow k="Pay to" v={b.pay_to.business_name} />}
              {b.pay_to.bank_name && <PayRow k="Bank" v={b.pay_to.bank_name} />}
              {b.pay_to.title && <PayRow k="Account title" v={b.pay_to.title} />}
              <PayRow k="Account number" v={b.pay_to.account} mono />
              {b.pay_to.iban && <PayRow k="IBAN" v={b.pay_to.iban} mono />}
            </tbody>
          </table>
        ) : (
          <p className="mt-2 rounded bg-amber-50 px-3 py-2 text-sm text-amber-900">
            Bank details have not been published yet. Please contact us
            {b.pay_to.support_phone ? ` on ${b.pay_to.support_phone}` : ''}.
          </p>
        )}
        <div className="mt-3 flex flex-wrap items-center gap-3">
          <button onClick={() => setReporting(true)}
            className="rounded bg-brand-600 px-3 py-2 text-sm font-medium text-white hover:bg-brand-700">
            I have paid: tell them the reference
          </button>
          {(b.pay_to.support_phone || b.pay_to.support_email) && (
            <span className="text-xs text-slate-500">
              Any question:{' '}
              {[b.pay_to.support_phone, b.pay_to.support_email].filter(Boolean).join(' · ')}
            </span>
          )}
        </div>
        {pending.length > 0 && (
          <p className="mt-2 rounded bg-slate-50 px-3 py-2 text-xs text-slate-600">
            {pending.length} payment{pending.length === 1 ? '' : 's'} you reported
            {pending.length === 1 ? ' is' : ' are'} being checked. The balance above will not
            change until it is confirmed.
          </p>
        )}
      </section>

      {/* --- the documents --------------------------------------------------- */}
      <section className="rounded-lg border border-slate-200 bg-white p-4">
        <div className="text-xs uppercase tracking-wide text-slate-500">
          Your invoices ({b.documents.length})
        </div>
        {b.documents.length === 0 ? (
          <p className="mt-2 text-sm text-slate-500">
            Nothing has been invoiced yet.
          </p>
        ) : (
          <div className="mt-2 overflow-x-auto">
            <table className="w-full text-sm">
              <thead>
                <tr className="border-b border-slate-200 text-left text-xs uppercase tracking-wide text-slate-500">
                  <th className="py-1.5">Number</th>
                  <th className="py-1.5">Date</th>
                  <th className="py-1.5">Covers</th>
                  <th className="py-1.5 text-right">Total</th>
                  <th className="py-1.5 text-right">Paid</th>
                  <th className="py-1.5"></th>
                </tr>
              </thead>
              <tbody className="divide-y divide-slate-100">
                {b.documents.map((d) => <DocRow key={d.id} d={d} onPrint={() => setPrinting(d.id)} />)}
              </tbody>
            </table>
          </div>
        )}
      </section>

      {/* --- what we told them, and what came of it -------------------------- */}
      {b.reports.length > 0 && (
        <section className="rounded-lg border border-slate-200 bg-white p-4">
          <div className="text-xs uppercase tracking-wide text-slate-500">
            Payments you have reported
          </div>
          <div className="mt-2 space-y-2">
            {b.reports.map((r) => (
              <div key={r.id} className="flex flex-wrap items-start justify-between gap-2 border-b border-slate-100 pb-2 text-sm last:border-0">
                <div>
                  <span className="font-medium">{formatPkr(r.amount)}</span>{' '}
                  <span className="text-slate-500">
                    {r.method} on {fmtDate(r.paid_on)}
                    {r.reference && <> · ref <span className="font-mono">{r.reference}</span></>}
                  </span>
                  <div className="text-xs text-slate-400">
                    Reported {fmtDateTime(r.claimed_at)}
                  </div>
                </div>
                <div className="text-right text-xs">
                  {r.status === 'pending' && (
                    <span className="rounded bg-slate-100 px-2 py-0.5 text-slate-600">
                      Being checked
                    </span>
                  )}
                  {r.status === 'confirmed' && (
                    <span className="rounded bg-emerald-50 px-2 py-0.5 text-emerald-800">
                      Received{r.decided_at ? ` ${fmtDate(r.decided_at)}` : ''}
                    </span>
                  )}
                  {r.status === 'rejected' && (
                    <div className="max-w-xs text-red-700">
                      <span className="rounded bg-red-50 px-2 py-0.5 font-medium">Not found</span>
                      {/* The reason, verbatim. A school that cannot see why is a
                          school that phones, and this is the sentence they need. */}
                      {r.decision_note && <div className="mt-0.5">{r.decision_note}</div>}
                    </div>
                  )}
                </div>
              </div>
            ))}
          </div>
        </section>
      )}

      {printing && <PrintDialog invoiceId={printing} onClose={() => setPrinting(null)} />}
      {reporting && (
        <ReportDialog
          suggested={owed > 0 ? owed : null}
          discount={discount.data ?? null}
          onClose={() => setReporting(false)} />
      )}
    </div>
  )
}

function DocRow({ d, onPrint }: { d: MyBillingDocument; onPrint: () => void }) {
  const isCredit = d.kind === 'credit_note'
  return (
    <tr className={d.voided ? 'text-slate-400' : ''}>
      <td className="py-1.5">
        <span className={d.voided ? 'line-through' : 'font-medium'}>{d.doc_no}</span>
        {isCredit && <span className="ml-1 text-xs text-emerald-700">credit</span>}
        {d.voided && <span className="ml-1 text-xs">cancelled</span>}
      </td>
      <td className="py-1.5">{fmtDate(d.issued_on)}</td>
      <td className="py-1.5 text-slate-600">
        {fmtDate(d.period_start)} to {fmtDate(d.period_end)}
      </td>
      <td className="py-1.5 text-right tabular-nums">
        {isCredit ? `− ${formatPkr(d.total)}` : formatPkr(d.total)}
      </td>
      <td className="py-1.5 text-right tabular-nums text-slate-500">
        {isCredit || d.voided ? '-' : formatPkr(d.paid)}
      </td>
      <td className="py-1.5 text-right">
        <button onClick={onPrint} className="text-xs text-brand-700 hover:underline">
          Print
        </button>
      </td>
    </tr>
  )
}

function PayRow({ k, v, mono }: { k: string; v: string; mono?: boolean }) {
  return (
    <tr>
      <td className="pr-4 align-top text-slate-500">{k}</td>
      <td className={mono ? 'font-mono font-medium' : 'font-medium'}>{v}</td>
    </tr>
  )
}

function PrintDialog({ invoiceId, onClose }: { invoiceId: string; onClose: () => void }) {
  const q = useQuery({
    queryKey: ['myPlatformInvoice', invoiceId],
    queryFn: () => myPlatformInvoice(invoiceId),
  })
  return (
    <div className="fixed inset-0 z-50 overflow-y-auto bg-black/40 p-4">
      <div className="mx-auto max-w-3xl rounded-lg bg-white p-3 shadow-lg">
        <div className="flex items-center justify-between gap-2 print:hidden">
          <button onClick={() => window.print()}
            className="rounded bg-brand-600 px-3 py-1.5 text-sm font-medium text-white hover:bg-brand-700">
            Print
          </button>
          <button onClick={onClose} className="text-sm text-slate-500 hover:underline">Close</button>
        </div>
        {q.isLoading && <p className="p-4 text-sm text-slate-500">Loading…</p>}
        {q.error && <p className="p-4 text-sm text-red-600">{(q.error as Error).message}</p>}
        {q.data && <InvoiceDoc d={q.data} />}
      </div>
    </div>
  )
}

function ReportDialog({ suggested, discount, onClose }: {
  suggested: number | null; discount: MyDiscount | null; onClose: () => void
}) {
  const qc = useQueryClient()
  const [amount, setAmount] = useState(suggested ? String(suggested) : '')
  const [touched, setTouched] = useState(false)
  // If the school opens this in trial (nothing invoiced yet), the amount box
  // is empty and the dialog looked blank. Once the next-payment sentence and
  // the itemised strip render, drop that total into the box so the school does
  // not have to copy it by hand. Overridden the moment they type.
  const nextq = useQuery({ queryKey: ['myNextPayment'], queryFn: myNextPayment })
  const previewCode = discount?.code ?? null
  const previewPlan = nextq.data?.plan_code
  const previewTerm = nextq.data?.term_months
  const pv = useQuery({
    queryKey: ['invoicePreview', previewPlan, previewTerm, previewCode],
    queryFn: async () => previewCode && previewPlan && previewTerm
      ? await previewDiscount(previewCode, previewPlan, previewTerm) : null,
    enabled: !!previewCode && !!previewPlan && !!previewTerm,
    staleTime: 60_000,
  })
  const chosen = (nextq.data?.terms ?? []).find((t) => t.months === previewTerm)
  const base = pv.data?.ok
    ? Number(pv.data.list_amount ?? 0)
    : Number(chosen?.amount ?? nextq.data?.next_charge_amount ?? 0)
  const off = pv.data?.ok ? Number(pv.data.discount_amount ?? 0) : 0
  const computed = Math.max(base - off, 0)
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

  const send = useMutation({
    mutationFn: () => reportSubscriptionPayment({
      amount: Number(amount), paidOn, method,
      reference: reference.trim() || null,
      fromBank: fromBank.trim() || null,
      note: note.trim() || null,
    }),
    onSuccess: (r) => {
      setErr(null); setDone(r.message)
      void qc.invalidateQueries({ queryKey: ['myBilling'] })
    },
    onError: (e) => setErr((e as Error).message),
  })

  if (done) {
    return (
      <div className="fixed inset-0 z-50 flex items-start justify-center overflow-y-auto bg-black/40 p-4 sm:items-center">
        <div className="w-full max-w-md rounded-lg bg-white p-4 shadow-lg">
          <h3 className="text-sm font-semibold text-emerald-800">Thank you</h3>
          <p className="mt-2 text-sm text-slate-700">{done}</p>
          <button onClick={onClose}
            className="mt-4 w-full rounded bg-brand-600 px-3 py-2 text-sm font-medium text-white hover:bg-brand-700">
            Done
          </button>
        </div>
      </div>
    )
  }

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center overflow-y-auto bg-black/40 p-4">
      <div className="w-full max-w-md rounded-lg bg-white p-4 shadow-lg">
        <h3 className="text-sm font-semibold text-slate-800">Tell us about your transfer</h3>
        {/* Said BEFORE the form, not after. This is not a payment screen and it
            must not be mistaken for one. */}
        <p className="mt-1 text-xs text-slate-500">
          This does not take a payment and does not change your balance. It tells us what
          to look for on our bank statement, so we can confirm it without phoning you.
        </p>

        <PaymentContextStrip suggested={suggested} discount={discount} />

        {err && <p className="mt-3 rounded bg-red-50 px-3 py-2 text-sm text-red-700">{err}</p>}

        <div className="mt-3 space-y-3">
          <label className="block">
            <span className="text-xs font-medium text-slate-600">How much you transferred</span>
            <input type="number" step="0.01" min="1" className={FIELD} value={amount}
              onChange={(e) => { setTouched(true); setAmount(e.target.value) }} />
          </label>
          <div className="grid gap-3 sm:grid-cols-2">
            <label className="block">
              <span className="text-xs font-medium text-slate-600">On what date</span>
              <input type="date" max={today()}
                className={FIELD} value={paidOn} onChange={(e) => setPaidOn(e.target.value)} />
            </label>
            <label className="block">
              <span className="text-xs font-medium text-slate-600">How</span>
              <select className={FIELD} value={method} onChange={(e) => setMethod(e.target.value)}>
                <option value="bank">Bank transfer</option>
                <option value="online">Online / app</option>
                <option value="cheque">Cheque</option>
                <option value="cash">Cash</option>
                <option value="other">Other</option>
              </select>
            </label>
          </div>
          <label className="block">
            <span className="text-xs font-medium text-slate-600">
              Transaction reference
            </span>
            <input className={FIELD} value={reference}
              onChange={(e) => setReference(e.target.value)}
              placeholder="From your bank slip or app receipt" />
            <span className="mt-0.5 block text-xs text-slate-400">
              This is how we find it on our statement. Without it we may not be able to
              match your transfer.
            </span>
          </label>
          <label className="block">
            <span className="text-xs font-medium text-slate-600">
              Which bank you sent it from (optional)
            </span>
            <input className={FIELD} value={fromBank}
              onChange={(e) => setFromBank(e.target.value)} />
          </label>
          <label className="block">
            <span className="text-xs font-medium text-slate-600">Anything else (optional)</span>
            <input className={FIELD} value={note} onChange={(e) => setNote(e.target.value)}
              placeholder="e.g. we deducted 8% withholding tax, CPR to follow" />
          </label>
        </div>

        <div className="mt-4 flex gap-2">
          <button onClick={() => send.mutate()} disabled={send.isPending || !amount}
            className="flex-1 rounded bg-brand-600 px-3 py-2 text-sm font-medium text-white hover:bg-brand-700 disabled:opacity-60">
            {send.isPending ? 'Sending…' : 'Send'}
          </button>
          <button onClick={onClose}
            className="flex-1 rounded border border-slate-300 px-3 py-2 text-sm hover:bg-slate-50">
            Cancel
          </button>
        </div>
      </div>
    </div>
  )
}

// -----------------------------------------------------------------------------
// The itemised preview: what the next invoice actually says.
//
// WHY THIS EXISTS. NextPaymentPanel above says "Rs 9,600 for a year" as one
// number. A school with a promo code sees the tag "SPRING24: 20% off" beside
// it and has no way to check the arithmetic; if the office switches the term
// from Monthly to Yearly, the number changes and the tag does not, and there
// is no line on the page that says how the two combined. Every complaint that
// begins "your invoice says X but the promo said Y" ends here, because this
// is the panel that would have prevented it.
//
// EVERY FIGURE COMES FROM fn_preview_discount, not from JavaScript. A browser
// reimplementation of the arithmetic is right until somebody adds a duration
// or changes fn__discount_off; then the panel that decides whether a school
// buys is quoting a figure the first invoice contradicts. The rows for the
// three cycles are three separate previews, cached per (code, plan, months)
// by react-query so switching the term is a paint, not a round trip.
//
// USABLE WITH NO CODE APPLIED. The rows still show the list price for each
// cycle, because the question "what does yearly cost" is worth answering
// whether or not there is a discount.
// -----------------------------------------------------------------------------
function InvoicePreviewPanel({ discount }: { discount: MyDiscount | null }) {
  const nextq = useQuery({ queryKey: ['myNextPayment'], queryFn: myNextPayment })
  const n = nextq.data

  const planCode = n?.plan_code ?? null
  const activeTerm = n?.term_months ?? null
  const terms = n?.terms ?? []
  const code = discount?.code ?? null

  // A preview per cycle. useQueries lets react-query cache each (code,plan,m)
  // independently, so switching the highlighted term is instant on the second
  // visit and the discount tag never sits over a stale number.
  const previews = useQueries({
    queries: terms.map((t) => ({
      queryKey: ['invoicePreview', planCode, t.months, code],
      queryFn: async () =>
        code && planCode
          ? await previewDiscount(code, planCode, t.months)
          : null,
      enabled: !!planCode,
      staleTime: 60_000,
    })),
  })

  if (!nextq.data?.has_subscription) return null
  if (nextq.isLoading) return null

  return (
    <section className="rounded-lg border border-slate-200 bg-white p-4">
      <div className="flex flex-wrap items-baseline justify-between gap-3">
        <div>
          <div className="text-xs font-semibold uppercase tracking-wide text-slate-500">
            Your next invoice, itemised
          </div>
          <p className="mt-1 text-sm text-slate-600">
            The three cycles side by side. The highlighted row is what you are on now.
          </p>
        </div>
        {n?.next_charge_on && (
          <div className="text-right text-xs text-slate-500">
            Raised on {fmtDate(n.next_charge_on)}
          </div>
        )}
      </div>

      <div className="mt-3 overflow-x-auto">
        <table className="w-full min-w-[520px] text-sm">
          <thead>
            <tr className="border-b border-slate-200 text-left text-xs uppercase tracking-wide text-slate-500">
              <th className="py-1.5">Cycle</th>
              <th className="py-1.5 text-right">Base</th>
              <th className="py-1.5 text-right">
                Discount{discount ? ` (${discount.code})` : ''}
              </th>
              <th className="py-1.5 text-right">Total</th>
            </tr>
          </thead>
          <tbody className="divide-y divide-slate-100">
            {terms.map((t, i) => {
              const pv = previews[i]?.data ?? null
              const err = previews[i]?.error as Error | null
              // Backend authoritative when a code is applied AND the preview
              // resolved OK. Otherwise the base price stands and the discount
              // column is blank. A refusal (pv.ok===false, e.g. code expired
              // this cycle) is reported in place; the invoice still costs the
              // list price so the row does not disappear.
              const showDiscount = !!discount && pv?.ok === true
              const base = pv?.ok ? Number(pv.list_amount ?? t.amount) : t.amount
              const off = showDiscount ? Number(pv?.discount_amount ?? 0) : 0
              // FLOORED AT ZERO. A flat Rs 5,000 code on a Rs 1,600 monthly
              // invoice cannot pay the school back Rs 3,400. The backend also
              // clamps but this panel is drawn without waiting for it.
              const total = Math.max(base - off, 0)
              const on = t.months === activeTerm
              return (
                <tr key={t.months} className={on ? 'bg-brand-50/60' : ''}>
                  <td className="py-2 font-medium text-slate-800">
                    {TERM_LABEL[t.months] ?? `${t.months} months`}
                    {on && <span className="ml-1.5 text-xs font-normal text-brand-700">· on now</span>}
                  </td>
                  <td className="py-2 text-right tabular-nums text-slate-900">
                    {formatPkr(base)}
                  </td>
                  <td className="py-2 text-right tabular-nums text-money-700">
                    {showDiscount && off > 0 ? '- ' + formatPkr(off) : '-'}
                    {discount && pv?.ok === false && (
                      <span className="ml-2 text-xs text-slate-500">{pv.reason}</span>
                    )}
                    {err && <span className="ml-2 text-xs text-slate-400">(checking)</span>}
                  </td>
                  <td className="py-2 text-right font-semibold tabular-nums text-slate-900">
                    {formatPkr(total)}
                  </td>
                </tr>
              )
            })}
          </tbody>
        </table>
      </div>

      {discount?.kind === 'trial_days' && (
        <p className="mt-2 rounded bg-money-50 px-3 py-1.5 text-xs text-money-800">
          {discount.summary}. This extends your trial rather than reducing an invoice.
        </p>
      )}
      <p className="mt-2 text-xs text-slate-500">
        {discount?.duration === 'once'
          ? 'This discount applies once, to the next invoice.'
          : discount?.duration === 'forever'
            ? 'This discount applies on every invoice from now on.'
            : discount?.duration === 'months'
              ? 'This discount applies for the number of months your code covers.'
              : discount?.duration === 'until'
                ? 'This discount applies on every invoice until it expires.'
                : 'Prices come from the same list your invoice will use.'}
      </p>
    </section>
  )
}

// -----------------------------------------------------------------------------
// The post-signup code input.
//
// A code handed to a school AFTER they signed up had nowhere to go: ChoosePlan
// takes one but it is the second step of signup, not a setting. Without this
// the office has to phone us to type the code into the database by hand, which
// defeats the point of having codes at all.
//
// PREVIEW BEFORE APPLY. A code that will be refused should say so on this
// screen rather than by throwing a red banner after applying. fn_preview_discount
// checks: existence, live window, plan match, term match, remaining uses,
// stacking rules; and returns the same sentence the operator sees.
// -----------------------------------------------------------------------------
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
    void qc.invalidateQueries({ queryKey: ['myDiscount'] })
    void qc.invalidateQueries({ queryKey: ['myNextPayment'] })
    void qc.invalidateQueries({ queryKey: ['myBilling'] })
    void qc.invalidateQueries({ queryKey: ['licence'] })
    void qc.invalidateQueries({ queryKey: ['invoicePreview'] })
  }

  async function check() {
    const c = code.trim().toUpperCase()
    if (!c || !plan || !term) return
    setBusy(true); setErr(null); setMsg(null)
    try { setPreview(await previewDiscount(c, plan, term)) }
    catch (e) { setErr((e as Error).message) }
    setBusy(false)
  }

  async function apply() {
    const c = code.trim().toUpperCase()
    if (!c) return
    setBusy(true); setErr(null); setMsg(null)
    try {
      const r = await applyDiscount(c)
      setMsg(r.summary + '. ' + r.what_next)
      setPreview(null); setCode('')
      refresh()
    } catch (e) { setErr((e as Error).message) }
    setBusy(false)
  }

  async function remove() {
    setBusy(true); setErr(null); setMsg(null)
    try { await removeMyDiscount(); setMsg('Removed.'); refresh() }
    catch (e) { setErr((e as Error).message) }
    setBusy(false); setShowRemove(false)
  }

  return (
    <section className="rounded-lg border border-slate-200 bg-white p-4">
      <div className="flex flex-wrap items-baseline justify-between gap-3">
        <div>
          <div className="text-xs font-semibold uppercase tracking-wide text-slate-500">
            Discount code
          </div>
          <p className="mt-1 text-sm text-slate-600">
            If we have sent you a code, enter it here. The preview above updates the moment it lands.
          </p>
        </div>
        {current && (
          <div className="text-right text-xs">
            <div className="rounded bg-money-50 px-2 py-1 font-medium text-money-800 ring-1 ring-money-100">
              On now: {current.code}
            </div>
            {!showRemove ? (
              <button className="mt-1 text-xs text-slate-500 hover:underline"
                onClick={() => setShowRemove(true)}>Remove</button>
            ) : (
              <div className="mt-1 flex justify-end gap-2">
                <button className="rounded border border-slate-300 px-2 py-0.5 text-xs hover:bg-slate-50"
                  onClick={() => setShowRemove(false)} disabled={busy}>Keep</button>
                <button className="rounded bg-red-600 px-2 py-0.5 text-xs font-medium text-white hover:bg-red-700"
                  onClick={() => void remove()} disabled={busy}>Remove for good</button>
              </div>
            )}
          </div>
        )}
      </div>

      <div className="mt-3 flex flex-wrap items-center gap-2">
        <input
          value={code}
          onChange={(e) => { setCode(e.target.value.toUpperCase()); setPreview(null); setErr(null); setMsg(null) }}
          onKeyDown={(e) => { if (e.key === 'Enter') { e.preventDefault(); void check() } }}
          placeholder="Type the code you were given"
          autoCapitalize="characters"
          spellCheck={false}
          className="min-w-0 flex-1 rounded border border-slate-300 px-3 py-2 text-sm uppercase tracking-wide"
        />
        <button
          type="button"
          onClick={() => void check()}
          disabled={!code.trim() || busy || !plan || !term}
          className="rounded border border-slate-300 px-3 py-2 text-sm font-medium text-slate-700 hover:bg-slate-50 disabled:opacity-50">
          {busy ? 'Checking…' : 'Check'}
        </button>
        {preview?.ok && (
          <button
            type="button"
            onClick={() => void apply()}
            disabled={busy}
            className="rounded bg-brand-600 px-3 py-2 text-sm font-medium text-white hover:bg-brand-700 disabled:opacity-60">
            Apply
          </button>
        )}
      </div>

      {preview && !preview.ok && (
        <p className="mt-2 rounded bg-amber-50 px-3 py-1.5 text-xs text-amber-900">
          {preview.reason}
        </p>
      )}
      {preview?.ok && (
        <p className="mt-2 rounded bg-money-50 px-3 py-1.5 text-xs text-money-800">
          {preview.summary}. New total for this cycle:{' '}
          <span className="font-semibold">{formatPkr(preview.amount ?? 0)}</span>{' '}
          (was {formatPkr(preview.list_amount ?? 0)}).
        </p>
      )}
      {msg && <p className="mt-2 rounded bg-emerald-50 px-3 py-1.5 text-xs text-emerald-800">{msg}</p>}
      {err && <p className="mt-2 rounded bg-red-50 px-3 py-1.5 text-xs text-red-700">{err}</p>}
    </section>
  )
}


// -----------------------------------------------------------------------------
// The bit that stopped the dialog looking blank.
//
// A school opens "I have paid" during their trial (nothing invoiced yet), sees
// "Outstanding Rs 0" and an empty form, and has no idea what to put in the
// amount box. This strip shows what the upcoming invoice will be for and how
// much: it is the only screen where an amount is genuinely required, so the
// number has to be visible on it.
// -----------------------------------------------------------------------------
function PaymentContextStrip({ suggested, discount }: {
  suggested: number | null; discount: MyDiscount | null
}) {
  const nextq = useQuery({ queryKey: ['myNextPayment'], queryFn: myNextPayment })
  const n = nextq.data
  const plan = n?.plan_code
  const term = n?.term_months
  const code = discount?.code ?? null
  const pv = useQuery({
    queryKey: ['invoicePreview', plan, term, code],
    queryFn: async () => code && plan && term
      ? await previewDiscount(code, plan, term) : null,
    enabled: !!code && !!plan && !!term,
    staleTime: 60_000,
  })

  const chosenTerm = (n?.terms ?? []).find((t) => t.months === term)
  const base = pv.data?.ok
    ? Number(pv.data.list_amount ?? 0)
    : Number(chosenTerm?.amount ?? n?.next_charge_amount ?? 0)
  const off = pv.data?.ok ? Number(pv.data.discount_amount ?? 0) : 0
  const total = suggested && suggested > 0
    ? suggested
    : Math.max(base - off, 0)

  if (!n?.has_subscription && !suggested) return null

  return (
    <div className="mt-3 rounded border border-slate-200 bg-slate-50 px-3 py-2 text-xs">
      <div className="font-semibold text-slate-700">
        {suggested && suggested > 0
          ? 'What you owe right now'
          : 'What you are about to pay for'}
      </div>
      <dl className="mt-1 space-y-0.5 text-slate-700">
        {n?.plan_name && (
          <div className="flex justify-between gap-3">
            <dt>{n.plan_name}</dt>
            <dd className="tabular-nums">{formatPkr(base)}</dd>
          </div>
        )}
        {off > 0 && (
          <div className="flex justify-between gap-3 text-money-800">
            <dt>Discount ({discount?.code})</dt>
            <dd className="tabular-nums">- {formatPkr(off)}</dd>
          </div>
        )}
        <div className="flex justify-between gap-3 border-t border-slate-200 pt-1 font-semibold">
          <dt>Total to send</dt>
          <dd className="tabular-nums">{formatPkr(total)}</dd>
        </div>
      </dl>
      {n?.sentence && (
        <p className="mt-1 text-[11px] text-slate-500">{n.sentence}</p>
      )}
    </div>
  )
}

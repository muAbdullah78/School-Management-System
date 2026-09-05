import { useState } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { myBilling, myPlatformInvoice, reportSubscriptionPayment } from '@/lib/db'
import type { MyBillingDocument } from '@/lib/db'
import { InvoiceDoc } from '@/components/InvoiceDoc'
import { formatPkr } from '@/lib/licence'
import { fmtDate, fmtDateTime } from '@/lib/format'

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
            <div className="mt-1 text-sm text-slate-500">
              {Number(lic.student_count ?? 0).toLocaleString()} students
              {lic.student_limit ? ` of ${Number(lic.student_limit).toLocaleString()} covered` : ''}
            </div>
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

function ReportDialog({ suggested, onClose }: {
  suggested: number | null; onClose: () => void
}) {
  const qc = useQueryClient()
  const [amount, setAmount] = useState(suggested ? String(suggested) : '')
  const [paidOn, setPaidOn] = useState(new Date().toISOString().slice(0, 10))
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

        {err && <p className="mt-3 rounded bg-red-50 px-3 py-2 text-sm text-red-700">{err}</p>}

        <div className="mt-3 space-y-3">
          <label className="block">
            <span className="text-xs font-medium text-slate-600">How much you transferred</span>
            <input type="number" step="0.01" min="1" className={FIELD} value={amount}
              onChange={(e) => setAmount(e.target.value)} />
          </label>
          <div className="grid gap-3 sm:grid-cols-2">
            <label className="block">
              <span className="text-xs font-medium text-slate-600">On what date</span>
              <input type="date" max={new Date().toISOString().slice(0, 10)}
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

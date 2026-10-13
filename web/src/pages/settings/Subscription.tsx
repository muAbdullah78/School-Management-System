import { useState } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { myBilling, myNextPayment, myPlatformInvoice, pkToday, reportSubscriptionPayment } from '@/lib/db'
import type { MyBilling, MyBillingDocument } from '@/lib/db'
import { InvoiceDoc } from '@/components/InvoiceDoc'
import { formatPkr } from '@/lib/licence'
import {
  lockedSentence, myCode, planLine, previewCode, redeemCode, removeMyCode,
  type CodePreview, type MyCode, type RedeemResult, type SubscriptionView,
} from '@/lib/subscription'
import { termSentence } from '@/lib/plans'
import { today } from '@/lib/dates'
import { fmtDate, fmtDateTime } from '@/lib/format'
import { Badge, Button, inputClass, buttonClass, type Tone } from '@/components/ui'
import {
  NextPaymentPanel, YourAccountBlock, LeaveOrStayPanel, useRefreshBilling,
  addDays, dayDiff, termWords,
} from './NextPayment'
import { PupilMeter, RoomForPupils } from './RoomForPupils'

const CARD = 'rounded-2xl border border-slate-200 bg-white p-4 shadow-card'
const HEAD = 'text-xs font-semibold uppercase tracking-wide text-slate-500'

/**
 * Your subscription: the school's own view of what it owes us.
 *
 * ONE DESCRIPTION. Every figure on this screen comes from the subscription
 * view (fn__subscription_view, carried by fn_my_billing as `subscription`):
 * the plan and its price, the status, the date the school locks, the pupils
 * against the limit, the open invoice and the next quote. The banner, the
 * locked screen and the invoice read the same view, so they cannot disagree.
 *
 * THE ORDER IS THE ORDER OF THE QUESTIONS. What are we on and what do we owe,
 * then is anything stopping us (the roll), then what is the next bill and how
 * often, then the code that lowers it, then where to send the money, then the
 * paperwork.
 *
 * PLANS ARE OURS. Since 0155 a school does not change its own plan: it asks,
 * from the roll panel, and we move it from the console. The only choice made
 * here is how often to pay.
 *
 * OWNER AND PRINCIPAL ONLY, enforced in the database.
 *
 * The one thing this screen must never do is look like it took a payment. "I
 * have paid" creates a REPORT we check against our bank statement, and it says
 * so before the button and after it.
 */
export function Subscription() {
  const q = useQuery({ queryKey: ['myBilling'], queryFn: myBilling })
  // The view also arrives with the next payment; it is the fallback for a
  // billing read that does not carry it.
  const next = useQuery({ queryKey: ['myNextPayment'], queryFn: myNextPayment, retry: false })
  // A code that cannot be read is not a reason to break the page.
  const code = useQuery({ queryKey: ['myCode'], queryFn: myCode, retry: false })
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

  const view = b.subscription ?? next.data?.view ?? null
  const reports = b.reports ?? []
  const pending = reports.filter((r) => r.status === 'pending')
  // What to put in the "I have paid" box: what the view says to pay now,
  // credit already taken off. With no view, what is owed on the books.
  const suggested = view
    ? (view.pay_now > 0 ? view.pay_now : null)
    : (Number(b.balance?.outstanding ?? 0) > 0 ? Number(b.balance.outstanding) : null)
  // An Enterprise school with no price agreed has nothing it could have paid,
  // so "I have paid" would be a button for something that cannot have happened.
  const canPay = !(view?.needs_price && view.owed <= 0)

  return (
    <div className="space-y-4">
      {view
        ? <Summary v={view} code={code.data ?? null} phone={b.pay_to?.support_phone ?? null}
            onPay={canPay ? () => setReporting(true) : null} />
        : <PlainSummary b={b} onPay={() => setReporting(true)} />}
      <RoomForPupils />
      {view && <NextPaymentPanel view={view} onPrint={setPrinting} />}
      <CodePanel view={view} current={code.data ?? null} />
      <PayUs b={b} pending={pending} onPay={canPay ? () => setReporting(true) : null} />
      <Reports reports={reports} />
      <Documents docs={b.documents ?? []} onPrint={setPrinting} />
      <Payments payments={b.payments ?? []} />
      <LeaveOrStayPanel />

      {printing && <PrintDialog invoiceId={printing} onClose={() => setPrinting(null)} />}
      {reporting && (
        <ReportDialog suggested={suggested} view={view} pending={pending} onClose={() => setReporting(false)} />
      )}
    </div>
  )
}

const STATUS: Record<string, { word: string; tone: Tone }> = {
  trialing: { word: 'Free trial', tone: 'info' },
  active: { word: 'Active', tone: 'brand' },
  grace: { word: 'Payment overdue', tone: 'due' },
  locked: { word: 'Locked', tone: 'danger' },
  cancelled: { word: 'Cancelled', tone: 'neutral' },
}

/**
 * The status in words, from the view's dates. Exported for its test: the
 * sentence a school reads about whether it can work tomorrow is the one most
 * worth pinning.
 */
export function statusSentence(v: SubscriptionView, on: string = pkToday()): string {
  const ending = v.cancel_at_period_end ? ' You asked to stop then, so nothing further will be invoiced.' : ''
  switch (v.status) {
    case 'trialing': {
      if (!v.trial_ends_on) return `You are on your free trial.${ending}`
      // The trial's last day counts: fourteen days of access read "14 days
      // left" on the day the school signs up.
      const left = dayDiff(on, v.trial_ends_on) + 1
      return left <= 1
        ? `Today is the last day of your free trial.${ending}`
        : `Free trial, ${left} days left. It runs to ${fmtDate(v.trial_ends_on)}.${ending}`
    }
    case 'active':
      return (v.paid_through ? `Active and paid through ${fmtDate(v.paid_through)}.` : 'Active.') + ending
    case 'grace':
      return v.locks_on
        ? `Payment is overdue. The software keeps working until ${fmtDate(addDays(v.locks_on, -1))} and locks on `
          + `${fmtDate(v.locks_on)} unless payment reaches us before then.`
        : 'Payment is overdue. Please pay as soon as you can to keep working.'
    default:
      return lockedSentence(v) ?? 'New entries are paused.'
  }
}

function Summary({ v, code, phone, onPay }: {
  v: SubscriptionView; code: MyCode | null; phone: string | null; onPay: (() => void) | null
}) {
  const st = STATUS[v.status]
  const stopped = v.status === 'locked' || v.status === 'cancelled'
  return (
    <section className={CARD} aria-labelledby="plan-head">
      <div className="flex flex-col gap-4 sm:flex-row sm:items-start sm:justify-between">
        <div className="min-w-0">
          <h2 id="plan-head" className={HEAD}>Your plan</h2>
          <p className="mt-0.5 text-xl font-semibold text-slate-900">{planLine(v)}</p>
          <div className="mt-1 flex flex-wrap items-center gap-2 text-sm text-slate-600">
            {st && <Badge tone={st.tone}>{st.word}</Badge>}
            {v.price.priced && <span>Paid {termSentence(v.term_months)}</span>}
          </div>
          <p className={`mt-2 max-w-prose text-sm ${stopped ? 'text-danger-800' : v.status === 'grace' ? 'text-due-900' : 'text-slate-800'}`}>
            {statusSentence(v)}
          </p>
          {code?.code && (
            <p className="mt-2 inline-block rounded-lg bg-money-50 px-2.5 py-1 text-xs text-money-800 ring-1 ring-money-100">
              Code <span className="font-semibold">{code.code}</span>{code.label ? `: ${code.label}` : ''}
            </p>
          )}
        </div>
        <PayNow v={v} />
      </div>

      {/* Enterprise before its price: the one case where the trial's end is
          also the lock, with no grace, because there is nothing to pay yet. */}
      {v.needs_price && !stopped && (
        <p className="mt-3 rounded-xl border border-info-200 bg-info-50 px-3 py-2 text-sm text-info-900">
          We are agreeing your price with you. Until it is set we cannot invoice you, and the software locks when your
          free trial ends{v.trial_ends_on ? ` on ${fmtDate(v.trial_ends_on)}` : ''} until it is.
          {phone ? ` If we have not called you, call us on ${phone}.` : ' If we have not called you, please call us.'}
        </p>
      )}

      <div className="mt-4 rounded-xl border border-slate-100 p-3">
        <PupilMeter students={v.students} planName={v.plan.name} />
      </div>

      {(stopped || v.status === 'grace') && (
        <div className="mt-3 rounded-xl border border-due-200 bg-due-50 px-3 py-2 text-sm text-due-900">
          <span className="font-medium">Nothing has been deleted.</span> You can open every screen, print and export at any
          time.{v.status === 'grace' ? ' New entries keep working until the lock date.' : ' Adding new entries resumes as soon as the payment is confirmed.'}
        </div>
      )}

      {onPay && (
        <div className="mt-4 grid gap-2 sm:flex">
          <Button onClick={onPay} className="w-full sm:w-auto">I have paid</Button>
        </div>
      )}
    </section>
  )
}

/**
 * The heading and the line under the figure in the top right of the summary.
 *
 * `pay_now` is the next term as soon as it is within thirty days, so a school
 * paid to 31 Oct read "To pay now Rs 1,800" on 10 Oct, for a payment nobody
 * asks for until 1 Nov, and the line under it said "Your next a month from 1
 * Nov". Nothing owed and a period that has not started yet is the NEXT
 * payment, with the day it falls due. Exported for its test.
 */
export function payNowWords(v: SubscriptionView, on: string = pkToday()): { head: string; line: string | null } {
  if (v.owed > 0) return { head: 'To pay now', line: `Owed on your invoices: ${formatPkr(v.owed)}` }
  if (v.pay_now > 0 && v.next) {
    const from = fmtDate(v.next.period_start)
    return v.next.period_start > on
      ? { head: 'Next payment', line: `Due on ${from}, for ${termWords(v.next.months)}. Not invoiced yet.` }
      : { head: 'To pay now', line: `For ${termWords(v.next.months)} from ${from}. Not invoiced yet.` }
  }
  return { head: 'To pay now', line: null }
}

/** What to pay now: owed on invoices, or the next term once it is near, less credit. */
function PayNow({ v }: { v: SubscriptionView }) {
  const pay = v.pay_now
  const words = payNowWords(v)
  return (
    <div className="rounded-xl bg-slate-50 p-3 sm:min-w-[13rem] sm:max-w-[18rem] sm:text-right">
      <div className={HEAD}>{words.head}</div>
      <div className={`text-2xl font-semibold tabular-nums ${pay > 0 ? 'text-due-800' : 'text-slate-900'}`}>
        {pay > 0 ? formatPkr(pay) : 'Nothing'}
      </div>
      {words.line && <div className="text-xs text-slate-500">{words.line}</div>}
      {v.credit > 0 && (
        <div className="text-xs text-money-700">{formatPkr(v.credit)} you paid ahead comes off</div>
      )}
    </div>
  )
}

/**
 * For a database that has not sent the view yet. It says what it can from the
 * books and nothing it would have to guess.
 */
function PlainSummary({ b, onPay }: { b: MyBilling; onPay: () => void }) {
  const lic = (b.licence ?? {}) as Record<string, unknown>
  const owed = Number(b.balance?.outstanding ?? 0)
  const st = STATUS[String(lic.status ?? '')]
  return (
    <section className={CARD} aria-labelledby="plan-head">
      <div className="flex flex-col gap-4 sm:flex-row sm:items-start sm:justify-between">
        <div className="min-w-0">
          <h2 id="plan-head" className={HEAD}>Your plan</h2>
          <p className="mt-0.5 text-xl font-semibold text-slate-900">{String(lic.plan_name ?? lic.plan_code ?? '-')}</p>
          {st && <div className="mt-1"><Badge tone={st.tone}>{st.word}</Badge></div>}
        </div>
        <div className="rounded-xl bg-slate-50 p-3 sm:min-w-[12rem] sm:text-right">
          <div className={HEAD}>You owe us now</div>
          <div className={`text-2xl font-semibold tabular-nums ${owed > 0 ? 'text-due-800' : 'text-slate-900'}`}>
            {owed > 0 ? formatPkr(owed) : 'Nothing'}
          </div>
        </div>
      </div>
      <div className="mt-4 grid gap-2 sm:flex">
        <Button onClick={onPay} className="w-full sm:w-auto">I have paid</Button>
      </div>
    </section>
  )
}

/** Our account, then the school's own, clearly apart. */
function PayUs({ b, pending, onPay }: { b: MyBilling; pending: MyBilling['reports']; onPay: (() => void) | null }) {
  const p = b.pay_to ?? ({} as MyBilling['pay_to'])
  return (
    <section className={CARD} aria-labelledby="pay-head">
      <h2 id="pay-head" className={HEAD}>Where to send the money</h2>
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
        {onPay && <Button onClick={onPay} className="w-full sm:w-auto">I have paid</Button>}
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
        <button type="button" onClick={doCopy} aria-label={`Copy ${k.toLowerCase()}`}
          className="shrink-0 rounded-lg px-2.5 py-1 text-xs font-medium text-brand-700 ring-1 ring-brand-200 hover:bg-brand-50 focus:outline-none focus-visible:ring-2 focus-visible:ring-brand-500">
          {done ? 'Copied' : 'Copy'}
        </button>
      )}
    </div>
  )
}

/** The small marks beside a document number: what kind of paper it is. */
function DocMarks({ d }: { d: MyBillingDocument }) {
  return (
    <>
      {d.kind === 'credit_note' && <span className="ml-1 text-xs text-money-700">credit</span>}
      {d.purpose === 'plan_change' && <span className="ml-1 text-xs text-info-700">plan change</span>}
      {d.voided && <span className="ml-1 text-xs">cancelled</span>}
    </>
  )
}

/** A code's saving on one invoice, where it had one. */
function DocCode({ d }: { d: MyBillingDocument }) {
  if (!d.discount_code || !(Number(d.discount_amount ?? 0) > 0)) return null
  return (
    <div className="text-xs text-money-700">
      Code {d.discount_code}: {formatPkr(Number(d.discount_amount))} off
    </div>
  )
}

function Documents({ docs, onPrint }: { docs: MyBillingDocument[]; onPrint: (id: string) => void }) {
  // Owed only means something on a live invoice: a credit note and a
  // cancelled invoice are never a demand for money.
  const owedOn = (d: MyBillingDocument) => (d.kind === 'invoice' && !d.voided ? Number(d.owed ?? 0) : 0)
  const total = (d: MyBillingDocument) => (d.kind === 'credit_note' ? `- ${formatPkr(d.total)}` : formatPkr(d.total))
  return (
    <section className={CARD} aria-labelledby="docs-head">
      <h2 id="docs-head" className={HEAD}>Your invoices ({docs.length})</h2>
      {docs.length === 0 ? (
        <p className="mt-2 text-sm text-slate-500">Nothing has been invoiced yet.</p>
      ) : (
        <>
          <ul className="mt-2 divide-y divide-slate-100 sm:hidden">
            {docs.map((d) => (
              <li key={d.id} className={`flex items-center justify-between gap-3 py-2.5 ${d.voided ? 'text-slate-400' : ''}`}>
                <div className="min-w-0">
                  <div className="text-sm font-medium">
                    <span className={d.voided ? 'line-through' : ''}>{d.doc_no}</span>
                    <DocMarks d={d} />
                  </div>
                  <div className="text-xs text-slate-500">
                    {d.plan_name ? `${d.plan_name}, ` : ''}{fmtDate(d.period_start)} to {fmtDate(d.period_end)}
                  </div>
                  {d.kind === 'invoice' && !d.voided && (
                    <div className="text-xs text-slate-500">
                      Paid {formatPkr(d.paid)}
                      {owedOn(d) > 0 && <span className="font-medium text-due-800"> · {formatPkr(owedOn(d))} owed</span>}
                    </div>
                  )}
                  <DocCode d={d} />
                </div>
                <div className="shrink-0 text-right">
                  <div className="text-sm font-semibold tabular-nums">{total(d)}</div>
                  <button type="button" onClick={() => onPrint(d.id)} aria-label={`Print ${d.doc_no}`}
                    className={buttonClass({ variant: 'soft', size: 'sm', className: 'mt-1' })}>Print</button>
                </div>
              </li>
            ))}
          </ul>
          <table className="mt-2 hidden w-full text-sm sm:table">
            <thead>
              <tr className="border-b border-slate-200 text-left text-xs uppercase tracking-wide text-slate-500">
                <th className="py-1.5">Number</th><th className="py-1.5">Plan</th><th className="py-1.5">Covers</th>
                <th className="py-1.5 text-right">Total</th><th className="py-1.5 text-right">Paid</th>
                <th className="py-1.5 text-right">Owed</th><th className="py-1.5"><span className="sr-only">Print</span></th>
              </tr>
            </thead>
            <tbody className="divide-y divide-slate-100">
              {docs.map((d) => {
                const live = d.kind === 'invoice' && !d.voided
                return (
                  <tr key={d.id} className={`align-top ${d.voided ? 'text-slate-400' : ''}`}>
                    <td className="py-1.5">
                      <span className={d.voided ? 'line-through' : 'font-medium'}>{d.doc_no}</span>
                      <DocMarks d={d} />
                      <div className="text-xs text-slate-500">Issued {fmtDate(d.issued_on)}</div>
                      <DocCode d={d} />
                    </td>
                    <td className="py-1.5 text-slate-600">{d.plan_name ?? d.plan_code}</td>
                    <td className="py-1.5 text-slate-600">{fmtDate(d.period_start)} to {fmtDate(d.period_end)}</td>
                    <td className="py-1.5 text-right tabular-nums">{total(d)}</td>
                    <td className="py-1.5 text-right tabular-nums text-slate-500">{live ? formatPkr(d.paid) : '-'}</td>
                    <td className={`py-1.5 text-right tabular-nums ${owedOn(d) > 0 ? 'font-medium text-due-800' : 'text-slate-500'}`}>
                      {live ? formatPkr(owedOn(d)) : '-'}
                    </td>
                    <td className="py-1.5 text-right">
                      <button type="button" onClick={() => onPrint(d.id)} aria-label={`Print ${d.doc_no}`}
                        className={buttonClass({ variant: 'soft', size: 'sm' })}>Print</button>
                    </td>
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

const METHOD: Record<string, string> = {
  bank: 'Bank transfer', online: 'Online or app', cheque: 'Cheque', cash: 'Cash', other: 'Other',
}

/** Money we have received and confirmed, as distinct from what was reported. */
function Payments({ payments }: { payments: MyBilling['payments'] }) {
  if (payments.length === 0) return null
  return (
    <section className={CARD} aria-labelledby="payments-head">
      <h2 id="payments-head" className={HEAD}>Payments we have received</h2>
      <ul className="mt-2 divide-y divide-slate-100">
        {payments.map((p, i) => (
          <li key={`${p.paid_on}-${i}`} className="flex flex-col gap-0.5 py-2.5 text-sm sm:flex-row sm:items-start sm:justify-between">
            <div>
              <span className="font-semibold tabular-nums">{formatPkr(p.amount)}</span>{' '}
              <span className="text-slate-500">
                {METHOD[p.method] ?? p.method} on {fmtDate(p.paid_on)}
                {p.reference && <> · ref <span className="font-mono">{p.reference}</span></>}
              </span>
            </div>
            {Number(p.tax_withheld) > 0 && (
              <div className="text-xs text-slate-500 sm:text-right">
                {formatPkr(p.tax_withheld)} tax withheld
                {p.tax_certificate ? `, certificate ${p.tax_certificate}` : ', certificate awaited'}
              </div>
            )}
          </li>
        ))}
      </ul>
    </section>
  )
}

function Reports({ reports }: { reports: MyBilling['reports'] }) {
  if (reports.length === 0) return null
  return (
    <section className={CARD} aria-labelledby="reports-head">
      <h2 id="reports-head" className={HEAD}>Payments you have reported</h2>
      <ul className="mt-2 divide-y divide-slate-100">
        {reports.map((r) => (
          <li key={r.id} className="flex flex-col gap-1 py-2.5 text-sm sm:flex-row sm:items-start sm:justify-between">
            <div>
              <span className="font-semibold tabular-nums">{formatPkr(r.amount)}</span>{' '}
              <span className="text-slate-500">
                {METHOD[r.method] ?? r.method} on {fmtDate(r.paid_on)}
                {r.reference && <> · ref <span className="font-mono">{r.reference}</span></>}
              </span>
              <div className="text-xs text-slate-500">Reported {fmtDateTime(r.claimed_at)}</div>
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
    <div className="fixed inset-0 z-50 overflow-y-auto bg-slate-900/50 p-2 sm:p-4" role="dialog" aria-modal="true" aria-label="Invoice">
      <div className="mx-auto max-w-3xl rounded-2xl bg-white p-3 shadow-pop">
        <div className="flex items-center justify-between gap-2 print:hidden">
          <Button size="sm" onClick={() => window.print()}>Print</Button>
          <button type="button" onClick={onClose} className={buttonClass({ variant: 'soft', tone: 'neutral', size: 'sm' })}>Close</button>
        </div>
        {q.isLoading && <p className="p-4 text-sm text-slate-500">Loading…</p>}
        {q.error && <p className="p-4 text-sm text-danger-700">{(q.error as Error).message}</p>}
        {q.data && <InvoiceDoc d={q.data} />}
      </div>
    </div>
  )
}

function ReportDialog({ suggested, view, pending, onClose }: {
  suggested: number | null; view: SubscriptionView | null; pending: MyBilling['reports']; onClose: () => void
}) {
  const qc = useQueryClient()
  const [amount, setAmount] = useState(suggested ? String(suggested) : '')
  const [touched, setTouched] = useState(false)
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

        {view && <PaymentContextStrip v={view} />}

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
 * What the transfer is for, on the one screen where an amount is required.
 * Straight from the view: what is owed on which invoice, or the next term,
 * less any credit. It used to rebuild the figure from a price and a discount
 * preview, which is how it came to disagree with the invoice.
 */
function PaymentContextStrip({ v }: { v: SubscriptionView }) {
  if (!(v.pay_now > 0)) return null
  const open = v.open_invoice
  const otherOwed = v.owed - (open?.owed ?? 0)
  const quote = v.owed <= 0 && v.next?.quote?.priced ? v.next.quote : null
  return (
    <div className="mt-3 rounded-xl border border-slate-200 bg-slate-50 px-3 py-2 text-xs">
      <div className="font-semibold text-slate-700">What you are paying for</div>
      <dl className="mt-1 space-y-0.5 text-slate-700">
        {open && open.owed > 0 && (
          <div className="flex justify-between gap-3">
            <dt className="min-w-0">Invoice {open.doc_no}, {fmtDate(open.period_start)} to {fmtDate(open.period_end)}</dt>
            <dd className="shrink-0 whitespace-nowrap tabular-nums">{formatPkr(open.owed)}</dd>
          </div>
        )}
        {otherOwed > 0 && (
          <div className="flex justify-between gap-3"><dt className="min-w-0">Other invoices</dt><dd className="shrink-0 whitespace-nowrap tabular-nums">{formatPkr(otherOwed)}</dd></div>
        )}
        {quote && v.next && (
          <div className="flex justify-between gap-3">
            <dt className="min-w-0">{quote.plan_name}, {termWords(quote.months)} from {fmtDate(v.next.period_start)}</dt>
            <dd className="shrink-0 whitespace-nowrap tabular-nums">{formatPkr(quote.amount)}</dd>
          </div>
        )}
        {v.credit > 0 && (
          <div className="flex justify-between gap-3 text-money-800"><dt className="min-w-0">Paid ahead</dt><dd className="shrink-0 whitespace-nowrap tabular-nums">- {formatPkr(v.credit)}</dd></div>
        )}
        <div className="flex justify-between gap-3 border-t border-slate-200 pt-1 font-semibold">
          <dt className="min-w-0">Total to send</dt><dd className="shrink-0 whitespace-nowrap tabular-nums">{formatPkr(v.pay_now)}</dd>
        </div>
      </dl>
    </div>
  )
}

/** Which invoice a code would first reach, in words. */
function whereItLands(p: CodePreview): string {
  const from = p.period_start ? `, from ${fmtDate(p.period_start)}` : ''
  switch (p.applies_to) {
    case 'open_invoice': return `your open invoice${from}, which we reissue with the code on it`
    case 'invoice_after_open': return `the invoice after the one you have started paying${from}`
    default: return `your next invoice${from}`
  }
}

/** Whether a checked code is worth offering to use: it takes something off. */
function usable(p: CodePreview): boolean {
  if (!p.ok) return false
  if (p.replaces?.granted_by_kind === 'platform') return false
  return p.kind === 'trial_days' || Number(p.discount_amount ?? 0) > 0
}

function PreviewLines({ p }: { p: CodePreview }) {
  if (p.kind === 'trial_days') {
    return (
      <p>
        <span className="font-semibold">{p.code}</span>{p.label ? ` (${p.label})` : ''}: adds {p.trial_days ?? 0} days to your free trial.
      </p>
    )
  }
  const off = Number(p.discount_amount ?? 0)
  return (
    <>
      <p>
        <span className="font-semibold">{p.code}</span>{p.label ? ` (${p.label})` : ''}: {p.summary}.
      </p>
      {p.term_price == null ? (
        <p className="mt-0.5">Your price is not agreed yet, so we cannot say what it takes off until it is.</p>
      ) : off > 0 ? (
        <p className="mt-0.5">
          On {whereItLands(p)}: {formatPkr(off)} off, covering {p.months_covered ?? 0} of its {p.months ?? 0}{' '}
          month{p.months === 1 ? '' : 's'}. You would pay {formatPkr(p.amount ?? 0)} instead of {formatPkr(p.term_price)}.
        </p>
      ) : (
        <p className="mt-0.5">It would take nothing off {whereItLands(p)}.</p>
      )}
      {p.skipped && <p className="mt-0.5">{p.skipped}</p>}
      {p.replaces && (
        p.replaces.granted_by_kind === 'platform' ? (
          <p className="mt-0.5">
            Your current code {p.replaces.code} was arranged with us, so it can only be changed by us. Please call us.
          </p>
        ) : (
          <p className="mt-0.5">
            Using it takes off your current code {p.replaces.code}{p.replaces.label ? ` (${p.replaces.label})` : ''}:{' '}
            {p.replaces.summary}. We will ask you first.
          </p>
        )
      )}
    </>
  )
}

/**
 * The discount code: what the school has, and using a new one.
 *
 * CHECK, THEN USE. A code is previewed against this school's plan and term
 * first, and the preview says exactly what it takes off which invoice, so the
 * school sees the figure before the code is spent. A code that would take
 * nothing off is not offered: using it would burn it for good.
 *
 * A REFUSAL IS AN ANSWER, shown as a plain sentence, not a red box. "That code
 * could be used until 03 Sep" is an ordinary reply to an ordinary question,
 * and the database returns it as data for that reason (it logs every try).
 *
 * REPLACING NEEDS A YES. A school with a code is told what it would lose and
 * asked; only then is the code used with replace. A code we gave cannot be
 * replaced or removed from here, and the panel says so instead of offering it.
 *
 * Schools see a code's label and the sentence built from its frozen terms,
 * never our description.
 */
function CodePanel({ view, current }: { view: SubscriptionView | null; current: MyCode | null }) {
  const refresh = useRefreshBilling()
  const [code, setCode] = useState('')
  const [preview, setPreview] = useState<CodePreview | null>(null)
  const [confirm, setConfirm] = useState<RedeemResult | null>(null)
  const [refusal, setRefusal] = useState<string | null>(null)
  const [msg, setMsg] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)
  const [askRemove, setAskRemove] = useState(false)
  const typed = code.trim().toUpperCase()

  function reset() { setPreview(null); setConfirm(null); setRefusal(null); setMsg(null) }

  async function check() {
    if (!typed || busy) return
    setBusy(true); reset()
    try {
      const p = await previewCode(typed, view?.plan.code ?? null, view?.term_months ?? null)
      if (p.ok) setPreview(p)
      else setRefusal(p.reason ?? 'That code cannot be used.')
    } catch (e) { setRefusal((e as Error).message) }
    setBusy(false)
  }

  async function use(replace: boolean) {
    if (!typed) return
    setBusy(true); setRefusal(null); setMsg(null)
    try {
      const r = await redeemCode(typed, replace)
      if (r.ok) {
        setMsg([r.summary ? `${r.code ?? typed}: ${r.summary}.` : null, r.what_next].filter(Boolean).join(' '))
        setCode(''); setPreview(null); setConfirm(null)
        refresh()
      } else if (r.needs_replace) {
        setConfirm(r)
      } else {
        setConfirm(null)
        setRefusal(r.reason ?? 'That code cannot be used.')
      }
    } catch (e) { setRefusal((e as Error).message) }
    setBusy(false)
  }

  async function remove() {
    setBusy(true); setRefusal(null); setMsg(null)
    try {
      const r = await removeMyCode()
      setMsg(r.removed
        ? `Code ${r.code ?? current?.code ?? ''} is off your subscription. It will not come off any invoice from now on.`
        : 'There was no code on your subscription to remove.')
      refresh()
    } catch (e) { setRefusal((e as Error).message) }
    setBusy(false); setAskRemove(false)
  }

  const old = confirm?.preview?.replaces ?? null

  return (
    <section className={CARD} aria-labelledby="code-head">
      <h2 id="code-head" className={HEAD}>Discount code</h2>

      {current?.code ? (
        <div className="mt-2 rounded-xl bg-money-50 px-3 py-2 text-sm text-money-900 ring-1 ring-money-100">
          <div className="flex flex-wrap items-start justify-between gap-2">
            <div className="min-w-0">
              <p>
                <span className="font-semibold">{current.code}</span>
                {current.label ? <span>: {current.label}</span> : null}
              </p>
              {current.summary && <p className="text-xs">{current.summary}.</p>}
              <p className="text-xs">
                {current.duration === 'months' && current.months_left != null
                  ? `${current.months_left} of ${current.months_total ?? current.months_left} months left. `
                  : current.duration === 'until' && current.ends_on
                    ? `Until ${fmtDate(current.ends_on)}. `
                    : ''}
                {Number(current.total_saved ?? 0) > 0
                  ? `Saved you ${formatPkr(Number(current.total_saved))} so far.`
                  : 'It has not come off an invoice yet.'}
              </p>
              {current.granted_by_us && (
                <p className="mt-0.5 text-xs">Arranged with us, so only we can change it. Call us to change it.</p>
              )}
            </div>
            {current.can_remove && (
              !askRemove ? (
                <button type="button" onClick={() => setAskRemove(true)}
                  className={buttonClass({ variant: 'soft', tone: 'neutral', size: 'sm' })}>Remove</button>
              ) : (
                <span className="flex gap-2">
                  <Button size="sm" variant="soft" tone="neutral" onClick={() => setAskRemove(false)} disabled={busy}>Keep</Button>
                  <Button size="sm" tone="danger" onClick={() => void remove()} disabled={busy}>Remove for good</Button>
                </span>
              )
            )}
          </div>
        </div>
      ) : (
        <p className="mt-1 text-sm text-slate-600">If we have sent you a code, enter it here. You will see what it takes off before it is used.</p>
      )}
      {current?.trial_code && (
        <p className="mt-2 text-xs text-slate-500">
          Code {current.trial_code.code} added {current.trial_code.days} days to your free trial on {fmtDate(current.trial_code.on)}.
        </p>
      )}

      <div className="mt-3 flex flex-col gap-2 sm:flex-row">
        <label className="sr-only" htmlFor="discount-code">Discount code</label>
        <input id="discount-code" value={code}
          onChange={(e) => { setCode(e.target.value.toUpperCase()); reset() }}
          onKeyDown={(e) => { if (e.key === 'Enter') { e.preventDefault(); void check() } }}
          placeholder={current?.code ? 'A different code' : 'Type the code you were given'}
          autoCapitalize="characters" autoComplete="off" spellCheck={false}
          className={`${inputClass} uppercase tracking-wide placeholder:normal-case placeholder:tracking-normal sm:flex-1`} />
        <div className="grid grid-cols-2 gap-2 sm:flex">
          <Button variant="soft" tone="neutral" onClick={() => void check()} disabled={!typed || busy}
            className={preview && usable(preview) && !confirm ? '' : 'col-span-2'}>
            {busy && !preview ? 'Checking…' : 'Check'}
          </Button>
          {preview && usable(preview) && !confirm && (
            <Button onClick={() => void use(false)} disabled={busy}>Use this code</Button>
          )}
        </div>
      </div>

      {preview && (
        <div className="mt-2 rounded-xl border border-slate-200 bg-slate-50 px-3 py-2 text-sm text-slate-700" role="status">
          <PreviewLines p={preview} />
        </div>
      )}

      {confirm && (
        <div className="mt-2 rounded-xl border border-due-200 bg-due-50 p-3 text-sm text-due-900">
          <p className="font-medium">Replace {old?.code ?? 'your current code'} with {typed}?</p>
          {confirm.reason && <p className="mt-0.5">{confirm.reason}</p>}
          {old?.summary && <p className="mt-0.5">What you have now: {old.summary}.</p>}
          <div className="mt-2 grid grid-cols-2 gap-2 sm:flex">
            <Button size="sm" onClick={() => void use(true)} disabled={busy}>
              {busy ? 'Replacing…' : `Yes, use ${typed}`}
            </Button>
            <Button size="sm" variant="soft" tone="neutral" onClick={() => setConfirm(null)} disabled={busy}>
              Keep {old?.code ?? 'what I have'}
            </Button>
          </div>
        </div>
      )}

      {refusal && <p className="mt-2 text-sm text-due-900">{refusal}</p>}
      {msg && <p className="mt-2 rounded-xl bg-brand-50 px-3 py-1.5 text-sm text-brand-900" role="status">{msg}</p>}
    </section>
  )
}

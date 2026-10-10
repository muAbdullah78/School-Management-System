import { useState, type FormEvent } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useAuth } from '@/auth/AuthProvider'
import { useLicence } from '@/hooks/useLicence'
import { formatPkr, type Licence } from '@/lib/licence'
import {
  exportAllData, getSchoolSettings, myBilling, myPlatformInvoice, reportSubscriptionPayment,
  type MyBilling,
} from '@/lib/db'
import { lockedSentence, requestMyInvoice, type LockedBecause, type SubscriptionView } from '@/lib/subscription'
import { downloadJSON } from '@/lib/csv'
import { today } from '@/lib/dates'
import { fmtDate, fmtDateTime } from '@/lib/format'
import { InvoiceDoc } from '@/components/InvoiceDoc'
import { Button, LoadError, buttonClass, inputClass } from '@/components/ui'
import { SchoolClosed } from '@/pages/SchoolClosed'

const CARD = 'rounded-2xl border border-slate-200 bg-white p-4 shadow-card sm:p-5'
const HEAD = 'text-xs font-semibold uppercase tracking-wide text-slate-500'

/**
 * Shown instead of the app when new entries are paused: the subscription ran
 * out, a payment is overdue, an Enterprise price is not agreed yet, or we
 * cancelled or paused the school.
 *
 * The tone here matters more than the code. A school seeing this screen is
 * usually not refusing to pay. They forgot, or the transfer is still clearing.
 * So it says plainly that nothing has been deleted, puts the export button on
 * the page, and tells them exactly what to do next. It never implies their
 * records are being held.
 *
 * EVERYTHING NEEDED TO GET BACK IN IS ON THIS ONE SCREEN, because it is the only
 * screen a locked school can reach. It used to print the plan's list prices and
 * say "send your payment and message us", which left the owner to find the bank
 * account, work out the amount and phone us with the reference. Now it says, in
 * this order: why, how much (from the database, the school's code included and
 * its credit taken off), the invoice if there is one, where to send the money,
 * and an "I have paid" form. Paying is what opens the school again under 0155:
 * once we record the transfer the lock lifts by itself.
 *
 * THE FORM DOES NOT TAKE A PAYMENT and says so. It tells us what to look for on
 * our statement. A form that looks like it settled the bill and did not is
 * worse than no form, so the reply and the report waiting to be checked are
 * shown underneath it once it is sent.
 *
 * OWNER AND PRINCIPAL ONLY. LicenceGate sends everybody else to SchoolClosed,
 * and this screen checks again itself, because it carries the amount, our bank
 * account and an export of the whole school.
 */
export function SubscriptionLocked({ licence }: { licence: Licence }) {
  const { profile, signOut } = useAuth()
  const leader = profile?.role === 'owner' || profile?.role === 'principal'
  const billing = useQuery({ queryKey: ['myBilling'], queryFn: myBilling, enabled: leader })
  const settings = useQuery({ queryKey: ['schoolSettings'], queryFn: getSchoolSettings, enabled: leader })
  const { refetch, isFetching } = useLicence()
  const [busy, setBusy] = useState(false)
  const [done, setDone] = useState<number | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [printing, setPrinting] = useState<string | null>(null)

  if (!leader) return <SchoolClosed licence={licence} audience="staff" />

  async function runExport() {
    setBusy(true); setError(null); setDone(null)
    try {
      const stamp = new Date().toISOString()
      const data = await exportAllData(stamp)
      const slug = (settings.data?.name || 'school').toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '')
      downloadJSON(`backup_${slug}_${stamp.slice(0, 10)}.json`, data)
      setDone(Object.values(data.counts).reduce((a, b) => a + b, 0))
    } catch (e) {
      setError((e as Error).message)
    } finally {
      setBusy(false)
    }
  }

  const b = billing.data?.ok ? billing.data : null
  const view = b?.subscription ?? null
  const reason: LockedBecause | null = view?.locked_because
    ?? licence.locked_because
    ?? (licence.status === 'cancelled' ? 'cancelled' : null)
  const inTrial = view ? view.in_trial : !licence.paid_through
  const sentence = view ? lockedSentence(view) : null

  return (
    <div className="min-h-full bg-slate-50 px-4 py-8 sm:px-6">
      <main className="mx-auto max-w-2xl space-y-4">
        <section className={CARD}>
          <div className={HEAD}>{licence.plan_name}</div>
          <h1 className="mt-1 text-xl font-semibold tracking-[-0.01em] text-slate-900">
            {title(reason, inTrial, licence.status)}
          </h1>
          {sentence && <p className="mt-2 text-sm text-slate-700">{sentence}</p>}
          <p className="mt-2 text-sm text-slate-600">
            Entering new information is paused for now: attendance, fees, admissions and results.
          </p>
          <p className="mt-3 rounded-xl border border-money-200 bg-money-50 px-3 py-2 text-sm text-money-900">
            <span className="font-medium">Nothing has been deleted.</span> Every student, payment and result
            is exactly where you left it, and you can download all of it from this page.
          </p>
        </section>

        {/* A failed read is said out loud. An amount that did not load must not
            be drawn as "nothing to pay". */}
        <LoadError of={[billing]} what="What you owe and where to pay" />
        {billing.isLoading && <div className="h-40 animate-pulse rounded-2xl bg-slate-100" />}

        {b && (
          <Money b={b} view={view} reason={reason} licence={licence}
            onPrint={setPrinting} />
        )}

        <section className={CARD}>
          <div className={HEAD}>Your records</div>
          <p className="mt-1 text-sm text-slate-600">
            A copy of everything this school has entered, to keep on your own computer.
          </p>
          <div className="mt-3 grid gap-2 sm:flex">
            <Button onClick={() => void runExport()} disabled={busy} className="w-full sm:w-auto">
              {busy ? 'Preparing your data…' : 'Download all my data'}
            </Button>
            {/* Recording a payment opens the school by itself now, so a school
                that has just been told it was received needs a way to see that
                without being told to restart the app. */}
            <Button variant="soft" tone="neutral" className="w-full sm:w-auto"
              onClick={() => { void refetch(); void billing.refetch() }} disabled={isFetching}>
              {isFetching ? 'Checking…' : 'Check again'}
            </Button>
            <Button variant="ghost" className="w-full sm:w-auto" onClick={() => void signOut()}>
              Sign out
            </Button>
          </div>
          {done !== null && (
            <p role="status" className="mt-3 rounded-xl bg-money-50 px-3 py-2 text-sm text-money-800">
              Downloaded: {done.toLocaleString()} records saved to your computer.
            </p>
          )}
          {error && <p className="mt-3 text-sm text-danger-700">{error}</p>}
        </section>
      </main>

      {printing && <PrintDialog invoiceId={printing} onClose={() => setPrinting(null)} />}
    </div>
  )
}

function title(reason: LockedBecause | null, inTrial: boolean, status: Licence['status']): string {
  switch (reason) {
    case 'needs_price': return 'Your price is not agreed yet'
    case 'unpaid': return 'A payment is overdue'
    case 'expired': return inTrial ? 'Your free trial has ended' : 'Your paid period has ended'
    case 'suspended': return 'This school is paused'
    case 'cancelled': return 'This subscription has been cancelled'
    default: return status === 'cancelled' ? 'This subscription has been cancelled' : 'Your subscription has ended'
  }
}

function months(n: number): string {
  return n === 1 ? 'one month' : n === 12 ? 'a year' : `${n} months`
}

/** How much, the invoice, where to send it, and the form to say it was sent. */
function Money({ b, view, reason, licence, onPrint }: {
  b: MyBilling; view: SubscriptionView | null; reason: LockedBecause | null
  licence: Licence; onPrint: (id: string) => void
}) {
  const qc = useQueryClient()
  const owed = view?.owed ?? Number(b.balance.outstanding || 0)
  // A database before 0155 sends no pay_now; what it says is outstanding is
  // the next best answer, and better than none.
  const payNow = view?.pay_now ?? licence.pay_now ?? (owed > 0 ? owed : null)
  const needsPrice = view?.needs_price ?? licence.needs_price ?? false
  const inv = view?.open_invoice ?? null
  const phone = b.pay_to.support_phone
  const callUs = phone ? `call us on ${phone}` : 'call us'
  // Nothing this school can pay would open it: a price we have not set, a
  // cancellation, or a pause we made. Those get a sentence and a number to
  // ring, and no form asking for a transfer nobody can make sense of.
  const callOnly = reason === 'cancelled'
    || ((reason === 'needs_price' || reason === 'suspended' || needsPrice) && owed <= 0)

  const ask = useMutation({
    mutationFn: requestMyInvoice,
    onSuccess: () => { void qc.invalidateQueries({ queryKey: ['myBilling'] }) },
  })

  return (
    <>
      <section className={CARD}>
        <div className={HEAD}>To pay now</div>
        {callOnly ? (
          <>
            <div className="mt-1 text-2xl font-semibold text-slate-900">
              {reason === 'cancelled' ? 'Nothing to pay here' : 'Nothing to pay yet'}
            </div>
            <p className="mt-1 text-sm text-slate-600">
              {reason === 'cancelled'
                ? `To start again, ${callUs}.`
                : reason === 'suspended'
                  ? `Please ${callUs}.`
                  : `We agree a monthly price with you first. We will call you, or you can ${callUs}.`}
            </p>
          </>
        ) : payNow === null ? (
          <p className="mt-1 text-sm text-slate-600">
            We could not work out the amount just now. Please {callUs} and we will tell you.
          </p>
        ) : (
          <>
            <div className={`mt-1 text-2xl font-semibold tabular-nums ${payNow > 0 ? 'text-due-800' : 'text-slate-900'}`}>
              {payNow > 0 ? formatPkr(payNow) : 'Nothing'}
            </div>
            {payNow > 0 && !inv && view?.next && (
              <p className="mt-1 text-sm text-slate-600">
                This pays for {months(view.next.months)} from {fmtDate(view.next.period_start)}.
              </p>
            )}
            {view && view.credit > 0 && (
              <p className="mt-1 text-xs text-slate-500">
                The {formatPkr(view.credit)} you have already paid us is taken off.
              </p>
            )}
            {payNow <= 0 && (
              <p className="mt-1 text-sm text-slate-600">
                Nothing is owed. If you have just paid, press Check again below.
              </p>
            )}
          </>
        )}

        {inv && (
          <div className="mt-3 flex flex-col gap-2 rounded-xl border border-slate-200 p-3 text-sm sm:flex-row sm:items-center sm:justify-between">
            <div className="min-w-0">
              <div className="font-medium text-slate-900">Invoice {inv.doc_no ?? ''}</div>
              <div className="text-slate-600">
                {fmtDate(inv.period_start)} to {fmtDate(inv.period_end)}
                {inv.due_on && <> · due {fmtDate(inv.due_on)}</>}
              </div>
              <div className="text-slate-600">
                Still owed <span className="font-semibold tabular-nums text-slate-900">{formatPkr(inv.owed)}</span>
                {inv.paid > 0 && <> of {formatPkr(inv.total)}</>}
              </div>
            </div>
            <Button size="sm" variant="soft" onClick={() => onPrint(inv.id)} className="shrink-0">
              Print invoice
            </Button>
          </div>
        )}

        {/* An accounts office often will not pay without a piece of paper. */}
        {!inv && !callOnly && view?.can_request_invoice && (
          <div className="mt-3 text-sm">
            <Button size="sm" variant="soft" onClick={() => ask.mutate()} disabled={ask.isPending}>
              {ask.isPending ? 'Making your invoice…' : 'Get an invoice for your accounts office'}
            </Button>
            {ask.error && <p className="mt-1 text-danger-700">{(ask.error as Error).message}</p>}
          </div>
        )}
      </section>

      {!callOnly && (
        <>
          <PayTo b={b} />
          <IHavePaid suggested={payNow && payNow > 0 ? payNow : null} />
        </>
      )}
      <Reports reports={b.reports} />
    </>
  )
}

/** Our account, copied rather than retyped. */
function PayTo({ b }: { b: MyBilling }) {
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
      {(p.support_phone || p.support_email) && (
        <p className="mt-2 text-xs text-slate-500">
          Any question: {[p.support_phone, p.support_email].filter(Boolean).join(' · ')}
        </p>
      )}
    </section>
  )
}

function PayRow({ k, v, mono, copy }: { k: string; v: string; mono?: boolean; copy?: boolean }) {
  const [copied, setCopied] = useState(false)
  // One wrong digit in an account number sends the school's money to a
  // stranger, and a phone keyboard makes that easy.
  function doCopy() {
    void navigator.clipboard?.writeText(v).then(() => {
      setCopied(true); window.setTimeout(() => setCopied(false), 1500)
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
          className={buttonClass({ variant: 'soft', size: 'sm', className: 'shrink-0' })}>
          {copied ? 'Copied' : 'Copy'}
        </button>
      )}
    </div>
  )
}

/**
 * "I have paid", on the page rather than behind a button: it is the one thing
 * a locked school that has paid needs to do, and this screen has nothing else
 * competing for the space.
 *
 * THE AMOUNT STARTS AS WHAT IS DUE, and stays the school's own once it types
 * in the box. Derived rather than copied in by an effect, so the figure is there
 * on the first paint once the bill has loaded.
 */
function IHavePaid({ suggested }: { suggested: number | null }) {
  const qc = useQueryClient()
  const [typed, setTyped] = useState<string | null>(null)
  const [paidOn, setPaidOn] = useState(today())
  const [method, setMethod] = useState('bank')
  const [reference, setReference] = useState('')
  const [fromBank, setFromBank] = useState('')
  const [note, setNote] = useState('')
  const [tried, setTried] = useState(false)
  const [reply, setReply] = useState<string | null>(null)

  const amount = typed ?? (suggested ? String(Math.round(suggested)) : '')
  const n = Number(amount)
  const amountProblem = amount.trim() === '' ? 'Enter the amount you sent.'
    : !Number.isFinite(n) || n <= 0 ? 'The amount has to be more than zero.'
      : n > 10_000_000 ? 'That is more than any invoice. Check the amount.'
        : null
  const dateProblem = !paidOn ? 'Enter the date you sent it.' : paidOn > today() ? 'That date is in the future.' : null

  const send = useMutation({
    mutationFn: () => reportSubscriptionPayment({
      amount: n, paidOn, method,
      reference: reference.trim() || null, fromBank: fromBank.trim() || null, note: note.trim() || null,
    }),
    onSuccess: (r) => {
      setReply(r.message)
      setTyped(null); setReference(''); setFromBank(''); setNote(''); setTried(false)
      void qc.invalidateQueries({ queryKey: ['myBilling'] })
    },
  })

  function onSubmit(e: FormEvent) {
    e.preventDefault()
    setTried(true)
    setReply(null)
    if (amountProblem || dateProblem) return
    send.mutate()
  }

  return (
    <section className={CARD} aria-labelledby="paid-head">
      <h2 id="paid-head" className={HEAD}>I have paid</h2>
      <p className="mt-1 text-sm text-slate-600">
        This does not take a payment. It tells us what to look for on our bank statement, so we can
        confirm it without phoning you. New entries start again as soon as we record it.
      </p>

      {reply && (
        <p role="status" className="mt-3 rounded-xl bg-money-50 px-3 py-2 text-sm text-money-900">{reply}</p>
      )}
      {send.error && (
        <p role="alert" className="mt-3 rounded-xl bg-danger-50 px-3 py-2 text-sm text-danger-800">
          {(send.error as Error).message}
        </p>
      )}

      <form onSubmit={onSubmit} className="mt-3 space-y-3" noValidate>
        <div className="grid gap-3 sm:grid-cols-2">
          <label className="block">
            <span className="text-xs font-medium text-slate-600">How much you sent (Rs)</span>
            <input type="number" inputMode="decimal" step="1" min="1" className={`mt-1 ${inputClass}`}
              value={amount} onChange={(e) => setTyped(e.target.value)}
              aria-invalid={tried && !!amountProblem} />
            {tried && amountProblem && <span className="mt-1 block text-xs text-danger-700">{amountProblem}</span>}
          </label>
          <label className="block">
            <span className="text-xs font-medium text-slate-600">On what date</span>
            <input type="date" max={today()} className={`mt-1 ${inputClass}`} value={paidOn}
              onChange={(e) => setPaidOn(e.target.value)} aria-invalid={tried && !!dateProblem} />
            {tried && dateProblem && <span className="mt-1 block text-xs text-danger-700">{dateProblem}</span>}
          </label>
        </div>
        <div className="grid gap-3 sm:grid-cols-2">
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
          <label className="block">
            <span className="text-xs font-medium text-slate-600">Which bank or app you sent it from (optional)</span>
            <input className={`mt-1 ${inputClass}`} value={fromBank} onChange={(e) => setFromBank(e.target.value)} />
          </label>
        </div>
        <div>
          <label className="block">
            <span className="text-xs font-medium text-slate-600">Transaction reference</span>
            <input className={`mt-1 ${inputClass}`} value={reference} onChange={(e) => setReference(e.target.value)}
              placeholder="From your bank slip or app receipt" aria-describedby="ref-hint" />
          </label>
          <p id="ref-hint" className="mt-1 text-xs text-slate-500">
            This is how we find it on our statement. Without it we may not be able to match your transfer.
          </p>
        </div>
        <label className="block">
          <span className="text-xs font-medium text-slate-600">Anything else (optional)</span>
          <input className={`mt-1 ${inputClass}`} value={note} onChange={(e) => setNote(e.target.value)}
            placeholder="For example: we deducted withholding tax, certificate to follow" />
        </label>
        <Button type="submit" disabled={send.isPending} className="w-full sm:w-auto">
          {send.isPending ? 'Sending…' : 'Tell us about this payment'}
        </Button>
      </form>
    </section>
  )
}

/** What the school has told us, and what came of it, including WHY one was not found. */
function Reports({ reports }: { reports: MyBilling['reports'] }) {
  const shown = reports.slice(0, 5)
  if (shown.length === 0) return null
  return (
    <section className={CARD}>
      <div className={HEAD}>Payments you have reported</div>
      <ul className="mt-2 divide-y divide-slate-100">
        {shown.map((r) => (
          <li key={r.id} className="flex flex-col gap-1 py-2.5 text-sm sm:flex-row sm:items-start sm:justify-between">
            <div>
              <span className="font-semibold tabular-nums">{formatPkr(r.amount)}</span>{' '}
              <span className="text-slate-500">
                on {fmtDate(r.paid_on)}
                {r.reference && <> · ref <span className="font-mono">{r.reference}</span></>}
              </span>
              <div className="text-xs text-slate-400">Reported {fmtDateTime(r.claimed_at)}</div>
            </div>
            <div className="text-xs sm:max-w-xs sm:text-right">
              {r.status === 'pending' && (
                <span className="rounded-full bg-info-50 px-2 py-0.5 text-info-800 ring-1 ring-info-100">Being checked</span>
              )}
              {r.status === 'confirmed' && (
                <span className="rounded-full bg-money-50 px-2 py-0.5 text-money-800 ring-1 ring-money-100">
                  Received{r.decided_at ? ` ${fmtDate(r.decided_at)}` : ''}
                </span>
              )}
              {r.status === 'rejected' && (
                <div className="text-danger-800">
                  <span className="rounded-full bg-danger-50 px-2 py-0.5 font-medium ring-1 ring-danger-100">Not found</span>
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
    <div className="fixed inset-0 z-50 overflow-y-auto bg-slate-900/50 p-2 sm:p-4" role="dialog" aria-modal="true" aria-label="Your invoice">
      <div className="mx-auto max-w-3xl rounded-2xl bg-white p-3 shadow-pop">
        <div className="flex items-center justify-between gap-2 print:hidden">
          <Button size="sm" onClick={() => window.print()} disabled={!q.data}>Print</Button>
          <Button size="sm" variant="soft" tone="neutral" onClick={onClose}>Close</Button>
        </div>
        {q.isLoading && <p className="p-4 text-sm text-slate-500">Loading…</p>}
        {q.error && <p className="p-4 text-sm text-danger-700">{(q.error as Error).message}</p>}
        {q.data && <InvoiceDoc d={q.data} />}
      </div>
    </div>
  )
}

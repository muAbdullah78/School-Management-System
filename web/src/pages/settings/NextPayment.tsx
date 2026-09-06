import { useState } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { chooseTerm, myNextPayment, setManualPaymentMethod, type NextPayment } from '@/lib/db'
import { formatPkr } from '@/lib/licence'

const FIELD = 'w-full rounded border border-slate-300 px-2 py-1.5 text-sm'

/**
 * What happens next, and how the money will get here.
 *
 * WHY THIS PANEL EXISTS AT ALL
 *
 * The subscription screen below it answered "what do we owe you" and "send the
 * invoice again". It could not answer the two questions a school actually asks
 * on day one of a trial: WHEN does this start costing money, and HOW MUCH. So
 * the trial ended and the software stopped, and the first anybody knew was a
 * locked screen.
 *
 * THE SENTENCE COMES FROM THE DATABASE, not from this component. A school reads
 * it at checkout and again three days before the charge, and if two screens
 * compose it from parts then one of them eventually says the 20th while the
 * invoice says the 21st. fn_my_next_payment owns the wording.
 *
 * AND IT NEVER PROMISES A CHARGE NOTHING CAN MAKE. Credit cards are held by
 * 0.22 percent of Pakistani adults and debit cards by 7.7 percent, so for most
 * schools here nothing will ever take the money automatically. "You will be
 * charged on the 20th" is a lie to those schools, and the worst kind: the school
 * relaxes, nothing arrives, and it is locked out having done everything asked of
 * it. The database says "is due by" instead, and this panel puts a reminder
 * beside it rather than a reassurance.
 */
export function NextPaymentPanel() {
  const q = useQuery({ queryKey: ['myNextPayment'], queryFn: myNextPayment })

  if (q.isLoading) return null
  // Quiet on failure. This panel sits above a screen that works without it, and
  // a red box at the top of the billing page over a read that may simply not be
  // applied yet would be alarming for no reason.
  if (q.error || !q.data?.has_subscription) return null

  return <Body n={q.data} />
}

function Body({ n }: { n: NextPayment }) {
  const qc = useQueryClient()
  const [editing, setEditing] = useState(false)
  const refresh = () => {
    void qc.invalidateQueries({ queryKey: ['myNextPayment'] })
    void qc.invalidateQueries({ queryKey: ['myBilling'] })
    void qc.invalidateQueries({ queryKey: ['licence'] })
  }

  const due = n.next_charge_on ?? null
  const amount = n.next_charge_amount ?? null
  const daysAway = due
    ? Math.ceil((new Date(`${due}T00:00:00+05:00`).getTime() - Date.now()) / 86_400_000)
    : null

  return (
    <section className={`rounded-lg border p-4 ${
      n.in_trial ? 'border-brand-200 bg-brand-50' : 'border-slate-200 bg-white'}`}>
      <div className="flex flex-wrap items-start justify-between gap-4">
        <div className="min-w-0">
          <div className="text-xs font-semibold uppercase tracking-wide text-slate-500">
            {n.in_trial ? 'Your free trial' : 'Next payment'}
          </div>
          {/* The database's sentence, verbatim. */}
          <p className="mt-1 max-w-prose text-sm font-medium text-slate-800">{n.sentence}</p>

          {/* THE DATE IS NOT REPEATED HERE. The sentence above already spells
              it, and this line spelled it again through fmtDate - which
              renders "20 Sept 2026" where the database's sentence says
              "20 Sep 2026". Two spellings of the same date, on the same
              screen, an inch apart. The countdown and the amount are what
              this line adds; the date belongs to the sentence. */}
          {due && amount !== null && (
            <div className="mt-2 flex flex-wrap items-baseline gap-x-4 gap-y-1 text-sm">
              <span className="text-lg font-semibold tabular-nums text-slate-800">
                {formatPkr(amount)}
              </span>
              <span className="text-slate-500">
                for {n.term_months === 12 ? 'a year'
                  : n.term_months === 1 ? 'one month'
                  : `${n.term_months} months`}
              </span>
              {daysAway !== null && daysAway >= 0 && (
                <span className="text-slate-400">
                  {daysAway === 0 ? 'due today'
                    : `in ${daysAway} day${daysAway === 1 ? '' : 's'}`}
                </span>
              )}
            </div>
          )}
        </div>
      </div>

      <div className="mt-4 grid gap-4 border-t border-slate-200/70 pt-3 sm:grid-cols-2">
        {/* NO TERM CHOOSER ON A SUBSCRIPTION THAT IS ENDING. Offering "monthly,
            three months, a year" to a school that has cancelled is a choice
            with no consequence: there is no next payment for a term to apply
            to. It read as though the cancellation had not registered. */}
        {n.cancel_at_period_end ? (
          <div>
            <div className="text-xs font-semibold uppercase tracking-wide text-slate-500">
              How often you pay
            </div>
            <p className="mt-2 text-sm text-slate-600">
              Nothing further is scheduled. If you start again, you can choose
              monthly, three months or a year then.
            </p>
          </div>
        ) : (
          <TermChooser terms={n.terms} current={n.term_months ?? 12} onDone={refresh} />
        )}
        <MethodBlock n={n} editing={editing} setEditing={setEditing} onDone={refresh} />
      </div>
    </section>
  )
}

/**
 * Monthly, three months, or a year.
 *
 * The saving is shown in rupees rather than as a percentage, because "Rs 4,000"
 * is a number a school can weigh against something and "16.7 percent" is
 * arithmetic homework. The figures come from the price list the invoice uses.
 */
function TermChooser({ terms, current, onDone }: {
  terms: NextPayment['terms']; current: number; onDone: () => void
}) {
  const [err, setErr] = useState<string | null>(null)
  const pick = useMutation({
    mutationFn: (m: 1 | 3 | 12) => chooseTerm(m),
    onSuccess: () => { setErr(null); onDone() },
    onError: (e) => setErr((e as Error).message),
  })

  const LABEL: Record<number, string> = { 1: 'Monthly', 3: '3 months', 12: 'A year' }
  // The figures come from the database, not from here. A saving stated in
  // RUPEES rather than as a percentage, because "Rs 4,000" is a number a school
  // can weigh against something it wants and "16.7 percent" is homework.
  const rows = terms ?? []

  if (rows.length === 0) {
    return (
      <div>
        <div className="text-xs font-semibold uppercase tracking-wide text-slate-500">
          How often you pay
        </div>
        <p className="mt-2 text-sm text-slate-600">
          Your plan is priced by arrangement. Talk to us about the term.
        </p>
      </div>
    )
  }

  return (
    <div>
      <div className="text-xs font-semibold uppercase tracking-wide text-slate-500">
        How often you pay
      </div>
      <div className="mt-2 flex flex-wrap gap-1.5">
        {rows.map((t) => {
          const on = current === t.months
          return (
            <button key={t.months} disabled={pick.isPending || on}
              onClick={() => pick.mutate(t.months)}
              className={`rounded border px-2.5 py-1.5 text-left text-xs ${
                on ? 'border-brand-600 bg-brand-600 text-white'
                   : 'border-slate-300 bg-white text-slate-700 hover:bg-slate-50'}`}>
              <span className="block font-medium">{LABEL[t.months] ?? `${t.months} months`}</span>
              <span className={`block tabular-nums ${on ? 'text-brand-100' : 'text-slate-500'}`}>
                {formatPkr(t.amount)}
              </span>
              {t.saving > 0 && (
                <span className={on ? 'text-brand-100' : 'text-money-700'}>
                  save {formatPkr(t.saving)}
                </span>
              )}
            </button>
          )
        })}
      </div>
      {/* SAID BEFORE IT IS PRESSED, not after. A school switching from monthly
          to yearly halfway through a paid month would otherwise wonder whether
          it has just been billed for a year on top of what it already paid. */}
      <p className="mt-1.5 text-xs text-slate-400">
        Applies to your next payment. The period you have already paid for is
        unchanged.
      </p>
      {err && <p className="mt-1 text-xs text-danger-700">{err}</p>}
    </div>
  )
}

/**
 * How the money will get here.
 *
 * There is no card form on this screen and that is not an omission. There is no
 * merchant account yet, and a card form that collected a number and had nowhere
 * to send it would be the single worst thing in this product. When card
 * payments are live this block gains a second option; until then it says what
 * it can actually do.
 */
function MethodBlock({ n, editing, setEditing, onDone }: {
  n: NextPayment; editing: boolean; setEditing: (v: boolean) => void; onDone: () => void
}) {
  const [label, setLabel] = useState(n.method?.label ?? '')
  const [instr, setInstr] = useState(n.method?.instructions ?? '')
  const [err, setErr] = useState<string | null>(null)
  const save = useMutation({
    mutationFn: () => setManualPaymentMethod(label, instr.trim() || null),
    onSuccess: () => { setErr(null); setEditing(false); onDone() },
    onError: (e) => setErr((e as Error).message),
  })

  const m = n.method
  return (
    <div>
      <div className="text-xs font-semibold uppercase tracking-wide text-slate-500">
        How you will pay
      </div>

      {!editing && m && (
        <div className="mt-2 text-sm">
          <div className="font-medium text-slate-800">
            {m.kind === 'card' && m.last4
              ? `${m.brand ?? 'Card'} ending ${m.last4}`
              : m.label || 'Recorded'}
          </div>
          {m.instructions && <div className="text-xs text-slate-500">{m.instructions}</div>}
          {/* THE FACT THAT MATTERS MOST ON THIS PANEL. A school that has
              "set up payment" and thinks it is on autopilot is a school that
              gets locked out feeling wronged.

              Suppressed when the subscription is ending: promising to remind
              somebody before a payment that will never be taken is a promise
              about nothing, and it read as though the cancellation had not
              registered. */}
          {!n.cancel_at_period_end && (
            <div className={`mt-1 text-xs ${n.auto_renew ? 'text-money-700' : 'text-due-800'}`}>
              {n.auto_renew
                ? 'Renews automatically on the date above.'
                : 'Nothing is taken automatically. You send the payment and we match it '
                  + 'against your invoice. We will remind you before it is due.'}
            </div>
          )}
          <button onClick={() => setEditing(true)}
            className="mt-1.5 text-xs text-brand-700 hover:underline">
            Change
          </button>
        </div>
      )}

      {!editing && !m && (
        <div className="mt-2 text-sm">
          <p className="text-slate-600">
            Not set yet. Tell us where the payment will come from and we can match it
            when it arrives.
          </p>
          <button onClick={() => setEditing(true)}
            className="mt-1.5 rounded border border-brand-200 bg-white px-2.5 py-1.5 text-xs font-medium text-brand-800 hover:bg-brand-100">
            Tell us how you will pay
          </button>
        </div>
      )}

      {editing && (
        <div className="mt-2 space-y-2">
          <label className="block">
            <span className="text-xs text-slate-600">Where it will come from</span>
            <input value={label} onChange={(e) => setLabel(e.target.value)}
              placeholder="e.g. HBL current account, or Easypaisa"
              className={`${FIELD} mt-1`} />
          </label>
          <label className="block">
            <span className="text-xs text-slate-600">Anything that helps us match it</span>
            <input value={instr} onChange={(e) => setInstr(e.target.value)}
              placeholder="e.g. sent from 0300-1234567, reference SCHOOL-AQ"
              className={`${FIELD} mt-1`} />
          </label>
          {/* Said in the school's interest, not ours. The tripwire in the
              database refuses a card number here, and a school that had one
              refused with no explanation would assume the form was broken. */}
          <p className="text-xs text-slate-400">
            Please do not put a card number here. We have no way to charge a card
            yet, and this field is only so we can recognise your transfer.
          </p>
          {err && <p className="text-xs text-danger-700">{err}</p>}
          <div className="flex gap-2">
            <button onClick={() => save.mutate()}
              disabled={save.isPending || label.trim() === ''}
              className="rounded bg-brand-600 px-3 py-1.5 text-xs font-medium text-white hover:bg-brand-700 disabled:opacity-60">
              {save.isPending ? 'Saving…' : 'Save'}
            </button>
            <button onClick={() => { setEditing(false); setErr(null) }}
              className="rounded border border-slate-300 px-3 py-1.5 text-xs hover:bg-slate-50">
              Cancel
            </button>
          </div>
        </div>
      )}
    </div>
  )
}

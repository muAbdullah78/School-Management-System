import { useState } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import {
  cancelMySubscription, chooseTerm, myNextPayment, resumeMySubscription,
  setManualPaymentMethod, type NextPayment,
} from '@/lib/db'
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

      <LeaveOrStay n={n} onDone={refresh} />
    </section>
  )
}

/**
 * Leaving, and changing your mind.
 *
 * AT THE BOTTOM, IN SMALL TEXT, AND NOT HIDDEN. Two failure modes to avoid and
 * they pull in opposite directions: a cancel link given the same weight as the
 * plan chooser invites an accidental press, and a cancellation buried behind a
 * support email is the thing that makes people distrust a subscription before
 * they have even started one. So it is quiet, it is here, and it takes two
 * presses.
 *
 * The confirmation says what the school KEEPS rather than warning it what it
 * loses, because the fear that stops people cancelling is not knowing whether
 * their records go with it. They do not: nothing is deleted, the software runs
 * to the date already paid for, and the export button stays.
 */
function LeaveOrStay({ n, onDone }: { n: NextPayment; onDone: () => void }) {
  const [asking, setAsking] = useState(false)
  const [reason, setReason] = useState('')
  const [err, setErr] = useState<string | null>(null)

  const leave = useMutation({
    mutationFn: () => cancelMySubscription(reason.trim() || null),
    onSuccess: () => { setErr(null); setAsking(false); onDone() },
    onError: (e) => setErr((e as Error).message),
  })
  const stay = useMutation({
    mutationFn: () => resumeMySubscription(),
    onSuccess: () => { setErr(null); onDone() },
    onError: (e) => setErr((e as Error).message),
  })

  // Already ending: the only thing to offer is the way back, and only while the
  // period is still running. Afterwards it is a purchase, not an undo, and the
  // database refuses it.
  if (n.cancel_at_period_end) {
    const stillRunning = !!n.period_end && n.period_end >= new Date().toISOString().slice(0, 10)
    return (
      <div className="mt-3 border-t border-slate-200/70 pt-3">
        {err && <p className="mb-1 text-xs text-danger-700">{err}</p>}
        {stillRunning ? (
          <p className="text-xs text-slate-500">
            Your subscription is set to end.{' '}
            <button onClick={() => stay.mutate()} disabled={stay.isPending}
              className="font-medium text-brand-700 hover:underline disabled:opacity-60">
              {stay.isPending ? 'Restarting…' : 'Carry on instead'}
            </button>
          </p>
        ) : (
          <p className="text-xs text-slate-500">
            Your subscription has ended. Choose a plan above to start again;
            everything is exactly where you left it.
          </p>
        )}
      </div>
    )
  }

  if (!asking) {
    return (
      <div className="mt-3 border-t border-slate-200/70 pt-3">
        <button onClick={() => setAsking(true)}
          className="text-xs text-slate-400 hover:text-slate-700 hover:underline">
          Cancel my subscription
        </button>
      </div>
    )
  }

  return (
    <div className="mt-3 rounded border border-slate-200 bg-white p-3">
      <p className="text-sm font-medium text-slate-800">
        Stop at the end of what you have already paid for?
      </p>
      {/* WHAT THEY KEEP, not what they lose. */}
      <ul className="mt-1.5 space-y-0.5 text-xs text-slate-600">
        <li>
          The software keeps working until{' '}
          <span className="font-medium">{n.period_end ?? n.trial_ends_on ?? 'your paid date'}</span>.
          Nothing stops today.
        </li>
        <li>Nothing is deleted. Every pupil, payment and result stays exactly as it is.</li>
        <li>You can download all of your records at any time, including afterwards.</li>
        <li>You can carry on instead, from this screen, before that date.</li>
      </ul>
      <label className="mt-2 block">
        <span className="text-xs text-slate-600">
          If you have a moment, what made you decide? It is optional.
        </span>
        <input value={reason} onChange={(e) => setReason(e.target.value)}
          placeholder="e.g. too expensive for our size"
          className={`${FIELD} mt-1`} />
      </label>
      {err && <p className="mt-1 text-xs text-danger-700">{err}</p>}
      <div className="mt-2 flex flex-wrap gap-2">
        <button onClick={() => leave.mutate()} disabled={leave.isPending}
          className="rounded border border-danger-200 bg-danger-50 px-3 py-1.5 text-xs font-medium text-danger-800 hover:bg-danger-100 disabled:opacity-60">
          {leave.isPending ? 'Cancelling…' : 'Yes, cancel at the end'}
        </button>
        <button onClick={() => { setAsking(false); setErr(null) }}
          className="rounded border border-slate-300 px-3 py-1.5 text-xs hover:bg-slate-50">
          Keep my subscription
        </button>
      </div>
    </div>
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
      {/* A TERM NO BUTTON REPRESENTS. fn_choose_term sells three; an operator
          can invoice any number of months from 1 to 60, and since 0127
          activating a subscription records the term it invoiced. So a school
          can legitimately be on six months, and before this line none of the
          three buttons lit up and the screen said nothing about why. */}
      {!rows.some((t) => t.months === current) && (
        <p className="mt-1.5 text-xs text-slate-600">
          You are on a {current} month term, arranged with us. Pressing one of
          these moves you onto the price list from your next payment.
        </p>
      )}
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

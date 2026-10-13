import { useState } from 'react'
import { Link, Navigate } from 'react-router-dom'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useAuth } from '@/auth/AuthProvider'
import { useSchoolName } from '@/hooks/useSchoolName'
import { chooseTerm, myNextPayment } from '@/lib/db'
import { formatPkr } from '@/lib/licence'
import { lockedSentence, type SubscriptionView, type Term } from '@/lib/subscription'
import { TERM_LABEL, termSentence } from '@/lib/plans'
import { fmtDate } from '@/lib/format'
import { PRODUCT_NAME } from '@/lib/config'
import { Button, LoadError, buttonClass } from '@/components/ui'

const CARD = 'rounded-2xl border border-slate-200 bg-white p-4 shadow-card sm:p-5'
const HEAD = 'text-xs font-semibold uppercase tracking-wide text-slate-500'
const SUBSCRIPTION = '/settings?tab=subscription'

/**
 * Your plan: what the school is on, what it costs, and how often it pays.
 *
 * IT NO LONGER LETS A SCHOOL PICK A PLAN, and that is the owner's decision in
 * 0155 rather than a missing feature. The plan follows the roll: the school
 * says how many pupils it has at signup and lands on Starter, Growth or
 * Enterprise. After that, plans move only by us, because a move changes the
 * pupil limit under a school that has already entered its pupils, and the
 * database refuses a school that asks for anything but its own plan. So this
 * screen shows the plan, and points at Settings, Subscription for asking to
 * move up or for more room on it.
 *
 * WHAT IT STILL CHANGES is the term: one month, three months or a year. The
 * three boxes are the school's own figures from fn__subscription_view, its
 * discount code already taken off, which is what the next invoice will say.
 * Choosing a term reissues an invoice nobody has started paying, and the reply
 * from the database says which invoice the change reaches.
 *
 * AN ENTERPRISE SCHOOL WITH NO PRICE has no figures to show and is told what
 * happens instead: we agree the price, and if that has not happened by the end
 * of the trial, new entries pause until it does.
 *
 * OWNER AND PRINCIPAL ONLY. Anybody else is sent to the dashboard: a teacher
 * has no business seeing what the school is charged. The database refuses the
 * reads and the term change to them anyway; this is the courtesy layer.
 *
 * OUTSIDE LicenceGate ON PURPOSE (see App.tsx). A locked school can still see
 * its plan and set its term, which changes what it is about to be invoiced.
 */
export function ChoosePlan() {
  const { profile } = useAuth()
  const leader = profile?.role === 'owner' || profile?.role === 'principal'
  const schoolName = useSchoolName()
  const q = useQuery({ queryKey: ['myNextPayment'], queryFn: myNextPayment, enabled: leader })

  if (!leader) return <Navigate to="/" replace />

  const view = q.data?.has_subscription ? (q.data.view ?? null) : null

  return (
    <div className="min-h-full bg-slate-50">
      <header className="border-b border-slate-200 bg-white">
        <div className="mx-auto flex h-16 max-w-3xl items-center justify-between gap-3 px-4 sm:px-6">
          <span className="truncate text-[15px] font-semibold tracking-[-0.01em] text-slate-900">
            {schoolName || PRODUCT_NAME}
          </span>
          <Link to="/" className={buttonClass({ variant: 'ghost', size: 'sm', className: 'shrink-0' })}>
            Back to the app
          </Link>
        </div>
      </header>

      <main className="mx-auto max-w-3xl space-y-4 px-4 py-8 sm:px-6">
        <h1 className="text-2xl font-semibold tracking-[-0.015em] text-slate-900">Your plan</h1>

        {q.isLoading && <div className="h-40 animate-pulse rounded-2xl bg-slate-100" />}

        {/* A PRICE THAT DID NOT LOAD MUST NOT BE DRAWN AS A PRICE. The first
            version of this screen drew "Rs 0" for a failed read. */}
        {q.isError && (
          <div>
            <LoadError of={[q]} what="Your plan and its price" />
            <Button variant="soft" tone="neutral" onClick={() => void q.refetch()}>Try again</Button>
          </div>
        )}

        {q.isSuccess && !q.data?.has_subscription && (
          <p className={`${CARD} text-sm text-slate-600`}>
            No subscription is set up for this school yet. Please contact us to start one.
          </p>
        )}

        {/* A database without bundle 56 answers with the old keys only. */}
        {q.isSuccess && q.data?.has_subscription && !view && (
          <p className={`${CARD} text-sm text-slate-600`}>
            You are on {q.data.plan_name ?? 'your plan'}. The full details are in{' '}
            <Link to={SUBSCRIPTION} className="font-medium text-brand-700 underline underline-offset-2">Settings, Subscription</Link>.
          </p>
        )}

        {view && (
          <>
            <PlanCard v={view} />
            {view.needs_price
              ? <WaitingForPrice v={view} />
              : view.price.priced && view.terms.length > 0 && !view.cancel_at_period_end
                && view.status !== 'cancelled' && <TermChooser v={view} />}
            {view.plan.student_limit !== null && <MoreRoom />}
          </>
        )}
      </main>
    </div>
  )
}

function PlanCard({ v }: { v: SubscriptionView }) {
  const s = v.students
  const locked = v.status === 'locked' || v.status === 'cancelled'
  return (
    <section className={CARD}>
      <div className={HEAD}>You are on</div>
      <div className="mt-0.5 text-xl font-semibold text-slate-900">{v.plan.name}</div>
      <p className="mt-1 text-sm text-slate-600">
        {v.plan.student_limit === null
          ? 'No pupil limit.'
          : `Up to ${v.plan.student_limit.toLocaleString('en-PK')} pupils.`}{' '}
        {s.count.toLocaleString('en-PK')} on your roll now.
      </p>
      {s.extra_until && s.limit !== null && (
        <p className="mt-1 text-sm text-slate-600">
          We have given you room for {s.limit.toLocaleString('en-PK')} pupils until {fmtDate(s.extra_until)}.
          After that your plan&rsquo;s own limit applies again.
        </p>
      )}
      <p className="mt-1 text-sm text-slate-600">
        {v.price.priced && v.price.month !== null
          ? <>{v.price.agreed ? 'Price agreed with you: ' : ''}<span className="font-medium text-slate-900">{formatPkr(v.price.month)}</span> a month before any saving.</>
          : 'Price to be agreed with you.'}
      </p>

      {locked ? (
        <div className="mt-3 rounded-xl border border-danger-200 bg-danger-50 px-3 py-2 text-sm text-danger-900">
          <p>{lockedSentence(v) ?? 'New entries are paused.'}</p>
          <Link to="/" className="mt-1 inline-block font-medium underline underline-offset-2">
            See what to pay and where
          </Link>
        </div>
      ) : (
        <p className="mt-3 text-sm text-slate-700">{whereYouStand(v)}</p>
      )}
    </section>
  )
}

/** One sentence on what the school has, by the 0155 rules. */
function whereYouStand(v: SubscriptionView): string {
  if (v.status === 'grace') {
    return `Your ${v.in_trial ? 'free trial' : 'paid period'} has ended. New entries are paused from `
      + `${fmtDate(v.locks_on)} unless a payment reaches us before then.`
  }
  if (v.in_trial && v.trial_ends_on) return `Free trial until ${fmtDate(v.trial_ends_on)}.`
  if (v.paid_through) return `Paid up to ${fmtDate(v.paid_through)}.`
  return ''
}

function months(n: number): string {
  return n === 1 ? 'one month' : n === 12 ? 'a year' : `${n} months`
}

/**
 * Monthly, three months or a year, as three boxes, and a button that says what
 * it will do. A tap selects; nothing changes until the button is pressed, so a
 * thumb brushing "Yearly" on a phone does not put a monthly school on a yearly
 * invoice.
 */
function TermChooser({ v }: { v: SubscriptionView }) {
  const qc = useQueryClient()
  const [pick, setPick] = useState<Term>(v.term_months)
  const [said, setSaid] = useState<string | null>(null)
  const save = useMutation({
    mutationFn: (m: Term) => chooseTerm(m),
    onSuccess: (r) => {
      setSaid(r.changed === false
        ? 'That is already how often you pay.'
        : `Saved. You now pay ${termSentence(r.term_months)}, from ${r.applies_from ?? 'your next invoice'}.`)
      for (const k of ['myNextPayment', 'myBilling', 'licence']) void qc.invalidateQueries({ queryKey: [k] })
    },
  })
  const chosen = v.terms.find((t) => t.months === pick) ?? null

  return (
    <section className={CARD}>
      <fieldset>
        <legend className={HEAD}>How often you pay</legend>
        <p className="mt-1 text-sm text-slate-600">
          What each invoice would say, any code you have already taken off. Every invoice is due on
          the first day of the time it pays for.
        </p>
        <div className="mt-3 grid gap-2 sm:grid-cols-3">
          {v.terms.map((t) => {
            const on = t.months === pick
            return (
              <label key={t.months}
                className={`cursor-pointer rounded-xl border p-3 text-left transition has-[:focus-visible]:ring-2 has-[:focus-visible]:ring-brand-500 has-[:focus-visible]:ring-offset-1 ${
                  on ? 'border-brand-600 bg-brand-600 text-white'
                     : 'border-slate-200 bg-white text-slate-700 hover:border-slate-300'}`}>
                <input type="radio" name="term" value={t.months} checked={on}
                  onChange={() => { setPick(t.months); setSaid(null); save.reset() }} className="sr-only" />
                <span className="flex items-baseline justify-between gap-2">
                  <span className="text-sm font-semibold">{TERM_LABEL[t.months]}</span>
                  {t.chosen && (
                    <span className={`text-xs ${on ? 'text-brand-100' : 'text-slate-500'}`}>now</span>
                  )}
                </span>
                <span className={`block text-base font-semibold tabular-nums ${on ? 'text-white' : 'text-slate-900'}`}>
                  {formatPkr(t.amount)}
                </span>
                {t.saving > 0 && (
                  <span className={`block text-xs ${on ? 'text-brand-100' : 'text-money-700'}`}>
                    save {formatPkr(t.saving)}
                  </span>
                )}
                {t.discount_amount > 0 && (
                  <span className={`block text-xs ${on ? 'text-brand-100' : 'text-slate-500'}`}>
                    includes {formatPkr(t.discount_amount)} off with your code
                  </span>
                )}
                {t.discount_note && (
                  <span className={`mt-1 block text-xs ${on ? 'text-brand-100' : 'text-due-800'}`}>{t.discount_note}</span>
                )}
              </label>
            )
          })}
        </div>
      </fieldset>

      {pick !== v.term_months && chosen && (
        <div className="mt-4 flex flex-col gap-2 sm:flex-row sm:items-center">
          <Button onClick={() => save.mutate(pick)} disabled={save.isPending} className="w-full sm:w-auto">
            {save.isPending ? 'Saving…' : `Pay ${termSentence(pick)}: ${formatPkr(chosen.amount)} for ${months(pick)}`}
          </Button>
          <span className="text-xs text-slate-500">
            Nothing is charged today. An invoice you have not started paying is made again for the new term.
          </span>
        </div>
      )}
      {said && <p role="status" className="mt-3 rounded-xl bg-money-50 px-3 py-2 text-sm text-money-900">{said}</p>}
      {save.error && (
        <p role="alert" className="mt-3 rounded-xl bg-danger-50 px-3 py-2 text-sm text-danger-800">
          {(save.error as Error).message}
        </p>
      )}
    </section>
  )
}

function WaitingForPrice({ v }: { v: SubscriptionView }) {
  return (
    <section className={`${CARD} border-info-200 bg-info-50/40`}>
      <div className={HEAD}>Waiting for your price</div>
      <p className="mt-1 text-sm text-slate-800">
        We agree a monthly price with you; three months is 10% off and a year is two months free.
      </p>
      {v.in_trial && v.trial_ends_on && v.status === 'trialing' && (
        <p className="mt-2 text-sm text-slate-700">
          Your free trial runs until {fmtDate(v.trial_ends_on)}. If your price is not agreed by then,
          new entries are paused until it is. We will call you before then.
        </p>
      )}
      <p className="mt-2 text-sm text-slate-700">
        Nothing is invoiced until the price is set. Once it is, you choose how often to pay here.
      </p>
    </section>
  )
}

function MoreRoom() {
  return (
    <section className={CARD}>
      <div className={HEAD}>More room, or a bigger plan</div>
      <p className="mt-1 text-sm text-slate-600">
        Plans are moved by us, so nothing you have entered is ever caught out. Ask from Settings,
        Subscription: say how many pupils you have and we will tell you what, if anything, it costs.
        A discount code goes in there too.
      </p>
      <Link to={SUBSCRIPTION} className={buttonClass({ variant: 'soft', className: 'mt-3' })}>
        Open Settings, Subscription
      </Link>
    </section>
  )
}

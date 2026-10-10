/**
 * Not a unit test - a rendering harness for the "what happens next" panel.
 *
 * The thing being judged cannot be asserted: whether a school reading this on
 * day one of a trial understands that the software will stop, when, and for how
 * much. The failure modes are all about wording and emphasis, and the most
 * dangerous one is a panel that reads as reassuring to a school which nothing
 * can actually charge.
 *
 * Since 0155 the panel reads one thing, the subscription view, so each case is
 * a view as fn__subscription_view returns it. Six states, because the panel
 * says something different in each: a trial, a trial with a code, an open
 * invoice, an overdue one, Enterprise before its price, and an ending.
 *
 * Run with `npm run harness`.
 */
import { it } from 'vitest'
import { NextPaymentPanel } from '../src/pages/settings/NextPayment'
import type { NextPayment } from '../src/lib/db'
import type { Quote, SubscriptionView, TermOption } from '../src/lib/subscription'
import { writePage } from './harness'

/** The three Starter terms as the view prices them, no code. */
const TERMS: TermOption[] = [
  { months: 1, term_price: 2000, amount: 2000, per_month: 2000, saving: 0, discount_amount: 0, discount_note: null, chosen: true },
  { months: 3, term_price: 5400, amount: 5400, per_month: 1800, saving: 600, discount_amount: 0, discount_note: null, chosen: false },
  { months: 12, term_price: 20000, amount: 20000, per_month: 1667, saving: 4000, discount_amount: 0, discount_note: null, chosen: false },
]

const QUOTE: Quote = {
  priced: true, plan_code: 'starter', plan_name: 'Starter', by_arrangement: false, months: 1,
  period_start: '2026-10-23', period_end: '2026-11-22', month_price: 2000, list_amount: 2000,
  term_price: 2000, term_saving: 0, discount: null, discount_note: null, discount_amount: 0, amount: 2000,
}

const base: SubscriptionView = {
  plan: { code: 'starter', name: 'Starter', by_arrangement: false, student_limit: 280, min_students: 1 },
  price: {
    priced: true, month: 2000, quarter: 5400, year: 20000, agreed: false, agreed_at: null,
    agreed_reason: null, quarter_set: false, year_set: false,
  },
  terms: TERMS, term_months: 1, status: 'trialing', stored_status: 'trialing', in_trial: true,
  trial_ends_on: '2026-10-22', paid_from: null, paid_through: null, covered_to: '2026-10-22',
  grace_days: 14, locks_on: '2026-11-06', days_to_lock: 28, locked_because: null, needs_price: false,
  cancel_at_period_end: false, suspended: false, suspend_reason: null,
  students: {
    count: 212, limit: 280, plan_limit: 280, extra: null, extra_until: null, extra_reason: null,
    extra_expired: false, declared: 220, room: 68, warn: false, full: false, over: false,
  },
  open_invoice: null, owed: 0, credit: 0,
  next: { period_start: '2026-10-23', months: 1, quote: QUOTE },
  pay_now: 2000, can_request_invoice: true,
}
const v = (p: Partial<SubscriptionView>): SubscriptionView => ({ ...base, ...p })
const next = (view: SubscriptionView): NextPayment => ({
  has_subscription: true, plan_code: view.plan.code, plan_name: view.plan.name,
  term_months: view.term_months, status: view.status, in_trial: view.in_trial,
  trial_ends_on: view.trial_ends_on, period_end: view.paid_through,
  auto_renew: false, cancel_at_period_end: view.cancel_at_period_end, method: null,
  terms: view.terms, view,
})
const panel = <div className="mx-auto max-w-3xl p-4"><NextPaymentPanel /></div>

it('renders what happens next, in every state it has to explain', () => {
  writePage('../scratch/next-payment.html', [
    {
      caption: 'Day one of a trial, paying monthly. The quote is itemised and the lock date is a date, '
        + 'not a promise of a charge nothing can make.',
      node: panel,
      seeds: [[['myNextPayment'], next(base)]],
    },
    {
      caption: 'A trial on the yearly term with a code: list price, the saving for paying a year at once, '
        + 'the code\'s saving and the amount, each on its own line.',
      node: panel,
      seeds: [[['myNextPayment'], next(v({
        term_months: 12,
        terms: TERMS.map((t) => t.months === 12
          ? { ...t, amount: 18000, per_month: 1500, saving: 6000, discount_amount: 2000, chosen: true }
          : t.months === 1 ? { ...t, chosen: false, discount_note: 'Code GROW10 needs paying for 12 months or more at a time, so it does not apply to a 1-month invoice.' }
            : { ...t, discount_note: 'Code GROW10 needs paying for 12 months or more at a time, so it does not apply to a 3-month invoice.' }),
        next: {
          period_start: '2026-10-23', months: 12,
          quote: {
            ...QUOTE, months: 12, period_end: '2027-10-22', list_amount: 24000, term_price: 20000,
            term_saving: 4000, discount_amount: 2000, amount: 18000,
            discount: { code: 'GROW10', label: 'Ten percent for a year', kind: 'percent', value: 10,
              months_covered: 12, amount: 2000, granted_by_kind: 'school' },
          },
        },
        pay_now: 18000,
      }))]],
    },
    {
      caption: 'Active, monthly, with the invoice open and three days to its due date.',
      node: panel,
      seeds: [[['myNextPayment'], next(v({
        status: 'active', stored_status: 'active', in_trial: false, trial_ends_on: '2026-08-21',
        paid_from: '2026-09-13', paid_through: '2026-10-12', covered_to: '2026-10-12',
        locks_on: '2026-10-27', days_to_lock: 17, next: null, can_request_invoice: false,
        open_invoice: {
          id: 'inv3', doc_no: 'INV-2026-0142', months: 1, period_start: '2026-10-13', period_end: '2026-11-12',
          amount: 2000, total: 2000, paid: 0, owed: 2000, due_on: '2026-10-13',
          discount_code: null, discount_amount: 0,
        },
        owed: 2000, pay_now: 2000,
      }))]],
    },
    {
      caption: 'Overdue and in its grace: the invoice is half paid, and the lock is five days away.',
      node: panel,
      seeds: [[['myNextPayment'], next(v({
        status: 'grace', stored_status: 'active', in_trial: false, trial_ends_on: '2026-07-20',
        paid_from: '2026-07-21', paid_through: '2026-09-30', covered_to: '2026-09-30',
        locks_on: '2026-10-15', days_to_lock: 5, next: null, can_request_invoice: false,
        open_invoice: {
          id: 'inv4', doc_no: 'INV-2026-0150', months: 3, period_start: '2026-10-01', period_end: '2026-12-31',
          amount: 5400, total: 5400, paid: 2000, owed: 3400, due_on: '2026-10-01',
          discount_code: null, discount_amount: 0,
        },
        term_months: 3, terms: TERMS.map((t) => ({ ...t, chosen: t.months === 3 })),
        owed: 3400, pay_now: 3400,
      }))]],
    },
    {
      caption: 'Enterprise before its price is agreed: no figure anywhere, no term boxes, and the lock '
        + 'is the day after the trial, said plainly.',
      node: panel,
      seeds: [[['myNextPayment'], next(v({
        plan: { code: 'enterprise', name: 'Enterprise', by_arrangement: true, student_limit: null, min_students: 1001 },
        price: { ...base.price, priced: false, month: null, quarter: null, year: null },
        terms: [], needs_price: true, locks_on: '2026-10-23', days_to_lock: 13, next: null,
        pay_now: 0, can_request_invoice: false,
        students: { ...base.students, count: 1460, limit: null, plan_limit: null, room: null, declared: 1500 },
      }))]],
    },
    {
      caption: 'Cancelled at period end. An ending, stated plainly, rather than a charge of Rs 0 which a '
        + 'screen renders as "free".',
      node: panel,
      seeds: [[['myNextPayment'], next(v({
        status: 'active', stored_status: 'active', in_trial: false, trial_ends_on: '2026-03-14',
        paid_through: '2026-12-31', covered_to: '2026-12-31', cancel_at_period_end: true,
        locks_on: '2027-01-15', days_to_lock: 97, next: null, pay_now: 0, can_request_invoice: false,
        term_months: 3,
      }))]],
    },
  ], { bodyStyle: 'background:#f1f5f9;margin:0' })
})

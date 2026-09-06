/**
 * Not a unit test - a rendering harness for the "what happens next" panel.
 *
 * The thing being judged cannot be asserted: whether a school reading this on
 * day one of a trial understands that the software will stop, when, and for how
 * much. The failure modes are all about wording and emphasis, and the most
 * dangerous one is a panel that reads as reassuring to a school which nothing
 * can actually charge.
 *
 * Five states, because the panel says something different in each and the one
 * most likely to be got wrong is the third.
 *
 * Run with `npm run harness`.
 */
import { it } from 'vitest'
import { NextPaymentPanel } from '../src/pages/settings/NextPayment'
import type { NextPayment } from '../src/lib/db'
import { writePage } from './harness'

const base: NextPayment = {
  has_subscription: true,
  plan_code: 'starter', plan_name: 'Starter (up to 150 students)',
  term_months: 12, status: 'trialing', in_trial: true,
  trial_ends_on: '2026-09-20', period_end: null,
  next_charge_on: '2026-09-20', next_charge_amount: 20000,
  auto_renew: false, cancel_at_period_end: false, method: null,
  // The real figures, as fn_my_next_payment returns them for Starter.
  terms: [
    { months: 1, amount: 2000, saving: 0, chosen: false },
    { months: 3, amount: 5700, saving: 300, chosen: false },
    { months: 12, amount: 20000, saving: 4000, chosen: true },
  ],
  sentence: 'Your free trial ends on 20 Sep 2026. To keep going, Rs 20,000 is due '
    + 'by then. You are charged nothing today.',
}
const s = (p: Partial<NextPayment>): NextPayment => ({ ...base, ...p })

it('renders what happens next, in every state it has to explain', () => {
  writePage('../scratch/next-payment.html', [
    {
      caption: 'Day one of a trial, no payment method yet. The commonest state a new '
        + 'customer is in, and the one this screen could not describe at all: the '
        + 'trial simply ended and the software stopped.',
      profile: null,
      node: <div className="mx-auto max-w-3xl p-4"><NextPaymentPanel /></div>,
      seeds: [[['myNextPayment'], s({})]],
    },
    {
      caption: 'A trial with a bank transfer recorded. Note what it does NOT say: '
        + 'nothing here promises a charge, because nothing can make one.',
      profile: null,
      node: <div className="mx-auto max-w-3xl p-4"><NextPaymentPanel /></div>,
      seeds: [[['myNextPayment'], s({
        method: { id: 'm1', kind: 'manual', brand: null, last4: null,
                  label: 'HBL current account',
                  instructions: 'sent from 0300-1234567, reference SCHOOL-AQ',
                  status: 'active' },
      })]],
    },
    {
      caption: 'The state that matters most: a saved card, so renewal really is '
        + 'automatic and the wording changes from "is due by" to "will be '
        + 'charged". Getting this the wrong way round is how a school that '
        + 'cannot be charged relaxes and gets locked out.',
      profile: null,
      node: <div className="mx-auto max-w-3xl p-4"><NextPaymentPanel /></div>,
      seeds: [[['myNextPayment'], s({
        in_trial: false, status: 'active', trial_ends_on: null,
        period_end: '2027-06-30', next_charge_on: '2027-07-01',
        auto_renew: true, term_months: 12,
        method: { id: 'm2', kind: 'card', brand: 'Visa', last4: '4242',
                  label: null, instructions: null, status: 'active' },
        sentence: 'Rs 20,000 will be charged on 1 Jul 2027.',
      })]],
    },
    {
      caption: 'On the monthly term, three days out, paying by transfer. The '
        + 'countdown is the point: a date alone makes the reader do arithmetic.',
      profile: null,
      node: <div className="mx-auto max-w-3xl p-4"><NextPaymentPanel /></div>,
      seeds: [[['myNextPayment'], s({
        in_trial: false, status: 'active', trial_ends_on: null, term_months: 1,
        period_end: '2026-09-08', next_charge_on: '2026-09-09',
        next_charge_amount: 2000,
        terms: [
          { months: 1, amount: 2000, saving: 0, chosen: true },
          { months: 3, amount: 5700, saving: 300, chosen: false },
          { months: 12, amount: 20000, saving: 4000, chosen: false },
        ],
        method: { id: 'm3', kind: 'manual', brand: null, last4: null,
                  label: 'Easypaisa', instructions: null, status: 'active' },
        sentence: 'Rs 2,000 is due by 9 Sep 2026.',
      })]],
    },
    {
      caption: 'Cancelled at period end. An ending, stated plainly, rather than a '
        + 'charge of Rs 0 which a screen renders as "free".',
      profile: null,
      node: <div className="mx-auto max-w-3xl p-4"><NextPaymentPanel /></div>,
      seeds: [[['myNextPayment'], s({
        in_trial: false, status: 'active', trial_ends_on: null,
        period_end: '2026-12-31', next_charge_on: null, next_charge_amount: null,
        cancel_at_period_end: true, term_months: 3,
        method: { id: 'm4', kind: 'manual', brand: null, last4: null,
                  label: 'HBL current account', instructions: null, status: 'active' },
        sentence: 'Your subscription ends on 31 Dec 2026. Nothing further will be charged.',
      })]],
    },
  ], { bodyStyle: 'background:#f1f5f9;margin:0' })
})

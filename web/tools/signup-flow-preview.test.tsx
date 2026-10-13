/**
 * The screens a new school sees, in order, at both widths.
 *
 * NOT A UNIT TEST -- a rendering harness. The behaviour is asserted in
 * src/test/pages.smoke.test.tsx; this exists because whether a price reads
 * correctly beside the number that produced it is a question about looking at
 * it. A plan panel with the wrong emphasis, or a first invoice that does not
 * visibly follow from the term picked above it, is confidently wrong in a way
 * no assertion about markup would catch.
 *
 * Since 0155 signup is one screen: the number of pupils sets the plan, and the
 * plan and its price are shown before the account exists. A static render
 * cannot type that number, so each state of the plan panel is rendered on its
 * own beside the empty form.
 *
 * Output: ../scratch/signup/{step1,step1-noregions,step1-plans,plan,step3}.html
 * against the real compiled stylesheet.
 *
 * Excluded from `npm test` by vitest's test.include; run with `npm run harness`.
 */
import { it } from 'vitest'
import { createElement } from 'react'
import { Signup, YourPlan } from '../src/pages/Signup'
import { ChoosePlan } from '../src/pages/ChoosePlan'
import { SetupWizard } from '../src/pages/SetupWizard'
import { planForStudents, type SignupPlan } from '../src/lib/plans'
import { writePage } from './harness'
import type { Profile } from '../src/auth/AuthProvider'

const OWNER: Profile = {
  id: '11111111-1111-1111-1111-111111111111',
  full_name: 'Nasreen Akhtar', role: 'owner',
  staff_id: null, school_id: '22222222-2222-2222-2222-222222222222',
}

const REGIONS = [
  'Punjab', 'Sindh', 'Khyber Pakhtunkhwa', 'Balochistan',
  'Islamabad Capital Territory', 'Azad Jammu and Kashmir', 'Gilgit-Baltistan',
]

/* The shape fn_signup_plans returns since 0155, with the savings it computes.
   Fixtures: the live figures are whatever the database holds. */
const PLANS: SignupPlan[] = [
  { code: 'starter', name: 'Starter', student_limit: 280, min_students: 1, by_arrangement: false,
    month_price: 2000, how_priced: null,
    terms: [{ months: 1, amount: 2000, per_month: 2000, saving: 0 },
            { months: 3, amount: 5400, per_month: 1800, saving: 600 },
            { months: 12, amount: 20000, per_month: 1667, saving: 4000 }] },
  { code: 'growth', name: 'Growth', student_limit: 1000, min_students: 281, by_arrangement: false,
    month_price: 4000, how_priced: null,
    terms: [{ months: 1, amount: 4000, per_month: 4000, saving: 0 },
            { months: 3, amount: 10800, per_month: 3600, saving: 1200 },
            { months: 12, amount: 40000, per_month: 3333, saving: 8000 }] },
  { code: 'enterprise', name: 'Enterprise', student_limit: null, min_students: 1001, by_arrangement: true,
    month_price: null, terms: [],
    how_priced: 'We agree a monthly price with you. Three months is 10% off it and a year is two months free.' },
]

const TERMS = [
  { months: 1 as const, term_price: 2000, amount: 2000, per_month: 2000, saving: 0, discount_amount: 0, discount_note: null, chosen: true },
  { months: 3 as const, term_price: 5400, amount: 5400, per_month: 1800, saving: 600, discount_amount: 0, discount_note: null, chosen: false },
  { months: 12 as const, term_price: 20000, amount: 20000, per_month: 1667, saving: 4000, discount_amount: 0, discount_note: null, chosen: false },
]

const VIEW = {
  plan: { code: 'starter', name: 'Starter', by_arrangement: false, student_limit: 280, min_students: 1 },
  price: { priced: true, month: 2000, quarter: 5400, year: 20000, agreed: false, agreed_at: null,
           agreed_reason: null, quarter_set: false, year_set: false },
  terms: TERMS, term_months: 1, status: 'trialing', stored_status: 'trialing', in_trial: true,
  trial_ends_on: '2026-10-23', paid_from: null, paid_through: null, covered_to: '2026-10-23',
  grace_days: 14, locks_on: '2026-11-07', days_to_lock: 28, locked_because: null, needs_price: false,
  cancel_at_period_end: false, suspended: false, suspend_reason: null,
  students: { count: 212, limit: 280, plan_limit: 280, extra: null, extra_until: null, extra_reason: null,
              extra_expired: false, declared: 220, room: 68, warn: false, full: false, over: false },
  open_invoice: null, owed: 0, credit: 0, next: null, pay_now: 2000, can_request_invoice: true,
}

const LICENCE = {
  ok: true, school_id: OWNER.school_id, status: 'trialing', locked: false,
  can_read: true, can_export: true, can_operate: true,
  plan_code: 'starter', plan_name: 'Starter',
  cycle: 'monthly', price_monthly: 2000, price_yearly: 20000,
  expires_on: '2026-10-23', days_left: 13,
  student_count: 0, student_limit: 280, term_months: 1,
  margin_limit: 280, limit_state: 'ok', limit_notice: null,
}

const seeds = [
  [['signupRegions'], REGIONS],
  [['signupPlans'], PLANS],
  [['licence'], LICENCE],
  [['myNextPayment'], { has_subscription: true, view: VIEW }],
] as [readonly unknown[], unknown][]

it('renders step 1, the details', () => {
  writePage('../scratch/signup/step1.html',
    [{ node: createElement(Signup), seeds, profile: null, route: '/signup' }])
})

/* The state the vendor actually hit: the app deployed, bundle 37 not pasted
   yet, so fn_signup_regions does not answer. The field must be absent rather
   than present and impossible. Seeded with an empty list because a harness
   renders once and cannot fail a query. */
it('renders step 1 with no region list to offer', () => {
  writePage('../scratch/signup/step1-noregions.html',
    [{ node: createElement(Signup),
       seeds: [[['signupRegions'], []], [['signupPlans'], PLANS]],
       profile: null, route: '/signup' }])
})

/* What the number puts the school on, in every state the panel has. */
it('renders the plan panel for each roll', () => {
  const panel = (pupils: number | null, term: 1 | 3 | 12, list = PLANS, failed = false) =>
    createElement('div', { style: { maxWidth: '26rem', margin: '0 auto', background: '#fff', padding: '1rem' } },
      createElement(YourPlan, {
        plans: list, loading: false, failed, pupils,
        plan: pupils === null ? null : planForStudents(list, pupils),
        term, onTerm: () => {},
      }))
  writePage('../scratch/signup/step1-plans.html', [
    { caption: 'NOTHING TYPED YET: the three plans and who each is for.', node: panel(null, 1) },
    { caption: '250 PUPILS: Starter, monthly, the default.', node: panel(250, 1) },
    { caption: '650 PUPILS: Growth, yearly chosen.', node: panel(650, 12) },
    { caption: '1,500 PUPILS: Enterprise, priced with us, and the lock at the trial end said up front.',
      node: panel(1500, 1) },
    { caption: 'THE PRICE LIST DID NOT LOAD: the school can still sign up.',
      node: panel(120, 1, [], true) },
  ])
})

it('renders your plan, after signup', () => {
  writePage('../scratch/signup/plan.html',
    [{ node: createElement(ChoosePlan), seeds, profile: OWNER, route: '/plan' }])
})

it('renders step 3, the school setup', () => {
  writePage('../scratch/signup/step3.html',
    [{ node: createElement(SetupWizard, { onDone: () => {} }),
       seeds, profile: OWNER, route: '/' }],
    // #root is a full-height box in the real app and the wizard fills it.
    { bodyStyle: 'background:#f1f5f9;margin:0' })
})

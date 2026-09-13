/**
 * The three screens a new school sees, in order, at both widths.
 *
 * NOT A UNIT TEST -- a rendering harness. The behaviour is asserted in
 * src/test/pages.smoke.test.tsx; this exists because the second screen is an
 * INVOICE, and whether an invoice reads correctly is a question about looking
 * at it. A panel headed "Upcoming invoice" with the wrong emphasis, or a total
 * that does not visibly follow from the lines above it, is confidently wrong in
 * a way no assertion about markup would catch.
 *
 * Output: ../scratch/signup/{step1,step2,step2-discount,step3}.html against the
 * real compiled stylesheet.
 *
 * Excluded from `npm test` by vitest's test.include; run with `npm run harness`.
 */
import { it } from 'vitest'
import { createElement } from 'react'
import { Signup } from '../src/pages/Signup'
import { ChoosePlan } from '../src/pages/ChoosePlan'
import { SetupWizard } from '../src/pages/SetupWizard'
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

/* The real price list shape, with the savings fn_signup_plans computes. */
const PLANS = [
  { code: 'starter', name: 'Starter (up to 150 students)', student_limit: 150,
    terms: [{ months: 1, amount: 2000, saving: 0 },
            { months: 3, amount: 5700, saving: 300 },
            { months: 12, amount: 20000, saving: 4000 }] },
  { code: 'growth', name: 'Growth (up to 350 students)', student_limit: 350,
    terms: [{ months: 1, amount: 3500, saving: 0 },
            { months: 3, amount: 9975, saving: 525 },
            { months: 12, amount: 35000, saving: 7000 }] },
  { code: 'institution', name: 'Institution (up to 600 students)', student_limit: 600,
    terms: [{ months: 1, amount: 5500, saving: 0 },
            { months: 3, amount: 15675, saving: 825 },
            { months: 12, amount: 55000, saving: 11000 }] },
]

const LICENCE = {
  ok: true, school_id: OWNER.school_id, status: 'trialing', locked: false,
  can_read: true, can_export: true, can_operate: true,
  plan_code: 'starter', plan_name: 'Starter (up to 150 students)',
  cycle: 'monthly', price_monthly: 2000, price_yearly: 20000,
  expires_on: '2026-09-27', days_left: 14,
  student_count: 0, student_limit: 150, term_months: 1,
  margin_limit: 165, limit_state: 'ok', limit_notice: null,
}

const seeds = [
  [['signupRegions'], REGIONS],
  [['signupPlans'], PLANS],
  [['licence'], LICENCE],
] as [readonly unknown[], unknown][]

it('renders step 1, the details', () => {
  writePage('../scratch/signup/step1.html',
    [{ node: createElement(Signup), seeds, profile: null, route: '/signup' }])
})

it('renders step 2, the plan and its invoice', () => {
  writePage('../scratch/signup/step2.html',
    [{ node: createElement(ChoosePlan), seeds, profile: OWNER, route: '/plan' }])
})

it('renders step 3, the school setup', () => {
  writePage('../scratch/signup/step3.html',
    [{ node: createElement(SetupWizard, { onDone: () => {} }),
       seeds, profile: OWNER, route: '/' }],
    // #root is a full-height box in the real app and the wizard fills it.
    { bodyStyle: 'background:#f1f5f9;margin:0' })
})

// @vitest-environment jsdom
/**
 * Mount every screen in the app and fail if any of them throws.
 *
 * WHY THIS EXISTS
 *
 * Because /accounts showed a school a blank white page and nothing in this
 * repository could have known. Until now no test rendered a single page: the
 * 160 unit tests all exercise lib/ in isolation, and the only components any
 * harness rendered were the portal, the dashboard and two auth screens. A page
 * could throw on mount and CI stayed green.
 *
 * WHAT IT COVERS, AND WHAT IT DOES NOT
 *
 * It mounts each screen for real, with effects running and queries resolving
 * through a fake client, in three states:
 *
 *   empty    a brand new school with no data. The commonest state a new
 *            customer is in, and the least tested.
 *   errors   every read fails. Screens must show a message, not explode.
 *   loaded   plausible rows and RPC results.
 *
 * It does NOT prove a screen is correct or that the numbers are right. It
 * proves the screen opens. That is a low bar which this application was not
 * clearing.
 */
import { describe, expect, it, vi, beforeAll, afterEach } from 'vitest'
import { createElement, type ComponentType } from 'react'
import { cleanup, render, waitFor } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { MemoryRouter } from 'react-router-dom'
import { fakeSupabase, type FakeOptions } from './fakeSupabase'
import { AuthContext, type Profile } from '@/auth/AuthProvider'

/**
 * The app must believe it is connected, whether or not this machine has a .env.
 *
 * isConfigured is computed at module load from VITE_SUPABASE_URL. A developer
 * with a local web/.env gets true; CI, which has no such file, gets false, and
 * Dashboard then renders "Supabase isn't configured" instead of running a
 * single query. So this suite passed on my machine and failed on the runner,
 * which is the exact shape of a test that is not testing anything: its result
 * depended on an untracked file.
 *
 * Pinned here rather than by setting env in vite.config, so the unit tests that
 * deliberately exercise the unconfigured path keep doing so.
 */
vi.mock('@/lib/config', async (importOriginal) => ({
  ...(await importOriginal<typeof import('@/lib/config')>()),
  isConfigured: true,
}))

// One mutable holder so each case can swap the client the app sees without
// re-mocking the module (vi.mock is hoisted and cannot close over a test's
// local state).
const current: { opts: FakeOptions } = { opts: {} }
vi.mock('@/lib/supabase', () => ({
  get supabase() { return fakeSupabase(current.opts) },
  isConfigured: true,
  requireSupabase: () => fakeSupabase(current.opts),
}))
vi.mock('./supabase', () => ({
  get supabase() { return fakeSupabase(current.opts) },
  isConfigured: true,
  requireSupabase: () => fakeSupabase(current.opts),
}))

const OWNER: Profile = {
  id: '11111111-1111-1111-1111-111111111111',
  full_name: 'Test Owner', role: 'owner',
  staff_id: null, school_id: '22222222-2222-2222-2222-222222222222',
}

function authValue(profile: Profile) {
  return {
    session: { user: { id: profile.id, email: 'owner@example.test' } } as never,
    profile, loading: false,
    signIn: async () => ({ error: null }),
    signOut: async () => {},
    sendReset: async () => ({ error: null }),
    setPassword: async () => ({ error: null }),
  }
}

/**
 * Uncaught render errors, collected.
 *
 * React reports an error thrown during a re-render to window.onerror rather
 * than propagating it out of render(), so the first version of this file
 * printed "Uncaught TypeError" four times and reported 30 tests PASSED. A
 * checker that prints the failure and calls it a pass is worse than no checker,
 * because it is trusted. Every mount now asserts that nothing reached here.
 */
const uncaught: Error[] = []
function onUncaught(e: ErrorEvent) {
  uncaught.push(e.error ?? new Error(e.message))
  e.preventDefault()
}

async function mount(Comp: ComponentType, route = '/', props: Record<string, unknown> = {}) {
  uncaught.length = 0
  window.addEventListener('error', onUncaught)
  const qc = new QueryClient({
    defaultOptions: { queries: { retry: false, gcTime: 0 }, mutations: { retry: false } },
  })
  const utils = render(
    createElement(MemoryRouter, { initialEntries: [route] },
      createElement(AuthContext.Provider, { value: authValue(OWNER) },
        createElement(QueryClientProvider, { client: qc },
          createElement(Comp as ComponentType<Record<string, unknown>>, props)))),
  )
  // Let every query settle. A screen that crashes only once its data arrives
  // is the exact failure this file exists to catch, so waiting matters more
  // than the initial paint.
  await waitFor(() => expect(qc.isFetching()).toBe(0), { timeout: 4000 })
  // One more tick, so a re-render triggered by the last query settling has
  // happened before we decide nothing threw.
  await new Promise((r) => setTimeout(r, 0))
  window.removeEventListener('error', onUncaught)
  if (uncaught.length) {
    throw new Error(
      `${uncaught.length} uncaught error(s) while rendering: ` +
      uncaught.map((e) => e.message).join(' | '),
    )
  }
  return utils
}

/** Every screen a signed-in school user can reach from the sidebar. */
const SCREENS: [string, () => Promise<Record<string, unknown>>, string][] = [
  ['Dashboard', () => import('@/pages/Dashboard'), 'Dashboard'],
  ['Students', () => import('@/pages/students/StudentsPage'), 'StudentsPage'],
  ['Admissions', () => import('@/pages/admissions/EnquiriesPage'), 'EnquiriesPage'],
  ['Attendance', () => import('@/pages/attendance/AttendancePage'), 'AttendancePage'],
  ['Fees', () => import('@/pages/fees/FeesPage'), 'FeesPage'],
  ['Accounts', () => import('@/pages/accounts/AccountsPage'), 'AccountsPage'],
  ['Staff', () => import('@/pages/staff/StaffPage'), 'StaffPage'],
  ['Birthdays', () => import('@/pages/people/BirthdaysPage'), 'BirthdaysPage'],
  ['Certificates', () => import('@/pages/certificates/CertificatesPage'), 'CertificatesPage'],
  ['Reports', () => import('@/pages/reports/ReportsPage'), 'ReportsPage'],
  ['Settings', () => import('@/pages/SettingsPage'), 'SettingsPage'],
  ['Till', () => import('@/pages/till/TillPage'), 'TillPage'],
  ['Messages', () => import('@/pages/messages/MessagesPage'), 'MessagesPage'],
  // Settings renders its FIRST tab, so the others were never opened by
  // anything. Subscription is the one a school looks at when it is deciding
  // whether to pay.
  ['Settings/Subscription', () => import('@/pages/settings/Subscription'), 'Subscription'],
  ['Settings/Users', () => import('@/pages/settings/Users'), 'Users'],
  ['Settings/Backup', () => import('@/pages/settings/Backup'), 'Backup'],
  ['Settings/StaffCheckin', () => import('@/pages/settings/StaffCheckin'), 'StaffCheckin'],
  ['Feedback', () => import('@/pages/FeedbackPage'), 'FeedbackPage'],
]

/**
 * Screens that need props, so they cannot go in the list above.
 *
 * StudentProfile is the largest page in this application at 84KB and had never
 * been rendered by anything. It is also the one the first real school spent
 * most of its time on, and the one they reported errors from.
 */
describe('screens that take props', () => {
  const CASES: [string, () => Promise<{ default?: unknown; [k: string]: unknown }>, string, Record<string, unknown>][] = [
    ['StudentProfile', () => import('@/pages/students/StudentProfile'), 'StudentProfile',
      { studentId: '33333333-3333-3333-3333-333333333333', onBack: () => {} }],
  ]
  for (const [label, importer, name, props] of CASES) {
    it(`${label}: opens for a school with no data`, async () => {
      current.opts = {}
      const mod = await importer()
      const Comp = (mod[name] ?? mod.default) as ComponentType
      expect(Comp, `${label} has no export named ${name}`).toBeTruthy()
      await mount(Comp, '/', props)
    })
    it(`${label}: says so when every read fails`, async () => {
      current.opts = { failEverything: FAIL_MARKER }
      const mod = await importer()
      const Comp = (mod[name] ?? mod.default) as ComponentType
      const { container } = await mount(Comp, '/', props)
      expect(
        container.textContent ?? '',
        `${label} rendered without showing why its data is missing.`,
      ).toContain(FAIL_MARKER)
    })
  }
})

async function load(entry: typeof SCREENS[number]): Promise<ComponentType | null> {
  const [, importer, name] = entry
  const mod = await importer()
  return (mod[name] ?? mod.default) as ComponentType ?? null
}

afterEach(() => cleanup())

beforeAll(() => {
  // jsdom has neither, and a screen that calls one must not fail for that
  // reason in a test that is looking for real crashes.
  if (!window.matchMedia) {
    // @ts-expect-error test shim
    window.matchMedia = () => ({ matches: false, addEventListener() {}, removeEventListener() {} })
  }
  window.scrollTo = () => {}
})

describe('every screen opens for a brand new school with no data', () => {
  for (const entry of SCREENS) {
    it(entry[0], async () => {
      current.opts = {}
      const Comp = await load(entry)
      expect(Comp, `${entry[0]} has no such export`).toBeTruthy()
      await mount(Comp!)
    })
  }
})

/**
 * A read that FAILED must never be drawn as a read that returned nothing.
 *
 * This is the difference between "you have no expenses this month" and "we
 * could not load your expenses", and on a screen showing a school its own
 * money that difference decides whether a wrong number gets believed. The
 * Accounts expense register showed "Nothing recorded yet" for a failed read:
 * only one of its five queries rendered its error at all.
 *
 * The marker is a string no screen could produce by accident, so a screen
 * passes only by actually putting the reason in front of the user.
 */
const FAIL_MARKER = 'permission denied for table'

describe('a screen says so when its reads fail, rather than looking empty', () => {
  for (const entry of SCREENS) {
    it(entry[0], async () => {
      current.opts = { failEverything: FAIL_MARKER }
      const Comp = await load(entry)
      const { container } = await mount(Comp!)
      expect(
        container.textContent ?? '',
        `${entry[0]} rendered without showing why its data is missing. A failed ` +
        'read that looks like an empty list is how a school comes to trust a ' +
        'number that was never loaded.',
      ).toContain(FAIL_MARKER)
    })
  }
})

/**
 * The shapes a STALE database returns.
 *
 * This project has already been bitten once by a deployment lagging the repo:
 * the create-teacher Edge Function still rejects role 'parent' on the live
 * project because it was deployed before that role was added, and the only
 * symptom is the words "Invalid role" with nothing to say where they came from.
 *
 * A database function can lag the same way. `fn_finance_summary` gained fields
 * over time, and a school that applied bundle 4 but not bundle 6 has an older
 * one installed. The screen trusts the shape completely: `data as FinanceSummary`
 * is a cast, which checks nothing at runtime, and the first `.by_category.length`
 * on a response that has no category list throws during render.
 *
 * These cases pin down what a screen does with a response that is legal JSON
 * and the wrong shape. They must not crash: the screen has to say something.
 *
 * THEY ALSO PROVED THE WRONG THING FOR A WHILE. Every case here is a MALFORMED
 * response, so they all passed while the guard was asking for a key the
 * database had not emitted since 0060 -- the guard fired, the screen said
 * something, the test was happy, and the Accounts screen was broken on every
 * up-to-date school. A suite of failure cases with no success case cannot tell
 * "correctly refuses bad data" from "refuses everything", so the last case
 * below is a GOOD response that must render. The database side is asserted
 * separately, against the real functions, in supabase/tests/accounts_shape.sql.
 */
/**
 * THE OPERATOR CONSOLE HAD NO COVERAGE AT ALL, which is why it is here.
 *
 * It is the screen the business is run from, it renders a customer list with a
 * button on every row that raises an invoice, and nothing in this repository
 * ever mounted it. Two of its screens were rebuilt in this change: the school
 * row went from eleven interactive controls to one plus five grouped links, and
 * the renewals list gained the actions it existed to offer.
 *
 * These are smoke tests and they say so. They prove the screens mount, that the
 * gate holds, and that the +14d control is gone. What they cannot prove is that
 * the layout is legible, which is the thing the redesign was for and is not a
 * thing a test can hold.
 */
describe('the operator console', () => {
  afterEach(cleanup)

  // The names are the RPCs the console actually calls, taken from
  // web/src/lib/platform.ts. The first draft of this guessed them
  // (fn_am_platform_admin, fn_due_soon) and the gate test passed for the wrong
  // reason: every stub missed, is_platform_admin came back undefined, and the
  // page correctly showed "for the system operator" -- which is what the test
  // asserting the refusal was looking for.
  const ADMIN_RPCS: Record<string, unknown> = {
    is_platform_admin: true,
    fn_platform_schools: [],
    fn_platform_revenue: {
      net_invoiced: 0, collected: 0, cash_received: 0, tax_withheld: 0,
      discounted: 0, outstanding_total: 0, voided: 0,
      tax_certificates_awaited: 0, schools_owing: [],
    },
    fn_platform_schema_state: { applied_count: 40, latest: '0107_x.sql', gaps: [], gaps_total: 0 },
    fn_platform_due_soon: [],
    fn_platform_payment_claims: [],
    fn_platform_settings: { missing: [] },
    fn_platform_orphan_report: [],
  }

  it('refuses anybody who is not the operator', async () => {
    current.opts = { rpc: { ...ADMIN_RPCS, is_platform_admin: false } }
    const { PlatformPage } = await import('@/pages/platform/PlatformPage')
    const { queryByText } = await mount(PlatformPage)
    expect(queryByText(/for the system operator/i)).not.toBeNull()
  })

  it('renders the schools screen for the operator', async () => {
    current.opts = { rpc: ADMIN_RPCS }
    const { PlatformPage } = await import('@/pages/platform/PlatformPage')
    const { queryByText } = await mount(PlatformPage)
    expect(queryByText(/for the system operator/i)).toBeNull()
  })

  it('offers no way to extend a trial', async () => {
    // fn_extend_trial capped one call at 30 days and capped nothing else, so
    // the button was a fortnight per press with no ceiling and no confirmation.
    // 0106 makes the database refuse it; this makes sure the control does not
    // quietly come back.
    current.opts = { rpc: ADMIN_RPCS }
    const { PlatformPage } = await import('@/pages/platform/PlatformPage')
    const { queryByText } = await mount(PlatformPage)
    expect(queryByText(/\+14d/)).toBeNull()
    expect(queryByText(/extend/i)).toBeNull()
  })

  it('keeps the migration filename out of sight while the schema is healthy', async () => {
    // It used to read "Schema 38 migrations applied · latest 0105_the_leave..."
    // in a box above the customer list, every day, forever. Build output at the
    // top of a business console teaches its owner to skim the top of the page,
    // which is where the money is.
    //
    // ASSERTED ON WHAT IS SHOWN, not on what exists. The first version of this
    // test checked the filename was absent from the DOM entirely and failed,
    // correctly: it is still there, inside a collapsed <details>, which is the
    // whole design. One click when you want it, nothing when you do not.
    current.opts = { rpc: ADMIN_RPCS }
    const { PlatformPage } = await import('@/pages/platform/PlatformPage')
    const { queryByText, container } = await mount(PlatformPage)
    expect(queryByText(/Database up to date/i)).not.toBeNull()
    const filename = queryByText(/0107_x/)
    expect(filename).not.toBeNull()
    const details = filename!.closest('details')
    expect(details).not.toBeNull()
    expect(details!.hasAttribute('open')).toBe(false)
    // And nothing in the page's own summary line mentions it.
    expect(container.querySelector('summary')?.textContent ?? '').not.toMatch(/0107_x/)
  })
})

describe('a screen survives a database function that returns an older shape', () => {
  const CASES: [string, Record<string, unknown>][] = [
    ['snapshot missing its periods', { fn_profit_snapshot: {} }],
    ['snapshot periods are null', { fn_profit_snapshot: { today: null, month: null, year: null } }],
    ['summary missing by_category', {
      fn_profit_snapshot: {
        today: { total_income: 0, expenses: 0, profit: 0 },
        month: { total_income: 0, expenses: 0, profit: 0 },
        year: { total_income: 0, expenses: 0, profit: 0 },
      },
      fn_finance_summary: { from: '2026-09-01', to: '2026-09-05', expenses: 0, profit: 0 },
    }],
    ['summary category list is null', {
      fn_finance_summary: { expenses: 100, profit: 0, expenses_by_category: null },
    }],
    // The pre-0060 name. A school part-way through the bundles is legitimately
    // on it, and the screen must work rather than tell them to apply bundles
    // they have already applied.
    ['summary uses the pre-0060 name', {
      fn_profit_snapshot: {
        today: { total_income: 0, expenses: 0, profit: 0, by_category: [] },
        month: { total_income: 0, expenses: 0, profit: 0, by_category: [] },
        year: { total_income: 0, expenses: 0, profit: 0, by_category: [] },
      },
      fn_finance_summary: {
        from: '2026-09-01', to: '2026-09-05', total_income: 0,
        expenses: 100, profit: -100, by_category: [{ category: 'Utilities', total: 100 }],
      },
    }],
    // THE SUCCESS CASE, which is the one that was missing. Everything above is
    // a malformed response, so all of them passed while the guard was rejecting
    // every well-formed one as well.
    ['summary is exactly what the database returns today', {
      fn_profit_snapshot: {
        today: { total_income: 0, expenses: 0, profit: 0, expenses_by_category: [] },
        month: { total_income: 0, expenses: 0, profit: 0, expenses_by_category: [] },
        year: { total_income: 0, expenses: 0, profit: 0, expenses_by_category: [] },
      },
      fn_finance_summary: {
        from: '2026-09-01', to: '2026-09-05', fee_income: 0, other_income: 0,
        total_income: 0, expenses: 5000, profit: -5000,
        expenses_by_category: [{ category: 'Utilities', total: 5000 }],
      },
    }],
  ]
  for (const [label, rpc] of CASES) {
    it(`Accounts: ${label}`, async () => {
      current.opts = { rpc }
      const { AccountsPage } = await import('@/pages/accounts/AccountsPage')
      await mount(AccountsPage)
    })
  }

  // NOT CRASHING IS NOT THE SAME AS WORKING, and the difference is the whole
  // bug. The cases above assert only that the screen survives; the screen also
  // "survives" by showing "your database is behind the app" forever, which is
  // what it did on every school from 0060 until this was written. So the two
  // shapes a real database can return are asserted to RENDER, and the
  // out-of-date message is asserted to be absent.
  for (const [label, key] of [
    ['the current name', 'expenses_by_category'],
    ['the pre-0060 name', 'by_category'],
  ] as const) {
    it(`Accounts renders the category table with ${label}`, async () => {
      const period = {
        total_income: 0, expenses: 5000, profit: -5000, [key]: [],
      }
      current.opts = {
        rpc: {
          fn_profit_snapshot: { today: period, month: period, year: period },
          fn_finance_summary: {
            from: '2026-09-01', to: '2026-09-05', fee_income: 0, other_income: 0,
            total_income: 0, expenses: 5000, profit: -5000,
            [key]: [{ category: 'Utilities', total: 5000 }],
          },
        },
      }
      const { AccountsPage } = await import('@/pages/accounts/AccountsPage')
      const { queryByText } = await mount(AccountsPage)
      expect(queryByText(/database is behind the app/i)).toBeNull()
      expect(queryByText(/Utilities/)).not.toBeNull()
    })
  }
})

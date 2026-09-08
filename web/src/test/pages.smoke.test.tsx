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
import { cleanup, fireEvent, render, waitFor } from '@testing-library/react'
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

function authValue(profile: Profile | null) {
  return {
    // A SESSION WITH NO PROFILE IS A REAL STATE, not a nonsense one. It is what
    // the platform operator looks like, and it is also what a school owner
    // whose signup did not finish looks like, which is the whole reason
    // LicenceGate has to ask which of the two it is talking to.
    session: {
      user: { id: profile?.id ?? '99999999-9999-9999-9999-999999999999',
              email: profile ? 'owner@example.test' : 'stranded@example.test' },
    } as never,
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

async function mount(
  Comp: ComponentType, route = '/', props: Record<string, unknown> = {},
  profile: Profile | null = OWNER,
) {
  uncaught.length = 0
  window.addEventListener('error', onUncaught)
  const qc = new QueryClient({
    defaultOptions: { queries: { retry: false, gcTime: 0 }, mutations: { retry: false } },
  })
  const utils = render(
    createElement(MemoryRouter, { initialEntries: [route] },
      createElement(AuthContext.Provider, { value: authValue(profile) },
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
  // 0116. It renders stored credentials, so "does it open" and "does it say so
  // when the read fails" are worth more here than on most screens: a key ring
  // that silently renders empty reads as "you have saved no passwords", which
  // is the opposite of the truth and sends the office off to set new ones.
  ['Settings/KeyRing', () => import('@/pages/settings/KeyRing'), 'KeyRing'],
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
    // TWO SCHOOLS, DELIBERATELY DIFFERENT. The console's list used to be checked
    // against an empty array, which renders the "no schools yet" sentence and
    // proves nothing about the table, the badges, the usage bar or the filters.
    fn_platform_schools: [
      {
        school_id: 'sch-1', school_name: 'Al Qalam School', city: 'Lahore',
        contact_name: 'Basha Salamat', contact_phone: '0300-1234567',
        plan_code: 'starter', status: 'active', expires_on: '2027-06-30',
        days_left: 297, student_count: 180, student_limit: 200, limit_state: 'within_margin',
        suggested_plan: 'starter', needs_upgrade: false,
        outstanding: 0, last_paid_on: '2026-07-01',
        suspended: false, suspend_reason: null, archived: false,
      },
      {
        school_id: 'sch-2', school_name: 'Beaconhouse Multan', city: 'Multan',
        contact_name: null, contact_phone: null,
        plan_code: 'growth', status: 'grace', expires_on: '2026-08-20',
        days_left: -17, student_count: 640, student_limit: 500, limit_state: 'over',
        suggested_plan: 'scale', needs_upgrade: true,
        outstanding: 38000, last_paid_on: '2025-08-19',
        suspended: false, suspend_reason: null, archived: false,
      },
    ],
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
    // 0115. Empty in every case but the one that asserts the tab, because an
    // unstubbed RPC comes back as an error and the tab would then be absent for
    // the wrong reason.
    fn_platform_unattached_logins: [],
    // 0128. Empty in every case but the one that asserts the tab, for the same
    // reason as the logins above: the tab only renders when the queue is not
    // empty, so an unstubbed RPC would make it absent for the wrong reason and
    // the assertion would pass without the screen existing.
    fn_platform_limit_requests: [],
    // 0113. The Renewals tab now opens with the run strip, which reads the run
    // history the moment "Past runs" is pressed and nothing before that. Stubbed
    // so a missing RPC cannot make the tab look broken in this suite while
    // being fine in the app, or the reverse.
    fn_platform_renewal_runs: [],
    fn_platform_run_renewals: {
      run_id: 'r1', dry_run: true, as_at: '2026-09-06',
      considered: 0, invoiced: 0, skipped: 0, failed: 0,
      note: 'Nothing was changed. 0 school(s) are due; run it again with dry run off to raise the invoices.',
      attempts: [],
    },
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

  it('lists schools in a table you can search', async () => {
    // The list was a stack of 130px cards with no search box anywhere on the
    // page, so finding one school among fifty meant scrolling past the other
    // forty-nine.
    current.opts = { rpc: ADMIN_RPCS }
    const { PlatformPage } = await import('@/pages/platform/PlatformPage')
    const { queryByText, queryByPlaceholderText } = await mount(PlatformPage)
    expect(queryByPlaceholderText(/search a school/i)).not.toBeNull()
    expect(queryByText('Al Qalam School')).not.toBeNull()
    expect(queryByText('Beaconhouse Multan')).not.toBeNull()
  })

  it('says what a status means instead of printing the database enum', async () => {
    // "grace" reads as a compliment. It means they have not paid and the clock
    // is running, and the operator should not have to translate it every time.
    current.opts = { rpc: ADMIN_RPCS }
    const { PlatformPage } = await import('@/pages/platform/PlatformPage')
    const { queryByText, queryAllByText } = await mount(PlatformPage)
    expect(queryByText('Payment overdue')).not.toBeNull()
    // More than one on purpose: the filter tab and the status chip share the
    // word, which is the point. The filter is named after the state it selects.
    expect(queryAllByText('Paying').length).toBeGreaterThan(0)
    expect(queryByText('grace')).toBeNull()
    expect(queryByText('trialing')).toBeNull()
  })

  it('puts the one thing each school needs today in the last column', async () => {
    // A fixed button on every row is a button nobody reads. The school that
    // owes money gets Record payment; the one that is paid up and inside its
    // dates gets an empty cell.
    current.opts = { rpc: ADMIN_RPCS }
    const { PlatformPage } = await import('@/pages/platform/PlatformPage')
    const { queryAllByText } = await mount(PlatformPage)
    expect(queryAllByText('Record payment')).toHaveLength(1)
  })

  it('opens one workspace rather than six dialogs', async () => {
    current.opts = { rpc: { ...ADMIN_RPCS, fn_platform_school_detail: null } }
    const { PlatformPage } = await import('@/pages/platform/PlatformPage')
    const { queryByText, getByText } = await mount(PlatformPage)
    // Nothing is open until a row is clicked.
    expect(queryByText('Overview')).toBeNull()
    getByText('Al Qalam School').click()
    await waitFor(() => expect(queryByText('Overview')).not.toBeNull())
    // Three tabs, one Actions menu, and no row of five blue links anywhere.
    expect(queryByText('Billing')).not.toBeNull()
    expect(queryByText('Activity')).not.toBeNull()
    expect(queryByText('Actions')).not.toBeNull()
  })

  it('says on the worklist which schools will pay by themselves', async () => {
    // Now that the runner raises the invoices, the question this list has to
    // answer is which of these rows is a phone call at all. A saved card means
    // the money is coming; a transfer means it is not. Under a twelfth of
    // Pakistani adults hold a card, so most of the list is the second kind, and
    // until this was here every row looked equally like work.
    current.opts = {
      rpc: {
        ...ADMIN_RPCS,
        fn_platform_due_soon: [{
          school_id: 'sch-2', school_name: 'Beaconhouse Multan', city: 'Multan',
          contact_name: null, contact_phone: null,
          plan_code: 'growth', status: 'grace', expires_on: '2026-08-20',
          days_left: -17, bucket: 'grace',
          student_count: 640, student_limit: 500,
          suggested_plan: 'scale', needs_upgrade: true,
          renewal_amount: 35000, outstanding: 38000,
          invoiced_to: null, unbilled_days: 0, never_invoiced: false,
          last_reminded_at: null, last_reminded_stage: null,
        }],
      },
      rows: {
        payment_methods: [{
          school_id: 'sch-2', kind: 'manual', brand: null, last4: null,
          label: 'HBL current account',
        }],
      },
    }
    const { PlatformPage } = await import('@/pages/platform/PlatformPage')
    const { queryByText, getByText } = await mount(PlatformPage)
    getByText('Renewals').click()
    // WAITED ON THE METHOD LINE, not on the school name. Clicking a tab starts
    // two queries and mount() has already stopped waiting; the name lands with
    // fn_platform_due_soon while the payment methods are still in flight, so
    // asserting on the name and then reading the line finds nothing.
    await waitFor(() => expect(queryByText(/will not arrive on its own/i)).not.toBeNull())
    expect(queryByText(/Beaconhouse Multan/)).not.toBeNull()
  })

  it('opens the renewals tab with a preview, not with a billing button', async () => {
    // A batch job that moves money and opens with "go" is one somebody runs by
    // accident while exploring, and exploring is what a new operator does
    // first. The only control on arrival changes nothing.
    current.opts = { rpc: ADMIN_RPCS }
    const { PlatformPage } = await import('@/pages/platform/PlatformPage')
    const { queryByText, getByText } = await mount(PlatformPage)
    getByText('Renewals').click()
    await waitFor(() => expect(queryByText(/Raise the bills that are due/i)).not.toBeNull())
    expect(queryByText(/Show me who is due/i)).not.toBeNull()
    // No "Raise N invoice(s)" until a preview has been read.
    expect(queryByText(/^Raise \d+ invoice/)).toBeNull()
    // And it says which of the two things it does, because they are easy to
    // conflate and the difference is the whole design.
    expect(queryByText(/does not take money/i)).not.toBeNull()
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

  it('shows a tab when somebody can sign in and has no school', async () => {
    // The state this tab exists for is invisible everywhere else in the
    // console. A school with a login and no profile appears in the list above
    // as an ordinary new customer, on trial, fourteen days left, nought
    // pupils, and the person it belongs to is being shown a wall.
    current.opts = {
      rpc: {
        ...ADMIN_RPCS,
        fn_platform_unattached_logins: [{
          user_id: 'usr-9', email: 'chaudharytraders735@example.test',
          school_id: 'sch-1', school_name: 'Al Qalam School',
          asked_role: null, created_at: '2026-09-05T08:00:00Z',
        }],
      },
    }
    const { PlatformPage } = await import('@/pages/platform/PlatformPage')
    const { queryByText, getByText } = await mount(PlatformPage)
    const tab = queryByText('Logins with no school')
    expect(tab).not.toBeNull()
    tab!.click()
    await waitFor(() =>
      expect(queryByText('chaudharytraders735@example.test')).not.toBeNull())
    expect(queryByText('Attach to their school')).not.toBeNull()
    // Said, not implied. The operator has to know which school it belongs to
    // before they press anything.
    expect(getByText('Al Qalam School')).not.toBeNull()
  })

  it('hides that tab when nobody is stranded, which is always', async () => {
    // A permanently empty tab teaches people to stop reading the nav, and the
    // nav is where the badges live.
    current.opts = { rpc: ADMIN_RPCS }
    const { PlatformPage } = await import('@/pages/platform/PlatformPage')
    const { queryByText } = await mount(PlatformPage)
    expect(queryByText('Logins with no school')).toBeNull()
  })
})

/**
 * THE THREE DOORS, MOUNTED.
 *
 * One page served an operator console, a school back office and a parent portal
 * while being written for a fourth person, a school buyer, who is not signing in
 * at all. The full critique is in web/src/auth/doors.ts; these hold the facts
 * that are checkable in a browser rather than by eye.
 */
describe('the sign-in doors', () => {
  afterEach(cleanup)

  async function door(mod: 'office' | 'parents' | 'operator') {
    current.opts = {}
    const { Login } = await import('@/pages/Login')
    const doors = await import('@/auth/doors')
    const d = mod === 'office' ? doors.OFFICE_DOOR
      : mod === 'parents' ? doors.PARENT_DOOR : doors.OPERATOR_DOOR
    return mount(() => createElement(Login, { door: d }), '/', {}, null)
  }

  it('shows a parent no price and no way to buy a school by accident', async () => {
    const { queryByText, queryAllByText, container } = await door('parents')
    expect(queryByText('Parent sign in')).not.toBeNull()
    // THE TWO THINGS THE OLD PAGE PUT IN FRONT OF THEM.
    expect(container.textContent ?? '').not.toMatch(/Rs 2,000/)
    expect(queryByText(/Start a free 14-day trial/i)).toBeNull()
    // And the sentence that replaces the trial link, which answers a question
    // parents genuinely ask the office.
    expect(queryByText(/nothing here for you to buy/i)).not.toBeNull()
    // The most useful sentence on the page for the largest group of users, and
    // queryAllByText because it is said twice on purpose: once on the card for
    // somebody who does not know their details, and once in the strip at the
    // bottom for somebody who cannot get in. Two different problems with the
    // same answer, and the strip is the half a phone still shows when the
    // support column is gone.
    expect(queryAllByText(/ask the school office/i).length).toBeGreaterThan(0)
    // WHERE AN ACCOUNT COMES FROM, which is a different question from "what
    // are my details" and had no answer anywhere in the product. A parent
    // cannot make their own, by design, so the page has to say who can.
    // Two facts, not one sentence: who an account comes from, and what to do
    // about it. Either alone leaves the reader stuck.
    expect(queryByText(/school can create one/i)).not.toBeNull()
    expect(queryByText(/contact the school office/i)).not.toBeNull()
    // And the way back to the office door, as a control rather than a phrase:
    // see the office-door test below for why that distinction is the point.
    const toOffice = container.querySelector('a[href="/login"]')
    expect(toOffice).not.toBeNull()
    expect(toOffice?.closest('p')).toBeNull()
  })

  it('keeps the office door working for everybody and points a parent at theirs', async () => {
    // /login has to keep serving all three audiences, because every bookmark
    // and every ProtectedRoute redirect lands on it. So it way-finds with a
    // sentence and never with a refusal.
    const { queryByText, container } = await door('office')
    // The EYEBROW, not the heading: "Sign in" is both the h1 and the submit
    // button on this door, which is right, and the eyebrow is what names the
    // door. Three applications sit behind this form and nothing on the old page
    // said which one the visitor was standing in front of.
    expect(queryByText('School office')).not.toBeNull()
    expect(queryByText(/Start a free 14-day trial/i)).not.toBeNull()
    // A CONTROL, AND NOT A SENTENCE, which is the whole of what a school
    // reported. The pointer used to be a 12px line of grey text at the foot of
    // a stack of four other lines, and parents sent to this door by their own
    // school did not find it.
    //
    // The old assertion here matched that sentence's WORDS, so it would have
    // gone on passing while the thing stayed unfindable, and it broke the
    // moment the words changed rather than when the behaviour did. These two
    // hold what a sentence cannot satisfy: there is an anchor addressed at the
    // parent door, and it is not a phrase buried in a paragraph of prose.
    const toPortal = container.querySelector('a[href="/parents"]')
    expect(toPortal).not.toBeNull()
    expect(toPortal?.textContent).toMatch(/parent portal/i)
    expect(toPortal?.closest('p')).toBeNull()
    // The caption underneath is what keeps it a signpost rather than a
    // correction. Every door signs anybody in, so a parent who has already
    // typed their password here does not have to start again.
    expect(queryByText(/same details work on both pages/i)).not.toBeNull()
  })

  it('gives the operator the plainest page in the product', async () => {
    const { queryByText, container } = await door('operator')
    expect(queryByText('Operator sign in')).not.toBeNull()
    expect(container.textContent ?? '').not.toMatch(/Rs 2,000/)
    expect(queryByText(/Start a free 14-day trial/i)).toBeNull()
    // No support column at all, at any width.
    expect(container.querySelector('aside')).toBeNull()
    // The way out for a school owner who found the address, because a person at
    // the wrong door should be redirected by a sentence and never by a refusal.
    expect(queryByText(/Sign in to your school/i)).not.toBeNull()
  })
})

/**
 * THE PASSWORDS A SCHOOL GAVE OUT.
 *
 * Storing a password is normally indefensible, and the reason it is defensible
 * here is written at the top of migration 0116. What makes it safe rather than
 * merely justified is a set of fences, and two of them are this screen's:
 * nothing is shown until somebody asks for one specific person, and the page
 * says out loud what it is before anybody reads anything off it.
 *
 * The database half of the fences (no school_id, RLS forced, no policies, owner
 * and principal only, never an owner's own, never another school, never the
 * operator even inside a support visit) is asserted in
 * supabase/tests/the_school_keeps_the_keys.sql. These are the two a test in a
 * browser can hold.
 */
describe('the key ring', () => {
  afterEach(cleanup)

  const RING = [
    {
      profile_id: 'p-1', full_name: 'Miss Ayesha', email: 'ayesha@school.pk',
      role: 'class_teacher', active: true, has_password: true,
      set_at: '2026-09-01T06:00:00Z', set_by_name: 'Test Owner',
      changed_since: false, reads: 0, read_by_name: null, read_at: null,
    },
    {
      profile_id: 'p-2', full_name: 'Ali Raza', email: 'aliraza786@gmail.com',
      role: 'parent', active: true, has_password: true,
      set_at: '2026-08-20T06:00:00Z', set_by_name: 'Test Owner',
      changed_since: true, reads: 3, read_by_name: 'Test Owner',
      read_at: '2026-09-04T06:00:00Z',
    },
    {
      profile_id: 'p-3', full_name: 'Bilal Khan', email: 'bilal@school.pk',
      role: 'admin_clerk', active: true, has_password: false,
      set_at: null, set_by_name: null,
      changed_since: false, reads: 0, read_by_name: null, read_at: null,
    },
  ]

  it('shows no password until one is asked for by name', async () => {
    current.opts = {
      rpc: {
        fn_school_key_ring: RING,
        fn_reveal_login_password: {
          email: 'ayesha@school.pk', full_name: 'Miss Ayesha',
          password: 'ayesha-2026', changed_since: false,
        },
      },
    }
    const { KeyRing } = await import('@/pages/settings/KeyRing')
    const { queryByText, queryAllByText, getAllByText } = await mount(KeyRing)

    // Everybody is listed, so "who could I set a password for" is answerable.
    expect(queryByText('Miss Ayesha')).not.toBeNull()
    expect(queryByText('Ali Raza')).not.toBeNull()
    expect(queryByText('Bilal Khan')).not.toBeNull()
    // AND NOT ONE PASSWORD IS ON THE PAGE. The listing deliberately does not
    // carry them: revealing one is a separate, counted act against one person.
    expect(queryByText('ayesha-2026')).toBeNull()

    // The plain truth, said before anything is read off the page rather than in
    // a footnote underneath it.
    expect(queryByText(/can sign in as any of these people/i)).not.toBeNull()
    expect(queryByText(/never kept here/i)).not.toBeNull()

    // One press, one password.
    getAllByText('Show')[0].click()
    await waitFor(() => expect(queryByText('ayesha-2026')).not.toBeNull())
    // Only the one asked for.
    expect(queryAllByText(/gmail/).length).toBeGreaterThan(0)
  })

  it('says when somebody has changed their own password since', async () => {
    // The failure this prevents: the office reads out a password that stopped
    // working the day the parent changed it, it fails, and the feature is never
    // trusted again. Nothing server-side sees a self-service password change,
    // so the only way to know is the fingerprint 0116 records.
    current.opts = { rpc: { fn_school_key_ring: RING } }
    const { KeyRing } = await import('@/pages/settings/KeyRing')
    const { queryByText } = await mount(KeyRing)
    expect(queryByText(/have changed their own password|has changed their own password/i))
      .not.toBeNull()
    expect(queryByText(/Changed by them since/i)).not.toBeNull()
    // And the count is on the row, so an owner can see what their principal has
    // been reading.
    expect(queryByText(/Shown 3 times/i)).not.toBeNull()
  })

  it('tells a school that is behind to apply the bundle, not that it is broken', async () => {
    // A missing migration and a broken screen need completely different things
    // done about them, and PostgREST reports the first as "function does not
    // exist", which reads exactly like the second.
    current.opts = { failEverything: 'Could not find the function public.fn_school_key_ring in the schema cache' }
    const { KeyRing } = await import('@/pages/settings/KeyRing')
    const { queryByText } = await mount(KeyRing)
    expect(queryByText(/bundle 22/i)).not.toBeNull()
  })
})

/**
 * WHICH SCREEN A SIGNED-IN USER WITH NO PROFILE GETS.
 *
 * This was one screen and it belonged to somebody else. "No profile" was read
 * as "platform operator", because that is what an operator looks like from the
 * browser, and the inference only runs one way. Two real schools signed up and
 * both owners were sent to the operator's console, which refused them with
 * "This area is for the system operator." on the click meant to open their new
 * school. Signing in again gave the same wall, and nothing on it said what had
 * gone wrong or who could fix it.
 *
 * Three ways to be here, three different right answers, all three asserted.
 */
describe('a signed-in user with no school', () => {
  afterEach(cleanup)

  const CHILD = () => createElement('div', null, 'THE SCHOOL APP')

  async function gate(rpc: Record<string, unknown>) {
    current.opts = { rpc }
    const { LicenceGate } = await import('@/components/LicenceGate')
    return mount(
      () => createElement(LicenceGate, null, createElement(CHILD)),
      '/', {}, null,
    )
  }

  it('tells a school owner their login is not attached, and how to fix it', async () => {
    const { queryByText, queryAllByText } = await gate({
      is_platform_admin: false, fn_operator_current: null, fn_my_licence: null,
      fn_my_login_state: { state: 'unattached' },
    })
    expect(queryByText(/not attached to a school/i)).not.toBeNull()
    // AND NOT THE WRONG SCREEN. This is the assertion the bug would fail.
    expect(queryByText(/for the system operator/i)).toBeNull()
    // The two things a person in this position can actually do. queryAllByText
    // because the button and the sentence telling them to press it both say
    // "Check again", which is deliberate: the instruction names the control.
    expect(queryAllByText(/Check again/i).length).toBeGreaterThan(0)
    expect(queryByText(/Get in touch/i)).not.toBeNull()
    // And the address, because whoever fixes this needs it and a person
    // reading their own off the screen gets it right.
    expect(queryByText(/stranded@example.test/)).not.toBeNull()
  })

  it('says so when the login was closed rather than never attached', async () => {
    // TWO WAYS TO HAVE NO SCHOOL, and the old screen said the same thing about
    // both. A teacher who left or a parent whose access was removed was told
    // their login was "not attached to a school yet" and to ask the office to
    // attach it, which sent the office hunting for a problem that was not
    // there while the remedy, one Activate button, sat beside that person's
    // name on the Users screen. A closed login reads no profile at all, by
    // design, so only fn_my_login_state (0117) can tell them apart.
    const { queryByText } = await gate({
      is_platform_admin: false, fn_operator_current: null, fn_my_licence: null,
      fn_my_login_state: { state: 'closed', school: 'Al Qalam School', role: 'class_teacher' },
    })
    expect(queryByText(/switched off/i)).not.toBeNull()
    expect(queryByText(/Al Qalam School/)).not.toBeNull()
    expect(queryByText(/press Activate/i)).not.toBeNull()
    // AND NOT THE OTHER SCREEN'S ADVICE. "Do not sign up again" and "ask the
    // office to attach it" are both wrong here.
    expect(queryByText(/not attached to a school yet/i)).toBeNull()
    expect(queryByText(/would make a second school/i)).toBeNull()
  })

  it('does not show that screen to the operator', async () => {
    const { queryByText } = await gate({
      is_platform_admin: true, fn_operator_current: null, fn_my_licence: null,
      fn_my_login_state: { state: 'operator' },
    })
    expect(queryByText(/not attached to a school/i)).toBeNull()
  })

  it('shows the school app to an operator inside a support visit', async () => {
    // "View as school" was dead for a different reason once already: the gate
    // saw no profile and bounced the operator back to the console while the
    // school's own audit trail recorded a visit that never happened. The visit
    // is therefore checked BEFORE the operator question, and this pins it.
    const { queryByText } = await gate({
      is_platform_admin: true, fn_my_licence: null,
      fn_operator_current: {
        id: 'sess-1', school_id: 'sch-1', school_name: 'Al Qalam School',
        reason: 'Principal on the phone', started_at: '2026-09-06T05:00:00Z',
        expires_at: '2026-09-06T07:00:00Z',
      },
    })
    expect(queryByText('THE SCHOOL APP')).not.toBeNull()
    expect(queryByText(/not attached to a school/i)).toBeNull()
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

describe('a finalised register has a way back', () => {
  /**
   * Until migration 0121 this screen's "This day is finalized and locked. It is
   * read-only." was the literal truth at every privilege level: a child marked
   * absent by mistake stayed absent on the register and on the attendance
   * percentage printed on every result card afterwards. The database now has
   * fn_unlock_attendance, and a fix a school cannot reach is not a fix, so what
   * is asserted here is that the door is on the screen and only the two roles
   * that may open it are shown it.
   *
   * Driven through the class picker rather than by reaching into state, because
   * an owner arrives with nothing selected and the roster does not load until
   * they choose: a test that skipped that step would be asserting against a
   * screen no owner ever sees.
   */
  const LOCKED_DAY = {
    rows: {
      academic_sessions: [{ id: 'sess-1', name: '2026-2027', is_current: true }],
      classes: [{ id: 'cls-1', name: 'Class 4', level_order: 4 }],
      sections: [],
    },
    rpc: {
      fn_section_roster: [{
        enrollment_id: 'enr-1', student_id: 'stu-1', roll_no: '1',
        full_name: 'Ali Raza', father_name: 'Raza Sahib',
        status: 'absent', is_locked: true,
      }],
      fn_unlock_attendance: 1,
    },
  }

  async function openLockedDay(profile: Profile) {
    const { AttendancePage } = await import('@/pages/attendance/AttendancePage')
    const utils = await mount(AttendancePage, '/', {}, profile)
    const picker = utils.container.querySelector('select')
    expect(picker).not.toBeNull()
    fireEvent.change(picker as HTMLSelectElement, { target: { value: 'cls-1' } })
    await waitFor(() => expect(utils.queryByText(/finalized and locked/i)).not.toBeNull())
    return utils
  }

  it('the owner is offered a way to reopen it', async () => {
    current.opts = LOCKED_DAY
    const { getByRole, queryByText } = await openLockedDay(OWNER)
    expect(getByRole('button', { name: /reopen this day/i })).not.toBeNull()
    // And the two write controls stay gone: reopening is a separate act from
    // editing, and the day is still locked until it happens.
    expect(queryByText(/^Save attendance$/)).toBeNull()
    expect(queryByText(/Finalize & lock/)).toBeNull()
  })

  it('and reopening it asks why, then calls the database', async () => {
    const seen = { tables: new Set<string>(), rpcs: new Set<string>() }
    current.opts = { ...LOCKED_DAY, seen }
    const { getByRole, getByLabelText, queryByText } = await openLockedDay(OWNER)
    fireEvent.click(getByRole('button', { name: /reopen this day/i }))

    // The reason is not optional, and the dialog says so before the database
    // has to. A four-character reason is refused by fn_unlock_attendance, and
    // finding that out after typing is how a clerk loses what they wrote.
    const confirm = getByRole('button', { name: /reopen the day/i }) as HTMLButtonElement
    expect(confirm.disabled).toBe(true)
    fireEvent.change(getByLabelText(/why is it being reopened/i),
      { target: { value: 'father produced the leave application' } })
    expect((getByRole('button', { name: /reopen the day/i }) as HTMLButtonElement).disabled).toBe(false)

    // From here the server reports the day OPEN, which is what makes the rest
    // of this test worth having: reopening invalidates the roster, and the
    // first version of the screen put its "reopened" message in the same state
    // that the roster-loaded effect clears, so the notice was wiped by its own
    // refetch and the owner saw nothing happen.
    current.opts = {
      ...LOCKED_DAY, seen,
      rpc: { ...LOCKED_DAY.rpc,
             fn_section_roster: [{ ...LOCKED_DAY.rpc.fn_section_roster[0], is_locked: false }] },
    }
    fireEvent.click(getByRole('button', { name: /reopen the day/i }))
    await waitFor(() => expect(seen.rpcs.has('fn_unlock_attendance')).toBe(true))
    await waitFor(() => expect(queryByText(/Reopened, and it is on the school/i)).not.toBeNull())
    // And the day is editable again, with a way to close it. By role, because
    // the notice itself names that button and a text match finds both.
    expect(getByRole('button', { name: /finalize & lock/i })).not.toBeNull()
  })

  it('a class teacher is told who to ask instead', async () => {
    current.opts = {
      ...LOCKED_DAY,
      rpc: {
        ...LOCKED_DAY.rpc,
        fn_my_assignments: [{ class_id: 'cls-1', class_name: 'Class 4', level_order: 4,
                              section_id: null, section_name: null }],
      },
    }
    const { AttendancePage } = await import('@/pages/attendance/AttendancePage')
    // A teacher with one assignment lands on it, so there is no picker to use.
    const { queryByRole, queryByText } = await mount(AttendancePage, '/', {}, {
      ...OWNER, role: 'class_teacher', full_name: 'Test Teacher',
    })
    await waitFor(() => expect(queryByText(/finalized and locked/i)).not.toBeNull())
    expect(queryByRole('button', { name: /reopen this day/i })).toBeNull()
    expect(queryByText(/ask the owner or the principal/i)).not.toBeNull()
  })
})

/**
 * The two screens migration 0128 shipped: the queue and the request box.
 *
 * These are worth a mount each rather than a line in the list above, because
 * both exist to keep a promise made in an error message. At its plan's limit
 * the database refuses an admission and tells the school to ask for room from
 * Settings then Subscription; the console tab is where that request lands. A
 * blank panel on either side turns the refusal into a dead end.
 */
describe('the plan limit, both ends of it', () => {
  afterEach(cleanup)

  const REQUEST = {
    id: 'req-1', school_id: 'sch-1', school_name: 'Al Qalam School',
    contact_name: 'Basha Salamat', contact_phone: '0300-1234567',
    plan_code: 'starter', requested_limit: 300,
    reason: 'we are opening a second campus in April',
    wants: 'more_room' as const,
    requested_at: '2026-09-01T09:00:00Z',
    count_at_request: 198, students_now: 200,
    plan_covers: 200, effective_limit: 200,
    suggested_plan: 'growth', suggested_plan_covers: 350,
    status: 'pending' as const,
    decided_at: null, granted_limit: null, decision_note: null,
  }

  it('shows the requests tab only when a school is waiting on us', async () => {
    current.opts = {
      rpc: {
        is_platform_admin: true, fn_platform_schools: [],
        fn_platform_revenue: {
          net_invoiced: 0, collected: 0, cash_received: 0, tax_withheld: 0,
          discounted: 0, outstanding_total: 0, voided: 0,
          tax_certificates_awaited: 0, schools_owing: [],
        },
        fn_platform_schema_state: { applied_count: 1, latest: 'x', gaps: [], gaps_total: 0 },
        fn_platform_due_soon: [], fn_platform_payment_claims: [],
        fn_platform_settings: { missing: [] }, fn_platform_orphan_report: [],
        fn_platform_unattached_logins: [],
        fn_platform_limit_requests: [REQUEST],
      },
    }
    const { PlatformPage } = await import('@/pages/platform/PlatformPage')
    const { queryByText, getByText } = await mount(PlatformPage)
    await waitFor(() => expect(queryByText('Requests for more room')).not.toBeNull())
    getByText('Requests for more room').click()
    // The school, what it asked for, and the sentence that makes an upgrade the
    // default answer rather than an exception.
    await waitFor(() => expect(queryByText(/Al Qalam School/)).not.toBeNull())
    expect(queryByText(/opening a second campus/)).not.toBeNull()
    expect(queryByText(/plan covers\s*350 pupils/)).not.toBeNull()
    // And the fact that matters most: they are refusing admissions right now.
    expect(queryByText(/cannot admit anybody until you answer/i)).not.toBeNull()
  })

  it('hides the tab when nobody is waiting, rather than showing an empty queue', async () => {
    // A permanently empty tab teaches an operator to stop reading the nav, and
    // the nav is the only thing in this console that says what needs doing.
    current.opts = {
      rpc: {
        is_platform_admin: true, fn_platform_schools: [],
        fn_platform_revenue: {
          net_invoiced: 0, collected: 0, cash_received: 0, tax_withheld: 0,
          discounted: 0, outstanding_total: 0, voided: 0,
          tax_certificates_awaited: 0, schools_owing: [],
        },
        fn_platform_schema_state: { applied_count: 1, latest: 'x', gaps: [], gaps_total: 0 },
        fn_platform_due_soon: [], fn_platform_payment_claims: [],
        fn_platform_settings: { missing: [] }, fn_platform_orphan_report: [],
        fn_platform_unattached_logins: [], fn_platform_limit_requests: [],
      },
    }
    const { PlatformPage } = await import('@/pages/platform/PlatformPage')
    const { queryByText } = await mount(PlatformPage)
    expect(queryByText('Requests for more room')).toBeNull()
  })

  it('gives a full school the box the refusal told it to look for', async () => {
    current.opts = {
      rpc: {
        fn_my_billing: {
          ok: true, licence: { plan_code: 'starter', plan_name: 'Starter', status: 'active', term_months: 12 },
          balance: { billed: 0, paid: 0, outstanding: 0 },
          documents: [], reports: [], how_to_pay: 'Bank transfer.',
          pay_to: { account: null, support_phone: null, support_email: null },
        },
        fn_my_student_limit: {
          students: 200, limit: 200, room: 0, at_limit: true, warn: true,
          granted_extra: false, plan_code: 'starter', plan_covers: 200,
          term_months: 12,
          next_plan: { code: 'growth', name: 'Growth', covers: 350, price: 96000, term_months: 12 },
          request: null,
        },
      },
    }
    const { Subscription } = await import('@/pages/settings/Subscription')
    const { queryByText, container } = await mount(Subscription)
    await waitFor(() => expect(queryByText(/Your roll is full/i)).not.toBeNull())
    // What has stopped, and that nothing else has. A school reading this
    // arrived from a refused admission.
    expect(queryByText(/New admissions are paused/i)).not.toBeNull()
    expect(container.textContent).toMatch(/nothing has been deleted/i)
    // Both ways out, and the upgrade one carries a price, because a school
    // choosing between them is choosing about money.
    expect(queryByText(/Give us room on the plan we have/i)).not.toBeNull()
    expect(queryByText(/Move us up to Growth/i)).not.toBeNull()
    expect(container.textContent).toMatch(/96,000/)
  })

  it('stays out of the way for a school nowhere near its limit', async () => {
    current.opts = {
      rpc: {
        fn_my_billing: {
          ok: true, licence: { plan_code: 'starter', plan_name: 'Starter', status: 'active', term_months: 12 },
          balance: { billed: 0, paid: 0, outstanding: 0 },
          documents: [], reports: [], how_to_pay: 'Bank transfer.',
          pay_to: { account: null, support_phone: null, support_email: null },
        },
        fn_my_student_limit: {
          students: 60, limit: 200, room: 140, at_limit: false, warn: false,
          granted_extra: false, plan_code: 'starter', plan_covers: 200,
          term_months: 12, next_plan: null, request: null,
        },
      },
    }
    const { Subscription } = await import('@/pages/settings/Subscription')
    const { queryByText, container } = await mount(Subscription)
    await waitFor(() => expect(queryByText(/Need room for more\?/i)).not.toBeNull())
    // One line and a link. No form, no warning, nothing to read every day.
    expect(container.textContent).toMatch(/60\s*of the 200 pupils your plan covers/)
    expect(queryByText(/Why you need it/i)).toBeNull()
  })

  it('offers no upgrade to a school already on the biggest plan', async () => {
    // next_plan null is the by-arrangement case. An option that leads nowhere
    // is worse than no option: the school picks it and waits for an answer we
    // have no plan to give.
    current.opts = {
      rpc: {
        fn_my_billing: {
          ok: true, licence: { plan_code: 'custom', plan_name: 'Custom', status: 'active', term_months: 12 },
          balance: { billed: 0, paid: 0, outstanding: 0 },
          documents: [], reports: [], how_to_pay: 'Bank transfer.',
          pay_to: { account: null, support_phone: null, support_email: null },
        },
        fn_my_student_limit: {
          students: 640, limit: 640, room: 0, at_limit: true, warn: true,
          granted_extra: false, plan_code: 'institution', plan_covers: 640,
          term_months: 12, next_plan: null, request: null,
        },
      },
    }
    const { Subscription } = await import('@/pages/settings/Subscription')
    const { queryByText } = await mount(Subscription)
    await waitFor(() => expect(queryByText(/Your roll is full/i)).not.toBeNull())
    expect(queryByText(/Move us up to/i)).toBeNull()
    expect(queryByText(/Give us room on the plan we have/i)).not.toBeNull()
  })

  it('shows a waiting request instead of a second form', async () => {
    // Two requests from one school is a queue the operator has to disambiguate,
    // and the database refuses the second. So the screen must not offer one.
    current.opts = {
      rpc: {
        fn_my_billing: {
          ok: true, licence: { plan_code: 'starter', plan_name: 'Starter', status: 'active', term_months: 12 },
          balance: { billed: 0, paid: 0, outstanding: 0 },
          documents: [], reports: [], how_to_pay: 'Bank transfer.',
          pay_to: { account: null, support_phone: null, support_email: null },
        },
        fn_my_student_limit: {
          students: 200, limit: 200, room: 0, at_limit: true, warn: true,
          granted_extra: false, plan_code: 'starter', plan_covers: 200,
          term_months: 12,
          next_plan: { code: 'growth', name: 'Growth', covers: 350, price: 96000, term_months: 12 },
          request: {
            id: 'r1', status: 'pending', requested_limit: 300,
            requested_at: '2026-09-01T09:00:00Z',
            reason: 'second campus in April', wants: 'more_room',
            granted_limit: null, decision_note: null, decided_at: null,
          },
        },
      },
    }
    const { Subscription } = await import('@/pages/settings/Subscription')
    const { queryByText } = await mount(Subscription)
    await waitFor(() => expect(queryByText(/You asked for room for 300 pupils/i)).not.toBeNull())
    expect(queryByText(/Take this request back/i)).not.toBeNull()
    expect(queryByText(/Why you need it/i)).toBeNull()
  })

  it('shows the answer, with the reason, when we said no', async () => {
    // A request that goes quiet is the thing that produces a phone call, and
    // this screen is where the school was told the answer would appear.
    current.opts = {
      rpc: {
        fn_my_billing: {
          ok: true, licence: { plan_code: 'starter', plan_name: 'Starter', status: 'active', term_months: 12 },
          balance: { billed: 0, paid: 0, outstanding: 0 },
          documents: [], reports: [], how_to_pay: 'Bank transfer.',
          pay_to: { account: null, support_phone: null, support_email: null },
        },
        fn_my_student_limit: {
          students: 200, limit: 200, room: 0, at_limit: true, warn: true,
          granted_extra: false, plan_code: 'starter', plan_covers: 200,
          term_months: 12, next_plan: null,
          request: {
            id: 'r1', status: 'declined', requested_limit: 300,
            requested_at: '2026-09-01T09:00:00Z',
            reason: 'second campus', wants: 'more_room',
            granted_limit: null,
            decision_note: 'Three hundred is the Growth band; happy to move you across.',
            decided_at: '2026-09-03T09:00:00Z',
          },
        },
      },
    }
    const { Subscription } = await import('@/pages/settings/Subscription')
    const { queryByText } = await mount(Subscription)
    await waitFor(() => expect(queryByText(/We could not do this one/i)).not.toBeNull())
    expect(queryByText(/happy to move you across/)).not.toBeNull()
    // And the form is back, because a declined request is not a closed door.
    expect(queryByText(/Why you need it/i)).not.toBeNull()
  })
})

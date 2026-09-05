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

async function mount(Comp: ComponentType, route = '/') {
  uncaught.length = 0
  window.addEventListener('error', onUncaught)
  const qc = new QueryClient({
    defaultOptions: { queries: { retry: false, gcTime: 0 }, mutations: { retry: false } },
  })
  const utils = render(
    createElement(MemoryRouter, { initialEntries: [route] },
      createElement(AuthContext.Provider, { value: authValue(OWNER) },
        createElement(QueryClientProvider, { client: qc },
          createElement(Comp)))),
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
]

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
 * on a response that has no by_category throws during render.
 *
 * These cases pin down what a screen does with a response that is legal JSON
 * and the wrong shape. They must not crash: the screen has to say something.
 */
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
    ['summary by_category is null', {
      fn_finance_summary: { expenses: 100, profit: 0, by_category: null },
    }],
  ]
  for (const [label, rpc] of CASES) {
    it(`Accounts: ${label}`, async () => {
      current.opts = { rpc }
      const { AccountsPage } = await import('@/pages/accounts/AccountsPage')
      await mount(AccountsPage)
    })
  }
})

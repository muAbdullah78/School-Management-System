// @vitest-environment jsdom
/**
 * The parent portal, pinned so its faults cannot come back:
 *
 *   * a weekly test the teacher marked and locked never reached the parent,
 *     whose Results tab said "No results published yet" (0150),
 *   * a portal left open on a phone never showed anything new,
 *   * a Rs 0 challan wore a green tick and "Paid",
 *   * the first screen answered nothing until a tab was pressed,
 *   * a school that has not applied bundle 51 must not see an error.
 */
import { afterEach, describe, expect, it, vi } from 'vitest'
import { createElement } from 'react'
import { cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { MemoryRouter } from 'react-router-dom'
import { fakeSupabase, type FakeOptions } from './fakeSupabase'
import { AuthContext, type Profile } from '@/auth/AuthProvider'

const current: { opts: FakeOptions } = { opts: {} }
vi.mock('@/lib/config', async (importOriginal) => ({
  ...(await importOriginal<typeof import('@/lib/config')>()),
  isConfigured: true,
}))
vi.mock('@/lib/supabase', () => ({
  get supabase() { return fakeSupabase(current.opts) },
  isConfigured: true,
  requireSupabase: () => fakeSupabase(current.opts),
}))

const { PortalPage } = await import('@/pages/portal/PortalPage')
const { today } = await import('@/lib/dates')

const PARENT: Profile = {
  id: '11111111-1111-1111-1111-111111111111', full_name: 'Humna Mahnoor', role: 'parent',
  staff_id: null, school_id: '22222222-2222-2222-2222-222222222222',
}

function shift(d: string, n: number) {
  const t = new Date(`${d}T00:00:00Z`); t.setUTCDate(t.getUTCDate() + n); return t.toISOString().slice(0, 10)
}

const T = today()
const ME = {
  profile_id: 'p', full_name: 'Humna Mahnoor', role: 'parent', school_name: 'The Pisces Science School',
  children: [{ student_id: 'h1', full_name: 'Hamna Masood', gr_no: '0001', class_name: 'Class 4', section_name: null,
    status: 'active', dob: `2017-${T.slice(5)}`, roll_no: '12', class_teacher: 'Sidra Batool' }],
  classes: [],
}
const FEES_NONE = {
  student_id: 'h1', balance: 0, family_outstanding: 0, family_credit: 0,
  invoices: [{ period_month: `${T.slice(0, 7)}-01`, due_date: `${T.slice(0, 7)}-10`, charge: 0, paid: 0, outstanding: 0, status: 'paid' }],
  receipts: [], adjustments: [], charges_not_on_a_challan: 0, deposit_held: 0,
}
const ATT = { from: `${T.slice(0, 7)}-01`, to: T, present: 2, late: 0, half_day: 0, absent: 0, leave: 0, marked: 2, percent: 100,
  days: [{ date: T, status: 'present' }] }
const TESTS = {
  today: T,
  tests: [{ id: 't1', title: 'Weekly test 1', subject: 'Maths', date: shift(T, -1), max_marks: 25, marks: 21,
    is_absent: false, class_marked: 12, class_average: 15.5, class_highest: 23, session: '2026-2027' }],
  upcoming: [{ id: 'u1', title: 'Weekly test 2', subject: 'English', date: shift(T, 4), max_marks: 20, status: 'upcoming' }],
}

function open(opts: FakeOptions, path = '/portal') {
  current.opts = opts
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false, gcTime: 0 } } })
  const auth = {
    session: { user: { id: PARENT.id, email: 'x@example.test' } } as never,
    profile: PARENT, loading: false,
    signIn: async () => ({ error: null }), signOut: async () => {},
    sendReset: async () => ({ error: null }), setPassword: async () => ({ error: null }),
  }
  return render(
    createElement(MemoryRouter, { initialEntries: [path] },
      createElement(AuthContext.Provider, { value: auth },
        createElement(QueryClientProvider, { client: qc }, createElement(PortalPage)))),
  )
}

const RPC = {
  fn_portal_me: ME, fn_portal_child_fees: FEES_NONE, fn_portal_child_ledger: [],
  fn_portal_child_attendance: ATT, fn_portal_child_tests: TESTS, fn_portal_child_results: [],
}

afterEach(() => cleanup())

describe('the weekly test', () => {
  it('a locked class test shows on Results with the mark and the class average, not "No results published yet"', async () => {
    open({ rpc: RPC }, '/portal?tab=results')
    expect(await screen.findByText('Weekly test 1')).toBeTruthy()
    expect(screen.queryByText(/No results published yet/)).toBeNull()
    expect(screen.getByText(/Class average/)).toBeTruthy()
    expect(screen.getByText('84%')).toBeTruthy()
    // A test coming up is shown, with no mark.
    expect(screen.getByText('Weekly test 2')).toBeTruthy()
    expect(screen.getByText('In 4 days')).toBeTruthy()
  })

  it('the first screen already says how the last test went, and the tile opens Results', async () => {
    open({ rpc: RPC })
    const tile = await screen.findByRole('button', { name: /Last test\s*21\/25/ })
    expect(tile.textContent).toMatch(/Maths · 84%/)
    fireEvent.click(tile)
    expect(await screen.findByText('Weekly test 1')).toBeTruthy()
  })

  it('a school that has not applied bundle 51 is told the marks are coming, not shown an error', async () => {
    open({ rpc: { ...RPC, fn_portal_child_tests: undefined }, rpcErrors: {
      fn_portal_child_tests: 'Could not find the function public.fn_portal_child_tests(p_student_id) in the schema cache',
    } }, '/portal?tab=results')
    expect(await screen.findByText(/once your school updates the app/)).toBeTruthy()
    expect(screen.queryByText(/schema cache/)).toBeNull()
  })

  it('Refresh reads the tests again, because a phone left open never did', async () => {
    const calls: FakeOptions['calls'] = []
    open({ rpc: RPC, calls }, '/portal?tab=results')
    await screen.findByText('Weekly test 1')
    const before = calls!.filter((c) => c.name === 'fn_portal_child_tests').length
    fireEvent.click(screen.getByRole('button', { name: 'Refresh' }))
    await waitFor(() => expect(calls!.filter((c) => c.name === 'fn_portal_child_tests').length).toBeGreaterThan(before))
  })
})

describe('the fees tab', () => {
  it('a Rs 0 challan says No fee, not a green Paid', async () => {
    open({ rpc: RPC })
    expect(await screen.findByText('All paid up')).toBeTruthy()
    const challans = screen.getByText('Monthly challans').closest('section')!
    expect(within(challans).getByText('No fee')).toBeTruthy()
    expect(within(challans).queryByText('Paid')).toBeNull()
  })

  it('an unpaid challan past its date says overdue, with what is left to pay', async () => {
    open({ rpc: { ...RPC, fn_portal_child_fees: { ...FEES_NONE, balance: 4500, family_outstanding: 4500,
      invoices: [{ period_month: '2026-01-01', due_date: '2026-01-10', charge: 4500, paid: 0, outstanding: 4500, status: 'unpaid' }] } } })
    expect(await screen.findByText(/Overdue since/)).toBeTruthy()
    expect(screen.getByText(/Rs 4,500 left to pay/)).toBeTruthy()
  })
})

describe('the child', () => {
  it('on the birthday the portal says so, and names the class teacher and roll number', async () => {
    open({ rpc: RPC })
    expect(await screen.findByText('Happy birthday, Hamna!')).toBeTruthy()
    expect(screen.getByText('Sidra Batool')).toBeTruthy()
    expect(screen.getByText(/Roll 12/)).toBeTruthy()
  })

  it('the parent\'s name is never cut short to fit beside Sign out', async () => {
    open({ rpc: RPC })
    const h1 = await screen.findByRole('heading', { level: 1 })
    expect(h1.textContent).toBe('Humna Mahnoor')
    expect(h1.className).not.toContain('truncate')
  })
})

describe('attendance', () => {
  it('is a calendar of the month, each day with a word as well as a colour', async () => {
    open({ rpc: RPC }, '/portal?tab=attendance')
    const label = new Date(`${T}T00:00:00`).toLocaleDateString('en-PK', { weekday: 'short', day: 'numeric', month: 'short' })
    expect(await screen.findByRole('button', { name: `${label}: Present` })).toBeTruthy()
    expect(screen.getByRole('button', { name: 'The month after' }).hasAttribute('disabled')).toBe(true)
  })
})

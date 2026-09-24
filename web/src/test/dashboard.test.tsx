// @vitest-environment jsdom
/**
 * The dashboard draws what the school's records say, and says so when it can't.
 *
 * A school shown the software called the old dashboard "just numbers". The
 * redraw adds charts, and charts are where a dashboard starts lying: a failed
 * read drawn as a quiet day, a figure on the ring that disagrees with the tile
 * beside it, a warning with a button to a screen the reader is refused. Each
 * case below is one of those, pinned.
 */
import { afterEach, beforeAll, describe, expect, it, vi } from 'vitest'
import { createElement } from 'react'
import { cleanup, render, screen, waitFor, within } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { MemoryRouter } from 'react-router-dom'
import { fakeSupabase, type FakeOptions } from './fakeSupabase'
import { AuthContext, type Profile } from '@/auth/AuthProvider'
import type { Role } from '@/auth/roles'

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
vi.mock('./supabase', () => ({
  get supabase() { return fakeSupabase(current.opts) },
  isConfigured: true,
  requireSupabase: () => fakeSupabase(current.opts),
}))

const { Dashboard } = await import('@/pages/Dashboard')

const SUMMARY = {
  active_students: 20, new_admissions_month: 2,
  // Deliberately NOT the class rows' totals: the tile must follow the rows.
  attendance: { marked: 99, present: 99, absent: 0, leave: 0, late: 0, half_day: 0 },
  finance_visible: true, collected_today: 5_000, collected_month: 60_000,
  outstanding: 12_000, defaulters: 3, billed_students_month: 20, classes_without_fee: 0,
  session_set: true, students_without_a_class: 0,
}

const TRENDS = {
  today: '2026-09-24', session_set: true,
  sections: [
    { class_id: 'c2', class_name: 'Class 2', level_order: 2, section_id: null, section_name: null, on_roll: 8, marked: 0, present: 0, late: 0, half_day: 0, leave: 0, absent: 0 },
    { class_id: 'c1', class_name: 'Class 1', level_order: 1, section_id: 's1', section_name: 'A', on_roll: 12, marked: 10, present: 8, late: 1, half_day: 0, leave: 0, absent: 1 },
  ],
  trend: [
    { date: '2026-09-23', marked: 20, present: 18, late: 0, half_day: 0, leave: 0, absent: 2, pct: 90 },
    { date: '2026-09-24', marked: 10, present: 8, late: 1, half_day: 0, leave: 0, absent: 1, pct: 90 },
  ],
  months: [
    { month: '2026-06-01', challans: 20, billed: 40_000, paid: 38_000, overdue: 2_000, not_due: 0 },
    { month: '2026-09-01', challans: 20, billed: 40_000, paid: 30_000, overdue: 0, not_due: 10_000 },
  ],
  dues_by_class: [
    { class_id: 'c1', class_name: 'Class 1', level_order: 1, students: 2, amount: 8_000 },
    { class_id: 'c2', class_name: 'Class 2', level_order: 2, students: 1, amount: 4_000 },
  ],
  staff: { on_books: 5, marked: 5, present: 4, late: 0, half_day: 0, leave: 0, absent: 1 },
}

function profile(role: Role): Profile {
  return {
    id: '11111111-1111-1111-1111-111111111111', full_name: 'Test Owner', role,
    staff_id: null, school_id: '22222222-2222-2222-2222-222222222222',
  }
}

function open(opts: FakeOptions, role: Role = 'owner') {
  current.opts = opts
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false, gcTime: 0 } } })
  const auth = {
    session: { user: { id: 'u', email: 'o@example.test' } } as never,
    profile: profile(role), loading: false,
    signIn: async () => ({ error: null }), signOut: async () => {},
    sendReset: async () => ({ error: null }), setPassword: async () => ({ error: null }),
  }
  return render(
    createElement(MemoryRouter, null,
      createElement(AuthContext.Provider, { value: auth },
        createElement(QueryClientProvider, { client: qc }, createElement(Dashboard)))),
  )
}

const rpc = (extra: Record<string, unknown> = {}) => ({
  fn_dashboard_summary: SUMMARY,
  fn_dashboard_trends: TRENDS,
  fn_draft_students: { count: 0 },
  fn_review_eligibility: { may_review: false, existing_review: null },
  ...extra,
})

beforeAll(() => {
  // jsdom lays nothing out; the charts fall back to a fixed width.
  window.scrollTo = () => {}
})
afterEach(() => cleanup())

describe('today’s register', () => {
  it('lists every class, the ones still to mark first', async () => {
    open({ rpc: rpc() })
    await waitFor(() => expect(screen.getByText('Today’s register')).toBeTruthy())
    const list = screen.getByLabelText('Each class today')
    const names = [...list.querySelectorAll('li')].map((li) => li.textContent ?? '')
    expect(names[0]).toMatch(/^Class 2/)
    expect(names[0]).toContain('Not marked')
    expect(names[1]).toMatch(/^Class 1 A/)
    // (8 present + 1 late) / 10 marked = 90%
    expect(names[1]).toContain('90%')
  })

  it('the tile counts the same children as the rows, not a second definition', async () => {
    open({ rpc: rpc() })
    await waitFor(() => expect(screen.getByText(/10 of 20 marked/)).toBeTruthy())
    expect(screen.queryByText(/99 marked/)).toBeNull()
  })
})

describe('the charts fail out loud', () => {
  it('a failed read says why, and draws no chart', async () => {
    open({ rpc: rpc(), rpcErrors: { fn_dashboard_trends: 'permission denied for function fn_dashboard_trends' } })
    // One retry first, as for any read that might be a dropped connection.
    await waitFor(() => expect(screen.getByText('The charts could not be loaded')).toBeTruthy(), { timeout: 4000 })
    expect(screen.getByText(/permission denied for function/)).toBeTruthy()
    expect(screen.queryByText('Today’s register')).toBeNull()
  })

  it('a function not yet installed is named as an update, not shown as a raw error', async () => {
    open({
      rpc: rpc(),
      rpcErrors: { fn_dashboard_trends: 'Could not find the function public.fn_dashboard_trends without parameters in the schema cache' },
    })
    await waitFor(() => expect(screen.getByText('The charts are not switched on yet')).toBeTruthy())
    expect(screen.queryByText(/schema cache/)).toBeNull()
    // The tiles are still live.
    expect(screen.getByText('Rs 5,000')).toBeTruthy()
  })
})

describe('money', () => {
  it('a month nobody billed is a gap with a word, on a fixed six-month axis', async () => {
    const { container } = open({ rpc: rpc() })
    await waitFor(() => expect(screen.getByText('Fees by billing month')).toBeTruthy())
    // Apr, May, Jul, Aug were never billed; Jun and Sep were.
    expect((container.textContent ?? '').match(/Not billed/g)?.length).toBe(4)
    expect(screen.getByText(/75% of September’s challans paid so far/)).toBeTruthy()
  })

  it('the dues bars add up to the Outstanding tile', async () => {
    open({ rpc: rpc() })
    await waitFor(() => expect(screen.getByText('Rs 12,000 owed by 3 students')).toBeTruthy())
  })

  it('a role that may not see money gets no money charts', async () => {
    open({ rpc: rpc({ fn_dashboard_summary: { ...SUMMARY, finance_visible: false } }) })
    await waitFor(() => expect(screen.getByText('Today’s register')).toBeTruthy())
    expect(screen.queryByText('Fees by billing month')).toBeNull()
    expect(screen.queryByText('Where the dues are')).toBeNull()
  })
})

describe('children on no class list', () => {
  const leftBehind = [
    { student_id: 'a', full_name: 'A', gr_no: null, father_name: null, admission_date: null, last_class: 'Class 3', last_session: '2025-2026' },
    { student_id: 'b', full_name: 'B', gr_no: null, father_name: null, admission_date: null, last_class: 'Class 4', last_session: '2025-2026' },
    { student_id: 'c', full_name: 'C', gr_no: null, father_name: null, admission_date: null, last_class: null, last_session: null },
  ]
  const opts = (): FakeOptions => ({
    rpc: rpc({
      fn_dashboard_summary: { ...SUMMARY, students_without_a_class: 3 },
      fn_students_without_a_class: leftBehind,
    }),
    rows: { academic_sessions: [{ id: 'ses', name: '2026-2027', is_current: true }] },
  })

  it('a skipped rollover is sent to Year Rollover, not told to enrol each child', async () => {
    open(opts())
    const link = await screen.findByRole('link', { name: /Open Year Rollover/ })
    expect(link.getAttribute('href')).toBe('/settings?tab=rollover')
    expect(screen.getByText(/2 of them were last in a class in 2025-2026/)).toBeTruthy()
    expect(screen.getByRole('link', { name: /See who/ }).getAttribute('href')).toBe('/students?no_class=1')
  })

  it('a clerk, who cannot open Settings, is not given a button to it', async () => {
    open(opts(), 'admin_clerk')
    await screen.findByText(/Ask the owner or principal/)
    expect(screen.getByRole('link', { name: /See who/ })).toBeTruthy()
    expect(screen.queryByRole('link', { name: /Open Year Rollover/ })).toBeNull()
  })
})

describe('shortcuts', () => {
  it('never offers a read-only trustee something it will be refused', async () => {
    open({ rpc: rpc() }, 'readonly')
    await waitFor(() => expect(screen.getByLabelText('Shortcuts')).toBeTruthy())
    expect(screen.queryByText('Collect a fee')).toBeNull()
    expect(screen.queryByText('Admit a student')).toBeNull()
    expect(screen.getByRole('link', { name: /Day book/ }).getAttribute('href')).toBe('/reports?tab=daybook')
  })

  it('an owner gets all four', async () => {
    open({ rpc: rpc() })
    await waitFor(() => expect(screen.getByLabelText('Shortcuts')).toBeTruthy())
    const bar = within(screen.getByLabelText('Shortcuts'))
    expect(bar.getAllByRole('link').map((a) => a.getAttribute('href')))
      .toEqual(['/fees', '/attendance', '/admissions', '/reports?tab=daybook'])
  })
})

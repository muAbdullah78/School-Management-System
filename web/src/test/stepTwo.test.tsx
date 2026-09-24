// @vitest-environment jsdom
/**
 * Step 2: Attendance, Tests, Exams, Fees and Accounts.
 *
 * The redraw found faults underneath the colours, and each case here is one
 * of them, pinned so it cannot come back:
 *
 *   * a failed read that said good news ("Nobody is behind", "nothing pending"),
 *   * a one-click action that moves money or a record (Verify, Raise now, Release),
 *   * a date that was a day out in Pakistan,
 *   * a lock that could freeze a test with children unmarked,
 *   * a register nobody could see was costing six absences,
 *   * a tab bar whose 1px underline gave Windows a vertical scrollbar.
 */
import { afterEach, beforeAll, describe, expect, it, vi } from 'vitest'
import { createElement, type ReactElement } from 'react'
import { cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/react'
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

const { AttendanceOverview } = await import('@/pages/attendance/AttendanceOverview')
const { TestsOverview, shiftDate, quickRanges } = await import('@/pages/assessments/TestsOverview')
const { Arrears } = await import('@/pages/fees/Arrears')
const { PendingClearances } = await import('@/pages/fees/PendingClearances')
const { BillingCalendar } = await import('@/pages/fees/BillingCalendar')
const { TabBar } = await import('@/components/TabBar')

function as(role: Role): Profile {
  return {
    id: '11111111-1111-1111-1111-111111111111', full_name: 'Someone', role,
    staff_id: null, school_id: '22222222-2222-2222-2222-222222222222',
  }
}

function open(node: ReactElement, opts: FakeOptions, role: Role = 'owner') {
  current.opts = opts
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false, gcTime: 0 }, mutations: { retry: false } } })
  const auth = {
    session: { user: { id: 'u', email: 'x@example.test' } } as never,
    profile: as(role), loading: false,
    signIn: async () => ({ error: null }), signOut: async () => {},
    sendReset: async () => ({ error: null }), setPassword: async () => ({ error: null }),
  }
  return render(
    createElement(MemoryRouter, null,
      createElement(AuthContext.Provider, { value: auth },
        createElement(QueryClientProvider, { client: qc }, node))),
  )
}

beforeAll(() => { window.scrollTo = () => {} })
afterEach(() => cleanup())

const SESSION = { academic_sessions: [{ id: 'ses', name: '2026-2027', is_current: true }] }

/* ------------------------------------------------------------ attendance --- */

describe('the head’s register', () => {
  const day = [
    { class_id: 'c5', class_name: 'Class 5', level_order: 5, section_id: 's5b', section_name: 'B', pupils: 34, marked: 34, locked: 0, state: 'unlocked' },
    { class_id: 'c1', class_name: 'Class 1', level_order: 1, section_id: null, section_name: null, pupils: 20, marked: 0, locked: 0, state: 'none' },
  ]
  const overview = {
    date: '2026-09-24', today: '2026-09-24',
    sections: [
      { class_id: 'c5', section_id: 's5b', pupils: 34, marked: 34, present: 27, late: 1, half_day: 0, leave: 0, absent: 6, pct: 82.4 },
      { class_id: 'c1', section_id: null, pupils: 20, marked: 0, present: 0, late: 0, half_day: 0, leave: 0, absent: 0, pct: null },
    ],
    trend: [{ date: '2026-09-23', marked: 54, present: 50, late: 1, half_day: 0, leave: 1, absent: 2, pct: 94.4 }],
    watchlist: [{ student_id: 'w1', full_name: 'Hamza Qureshi', gr_no: '1290', class_name: 'Class 1', section_name: null,
      marked: 118, present: 79, late: 3, half_day: 1, leave: 6, absent: 29, pct: 69.9 }],
  }

  it('a class card says six were away, not only that the register is done', async () => {
    open(createElement(AttendanceOverview, { sessionId: 'ses' }), {
      rpc: { fn_attendance_day: day, fn_subject_attendance_day: [], fn_attendance_overview: overview },
    }, 'principal')
    expect(await screen.findByText('34 of 34 marked')).toBeTruthy()
    const card = screen.getByText('34 of 34 marked').closest('button')!
    expect(within(card).getByText('82%')).toBeTruthy()
    expect(within(card).getByText('6')).toBeTruthy()
    expect(within(card).getByText(/absent/)).toBeTruthy()
  })

  it('names the children below the 75% line, each linked to their record', async () => {
    open(createElement(AttendanceOverview, { sessionId: 'ses' }), {
      rpc: { fn_attendance_day: day, fn_subject_attendance_day: [], fn_attendance_overview: overview },
    }, 'principal')
    const link = await screen.findByRole('link', { name: 'Hamza Qureshi' })
    expect(link.getAttribute('href')).toBe('/students?student=w1')
    expect(screen.getByText('70%')).toBeTruthy()
  })

  it('without bundle 48 the piles still work and the charts say they are not switched on', async () => {
    open(createElement(AttendanceOverview, { sessionId: 'ses' }), {
      rpc: { fn_attendance_day: day, fn_subject_attendance_day: [] },
      rpcErrors: { fn_attendance_overview: 'Could not find the function public.fn_attendance_overview in the schema cache' },
    }, 'principal')
    expect(await screen.findByText('The attendance charts are not switched on yet')).toBeTruthy()
    expect(screen.getAllByText('Not done').length).toBeGreaterThan(0)
    expect(screen.queryByText(/schema cache/)).toBeNull()
  })
})

/* ----------------------------------------------------------------- tests --- */

describe('dates on the Tests screen are whole days, not clocks', () => {
  it('moves a plain date without the browser’s timezone', () => {
    expect(shiftDate('2026-09-24', 7)).toBe('2026-10-01')
    expect(shiftDate('2026-03-01', -1)).toBe('2026-02-28')
    expect(shiftDate('2028-03-01', -1)).toBe('2028-02-29')
  })
  it('"Around now" is seven days back and seven ahead, exactly', () => {
    const [around, back, ahead] = quickRanges('2026-09-24')
    expect(around.range).toEqual({ from: '2026-09-17', to: '2026-10-01' })
    expect(back.range).toEqual({ from: '2026-08-25', to: '2026-09-24' })
    expect(ahead.range).toEqual({ from: '2026-09-24', to: '2026-10-24' })
  })
})

describe('the head’s Tests screen', () => {
  const rows = [
    { assessment_id: 't1', title: 'Spelling quiz', assessment_date: '2026-09-18', class_id: 'c2', class_name: 'Class 2',
      level_order: 2, section_name: null, subject_name: 'English', set_by_name: 'Unknown', max_marks: 10,
      is_locked: true, pupils: 28, marked: 25, state: 'locked' },
    { assessment_id: 't2', title: 'Weekly test', assessment_date: '2026-09-19', class_id: 'c5', class_name: 'Class 5',
      level_order: 5, section_name: 'B', subject_name: 'Maths', set_by_name: 'Sadia Rehman', max_marks: 25,
      is_locked: false, pupils: 34, marked: 34, state: 'marked' },
  ]
  const marks = [{ assessment_id: 't2', sat: 32, absent: 2, avg_pct: 61.5, below_pass: 3, top_pct: 96, pass_pct: 33 }]

  it('an old test with no author says "Not recorded", not a person called Unknown', async () => {
    open(createElement(TestsOverview, { sessionId: 'ses' }), { rpc: { fn_tests_overview: rows, fn_tests_marks: marks } }, 'principal')
    expect((await screen.findAllByText('Not recorded')).length).toBeGreaterThan(0)
    expect(screen.queryByText('Unknown')).toBeNull()
  })

  it('a test locked with children unmarked is said to be, not called finished', async () => {
    open(createElement(TestsOverview, { sessionId: 'ses' }), { rpc: { fn_tests_overview: rows, fn_tests_marks: marks } }, 'principal')
    expect((await screen.findAllByText('Locked with gaps')).length).toBeGreaterThan(0)
  })

  it('shows how the test went: class average and how many fell below the pass mark', async () => {
    open(createElement(TestsOverview, { sessionId: 'ses' }), { rpc: { fn_tests_overview: rows, fn_tests_marks: marks } }, 'principal')
    expect((await screen.findAllByText('61.5%')).length).toBeGreaterThan(0)
    expect(screen.getAllByText('3 below pass').length).toBeGreaterThan(0)
  })

  it('the head may reopen a locked test, with a reason; an observer may not', async () => {
    const o: FakeOptions = { rpc: { fn_tests_overview: rows, fn_tests_marks: marks, fn_unlock_assessment: {} }, calls: [] }
    open(createElement(TestsOverview, { sessionId: 'ses' }), o, 'principal')
    fireEvent.click((await screen.findAllByRole('button', { name: /^Reopen/ }))[0])
    const box = await screen.findByPlaceholderText(/marked out of 10/)
    fireEvent.change(box, { target: { value: 'two papers marked out of 5' } })
    fireEvent.click(screen.getByRole('button', { name: 'Reopen the test' }))
    await waitFor(() => expect(o.calls!.some((c) => c.name === 'fn_unlock_assessment')).toBe(true))
    const call = o.calls!.find((c) => c.name === 'fn_unlock_assessment')!
    expect(call.args).toEqual({ p_assessment_id: 't1', p_reason: 'two papers marked out of 5' })

    cleanup()
    open(createElement(TestsOverview, { sessionId: 'ses' }), { rpc: { fn_tests_overview: rows, fn_tests_marks: marks } }, 'readonly')
    await screen.findAllByText('Spelling quiz')
    expect(screen.queryByRole('button', { name: /^Reopen/ })).toBeNull()
  })

  it('dates the wrong way round are refused on the screen, before any read', async () => {
    const o: FakeOptions = { rpc: { fn_tests_overview: rows }, calls: [] }
    open(createElement(TestsOverview, { sessionId: 'ses' }), o, 'principal')
    await screen.findAllByText('Spelling quiz')
    const [from] = document.querySelectorAll('input[type=date]')
    fireEvent.change(from, { target: { value: '2027-01-01' } })
    expect(await screen.findByText('The end date is before the start date.')).toBeTruthy()
  })
})

/* ------------------------------------------------------------------ fees --- */

describe('a failed read never says good news', () => {
  it('Arrears: a failed read is not "Nobody is behind"', async () => {
    open(createElement(Arrears), {
      rows: SESSION,
      rpcErrors: { fn_arrears: 'permission denied for function fn_arrears' },
    })
    expect(await screen.findByText('The arrears list could not be loaded')).toBeTruthy()
    expect(screen.queryByText(/Nobody is behind/)).toBeNull()
  })

  it('Arrears: an empty answer from the database is', async () => {
    open(createElement(Arrears), { rows: SESSION, rpc: { fn_arrears: [] } })
    expect(await screen.findByText(/Nobody is behind/)).toBeTruthy()
  })

  it('Pending: a failed read is not "nothing pending"', async () => {
    open(createElement(PendingClearances), { failEverything: 'permission denied for table payments' })
    expect(await screen.findByText('The pending list could not be loaded')).toBeTruthy()
    expect(screen.queryByText(/Nothing pending/)).toBeNull()
  })
})

describe('money does not move on one click', () => {
  const pending = {
    payments: [{
      id: 'p1', amount: 3000, method: 'easypaisa', receipt_no: 20101, created_at: '2026-09-12T11:00:00Z',
      note: null, student_id: null, students: null, families: { head_name: 'Tariq Siddiqui' },
    }],
  }

  it('Verify asks whether the money has reached the school, and names a family payer', async () => {
    const o: FakeOptions = { rows: pending, rpc: { fn_verify_payment: {} }, calls: [] }
    open(createElement(PendingClearances), o)
    expect(await screen.findByText('Tariq Siddiqui (family)')).toBeTruthy()
    fireEvent.click(screen.getByRole('button', { name: 'Verify' }))
    expect(await screen.findByText('Has this money reached the school?')).toBeTruthy()
    expect(o.calls!.some((c) => c.name === 'fn_verify_payment')).toBe(false)
    fireEvent.click(screen.getByRole('button', { name: 'Yes, it has cleared' }))
    await waitFor(() => expect(o.calls!.some((c) => c.name === 'fn_verify_payment')).toBe(true))
  })

  it('Raise now asks first, and says so when the month has not started', async () => {
    const o: FakeOptions = {
      rows: { ...SESSION, school_settings: [{ billing_day: 1, due_day: 10 }] },
      rpc: {
        fn_billing_calendar: [{ period_month: '2099-03-01', state: 'scheduled', due_date: null, billed_at: null, pupils_billed: 0, note: null, invoices: 0, unpaid: 0 }],
        fn_bill_month: { billed: 0, classes_with_no_fee: 0 },
      },
      calls: [],
    }
    open(createElement(BillingCalendar), o)
    fireEvent.click(await screen.findByRole('button', { name: 'Raise now' }))
    expect(await screen.findByText(/This month has not started yet/)).toBeTruthy()
    expect(o.calls!.some((c) => c.name === 'fn_bill_month')).toBe(false)
  })

  it('a due day before the billing day cannot be saved', async () => {
    const o: FakeOptions = { rows: { ...SESSION, school_settings: [{ billing_day: 1, due_day: 10 }] }, rpc: { fn_billing_calendar: [] }, calls: [] }
    open(createElement(BillingCalendar), o)
    const [raiseOn, dueOn] = await waitFor(() => {
      const els = document.querySelectorAll('input[type=number]')
      expect(els.length).toBe(2)
      return els
    })
    fireEvent.change(raiseOn, { target: { value: '15' } })
    fireEvent.change(dueOn, { target: { value: '10' } })
    expect(await screen.findByText(/would fall due \(the 10\) before it is raised \(the 15\)/)).toBeTruthy()
    expect((screen.getByRole('button', { name: 'Save' }) as HTMLButtonElement).disabled).toBe(true)
  })
})

/* -------------------------------------------------------------- the tabs --- */

describe('the tab bar', () => {
  it('has no negative margin to overflow with, and clips vertically', () => {
    render(createElement(TabBar, {
      label: 'Fees', value: 'b', onChange: () => {},
      tabs: [{ key: 'a', label: 'Collect' }, { key: 'b', label: 'Pending', count: 3 }],
    }))
    const nav = screen.getByRole('navigation', { name: 'Fees' })
    expect(nav.className).toContain('overflow-y-hidden')
    expect(nav.innerHTML).not.toContain('-mb-px')
    expect(screen.getByRole('button', { name: /Pending/ }).getAttribute('aria-current')).toBe('page')
    expect(screen.getByLabelText('3 waiting')).toBeTruthy()
  })
})

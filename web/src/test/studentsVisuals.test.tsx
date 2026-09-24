// @vitest-environment jsdom
/**
 * The roster and the profile say what the records say, with colour that means
 * one thing.
 *
 * Pinned here: the strip above the roster counts from the same reads as the
 * dashboard; a skipped rollover is sent to Year Rollover and a clerk is not
 * given a button to a screen they are refused; the profile says so when the
 * child's last class is from an old session; and a month's fee reads "due"
 * until its due date and "overdue" after, instead of red from the day the
 * challan was issued.
 */
import { afterEach, beforeAll, describe, expect, it, vi } from 'vitest'
import { createElement, type ReactElement } from 'react'
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { MemoryRouter } from 'react-router-dom'
import { fakeSupabase, type FakeOptions } from './fakeSupabase'
import { AuthContext, type Profile } from '@/auth/AuthProvider'
import type { Role } from '@/auth/roles'
import { todayISO } from '@/lib/format'

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

const { StudentsPage } = await import('@/pages/students/StudentsPage')
const { StudentProfile } = await import('@/pages/students/StudentProfile')

function as(role: Role): Profile {
  return {
    id: '11111111-1111-1111-1111-111111111111', full_name: 'Someone', role,
    staff_id: null, school_id: '22222222-2222-2222-2222-222222222222',
  }
}

function open(node: ReactElement, opts: FakeOptions, role: Role = 'owner', route = '/students') {
  current.opts = opts
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false, gcTime: 0 } } })
  const auth = {
    session: { user: { id: 'u', email: 'x@example.test' } } as never,
    profile: as(role), loading: false,
    signIn: async () => ({ error: null }), signOut: async () => {},
    sendReset: async () => ({ error: null }), setPassword: async () => ({ error: null }),
  }
  return render(
    createElement(MemoryRouter, { initialEntries: [route] },
      createElement(AuthContext.Provider, { value: auth },
        createElement(QueryClientProvider, { client: qc }, node))),
  )
}

const SUMMARY = {
  active_students: 214, new_admissions_month: 9,
  attendance: { marked: 0, present: 0, absent: 0, leave: 0, late: 0, half_day: 0 },
  finance_visible: true, collected_today: 0, collected_month: 0, outstanding: 386_000, defaulters: 23,
  billed_students_month: 200, classes_without_fee: 0, session_set: true, students_without_a_class: 3,
}
const behind = (last_session: string | null, i: number) => ({
  student_id: `nc-${i}`, full_name: `Child ${i}`, gr_no: null, father_name: null, admission_date: null,
  last_class: last_session ? 'Class 3' : null, last_session,
})
const ROW = {
  student_id: 'st-1', full_name: 'Ayesha Aslam', gr_no: '1204', admission_no: null,
  father_name: 'Muhammad Aslam', gender: 'female', phone: null, status: 'active',
  class_name: 'Class 5', section_name: 'B', roll_no: '12', family_id: null, balance: 4_500, total_count: 1,
}

function roster(noClass: ReturnType<typeof behind>[]): FakeOptions {
  return {
    rows: { academic_sessions: [{ id: 'ses', name: '2026-2027', is_current: true }], classes: [] },
    rpc: {
      fn_student_list: [ROW, { ...ROW, student_id: 'st-2', full_name: 'Usman Memon', balance: -1_500 }],
      fn_dashboard_summary: { ...SUMMARY, students_without_a_class: noClass.length },
      fn_students_without_a_class: noClass,
      fn_draft_students: { count: 0 },
      fn_draft_student_ids: [],
    },
  }
}

beforeAll(() => { window.scrollTo = () => {} })
afterEach(() => cleanup())

describe('the roster strip', () => {
  it('counts from the same reads as the dashboard, and links the dues to the defaulters list', async () => {
    open(createElement(StudentsPage), roster([behind(null, 1)]))
    expect(await screen.findByText('214')).toBeTruthy()
    expect(await screen.findByText('Rs 386,000 between them')).toBeTruthy()
    expect(screen.getByRole('link', { name: /Owe fees/ }).getAttribute('href')).toBe('/reports?tab=defaulters')
  })

  it('an owed balance is amber and a credit says advance, never a debt', async () => {
    open(createElement(StudentsPage), roster([]))
    const owed = await screen.findAllByText('Rs 4,500')
    expect(owed[0].className).toContain('text-due-800')
    expect(screen.getAllByText('Rs 1,500 advance').length).toBeGreaterThan(0)
  })
})

describe('children on no class list', () => {
  it('a skipped rollover gets a button to Year Rollover, without being asked', async () => {
    open(createElement(StudentsPage), roster([behind('2025-2026', 1), behind('2025-2026', 2), behind(null, 3)]))
    const link = await screen.findByRole('link', { name: /Open Year Rollover/ })
    expect(link.getAttribute('href')).toBe('/settings?tab=rollover')
    expect(screen.getByText(/2 of them were last in a class/)).toBeTruthy()
  })

  it('a clerk is told who to ask, and gets no button to a screen they are refused', async () => {
    open(createElement(StudentsPage), roster([behind('2025-2026', 1)]), 'admin_clerk')
    await screen.findByText(/Ask the owner or principal/)
    expect(screen.queryByRole('link', { name: /Open Year Rollover/ })).toBeNull()
  })

  it('a child never enrolled is counted in the strip, and listed only when asked', async () => {
    open(createElement(StudentsPage), roster([behind(null, 1)]))
    const tile = await screen.findByRole('button', { name: /Not in a class/ })
    expect(screen.queryByText(/is not on any class list/)).toBeNull()
    fireEvent.click(tile)
    expect(await screen.findByText(/1 student is not on any class list/)).toBeTruthy()
    expect(screen.getByText('Never enrolled')).toBeTruthy()
  })
})

describe('the profile', () => {
  const STUDENT = {
    id: 'st-1', gr_no: '1204', admission_no: null, full_name: 'Ayesha Aslam', father_name: 'Muhammad Aslam',
    mother_name: null, b_form: null, dob: '2015-11-02', gender: 'female', address: null, phone: null,
    whatsapp: null, status: 'active', admission_date: '2019-04-08', notes: null, left_on: null,
    leaving_reason: null, photo_path: null,
  }
  const enrolment = (session_id: string, name: string) => ({
    id: `en-${session_id}`, session_id, roll_no: '12', status: 'active',
    academic_sessions: { name, starts_on: '2026-04-01', ends_on: '2027-03-31' },
    classes: { name: 'Class 5' }, sections: { name: 'B' },
  })
  const base = (sessionId: string, name: string): FakeOptions => ({
    rows: {
      students: [STUDENT],
      enrollments: [enrolment(sessionId, name)],
      academic_sessions: [{ id: 'ses', name: '2026-2027', is_current: true }],
    },
    rpc: {
      fn_attendance_summary: { present: 90, absent: 5, leave: 2, late: 3, half_day: 0, marked_days: 100, present_pct: 93 },
      student_balance: 4_500,
      fn_student_marks_trend: [],
    },
  })
  const profile = () => createElement(StudentProfile, { studentId: 'st-1', onBack: () => {} })

  it('opens on the child at a glance: attendance this session and what is owed', async () => {
    open(profile(), base('ses', '2026-2027'))
    expect(await screen.findByText('Attendance, 2026-2027')).toBeTruthy()
    await waitFor(() => expect(screen.getByText('93%')).toBeTruthy())
    expect(screen.getByText(/owed, everything on the ledger together/)).toBeTruthy()
    expect(screen.queryByText(/Not on any class list for/)).toBeNull()
  })

  it('says so when the last class on record is from an old session', async () => {
    open(profile(), base('ses-old', '2025-2026'))
    expect(await screen.findByText('Not on any class list for 2026-2027')).toBeTruthy()
    expect(screen.getByRole('link', { name: 'Open Year Rollover' }).getAttribute('href')).toBe('/settings?tab=rollover')
  })

  it('a month is due until its due date and overdue after it, not red from the day it was issued', async () => {
    const t = todayISO()
    const o = base('ses', '2026-2027')
    o.rows!.invoice_balances = [
      { invoice_id: 'i1', period_month: `${t.slice(0, 7)}-01`, status: 'unpaid', due_date: '2999-12-31',
        arrears_brought_forward: 0, fine: 0, charge: 3000, allocated: 0, deferred_until: null, defer_reason: null },
      { invoice_id: 'i2', period_month: '2026-04-01', status: 'unpaid', due_date: '2026-04-10',
        arrears_brought_forward: 0, fine: 0, charge: 3000, allocated: 0, deferred_until: null, defer_reason: null },
    ]
    open(profile(), o)
    fireEvent.click(await screen.findByRole('button', { name: 'Fees' }))
    expect(await screen.findByText(/^Due 31 Dec 2999/)).toBeTruthy()
    const late = await screen.findByText(/^Overdue since/)
    expect(late.className).toContain('text-danger-800')
  })

  const twoInvoices = () => {
    const t = todayISO()
    const o = base('ses', '2026-2027')
    o.rows!.invoice_balances = [
      { invoice_id: 'i1', period_month: `${t.slice(0, 7)}-01`, status: 'unpaid', due_date: '2999-12-31',
        arrears_brought_forward: 0, fine: 0, charge: 3000, allocated: 0, deferred_until: null, defer_reason: null },
      { invoice_id: 'i2', period_month: '2026-04-01', status: 'unpaid', due_date: '2026-04-10',
        arrears_brought_forward: 0, fine: 0, charge: 3000, allocated: 0, deferred_until: null, defer_reason: null },
    ]
    return o
  }

  it('the session reads at a glance: a tile a month, the rest of the year to come', async () => {
    open(profile(), twoInvoices())
    fireEvent.click(await screen.findByRole('button', { name: 'Fees' }))
    expect(await screen.findByText('2026-2027 at a glance')).toBeTruthy()
    expect(await screen.findByRole('button', { name: /^April 2026: Overdue, Rs 3,000/ })).toBeTruthy()
    expect(screen.getByRole('button', { name: /^September 2026: Due, Rs 3,000/ })).toBeTruthy()
    // April to September have happened; October to March are still to come.
    expect(screen.getAllByLabelText(/: still to come$/)).toHaveLength(12 - Number(todayISO().slice(5, 7)) + 3)
  })

  it('"Owed" shows only the months with money on them', async () => {
    open(profile(), twoInvoices())
    fireEvent.click(await screen.findByRole('button', { name: 'Fees' }))
    fireEvent.click(await screen.findByRole('button', { name: 'Owed 2' }))
    const lines = [...document.querySelectorAll('[id^="fee-month-"]')].map((e) => e.id)
    expect(lines).toEqual([`fee-month-${todayISO().slice(0, 7)}`, 'fee-month-2026-04'])
  })

  it('the old-session warning stands above the Fees tab too, where the clerk actually works', async () => {
    open(profile(), base('ses-old', '2025-2026'))
    fireEvent.click(await screen.findByRole('button', { name: 'Fees' }))
    expect(await screen.findByText('Not on any class list for 2026-2027')).toBeTruthy()
  })
})

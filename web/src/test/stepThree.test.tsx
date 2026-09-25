// @vitest-environment jsdom
/**
 * Step 3: Staff, Reports and Settings.
 *
 * Each case is a fault the redraw found, pinned so it cannot come back:
 *
 *   * a login dropdown that offered parents and attached on a slip of the thumb,
 *   * a banner that nagged the owner about their own login,
 *   * a class teacher who cannot sign in, looking exactly like one who can,
 *   * a family receipt with a dash where the children's names belong,
 *   * a report that stopped at Supabase's 1,000th row and added up what it got,
 *   * a cash drawer counted against receipts alone, ignoring what was spent,
 *   * a Users screen listing every parent with a dropdown to make them Principal,
 *   * a year with no dates told to "add it again", making a second one,
 *   * a class with children in it switched off on one tap,
 *   * a fee box cleared to nothing that silently changed nothing.
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

const { StaffPage } = await import('@/pages/staff/StaffPage')
const { StaffDayRegister } = await import('@/pages/staff/StaffDayRegister')
const { ReportsPage } = await import('@/pages/reports/ReportsPage')
const { Users } = await import('@/pages/settings/Users')
const { Sessions } = await import('@/pages/settings/Sessions')
const { ClassesSections } = await import('@/pages/settings/ClassesSections')
const { FeeStructure } = await import('@/pages/settings/FeeStructure')
const { SchoolProfile } = await import('@/pages/settings/SchoolProfile')
const { Receipt } = await import('@/components/Receipt')
const db = await import('@/lib/db')

const ME = '11111111-1111-1111-1111-111111111111'

function as(role: Role): Profile {
  return { id: ME, full_name: 'Someone', role, staff_id: null, school_id: '22222222-2222-2222-2222-222222222222' }
}

function open(node: ReactElement, opts: FakeOptions, role: Role = 'owner', path = '/') {
  current.opts = opts
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false, gcTime: 0 }, mutations: { retry: false } } })
  const auth = {
    session: { user: { id: ME, email: 'x@example.test' } } as never,
    profile: as(role), loading: false,
    signIn: async () => ({ error: null }), signOut: async () => {},
    sendReset: async () => ({ error: null }), setPassword: async () => ({ error: null }),
  }
  return render(
    createElement(MemoryRouter, { initialEntries: [path] },
      createElement(AuthContext.Provider, { value: auth },
        createElement(QueryClientProvider, { client: qc }, node))),
  )
}

beforeAll(() => { window.scrollTo = () => {} })
afterEach(() => cleanup())

const SESSION = { academic_sessions: [{ id: 'ses', name: '2026-2027', is_current: true, starts_on: '2026-04-01', ends_on: '2027-03-31' }] }

const person = (over: Record<string, unknown>) => ({
  id: 'st', full_name: 'X', designation: 'Teacher', employee_no: null, mobile: null, whatsapp: null, cnic: null,
  joined_on: null, dob: null, left_on: null, status: 'active', profile_id: null, login_active: null, login_role: null,
  class_teacher_of: null, assignments: 0, ...over,
})

/* ================================================================ staff === */

describe('the staff list', () => {
  const roster = [
    person({ id: 'st1', full_name: 'Ayesha Khan', profile_id: 'p1', login_active: true, login_role: 'class_teacher', class_teacher_of: 'Class 1-A', assignments: 1 }),
    person({ id: 'st2', full_name: 'Bilal Ahmed', class_teacher_of: 'Class 2', assignments: 1 }),
  ]
  const logins = [
    { profile_id: ME, full_name: 'Majid Owner', email: 'owner@school.pk', role: 'owner', active: true, staff_id: null, staff_name: null, last_sign_in_at: null },
    { profile_id: 'p9', full_name: 'Loose Teacher', email: 'loose@school.pk', role: 'class_teacher', active: true, staff_id: null, staff_name: null, last_sign_in_at: null },
  ]
  const profiles = [
    { id: 'p1', full_name: 'Ayesha Khan', role: 'class_teacher', active: true, staff_id: 'st1' },
    { id: 'p9', full_name: 'Loose Teacher', role: 'class_teacher', active: true, staff_id: null },
    { id: 'pp', full_name: 'A Parent', role: 'parent', active: true, staff_id: null },
  ]
  const opts = (): FakeOptions => ({
    rows: { ...SESSION, profiles },
    rpc: { fn_staff_roster: roster, fn_school_logins: logins },
    calls: [],
  })

  it('does not nag the owner about their own login, and still lists a stray one', async () => {
    open(createElement(StaffPage), opts())
    expect(await screen.findByText('One login is not attached to anybody on the staff list')).toBeTruthy()
    expect(screen.getByText('loose@school.pk')).toBeTruthy()
    expect(screen.queryByText('owner@school.pk')).toBeNull()
  })

  it('names a teacher who cannot sign in, and counts them', async () => {
    open(createElement(StaffPage), opts())
    expect(await screen.findByText(/Teaches, but cannot sign in/)).toBeTruthy()
    expect(screen.getByText('Teachers who cannot sign in')).toBeTruthy()
  })

  it('never offers a parent login, and asks before attaching one', async () => {
    const o = opts()
    open(createElement(StaffPage), o)
    // Closed until asked for: it used to sit open on every row.
    expect(screen.queryByLabelText('Attached login for Bilal Ahmed')).toBeNull()
    fireEvent.click(await screen.findByRole('button', { name: 'Attach an existing login' }))
    const select = await screen.findByLabelText('Attached login for Bilal Ahmed') as HTMLSelectElement
    const labels = [...select.options].map((x) => x.textContent ?? '')
    expect(labels.some((l) => l.includes('A Parent'))).toBe(false)
    // Ayesha's login belongs to Ayesha: not offered to Bilal either.
    expect(labels.some((l) => l.includes('Ayesha Khan'))).toBe(false)
    fireEvent.change(select, { target: { value: 'p9' } })
    expect(await screen.findByText('Attach this login to Bilal Ahmed?')).toBeTruthy()
    expect(o.calls!.some((c) => c.name === 'fn_link_staff_profile')).toBe(false)
  })
})

describe('the class teacher board', () => {
  it('shows every class at once and says which registers nobody can mark', async () => {
    open(createElement(StaffPage), {
      rows: {
        ...SESSION,
        classes: [{ id: 'c1', name: 'Class 1', level_order: 1 }, { id: 'c2', name: 'Class 2', level_order: 2 }, { id: 'c3', name: 'Class 3', level_order: 3 }],
        sections: [],
        teacher_assignments: [
          { id: 'a1', staff_id: 'st1', class_id: 'c1', section_id: null, staff: { full_name: 'Ayesha Khan' }, classes: { name: 'Class 1' }, sections: null },
          { id: 'a2', staff_id: 'st2', class_id: 'c2', section_id: null, staff: { full_name: 'Bilal Ahmed' }, classes: { name: 'Class 2' }, sections: null },
        ],
      },
      rpc: {
        fn_staff_roster: [
          person({ id: 'st1', full_name: 'Ayesha Khan', login_active: true }),
          person({ id: 'st2', full_name: 'Bilal Ahmed', login_active: null }),
        ],
      },
    }, 'owner', '/staff?tab=teachers')
    expect(await screen.findByText('registers have a class teacher who can mark them')).toBeTruthy()
    expect(screen.getByText(/Bilal Ahmed cannot sign in, so nobody marks this register/)).toBeTruthy()
    expect(screen.getAllByText('Nobody is set to mark this register.').length).toBe(1)
    expect(screen.getByRole('button', { name: 'Show only the 2 that need someone' })).toBeTruthy()
  })
})

describe('the day’s staff register', () => {
  const day = [
    { staff_id: 's1', full_name: 'Ayesha Khan', designation: null, employee_no: null, status: 'present', checked_at: '2026-09-24T09:05:00Z', checked_out_at: null, late_minutes: null, worked_minutes: null, source: 'manual', scanned: false, code_label: null, code_window: null, device: null, reason: null, marked_by_name: 'Office' },
    { staff_id: 's2', full_name: 'Bilal Ahmed', designation: null, employee_no: null, status: 'not marked', checked_at: null, checked_out_at: null, late_minutes: null, worked_minutes: null, source: null, scanned: false, code_label: null, code_window: null, device: null, reason: null, marked_by_name: null },
  ]
  it('a day typed by the office shows no arrival time, and marking the rest asks first', async () => {
    const o: FakeOptions = { rpc: { fn_staff_attendance_day: day }, calls: [] }
    open(createElement(StaffDayRegister), o)
    const table = await screen.findByRole('table')
    // 09:05 UTC would print as 14:05 in Karachi: the moment somebody typed it.
    expect(within(table).queryByText('14:05')).toBeNull()
    fireEvent.click(screen.getByRole('button', { name: 'Mark the 1 not marked as present' }))
    expect(await screen.findByText(/Mark 1 person present for/)).toBeTruthy()
    expect(o.calls!.some((c) => c.name === 'fn_staff_mark_rest_present')).toBe(false)
  })
})

/* ============================================================== reports === */

describe('fee collection', () => {
  const receipts = {
    from: '2026-09-01', to: '2026-09-24', total: 9000, receipts: 1, reversals: 0, reversed: 0,
    pending_count: 0, pending_total: 0,
    by_method: [{ method: 'easypaisa', receipts: 1, amount: 9000 }],
    by_day: [{ day: '2026-09-24', receipts: 1, amount: 9000 }],
    rows: [{ id: 'p1', paid_at: '2026-09-24T05:00:00Z', paid_on: '2026-09-24', time: '10:00', receipt_no: 1042,
      amount: 9000, method: 'easypaisa', payer: 'Shahid Anwar', children: 'Aisha Anwar, Bilal Anwar', child_count: 2,
      gr_no: null, class_label: null, is_reversal: false, recorded_by: 'Office', note: null }],
  }
  it('names the children on a family payment, and says Easypaisa, not easypaisa', async () => {
    open(createElement(ReportsPage), { rpc: { fn_fee_receipts: receipts } })
    const table = await screen.findByRole('table')
    expect(within(table).getByText('Aisha Anwar, Bilal Anwar')).toBeTruthy()
    expect(within(table).getByText('Shahid Anwar')).toBeTruthy()
    expect(within(table).getByText('Easypaisa')).toBeTruthy()
    expect(within(table).queryByText('easypaisa')).toBeNull()
  })

  it('says what to paste when the database has not got bundle 49', async () => {
    open(createElement(ReportsPage), { rpcErrors: { fn_fee_receipts: 'Could not find the function public.fn_fee_receipts in the schema cache' } })
    expect(await screen.findByText(/latest database update \(bundle 49\)/)).toBeTruthy()
  })
})

describe('every row, not the first thousand', () => {
  it('pages a report past 1,000 rows and stops at the end', async () => {
    const many = Array.from({ length: 2500 }, (_, i) => ({ invoice_id: `i${i}`, due: 100, days_overdue: 0, charge: 100, paid: 0, student_name: 'X', period_label: 'Sep' }))
    current.opts = { rpc: { fn_report_unpaid_invoices: many } }
    const rows = await db.getUnpaidInvoices('ses')
    expect(rows.length).toBe(2500)
    expect(rows.reduce((t, r) => t + r.due, 0)).toBe(250000)
  })
})

describe('the day book', () => {
  it('counts the drawer as cash in, less cash spent', async () => {
    open(createElement(ReportsPage), {
      rpc: {
        fn_fee_receipts: { from: '', to: '', total: 5000, receipts: 1, reversals: 0, reversed: 0, pending_count: 0, pending_total: 0,
          by_method: [{ method: 'cash', receipts: 1, amount: 5000 }], by_day: [], rows: [] },
        fn_report_ledger: [
          { entry_date: '2026-09-24', kind: 'income', category: 'Other income', particulars: 'Hall rent', reference: '-', party: '-', method: 'cash', debit: 500, credit: 0, recorded_by: '-', is_reversal: false },
          { entry_date: '2026-09-24', kind: 'expense', category: 'Utilities', particulars: 'Generator diesel', reference: 'V1', party: '-', method: 'cash', debit: 0, credit: 3000, recorded_by: '-', is_reversal: false },
        ],
      },
    }, 'owner', '/reports?tab=daybook')
    const row = (await screen.findByText('The drawer should hold')).closest('tr')!
    // 5,000 in fees + 500 hall rent - 3,000 diesel. It used to say 5,000.
    expect(row.textContent).toContain('2,500')
  })
})

/* ============================================================= settings === */

describe('users and roles', () => {
  const profiles = [
    { id: 'o1', full_name: 'The Owner', role: 'owner', active: true, staff_id: null },
    { id: ME, full_name: 'Me Principal', role: 'principal', active: true, staff_id: null },
    { id: 't1', full_name: 'Ayesha Khan', role: 'class_teacher', active: true, staff_id: 'st1' },
    { id: 'pa', full_name: 'A Parent', role: 'parent', active: true, staff_id: null },
  ]
  it('lists no parents, and a principal cannot touch the owner or themselves', async () => {
    open(createElement(Users), { rows: { profiles }, rpc: { fn_school_logins: [] } }, 'principal')
    expect(await screen.findByText('Ayesha Khan')).toBeTruthy()
    expect(screen.queryByText('A Parent')).toBeNull()
    expect(screen.getByText(/1 parent login/)).toBeTruthy()
    // One Change role button, for the teacher: not for the owner, not for me.
    expect(screen.getAllByRole('button', { name: 'Change role' }).length).toBe(1)
    expect(screen.getByText('Only an owner can change an owner')).toBeTruthy()
  })

  it('a role change asks first and says what the role can do', async () => {
    const o: FakeOptions = { rows: { profiles }, rpc: { fn_school_logins: [] }, calls: [] }
    open(createElement(Users), o, 'owner')
    fireEvent.click((await screen.findAllByRole('button', { name: 'Change role' }))[0])
    expect(await screen.findByText(/What should .* be able to do\?/)).toBeTruthy()
    expect(screen.getByText(/Sees everything and can change nothing/)).toBeTruthy()
  })
})

describe('sessions', () => {
  it('a year without dates is fixed on the year, not by adding it again', async () => {
    open(createElement(Sessions), { rows: { academic_sessions: [{ id: 's', name: '2026-2027', starts_on: null, ends_on: null, is_current: true, is_closed: false }] } })
    expect(await screen.findByRole('button', { name: 'Set its dates' })).toBeTruthy()
    expect(screen.queryByText(/Add it again/i)).toBeNull()
  })
})

describe('classes and sections', () => {
  it('a class with children in it is not switched off with one tap', async () => {
    const o: FakeOptions = {
      rows: {
        ...SESSION,
        classes: [{ id: 'c1', name: 'Class 1', level_order: 10, active: true }],
        enrollments: [{ id: 'e1', class_id: 'c1', section_id: null, classes: { name: 'Class 1', level_order: 10 }, sections: null, students: { gender: 'male' } }],
      },
      calls: [],
    }
    open(createElement(ClassesSections), o)
    expect(await screen.findByText('1 child this year')).toBeTruthy()
    fireEvent.click(screen.getByRole('button', { name: 'Switch off' }))
    expect(await screen.findByRole('alert')).toBeTruthy()
    expect(screen.getByRole('alert').textContent).toContain('cannot be switched off')
  })
})

describe('the fee structure', () => {
  const grid = [{ fee_head_id: 'h1', fee_head: 'Tuition', is_recurring: true, amount: 4000, effective_from: null, next_amount: null, next_from: null }]
  it('every class on one sheet, with its monthly total, and a cleared box is refused', async () => {
    open(createElement(FeeStructure), {
      rows: { ...SESSION, classes: [{ id: 'c1', name: 'Class 1', level_order: 1 }, { id: 'c2', name: 'Class 2', level_order: 2 }] },
      rpc: { fn_fee_structure: grid },
    })
    const table = await screen.findByRole('table')
    expect(within(table).getByText('Class 1')).toBeTruthy()
    expect(within(table).getByText('Class 2')).toBeTruthy()
    const box = within(table).getByLabelText('Class 1, Tuition') as HTMLInputElement
    fireEvent.change(box, { target: { value: '' } })
    expect(within(table).getByText('Enter 0 to stop charging it')).toBeTruthy()
    expect((screen.getByRole('button', { name: /Save 1 change/ }) as HTMLButtonElement).disabled).toBe(true)
  })
})

describe('the school profile', () => {
  it('Save lights only after a change, and a blank name is refused', async () => {
    open(createElement(SchoolProfile), { rows: { school_settings: [{ name: 'City School', pass_percent: 33, grade_scale: 'letter' }] } })
    const save = await screen.findByRole('button', { name: 'Save the profile' }) as HTMLButtonElement
    await waitFor(() => expect((screen.getByPlaceholderText('e.g. City Public School') as HTMLInputElement).value).toBe('City School'))
    expect(save.disabled).toBe(true)
    // Nothing is called wrong before anything has been changed.
    expect(screen.queryByText(/cannot be blank/)).toBeNull()
    fireEvent.change(screen.getByPlaceholderText('e.g. City Public School'), { target: { value: '  ' } })
    expect(screen.getByText(/cannot be blank/)).toBeTruthy()
    expect(save.disabled).toBe(true)
  })
})

describe('the receipt', () => {
  it('prints the receipt prefix the school set, which nothing read before', async () => {
    open(createElement(Receipt, {
      data: { receiptNo: 1042, studentName: 'Aisha', amount: 4000, method: 'Cash', balanceAfter: 0 },
      onClose: () => {},
    }), { rows: { school_settings: [{ name: 'City School', receipt_prefix: 'R-' }] } })
    expect(await screen.findByText('R-1042')).toBeTruthy()
  })
})

// @vitest-environment jsdom
/**
 * The two screens that show the same child's fee, and did not show the same
 * thing.
 *
 * ASSERTION 6 IS THE ONE THAT EARNS THIS FILE. The student profile's "Propose
 * discount" button handed fn_add_discount an ENROLMENT id, and that function has
 * taken a CHILD since 0138. Every press, in every school, came back
 *
 *     students not found in this school
 *
 * Nothing could have caught it except the value: both ids are uuid strings, so
 * TypeScript was satisfied, the RPC contract checker was satisfied because the
 * argument NAMES were right, and every SQL suite passed because the database was
 * never the thing that was wrong. The fake client records RPC arguments now for
 * exactly this reason.
 *
 * ASSERTIONS 1 TO 5 are the vendor's own complaint, written down: at the counter
 * a child showed a name, a GR number and one balance, while the same child in
 * Students showed the class, the fee before the concession, the concession, its
 * rate and its reason.
 */
import { describe, expect, it, vi, afterEach } from 'vitest'
import { createElement } from 'react'
import { cleanup, render, screen, waitFor, fireEvent, within } from '@testing-library/react'
import { MemoryRouter } from 'react-router-dom'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { fakeSupabase, type FakeOptions } from './fakeSupabase'
import { FamilyCollect } from '@/pages/fees/FamilyCollect'
import { Discounts } from '@/pages/fees/Discounts'
import { StudentProfile } from '@/pages/students/StudentProfile'

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
vi.mock('@/auth/AuthProvider', () => ({
  useAuth: () => ({ profile: { id: 'u1', role: 'owner', full_name: 'Head' } }),
}))

/**
 * Shahid Anwar's family: Abdullah in Class 1 on a 40 per cent hardship waiver
 * with three months behind him, and Ayesha in Class 4 on the plain fee. This is
 * the family in the vendor's screenshot, to the rupee.
 */
const FAMILY = {
  family: {
    id: 'fam-1', head_name: 'Shahid Anwar', head_cnic: '11010000000',
    phone: '0333 1234567', whatsapp: null, address: null,
  },
  credit: 0,
  outstanding: 38200,
  month: '2026-09-01',
  children: [
    {
      student_id: 'stu-1', full_name: 'Abdullah Dar', gr_no: '0001', status: 'active',
      balance: 16200, photo_path: null,
      class_name: 'Class 1', section_name: 'A', roll_no: '01',
      gross: 4500, discount: 1800, net: 2700,
      discount_lines: [{
        discount_id: 'd-1', type: 'hardship', amount: 1800,
        is_percent: true, rate: 40, reason: 'Hard Core',
      }],
      month_state: 'unpaid', month_charge: 2700, month_paid: 0, month_due: 2700,
      arrears_months: 3, arrears_amount: 13500, arrears_oldest: '2026-06-01',
      invoices: [{
        invoice_id: 'i-1', period_month: '2026-09-01', due_date: '2026-09-10',
        charge: 2700, allocated: 0, outstanding: 2700, status: 'issued',
      }],
    },
    {
      student_id: 'stu-2', full_name: 'Ayesha Dar', gr_no: '0002', status: 'active',
      balance: 22000, photo_path: null,
      class_name: 'Class 4', section_name: null, roll_no: '07',
      gross: 5500, discount: 0, net: 5500,
      discount_lines: [],
      month_state: 'part_paid', month_charge: 5500, month_paid: 1500, month_due: 4000,
      arrears_months: 3, arrears_amount: 16500, arrears_oldest: '2026-06-01',
      invoices: [],
    },
  ],
}

const AT_THE_COUNTER: FakeOptions = {
  rows: { students: [{ id: 'stu-1', family_id: 'fam-1' }] },
  rpc: {
    fn_current_session: { id: 'sess-1', name: '2026-2027' },
    fn_family_sheet: FAMILY,
    fn_ensure_billing_current: { billed: 0, months: [] },
    fn_find_family: [{
      family_id: 'fam-1', head_name: 'Shahid Anwar', head_cnic: '11010000000',
      phone: '0333 1234567', children: 2, outstanding: 38200, credit: 0,
    }],
  },
}

function mount(node: unknown, opts: FakeOptions) {
  current.opts = opts
  const qc = new QueryClient({
    defaultOptions: { queries: { retry: false, gcTime: 0 }, mutations: { retry: false } },
  })
  return render(
    createElement(MemoryRouter, null,
      createElement(QueryClientProvider, { client: qc }, node as never)),
  )
}

/** Land on the family sheet the way a clerk does: search the father, pick him. */
async function openTheFamily(opts: FakeOptions = AT_THE_COUNTER) {
  mount(createElement(FamilyCollect), opts)
  const box = await screen.findByPlaceholderText(/CNIC, phone, parent name/i)
  fireEvent.change(box, { target: { value: '11010000000' } })
  fireEvent.click(screen.getByRole('button', { name: /^Search$/ }))
  const hit = await screen.findByText('Shahid Anwar')
  fireEvent.click(hit)
  await waitFor(() => expect(screen.getByText('Abdullah Dar')).toBeTruthy())
}

afterEach(() => cleanup())

describe('the counter can see the fee it is collecting', () => {
  it('1. names the class and the roll, so the clerk knows whose fee this is', async () => {
    await openTheFamily()
    expect(screen.getByText(/Class 1 \(A\) · Roll 01/)).toBeTruthy()
    expect(screen.getByText(/Class 4 · Roll 07/)).toBeTruthy()
  })

  it('2. shows the fee AFTER the concession with the full fee struck through', async () => {
    await openTheFamily()
    // Rs 2,700 is what this family pays. Rs 4,500 is what Class 1 costs, and it
    // has to stay visible or the office quotes the discounted figure to the
    // next parent through the window.
    expect(screen.getAllByText(/Rs\s*2,700/).length).toBeGreaterThan(0)
    expect(screen.getByText(/Rs\s*4,500/)).toBeTruthy()
  })

  it('3. THE COMPLAINT: names the concession, its rate, its rupees and its reason', async () => {
    await openTheFamily()
    expect(screen.getByText(/Hardship 40% off/)).toBeTruthy()
    expect(screen.getByText(/saves Rs\s*1,800 · Hard Core/)).toBeTruthy()
  })

  it('4. tags this month, and says part paid rather than simply unpaid', async () => {
    await openTheFamily()
    expect(screen.getByText(/^Due Rs\s*2,700$/)).toBeTruthy()
    // Ayesha has had Rs 1,500 of September. Calling that "unpaid" is how a
    // parent is asked for the whole fee twice.
    expect(screen.getByText(/Part paid, Rs\s*4,000 left/)).toBeTruthy()
  })

  it('5. counts the months behind SEPARATELY from the month in progress', async () => {
    await openTheFamily()
    expect(screen.getByText(/3 earlier months unpaid · Rs\s*13,500, oldest Jun 2026/)).toBeTruthy()
  })
})

describe('the discount register reads the model the database actually has', () => {
  const REGISTER: FakeOptions = {
    rpc: {
      fn_discounts_register: [
        {
          id: 'd-1', student_id: 'stu-1', student_name: 'Abdullah Dar', gr_no: '0001',
          class_name: 'Class 1', section_name: 'A', type: 'hardship', amount: 40,
          is_percent: true, reason: 'Hard Core', status: 'approved',
          starts_on: '2026-09-01', ends_on: null, live: true,
          created_at: '2026-09-16T00:00:00Z', proposed_by: 'Head', approved_by: 'Head',
        },
        {
          id: 'd-2', student_id: 'stu-9', student_name: 'Bilal Dar', gr_no: '0009',
          // A child between two school years. The old screen dropped this row
          // entirely, because it joined enrollments!inner.
          class_name: null, section_name: null, type: 'sibling', amount: 500,
          is_percent: false, reason: 'two brothers', status: 'approved',
          starts_on: '2025-04-01', ends_on: '2026-03-01', live: false,
          created_at: '2025-04-01T00:00:00Z', proposed_by: 'Head', approved_by: 'Head',
        },
      ],
    },
  }

  it('6. shows the months a concession covers, at both ends', async () => {
    mount(createElement(Discounts), REGISTER)
    // Twice in the page: the phone list and the desktop table, one shown by CSS.
    await waitFor(() => expect(screen.getAllByText('Abdullah Dar').length).toBeGreaterThan(0))
    // getByText matches one text NODE, and the cell is built from two, so the
    // whole cell is read instead of asserting on how JSX happened to split it.
    const cells = Array.from(document.querySelectorAll('td')).map((td) => td.textContent ?? '')
    // "Sept", not "Sep": en-GB spells September with four letters and every
    // other month with three, and the vendor's own screenshot says Sept 2026.
    expect(cells.some((t) => /Sept 2026 onwards/.test(t))).toBe(true)
    expect(cells.some((t) => /Apr 2025 to Mar 2026/.test(t))).toBe(true)
  })

  it('7. separates "in force" from "approved", which the old list could not', async () => {
    mount(createElement(Discounts), REGISTER)
    // Twice in the page: the phone list and the desktop table, one shown by CSS.
    await waitFor(() => expect(screen.getAllByText('Abdullah Dar').length).toBeGreaterThan(0))
    // Both rows are approved. Only one of them is coming off a fee this month,
    // and the old screen showed them identically with a Revoke button each.
    const table = within(document.querySelector('table')!)
    expect(table.getAllByText('Approved').length).toBe(2)
    expect(table.getAllByText('In force').length).toBe(1)
    expect(screen.getByText(/1 running this month/)).toBeTruthy()
  })

  it('8. keeps a child with no enrolment on the list instead of dropping them', async () => {
    mount(createElement(Discounts), REGISTER)
    await waitFor(() => expect(screen.getAllByText('Bilal Dar').length).toBeGreaterThan(0))
    expect(screen.getByText('not enrolled')).toBeTruthy()
  })

  it('9. hands fn_add_discount a CHILD id and the months, not an enrolment', async () => {
    const calls: { name: string; args: Record<string, unknown> }[] = []
    mount(createElement(Discounts), {
      ...REGISTER,
      calls,
      rpc: {
        ...REGISTER.rpc,
        fn_add_discount: 'new-discount-id',
        fn_set_discount_status: {},
      },
      // searchStudents reads the table directly, it is not an RPC.
      rows: { students: [{ id: 'stu-7', full_name: 'Usman Ali', gr_no: '0007', father_name: 'Ali' }] },
    })
    const box = await screen.findByPlaceholderText(/Search student by name or GR/i)
    fireEvent.change(box, { target: { value: 'Usman' } })
    fireEvent.click(await screen.findByText('Usman Ali'))

    const amount = await screen.findByRole('spinbutton')
    fireEvent.change(amount, { target: { value: '25' } })
    fireEvent.click(screen.getByRole('button', { name: /Apply discount/ }))

    await waitFor(() => expect(calls.some((c) => c.name === 'fn_add_discount')).toBe(true))
    const add = calls.find((c) => c.name === 'fn_add_discount')!
    expect(add.args.p_student_id).toBe('stu-7')
    // 0138 gave a discount a start and an end and nothing in the product ever
    // set either, so every concession began this month and ran for ever.
    expect(String(add.args.p_starts_on)).toMatch(/^\d{4}-\d{2}-01$/)
    expect(add.args).toHaveProperty('p_ends_on')
  })
})

/**
 * The child's own page, which is the screen in the vendor's second screenshot.
 *
 * Assertion 12 is the shipped defect: "Propose discount" was handed
 * enrollment.enrollment_id, and fn_add_discount has taken a child since 0138.
 */
describe('the child page and the counter agree, and its discount button works', () => {
  const CHILD: FakeOptions = {
    rows: {
      students: [{
        id: 'stu-1', gr_no: '0001', full_name: 'Abdullah Dar', father_name: 'Shahid Anwar',
        status: 'active', admission_date: '2026-06-01', photo_path: null,
        mother_name: null, b_form: null, dob: null, gender: null, address: null,
        phone: null, whatsapp: null, notes: null, left_on: null, leaving_reason: null,
        admission_no: null,
      }],
      enrollments: [{
        id: 'enr-1', session_id: 'sess-1', roll_no: '01', status: 'active',
        academic_sessions: { name: '2026-2027', starts_on: '2026-06-01', ends_on: '2027-05-31' },
        classes: { name: 'Class 1' }, sections: { name: 'A' },
      }],
      guardians: [],
      invoice_balances: [],
      payments: [],
    },
    rpc: {
      student_balance: 2700,
      fn_deposit_held: 0,
      fn_student_ledger: [],
      fn_student_fee_for_month: {
        month: '2026-09-01', gross: 4500, discount: 1800, net: 2700,
        class_name: 'Class 1', section_name: 'A', roll_no: '01', enrollment_id: 'enr-1',
        lines: [{
          discount_id: 'd-1', type: 'hardship', amount: 1800,
          is_percent: true, rate: 40, reason: 'Hard Core',
        }],
      },
      fn_student_fee_state: {
        month: '2026-09-01', billed: true, state: 'unpaid',
        charge: 2700, paid: 0, due: 2700,
        arrears_months: 0, arrears_amount: 0, arrears_oldest: null,
        balance: 2700, family_credit: 0,
      },
      fn_student_discounts: [{
        id: 'd-1', type: 'hardship', amount: 40, is_percent: true, reason: 'Hard Core',
        status: 'approved', starts_on: '2026-09-01', ends_on: null, live: true,
        proposed_by: 'Head', approved_by: 'Head', approved_at: '2026-09-16T00:00:00Z',
      }],
      fn_add_discount: 'new-discount-id',
      fn_set_discount_status: {},
    },
  }

  async function openFees(opts: FakeOptions) {
    mount(createElement(StudentProfile, {
      studentId: 'stu-1', onBack: () => {},
    }), opts)
    // Twice in the page: the phone list and the desktop table, one shown by CSS.
    await waitFor(() => expect(screen.getAllByText('Abdullah Dar').length).toBeGreaterThan(0))
    fireEvent.click(screen.getByRole('button', { name: 'Fees' }))
    // Wait for the discount strip to have LOADED, not merely to exist. It
    // renders an ellipsis while fn_student_discounts is in flight, and
    // asserting against that is asserting against a spinner.
    await waitFor(() => expect(screen.getAllByText(/Hardship/).length).toBeGreaterThan(0))
  }

  it('10. says what the concession is WORTH this month, not only its rate', async () => {
    await openFees(CHILD)
    // "40%" is not a figure a parent can check against a receipt. The statement
    // shows Rs 1,800 and nothing on the strip tied the two together.
    expect(screen.getByText(/= Rs\s*1,800 this month/)).toBeTruthy()
    // Named twice on purpose: once under the fee it reduced, once in the list
    // of concessions. Both were missing before.
    expect(screen.getAllByText(/Hardship 40% off/).length).toBe(1)
    expect(screen.getAllByText(/saves Rs\s*1,800/).length).toBe(1)
  })

  it('11. labels the fee with the class the FIGURE is for, not this year\'s', async () => {
    await openFees(CHILD)
    expect(screen.getByText(/Monthly fee · Class 1/)).toBeTruthy()
  })

  it('12. THE SHIPPED DEFECT: the discount button sends a CHILD id', async () => {
    const calls: { name: string; args: Record<string, unknown> }[] = []
    await openFees({ ...CHILD, calls })
    fireEvent.click(screen.getByRole('button', { name: /Give a discount/ }))

    const amount = await screen.findByRole('spinbutton')
    fireEvent.change(amount, { target: { value: '25' } })
    fireEvent.click(screen.getByRole('button', { name: /Apply discount/ }))

    await waitFor(() => expect(calls.some((c) => c.name === 'fn_add_discount')).toBe(true))
    const add = calls.find((c) => c.name === 'fn_add_discount')!
    // 'enr-1' is what it used to send, and the database answered
    // "students not found in this school" every single time.
    expect(add.args.p_student_id).toBe('stu-1')
    expect(add.args.p_student_id).not.toBe('enr-1')
  })
})

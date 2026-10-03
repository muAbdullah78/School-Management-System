// @vitest-environment jsdom
/**
 * What a child already owed before the software knew them (0153).
 *
 * ASSERTION 6 IS THE ONE THIS FILE EXISTS FOR. The grid used to send one
 * "Owes Rs" figure per child against ONE month chosen above the grid for the
 * whole class. A child owing three months went in as owing one, and an
 * admission fee or a stationery bill could not go in at all. Each row now
 * carries its own list, and what is sent is asserted value by value, because
 * a payload key nobody reads is dropped without a sound.
 *
 * ASSERTION 3 IS THE OTHER. Quick Add said "Enter saves" and Enter did nothing,
 * and a save the server answered "partial" was shown as "ok" with the reason
 * thrown away.
 */
import { describe, expect, it, vi, afterEach, beforeEach } from 'vitest'
import { createElement } from 'react'
import { cleanup, render, screen, waitFor, fireEvent, within } from '@testing-library/react'
import { MemoryRouter } from 'react-router-dom'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { fakeSupabase, type FakeOptions } from './fakeSupabase'
import {
  parseAmount, dueMonths, karachiMonth, checkDues, encodeDues, decodeDues, isDuesEmpty, emptyDues,
} from '@/lib/dues'
import { QuickAdd } from '@/pages/students/QuickAdd'
import { BulkClassAdd } from '@/pages/students/BulkClassAdd'
import { DuesCard } from '@/pages/students/DuesCard'
import { Arrears } from '@/pages/fees/Arrears'
import { fmtMonth } from '@/lib/format'

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

const FEE = [{
  fee_head_id: 'h1', fee_head: 'Monthly Fee', is_recurring: true, amount: 3000,
  effective_from: '2026-04-01', next_amount: null, next_from: null,
}]
const ROLL = { on_roll: 2, taken: [1, 2], unnumbered: 0, next_free: 3 }

function mount(node: ReturnType<typeof createElement>, opts: FakeOptions) {
  current.opts = opts
  const qc = new QueryClient({
    defaultOptions: { queries: { retry: false, gcTime: 0 }, mutations: { retry: false } },
  })
  return render(createElement(MemoryRouter, null,
    createElement(QueryClientProvider, { client: qc }, node)))
}

const quick = () => createElement(QuickAdd, {
  sessionId: 'sess-1', sessionStart: '2026-04-01', classId: 'cls-1', sectionId: 'sec-1',
})
const grid = () => createElement(BulkClassAdd, {
  sessionId: 'sess-1', sessionStart: '2026-04-01', classId: 'cls-1', sectionId: 'sec-1',
  className: 'Class 1', sectionName: 'A',
})
const rdeCalls = (calls: NonNullable<FakeOptions['calls']>) =>
  calls.filter((c) => c.name === 'fn_rde_add_students')
const firstRow = (c: { args: Record<string, unknown> }) =>
  ((c.args.p as { rows: Record<string, unknown>[] }).rows)[0]

beforeEach(() => { localStorage.clear() })
afterEach(() => cleanup())

// =============================================================================
describe('the rules every screen shares', () => {
  it('1. reads an amount the way people type it, and tells empty from wrong', () => {
    expect(parseAmount('5000')).toBe(5000)
    expect(parseAmount('Rs 5,000')).toBe(5000)
    expect(parseAmount('PKR 2,500.50')).toBe(2500.5)
    expect(parseAmount('')).toBeNull()
    expect(parseAmount('   ')).toBeNull()
    expect(Number.isNaN(parseAmount('abc') as number)).toBe(true)
    expect(Number.isNaN(parseAmount('-500') as number)).toBe(true)
  })

  it('2. offers three years of finished months, last year included, never this month', () => {
    const months = dueMonths()
    expect(months).toHaveLength(36)
    expect(months).not.toContain(karachiMonth())
    // Newest first, each one month before the last.
    expect([...months].sort().reverse()).toEqual(months)
    // A school that switches in its first month has only last year's dues, so
    // the list does not stop at the start of the school year.
    expect(months.some((m) => m < '2026-04-01')).toBe(true)

    const m = months[0]
    const c = checkDues({
      months: { [m]: '3,000', [months[1]]: 'x', [karachiMonth()]: '100' },
      named: [
        { key: 'a', kind: 'stationery', label: 'Stationery', amount: '800' },
        { key: 'b', kind: 'other', label: '', amount: '500' },
        { key: 'c', kind: 'books', label: 'Books', amount: '' },
      ],
    })
    expect(c.dues).toEqual([
      { kind: 'month', month: m.slice(0, 7), amount: 3000 },
      { kind: 'stationery', label: 'Stationery', amount: 800 },
    ])
    expect(c.total).toBe(3800)
    // The bad month, this month, the nameless "other" and the empty amount.
    expect(c.problems).toHaveLength(4)
    expect(c.problems.join(' ')).toMatch(/needs a name/)

    expect(isDuesEmpty(decodeDues(encodeDues(emptyDues())))).toBe(true)
    expect(decodeDues('not json')).toEqual(emptyDues())
    expect(decodeDues(encodeDues({ months: { [m]: '1' }, named: [] })).months).toEqual({ [m]: '1' })
  })
})

// =============================================================================
describe('Quick Add takes the dues in with the child', () => {
  it('3. Enter in the name box saves, and a partial save says what did not go in', async () => {
    const calls: FakeOptions['calls'] = []
    mount(quick(), {
      calls,
      rpc: {
        fn_section_roll_state: ROLL, fn_fee_structure: FEE, fn_portal_targets: [],
        fn_rde_add_students: {
          created: 1, failed: 0, drafts: 0,
          results: [{
            row: 1, status: 'partial', student_id: 'stu-1', gr_no: '0003', roll_no: '3',
            full_name: 'Zara Owes', is_draft: true,
            message: 'Aug 2026 already has a charge of Rs 3,000 on this child’s account, so it was left alone.',
          }],
        },
      },
    })
    const name = await screen.findByPlaceholderText(/As written in the register/i)
    fireEvent.change(name, { target: { value: 'Zara Owes' } })
    fireEvent.keyDown(name, { key: 'Enter' })
    await waitFor(() => expect(rdeCalls(calls)).toHaveLength(1))
    expect(await screen.findByText(/was saved, but not all of it went in/)).toBeTruthy()
    expect(screen.getAllByText(/already has a charge of Rs 3,000/).length).toBeGreaterThan(0)
    // Not "ok": the list says to check it.
    expect(screen.getByText('check')).toBeTruthy()
  })

  it('4. ticked months are filled with the class fee and named dues go with them', async () => {
    const calls: FakeOptions['calls'] = []
    mount(quick(), {
      calls,
      rpc: {
        fn_section_roll_state: ROLL, fn_fee_structure: FEE, fn_portal_targets: [],
        fn_rde_add_students: { created: 1, failed: 0, drafts: 0, results: [
          { row: 1, status: 'created', student_id: 'stu-1', full_name: 'Zara', dues_total: 3800, dues_recorded: 2 },
        ] },
      },
    })
    fireEvent.change(await screen.findByPlaceholderText(/As written in the register/i), { target: { value: 'Zara' } })
    fireEvent.click(screen.getByRole('checkbox', { name: /Owes for earlier months/ }))
    const m = dueMonths()[0]
    await waitFor(() => expect(screen.getAllByText(/This class pays Rs 3,000 a month/).length).toBeGreaterThan(0))
    fireEvent.click(document.getElementById(`qa-dues-m-${m}`)!)
    expect((screen.getByLabelText(`Amount owed for ${fmtMonth(m)}`) as HTMLInputElement).value).toBe('3000')
    fireEvent.click(screen.getByRole('button', { name: /Stationery/ }))
    fireEvent.change(screen.getByLabelText('Amount owed for Stationery'), { target: { value: '800' } })
    expect(screen.getAllByText(/Rs 3,800 · 1 month · 1 other due/).length).toBeGreaterThan(0)

    fireEvent.click(screen.getByRole('button', { name: /Save and add the next/ }))
    await waitFor(() => expect(rdeCalls(calls)).toHaveLength(1))
    const call = rdeCalls(calls)[0]
    expect(firstRow(call).dues).toEqual([
      { kind: 'month', month: m.slice(0, 7), amount: 3000 },
      { kind: 'stationery', label: 'Stationery', amount: 800 },
    ])
    expect(firstRow(call).paid_this_month).toBe(false)
    // A request id, so a retry of a lost answer cannot admit the child twice.
    expect((call.args.p as { request_id: string }).request_id).toMatch(/^[0-9a-f-]{36}$/)
    // The dues are cleared for the next child, not carried onto them.
    await waitFor(() => expect(screen.getByText(/No previous dues entered/)).toBeTruthy())
  })

  it('5. part of this month is sent as the part, and a class with no fee cannot be marked paid', async () => {
    const calls: FakeOptions['calls'] = []
    mount(quick(), {
      calls,
      rpc: {
        fn_section_roll_state: ROLL, fn_fee_structure: FEE, fn_portal_targets: [],
        fn_rde_add_students: { created: 1, failed: 0, drafts: 0, results: [
          { row: 1, status: 'created', student_id: 'stu-1', full_name: 'Part', paid_amount: 1000 },
        ] },
      },
    })
    fireEvent.change(await screen.findByPlaceholderText(/As written in the register/i), { target: { value: 'Part' } })
    await waitFor(() => expect(screen.getAllByText(/This class pays Rs 3,000 a month/).length).toBeGreaterThan(0))
    fireEvent.click(screen.getByLabelText('Part of it is collected'))
    fireEvent.change(screen.getByLabelText("Amount of this month's fee collected"), { target: { value: '1,000' } })
    expect(screen.getByText(/Rs 2,000 still owed/)).toBeTruthy()
    fireEvent.click(screen.getByRole('button', { name: /Save and add the next/ }))
    await waitFor(() => expect(rdeCalls(calls)).toHaveLength(1))
    expect(firstRow(rdeCalls(calls)[0]).paid_this_month).toBe(true)
    expect(firstRow(rdeCalls(calls)[0]).paid_amount).toBe(1000)

    cleanup()
    mount(quick(), { rpc: { fn_section_roll_state: ROLL, fn_fee_structure: [] } })
    await waitFor(() => expect(screen.getByText(/No monthly fee is set for this class yet/)).toBeTruthy())
    expect((screen.getByLabelText(/already collected/) as HTMLInputElement).disabled).toBe(true)
  })

  it('6b. a half-typed child survives the page closing', async () => {
    const first = mount(quick(), { rpc: { fn_section_roll_state: ROLL, fn_fee_structure: FEE } })
    fireEvent.change(await screen.findByPlaceholderText(/As written in the register/i), { target: { value: 'Half Typed' } })
    await new Promise((r) => setTimeout(r, 450))
    first.unmount()
    mount(quick(), { rpc: { fn_section_roll_state: ROLL, fn_fee_structure: FEE } })
    await waitFor(() =>
      expect((screen.getByPlaceholderText(/As written in the register/i) as HTMLInputElement).value).toBe('Half Typed'))
    expect(screen.getByText(/came back from your last visit/)).toBeTruthy()
  })
})

// =============================================================================
describe('the grid keeps each child’s dues on their own row', () => {
  it('6. THE ONE THIS FILE EXISTS FOR: a row’s dues go with that row, by row number', async () => {
    localStorage.setItem('rde.grid.fees', '1')
    const calls: FakeOptions['calls'] = []
    mount(grid(), {
      calls,
      rpc: {
        fn_section_roll_state: ROLL, fn_fee_structure: FEE, fn_portal_targets: [],
        // Answered out of order and for row 2 first: mapping by position would
        // put Bad One's error on Good One and drop Good One's dues.
        fn_rde_add_students: { created: 1, failed: 1, drafts: 0, results: [
          { row: 2, status: 'error', full_name: 'Bad One', message: 'GR number 0001 is already used' },
          { row: 1, status: 'created', student_id: 's1', full_name: 'Good One', dues_total: 3000 },
        ] },
      },
    })
    const names = await waitFor(() => {
      const els = Array.from(document.querySelectorAll<HTMLInputElement>('[data-cell$=":full_name"]'))
      expect(els.length).toBeGreaterThan(1)
      return els
    })
    fireEvent.change(names[0], { target: { value: 'Good One' } })
    fireEvent.change(names[1], { target: { value: 'Bad One' } })

    const duesCells = Array.from(document.querySelectorAll<HTMLButtonElement>('[data-cell$=":dues"]'))
    fireEvent.keyDown(duesCells[0], { key: 'Enter' })
    const dialog = await screen.findByRole('dialog', { name: /Previous dues for Good One/ })
    const m = dueMonths()[0]
    await waitFor(() => expect(within(dialog).getByText(/This class pays Rs 3,000 a month/)).toBeTruthy())
    fireEvent.click(document.getElementById(`dlg-m-${m}`)!)
    fireEvent.click(within(dialog).getByRole('button', { name: 'Done' }))
    await waitFor(() => expect(duesCells[0].textContent).toMatch(/Rs 3,0001 item/))
    expect(duesCells[1].textContent).toBe('Add')

    fireEvent.click(screen.getByRole('button', { name: /^Save/ }))
    await waitFor(() => expect(rdeCalls(calls)).toHaveLength(1))
    const rows = (rdeCalls(calls)[0].args.p as { rows: Record<string, unknown>[] }).rows
    expect(rows[0].dues).toEqual([{ kind: 'month', month: m.slice(0, 7), amount: 3000 }])
    expect(rows[1].dues).toBeNull()

    await waitFor(() => expect(screen.getByText(/GR number 0001 is already used/)).toBeTruthy())
    const left = Array.from(document.querySelectorAll<HTMLInputElement>('[data-cell$=":full_name"]')).map((e) => e.value)
    expect(left).toContain('Bad One')
    expect(left).not.toContain('Good One')
  })

  it('7. a class nobody typed into does not come back as "12 rows from your last sitting"', async () => {
    const first = mount(grid(), { rpc: { fn_section_roll_state: ROLL } })
    // The roll column fills itself; that is not typing.
    await waitFor(() => {
      const r = document.querySelector<HTMLInputElement>('[data-cell$=":roll_no"]')
      expect(r?.value).toBe('3')
    })
    await new Promise((r) => setTimeout(r, 650))
    first.unmount()
    expect(localStorage.getItem('rde.grid.cls-1.sec-1')).toBeNull()
    mount(grid(), { rpc: { fn_section_roll_state: ROLL } })
    await waitFor(() => expect(document.querySelectorAll('[data-cell$=":full_name"]').length).toBeGreaterThan(0))
    expect(screen.queryByText(/came back from your last sitting/)).toBeNull()
  })

  it('8. a row with no name, a roll already used, and an old "Owes Rs" draft', async () => {
    // A draft kept by the old grid: one amount, no month.
    localStorage.setItem('rde.grid.cls-1.sec-1', JSON.stringify([
      { full_name: 'Old Draft', roll_no: '2', arrears: '2,500' },
      { father_name: 'Somebody' },
    ]))
    const calls: FakeOptions['calls'] = []
    mount(grid(), { calls, rpc: { fn_section_roll_state: ROLL, fn_fee_structure: FEE } })
    // The money brought the fee columns back, and the amount became a month due.
    const cell = await waitFor(() => {
      const el = document.querySelector<HTMLButtonElement>('[data-cell$=":dues"]')
      expect(el).toBeTruthy()
      return el!
    })
    expect(cell.textContent).toMatch(/Rs 2,5001 item/)
    expect(cell.getAttribute('aria-label')).toMatch(/Rs 2,500 · 1 month/)
    // The section's rolls have to be known before a clash can be.
    await waitFor(() => expect(screen.getByText(/on rolls 1 to 2/)).toBeTruthy())

    fireEvent.click(screen.getByRole('button', { name: /^Save/ }))
    await waitFor(() => expect(screen.getByText(/Roll 2 is already used in this section/)).toBeTruthy())
    expect(screen.getByText(/Type a name for this row, or clear it/)).toBeTruthy()
    // Neither row could go, so nothing was sent.
    expect(rdeCalls(calls)).toHaveLength(0)
  })
})

// =============================================================================
describe('the child’s page lists and takes previous dues', () => {
  const card = (canRecord = true) => createElement(DuesCard, {
    studentId: 's1', studentName: 'Zara', sessionStart: '2026-04-01', monthlyFee: 3000,
    canRecord, onChanged: () => {}, onPrint: () => {}, onCancel: () => {},
  })

  it('9. shows what was typed in and records more for a child already entered', async () => {
    const calls: FakeOptions['calls'] = []
    mount(card(), {
      calls,
      rpc: {
        fn_student_dues: { outstanding: 800, dues: [{
          invoice_id: 'i1', kind: 'stationery', carried: true, label: 'Stationery', period_month: null,
          due_date: '2026-10-03', voucher_code: 'V1', charge: 800, paid: 0, outstanding: 800,
          status: 'issued', entered_on: '2026-10-03T05:00:00Z', entered_by: 'Head',
        }] },
        fn_record_dues: { recorded: 1, months: 0, total: 5000, items: [
          { i: 1, kind: 'admission', month: null, label: 'Admission fee', amount: 5000, status: 'recorded', message: null, invoice_id: 'i2' },
        ] },
      },
    })
    expect(await screen.findByText('Stationery')).toBeTruthy()
    expect(screen.getByText('from before')).toBeTruthy()
    expect(screen.getByText(/Still owed from these/)).toBeTruthy()

    fireEvent.click(screen.getByRole('button', { name: /Add previous dues/ }))
    const dialog = await screen.findByRole('dialog', { name: /Previous dues for Zara/ })
    fireEvent.click(within(dialog).getByRole('button', { name: /Admission fee/ }))
    fireEvent.change(within(dialog).getByLabelText('Amount owed for Admission fee'), { target: { value: '5000' } })
    fireEvent.click(within(dialog).getByRole('button', { name: 'Record these dues' }))
    await waitFor(() => expect(calls.some((c) => c.name === 'fn_record_dues')).toBe(true))
    const call = calls.find((c) => c.name === 'fn_record_dues')!
    expect(call.args).toEqual({
      p_student_id: 's1',
      p_dues: [{ kind: 'admission', label: 'Admission fee', amount: 5000 }],
    })
    expect(await screen.findByText(/1 due recorded/)).toBeTruthy()
  })

  it('10. an observer sees them and cannot add, and a school without bundle 54 is told so', async () => {
    mount(card(false), { rpc: { fn_student_dues: { outstanding: 0, dues: [] } } })
    expect(await screen.findByText(/Nothing owed from before/)).toBeTruthy()
    expect(screen.queryByRole('button', { name: /Add previous dues/ })).toBeNull()

    cleanup()
    mount(card(), { rpcErrors: { fn_student_dues: 'Could not find the function public.fn_student_dues(p_student_id) in the schema cache' } })
    expect(await screen.findByText(/54_what_was_owed_before\.sql/)).toBeTruthy()
  })
})

// =============================================================================
describe('Arrears lists a child who owes only a named due', () => {
  it('11. "Other dues", with no month and no crash', async () => {
    mount(createElement(Arrears), {
      rows: { academic_sessions: [{ id: 'sess-1', name: '2026-2027', is_current: true, starts_on: '2026-04-01', ends_on: '2027-03-31' }] },
      rpc: {
        fn_arrears: [{
          student_id: 's1', gr_no: '0001', full_name: 'Only Stationery', class_name: 'Class 1',
          section_name: null, roll_no: '1', family_id: null, family_head: 'Tariq', phone: '03001234567',
          months_owed: 0, oldest_month: null, amount: 800,
        }],
      },
    })
    expect(await screen.findByText('Only Stationery', { exact: false })).toBeTruthy()
    expect(screen.getByText('Other dues')).toBeTruthy()
    expect(screen.queryByText(/since/)).toBeNull()
  })
})

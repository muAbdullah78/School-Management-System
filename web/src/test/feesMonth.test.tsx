// @vitest-environment jsdom
/**
 * The Fees screen answers the question a school actually asks.
 *
 * WHAT IT USED TO SHOW: unpaid challans, collected today, spent today, balance
 * today. Four numbers, none of which is "it is September, there are 240
 * children, how many have paid". Two of the four were also measured in the
 * server's timezone, so a fee taken before 5am in Karachi appeared on the
 * previous day.
 *
 * THE ASSERTION THAT EARNS THIS FILE IS 4. "Not charged" must be its own state
 * and must never be folded into paid or unpaid. A child nobody billed has not
 * paid and does not owe, and calling them either is how a school either chases
 * a family for a fee it never raised, or reports a month as collected when a
 * whole class was never billed. That second one is the fault the entire 0138 to
 * 0140 rebuild exists for, so a screen that hides it would undo the work.
 */
import { describe, expect, it, vi, afterEach } from 'vitest'
import { createElement } from 'react'
import { cleanup, render, screen, waitFor, fireEvent } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { fakeSupabase, type FakeOptions } from './fakeSupabase'
import { MonthHeader } from '@/pages/fees/MonthHeader'

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

/** September, 4 children on the roll: one paid, two owing, one never charged. */
const SEPTEMBER: FakeOptions = {
  rows: {},
  rpc: {
    fn_ensure_billing_current: { billed: 0, months: [] },
    fn_fees_month: {
      month: '2026-09-01', today: '2026-09-16', state: 'billed', due_date: '2026-09-10',
      roll: 4, billed: 3, not_billed: 1,
      paid: 1, unpaid: 2, part_paid: 1,
      charged_total: 9000, paid_total: 4000, due_total: 5000,
    },
    fn_fees_month_pupils: [
      {
        student_id: 's2', gr_no: 'GR-2', full_name: 'Owing Child',
        class_name: 'Prep', section_name: null, roll_no: '2',
        family_id: 'fam-2', family_head: 'Shahid Anwar',
        charge: 3000, paid: 0, due: 3000, state: 'unpaid',
      },
    ],
  },
}

function open(opts: FakeOptions) {
  current.opts = opts
  const qc = new QueryClient({
    defaultOptions: { queries: { retry: false, gcTime: 0 }, mutations: { retry: false } },
  })
  return render(
    createElement(QueryClientProvider, { client: qc },
      createElement(MonthHeader, { sessionId: 'sess-1', canWrite: true })),
  )
}

afterEach(() => cleanup())

describe('the Fees screen opens on the month', () => {
  it('1. names the month and the day, which no version of this screen did', async () => {
    open(SEPTEMBER)
    await waitFor(() => expect(screen.getByText(/September 2026/)).toBeTruthy())
    expect(screen.getByText(/Wednesday 16 September/)).toBeTruthy()
  })

  it('2. shows the roll, and how many have and have not paid', async () => {
    open(SEPTEMBER)
    await waitFor(() => expect(screen.getByText('On the roll')).toBeTruthy())
    const tile = (label: string) =>
      screen.getByText(label).parentElement?.querySelector('.text-3xl')?.textContent
    expect(tile('On the roll')).toBe('4')
    expect(tile('Paid this month')).toBe('1')
    expect(tile('Not paid yet')).toBe('2')
  })

  it('3. opens the names behind a count, because a number nobody can act on is decoration', async () => {
    open(SEPTEMBER)
    await waitFor(() => expect(screen.getByText('Not paid yet')).toBeTruthy())
    expect(screen.queryByText('Owing Child')).toBeNull()
    fireEvent.click(screen.getByText('Not paid yet'))
    // Twice in the page, which is the phone list and the desktop table; CSS
    // shows one of them. Each still has to name the child.
    await waitFor(() => expect(screen.getAllByText('Owing Child').length).toBeGreaterThan(0))
    // The parent's name is there too: the office rings the father, not the child.
    expect(screen.getAllByText(/Shahid Anwar/).length).toBeGreaterThan(0)
  })

  it('4. keeps "not charged" separate from paid and unpaid', async () => {
    open(SEPTEMBER)
    await waitFor(() => expect(screen.getByText('Not charged')).toBeTruthy())
    const tile = (label: string) =>
      screen.getByText(label).parentElement?.querySelector('.text-3xl')?.textContent
    // 1 paid + 2 unpaid + 1 not charged = the roll of 4. If "not charged" were
    // folded into either, one of those two numbers would read 2 or 3 and the
    // office would be told something untrue about a child nobody billed.
    expect(tile('Not charged')).toBe('1')
    expect(Number(tile('Paid this month')) + Number(tile('Not paid yet'))
           + Number(tile('Not charged'))).toBe(Number(tile('On the roll')))
  })

  it('5. says so in words when a month has not been charged at all', async () => {
    open({
      ...SEPTEMBER,
      rpc: {
        ...SEPTEMBER.rpc,
        fn_fees_month: {
          month: '2026-09-01', today: '2026-09-16', state: 'scheduled', due_date: null,
          roll: 40, billed: 0, not_billed: 40,
          paid: 0, unpaid: 0, part_paid: 0,
          charged_total: 0, paid_total: 0, due_total: 0,
        },
      },
    })
    // A count of zero unpaid on an unbilled month reads as "everybody has paid",
    // which is exactly the lie the old screen told for a class nobody billed.
    await waitFor(() =>
      expect(screen.getByText(/Nobody has been charged for September 2026 yet/)).toBeTruthy())
    expect(screen.getByText(/Raise the fee for all 40/)).toBeTruthy()
  })

  it('6. says a skipped month is a decision, not an oversight', async () => {
    open({
      ...SEPTEMBER,
      rpc: {
        ...SEPTEMBER.rpc,
        fn_fees_month: {
          month: '2026-09-01', today: '2026-09-16', state: 'skipped', due_date: null,
          roll: 40, billed: 0, not_billed: 40,
          paid: 0, unpaid: 0, part_paid: 0,
          charged_total: 0, paid_total: 0, due_total: 0,
        },
      },
    })
    await waitFor(() =>
      expect(screen.getByText(/No fee is charged for September 2026/)).toBeTruthy())
    // And it must NOT also nag to raise it.
    expect(screen.queryByText(/Raise the fee for all/)).toBeNull()
  })
})

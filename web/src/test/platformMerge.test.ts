/**
 * The console's school list and statement, joined with what 0155 knows.
 *
 * fn_platform_schools and fn_platform_ledger return fixed columns that an older
 * bundle pasted again would expect, so 0155 put the new facts in two readers
 * beside them and the library joins them. These tests hold the join: the facts
 * land on the right row, a payment never picks up an invoice's purpose, and a
 * database without 0155 still gets its list and statement, unchanged.
 */
import { describe, expect, it, vi } from 'vitest'
import { fakeSupabase, type FakeOptions } from './fakeSupabase'

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

const { listPlatformSchools, platformLedger } = await import('@/lib/platform')

const school = (id: string, name: string) => ({
  school_id: id, school_name: name, city: null, contact_name: null, contact_phone: null,
  plan_code: 'starter', status: 'trialing', expires_on: null, days_left: null,
  student_count: 10, student_limit: 280, limit_state: 'ok', suggested_plan: 'starter',
  needs_upgrade: false, outstanding: 0, last_paid_on: null, suspended: false,
  suspend_reason: null, archived: false,
})

describe('the school list carries what 0155 knows', () => {
  it('puts each school its own facts, by school id', async () => {
    current.opts = {
      rpc: {
        fn_platform_schools: [school('a', 'Alpha'), school('b', 'Beta')],
        fn_platform_school_billing_states: [
          { school_id: 'b', needs_price: true, trial_ends_on: '2026-10-20', paid_through: null,
            in_trial: true, credit: 0, extra_until: null },
          { school_id: 'a', needs_price: false, trial_ends_on: '2026-09-01', paid_through: '2026-12-31',
            in_trial: false, credit: 500, extra_until: '2026-12-31' },
        ],
      },
    }
    const rows = await listPlatformSchools(true)
    const a = rows.find((r) => r.school_id === 'a')!
    const b = rows.find((r) => r.school_id === 'b')!
    expect(a.needs_price).toBe(false)
    expect(a.paid_through).toBe('2026-12-31')
    expect(a.credit).toBe(500)
    expect(a.extra_until).toBe('2026-12-31')
    expect(b.needs_price).toBe(true)
    expect(b.trial_ends_on).toBe('2026-10-20')
  })

  it('without 0155 the list is the old list, not an error', async () => {
    current.opts = {
      rpc: { fn_platform_schools: [school('a', 'Alpha')] },
      rpcErrors: {
        fn_platform_school_billing_states:
          'Could not find the function public.fn_platform_school_billing_states in the schema cache',
      },
    }
    const rows = await listPlatformSchools(true)
    expect(rows).toHaveLength(1)
    expect(rows[0].needs_price).toBeUndefined()
  })

  it('any other failure of the second read is shown, not hidden', async () => {
    current.opts = {
      rpc: { fn_platform_schools: [school('a', 'Alpha')] },
      rpcErrors: { fn_platform_school_billing_states: 'Not permitted' },
    }
    await expect(listPlatformSchools(true)).rejects.toThrow('Not permitted')
  })
})

describe('the statement carries each invoice purpose and what is owed on it', () => {
  const ledger = [
    { entry_id: 'inv1', entry_date: '2026-10-01', kind: 'invoice', doc_no: 'BSH-1', description: 'x',
      charged: 2000, paid: null, voided: false, note: null, reference: null },
    { entry_id: 'inv2', entry_date: '2026-10-02', kind: 'invoice', doc_no: 'BSH-2', description: 'y',
      charged: 700, paid: null, voided: false, note: null, reference: null },
    { entry_id: 'inv1', entry_date: '2026-10-03', kind: 'payment', doc_no: null, description: 'z',
      charged: null, paid: 2000, voided: false, note: null, reference: 'T1' },
  ]

  it('joins by invoice, and a payment never takes an invoice purpose', async () => {
    current.opts = {
      rpc: {
        fn_platform_ledger: ledger,
        fn_platform_invoice_states: [
          { invoice_id: 'inv1', purpose: 'term', owed: 0 },
          { invoice_id: 'inv2', purpose: 'plan_change', owed: 700 },
        ],
      },
    }
    const rows = await platformLedger('s1')
    expect(rows[0]).toMatchObject({ purpose: 'term', owed: 0 })
    expect(rows[1]).toMatchObject({ purpose: 'plan_change', owed: 700 })
    expect(rows[2].purpose).toBeUndefined()
    expect(rows[2].owed).toBeUndefined()
  })

  it('without 0155 the statement is the old statement', async () => {
    current.opts = {
      rpc: { fn_platform_ledger: ledger },
      rpcErrors: {
        fn_platform_invoice_states:
          'Could not find the function public.fn_platform_invoice_states(p_school_id) in the schema cache',
      },
    }
    const rows = await platformLedger('s1')
    expect(rows).toHaveLength(3)
    expect(rows[1].purpose).toBeUndefined()
  })
})

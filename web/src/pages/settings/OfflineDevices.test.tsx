// @vitest-environment jsdom
// Devices and offline work: what the owner sees, switching a device off, and
// marking refused work as seen.
import { afterEach, describe, expect, it, vi } from 'vitest'
import { createElement } from 'react'
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { fakeSupabase, type FakeOptions } from '@/test/fakeSupabase'

const current: { opts: FakeOptions } = { opts: {} }
vi.mock('@/lib/supabase', () => ({
  get supabase() { return fakeSupabase(current.opts) },
  isConfigured: true,
  readStore: null,
  requireSupabase: () => fakeSupabase(current.opts),
}))

const { OfflineDevices, whatWasSent, whyListed } = await import('./OfflineDevices')

afterEach(cleanup)

const DEVICE = {
  device_id: 'd1', user_id: 'u1', name: 'Sidra Batool', role: 'class_teacher', platform: 'android',
  app_version: '1.0.0', first_seen: '2026-11-01T05:00:00Z', last_seen: '2026-11-02T05:00:00Z',
  lease_until: '2026-11-09T05:00:00Z', revoked_at: null, revoked_by: null, revoke_reason: null,
  receipt_blocks: [], refused: 1,
}
const REFUSED = {
  id: 'c1', type: 'fees.payment', status: 'rejected', occurred_at: '2026-11-02T04:00:00Z',
  received_at: '2026-11-02T05:00:00Z', user_id: 'u1', name: 'Sidra Batool', device_id: 'd1',
  error: 'This login was switched off by the school, so this was not saved.', error_code: 'login_off',
  flags: [], payload: { student_id: 's1', amount: 2500 }, result: null, reviewed_at: null, reviewed_by: null,
}

function open(opts: FakeOptions) {
  current.opts = opts
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false, gcTime: 0 }, mutations: { retry: false } } })
  return render(createElement(QueryClientProvider, { client: qc }, createElement(OfflineDevices)))
}

describe('what each entry says', () => {
  it('money by its amount, registers by how many pupils, an admission by the child', () => {
    expect(whatWasSent({ type: 'fees.payment', payload: { amount: 2500 } })).toMatch(/2,500/)
    expect(whatWasSent({ type: 'attendance.day', payload: { marks: [{}, {}, {}] } })).toBe('3 pupils')
    expect(whatWasSent({ type: 'students.admit', payload: { admission: { full_name: ' Hira Bibi ' } } })).toBe('Hira Bibi')
    expect(whatWasSent({ type: 'expenses.record', payload: null })).toBeNull()
  })

  it('a refusal in the server\'s words, a renumbering with both numbers', () => {
    expect(whyListed({ status: 'rejected', flags: [], result: null, error: 'Refused for a reason.' }))
      .toBe('Refused for a reason.')
    expect(whyListed({ status: 'applied', flags: ['receipt_renumbered', 'gr_renumbered'], error: null,
      result: { receipt_no: 1530, printed_receipt_no: 1204, typed_gr_no: '0401', gr_no: '0412' } }))
      .toBe('Recorded as receipt 1530, but printed as receipt 1204. GR 0401 was taken, so the pupil was given GR 0412.')
  })
})

describe('the screen', () => {
  it('lists the work to look at and the devices', async () => {
    open({ rpc: { fn_school_devices: [DEVICE], fn_offline_review: [REFUSED] } })
    expect(await screen.findByText(/switched off by the school/)).toBeTruthy()
    expect(screen.getByText(/Sidra Batool, Android app/)).toBeTruthy()
    expect(screen.getByText(/1 refused/)).toBeTruthy()
  })

  it('switches a device off with the reason given', async () => {
    const calls: { name: string; args: Record<string, unknown> }[] = []
    open({ calls, rpc: { fn_school_devices: [DEVICE], fn_offline_review: [], fn_revoke_device: { revoked: true, already: false } } })
    fireEvent.click(await screen.findByRole('button', { name: 'Switch off' }))
    fireEvent.change(screen.getByPlaceholderText(/Lost, stolen/), { target: { value: 'Lost on the bus' } })
    fireEvent.click(screen.getAllByRole('button', { name: 'Switch off' }).at(-1)!)
    await waitFor(() => expect(calls.find((c) => c.name === 'fn_revoke_device')).toBeTruthy())
    expect(calls.find((c) => c.name === 'fn_revoke_device')!.args)
      .toEqual({ p_device_id: 'd1', p_user_id: 'u1', p_reason: 'Lost on the bus' })
  })

  it('says so when the server keeps an entry for the owner', async () => {
    open({ rpc: { fn_school_devices: [], fn_offline_review: [REFUSED], fn_offline_dismiss: { dismissed: false } } })
    fireEvent.click(await screen.findByRole('button', { name: 'Mark as seen' }))
    expect(await screen.findByText(/Only the owner, or a principal who did not send it/)).toBeTruthy()
  })
})

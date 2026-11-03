// @vitest-environment jsdom
/**
 * Money at the counter with the connection gone or crawling, through the real
 * Collect a fee screen. Each case is a defect the client review of the offline
 * work reproduced:
 *
 *   * a fee pressed while the browser said offline was never saved, and every
 *     press ran when the line came back (one fee recorded as many times);
 *   * a payment still settling printed under whichever family was open when
 *     its answer came;
 *   * a fee taken on this device and not yet sent was invisible, so it was
 *     taken again.
 */
import { afterEach, describe, expect, it, vi } from 'vitest'
import { createElement, useState } from 'react'
import { act, cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import { MemoryRouter } from 'react-router-dom'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { fakeSupabase, type FakeOptions } from '@/test/fakeSupabase'
import { OfflineContext, type OfflineState, type Settled } from '@/offline/OfflineProvider'
import type { OutboxItem } from '@/offline/store'
import { queryClient as appQueryClient } from '@/lib/queryClient'

const current: { opts: FakeOptions } = { opts: {} }
vi.mock('@/lib/config', async (importOriginal) => ({ ...(await importOriginal<object>()), isConfigured: true }))
vi.mock('@/lib/supabase', () => ({
  get supabase() { return fakeSupabase(current.opts) }, isConfigured: true, readStore: null,
  requireSupabase: () => fakeSupabase(current.opts),
}))
vi.mock('@/auth/AuthProvider', () => ({ useAuth: () => ({ profile: { id: 'u1', role: 'owner', full_name: 'Head' } }) }))
const { FamilyCollect } = await import('@/pages/fees/FamilyCollect')

afterEach(() => {
  cleanup()
  act(() => { window.dispatchEvent(new Event('online')) })
})

const fam = (id: string, head: string, kid: string) => ({
  family: { id, head_name: head, head_cnic: null, phone: null, whatsapp: null, address: null },
  credit: 0, outstanding: 5000, month: '2026-11-01',
  children: [{ student_id: `s-${id}`, full_name: kid, gr_no: '1', status: 'active', balance: 5000, photo_path: null,
    class_name: 'Class 1', section_name: null, roll_no: '1', gross: 5000, discount: 0, net: 5000, discount_lines: [],
    month_state: 'unpaid', month_charge: 5000, month_paid: 0, month_due: 5000, arrears_months: 0, arrears_amount: 0,
    arrears_oldest: null, invoices: [] }],
})
const A = fam('fam-a', 'Aslam Khan', 'Ali Khan')
const B = fam('fam-b', 'Bashir Ahmed', 'Bilal Ahmed')
const HITS = [
  { family_id: 'fam-a', head_name: 'Aslam Khan', head_cnic: null, phone: null, children: 1, outstanding: 5000, credit: 0 },
  { family_id: 'fam-b', head_name: 'Bashir Ahmed', head_cnic: null, phone: null, children: 1, outstanding: 5000, credit: 0 },
]

const outboxItem = (payload: Record<string, unknown>, n = 1): OutboxItem => ({
  seq: n, id: `cmd-${n}`, user_id: 'u1', school_id: 's', type: 'fees.family_payment', occurred_at: '',
  payload, v: 1, status: 'pending', depends_on: [], label: 'Fee', code: null, error: null, created_wall: 0, tries: 0,
})

function offlineState(over: Partial<OfflineState>, saved: Record<string, unknown>[]): OfflineState {
  return {
    active: true, online: true, syncing: false, snapshot: null, legacyWaiting: 0, lastReport: null, copySavedAt: null,
    syncNow: vi.fn(async () => null),
    submit: vi.fn(async (w): Promise<OutboxItem> => {
      saved.push(w.payload)
      return { ...outboxItem({ ...w.payload, receipt_no: 1000 + saved.length }, saved.length), type: w.type, label: w.label }
    }),
    settle: vi.fn(async (): Promise<Settled> => ({ status: 'pending' })),
    resend: vi.fn(), discard: vi.fn(async () => undefined), clearRevokedNotice: vi.fn(async () => undefined),
    ...over,
  }
}

async function openFamily(who: string) {
  const box = await screen.findByPlaceholderText(/CNIC, phone, parent name/i)
  fireEvent.change(box, { target: { value: 'x' + who } })
  fireEvent.click(screen.getByRole('button', { name: /^Search$/ }))
  fireEvent.click(await screen.findByText(who))
}

describe('Collect a fee, offline and on a weak signal', () => {
  it('with the connection gone, Receive saves on the device at once, and only once', async () => {
    current.opts = { rows: {}, rpc: { fn_current_session: { id: 'sess-1', name: '2026-2027' }, fn_family_sheet: A, fn_find_family: HITS } }
    const saved: Record<string, unknown>[] = []
    const off = offlineState({ online: false }, saved)
    let show!: (v: boolean) => void
    function Shell() {
      const [on, setOn] = useState(true)
      show = setOn
      return on ? createElement(FamilyCollect) : createElement('p', null, 'another screen')
    }
    render(createElement(MemoryRouter, null, createElement(OfflineContext.Provider, { value: off },
      createElement(QueryClientProvider, { client: appQueryClient }, createElement(Shell)))))

    act(() => { window.dispatchEvent(new Event('offline')) })
    await openFamily('Aslam Khan')
    await screen.findByText('Ali Khan')
    fireEvent.change(screen.getByPlaceholderText('0'), { target: { value: '5000' } })
    fireEvent.click(screen.getByRole('button', { name: /Receive/ }))
    await waitFor(() => expect(saved).toHaveLength(1))
    expect(await screen.findByText(/Saved on this device/)).toBeTruthy()

    // The line comes back: nothing paused is waiting to run a second time.
    act(() => show(false)); act(() => show(true))
    act(() => { window.dispatchEvent(new Event('online')) })
    await new Promise((r) => setTimeout(r, 200))
    expect(saved).toHaveLength(1)
  })

  it('a payment still settling keeps the clerk on its family, and prints under its own name', async () => {
    current.opts = { rows: {}, rpc: { fn_current_session: { id: 'sess-1', name: '2026-2027' }, fn_family_sheet: A, fn_find_family: HITS } }
    let release!: (s: Settled) => void
    const saved: Record<string, unknown>[] = []
    const off = offlineState({ settle: vi.fn(() => new Promise<Settled>((r) => { release = r })) }, saved)
    const qc = new QueryClient({ defaultOptions: { queries: { retry: false, gcTime: 0 }, mutations: { retry: false } } })
    render(createElement(MemoryRouter, null, createElement(OfflineContext.Provider, { value: off },
      createElement(QueryClientProvider, { client: qc }, createElement(FamilyCollect)))))

    await openFamily('Aslam Khan')
    await screen.findByText('Ali Khan')
    fireEvent.change(screen.getByPlaceholderText('0'), { target: { value: '5000' } })
    fireEvent.click(screen.getByRole('button', { name: /Receive/ }))
    await waitFor(() => expect(off.settle).toHaveBeenCalled())

    // While it records, the next family cannot be opened over it.
    const next = screen.getByRole('button', { name: 'New search' }) as HTMLButtonElement
    expect(next.disabled).toBe(true)
    current.opts.rpc!.fn_family_sheet = B
    fireEvent.click(next)
    expect(screen.getByText('Ali Khan')).toBeTruthy()

    release({ status: 'pending' })
    await screen.findByText(/Saved on this device/)
    fireEvent.click(screen.getByRole('button', { name: /Print receipt/ }))
    const receipt = document.getElementById('receipt')!
    expect(saved[0].family_id).toBe('fam-a')
    expect(receipt.textContent).toContain('Aslam Khan')
    expect(receipt.textContent).not.toContain('Bashir Ahmed')
  })

  it('a fee taken on this device and not sent yet is shown on the family, so it is not taken twice', async () => {
    current.opts = { rows: {}, rpc: { fn_current_session: { id: 'sess-1', name: '2026-2027' }, fn_family_sheet: A, fn_find_family: HITS } }
    const off = offlineState({
      snapshot: {
        state: {} as never, done: [], othersWaiting: 0, pending: 1, held: 0, attention: 0,
        items: [outboxItem({ family_id: 'fam-a', amount: 5000, receipt_no: 1001 })],
      },
    }, [])
    const qc = new QueryClient({ defaultOptions: { queries: { retry: false, gcTime: 0 } } })
    render(createElement(MemoryRouter, null, createElement(OfflineContext.Provider, { value: off },
      createElement(QueryClientProvider, { client: qc }, createElement(FamilyCollect)))))

    await openFamily('Aslam Khan')
    await screen.findByText('Ali Khan')
    const notice = await screen.findByText(/taken on this device/)
    expect(notice.textContent).toMatch(/#1001/)
    expect(notice.textContent).toMatch(/Do not take it again/)
  })
})

// How screens write when the connection may not be there: registers and marks
// fall back to the outbox, money always goes through it, and a refusal keeps
// its code so a screen can offer a way on.
import { afterEach, describe, expect, it, vi } from 'vitest'
import { directOrOffline, pendingMarks, submitMoney, RefusedBySchool } from './write'
import { OfflineRefusal, type OutboxItem } from './store'
import type { OfflineState, Settled } from './OfflineProvider'

const item = (over: Partial<OutboxItem> = {}): OutboxItem => ({
  seq: 1, id: 'cmd-1', user_id: 'u', school_id: 's', type: 'attendance.day', occurred_at: '2026-11-01T05:00:00Z',
  payload: {}, v: 1, status: 'pending', depends_on: [], label: 'x', code: null, error: null,
  created_wall: 0, tries: 0, ...over,
})

function state(over: Partial<OfflineState> = {}): OfflineState {
  return {
    active: true, online: true, syncing: false, snapshot: null, legacyWaiting: 0, lastReport: null, copySavedAt: null,
    syncNow: vi.fn(async () => null),
    submit: vi.fn(async (w) => item({ type: w.type, payload: w.payload })),
    settle: vi.fn(async (): Promise<Settled> => ({ status: 'pending' })),
    resend: vi.fn(async () => 'new'), discard: vi.fn(async () => undefined),
    clearRevokedNotice: vi.fn(async () => undefined),
    ...over,
  }
}

// Node 20 (CI) has no global navigator and Node 22 has one without onLine, so
// the browser's answer is stubbed whole rather than patched onto what is there.
const setOnline = (v: boolean) => vi.stubGlobal('navigator', { onLine: v })
afterEach(() => { vi.unstubAllGlobals() })

const register = { type: 'attendance.day' as const, payload: { date: '2026-11-01', marks: [] }, label: 'Register' }

describe('registers and marks: straight to the server, saved on the device when it cannot be reached', () => {
  it('online: the direct call, nothing saved', async () => {
    const off = state()
    const direct = vi.fn(async () => ({ marked: 30 }))
    const w = await directOrOffline(off, direct, register)
    expect(w).toEqual({ queued: false, result: { marked: 30 } })
    expect(off.submit).not.toHaveBeenCalled()
  })

  it('the browser says offline: saved on the device without trying the server', async () => {
    setOnline(false)
    const off = state()
    const direct = vi.fn()
    const w = await directOrOffline(off, direct, register)
    expect(w.queued).toBe(true)
    expect(direct).not.toHaveBeenCalled()
  })

  it('the call fails for want of a network: saved on the device', async () => {
    const off = state()
    const w = await directOrOffline(off, async () => { throw new TypeError('Failed to fetch') }, register)
    expect(w.queued).toBe(true)
  })

  it('the server says no: that is the answer, nothing saved', async () => {
    const off = state()
    await expect(directOrOffline(off, async () => { throw new Error('You can only mark your class') }, register))
      .rejects.toThrow(/only mark your class/)
    expect(off.submit).not.toHaveBeenCalled()
  })

  it('unsent marks: the newest wins, a refused one does not count', () => {
    const off = state({
      snapshot: {
        items: [
          item({ id: 'a', payload: { date: 'd1', marks: [{ enrollment_id: 'e1', status: 'absent' }, { enrollment_id: 'e2', status: 'absent' }] } }),
          item({ id: 'b', payload: { date: 'd1', marks: [{ enrollment_id: 'e1', status: 'late' }] } }),
          item({ id: 'c', status: 'attention', payload: { date: 'd1', marks: [{ enrollment_id: 'e2', status: 'present' }] } }),
          item({ id: 'd', payload: { date: 'd2', marks: [{ enrollment_id: 'e3', status: 'absent' }] } }),
        ],
      } as never,
    })
    const m = pendingMarks(off, 'attendance.day', (p) => p.date === 'd1', (x) => x.status)
    expect(Object.fromEntries(m)).toEqual({ e1: 'late', e2: 'absent' })
  })
})

describe('money: always through the outbox', () => {
  const fee = { type: 'fees.payment' as const, payload: { student_id: 's1', amount: 500 }, label: 'Fee', receiptField: 'receipt_no' as const }

  it('taken by the school within the wait: its answer', async () => {
    const off = state({ settle: vi.fn(async (): Promise<Settled> => ({ status: 'applied', result: { receipt_no: 1204 }, flags: [] })) })
    const out = await submitMoney(off, fee)
    expect(out).toMatchObject({ kind: 'applied', result: { receipt_no: 1204 } })
  })

  it('not reached the school: saved, to go later, never twice', async () => {
    const out = await submitMoney(state(), fee)
    expect(out.kind).toBe('saved')
  })

  it('refused by the school: its sentence and code, and it leaves this device', async () => {
    const off = state({ settle: vi.fn(async (): Promise<Settled> => ({ status: 'attention', code: 'possible_duplicate', error: 'Looks like the same child' })) })
    const err = await submitMoney(off, fee).catch((e) => e)
    expect(err).toBeInstanceOf(RefusedBySchool)
    expect(err.code).toBe('possible_duplicate')
    expect(err.message).toBe('Looks like the same child')
    expect(off.discard).toHaveBeenCalledWith('cmd-1')
  })

  it('refused on the device while online (no hello yet): says hello and tries once more', async () => {
    let first = true
    const off = state({
      submit: vi.fn(async (w) => {
        if (first) { first = false; throw new OfflineRefusal('This device has not connected to the school yet.') }
        return item({ type: w.type, payload: w.payload })
      }),
    })
    const out = await submitMoney(off, fee)
    expect(off.syncNow).toHaveBeenCalledTimes(1)
    expect(out.kind).toBe('saved')
  })

  it('refused on the device while offline: the sentence stands', async () => {
    setOnline(false)
    const off = state({ submit: vi.fn(async () => { throw new OfflineRefusal('Offline for too long.') }) })
    await expect(submitMoney(off, fee)).rejects.toThrow(/too long/)
    expect(off.syncNow).not.toHaveBeenCalled()
  })
})

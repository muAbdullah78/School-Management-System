// @vitest-environment jsdom
// What a person sees about offline work: the bar, the notices, the page.
import { afterEach, describe, expect, it, vi } from 'vitest'
import { createElement } from 'react'
import { cleanup, fireEvent, render } from '@testing-library/react'
import { MemoryRouter } from 'react-router-dom'
import { OfflineContext, type OfflineState } from './OfflineProvider'
import { OfflineStatus, ago, hoursLeft } from './OfflineStatus'
import { OfflineWorkPage, noticeFor } from '@/pages/OfflineWorkPage'
import { blankState, type DoneItem, type OutboxItem } from './store'
import type { Snapshot } from './engine'

afterEach(cleanup)

const NOW = Date.now()

function snap(over: Partial<Snapshot> = {}, state: Partial<Snapshot['state']> = {}): Snapshot {
  return {
    state: {
      ...blankState({ userId: 'u', schoolId: 's' }),
      hello: {
        server_time: new Date(NOW).toISOString(), status: 'active', role: 'principal', can_write: true,
        revoked: false, lease_until: new Date(NOW + 5 * 86_400_000).toISOString(),
        receipt_blocks: [{ first_no: 101, last_no: 300 }], command_version: 1, min_app_version: '1.0.0',
      },
      last_sync_wall: NOW - 2 * 3_600_000,
      clock: { offset_ms: 0, measured_wall: NOW, last_seen_wall: NOW },
      ...state,
    },
    items: [], done: [], othersWaiting: 0, pending: 0, held: 0, attention: 0,
    ...over,
  }
}

function state(over: Partial<OfflineState>): OfflineState {
  return {
    active: true, online: true, syncing: false, snapshot: snap(), legacyWaiting: 0, lastReport: null, copySavedAt: null,
    syncNow: vi.fn(async () => null), submit: vi.fn(), settle: vi.fn(async () => ({ status: 'pending' as const })),
    resend: vi.fn(async () => 'new'),
    discard: vi.fn(async () => undefined), clearRevokedNotice: vi.fn(async () => undefined),
    ...over,
  }
}

function draw(el: React.ReactElement, value: OfflineState) {
  return render(createElement(MemoryRouter, null, createElement(OfflineContext.Provider, { value }, el)))
}

const item = (over: Partial<OutboxItem>): OutboxItem => ({
  seq: 1, id: 'c1', user_id: 'u', school_id: 's', type: 'fees.payment',
  occurred_at: new Date(NOW - 3_600_000).toISOString(), payload: {}, v: 1, status: 'pending',
  depends_on: [], label: 'Fee Rs 2,500, Ali Raza, receipt 1204', code: null, error: null,
  created_wall: NOW, tries: 0, ...over,
})

describe('the offline bar', () => {
  it('says nothing when online with nothing waiting', () => {
    const r = draw(createElement(OfflineStatus), state({}))
    expect(r.container.textContent).toBe('')
  })

  it('offline with work waiting: how much, that it goes later, when it last synced', () => {
    const r = draw(createElement(OfflineStatus), state({ online: false, snapshot: snap({ pending: 3 }) }))
    const t = r.container.textContent ?? ''
    expect(t).toContain('Offline.')
    expect(t).toContain('3 entries saved on this device will be sent when the connection returns.')
    expect(t).toContain('Last synced 2 hours ago.')
  })

  it('counts registers queued the old way too', () => {
    const r = draw(createElement(OfflineStatus), state({ online: false, legacyWaiting: 2 }))
    expect(r.container.textContent).toContain('2 entries saved on this device')
  })

  it('warns when less than a day of offline working is left', () => {
    const s = snap({}, {})
    s.state.hello!.lease_until = new Date(NOW + 5 * 3_600_000).toISOString()
    const r = draw(createElement(OfflineStatus), state({ online: false, snapshot: s }))
    expect(r.container.textContent).toMatch(/Connect within (4|5) hours to keep working offline/)
  })

  it('online with refused work: says so, links to it, and offers Sync now', () => {
    const v = state({ snapshot: snap({ attention: 1 }) })
    const r = draw(createElement(OfflineStatus), v)
    expect(r.container.textContent).toContain('1 entry needs your attention.')
    expect(r.getByText('Offline work').getAttribute('href')).toBe('/offline')
    fireEvent.click(r.getByText('Sync now'))
    expect(v.syncNow).toHaveBeenCalled()
  })

  it('a locked school: the server\'s own sentence', () => {
    const r = draw(createElement(OfflineStatus), state({
      snapshot: snap({ pending: 2 }, { waiting: { code: 'school_locked', error: 'The school\'s subscription has ended. This is kept on this device.' } }),
    }))
    expect(r.container.textContent).toContain('subscription has ended')
  })
})

describe('the offline work page', () => {
  it('a possible duplicate offers Admit anyway, which resends with the person\'s word', () => {
    const v = state({ snapshot: snap({ attention: 1, items: [item({
      type: 'students.admit', status: 'attention', code: 'possible_duplicate', label: 'Admit Hamza Tariq',
      error: 'Hamza Tariq (GR 0042) looks like the same child, so this admission was not made.',
    })] }) })
    const r = draw(createElement(OfflineWorkPage), v)
    expect(r.container.textContent).toContain('looks like the same child')
    fireEvent.click(r.getByText('Admit anyway'))
    expect(v.resend).toHaveBeenCalledWith('c1', { allow_duplicate: true })
  })

  it('work refused for being outside the lease cannot be sent again, only discarded', () => {
    const v = state({ snapshot: snap({ attention: 1, items: [item({ status: 'attention', code: 'outside_lease', error: 'offline too long' })] }) })
    const r = draw(createElement(OfflineWorkPage), v)
    expect(r.queryByText('Send again')).toBeNull()
    fireEvent.click(r.getByText('Discard'))
    expect(r.container.textContent).toContain('Discard this entry?')
  })

  it('shows what is left of the receipt block and when offline work must stop', () => {
    const r = draw(createElement(OfflineWorkPage), state({ snapshot: snap({}, { receipt_next: 151 }) }))
    expect(r.container.textContent).toContain('Receipt numbers left on this device150')
  })

  it('names another login\'s waiting work without showing it', () => {
    const r = draw(createElement(OfflineWorkPage), state({ snapshot: snap({ othersWaiting: 2 }) }))
    expect(r.container.textContent).toContain('2 entries saved on this computer by another login are waiting')
  })
})

describe('notices', () => {
  const done = (over: Partial<DoneItem>): DoneItem => ({
    id: 'd', user_id: 'u', type: 'fees.payment', label: 'Fee', occurred_at: '', result: {}, flags: [], finished_wall: NOW, ...over,
  })
  it('a receipt recorded under another number says both', () => {
    expect(noticeFor(done({ flags: ['receipt_renumbered'], result: { receipt_no: 1530, printed_receipt_no: 1204 } })))
      .toContain('Printed as receipt 1204, recorded as receipt 1530.')
  })
  it('a register where newer marks were kept says how many', () => {
    expect(noticeFor(done({ type: 'attendance.day', result: { kept_newer: ['e1', 'e2'] } })))
      .toBe('2 pupils were left as marked later on another device.')
  })
  it('an ordinary answer is not a notice', () => {
    expect(noticeFor(done({}))).toBeNull()
  })
  it('a GR number taken meanwhile says both numbers', () => {
    expect(noticeFor(done({ type: 'students.admit', flags: ['gr_renumbered'], result: { typed_gr_no: '0401', gr_no: '0412' } })))
      .toBe('GR number 0401 was already taken, so this pupil was given GR 0412.')
  })
  it('a register locked meanwhile says how many pupils it did not change', () => {
    expect(noticeFor(done({ type: 'attendance.day', result: { total: 2, marked: 0, skipped: 2 } })))
      .toBe('2 pupils were not changed, because the register or sheet is locked. To change a locked one, ask the owner or principal to reopen it.')
    expect(noticeFor(done({ type: 'fees.payment', result: { skipped: 2 } }))).toBeNull()
  })
  it('a sheet with a pupil no longer on it says how many were left out', () => {
    expect(noticeFor(done({ type: 'marks.exam', result: { left_out: ['e9'] } })))
      .toBe('1 pupil was left out: no longer on this register or sheet.')
  })
})

describe('small words', () => {
  it('ago', () => {
    expect(ago(null)).toBe('never')
    expect(ago(NOW - 30_000, NOW)).toBe('just now')
    expect(ago(NOW - 5 * 60_000, NOW)).toBe('5 minutes ago')
    expect(ago(NOW - 3 * 86_400_000, NOW)).toBe('3 days ago')
  })
  it('hours left', () => {
    expect(hoursLeft(new Date(NOW + 90 * 60_000).toISOString(), NOW)).toBe(1)
    expect(hoursLeft(null, NOW)).toBeNull()
  })
})

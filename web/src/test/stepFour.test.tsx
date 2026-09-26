// @vitest-environment jsdom
/**
 * Step 4: staff check-in end to end, the phone layout of Settings and Reports,
 * and the Subscription screen.
 *
 * Each case is a fault the step found, pinned so it cannot come back:
 *
 *   * a teacher asked to type a 32 character code into a text box,
 *   * a keypad that would have opened the phone's own keyboard over itself,
 *   * a scanned stranger's QR sent to the server and counted as a refusal,
 *   * a location refusal that still spent one of the ten tries,
 *   * a teacher's history that said "no attendance" when the read had failed,
 *   * a day the office typed offered as something to check out of,
 *   * a register that did not say whether a day was scanned or typed from a PIN,
 *   * a phone opening Settings on a dropdown of fourteen names,
 *   * a school with 238 pupils on a 150 plan offered "room for 200",
 *   * a billing term that switched on a stray tap,
 *   * the same transfer reported twice without a word,
 *   * "your roll is full" pinned above every screen.
 */
import { afterEach, describe, expect, it, vi } from 'vitest'
import { createElement, useState, type ReactElement } from 'react'
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

const { PinPad } = await import('@/components/checkin/PinPad')
const { CheckInPanel } = await import('@/components/checkin/CheckInPanel')
const { codeFromScan, cleanPin } = await import('@/components/checkin/checkinKit')
const { MyClass } = await import('@/pages/MyClass')
const { StaffDayRegister } = await import('@/pages/staff/StaffDayRegister')
const { StaffCheckin } = await import('@/pages/settings/StaffCheckin')
const { SettingsPage } = await import('@/pages/SettingsPage')
const { RoomForPupils } = await import('@/pages/settings/RoomForPupils')
const { NextPaymentPanel } = await import('@/pages/settings/NextPayment')
const { Subscription } = await import('@/pages/settings/Subscription')
const { LicenceBanner } = await import('@/components/LicenceBanner')

const ME = '11111111-1111-1111-1111-111111111111'
const SCHOOL = '22222222-2222-2222-2222-222222222222'

function as(role: Role, staffId: string | null = null): Profile {
  return { id: ME, full_name: 'Sidra Batool', role, staff_id: staffId, school_id: SCHOOL }
}

function open(node: ReactElement, opts: FakeOptions, profile: Profile = as('owner'), path = '/') {
  current.opts = opts
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false, gcTime: 0 }, mutations: { retry: false } } })
  const auth = {
    session: { user: { id: ME, email: 'x@example.test' } } as never,
    profile, loading: false,
    signIn: async () => ({ error: null }), signOut: async () => {},
    sendReset: async () => ({ error: null }), setPassword: async () => ({ error: null }),
  }
  return render(
    createElement(MemoryRouter, { initialEntries: [path] },
      createElement(AuthContext.Provider, { value: auth },
        createElement(QueryClientProvider, { client: qc }, node))),
  )
}

/** A phone: every media query answers "no", so nothing is wide. */
function asPhone() {
  window.matchMedia = ((q: string) => ({
    matches: false, media: q, addEventListener() {}, removeEventListener() {},
  })) as never
}
function asDesktop() {
  // @ts-expect-error jsdom has none, which the app reads as wide
  delete window.matchMedia
}

afterEach(() => { cleanup(); asDesktop() })

const today = new Date().toLocaleDateString('en-CA', { timeZone: 'Asia/Karachi' })
const at = (hhmm: string) => new Date(`${today}T${hhmm}:00+05:00`).toISOString()
const ME_BASE = {
  linked: true, active: true, today, mode: 'rotating', geofence: false, day_starts_at: '07:45:00',
  record: null, can_check_out: false, out_opens_at: null,
}

describe('the PIN, typed on keys that are not a text box', () => {
  function Harness({ onDone }: { onDone: (p: string) => void }) {
    const [v, setV] = useState('')
    return createElement(PinPad, { value: v, onChange: setV, onComplete: onDone })
  }

  it('six presses of the keys complete the PIN, and there is no input to summon the phone keyboard', () => {
    const done = vi.fn()
    const { container } = render(createElement(Harness, { onDone: done }))
    expect(container.querySelector('input')).toBeNull()
    for (const d of '482913') fireEvent.click(screen.getByRole('button', { name: d }))
    expect(done).toHaveBeenCalledWith('482913')
  })

  it('the keys stop a double tap zooming the page', () => {
    render(createElement(Harness, { onDone: () => {} }))
    expect((screen.getByRole('button', { name: '5' }) as HTMLElement).style.touchAction).toBe('manipulation')
  })

  it('a pasted "482-913" is read as six digits', () => {
    expect(cleanPin('482-913')).toBe('482913')
    expect(cleanPin(' 48 29 13 99')).toBe('482913')
  })
})

describe('a scanned QR', () => {
  it('the gate link gives its token, whatever the address', () => {
    const token = `${'a'.repeat(32)}.59400000.1a2b3c4d`
    expect(codeFromScan(`https://app.theschoolmanager.site/checkin?c=${encodeURIComponent(token)}`)).toBe(token)
  })
  it('somebody else’s QR is refused here, not sent to the server as an attempt', () => {
    expect(codeFromScan('WIFI:S:School;T:WPA;P:secret;;')).toBeNull()
    expect(codeFromScan('https://example.com/menu')).toBeNull()
  })
})

describe('the check-in panel', () => {
  it('when the school checks location and the phone blocks it, it says how to fix it and spends no try', async () => {
    const calls: FakeOptions['calls'] = []
    Object.defineProperty(navigator, 'geolocation', {
      configurable: true,
      value: { getCurrentPosition: (_ok: unknown, bad: (e: { code: number }) => void) => bad({ code: 1 }) },
    })
    open(createElement(CheckInPanel, { intent: 'in', mode: 'rotating', geofence: true, known: true, onResult: () => {} }),
      { calls })
    for (const d of '123456') fireEvent.click(screen.getByRole('button', { name: d }))
    expect((await screen.findByRole('alert')).textContent).toMatch(/allow Location for this site/i)
    expect(calls!.some((c) => c.name === 'fn_staff_check_in')).toBe(false)
  })

  it('without a location check it never asks for location, and sends the PIN', async () => {
    const calls: FakeOptions['calls'] = []
    const ask = vi.fn()
    Object.defineProperty(navigator, 'geolocation', { configurable: true, value: { getCurrentPosition: ask } })
    const got = vi.fn()
    open(createElement(CheckInPanel, { intent: 'in', mode: 'rotating', geofence: false, known: true, onResult: got }),
      { calls, rpc: { fn_staff_check_in: { status: 'ok', checked_at: at('07:52'), attendance_status: 'present', method: 'pin' } } })
    for (const d of '305871') fireEvent.click(screen.getByRole('button', { name: d }))
    await waitFor(() => expect(got).toHaveBeenCalled())
    expect(ask).not.toHaveBeenCalled()
    expect(calls!.find((c) => c.name === 'fn_staff_check_in')?.args.p_code).toBe('305871')
  })
})

describe('the teacher’s home', () => {
  const T = as('class_teacher', 'st-1')

  it('a day the office typed is shown as theirs, with no keypad and no check-out', async () => {
    open(createElement(MyClass), { rpc: {
      fn_my_checkin: { ...ME_BASE, record: { status: 'present', source: 'manual', scanned: false, method: null, checked_at: null, checked_out_at: null, late_minutes: null, worked_minutes: null, reason: 'Phone broken' } },
      fn_my_staff_attendance: [], fn_my_assignments: [],
    } }, T)
    expect(await screen.findByText(/marked by the office/)).toBeTruthy()
    expect(screen.getByText(/Phone broken/)).toBeTruthy()
    expect(screen.queryByRole('button', { name: 'Check out' })).toBeNull()
    expect(screen.queryByRole('button', { name: '5' })).toBeNull()
  })

  it('checked in, with the check-out open, it offers Check out', async () => {
    open(createElement(MyClass), { rpc: {
      fn_my_checkin: { ...ME_BASE, record: { status: 'present', source: 'qr', scanned: true, method: 'pin', checked_at: at('07:52'), checked_out_at: null, late_minutes: 0, worked_minutes: null, reason: null },
        can_check_out: true, out_opens_at: new Date(Date.now() - 60_000).toISOString() },
      fn_my_staff_attendance: [], fn_my_assignments: [],
    } }, T)
    expect(await screen.findByRole('button', { name: 'Check out' })).toBeTruthy()
    expect(screen.getByText('07:52')).toBeTruthy()
  })

  it('a school with no check-in says the office marks you, rather than offering a keypad that cannot work', async () => {
    open(createElement(MyClass), { rpc: { fn_my_checkin: { ...ME_BASE, mode: null }, fn_my_staff_attendance: [], fn_my_assignments: [] } }, T)
    expect(await screen.findByText(/the office marks your attendance/)).toBeTruthy()
    expect(screen.queryByRole('button', { name: '5' })).toBeNull()
  })

  it('the last seven days are one square each, with a letter as well as a colour', async () => {
    const y = new Date(Date.now() - 86_400_000).toLocaleDateString('en-CA', { timeZone: 'Asia/Karachi' })
    open(createElement(MyClass), { rpc: {
      fn_my_checkin: ME_BASE, fn_my_assignments: [],
      fn_my_staff_attendance: [{ attendance_date: y, status: 'absent', checked_at: null, checked_out_at: null, late_minutes: null, worked_minutes: null, source: 'manual', method: null, reason: null }],
    } }, T)
    expect((await screen.findAllByLabelText(`${y}: Absent`)).length).toBeGreaterThan(0)
  })

  it('a history that failed to load says so, rather than "nothing recorded"', async () => {
    open(createElement(MyClass), {
      rpc: { fn_my_checkin: ME_BASE, fn_my_assignments: [] },
      rpcErrors: { fn_my_staff_attendance: 'permission denied for function' },
    }, T)
    expect((await screen.findAllByText(/could not be loaded/)).length).toBeGreaterThan(0)
    expect(screen.queryByText(/Nothing recorded in the last seven days/)).toBeNull()
  })
})

describe('the office’s register', () => {
  it('reads the register that knows how each day was recorded, and says PIN or QR', async () => {
    const calls: FakeOptions['calls'] = []
    open(createElement(StaffDayRegister), { calls, rpc: { fn_staff_register_day: [
      { staff_id: 's1', full_name: 'Sidra Batool', designation: 'Teacher', employee_no: null, status: 'present', checked_at: at('07:52'), checked_out_at: null, late_minutes: 0, worked_minutes: null, source: 'qr', scanned: true, code_label: 'Main gate', code_window: 1, device: null, reason: null, marked_by_name: null, method: 'pin' },
      { staff_id: 's2', full_name: 'Imran Qureshi', designation: 'Teacher', employee_no: null, status: 'present', checked_at: at('07:40'), checked_out_at: null, late_minutes: 0, worked_minutes: null, source: 'qr', scanned: true, code_label: 'Main gate', code_window: 1, device: null, reason: null, marked_by_name: null, method: 'qr' },
    ] } })
    const table = await screen.findByRole('table')
    expect(within(table).getByText(/Typed the PIN/)).toBeTruthy()
    expect(within(table).getByText(/Scanned the QR/)).toBeTruthy()
    expect(calls!.some((c) => c.name === 'fn_staff_register_day')).toBe(true)
  })
})

describe('Settings, Staff check-in', () => {
  it('with no code it says check-in is off, rather than opening on a form that switches the poster off', async () => {
    open(createElement(StaffCheckin), { rows: { staff_checkin_codes: [] } })
    expect(await screen.findByText(/Self check-in is off/)).toBeTruthy()
  })

  it('a poster code shows its PIN, and replacing it asks first', async () => {
    open(createElement(StaffCheckin), { rows: { staff_checkin_codes: [
      { id: 'k', code: 'b'.repeat(32), label: 'Staff room', valid_from: null, valid_to: null, active: true, rotating: false, pin: '482913' },
    ] } })
    expect(await screen.findByText('482 913')).toBeTruthy()
    fireEvent.click(screen.getByRole('button', { name: 'Replace with a new code' }))
    fireEvent.click(screen.getByRole('button', { name: /Make the code and open the gate screen/ }))
    expect(await screen.findByText(/Replace the check-in code\?/)).toBeTruthy()
  })
})

describe('Settings on a phone', () => {
  it('opens on the grouped list of screens, and a screen has a way back', async () => {
    asPhone()
    open(createElement(SettingsPage), {}, as('owner'), '/settings')
    expect(await screen.findByText('Staff check-in')).toBeTruthy()
    expect(screen.queryByRole('combobox', { name: /Setting/ })).toBeNull()
    fireEvent.click(screen.getByRole('button', { name: /Backup/ }))
    expect(await screen.findByRole('button', { name: /All settings/ })).toBeTruthy()
  })
})

describe('the room on the roll', () => {
  const OVER = {
    students: 238, limit: 150, plan_code: 'starter', term_months: 1, plan_covers: 150, room: 0, at_limit: true, warn: true,
    granted_extra: false, next_plan: { code: 'growth', name: 'Growth', covers: 350, price: 3500, term_months: 1 }, request: null,
  }
  it('a school over its plan is told by how much, and the request starts above its roll, not above its limit', async () => {
    open(createElement(RoomForPupils), { rpc: { fn_my_student_limit: OVER } })
    expect(await screen.findByText(/88 more/)).toBeTruthy()
    const box = screen.getByRole('spinbutton') as HTMLInputElement
    expect(Number(box.value)).toBeGreaterThan(238)
    fireEvent.change(box, { target: { value: '200' } })
    expect(screen.getByText(/Ask for more than 238/)).toBeTruthy()
  })
})

describe('the billing term', () => {
  const NEXT = {
    has_subscription: true, plan_code: 'starter', plan_name: 'Starter', term_months: 1, status: 'active', in_trial: false,
    next_charge_on: '2026-10-08', next_charge_amount: 2000, auto_renew: false, cancel_at_period_end: false, method: null,
    terms: [{ months: 1, amount: 2000, saving: 0, chosen: true }, { months: 12, amount: 20000, saving: 4000, chosen: false }],
    sentence: 'Rs 2,000 is due by 08 Oct 2026.',
  }
  it('a tap on another term asks before it changes anything', async () => {
    const calls: FakeOptions['calls'] = []
    open(createElement(NextPaymentPanel), { calls, rpc: { fn_my_next_payment: NEXT, fn_my_discount: null } })
    fireEvent.click(await screen.findByRole('button', { name: /Yearly/ }))
    expect(calls!.some((c) => c.name === 'fn_choose_term')).toBe(false)
    expect(screen.getByText(/Pay yearly from your next payment\?/)).toBeTruthy()
  })
})

describe('reporting a payment', () => {
  it('warns when the same amount is already being checked', async () => {
    open(createElement(Subscription), { rpc: {
      fn_my_billing: {
        ok: true, licence: { status: 'active', plan_name: 'Starter' }, balance: { billed: 2000, paid: 0, outstanding: 2000 },
        documents: [], payments: [],
        reports: [{ id: 'r', amount: 2000, paid_on: '2026-09-20', method: 'bank', reference: 'X1', claimed_at: '2026-09-20T05:00:00Z', status: 'pending', decided_at: null, decision_note: null }],
        pay_to: { business_name: null, bank_name: 'Meezan Bank', title: 'T', account: '0110', iban: null, support_phone: null, support_email: null, online_available: false },
        how_to_pay: 'Transfer to the account above.',
      },
      fn_my_discount: null,
    } })
    fireEvent.click((await screen.findAllByRole('button', { name: /I have paid/ }))[0])
    expect(await screen.findByText(/is already being checked/)).toBeTruthy()
  })
})

describe('the roll notice', () => {
  it('is no longer part of the strip pinned above every screen', async () => {
    open(createElement(LicenceBanner), { rpc: { fn_my_licence: {
      ok: true, status: 'active', days_left: 200, limit_state: 'over', at_limit: true,
      limit_notice: 'Your roll is full.', limit_notice_staff: 'The roll is full.',
    } } })
    await new Promise((r) => setTimeout(r, 20))
    expect(screen.queryByText(/roll is full/)).toBeNull()
  })
})

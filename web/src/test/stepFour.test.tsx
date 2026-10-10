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

// ---------------------------------------------------------------------------
// Settings, Subscription since 0155 and 0156: one view, codes that ask first.
// ---------------------------------------------------------------------------
const { statusSentence } = await import('@/pages/settings/Subscription')
const { addDays } = await import('@/pages/settings/NextPayment')
type View = Parameters<typeof statusSentence>[0]

/** Starter's three terms, as the view prices them with no code. */
const TERMS: View['terms'] = [
  { months: 1, term_price: 2000, amount: 2000, per_month: 2000, saving: 0, discount_amount: 0, discount_note: null, chosen: true },
  { months: 3, term_price: 5400, amount: 5400, per_month: 1800, saving: 600, discount_amount: 0, discount_note: null, chosen: false },
  { months: 12, term_price: 20000, amount: 20000, per_month: 1667, saving: 4000, discount_amount: 0, discount_note: null, chosen: false },
]
/** An active Starter school paying monthly, paid for twenty more days. */
function view(p: Partial<View> = {}): View {
  return {
    plan: { code: 'starter', name: 'Starter', by_arrangement: false, student_limit: 280, min_students: 1 },
    price: { priced: true, month: 2000, quarter: 5400, year: 20000, agreed: false, agreed_at: null, agreed_reason: null, quarter_set: false, year_set: false },
    terms: TERMS, term_months: 1, status: 'active', stored_status: 'active', in_trial: false,
    trial_ends_on: addDays(today, -60), paid_from: addDays(today, -10), paid_through: addDays(today, 20),
    covered_to: addDays(today, 20), grace_days: 14, locks_on: addDays(today, 35), days_to_lock: 35,
    locked_because: null, needs_price: false, cancel_at_period_end: false, suspended: false, suspend_reason: null,
    students: {
      count: 120, limit: 280, plan_limit: 280, extra: null, extra_until: null, extra_reason: null,
      extra_expired: false, declared: 120, room: 160, warn: false, full: false, over: false,
    },
    open_invoice: null, owed: 0, credit: 0,
    next: {
      period_start: addDays(today, 21), months: 1,
      quote: {
        priced: true, plan_code: 'starter', plan_name: 'Starter', months: 1,
        period_start: addDays(today, 21), period_end: addDays(today, 50), month_price: 2000, list_amount: 2000,
        term_price: 2000, term_saving: 0, discount: null, discount_note: null, discount_amount: 0, amount: 2000,
      },
    },
    pay_now: 2000, can_request_invoice: true,
    ...p,
  }
}
const PAY_TO = { business_name: null, bank_name: 'Meezan Bank', title: 'T', account: '0110', iban: null, support_phone: '0300-1234567', support_email: null, online_available: false }
function billing(v: View, extra: Record<string, unknown> = {}) {
  return {
    ok: true, licence: { status: v.status, plan_name: v.plan.name }, subscription: v,
    balance: { billed: 0, paid: 0, outstanding: v.owed }, documents: [], payments: [], reports: [],
    pay_to: PAY_TO, how_to_pay: 'Transfer to the account above.', ...extra,
  }
}
const OPEN = {
  id: 'inv-142', doc_no: 'INV-2026-0142', months: 1, period_start: addDays(today, -3), period_end: addDays(today, 26),
  amount: 2000, total: 2000, paid: 0, owed: 2000, due_on: addDays(today, -3), discount_code: null, discount_amount: 0,
}

describe('the room on the roll', () => {
  const OVER = {
    students: 300, limit: 280, plan_code: 'starter', term_months: 1, plan_covers: 280, room: 0, at_limit: true, warn: true,
    granted_extra: false, extra_until: null,
    next_plan: { code: 'growth', name: 'Growth', covers: 1000, by_arrangement: false, price: 4000, term_months: 1 }, request: null,
  }
  it('a school over its limit is told by how much, and the request starts above its roll, not above its limit', async () => {
    open(createElement(RoomForPupils), { rpc: { fn_my_student_limit: OVER } })
    expect(await screen.findByText(/20 more/)).toBeTruthy()
    const box = screen.getByRole('spinbutton') as HTMLInputElement
    expect(Number(box.value)).toBeGreaterThan(300)
    fireEvent.change(box, { target: { value: '290' } })
    expect(screen.getByText(/Ask for more than 300/)).toBeTruthy()
  })

  it('sends a move up with the plan it names, through the existing request', async () => {
    const calls: FakeOptions['calls'] = []
    open(createElement(RoomForPupils), { calls, rpc: {
      fn_my_student_limit: OVER,
      fn_request_student_limit: { id: 'q1', status: 'pending', wants: 'move_up', what_next: 'We will work out what the bigger plan costs.' },
    } })
    fireEvent.click(await screen.findByText(/Move us up to Growth/))
    fireEvent.change(screen.getByRole('textbox', { name: /Why you need it/ }), { target: { value: 'two new sections in April' } })
    fireEvent.click(screen.getByRole('button', { name: /Ask to move up to Growth/ }))
    expect(await screen.findByText(/We will work out what the bigger plan costs/)).toBeTruthy()
    expect(calls!.find((c) => c.name === 'fn_request_student_limit')?.args).toEqual({
      p_requested: 1000, p_reason: 'two new sections in April', p_wants: 'move_up',
    })
  })
})

describe('the billing term', () => {
  const NEXT = {
    has_subscription: true, plan_code: 'starter', plan_name: 'Starter', term_months: 1, status: 'active', in_trial: false,
    auto_renew: false, cancel_at_period_end: false, method: null, terms: TERMS, view: view(),
  }
  it('a tap on another term asks before it changes anything', async () => {
    const calls: FakeOptions['calls'] = []
    open(createElement(NextPaymentPanel), { calls, rpc: { fn_my_next_payment: NEXT } })
    fireEvent.click(await screen.findByRole('button', { name: /Yearly/ }))
    expect(calls!.some((c) => c.name === 'fn_choose_term')).toBe(false)
    expect(screen.getByText(/Pay yearly from your next invoice\?/)).toBeTruthy()
  })

  it('reissues an unpaid open invoice for the new term, and says which invoice replaced it', async () => {
    const calls: FakeOptions['calls'] = []
    const v = view({ open_invoice: OPEN, owed: 2000, next: null, can_request_invoice: false })
    open(createElement(NextPaymentPanel), { calls, rpc: {
      fn_my_next_payment: { ...NEXT, view: v },
      fn_choose_term: {
        term_months: 12, changed: true, applies_from: 'the invoice we have just reissued',
        invoice: { voided: 'INV-2026-0142', raised: { doc_no: 'INV-2026-0143', amount: 20000, period_start: OPEN.period_start, period_end: addDays(today, 361), due_on: today } },
        next: { has_subscription: true },
      },
    } })
    fireEvent.click(await screen.findByRole('button', { name: /Yearly/ }))
    expect(screen.getByText(/Your open invoice INV-2026-0142 is cancelled and reissued for a year/)).toBeTruthy()
    fireEvent.click(screen.getByRole('button', { name: 'Switch' }))
    expect(await screen.findByText(/INV-2026-0143 replaces it: Rs 20,000/)).toBeTruthy()
    expect(calls!.find((c) => c.name === 'fn_choose_term')?.args).toEqual({ p_months: 12 })
  })

  it('leaves an invoice the school has started paying, and says the change comes after it', async () => {
    const v = view({ open_invoice: { ...OPEN, paid: 500, owed: 1500 }, owed: 1500, next: null, can_request_invoice: false })
    open(createElement(NextPaymentPanel), { rpc: {
      fn_my_next_payment: { ...NEXT, view: v },
      fn_choose_term: { term_months: 3, changed: true, applies_from: 'the invoice after the one you have started paying', invoice: { kept: 'INV-2026-0142', why: 'money has been paid against it' }, next: {} },
    } })
    fireEvent.click(await screen.findByRole('button', { name: /Every 3 months/ }))
    expect(screen.getByText(/You have started paying INV-2026-0142, so it stays as it is/)).toBeTruthy()
    fireEvent.click(screen.getByRole('button', { name: 'Switch' }))
    expect(await screen.findByText(/pay every three months from the invoice after it/)).toBeTruthy()
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

  it('starts the amount at what the view says to pay now, credit already off', async () => {
    const v = view({ open_invoice: { ...OPEN, paid: 500, owed: 1500 }, owed: 1500, credit: 300, pay_now: 1200, next: null, can_request_invoice: false })
    open(createElement(Subscription), { rpc: { fn_my_billing: billing(v) } })
    fireEvent.click((await screen.findAllByRole('button', { name: /I have paid/ }))[0])
    const dialog = await screen.findByRole('dialog', { name: /Tell us about your transfer/ })
    expect((within(dialog).getByRole('spinbutton') as HTMLInputElement).value).toBe('1200')
    expect(within(dialog).getByText('Total to send')).toBeTruthy()
    expect(within(dialog).getByText('Paid ahead')).toBeTruthy()
  })
})

describe('the subscription summary says where the school stands', () => {
  it('in words, for each status, from the view\'s own dates', () => {
    const on = '2026-10-10'
    expect(statusSentence(view({ status: 'trialing', in_trial: true, trial_ends_on: '2026-10-19' }), on))
      .toMatch(/Free trial, 10 days left\. It runs to 19 Oct 2026\./)
    expect(statusSentence(view({ status: 'trialing', in_trial: true, trial_ends_on: on }), on))
      .toMatch(/last day of your free trial/)
    expect(statusSentence(view({ paid_through: '2026-11-30' }), on)).toBe('Active and paid through 30 Nov 2026.')
    expect(statusSentence(view({ status: 'grace', locks_on: '2026-10-15' }), on))
      .toMatch(/keeps working until 14 Oct 2026 and locks on 15 Oct 2026/)
    expect(statusSentence(view({ status: 'locked', locked_because: 'unpaid' }), on)).toMatch(/more than fourteen days overdue/)
    expect(statusSentence(view({ status: 'locked', locked_because: 'needs_price', needs_price: true }), on))
      .toMatch(/not agreed your price yet/)
  })

  it('shows the plan line, the pupils meter amber from 90%, and what to pay now', async () => {
    const v = view({ students: { ...view().students, count: 255, room: 25, warn: true } })
    open(createElement(Subscription), { rpc: { fn_my_billing: billing(v) } })
    expect(await screen.findByText('Starter, Rs 2,000 a month')).toBeTruthy()
    expect(screen.getByText(/Active and paid through/)).toBeTruthy()
    const meter = screen.getByRole('meter', { name: /Pupils on the roll/ })
    expect(meter.getAttribute('aria-valuenow')).toBe('255')
    expect(meter.getAttribute('aria-valuemax')).toBe('280')
    expect(screen.getByText(/25 places left\. Ask us for room/)).toBeTruthy()
    expect(screen.getByText('To pay now')).toBeTruthy()
  })

  it('says when extra room ends and which limit follows it', async () => {
    const v = view({ students: { ...view().students, count: 300, limit: 320, extra: 320, extra_until: '2026-11-30', room: 20, warn: true } })
    open(createElement(Subscription), { rpc: { fn_my_billing: billing(v) } })
    expect(await screen.findByText(/Extra room for 40 pupils until 30 Nov 2026 \(320 in all\), then your plan's limit of 280 applies/)).toBeTruthy()
  })

  it('tells an Enterprise school with no price yet that we are agreeing it, and that the trial end is the lock', async () => {
    const v = view({
      plan: { code: 'enterprise', name: 'Enterprise', by_arrangement: true, student_limit: null, min_students: 1001 },
      price: { ...view().price, priced: false, month: null, quarter: null, year: null },
      terms: [], status: 'trialing', in_trial: true, trial_ends_on: addDays(today, 5), locks_on: addDays(today, 6),
      days_to_lock: 6, needs_price: true, next: null, pay_now: 0, can_request_invoice: false, paid_through: null,
      students: { ...view().students, count: 1460, limit: null, plan_limit: null, room: null },
    })
    const { container } = open(createElement(Subscription), { rpc: { fn_my_billing: billing(v) } })
    expect(await screen.findByText('Enterprise, price to be agreed with you')).toBeTruthy()
    expect(screen.getByText(/No pupil limit on Enterprise/)).toBeTruthy()
    expect(container.textContent).toMatch(/We are agreeing your price with you\. Until it is set we cannot invoice you, and the software locks when your free trial ends/)
    // No term boxes and no figure the database did not give.
    expect(screen.queryByRole('button', { name: /Yearly/ })).toBeNull()
    expect(screen.queryByRole('button', { name: 'Get my invoice' })).toBeNull()
    expect(container.textContent).not.toMatch(/Rs 0\b/)
  })
})

describe('the next payment', () => {
  it('shows the open invoice, what is owed on it, and the date the school locks without it', async () => {
    const v = view({ open_invoice: { ...OPEN, paid: 500, owed: 1500 }, owed: 1500, pay_now: 1500, next: null, can_request_invoice: false })
    open(createElement(Subscription), { rpc: { fn_my_billing: billing(v) } })
    const panel = (await screen.findByRole('heading', { name: 'Next payment' })).closest('section')!
    expect(within(panel).getByText('INV-2026-0142')).toBeTruthy()
    expect(within(panel).getByText('Still owed')).toBeTruthy()
    expect(within(panel).getByText('Rs 1,500')).toBeTruthy()
    expect(within(panel).getByText(/If payment has not reached us by .*, the software locks on .* \(35 days from today\)/)).toBeTruthy()
  })

  it('itemises the next invoice: list, term saving, code saving, amount', async () => {
    const v = view({
      term_months: 12,
      next: {
        period_start: addDays(today, 21), months: 12,
        quote: {
          ...view().next!.quote, months: 12, list_amount: 24000, term_price: 20000, term_saving: 4000,
          discount: { code: 'GROW10', label: 'Ten percent', kind: 'percent', value: 10, months_covered: 12, amount: 2000, granted_by_kind: 'school' },
          discount_amount: 2000, amount: 18000,
        },
      },
    })
    open(createElement(Subscription), { rpc: { fn_my_billing: billing(v) } })
    const panel = (await screen.findByRole('heading', { name: 'Next payment' })).closest('section')!
    expect(within(panel).getByText('12 months at Rs 2,000 a month')).toBeTruthy()
    expect(within(panel).getByText('Less, for paying a year at a time')).toBeTruthy()
    expect(within(panel).getByText('Less code GROW10 (Ten percent), 12 of 12 months')).toBeTruthy()
    expect(within(panel).getByText('Rs 18,000')).toBeTruthy()
  })

  it('raises the invoice when asked and says what it is', async () => {
    const calls: FakeOptions['calls'] = []
    open(createElement(Subscription), { calls, rpc: {
      fn_my_billing: billing(view()),
      fn_my_request_invoice: {
        invoice_id: 'inv-200', doc_no: 'INV-2026-0200', plan_code: 'starter', plan_name: 'Starter', months: 1,
        period_start: '2026-10-31', period_end: '2026-11-30', due_on: '2026-10-31', amount: 2000, term_price: 2000,
        discount_code: null, discount_amount: 0, owed: 2000, status: 'active', already: false,
      },
    } })
    fireEvent.click(await screen.findByRole('button', { name: 'Get my invoice' }))
    expect(await screen.findByText(/Invoice INV-2026-0200 is ready: Rs 2,000 for 31 Oct 2026 to 30 Nov 2026, due on 31 Oct 2026/)).toBeTruthy()
    expect(calls!.filter((c) => c.name === 'fn_my_request_invoice')).toHaveLength(1)
    expect(screen.getByRole('button', { name: 'Print it' })).toBeTruthy()
  })

  it('says why an invoice cannot be raised yet as a plain sentence', async () => {
    open(createElement(Subscription), { rpc: { fn_my_billing: billing(view()) }, rpcErrors: {
      fn_my_request_invoice: 'Your next invoice can be raised from 01 Nov 2026, thirty days before your paid period ends on 01 Dec 2026.',
    } })
    fireEvent.click(await screen.findByRole('button', { name: 'Get my invoice' }))
    const line = await screen.findByText(/Your next invoice can be raised from 01 Nov 2026/)
    expect(line.className).not.toMatch(/bg-danger/)
  })

  it('tells a school locked for money how to start again, and no longer counts days to a lock', async () => {
    const v = view({
      status: 'locked', locked_because: 'unpaid', locks_on: addDays(today, -2), days_to_lock: -2,
      open_invoice: OPEN, owed: 2000, pay_now: 2000, next: null, can_request_invoice: false,
    })
    open(createElement(Subscription), { rpc: { fn_my_billing: billing(v) } })
    expect(await screen.findByText(/more than fourteen days overdue/)).toBeTruthy()
    expect(screen.getByText(/Send Rs 2,000 and tell us with "I have paid"/)).toBeTruthy()
    expect(screen.queryByText(/If payment has not reached us by/)).toBeNull()
  })
})

describe('the invoices list', () => {
  it('shows the plan at the time, what is owed on each, a plan change, and a code\'s saving', async () => {
    const doc = (p: Record<string, unknown>) => ({
      kind: 'invoice', issued_on: '2026-09-01', due_on: '2026-09-01', plan_code: 'starter', months: 1,
      amount: 2000, tax_amount: 0, total: 2000, voided: false, paid: 0, owed: 0, purpose: 'term',
      plan_name: 'Starter', discount_code: null, discount_amount: 0, note: null, ...p,
    })
    open(createElement(Subscription), { rpc: { fn_my_billing: billing(view(), { documents: [
      doc({ id: 'd1', doc_no: 'INV-2026-0150', period_start: '2026-10-01', period_end: '2026-10-31', total: 1800, amount: 1800, owed: 1300, paid: 500, discount_code: 'GROW10', discount_amount: 200 }),
      doc({ id: 'd2', doc_no: 'INV-2026-0151', purpose: 'plan_change', plan_name: 'Growth', plan_code: 'growth', period_start: '2026-10-05', period_end: '2026-10-31', total: 1700, amount: 1700, owed: 1700 }),
    ] }) } })
    const table = (await screen.findAllByRole('table'))[0]
    expect(within(table).getByText('Rs 1,300')).toBeTruthy()
    expect(within(table).getByText('plan change')).toBeTruthy()
    expect(within(table).getByText('Growth')).toBeTruthy()
    expect(within(table).getByText('Code GROW10: Rs 200 off')).toBeTruthy()
  })
})

describe('a discount code', () => {
  const PREVIEW = {
    ok: true, code: 'GROW10', label: 'Ten percent for a year', kind: 'percent', value: 10, duration: 'months',
    duration_months: 12, summary: '10% off, for 12 months of your subscription', applies_to: 'next_invoice',
    period_start: '2026-10-31', months: 12, term_price: 20000, months_covered: 12, discount_amount: 2000, amount: 18000,
    skipped: null,
    replaces: { code: 'OLD5', label: 'Five percent', granted_by_kind: 'school', summary: '5% off, for 2 months of your subscription' },
  }
  const MINE = {
    code: 'OLD5', label: 'Five percent', kind: 'percent', value: 5, duration: 'months', ends_on: null,
    months_left: 2, months_total: 3, times_applied: 1, total_saved: 100, granted_by_us: false, can_remove: true,
    plan_codes: null, min_term_months: null, summary: '5% off, for 2 months of your subscription', trial_code: null,
    // Never on a school's screen. fn_my_discount does not send it; if it ever
    // did, the panel still must not print it.
    description: 'Given after the August complaint',
  }

  it('is checked first, shows what it takes off which invoice, and asks before it replaces the one in place', async () => {
    const calls: FakeOptions['calls'] = []
    const rpc: Record<string, unknown> = {
      fn_my_billing: billing(view({ term_months: 12 })), fn_my_discount: MINE, fn_preview_discount: PREVIEW,
      fn_my_redeem_code: { ok: false, needs_replace: true, preview: PREVIEW, reason: 'Your subscription already has OLD5 (Five percent). Using GROW10 takes it off for good.' },
    }
    const { container } = open(createElement(Subscription), { calls, rpc })
    // The current code: label, summary, months left, saved so far.
    expect(await screen.findByText(/2 of 3 months left\. Saved you Rs 100 so far\./)).toBeTruthy()
    expect(container.textContent).not.toMatch(/August complaint/)

    fireEvent.change(screen.getByRole('textbox', { name: 'Discount code' }), { target: { value: 'grow10' } })
    fireEvent.click(screen.getByRole('button', { name: 'Check' }))
    expect(await screen.findByText(/On your next invoice, from 31 Oct 2026: Rs 2,000 off, covering 12 of its 12 months\. You would pay Rs 18,000 instead of Rs 20,000\./)).toBeTruthy()
    expect(screen.getByText(/Using it takes off your current code OLD5/)).toBeTruthy()
    expect(calls!.find((c) => c.name === 'fn_preview_discount')?.args).toEqual({ p_code: 'GROW10', p_plan_code: 'starter', p_term_months: 12 })

    fireEvent.click(screen.getByRole('button', { name: 'Use this code' }))
    expect(await screen.findByText('Replace OLD5 with GROW10?')).toBeTruthy()
    expect(calls!.filter((c) => c.name === 'fn_my_redeem_code').map((c) => c.args)).toEqual([{ p_code: 'GROW10', p_replace: false }])

    rpc.fn_my_redeem_code = { ok: true, code: 'GROW10', label: 'Ten percent for a year', summary: '10% off, for 12 months of your subscription', what_next: 'It comes off your next invoice automatically.' }
    fireEvent.click(screen.getByRole('button', { name: 'Yes, use GROW10' }))
    expect(await screen.findByText(/It comes off your next invoice automatically\./)).toBeTruthy()
    expect(calls!.filter((c) => c.name === 'fn_my_redeem_code').map((c) => c.args)).toEqual([
      { p_code: 'GROW10', p_replace: false }, { p_code: 'GROW10', p_replace: true },
    ])
  })

  it('shows a refusal as a plain sentence, not an error banner, and offers nothing to press', async () => {
    open(createElement(Subscription), { rpc: {
      fn_my_billing: billing(view()), fn_my_discount: null,
      fn_preview_discount: { ok: false, reason: 'That code could be used until 03 Sep 2026.' },
    } })
    fireEvent.change(await screen.findByRole('textbox', { name: 'Discount code' }), { target: { value: 'LATE' } })
    fireEvent.click(screen.getByRole('button', { name: 'Check' }))
    const line = await screen.findByText('That code could be used until 03 Sep 2026.')
    expect(line.className).not.toMatch(/bg-danger/)
    expect(screen.queryByRole('button', { name: 'Use this code' })).toBeNull()
  })

  it('a code we gave says so and cannot be removed from here', async () => {
    open(createElement(Subscription), { rpc: {
      fn_my_billing: billing(view()), fn_my_discount: { ...MINE, granted_by_us: true, can_remove: false },
    } })
    expect(await screen.findByText(/Arranged with us, so only we can change it\. Call us to change it\./)).toBeTruthy()
    expect(screen.queryByRole('button', { name: 'Remove' })).toBeNull()
  })

  it('a code the school added comes off after a second press', async () => {
    const calls: FakeOptions['calls'] = []
    open(createElement(Subscription), { calls, rpc: {
      fn_my_billing: billing(view()), fn_my_discount: MINE, fn_my_remove_discount: { removed: true, code: 'OLD5' },
    } })
    fireEvent.click(await screen.findByRole('button', { name: 'Remove' }))
    expect(calls!.some((c) => c.name === 'fn_my_remove_discount')).toBe(false)
    fireEvent.click(screen.getByRole('button', { name: 'Remove for good' }))
    expect(await screen.findByText(/Code OLD5 is off your subscription/)).toBeTruthy()
    expect(calls!.filter((c) => c.name === 'fn_my_remove_discount')).toHaveLength(1)
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

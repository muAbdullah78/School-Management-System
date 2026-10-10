// @vitest-environment jsdom
/**
 * The operator console's subscription screens after 0155 and 0156.
 *
 * WHY A FILE OF ITS OWN. These screens changed what they promise, not just how
 * they look: raising an invoice no longer gives a school time, plans move only
 * by us with a suggested charge, Enterprise is priced one school at a time,
 * extra room ends at the next renewal, and a payment answers with what it did.
 * Each of those is a sentence the operator repeats on the phone, so each is
 * asserted here as the words on the screen AND the call the screen makes, with
 * its arguments. A screen that says the right thing and sends the wrong number
 * is the failure the `calls` log in fakeSupabase exists to catch.
 */
import { describe, expect, it, vi, afterEach } from 'vitest'
import { createElement, type ComponentType } from 'react'
import { cleanup, fireEvent, render, waitFor } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { MemoryRouter } from 'react-router-dom'
import { fakeSupabase, type FakeOptions } from './fakeSupabase'
import { AuthContext } from '@/auth/AuthProvider'
import type { SubscriptionView } from '@/lib/subscription'
import type { PlatformSchool } from '@/lib/platform'
import { fmtDate } from '@/lib/format'

vi.mock('@/lib/config', async (importOriginal) => ({
  ...(await importOriginal<typeof import('@/lib/config')>()),
  isConfigured: true,
}))

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

afterEach(cleanup)

function mount(Comp: ComponentType<Record<string, unknown>>, props: Record<string, unknown> = {}) {
  const qc = new QueryClient({
    defaultOptions: { queries: { retry: false, gcTime: 0 }, mutations: { retry: false } },
  })
  return render(
    createElement(MemoryRouter, null,
      createElement(AuthContext.Provider, {
        value: {
          session: { user: { id: 'op', email: 'op@example.test' } } as never,
          profile: null, loading: false,
          signIn: async () => ({ error: null }), signOut: async () => {},
          sendReset: async () => ({ error: null }), setPassword: async () => ({ error: null }),
        },
      },
        createElement(QueryClientProvider, { client: qc },
          createElement(Comp, props)))),
  )
}

/** Every call the screen made to one RPC, with its arguments. */
function callsTo(calls: NonNullable<FakeOptions['calls']>, name: string) {
  return calls.filter((c) => c.name === name).map((c) => c.args)
}

// ---------------------------------------------------------------- fixtures --

const SCHOOL: PlatformSchool = {
  school_id: 'sch-1', school_name: 'Al Qalam School', city: 'Lahore',
  contact_name: 'Basha Salamat', contact_phone: '0300-1234567',
  plan_code: 'starter', status: 'active', expires_on: '2026-10-31', days_left: 21,
  student_count: 250, student_limit: 280, limit_state: 'ok',
  suggested_plan: 'starter', needs_upgrade: false,
  outstanding: 0, last_paid_on: '2026-10-01',
  suspended: false, suspend_reason: null, archived: false,
}

function view(p: Partial<SubscriptionView> = {}): SubscriptionView {
  const base: SubscriptionView = {
    plan: { code: 'starter', name: 'Starter', by_arrangement: false, student_limit: 280, min_students: 1 },
    price: {
      priced: true, month: 2000, quarter: 5400, year: 20000, agreed: false, agreed_at: null,
      agreed_reason: null, quarter_set: false, year_set: false,
    },
    terms: [
      { months: 1, term_price: 2000, amount: 2000, per_month: 2000, saving: 0,
        discount_amount: 0, discount_note: null, chosen: true },
      { months: 3, term_price: 5400, amount: 4860, per_month: 1620, saving: 1140,
        discount_amount: 540, discount_note: null, chosen: false },
      { months: 12, term_price: 20000, amount: 20000, per_month: 1667, saving: 4000,
        discount_amount: 0, discount_note: 'Your code works on 3-month invoices only.', chosen: false },
    ],
    term_months: 1, status: 'active', stored_status: 'active', in_trial: false,
    trial_ends_on: '2026-09-14', paid_from: '2026-10-01', paid_through: '2026-10-31',
    covered_to: '2026-10-31', grace_days: 14, locks_on: '2026-11-15', days_to_lock: 36,
    locked_because: null, needs_price: false, cancel_at_period_end: false, suspended: false,
    suspend_reason: null,
    students: {
      count: 250, limit: 280, plan_limit: 280, extra: null, extra_until: null,
      extra_reason: null, extra_expired: false, declared: 240, room: 30,
      warn: false, full: false, over: false,
    },
    open_invoice: null, owed: 0, credit: 0,
    next: {
      period_start: '2026-11-01', months: 1,
      quote: {
        priced: true, plan_code: 'starter', plan_name: 'Starter', months: 1,
        period_start: '2026-11-01', period_end: '2026-11-30', month_price: 2000,
        list_amount: 2000, term_price: 2000, term_saving: 0, discount: null,
        discount_note: null, discount_amount: 0, amount: 2000,
      },
    },
    pay_now: 0, can_request_invoice: true,
  }
  return { ...base, ...p }
}

function detail(v: SubscriptionView | null, extra: Record<string, unknown> = {}) {
  return {
    school: { id: 'sch-1', name: 'Al Qalam School', city: 'Lahore', created_at: '2026-09-01T00:00:00Z',
      contact_name: null, contact_phone: null, contact_email: null, notes: null, active: true,
      display_name: null, address: null, phone: null, principal_name: null, has_logo: false },
    licence: {
      plan_code: v?.plan.code ?? 'starter', plan_name: v?.plan.name ?? 'Starter', status: 'active',
      cycle: 'monthly', expires_on: null, days_left: null, student_count: v?.students.count ?? 0,
      student_limit: v?.students.limit ?? null, margin_limit: null, counted_at: null,
      over_limit_since: null, limit_state: 'ok', suggested_plan: 'growth',
      plan_student_limit: v?.students.plan_limit ?? null,
      limit_override: v?.students.extra ?? null, limit_override_reason: null,
      limit_override_at: '2026-10-02T09:00:00Z', limit_override_by: 'Usman Ali',
      limit_override_until: v?.students.extra_until ?? null, limit_request: null,
    },
    money: { invoiced: 0, paid: 0, outstanding: v?.owed ?? 0, last_paid_on: null, invoice_count: 0 },
    people: [], readiness: [],
    counts: { classes: 0, sections: 0, fee_heads: 0, classes_priced: 0, students: 0, staff: 0,
      families: 0, parents_linked: 0 },
    activity: { last_payment: null, last_invoice: null, last_attendance: null, last_mark: null,
      last_certificate: null, last_till_close: null, last_message: null },
    subscription: v, discount: null, not_recorded: [],
    ...extra,
  }
}

const PLANS = [
  { code: 'starter', name: 'Starter', student_limit: 280, min_students: 1, by_arrangement: false,
    month_price: 2000, terms: [
      { months: 1, amount: 2000, per_month: 2000, saving: 0 },
      { months: 3, amount: 5400, per_month: 1800, saving: 600 },
      { months: 12, amount: 20000, per_month: 1667, saving: 4000 }], how_priced: null },
  { code: 'growth', name: 'Growth', student_limit: 1000, min_students: 281, by_arrangement: false,
    month_price: 4000, terms: [
      { months: 1, amount: 4000, per_month: 4000, saving: 0 },
      { months: 3, amount: 10800, per_month: 3600, saving: 1200 },
      { months: 12, amount: 40000, per_month: 3333, saving: 8000 }], how_priced: null },
  { code: 'enterprise', name: 'Enterprise', student_limit: null, min_students: 1001,
    by_arrangement: true, month_price: null, terms: [],
    how_priced: 'We agree a monthly price with you. Three months is 10% off it and a year is two months free.' },
]

// ------------------------------------------------------- raising an invoice --

describe('raising an invoice', () => {
  it('says raising gives no time, offers the terms at the database price, and sends the choice', async () => {
    const calls: NonNullable<FakeOptions['calls']> = []
    current.opts = {
      calls,
      rpc: {
        fn_platform_school_detail: detail(view()),
        fn_platform_raise_invoice: {
          invoice_id: 'inv-9', doc_no: 'INV-2026-0090', amount: 4860, term_price: 5400,
          list_amount: 5400, discount_code: 'SPRING10', discount_amount: 540, overridden: false,
          owed: 4860, months: 3, period_start: '2026-11-01', period_end: '2027-01-31',
          due_on: '2026-11-01', status: 'active',
        },
      },
    }
    const { RaiseInvoiceDialog } = await import('@/pages/platform/PlatformPage')
    const r = mount(RaiseInvoiceDialog as never, { school: SCHOOL, onClose: () => {} })
    await waitFor(() => expect(r.queryByText(/does not give Al Qalam School any time/i)).not.toBeNull())
    expect(r.container.textContent).toMatch(/Paying it does/)
    // The plan is named and not offered: plans move with Change plan.
    expect(r.container.textContent).toMatch(/On Starter/)
    expect(r.queryByRole('combobox')).toBeNull()
    // Every term at what the next invoice would say, the code already off.
    expect(r.container.textContent).toMatch(/Rs 4,860/)
    expect(r.container.textContent).toMatch(/Rs 540 off with their code/)
    expect(r.container.textContent).toMatch(/Your code works on 3-month invoices only/)

    fireEvent.click(r.getByLabelText(/Every 3 months/))
    fireEvent.click(r.getByText(/Raise the invoice for Rs 4,860/))
    await waitFor(() => expect(r.queryByText(/INV-2026-0090 raised/)).not.toBeNull())
    // An empty amount box means the quote: nothing typed, nothing overridden.
    expect(callsTo(calls, 'fn_platform_raise_invoice')).toEqual([
      { p_school_id: 'sch-1', p_months: 3, p_amount: null, p_reason: null },
    ])
    expect(r.container.textContent).toMatch(/Nothing changes for Al Qalam School until it is paid/)
  })

  it('asks for a reason when the amount differs, and warns that the code is used up', async () => {
    const calls: NonNullable<FakeOptions['calls']> = []
    current.opts = { calls, rpc: { fn_platform_school_detail: detail(view({
      next: { ...view().next!, quote: { ...view().next!.quote,
        discount: { code: 'SPRING10', label: 'Spring offer', kind: 'percent', value: 10,
          months_covered: 3, amount: 540, granted_by_kind: 'school' } } },
    })), fn_platform_raise_invoice: { invoice_id: 'x', doc_no: 'INV-1', amount: 4000, owed: 4000,
      months: 3, period_start: '2026-11-01', period_end: '2027-01-31', due_on: '2026-11-01',
      overridden: true, discount_code: 'SPRING10', discount_amount: 0, status: 'active' } } }
    const { RaiseInvoiceDialog } = await import('@/pages/platform/PlatformPage')
    const r = mount(RaiseInvoiceDialog as never, { school: SCHOOL, onClose: () => {} })
    await waitFor(() => expect(r.queryByLabelText(/Every 3 months/)).not.toBeNull())
    fireEvent.click(r.getByLabelText(/Every 3 months/))
    fireEvent.change(r.getByLabelText(/^Amount/), { target: { value: '4,000' } })
    expect(r.container.textContent).toMatch(/needs a reason: it is printed on the invoice/)
    expect(r.container.textContent).toMatch(/code SPRING10 is used up on this invoice/)
    const go = r.getByText(/Raise the invoice for Rs 4,000/).closest('button')!
    expect(go.disabled).toBe(true)
    fireEvent.change(r.getByLabelText(/^Reason/), { target: { value: 'Agreed on the phone with the owner' } })
    expect(go.disabled).toBe(false)
    fireEvent.click(go)
    await waitFor(() => expect(callsTo(calls, 'fn_platform_raise_invoice')).toHaveLength(1))
    expect(callsTo(calls, 'fn_platform_raise_invoice')[0]).toEqual({
      p_school_id: 'sch-1', p_months: 3, p_amount: 4000, p_reason: 'Agreed on the phone with the owner',
    })
  })

  it('says an open invoice and an unpriced school are refused, in plain words, with no button', async () => {
    current.opts = { rpc: { fn_platform_school_detail: detail(view({
      open_invoice: { id: 'i1', doc_no: 'INV-2026-0031', months: 1, period_start: '2026-11-01',
        period_end: '2026-11-30', amount: 2000, total: 2000, paid: 0, owed: 2000,
        due_on: '2026-11-01', discount_code: null, discount_amount: 0 },
    })) } }
    const { RaiseInvoiceDialog } = await import('@/pages/platform/PlatformPage')
    let r = mount(RaiseInvoiceDialog as never, { school: SCHOOL, onClose: () => {} })
    await waitFor(() => expect(r.queryByText(/already has INV-2026-0031 open/)).not.toBeNull())
    expect(r.container.textContent).toMatch(/That one is paid first/)
    expect(r.queryByText(/^Raise the invoice/)).toBeNull()
    cleanup()

    current.opts = { rpc: { fn_platform_school_detail: detail(view({
      plan: { code: 'enterprise', name: 'Enterprise', by_arrangement: true, student_limit: null, min_students: 1001 },
      price: { priced: false, month: null, quarter: null, year: null, agreed: false, agreed_at: null,
        agreed_reason: null, quarter_set: false, year_set: false },
      terms: [], needs_price: true, next: null,
    })) } }
    r = mount(RaiseInvoiceDialog as never, { school: SCHOOL, onClose: () => {} })
    await waitFor(() => expect(r.queryByText(/no price has been agreed with it yet/)).not.toBeNull())
    expect(r.queryByText(/^Raise the invoice/)).toBeNull()
  })

  it('holds a school over its limit for the period until a reason is given (SB004)', async () => {
    const calls: NonNullable<FakeOptions['calls']> = []
    current.opts = { calls, rpc: {
      fn_platform_school_detail: detail(view({
        students: { ...view().students, count: 300, over: true, full: true, warn: true, room: 0,
          // Extra room that ends before the new period does not count in it.
          extra: 320, extra_until: '2026-10-31', limit: 320 },
      })),
      fn_platform_raise_invoice: { invoice_id: 'x', doc_no: 'INV-2', amount: 2000, owed: 2000,
        months: 1, period_start: '2026-11-01', period_end: '2026-11-30', due_on: '2026-11-01',
        overridden: false, discount_code: null, discount_amount: 0, status: 'active' },
    } }
    const { RaiseInvoiceDialog } = await import('@/pages/platform/PlatformPage')
    const r = mount(RaiseInvoiceDialog as never, { school: SCHOOL, onClose: () => {} })
    await waitFor(() => expect(r.queryByText(/has 300 pupils and Starter covers 280 in the period/)).not.toBeNull())
    expect(r.container.textContent).toMatch(/Move\s+them with Change plan/)
    const go = r.getByText(/^Raise the invoice/).closest('button')!
    expect(go.disabled).toBe(true)
    fireEvent.change(r.getByLabelText(/^Reason/), { target: { value: 'Moving them next month, agreed' } })
    fireEvent.click(go)
    await waitFor(() => expect(callsTo(calls, 'fn_platform_raise_invoice')).toHaveLength(1))
    expect(callsTo(calls, 'fn_platform_raise_invoice')[0].p_reason).toBe('Moving them next month, agreed')
  })

  it('shows a refusal from the database as the sentence it is', async () => {
    current.opts = {
      rpc: { fn_platform_school_detail: detail(view()) },
      rpcErrors: { fn_platform_raise_invoice: 'Al Qalam School has 300 pupils and Starter covers 280. Move it to Growth with Change plan, or give a reason to invoice it on Starter anyway.' },
    }
    const { RaiseInvoiceDialog } = await import('@/pages/platform/PlatformPage')
    const r = mount(RaiseInvoiceDialog as never, { school: SCHOOL, onClose: () => {} })
    await waitFor(() => expect(r.queryByText(/^Raise the invoice/)).not.toBeNull())
    fireEvent.click(r.getByText(/^Raise the invoice/))
    await waitFor(() => expect(r.queryByText(/give a reason to invoice it on Starter anyway/)).not.toBeNull())
  })
})

// ---------------------------------------------------------- recording money --

describe('recording a payment', () => {
  it('says what the payment did: allocated, invoice raised, credit, status and paid through', async () => {
    const calls: NonNullable<FakeOptions['calls']> = []
    current.opts = { calls, rpc: { fn_platform_record_payment: {
      payment_id: 'p1', outstanding: 0, tax_withheld: 0, settled: 7000, awaiting_certificate: false,
      allocated: 2000, lapsed_voided: 0, credit: 1140, status: 'active', paid_through: '2027-01-31',
      not_raised_because: null,
      raised: { invoice_id: 'i2', doc_no: 'INV-2026-0091', amount: 4860, owed: 0, months: 3,
        period_start: '2026-11-01', period_end: '2027-01-31' },
    } } }
    const { PaymentDialog } = await import('@/pages/platform/PlatformPage')
    const r = mount(PaymentDialog as never, { school: { ...SCHOOL, outstanding: 2000 }, onClose: () => {} })
    fireEvent.change(r.getByLabelText(/^Amount/), { target: { value: '7,000' } })
    fireEvent.click(r.getByText('Record'))
    await waitFor(() => expect(r.queryByText(/Rs 7,000 recorded for Al Qalam School/)).not.toBeNull())
    expect(callsTo(calls, 'fn_platform_record_payment')[0]).toMatchObject({
      p_school_id: 'sch-1', p_amount: 7000, p_method: 'bank',
    })
    const text = r.container.textContent ?? ''
    expect(text).toMatch(/Rs 2,000 went against what they owed/)
    expect(text).toMatch(/INV-2026-0091, was raised for 3 month\(s\)/)
    expect(text).toMatch(/Rs 1,140 is left over as credit/)
    expect(text).toMatch(/They are nowPaying/)
    expect(text).toContain(`Paid through${fmtDate('2027-01-31')}`)
  })
})

// -------------------------------------------------------------- plan moves --

describe('changing a plan', () => {
  const QUOTE = {
    from: { code: 'starter', name: 'Starter', limit: 280, term_price: 20000 },
    to: { code: 'growth', name: 'Growth', limit: 1000, term_price: 40000, by_arrangement: false },
    term_months: 12, students: 300, fits: true, in_trial: false,
    paid_from: '2026-07-01', paid_to: '2027-06-30', days_left: 263, days_in_period: 365,
    suggested_charge: 14411,
    explain: 'Rs 14,411 for the 263 day(s) left of the period paid to 30 Jun 2027: the difference between Rs 40,000 and Rs 20,000 for a 12-month term, pro rata.',
  }

  it('shows the suggested charge and its reasons, says extra room ends, and sends what we chose', async () => {
    const calls: NonNullable<FakeOptions['calls']> = []
    current.opts = { calls, rpc: {
      fn_platform_school_detail: detail(view({
        students: { ...view().students, count: 300, extra: 320, extra_until: '2027-06-30', limit: 320 },
      })),
      fn_signup_plans: PLANS,
      fn_platform_plan_change_quote: QUOTE,
      fn_platform_change_plan: { from: 'starter', to: 'growth', student_limit: 1000, charge: 12000,
        invoice_id: 'i3', doc_no: 'INV-2026-0095', suggested_charge: 14411, status: 'active' },
    } }
    const { ChangePlanDialog } = await import('@/pages/platform/SchoolDetail')
    const r = mount(ChangePlanDialog as never, {
      schoolId: 'sch-1', schoolName: 'Al Qalam School', onClose: () => {},
    })
    await waitFor(() => expect(r.queryByLabelText(/Growth/)).not.toBeNull())
    // The plan they are on is shown and cannot be picked.
    expect((r.getByLabelText(/Starter/) as HTMLInputElement).disabled).toBe(true)
    fireEvent.click(r.getByLabelText(/Growth/))
    await waitFor(() => expect(r.queryByText(/Rs 14,411 for the 263 day/)).not.toBeNull())
    expect(r.container.textContent).toMatch(/263 of 365 days left/)
    expect(r.container.textContent).toMatch(/extra room for 320 pupils/)
    expect(r.container.textContent).toMatch(/ends\s+with the move/)

    // Change the charge, give a reason, move.
    fireEvent.click(r.getByLabelText(/A different amount/))
    fireEvent.change(r.getByLabelText(/Charge in rupees/), { target: { value: '12,000' } })
    fireEvent.change(r.getByLabelText(/Why they are moving/), { target: { value: 'Principal called: 300 on the roll' } })
    fireEvent.click(r.getByText(/Move to Growth and charge Rs 12,000/))
    await waitFor(() => expect(r.queryByText(/INV-2026-0095/)).not.toBeNull())
    expect(callsTo(calls, 'fn_platform_change_plan')).toEqual([{
      p_school_id: 'sch-1', p_plan_code: 'growth', p_reason: 'Principal called: 300 on the roll',
      p_charge: 12000, p_agreed_monthly: null,
    }])
  })

  it('can charge nothing', async () => {
    const calls: NonNullable<FakeOptions['calls']> = []
    current.opts = { calls, rpc: {
      fn_platform_school_detail: detail(view()), fn_signup_plans: PLANS,
      fn_platform_plan_change_quote: QUOTE,
      fn_platform_change_plan: { from: 'starter', to: 'growth', student_limit: 1000, charge: 0,
        invoice_id: null, doc_no: null, suggested_charge: 14411, status: 'active' },
    } }
    const { ChangePlanDialog } = await import('@/pages/platform/SchoolDetail')
    const r = mount(ChangePlanDialog as never, { schoolId: 'sch-1', schoolName: 'Al Qalam School',
      initialPlan: 'growth', onClose: () => {} })
    await waitFor(() => expect(r.queryByLabelText(/Nothing now/)).not.toBeNull())
    fireEvent.click(r.getByLabelText(/Nothing now/))
    fireEvent.change(r.getByLabelText(/Why they are moving/), { target: { value: 'Courtesy move agreed' } })
    fireEvent.click(r.getByText(/^Move to Growth$/))
    await waitFor(() => expect(r.queryByText(/Nothing was charged/)).not.toBeNull())
    expect(callsTo(calls, 'fn_platform_change_plan')[0].p_charge).toBe(0)
  })

  it('refuses a move the roll does not fit before anything is pressed', async () => {
    current.opts = { rpc: {
      fn_platform_school_detail: detail(view({
        plan: { code: 'growth', name: 'Growth', by_arrangement: false, student_limit: 1000, min_students: 281 },
      })),
      fn_signup_plans: PLANS,
      fn_platform_plan_change_quote: { ...QUOTE, from: QUOTE.to, to: { ...QUOTE.from, by_arrangement: false },
        students: 400, fits: false, suggested_charge: 0 },
    } }
    const { ChangePlanDialog } = await import('@/pages/platform/SchoolDetail')
    const r = mount(ChangePlanDialog as never, { schoolId: 'sch-1', schoolName: 'Al Qalam School',
      initialPlan: 'starter', initialReason: 'Asked to come down a plan', onClose: () => {} })
    await waitFor(() => expect(r.queryAllByText(/This move is refused/).length).toBeGreaterThan(0))
    expect(r.getByText(/^Move to Starter/).closest('button')!.disabled).toBe(true)
  })

  it('asks Enterprise for its monthly price and sends it with the move', async () => {
    const calls: NonNullable<FakeOptions['calls']> = []
    current.opts = { calls, rpc: {
      fn_platform_school_detail: detail(view({
        plan: { code: 'growth', name: 'Growth', by_arrangement: false, student_limit: 1000, min_students: 281 },
      })),
      fn_signup_plans: PLANS,
      fn_platform_plan_change_quote: { ...QUOTE, to: { code: 'enterprise', name: 'Enterprise', limit: null,
        term_price: 600000, by_arrangement: true }, suggested_charge: 0,
        explain: 'Nothing to charge.' },
      fn_platform_change_plan: { from: 'growth', to: 'enterprise', student_limit: null, charge: 0,
        invoice_id: null, doc_no: null, suggested_charge: 0, status: 'active' },
    } }
    const { ChangePlanDialog } = await import('@/pages/platform/SchoolDetail')
    const r = mount(ChangePlanDialog as never, { schoolId: 'sch-1', schoolName: 'Al Qalam School',
      initialPlan: 'enterprise', onClose: () => {} })
    await waitFor(() => expect(r.queryByLabelText(/Monthly price agreed/)).not.toBeNull())
    fireEvent.change(r.getByLabelText(/Monthly price agreed/), { target: { value: '60000' } })
    fireEvent.change(r.getByLabelText(/Why they are moving/), { target: { value: 'Roll passed 1,000 in September' } })
    await waitFor(() => expect(r.getByText(/^Move to Enterprise/).closest('button')!.disabled).toBe(false))
    fireEvent.click(r.getByText(/^Move to Enterprise/))
    await waitFor(() => expect(callsTo(calls, 'fn_platform_change_plan')).toHaveLength(1))
    expect(callsTo(calls, 'fn_platform_change_plan')[0]).toMatchObject({
      p_plan_code: 'enterprise', p_agreed_monthly: 60000,
    })
  })
})

// --------------------------------------------------------- Enterprise price --

describe('the Enterprise price', () => {
  const ENT = {
    plan: { code: 'enterprise', name: 'Enterprise', by_arrangement: true, student_limit: null, min_students: 1001 },
    students: { ...view().students, count: 1400, limit: null, plan_limit: null, room: null },
  }

  it('flags a school waiting for its price, with the trial end, and offers Set price', async () => {
    current.opts = { rpc: { fn_platform_school_detail: detail(view({
      ...ENT, needs_price: true, in_trial: true, paid_through: null, status: 'trialing',
      trial_ends_on: '2026-10-20', locks_on: '2026-10-21', terms: [], next: null,
      price: { priced: false, month: null, quarter: null, year: null, agreed: false, agreed_at: null,
        agreed_reason: null, quarter_set: false, year_set: false },
    })) } }
    const { PlanPanel } = await import('@/pages/platform/SchoolDetail')
    const r = mount(PlanPanel as never, { schoolId: 'sch-1', schoolName: 'Al Qalam School' })
    await waitFor(() => expect(r.queryByText('No price agreed yet.')).not.toBeNull())
    expect(r.container.textContent).toContain(fmtDate('2026-10-20'))
    expect(r.container.textContent).toMatch(/with no grace/)
    expect(r.queryByText('Set price')).not.toBeNull()
  })

  it('shows the agreed price, which figures follow, and how it was agreed', async () => {
    current.opts = { rpc: { fn_platform_school_detail: detail(view({
      ...ENT,
      price: { priced: true, month: 60000, quarter: 162000, year: 550000, agreed: true,
        agreed_at: '2026-10-03T10:00:00Z', agreed_reason: 'Agreed with the principal for 1,400 pupils',
        quarter_set: false, year_set: true },
    })) } }
    const { PlanPanel } = await import('@/pages/platform/SchoolDetail')
    const r = mount(PlanPanel as never, { schoolId: 'sch-1', schoolName: 'Al Qalam School' })
    await waitFor(() => expect(r.queryByText('Rs 60,000')).not.toBeNull())
    expect(r.queryByText('Rs 162,000')).not.toBeNull()
    expect(r.queryByText(/follows: 10% off three months/)).not.toBeNull()
    expect(r.queryByText('Rs 550,000')).not.toBeNull()
    expect(r.container.textContent).toMatch(/Agreed with the principal for 1,400 pupils/)
    expect(r.queryByText('Change the price')).not.toBeNull()
  })

  it('sets a price with its caps checked and the reason sent', async () => {
    const calls: NonNullable<FakeOptions['calls']> = []
    current.opts = { calls, rpc: { fn_platform_set_price: {
      monthly: 60000, quarterly: 162000, yearly: 600000, quarterly_is_derived: true,
      yearly_is_derived: true, invoice: null, status: 'trialing',
    } } }
    const { SetPriceDialog } = await import('@/pages/platform/SchoolDetail')
    const r = mount(SetPriceDialog as never, { schoolId: 'sch-1', schoolName: 'Al Qalam School',
      v: view({ ...ENT, needs_price: true }), onClose: () => {} })
    fireEvent.change(r.getByLabelText(/A month/), { target: { value: '60,000' } })
    fireEvent.change(r.getByLabelText(/Three months/), { target: { value: '200000' } })
    expect(r.container.textContent).toMatch(/no more than three times the monthly price \(Rs 180,000\)/)
    fireEvent.change(r.getByLabelText(/Three months/), { target: { value: '' } })
    fireEvent.change(r.getByLabelText(/How it was agreed/), { target: { value: 'Agreed with the owner on 3 Oct' } })
    fireEvent.click(r.getByText('Save the price'))
    await waitFor(() => expect(r.queryByText(/price is set/)).not.toBeNull())
    expect(callsTo(calls, 'fn_platform_set_price')).toEqual([{
      p_school_id: 'sch-1', p_monthly: 60000, p_quarterly: null, p_yearly: null,
      p_reason: 'Agreed with the owner on 3 Oct',
    }])
    expect(r.queryAllByText('follows from the monthly')).toHaveLength(2)
  })
})

// ---------------------------------------------------------------- extra room --

describe('extra room', () => {
  it('shows the allowance with its end date, who gave it and why', async () => {
    current.opts = { rpc: { fn_platform_school_detail: detail(view({
      students: { ...view().students, count: 300, limit: 320, extra: 320, extra_until: '2026-10-31',
        extra_reason: 'Second campus opens in November' },
    })) } }
    const { OverviewTab } = await import('@/pages/platform/SchoolDetail')
    const r = mount(OverviewTab as never, { schoolId: 'sch-1' })
    await waitFor(() => expect(r.queryByText(/Room for 320 pupils/)).not.toBeNull())
    const text = r.container.textContent ?? ''
    expect(text).toContain(`until ${fmtDate('2026-10-31')}, then Starter’s limit of 280 applies`)
    expect(text).toMatch(/by Usman Ali/)
    expect(text).toMatch(/Second campus opens in November/)
    expect(r.queryByText('End it now')).not.toBeNull()
  })

  it('grants only above the plan, with a reason, and says until when', async () => {
    const calls: NonNullable<FakeOptions['calls']> = []
    current.opts = { calls, rpc: {
      fn_platform_school_detail: detail(view()),
      fn_platform_grant_student_limit: { limit: 320, until: '2026-10-31', was: null, partial: false },
    } }
    const { OverviewTab } = await import('@/pages/platform/SchoolDetail')
    const r = mount(OverviewTab as never, { schoolId: 'sch-1' })
    await waitFor(() => expect(r.queryByText('Give extra room')).not.toBeNull())
    fireEvent.click(r.getByText('Give extra room'))
    fireEvent.change(r.getByLabelText(/Pupils they may have/), { target: { value: '250' } })
    expect(r.container.textContent).toMatch(/Extra room is more than the 280 pupils Starter/)
    fireEvent.change(r.getByLabelText(/Pupils they may have/), { target: { value: '320' } })
    fireEvent.change(r.getByLabelText(/^Reason/), { target: { value: 'New wing opening this month' } })
    fireEvent.click(r.getByText(/^Allow 320 pupils until/))
    await waitFor(() => expect(callsTo(calls, 'fn_platform_grant_student_limit')).toHaveLength(1))
    expect(callsTo(calls, 'fn_platform_grant_student_limit')[0]).toEqual({
      p_school_id: 'sch-1', p_limit: 320, p_note: 'New wing opening this month',
    })
  })

  it('offers none on Enterprise, which has no limit', async () => {
    current.opts = { rpc: { fn_platform_school_detail: detail(view({
      plan: { code: 'enterprise', name: 'Enterprise', by_arrangement: true, student_limit: null, min_students: 1001 },
      students: { ...view().students, limit: null, plan_limit: null },
    })) } }
    const { OverviewTab } = await import('@/pages/platform/SchoolDetail')
    const r = mount(OverviewTab as never, { schoolId: 'sch-1' })
    await waitFor(() => expect(r.queryByText(/no pupil limit, so there is no extra room to give/)).not.toBeNull())
    expect(r.queryByText('Give extra room')).toBeNull()
  })
})

// ----------------------------------------------------------- the renewal run --

describe('the renewal run', () => {
  it('names the new outcomes and says it never invoices a trial', async () => {
    current.opts = { rpc: { fn_platform_run_renewals: {
      run_id: 'r1', dry_run: true, as_at: '2026-10-10', considered: 3, invoiced: 0, skipped: 3, failed: 0,
      note: 'Nothing was changed.',
      attempts: [
        { school_name: 'Trial School', amount: 2000, outcome: 'trial_ending',
          message: 'Trial ends 12 Oct 2026. Trials are not invoiced by the run.' },
        { school_name: 'Big School', amount: null, outcome: 'needs_price',
          message: 'No price has been agreed with this school.' },
        { school_name: 'Paying School', amount: 4000, outcome: 'would_invoice', message: null },
      ],
    } } }
    const { RenewalRunStrip } = await import('@/pages/platform/RenewalRun')
    const r = mount(RenewalRunStrip as never)
    expect(r.container.textContent).toMatch(/It never invoices a trial/)
    fireEvent.click(r.getByText('Show me who is due'))
    await waitFor(() => expect(r.queryByText('trial ending, not billed')).not.toBeNull())
    expect(r.queryByText('no price agreed')).not.toBeNull()
    // Only the one that would actually be billed is counted on the button.
    expect(r.queryByText('Raise 1 invoice(s)')).not.toBeNull()
  })
})

// ------------------------------------------------------------- a new school --

describe('adding a school', () => {
  it('lets the number of pupils pick the plan, and sends an Enterprise price with its reason', async () => {
    const calls: NonNullable<FakeOptions['calls']> = []
    current.opts = { calls, rpc: {
      fn_signup_plans: PLANS,
      fn_platform_create_school: { school_id: 'new-1', name: 'Roots', plan_code: 'enterprise',
        trial_ends_on: '2026-10-23', trial_days: 14, still_needed: 'Nobody can sign in yet.' },
    } }
    const { NewSchoolDialog } = await import('@/pages/platform/NewSchool')
    const r = mount(NewSchoolDialog as never, { onClose: () => {}, onCreated: () => {} })
    fireEvent.change(r.getByLabelText(/School name/), { target: { value: 'Roots' } })
    fireEvent.change(r.getByLabelText(/Pupils on their roll/), { target: { value: '250' } })
    await waitFor(() => expect(r.queryByText('Starter')).not.toBeNull())
    expect(r.container.textContent).toMatch(/Rs 20,000/)
    fireEvent.change(r.getByLabelText(/Pupils on their roll/), { target: { value: '1500' } })
    await waitFor(() => expect(r.queryByText('Enterprise')).not.toBeNull())
    expect(r.container.textContent).toMatch(/We agree a monthly price with you/)
    fireEvent.change(r.getByLabelText(/Agreed price a month/), { target: { value: '60000' } })
    expect(r.getByText('Add the school').closest('button')!.disabled).toBe(true)
    fireEvent.change(r.getByLabelText(/How it was agreed/), { target: { value: 'Agreed at the demo, 1,500 pupils' } })
    fireEvent.click(r.getByLabelText(/Yearly/))
    fireEvent.click(r.getByText('Add the school'))
    await waitFor(() => expect(callsTo(calls, 'fn_platform_create_school')).toHaveLength(1))
    expect(callsTo(calls, 'fn_platform_create_school')[0].p).toMatchObject({
      name: 'Roots', plan_code: null, students: 1500, term_months: 12, trial_days: 14,
      agreed_monthly: 60000, agreed_reason: 'Agreed at the demo, 1,500 pupils',
    })
  })
})

// ------------------------------------------------------------ room requests --

describe('requests for room', () => {
  const REQ = {
    id: 'req-1', school_id: 'sch-1', school_name: 'Al Qalam School',
    contact_name: 'Basha Salamat', contact_phone: '0300-1234567', plan_code: 'starter',
    requested_limit: 320, reason: 'Second campus in November', wants: 'more_room',
    requested_at: '2026-10-01T09:00:00Z', count_at_request: 278, students_now: 280,
    plan_covers: 280, effective_limit: 280, suggested_plan: 'growth', suggested_plan_covers: 1000,
    status: 'pending', decided_at: null, granted_limit: null, decision_note: null,
  }

  it('answers more room with extra room until the next renewal', async () => {
    const calls: NonNullable<FakeOptions['calls']> = []
    current.opts = { calls, rpc: {
      fn_platform_limit_requests: [REQ],
      fn_platform_grant_student_limit: { limit: 320, until: '2026-10-31', was: null, partial: false },
    } }
    const { RoomRequests } = await import('@/pages/platform/RoomRequests')
    const r = mount(RoomRequests as never)
    await waitFor(() => expect(r.queryByText('Give them room')).not.toBeNull())
    expect(r.queryByText('Move them up')).toBeNull()
    fireEvent.click(r.getByText('Give them room'))
    expect(r.container.textContent).toMatch(/Until their next renewal/)
    fireEvent.change(r.getByLabelText(/Why they get it/), { target: { value: 'Second campus, agreed' } })
    fireEvent.click(r.getByText('Allow 320 pupils'))
    await waitFor(() => expect(r.queryByText(/has room/)).not.toBeNull())
    expect(r.container.textContent).toContain(`until ${fmtDate('2026-10-31')}`)
    expect(callsTo(calls, 'fn_platform_grant_student_limit')[0]).toEqual({
      p_school_id: 'sch-1', p_limit: 320, p_note: 'Second campus, agreed',
    })
  })

  it('answers a move-up through Change plan with the plan that fits chosen', async () => {
    current.opts = { rpc: {
      fn_platform_limit_requests: [{ ...REQ, wants: 'move_up' }],
      fn_platform_school_detail: detail(view()),
      fn_signup_plans: PLANS,
      fn_platform_plan_change_quote: {
        from: { code: 'starter', name: 'Starter', limit: 280, term_price: 2000 },
        to: { code: 'growth', name: 'Growth', limit: 1000, term_price: 4000, by_arrangement: false },
        term_months: 1, students: 280, fits: true, in_trial: false, paid_from: '2026-10-01',
        paid_to: '2026-10-31', days_left: 21, days_in_period: 31, suggested_charge: 1355,
        explain: 'Rs 1,355 for the 21 day(s) left.',
      },
    } }
    const { RoomRequests } = await import('@/pages/platform/RoomRequests')
    const r = mount(RoomRequests as never)
    await waitFor(() => expect(r.queryByText('Move them up')).not.toBeNull())
    expect(r.queryByText('Give them room')).toBeNull()
    fireEvent.click(r.getByText('Move them up'))
    await waitFor(() => expect(r.queryByText(/Rs 1,355 for the 21 day/)).not.toBeNull())
    expect((r.getByLabelText(/Growth/) as HTMLInputElement).checked).toBe(true)
    expect((r.getByLabelText(/Why they are moving/) as HTMLTextAreaElement).value)
      .toMatch(/Second campus in November/)
  })
})

// -------------------------------------------------------- the school list --

describe('the school list', () => {
  it('flags a school waiting for its price and offers Set price; warns from 90%, stops at 100%', async () => {
    const { SchoolsTable } = await import('@/pages/platform/SchoolsTable')
    const rows = [
      { ...SCHOOL, school_id: 'a', school_name: 'Roots', plan_code: 'enterprise', status: 'trialing',
        student_limit: null, student_count: 1400, needs_price: true, trial_ends_on: '2026-10-20',
        days_left: 10, expires_on: '2026-10-20' },
      { ...SCHOOL, school_id: 'b', school_name: 'Nearly Full', student_count: 260, days_left: 200 },
      { ...SCHOOL, school_id: 'c', school_name: 'Full Up', student_count: 280, days_left: 200 },
    ]
    const r = mount(SchoolsTable as never, {
      schools: rows, loading: false, error: null, busy: false, onOpen: () => {}, onQuickAction: () => {},
    })
    expect(r.container.textContent).toContain(`price not agreed · trial ends ${fmtDate('2026-10-20')}`)
    expect(r.queryByText('Set price')).not.toBeNull()
    expect(r.queryByText('nearly full')).not.toBeNull()
    expect(r.queryByText('full: admissions stop')).not.toBeNull()
    expect(r.container.textContent).not.toMatch(/margin/i)
  })
})

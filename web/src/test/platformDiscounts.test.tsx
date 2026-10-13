// @vitest-environment jsdom
/**
 * The operator's Discounts tab under 0156: codes that keep their word.
 *
 * WHAT THIS FILE HOLDS THE SCREEN TO
 *
 *   1. The arithmetic the worked example shows is fn__discount_calc's: billed
 *      months, the share of the term price, whole rupees, never more than the
 *      invoice. And the figures come from the price list the database gave,
 *      not from this code: change the list and the example changes.
 *   2. New and Edit are different calls. Edit sends ONLY what changed, with the
 *      version it was opened from, and a locked code offers only what may
 *      still change. A stale edit says so in plain words and offers a reload.
 *   3. Giving a code never replaces a school's live code without an explicit
 *      "Replace it", and a code coming back says it was restored.
 *   4. Every call is asserted with its arguments, because a payload key nobody
 *      reads is dropped without a sound.
 */
import { describe, expect, it, vi, afterEach } from 'vitest'
import { createElement } from 'react'
import { cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/react'
import { MemoryRouter } from 'react-router-dom'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { fakeSupabase, type FakeOptions } from './fakeSupabase'
import type { DiscountEvent } from '@/lib/platform'
import {
  addMonths, changedTerms, checkTerms, discountCalc, formFromCode, monthsUntil, termsFromForm,
  type CodeTerms,
} from '@/pages/platform/discounts/rules'
import { describeEvent } from '@/pages/platform/discounts/Log'
import { Discounts } from '@/pages/platform/Discounts'

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

afterEach(() => cleanup())

// ----------------------------------------------------------------- fixtures --

const plan = (code: string, name: string, month: number, quarter: number, year: number,
  extra: Record<string, unknown> = {}) => ({
  code, name, active: true, student_limit: null, min_students: 1, by_arrangement: false,
  month, quarter, year, schools: 0, ...extra,
})
const PRICES = {
  plans: [
    plan('starter', 'Starter', 2000, 5400, 20000),
    plan('growth', 'Growth', 4000, 10800, 40000),
    plan('enterprise', 'Enterprise', 0, 0, 0, { by_arrangement: true }),
    plan('institution', 'Institution', 9000, 24300, 90000, { active: false }),
  ],
  changes: [],
}

const school = (id: string, name: string, status: string, extra: Record<string, unknown> = {}) => ({
  school_id: id, school_name: name, city: 'Lahore', contact_name: null, contact_phone: null,
  plan_code: 'growth', status, expires_on: null, days_left: null, student_count: 300,
  student_limit: 1000, limit_state: 'ok', suggested_plan: 'growth', needs_upgrade: false,
  outstanding: 0, last_paid_on: null, suspended: false, suspend_reason: null, archived: false,
  ...extra,
})
const SCHOOLS = [
  school('sch-1', 'Al Qalam School', 'active'),
  school('sch-2', 'Beacon Grammar', 'trialing'),
  school('sch-3', 'Closed Academy', 'cancelled', { archived: true }),
]

const code = (c: string, extra: Record<string, unknown>) => ({
  code: c, label: `${c} label`, description: `${c} is ours`, kind: 'percent', value: 10,
  duration: 'months', duration_months: 3, duration_until: null, redeem_from: null,
  redeem_until: null, max_redemptions: null, plan_codes: null, min_term_months: null,
  active: true, private: false, school_id: null, school_name: null,
  updated_at: `2026-09-01T10:00:00.${c.length}00+00:00`, created_at: '2026-09-01T10:00:00+00:00',
  summary: '10% off, for 3 months of your subscription', seats_taken: 0, redeemed: 0, live: 0,
  invoices: 0, total_saved: 0, deletable: true, terms_locked: false,
  ...extra,
})
const CODES = [
  code('SPRING20', {
    label: 'Spring offer', description: 'Spring campaign, Lahore', value: 20,
    duration: 'forever', duration_months: null, plan_codes: ['growth'], min_term_months: 12,
    max_redemptions: 50, redeem_until: '2099-12-31',
    summary: '20% off, for as long as you subscribe',
    seats_taken: 3, redeemed: 3, live: 2, invoices: 2, total_saved: 12000,
    deletable: false, terms_locked: true,
    updated_at: '2026-09-05T08:30:00.123456+00:00',
  }),
  code('FRESH10', {}),
  code('P1A2B3C4D5', {
    label: 'Our thanks', private: true, school_id: 'sch-2', school_name: 'Beacon Grammar',
    max_redemptions: 1,
  }),
  code('OLDCODE', {
    active: false, redeem_until: '2020-06-30', terms_locked: true, deletable: false,
    seats_taken: 1, redeemed: 1,
  }),
]

const use = (extra: Record<string, unknown>) => ({
  redemption_id: `r-${Math.random()}`, school_id: 'sch-1', school_name: 'Al Qalam School',
  code: 'SPRING20', label: 'Spring offer', kind: 'percent', value: 20, duration: 'forever',
  ends_on: null, months_left: null, months_total: null, times_applied: 2, total_saved: 8000,
  trial_days_added: null, granted_by_kind: 'school', grant_reason: null,
  redeemed_at: '2026-09-02T09:00:00+00:00', redeemed_by: 'Basha Salamat',
  removed_at: null, removed_reason: null, removed_by: null, plan_code: 'growth',
  summary: '20% off, for as long as you subscribe', state: 'active', ...extra,
})
const USAGE = [
  use({}),
  use({
    school_id: 'sch-2', school_name: 'Beacon Grammar', code: 'OLDCODE', label: 'Old offer',
    kind: 'percent', value: 10, duration: 'months', months_left: 2, months_total: 3,
    times_applied: 1, total_saved: 400, granted_by_kind: 'platform',
    grant_reason: 'Agreed on the phone in June', redeemed_by: 'Asif',
    removed_at: '2026-08-01T09:00:00+00:00', removed_reason: 'Moved to a yearly contract',
    removed_by: 'Asif', state: 'removed', summary: '10% off, for 2 months of your subscription',
  }),
]

const ev = (e: Partial<DiscountEvent>): DiscountEvent => ({
  at: '2026-09-06T10:00:00+00:00', event: 'edited', code: 'SPRING20', school_id: null,
  school_name: null, invoice_id: null, doc_no: null, actor_kind: 'platform', actor: 'Asif',
  before: null, after: null, reason: null, ...e,
})
const EVENTS: DiscountEvent[] = [
  ev({
    before: { label: 'Spring', redeem_until: '2026-11-30', updated_at: 'a' },
    after: { label: 'Spring offer', redeem_until: '2026-12-31', updated_at: 'b' },
  }),
  ev({
    event: 'refused', code: 'SPRNG20', school_id: 'sch-2', school_name: 'Beacon Grammar',
    actor_kind: 'school', actor: 'Head Teacher',
    reason: 'That code is not one we can apply for your school. Check it, or ask us.',
  }),
  ev({
    event: 'invoiced', school_id: 'sch-1', school_name: 'Al Qalam School', doc_no: 'INV-0007',
    actor_kind: 'system', actor: null,
    after: { doc_no: 'INV-0007', months_covered: 12, amount_off: 4000, overridden: false },
  }),
]

function rpcs(extra: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    fn_platform_discounts: CODES,
    fn_platform_discount_usage: USAGE,
    fn_platform_discount_events: EVENTS,
    fn_platform_price_list: PRICES,
    fn_platform_schools: SCHOOLS,
    ...extra,
  }
}

async function mount(opts: Partial<FakeOptions> = {}) {
  const calls: NonNullable<FakeOptions['calls']> = []
  current.opts = { rpc: rpcs(), calls, ...opts }
  const qc = new QueryClient({
    defaultOptions: { queries: { retry: false, gcTime: 0 }, mutations: { retry: false } },
  })
  render(createElement(MemoryRouter, null,
    createElement(QueryClientProvider, { client: qc }, createElement(Discounts))))
  await waitFor(() => expect(screen.getAllByText('SPRING20').length).toBeGreaterThan(0))
  // The forms read the price list and the schools; let both land.
  await waitFor(() => expect(calls.some((c) => c.name === 'fn_platform_price_list')).toBe(true))
  await waitFor(() => expect(screen.queryAllByText(/Loading/)).toHaveLength(0))
  return calls
}

const lastCall = (calls: NonNullable<FakeOptions['calls']>, name: string) =>
  [...calls].reverse().find((c) => c.name === name)
const row = (c: string) => screen.getAllByText(c)[0].closest('tr') as HTMLElement
const type = (el: HTMLElement, value: string) => fireEvent.change(el, { target: { value } })

// ===================================================================== rules --
describe('the rules the console mirrors', () => {
  const terms = (t: Partial<CodeTerms>): CodeTerms => ({
    code: 'SPRING26', kind: 'percent', value: 10, duration: 'months', monthsLeft: 3,
    until: null, planCodes: null, minTerm: null, ...t,
  })
  const inv = (months: number, termPrice: number, extra: Record<string, unknown> = {}) => ({
    planCode: 'growth', planNames: 'Growth', months, start: '2026-10-10', termPrice, ...extra,
  })

  it('1. counts billed months and takes their share of the term price, in whole rupees', () => {
    // The example the owner gave: a yearly Growth invoice, 10% for 3 months.
    expect(discountCalc(terms({}), inv(12, 40000))).toEqual({ covered: 3, amount: 1000 })
    expect(discountCalc(terms({}), inv(1, 4000))).toEqual({ covered: 1, amount: 400 })
    expect(discountCalc(terms({}), inv(3, 10800))).toEqual({ covered: 3, amount: 1080 })
    // For as long as they subscribe covers every billed month.
    expect(discountCalc(terms({ duration: 'forever' }), inv(12, 20000)))
      .toEqual({ covered: 12, amount: 2000 })
    // Rupees come off each covered month and never more than the invoice.
    expect(discountCalc(terms({ kind: 'flat', value: 500 }), inv(12, 40000)))
      .toEqual({ covered: 3, amount: 1500 })
    expect(discountCalc(terms({ kind: 'flat', value: 5000, duration: 'forever' }), inv(1, 2000)))
      .toEqual({ covered: 1, amount: 2000 })
    // Until a date: the billed months that START by it.
    expect(monthsUntil('2026-10-10', 12, '2026-12-31')).toBe(3)
    expect(discountCalc(terms({ duration: 'until', until: '2026-12-31' }), inv(12, 40000)))
      .toEqual({ covered: 3, amount: 1000 })
    // Postgres adds a month to the 31st of January by landing on February's last day.
    expect(addMonths('2027-01-31', 1)).toBe('2027-02-28')
    expect(addMonths('2027-11-15', 3)).toBe('2028-02-15')
  })

  it('2. skips an invoice the code does not fit, in the database\'s words', () => {
    expect(discountCalc(terms({ minTerm: 12 }), inv(1, 4000)).skipped).toBe(
      'Code SPRING26 needs paying for 12 months or more at a time, so it does not apply to a 1-month invoice.')
    expect(discountCalc(terms({ planCodes: ['starter'] }), inv(12, 40000, { planNames: 'Starter' })).skipped)
      .toBe('Code SPRING26 is for Starter, so it does not apply to this invoice.')
    expect(discountCalc(terms({ monthsLeft: 0 }), inv(1, 4000)).skipped)
      .toBe('Code SPRING26 has run its course, so it does not apply to this invoice.')
  })

  it('3. refuses what the database refuses, and past dates only when they changed', () => {
    const base = termsFromForm({
      ...formFromCode(CODES[1] as never), code: 'SPRING26', label: 'Spring', description: 'Ours',
    })
    const today = '2026-10-10'
    expect(checkTerms({ ...base, code: 'SPR' }, { today }))
      .toMatch(/^A code is 6 to 32 letters/)
    // A private code may be left empty: the database makes one up.
    expect(checkTerms({ ...base, code: '', private: true, school_id: 'sch-1' }, { today })).toBeNull()
    expect(checkTerms({ ...base, code: '', private: true, school_id: null }, { today }))
      .toBe('A private code is made for one school. Choose the school.')
    expect(checkTerms({ ...base, code: 'FREEFOREVER', value: 100, duration: 'forever', duration_months: null }, { today }))
      .toBe('A code that makes the subscription free for ever must be private to one school.')
    expect(checkTerms({ ...base, code: 'SPRING26', redeem_until: '2020-01-01' }, { today }))
      .toBe('The last day it can be used is in the past.')
    // The same past date, unchanged on an edit, is not a reason to refuse it.
    const old = { ...base, redeem_until: '2020-01-01' }
    expect(checkTerms({ ...old, label: 'New name' }, { today, before: old })).toBeNull()
    expect(checkTerms({ ...base, max_redemptions: 2 }, { today, before: base, seatsTaken: 3, codeName: 'SPRING26' }))
      .toBe('3 school(s) already hold a place on SPRING26. The limit cannot go below that.')
    expect(checkTerms({ ...base, code: 'SPRING26', kind: 'trial_days', value: 31, duration: 'once' }, { today }))
      .toBe('A trial can be extended by 1 to 30 days with a code.')
  })

  it('4. an edit carries only what changed, and only what is open once locked', () => {
    const before = termsFromForm(formFromCode(CODES[0] as never), ['starter', 'growth', 'enterprise'])
    expect(changedTerms(before, before, true)).toEqual({})
    expect(changedTerms(before, { ...before, label: 'New', value: 5 }, true)).toEqual({ label: 'New' })
    expect(changedTerms(before, { ...before, label: 'New', value: 5 }, false)).toEqual({ label: 'New', value: 5 })
  })

  it('5. reads the log as sentences, with each change from what to what', () => {
    const ctx = { plans: PRICES.plans, schoolName: () => null }
    const edited = describeEvent(EVENTS[0], ctx)
    expect(edited.what).toBe('Changed SPRING20.')
    expect(edited.who).toBe('Asif')
    expect(edited.changes).toEqual([
      { field: 'What schools see', from: '"Spring"', to: '"Spring offer"' },
      { field: 'Can be taken up until', from: '30 Nov 2026', to: '31 Dec 2026' },
    ])
    const refused = describeEvent(EVENTS[1], ctx)
    expect(refused.what).toBe('Beacon Grammar typed "SPRNG20" and it was refused.')
    expect(refused.who).toBe('Head Teacher, Beacon Grammar')
    expect(refused.why).toMatch(/^They were told: That code is not one/)
    expect(describeEvent(EVENTS[2], ctx).what)
      .toBe('SPRING20 took Rs 4,000 off INV-0007 for Al Qalam School, covering 12 months of it.')
    expect(describeEvent(ev({ event: 'restored', school_name: 'Beacon Grammar', code: 'OLDCODE',
      after: { months_left: 2 }, reason: 'Back on the old deal' }), ctx))
      .toMatchObject({ what: 'Gave OLDCODE back to Beacon Grammar, as it was, with 2 months left.',
        why: 'Why: Back on the old deal' })
  })
})

// ==================================================================== screen --
describe('the codes table', () => {
  it('6. shows what schools see, what only we see, places, the lock and what came off', async () => {
    await mount()
    const spring = row('SPRING20')
    expect(within(spring).getByText('Spring offer')).toBeTruthy()
    expect(within(spring).getByText('20% off, for as long as you subscribe')).toBeTruthy()
    expect(within(spring).getByText(/Only we see this/)).toBeTruthy()
    expect(within(spring).getByText(/Spring campaign, Lahore/)).toBeTruthy()
    expect(within(spring).getByText('Growth only, 12 months or more at a time')).toBeTruthy()
    expect(within(spring).getByText('3 of 50 places taken')).toBeTruthy()
    expect(within(spring).getByText('Locked')).toBeTruthy()
    expect(within(spring).getByText('2 invoices')).toBeTruthy()
    expect(within(spring).getByText('Rs 12,000 saved')).toBeTruthy()
    // Used, so it can be retired but never deleted.
    expect(within(spring).queryByText('Delete')).toBeNull()
    expect(within(spring).getByText('Retire')).toBeTruthy()
    expect(within(row('FRESH10')).getByText('Delete')).toBeTruthy()
    expect(within(row('P1A2B3C4D5')).getByText('Private: Beacon Grammar')).toBeTruthy()
    expect(within(row('OLDCODE')).getByText('Retired')).toBeTruthy()
    expect(within(row('OLDCODE')).queryByText('Retire')).toBeNull()
  })

  it('7. opens one code onto its own schools and its own log', async () => {
    const calls = await mount()
    fireEvent.click(within(row('SPRING20')).getByText('Schools and log'))
    await screen.findByText('Schools with SPRING20')
    await screen.findByText('What happened to SPRING20')
    await waitFor(() => {
      expect(calls.some((c) => c.name === 'fn_platform_discount_usage' && c.args.p_code === 'SPRING20')).toBe(true)
      expect(calls.some((c) => c.name === 'fn_platform_discount_events' && c.args.p_code === 'SPRING20')).toBe(true)
    })
  })

  it('8. retires with a reason, and deletes only what nobody had', async () => {
    const calls = await mount({ rpc: rpcs({ fn_platform_retire_discount: { code: 'SPRING20' } }) })
    fireEvent.click(within(row('SPRING20')).getByText('Retire'))
    const dlg = screen.getByRole('dialog', { name: 'Retire SPRING20' })
    type(within(dlg).getByLabelText(/^Why/), 'The spring campaign has ended')
    fireEvent.click(within(dlg).getByText('Retire it'))
    await waitFor(() => expect(lastCall(calls, 'fn_platform_retire_discount')?.args)
      .toEqual({ p_code: 'SPRING20', p_reason: 'The spring campaign has ended' }))
    await screen.findByText(/SPRING20 is retired/)

    fireEvent.click(within(row('FRESH10')).getByText('Delete'))
    fireEvent.click(within(screen.getByRole('dialog', { name: 'Delete FRESH10' })).getByText('Delete it'))
    await waitFor(() => expect(lastCall(calls, 'fn_platform_delete_discount')?.args)
      .toEqual({ p_code: 'FRESH10' }))
  })
})

describe('a new code', () => {
  it('9. works the example out on the database\'s price list and creates with every term', async () => {
    const calls = await mount({ rpc: rpcs({
      fn_platform_create_discount: { code: 'SPRING26', summary: '10% off, for 3 months of your subscription' },
    }) })
    fireEvent.click(screen.getByText('New code'))
    const dlg = screen.getByRole('dialog', { name: 'New discount code' })
    const q = within(dlg)
    type(q.getByLabelText(/^Code/), 'spring 26')
    type(q.getByLabelText(/^Label: what schools see/), 'Spring offer')
    type(q.getByLabelText(/^Our description/), 'Spring campaign for Lahore')
    fireEvent.click(q.getByLabelText('Growth'))
    expect(q.getByText(
      'On a yearly Growth invoice (Rs 40,000), 10% for 3 months covers 3 of its 12 billed months '
      + 'and takes Rs 1,000 off. The school pays Rs 39,000. That uses the code up.')).toBeTruthy()
    expect(q.getByText('On a monthly Growth invoice (Rs 4,000), 10% for 3 months covers its one billed month '
      + 'and takes Rs 400 off. The school pays Rs 3,600. The other 2 months come off the invoices after it.'))
      .toBeTruthy()
    // Enterprise has no list price, so no figure is made up for it.
    expect(q.queryByText(/On a yearly Enterprise invoice/)).toBeNull()

    fireEvent.click(q.getByText('Create code'))
    await waitFor(() => expect(lastCall(calls, 'fn_platform_create_discount')).toBeTruthy())
    expect(lastCall(calls, 'fn_platform_create_discount')!.args.p).toEqual({
      code: 'SPRING26', label: 'Spring offer', description: 'Spring campaign for Lahore',
      kind: 'percent', value: 10, duration: 'months', duration_months: 3, duration_until: null,
      redeem_from: null, redeem_until: null, max_redemptions: null, plan_codes: ['growth'],
      min_term_months: null, active: true, private: false, school_id: null,
    })
    await screen.findByText('Made SPRING26: 10% off, for 3 months of your subscription.')
  })

  it('10. never shows a price the list did not give', async () => {
    const dear = { ...PRICES, plans: PRICES.plans.map((p) => p.code === 'growth' ? { ...p, year: 50000 } : p) }
    await mount({ rpc: rpcs({ fn_platform_price_list: dear }) })
    fireEvent.click(screen.getByText('New code'))
    const q = within(screen.getByRole('dialog', { name: 'New discount code' }))
    fireEvent.click(q.getByLabelText('Growth'))
    expect(q.getByText(/On a yearly Growth invoice \(Rs 50,000\), 10% for 3 months covers 3 of its 12 billed months and takes Rs 1,250 off/))
      .toBeTruthy()
  })

  it('11. says what is wrong before the round trip, in the database\'s sentence', async () => {
    const calls = await mount()
    fireEvent.click(screen.getByText('New code'))
    const q = within(screen.getByRole('dialog', { name: 'New discount code' }))
    type(q.getByLabelText(/^Code/), 'ABC')
    type(q.getByLabelText(/^Label: what schools see/), 'Spring offer')
    type(q.getByLabelText(/^Our description/), 'Spring')
    fireEvent.click(q.getByText('Create code'))
    expect(q.getByRole('alert').textContent).toMatch(/^A code is 6 to 32 letters/)
    expect(lastCall(calls, 'fn_platform_create_discount')).toBeUndefined()
  })

  it('12. a private code may be left unnamed, is one school\'s, and is then given to it', async () => {
    const calls = await mount({ rpc: rpcs({
      fn_platform_create_discount: { code: 'P1A2B3C4D5', summary: '10% off, for 3 months of your subscription' },
    }) })
    fireEvent.click(screen.getByText('New code'))
    const q = within(screen.getByRole('dialog', { name: 'New discount code' }))
    fireEvent.click(q.getByLabelText(/^Private: made for one school/))
    // Archived schools are not offered.
    expect(q.queryByText(/Closed Academy/)).toBeNull()
    type(q.getByLabelText(/^Which school/), 'sch-2')
    type(q.getByLabelText(/^Label: what schools see/), 'Our thanks')
    type(q.getByLabelText(/^Our description/), 'For the referral in September')
    fireEvent.click(q.getByText('Create code'))
    await waitFor(() => expect(lastCall(calls, 'fn_platform_create_discount')).toBeTruthy())
    expect(lastCall(calls, 'fn_platform_create_discount')!.args.p).toMatchObject({
      code: null, private: true, school_id: 'sch-2', max_redemptions: 1,
    })
    fireEvent.click(await screen.findByText('Give it to Beacon Grammar now'))
    const give = screen.getByRole('dialog', { name: 'Give P1A2B3C4D5 to a school' })
    // Made for them, so there is no choosing another school.
    expect(within(give).queryByRole('combobox')).toBeNull()
    expect(within(give).getByText(/the code was made for them/)).toBeTruthy()
  })
})

describe('editing a code', () => {
  it('13. a locked code shows what it gives and sends only what changed, from its version', async () => {
    const calls = await mount({ rpc: rpcs({
      fn_platform_edit_discount: { code: 'SPRING20', note: 'Schools that already have this code keep exactly what they were given.' },
    }) })
    fireEvent.click(screen.getByRole('button', { name: 'Edit SPRING20' }))
    const q = within(screen.getByRole('dialog', { name: 'Edit SPRING20' }))
    expect(q.getByText('Schools already have this code. Retire it and make a new one to change what it gives.'))
      .toBeTruthy()
    expect(q.queryByLabelText(/^Kind/)).toBeNull()
    expect(q.getByText('Nothing changed')).toBeTruthy()
    type(q.getByLabelText(/^Label: what schools see/), 'Spring offer 2026')
    type(q.getByLabelText(/^Most schools/), '60')
    fireEvent.click(q.getByText('Save changes'))
    await waitFor(() => expect(lastCall(calls, 'fn_platform_edit_discount')?.args).toEqual({
      p_code: 'SPRING20',
      p: { label: 'Spring offer 2026', max_redemptions: 60 },
      p_expected_updated_at: '2026-09-05T08:30:00.123456+00:00',
    }))
    await screen.findByText('Schools that already have this code keep exactly what they were given.')
  })

  it('14. a code past its dates can still be renamed', async () => {
    const calls = await mount({ rpc: rpcs({ fn_platform_edit_discount: { code: 'OLDCODE', note: null } }) })
    fireEvent.click(screen.getByRole('button', { name: 'Edit OLDCODE' }))
    const q = within(screen.getByRole('dialog', { name: 'Edit OLDCODE' }))
    type(q.getByLabelText(/^Label: what schools see/), 'Old offer')
    fireEvent.click(q.getByText('Save changes'))
    await waitFor(() => expect(lastCall(calls, 'fn_platform_edit_discount')?.args.p)
      .toEqual({ label: 'Old offer' }))
  })

  it('15. an open code changes what it gives, and the example follows', async () => {
    const calls = await mount({ rpc: rpcs({ fn_platform_edit_discount: { code: 'FRESH10', note: null } }) })
    fireEvent.click(screen.getByRole('button', { name: 'Edit FRESH10' }))
    const q = within(screen.getByRole('dialog', { name: 'Edit FRESH10' }))
    type(q.getByLabelText(/^Percent/), '15')
    expect(q.getByText(/On a yearly Starter invoice \(Rs 20,000\), 15% for 3 months covers 3 of its 12 billed months and takes Rs 750 off/))
      .toBeTruthy()
    fireEvent.click(q.getByText('Save changes'))
    await waitFor(() => expect(lastCall(calls, 'fn_platform_edit_discount')?.args.p).toEqual({ value: 15 }))
  })

  it('16. an edit made from an old copy says so and offers a reload', async () => {
    const calls = await mount({
      rpcErrors: {
        fn_platform_edit_discount: 'Somebody changed SPRING20 while you were editing it. Reload it and make your change again.',
      },
    })
    fireEvent.click(screen.getByRole('button', { name: 'Edit SPRING20' }))
    const q = within(screen.getByRole('dialog', { name: 'Edit SPRING20' }))
    type(q.getByLabelText(/^Label: what schools see/), 'Spring offer 2026')
    fireEvent.click(q.getByText('Save changes'))
    await q.findByText('Somebody changed this code while you were editing it. Reload it.')
    const before = calls.filter((c) => c.name === 'fn_platform_discounts').length
    fireEvent.click(q.getByText('Reload it'))
    await waitFor(() => expect(calls.filter((c) => c.name === 'fn_platform_discounts').length).toBeGreaterThan(before))
    await waitFor(() => expect(q.queryByText(/Somebody changed this code/)).toBeNull())
    // The reloaded copy is the one on screen, so nothing is waiting to be saved.
    expect(q.getByText('Nothing changed')).toBeTruthy()
  })
})

describe('giving a code to a school', () => {
  it('17. shows the live code and gives nothing until "Replace it" is chosen', async () => {
    const calls = await mount({ rpc: rpcs({
      fn_platform_grant_discount: { code: 'FRESH10', restored: false, trial_ends_on: null,
        summary: '10% off, for 3 months of your subscription' },
    }) })
    fireEvent.click(within(row('FRESH10')).getByText('Give to a school'))
    const q = within(screen.getByRole('dialog', { name: 'Give FRESH10 to a school' }))
    type(q.getByLabelText(/^School/), 'sch-1')
    expect(q.getByText(/already has/).textContent).toMatch(/Al Qalam School already has SPRING20 \(Spring offer\)/)
    expect(q.getByText('They typed it in themselves.', { exact: false })).toBeTruthy()
    type(q.getByLabelText(/^Why they are getting it/), 'Agreed on the phone for the new session')
    const go = q.getByText('Replace and give') as HTMLButtonElement
    expect(go.disabled).toBe(true)
    fireEvent.click(q.getByLabelText(/^Replace it/))
    expect(go.disabled).toBe(false)
    fireEvent.click(go)
    await waitFor(() => expect(lastCall(calls, 'fn_platform_grant_discount')?.args).toEqual({
      p_school_id: 'sch-1', p_code: 'FRESH10',
      p_reason: 'Agreed on the phone for the new session', p_replace: true,
    }))
    await screen.findByText('Al Qalam School now has FRESH10: 10% off, for 3 months of your subscription.')
  })

  it('18. a code the school had before is restored, and says so', async () => {
    const calls = await mount({ rpc: rpcs({
      fn_platform_grant_discount: { code: 'OLDCODE', restored: true, trial_ends_on: null, summary: 'x' },
    }) })
    fireEvent.click(within(row('OLDCODE')).getByText('Give to a school'))
    const q = within(screen.getByRole('dialog', { name: 'Give OLDCODE to a school' }))
    type(q.getByLabelText(/^School/), 'sch-2')
    expect(q.getByText(/Beacon Grammar had OLDCODE before/).textContent)
      .toMatch(/restores it as it was, with 2 month\(s\) left/)
    type(q.getByLabelText(/^Why they are getting it/), 'Back on the deal from June')
    fireEvent.click(q.getByText('Restore it'))
    await waitFor(() => expect(lastCall(calls, 'fn_platform_grant_discount')?.args)
      .toMatchObject({ p_school_id: 'sch-2', p_code: 'OLDCODE', p_replace: false }))
    await screen.findByText("OLDCODE is back on Beacon Grammar's subscription, restored as it was before it came off.")
  })

  it('19. a refusal for a code the roster did not know about offers the same choice', async () => {
    await mount({ rpcErrors: {
      fn_platform_grant_discount: 'Beacon Grammar already has WINTER10 (Winter offer). Replace it on purpose if that is what you mean.',
    } })
    fireEvent.click(within(row('FRESH10')).getByText('Give to a school'))
    const q = within(screen.getByRole('dialog', { name: 'Give FRESH10 to a school' }))
    type(q.getByLabelText(/^School/), 'sch-2')
    type(q.getByLabelText(/^Why they are getting it/), 'Agreed on the phone for the new session')
    fireEvent.click(q.getByText('Give it'))
    await q.findByText(/Replace it on purpose/)
    expect(q.getByLabelText(/^Replace it/)).toBeTruthy()
  })
})

describe('the roster and the log', () => {
  it('20. says how each school got its code, and takes one off with a reason', async () => {
    const calls = await mount({ rpc: rpcs({ fn_platform_remove_discount: { removed: true } }) })
    const roster = screen.getByRole('region', { name: /Who has a discount/ })
    const r = within(roster)
    expect(r.getByText('Typed in by the school')).toBeTruthy()
    expect(r.getByText('Given by us')).toBeTruthy()
    expect(r.getByText('Why: Agreed on the phone in June')).toBeTruthy()
    expect(r.getByText('Live')).toBeTruthy()
    expect(r.getByText('Taken off')).toBeTruthy()
    expect(r.getByText(/by Asif: Moved to a yearly contract/)).toBeTruthy()
    expect(r.getByText('2 of 3 billed month(s) left')).toBeTruthy()

    fireEvent.click(r.getByRole('button', { name: 'Take SPRING20 off Al Qalam School' }))
    const dlg = screen.getByRole('dialog', { name: 'Take SPRING20 off Al Qalam School' })
    type(within(dlg).getByLabelText(/^Why/), 'Moved to a yearly contract at a new price')
    fireEvent.click(within(dlg).getByText('Take it off'))
    await waitFor(() => expect(lastCall(calls, 'fn_platform_remove_discount')?.args).toEqual({
      p_school_id: 'sch-1', p_reason: 'Moved to a yearly contract at a new price',
    }))
  })

  it('21. the log reads as sentences and can show only the refused tries', async () => {
    await mount()
    const log = within(screen.getByRole('region', { name: /Discount log/ }))
    expect(log.getByText('Changed SPRING20.')).toBeTruthy()
    expect(log.getByText('Beacon Grammar typed "SPRNG20" and it was refused.')).toBeTruthy()
    expect(log.getByText(/took Rs 4,000 off INV-0007/)).toBeTruthy()
    type(log.getByLabelText(/^Show/), 'refused')
    expect(log.queryByText('Changed SPRING20.')).toBeNull()
    expect(log.getByText('Beacon Grammar typed "SPRNG20" and it was refused.')).toBeTruthy()
  })
})

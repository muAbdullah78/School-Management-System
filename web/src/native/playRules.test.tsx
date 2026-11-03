// @vitest-environment jsdom
/**
 * Google Play's payment rules, inside the Android app: no price, no bank
 * details, no "I have paid", no discount code, no plan to buy, no sign-up and
 * no way back to the selling website. The same screens in a browser are
 * unchanged, which each case also checks, so the rule cannot leak outward.
 */
import { afterEach, describe, expect, it, vi } from 'vitest'
import { readdirSync, readFileSync, statSync } from 'node:fs'
import { join } from 'node:path'
import { createElement, type ReactElement } from 'react'
import { cleanup, render, screen, waitFor } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { MemoryRouter } from 'react-router-dom'
import { fakeSupabase, type FakeOptions } from '@/test/fakeSupabase'
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
  readStore: null,
  requireSupabase: () => fakeSupabase(current.opts),
}))

const { LicenceBanner } = await import('@/components/LicenceBanner')
const { LicenceGate } = await import('@/components/LicenceGate')
const { RollLimitNotice } = await import('@/components/RollLimitNotice')
const { InAppSubscription, MANAGED_ELSEWHERE } = await import('./InAppSubscription')
const { Login } = await import('@/pages/Login')
const { OFFICE_DOOR } = await import('@/auth/doors')

const ME = '11111111-1111-1111-1111-111111111111'
const SCHOOL = '22222222-2222-2222-2222-222222222222'
const as = (role: Role): Profile => ({ id: ME, full_name: 'Sidra Batool', role, staff_id: null, school_id: SCHOOL })

function open(node: ReactElement, opts: FakeOptions, profile: Profile | null = as('owner')) {
  current.opts = opts
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false, gcTime: 0 } } })
  const auth = {
    session: profile ? { user: { id: ME, email: 'x@example.test' } } as never : null,
    profile, loading: false,
    signIn: async () => ({ error: null }), signOut: async () => {},
    sendReset: async () => ({ error: null }), setPassword: async () => ({ error: null }),
  }
  return render(
    createElement(MemoryRouter, null,
      createElement(AuthContext.Provider, { value: auth as never },
        createElement(QueryClientProvider, { client: qc }, node))),
  )
}

const asApp = () => vi.stubGlobal('Capacitor', { isNativePlatform: () => true })
afterEach(() => { cleanup(); vi.unstubAllGlobals() })

const LIC = {
  ok: true, school_id: SCHOOL, status: 'grace', locked: false, can_read: true, can_export: true, can_operate: true,
  plan_code: 'standard', plan_name: 'Standard', cycle: 'monthly', price_monthly: 3500, price_yearly: 38000,
  expires_on: '2026-11-01', days_left: 0, student_count: 140, student_limit: 150, margin_limit: null,
  limit_state: 'ok', limit_notice: null, paid_through: '2026-10-31', pay_now: 3500, needs_price: false,
}
const MONEY = /\bRs\b|PKR|bank|I have paid|discount|3,?500|38,?000/i

describe('the licence banner', () => {
  it('in the app: the status, and who acts, with no link and no bank details', async () => {
    asApp()
    const { container } = open(createElement(LicenceBanner), { rpc: { fn_my_licence: LIC } })
    await waitFor(() => expect(screen.getByText(MANAGED_ELSEWHERE)).toBeTruthy())
    expect(container.querySelector('a')).toBeNull()
    expect(container.textContent).not.toMatch(MONEY)
  })

  it('in a browser: unchanged, the way to pay is one tap away', async () => {
    const { container } = open(createElement(LicenceBanner), { rpc: { fn_my_licence: LIC } })
    await waitFor(() => expect(container.querySelector('a[href="/settings?tab=subscription"]')).toBeTruthy())
    expect(container.textContent).toMatch(/bank details/)
  })
})

describe('a locked school', () => {
  const locked = { ...LIC, status: 'locked', locked: true, locked_because: 'unpaid', can_operate: false }

  it('in the app the owner sees it is paused and who manages it, and no way to pay', async () => {
    asApp()
    const { container } = open(createElement(LicenceGate, null, 'the app'), { rpc: { fn_my_licence: locked } })
    await waitFor(() => expect(screen.getByText(/account is paused/)).toBeTruthy())
    expect(container.textContent).toContain(MANAGED_ELSEWHERE)
    expect(container.textContent).not.toMatch(MONEY)
    expect(container.textContent).not.toContain('the app is')
  })

  it('in a browser the owner still gets the screen that says how to pay', async () => {
    const { container } = open(createElement(LicenceGate, null, 'the app'),
      { rpc: { fn_my_licence: locked, fn_my_billing: null } })
    await waitFor(() => expect(container.textContent).not.toContain('Loading'))
    expect(container.textContent).not.toContain(MANAGED_ELSEWHERE)
  })
})

describe('the subscription page in the app', () => {
  it('plan, status and roll, never a price', async () => {
    asApp()
    const { container } = open(createElement(InAppSubscription), { rpc: { fn_my_licence: LIC } })
    await waitFor(() => expect(screen.getByText('Standard')).toBeTruthy())
    expect(screen.getByText('Renewal due')).toBeTruthy()
    expect(screen.getByText('140 of 150')).toBeTruthy()
    expect(container.textContent).toContain(MANAGED_ELSEWHERE)
    expect(container.textContent).not.toMatch(MONEY)
  })
})

describe('asking for room, and signing up', () => {
  const full = { ...LIC, status: 'active', days_left: 200, limit_state: 'over', at_limit: true,
    limit_notice: 'Your roll is full.', limit_notice_staff: 'The roll is full.' }

  it('in the app the roll notice keeps its words but not the button to a bigger plan', async () => {
    asApp()
    open(createElement(RollLimitNotice), { rpc: { fn_my_licence: full } })
    await waitFor(() => expect(screen.getByText(/roll is full/)).toBeTruthy())
    expect(screen.queryByText('Ask for room')).toBeNull()
  })

  it('in a browser the owner can still ask for room', async () => {
    open(createElement(RollLimitNotice), { rpc: { fn_my_licence: full } })
    await waitFor(() => expect(screen.getByText('Ask for room')).toBeTruthy())
  })

  it('the office door offers a free trial in a browser, and not in the app', () => {
    expect(OFFICE_DOOR.offerTrial).toBe(true)
    open(createElement(Login, { door: OFFICE_DOOR }), {}, null)
    expect(screen.getByText(/free 14-day trial/)).toBeTruthy()
    cleanup()
    asApp()
    open(createElement(Login, { door: OFFICE_DOOR }), {}, null)
    expect(screen.queryByText(/free 14-day trial/)).toBeNull()
  })
})

describe('the handbook from inside the app', () => {
  // The handbook has a chapter on paying for the software. Every screen that
  // links to it must hide the link inside the app, so a new one cannot slip in.
  it('every screen that links the handbook hides it inside the app', () => {
    const files: string[] = []
    const walk = (d: string) => {
      for (const f of readdirSync(d)) {
        const p = join(d, f)
        if (statSync(p).isDirectory()) walk(p)
        else if (/\.tsx$/.test(f) && !/\.test\.tsx$/.test(f)) files.push(p)
      }
    }
    walk(join(process.cwd(), 'src'))
    const linking = files.filter((f) => /href=\{guideUrl\}/.test(readFileSync(f, 'utf8')))
    expect(linking.length).toBeGreaterThan(0)
    for (const f of linking) expect([f, readFileSync(f, 'utf8').includes('isNativeApp()')]).toEqual([f, true])
  })
})

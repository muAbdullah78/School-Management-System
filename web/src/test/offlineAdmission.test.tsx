// @vitest-environment jsdom
/**
 * An admission with no connection, and one the school thinks is a child it
 * already has.
 *
 * With the offline engine running, an admission goes through the outbox: the
 * pupil gets an id on this device, so the same admission arriving twice can
 * never make two children. Saved and not yet at the school, the slip says the
 * GR number comes when it arrives. Refused as a likely duplicate, the person is
 * shown the child the school means and can say they are different children.
 */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { createElement } from 'react'
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { MemoryRouter } from 'react-router-dom'
import { fakeSupabase, type FakeOptions } from './fakeSupabase'
import { AuthContext, type Profile } from '@/auth/AuthProvider'
import { OfflineContext, type OfflineState, type Settled } from '@/offline/OfflineProvider'
import type { NewWork } from '@/offline/engine'
import type { OutboxItem } from '@/offline/store'

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

const { AdmissionsPage } = await import('@/pages/admissions/AdmissionsPage')

const OWNER: Profile = {
  id: '11111111-1111-1111-1111-111111111111', full_name: 'Owner', role: 'owner',
  staff_id: null, school_id: '22222222-2222-2222-2222-222222222222',
}

function school(): FakeOptions {
  return {
    rows: {
      academic_sessions: [{ id: 'ses', name: '2026-2027', is_current: true }],
      classes: [{ id: 'c5', name: 'Class 5', level_order: 5 }],
      sections: [],
    },
    rpc: {},
    calls: [],
  }
}

function engine(settles: Settled[]) {
  const sent: NewWork[] = []
  const off: OfflineState = {
    active: true, online: false, syncing: false, snapshot: null, legacyWaiting: 0, lastReport: null, copySavedAt: null,
    syncNow: vi.fn(async () => null),
    submit: vi.fn(async (w: NewWork): Promise<OutboxItem> => {
      sent.push(w)
      return {
        seq: sent.length, id: `cmd-${sent.length}`, user_id: OWNER.id, school_id: OWNER.school_id, type: w.type,
        occurred_at: new Date().toISOString(), payload: w.payload, v: 1, status: 'pending', depends_on: [],
        label: w.label, code: null, error: null, created_wall: 0, tries: 0,
      }
    }),
    settle: vi.fn(async (): Promise<Settled> => settles.shift() ?? { status: 'pending' }),
    resend: vi.fn(async () => 'new'), discard: vi.fn(async () => undefined),
    clearRevokedNotice: vi.fn(async () => undefined),
  }
  return { off, sent }
}

function open(opts: FakeOptions, off: OfflineState) {
  current.opts = opts
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false, gcTime: 0 }, mutations: { retry: false } } })
  const auth = {
    session: { user: { id: OWNER.id, email: 'o@example.test' } } as never,
    profile: OWNER, loading: false,
    signIn: async () => ({ error: null }), signOut: async () => {},
    sendReset: async () => ({ error: null }), setPassword: async () => ({ error: null }),
  }
  return render(
    createElement(MemoryRouter, null,
      createElement(AuthContext.Provider, { value: auth },
        createElement(OfflineContext.Provider, { value: off },
          createElement(QueryClientProvider, { client: qc }, createElement(AdmissionsPage))))),
  )
}

const name = () => document.querySelector('input[name=full_name]') as HTMLInputElement
const submitVia = (el: Element) => fireEvent.submit(el.closest('form')!)

async function toReview(o: FakeOptions, off: OfflineState) {
  open(o, off)
  await waitFor(() => expect(name()).toBeTruthy())
  fireEvent.change(name(), { target: { value: 'Zainab Aslam' } })
  submitVia(name())
  await screen.findByText('Family and contact')
  fireEvent.change(document.querySelector('input[name=father_name]')!, { target: { value: 'Muhammad Aslam' } })
  submitVia(document.querySelector('input[name=father_name]')!)
  await screen.findByText('Class and admission fee')
  const cls = await waitFor(() => {
    const el = document.querySelector('select[name=class_id]') as HTMLSelectElement
    expect(el.options.length).toBeGreaterThan(1)
    return el
  })
  fireEvent.change(cls, { target: { value: 'c5' } })
  submitVia(cls)
  await screen.findByRole('heading', { name: 'Check, then admit' })
}

beforeEach(() => sessionStorage.clear())
afterEach(() => cleanup())

describe('an admission with no connection', () => {
  it('is saved on this device with a pupil id of its own, never sent straight to the school', async () => {
    const o = school()
    const { off, sent } = engine([{ status: 'pending' }])
    await toReview(o, off)
    fireEvent.click(screen.getByRole('button', { name: /Admit student/ }))
    expect((await screen.findAllByText('Given when it reaches the school')).length).toBeGreaterThan(0)
    expect(sent).toHaveLength(1)
    expect(sent[0].type).toBe('students.admit')
    expect(sent[0].payload.student_id).toMatch(/^[0-9a-f-]{36}$/)
    expect((sent[0].payload.admission as Record<string, unknown>).full_name).toBe('Zainab Aslam')
    expect(sent[0].payload.allow_duplicate).toBe(false)
    expect((o.calls ?? []).some((c) => c.name === 'fn_admit_student')).toBe(false)
  })

  it('reaching the school within the wait shows the GR number it gave', async () => {
    const { off } = engine([{ status: 'applied', flags: [], result: {
      student_id: 'st-new', enrollment_id: 'en-new', gr_no: '1318', roll_no: '35', family_id: null,
      admission_fee_amount: null, admission_receipt_no: null,
    } }])
    await toReview(school(), off)
    fireEvent.click(screen.getByRole('button', { name: /Admit student/ }))
    expect(await screen.findByText('1318')).toBeTruthy()
  })
})

describe('a child the school may already have', () => {
  it('says which child, and admits only when the person says they are different', async () => {
    const { off, sent } = engine([
      { status: 'attention', code: 'possible_duplicate', error: 'Zainab Aslam (GR 0042) looks like the same child, so this admission was not made.' },
      { status: 'applied', flags: [], result: {
        student_id: 'st-2', enrollment_id: 'en-2', gr_no: '1319', roll_no: '36', family_id: null,
        admission_fee_amount: null, admission_receipt_no: null,
      } },
    ])
    await toReview(school(), off)
    fireEvent.click(screen.getByRole('button', { name: /Admit student/ }))
    expect(await screen.findByText(/GR 0042\) looks like the same child/)).toBeTruthy()
    expect(off.discard).toHaveBeenCalledWith('cmd-1')
    fireEvent.click(screen.getByRole('button', { name: /different children: admit anyway/ }))
    expect(await screen.findByText('1319')).toBeTruthy()
    expect(sent).toHaveLength(2)
    expect(sent[1].payload.allow_duplicate).toBe(true)
  })
})

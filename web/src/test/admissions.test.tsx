// @vitest-environment jsdom
/**
 * The admission wizard issues a GR number only when somebody means it to.
 *
 * A GR number is permanent: it is printed on the slip, the challan, the result
 * card and one day the leaving certificate. So the cases that matter are the
 * ones where the old single form could issue one by accident (Enter in the
 * first box submitted the whole form) and the ones where the new steps could
 * lose or garble what was typed on the way to Review.
 */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { createElement } from 'react'
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { MemoryRouter } from 'react-router-dom'
import { fakeSupabase, type FakeOptions } from './fakeSupabase'
import { AuthContext, type Profile } from '@/auth/AuthProvider'

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
vi.mock('./supabase', () => ({
  get supabase() { return fakeSupabase(current.opts) },
  isConfigured: true,
  requireSupabase: () => fakeSupabase(current.opts),
}))

const { AdmissionsPage } = await import('@/pages/admissions/AdmissionsPage')

const CLERK: Profile = {
  id: '11111111-1111-1111-1111-111111111111', full_name: 'Office Clerk', role: 'admin_clerk',
  staff_id: null, school_id: '22222222-2222-2222-2222-222222222222',
}

function school(): FakeOptions {
  return {
    rows: {
      academic_sessions: [{ id: 'ses', name: '2026-2027', is_current: true }],
      classes: [{ id: 'c5', name: 'Class 5', level_order: 5 }],
      sections: [],
    },
    rpc: {
      fn_admit_student: {
        student_id: 'st-new', enrollment_id: 'en-new', gr_no: '1318', roll_no: '35',
        family_id: null, admission_fee_amount: null, admission_receipt_no: null,
      },
    },
    calls: [],
  }
}

function open(opts: FakeOptions) {
  current.opts = opts
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false, gcTime: 0 }, mutations: { retry: false } } })
  const auth = {
    session: { user: { id: CLERK.id, email: 'c@example.test' } } as never,
    profile: CLERK, loading: false,
    signIn: async () => ({ error: null }), signOut: async () => {},
    sendReset: async () => ({ error: null }), setPassword: async () => ({ error: null }),
  }
  return render(
    createElement(MemoryRouter, null,
      createElement(AuthContext.Provider, { value: auth },
        createElement(QueryClientProvider, { client: qc }, createElement(AdmissionsPage)))),
  )
}

const name = () => document.querySelector('input[name=full_name]') as HTMLInputElement
const submitVia = (el: Element) => fireEvent.submit(el.closest('form')!)
const admits = (o: FakeOptions) => (o.calls ?? []).filter((c) => c.name === 'fn_admit_student')

beforeEach(() => sessionStorage.clear())
afterEach(() => cleanup())

describe('moving through the steps', () => {
  it('Enter in the name box moves on to Family and issues nothing', async () => {
    const o = school()
    open(o)
    await waitFor(() => expect(name()).toBeTruthy())
    fireEvent.change(name(), { target: { value: 'Zainab Aslam' } })
    submitVia(name())
    expect(await screen.findByText('Family and contact')).toBeTruthy()
    expect(admits(o)).toHaveLength(0)
  })

  it('Next with no name stays put and says what is missing', async () => {
    open(school())
    await waitFor(() => expect(name()).toBeTruthy())
    submitVia(name())
    expect(await screen.findByText(/as it is on the B-Form/)).toBeTruthy()
    expect(screen.getByText('About the child')).toBeTruthy()
  })

  it('Review names what stops the admission, and the button stays shut', async () => {
    open(school())
    await waitFor(() => expect(name()).toBeTruthy())
    fireEvent.change(name(), { target: { value: 'Zainab Aslam' } })
    // Straight to Review from the step bar, skipping the class.
    fireEvent.click(screen.getByRole('button', { name: /Review Check, then admit/ }))
    expect(await screen.findByText('Before this child can be admitted:')).toBeTruthy()
    expect(screen.getByText('The class they are joining')).toBeTruthy()
    expect((screen.getByRole('button', { name: /Admit student/ }) as HTMLButtonElement).disabled).toBe(true)
  })

  it('a fee switched on with no amount blocks, rather than recording Rs 0', async () => {
    open(school())
    await waitFor(() => expect(name()).toBeTruthy())
    fireEvent.change(name(), { target: { value: 'Zainab Aslam' } })
    fireEvent.click(screen.getByRole('button', { name: 'Go to Class & fee' }))
    const cls = await waitFor(() => {
      const el = document.querySelector('select[name=class_id]') as HTMLSelectElement
      expect(el.options.length).toBeGreaterThan(1)
      return el
    })
    fireEvent.change(cls, { target: { value: 'c5' } })
    fireEvent.click(document.querySelector('input[name=admissionFeeOn]')!)
    fireEvent.click(screen.getByRole('button', { name: /Review Check, then admit/ }))
    expect(await screen.findByText(/The admission fee received, or switch the fee off/)).toBeTruthy()
    expect((screen.getByRole('button', { name: /Admit student/ }) as HTMLButtonElement).disabled).toBe(true)
  })
})

describe('admitting', () => {
  async function toReview(o: FakeOptions) {
    open(o)
    await waitFor(() => expect(name()).toBeTruthy())
    fireEvent.change(name(), { target: { value: '  Zainab Aslam  ' } })
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

  it('Review shows what was typed on every step', async () => {
    await toReview(school())
    expect(screen.getAllByText('Zainab Aslam').length).toBeGreaterThan(0)
    expect(screen.getAllByText('Muhammad Aslam').length).toBeGreaterThan(0)
    expect(screen.getAllByText('Class 5').length).toBeGreaterThan(0)
  })

  it('Admit sends exactly what was typed, trimmed, and shows the GR number', async () => {
    const o = school()
    await toReview(o)
    fireEvent.click(screen.getByRole('button', { name: /Admit student/ }))
    expect(await screen.findByText('1318')).toBeTruthy()
    const [call] = admits(o)
    const p = call.args.p as Record<string, unknown>
    expect(p.full_name).toBe('Zainab Aslam')
    expect(p.father_name).toBe('Muhammad Aslam')
    expect(p.class_id).toBe('c5')
    expect(p.section_id).toBeNull()
    expect(p.session_id).toBe('ses')
    expect(p.admission_fee).toEqual({ charged: false })
    expect(screen.getByRole('link', { name: 'Open the profile' }).getAttribute('href')).toBe('/students?student=st-new')
  })

  it('Admit another starts again at step one, in the same class, with nobody’s details', async () => {
    const o = school()
    await toReview(o)
    fireEvent.click(screen.getByRole('button', { name: /Admit student/ }))
    await screen.findByText('1318')
    // The slip opens over the page by itself; the success card is still behind it.
    fireEvent.click(screen.getByRole('button', { name: 'Admit another' }))
    expect(await screen.findByText('About the child')).toBeTruthy()
    expect(name().value).toBe('')
    fireEvent.click(screen.getByRole('button', { name: 'Go to Class & fee' }))
    await waitFor(() => expect((document.querySelector('select[name=class_id]') as HTMLSelectElement).value).toBe('c5'))
  })

  it('a refused admission says why and keeps everything typed', async () => {
    const o = school()
    o.rpcErrors = { fn_admit_student: 'GR number 1318 is already used by another student' }
    await toReview(o)
    fireEvent.click(screen.getByRole('button', { name: /Admit student/ }))
    expect(await screen.findByText(/already used by another student/)).toBeTruthy()
    expect(screen.getByRole('heading', { name: 'Check, then admit' })).toBeTruthy()
    expect(screen.getAllByText('Zainab Aslam').length).toBeGreaterThan(0)
  })
})

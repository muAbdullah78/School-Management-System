// @vitest-environment jsdom
/**
 * Year Rollover starts from the year the children are actually in.
 *
 * It defaulted From to the current session, which is right only for a school
 * that rolls over before moving the current year on. A school that switched to
 * 2026-2027 first found From already set to 2026-2027, the year its children
 * were NOT in, and a preview that moved nobody.
 */
import { afterEach, describe, expect, it, vi } from 'vitest'
import { createElement } from 'react'
import { cleanup, render, screen, waitFor } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { MemoryRouter } from 'react-router-dom'
import { fakeSupabase, type FakeOptions } from './fakeSupabase'

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

const { Rollover } = await import('@/pages/settings/Rollover')

// The fake answers every academic_sessions read with these rows, and the
// current-session read takes the first, so the current year goes first.
const SESSIONS = [
  { id: 'ses-2627', name: '2026-2027', is_current: true, starts_on: '2026-04-01', ends_on: '2027-03-31' },
  { id: 'ses-2526', name: '2025-2026', is_current: false, starts_on: '2025-04-01', ends_on: '2026-03-31' },
]
const child = (i: number, last_session: string | null) => ({
  student_id: `s${i}`, full_name: `Child ${i}`, gr_no: null, father_name: null, admission_date: null,
  last_class: last_session ? 'Class 2' : null, last_session,
})

function open(noClass: ReturnType<typeof child>[]) {
  current.opts = {
    rows: { academic_sessions: SESSIONS, classes: [] },
    rpc: { fn_students_without_a_class: noClass },
  }
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false, gcTime: 0 } } })
  return render(createElement(MemoryRouter, null,
    createElement(QueryClientProvider, { client: qc }, createElement(Rollover))))
}

const selects = () => [...document.querySelectorAll('select')] as HTMLSelectElement[]

afterEach(() => cleanup())

describe('Year Rollover', () => {
  it('children stranded in last year: From is last year, To is this year, and it says why', async () => {
    open([child(1, '2025-2026'), child(2, '2025-2026'), child(3, null)])
    expect(await screen.findByText(/Chosen for you: 2 students were last in a class in 2025-2026/)).toBeTruthy()
    const [from, to] = selects()
    expect(from.value).toBe('ses-2526')
    expect(to.value).toBe('ses-2627')
  })

  it('nobody stranded: the old default, from the current year', async () => {
    open([])
    await waitFor(() => expect(selects()[0].value).toBe('ses-2627'))
    expect(screen.queryByText(/Chosen for you/)).toBeNull()
  })
})

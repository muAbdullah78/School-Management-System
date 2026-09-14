// @vitest-environment jsdom
/**
 * A principal must not be shown a screen they may not use.
 *
 * Migrations 0134 and 0135 revoke attendance marking and test creation from the
 * principal IN THE DATABASE. That half is asserted by
 * supabase/tests/who_marks_the_register.sql. This file asserts the other half,
 * which is easy to get wrong in a way nothing else would notice.
 *
 * THE FAILURE THIS GUARDS AGAINST is not a security hole: the database refuses
 * the write whatever the browser renders. It is worse than that in the way that
 * matters to a school. A head who is still given a class picker, a roster and a
 * Save button will fill one in, press Save, and be refused by a sentence they
 * did not expect, having done the work. And the screen they actually need, the
 * one that says which classes have not marked, would be reachable from nowhere.
 *
 * So what is asserted is BOTH directions:
 *
 *   * the principal gets the oversight screen and no marking controls
 *   * the teacher gets the marking screen and not the oversight one
 *   * the owner gets the oversight screen with the hatch on it, because 0134
 *     leaves the owner able to mark and this is where that decision is visible
 */
import { describe, expect, it, vi, afterEach } from 'vitest'
import { createElement, type ComponentType } from 'react'
import { cleanup, render, waitFor, fireEvent } from '@testing-library/react'
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

const SCHOOL = '22222222-2222-2222-2222-222222222222'

function profileWith(role: Role): Profile {
  return { id: `id-${role}`, full_name: `A ${role}`, role, staff_id: null, school_id: SCHOOL }
}

/** A school with one class and a current year, so both screens have work to do. */
const SCHOOL_WITH_A_CLASS: FakeOptions = {
  rows: {
    academic_sessions: [{ id: 'sess-1', name: '2026-2027', is_current: true }],
    classes: [{ id: 'cls-1', name: 'Class 4', level_order: 4 }],
    sections: [],
  },
  rpc: {
    fn_attendance_day: [{
      class_id: 'cls-1', class_name: 'Class 4', level_order: 4,
      section_id: null, section_name: null,
      pupils: 30, marked: 0, locked: 0, state: 'none',
    }],
    fn_subject_attendance_day: [],
    fn_tests_overview: [],
    fn_my_unmarked_tests: [],
    fn_my_assignments: [{ class_id: 'cls-1', class_name: 'Class 4', level_order: 4, section_id: null, section_name: null }],
  },
}

async function open(path: string, name: string, role: Role) {
  current.opts = SCHOOL_WITH_A_CLASS
  const mod = await import(/* @vite-ignore */ path)
  const Comp = (mod as Record<string, unknown>)[name] as ComponentType
  const qc = new QueryClient({
    defaultOptions: { queries: { retry: false, gcTime: 0 }, mutations: { retry: false } },
  })
  const utils = render(
    createElement(MemoryRouter, { initialEntries: ['/'] },
      createElement(AuthContext.Provider, {
        value: {
          session: { user: { id: `id-${role}` } } as never,
          profile: profileWith(role),
          loading: false,
          signIn: async () => ({ error: null }),
          signOut: async () => {},
          sendReset: async () => ({ error: null }),
          setPassword: async () => ({ error: null }),
        },
      },
        createElement(QueryClientProvider, { client: qc }, createElement(Comp)))),
  )
  await waitFor(() => expect(qc.isFetching()).toBe(0), { timeout: 4000 })
  return utils
}

const ATTENDANCE = ['@/pages/attendance/AttendancePage', 'AttendancePage'] as const
const TESTS = ['@/pages/assessments/TestsPage', 'TestsPage'] as const

afterEach(() => {
  cleanup()
  current.opts = {}
})

describe('the register', () => {
  it('gives a principal the oversight screen and no way to mark', async () => {
    const u = await open(ATTENDANCE[0], ATTENDANCE[1], 'principal')
    // The three piles a head thinks in. "Not done" appears twice on purpose,
    // as a count at the top and as the heading of the list underneath, so this
    // asserts on the one that is always present.
    expect(u.queryAllByText('Not done').length).toBeGreaterThan(0)
    expect(u.queryByText('Done and locked')).not.toBeNull()
    // And none of the marking apparatus.
    expect(u.queryByText(/^Save attendance$/)).toBeNull()
    expect(u.queryByText(/Finalize & lock/)).toBeNull()
    expect(u.queryByRole('button', { name: /mark a register/i })).toBeNull()
  })

  it('gives an observer the same screen, because oversight is what the role is for', async () => {
    const u = await open(ATTENDANCE[0], ATTENDANCE[1], 'readonly')
    expect(u.queryAllByText('Not done').length).toBeGreaterThan(0)
    expect(u.queryByText(/^Save attendance$/)).toBeNull()
    // Not even the owner's hatch. An observer writes nothing, ever.
    expect(u.queryByRole('button', { name: /mark a register/i })).toBeNull()
  })

  it('gives an owner the oversight screen with the hatch on it', async () => {
    const u = await open(ATTENDANCE[0], ATTENDANCE[1], 'owner')
    expect(u.queryAllByText('Not done').length).toBeGreaterThan(0)
    // THE HATCH IS DELIBERATE AND THIS IS WHERE THAT SHOWS. 0134 leaves the
    // owner able to mark: 'owner' is the signup account rather than a job
    // title, and a school of this size often has one account with any
    // authority. If that is ever decided against, this assertion is the one
    // that should fail and send somebody to fn_may_write_register.
    expect(u.queryByRole('button', { name: /mark a register/i })).not.toBeNull()
  })

  it('gives a class teacher the marking screen, not the overview', async () => {
    const u = await open(ATTENDANCE[0], ATTENDANCE[1], 'class_teacher')
    expect(u.queryByText('Done and locked')).toBeNull()
    // The two tabs a teacher gets: their register, and their subject.
    expect(u.queryByRole('button', { name: /daily register/i })).not.toBeNull()
    expect(u.queryByRole('button', { name: /subject attendance/i })).not.toBeNull()
  })

  it('lets a subject teacher reach the subject register from the same screen', async () => {
    const u = await open(ATTENDANCE[0], ATTENDANCE[1], 'subject_teacher')
    fireEvent.click(u.getByRole('button', { name: /subject attendance/i }))
    await waitFor(() =>
      expect(u.queryByText(/it is not the daily register/i)).not.toBeNull())
  })
})

describe('tests', () => {
  it('gives a principal the overview and no way to set a test', async () => {
    const u = await open(TESTS[0], TESTS[1], 'principal')
    expect(u.queryByText(/Waiting to be marked/i)).not.toBeNull()
    expect(u.queryByText(/^New test$/)).toBeNull()
    expect(u.queryByRole('button', { name: /create test/i })).toBeNull()
    expect(u.queryByRole('button', { name: /set a test/i })).toBeNull()
  })

  it('gives an owner the overview with the hatch', async () => {
    const u = await open(TESTS[0], TESTS[1], 'owner')
    expect(u.queryByText(/Waiting to be marked/i)).not.toBeNull()
    expect(u.queryByRole('button', { name: /set a test/i })).not.toBeNull()
  })

  it('gives a teacher the screen that can set one', async () => {
    const u = await open(TESTS[0], TESTS[1], 'class_teacher')
    expect(u.queryByText(/Waiting to be marked/i)).toBeNull()
    await waitFor(() => expect(u.queryByText(/Daily, weekly and monthly class tests/i)).not.toBeNull())
  })
})

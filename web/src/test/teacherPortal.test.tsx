// @vitest-environment jsdom
/**
 * Two teacher portal faults, pinned so they cannot come back:
 *
 *   * "My attendance" on a laptop drew the month as seven 150px squares a row,
 *     about 1000px of mostly empty calendar,
 *   * "Mark attendance" on a class card opened a blank register, and the
 *     teacher had to pick the class they had just pressed all over again.
 */
import { afterEach, describe, expect, it, vi } from 'vitest'
import { createElement, type ReactElement } from 'react'
import { cleanup, render, screen, waitFor } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { MemoryRouter, useLocation } from 'react-router-dom'
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

const { MyClass } = await import('@/pages/MyClass')
const { AttendancePage } = await import('@/pages/attendance/AttendancePage')
const { todayISO } = await import('@/lib/format')

const ME = '11111111-1111-1111-1111-111111111111'
const SCHOOL = '22222222-2222-2222-2222-222222222222'
const as = (role: Role, staffId: string | null = null): Profile =>
  ({ id: ME, full_name: 'Sidra Batool', role, staff_id: staffId, school_id: SCHOOL })

const where: { url: string } = { url: '' }
function Where() {
  const l = useLocation()
  where.url = `${l.pathname}${l.search}`
  return null
}

function open(node: ReactElement, opts: FakeOptions, profile: Profile, path = '/') {
  current.opts = opts
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false, gcTime: 0 } } })
  const auth = {
    session: { user: { id: ME, email: 'x@example.test' } } as never,
    profile, loading: false,
    signIn: async () => ({ error: null }), signOut: async () => {},
    sendReset: async () => ({ error: null }), setPassword: async () => ({ error: null }),
  }
  return render(
    createElement(MemoryRouter, { initialEntries: [path] },
      createElement(AuthContext.Provider, { value: auth },
        createElement(QueryClientProvider, { client: qc }, node, createElement(Where)))),
  )
}

afterEach(() => cleanup())

const ME_BASE = {
  linked: true, active: true, full: true, today: todayISO(), mode: 'rotating', geofence: false,
  record: null, can_check_out: false, out_opens_at: null,
}
const SESSION = { id: 'sess-1', name: '2026-27', is_current: true, starts_on: '2026-04-01', ends_on: '2027-03-31' }
const ROSTER = [
  { enrollment_id: 'e1', student_id: 's1', full_name: 'Ayesha Khan', father_name: null, roll_no: '1', status: null, is_locked: false },
  { enrollment_id: 'e2', student_id: 's2', full_name: 'Bilal Ahmed', father_name: null, roll_no: '2', status: null, is_locked: false },
]

describe('My attendance on a laptop', () => {
  it('is a centred card with a width cap, and each day is at most a 2.75rem square', async () => {
    open(createElement(MyClass), { rpc: { fn_my_checkin: ME_BASE, fn_my_staff_attendance: [], fn_my_assignments: [] } },
      as('class_teacher', 'st-1'))
    const first = await screen.findByLabelText(`${todayISO().slice(0, 7)}-01: Not recorded`)
    expect(first.className).toContain('aspect-square')
    const grid = first.parentElement!
    expect(grid.className).toContain('grid-cols-[repeat(7,minmax(0,2.75rem))]')
    expect(grid.className).toContain('justify-center')
    const card = screen.getByText('My attendance').parentElement!
    expect(card.className).toContain('max-w-md')
    expect(card.className).toContain('mx-auto')
  })
})

describe('Mark attendance on a class card', () => {
  it('carries the class and section to the register in the URL', async () => {
    open(createElement(MyClass), { rpc: { fn_my_checkin: ME_BASE, fn_my_staff_attendance: [], fn_my_assignments: [
      { class_id: 'c4', class_name: 'Class 4', level_order: 4, section_id: 's4a', section_name: 'A' },
      { class_id: 'c5', class_name: 'Class 5', level_order: 5, section_id: null, section_name: null },
    ] } }, as('class_teacher', 'st-1'))
    const links = await screen.findAllByRole('link', { name: 'Mark attendance' })
    expect(links.map((l) => l.getAttribute('href'))).toEqual([
      '/attendance?classId=c4&sectionId=s4a',
      '/attendance?classId=c5',
    ])
  })
})

describe('the register opened from that link', () => {
  const TEACHER = as('class_teacher', 'st-1')
  const ASSIGNED = [
    { class_id: 'c4', class_name: 'Class 4', level_order: 4, section_id: 's4a', section_name: 'A' },
    { class_id: 'c5', class_name: 'Class 5', level_order: 5, section_id: 's5a', section_name: 'A' },
  ]

  it('selects the class and section, stays on today, and loads the roster straight away', async () => {
    const calls: FakeOptions['calls'] = []
    open(createElement(AttendancePage), {
      calls,
      rows: {
        academic_sessions: [SESSION],
        classes: [{ id: 'c4', name: 'Class 4', level_order: 4 }, { id: 'c5', name: 'Class 5', level_order: 5 }],
        sections: [{ id: 's4a', name: 'A', class_id: 'c4' }, { id: 's4b', name: 'B', class_id: 'c4' }],
      },
      rpc: { fn_my_assignments: ASSIGNED, fn_section_roster: ROSTER },
    }, TEACHER, '/attendance?classId=c4&sectionId=s4a')

    expect(await screen.findByText('Ayesha Khan')).toBeTruthy()
    const [cls, sec] = screen.getAllByRole('combobox') as HTMLSelectElement[]
    expect(cls.value).toBe('c4')
    expect(sec.value).toBe('s4a')
    expect((screen.getByLabelText('Date') as HTMLInputElement).value).toBe(todayISO())
    const read = calls!.find((c) => c.name === 'fn_section_roster')!
    expect(read.args).toMatchObject({ p_class_id: 'c4', p_section_id: 's4a', p_date: todayISO() })
  })

  it('a class the teacher does not teach is dropped, not loaded', async () => {
    const calls: FakeOptions['calls'] = []
    open(createElement(AttendancePage), {
      calls,
      rows: {
        academic_sessions: [SESSION],
        classes: [{ id: 'c4', name: 'Class 4', level_order: 4 }, { id: 'c9', name: 'Class 9', level_order: 9 }],
        sections: [],
      },
      rpc: { fn_my_assignments: ASSIGNED, fn_section_roster: ROSTER },
    }, TEACHER, '/attendance?classId=c9')

    await waitFor(() => expect((screen.getAllByRole('combobox')[0] as HTMLSelectElement).value).toBe(''))
    await waitFor(() => expect(where.url).toBe('/attendance'))
    expect(screen.getByText(/to load the roster/)).toBeTruthy()
  })

  it('a class with one section the teacher may mark opens on it without a second pick', async () => {
    open(createElement(AttendancePage), {
      rows: {
        academic_sessions: [SESSION],
        classes: [{ id: 'c5', name: 'Class 5', level_order: 5 }],
        sections: [{ id: 's5a', name: 'A', class_id: 'c5' }],
      },
      rpc: { fn_my_assignments: [{ ...ASSIGNED[1], section_id: null, section_name: null }], fn_section_roster: ROSTER },
    }, TEACHER, '/attendance?classId=c5')

    expect(await screen.findByText('Bilal Ahmed')).toBeTruthy()
    expect((screen.getAllByRole('combobox')[1] as HTMLSelectElement).value).toBe('s5a')
    await waitFor(() => expect(where.url).toBe('/attendance?classId=c5&sectionId=s5a'))
  })

  it('with no class in the URL, the register still waits for a pick', async () => {
    open(createElement(AttendancePage), {
      rows: { academic_sessions: [SESSION], classes: [{ id: 'c4', name: 'Class 4', level_order: 4 }, { id: 'c5', name: 'Class 5', level_order: 5 }], sections: [] },
      rpc: { fn_my_assignments: ASSIGNED, fn_section_roster: ROSTER },
    }, TEACHER, '/attendance')
    expect(await screen.findByText(/to load the roster/)).toBeTruthy()
    expect((screen.getAllByRole('combobox')[0] as HTMLSelectElement).value).toBe('')
  })
})

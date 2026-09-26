// @vitest-environment jsdom
/**
 * The teacher portal, pinned so its faults cannot come back:
 *
 *   * the home screen said nothing about today: no register state, no tests to
 *     mark, no birthdays,
 *   * a teacher who only teaches a subject had an empty portal: no class on the
 *     home screen, in Tests, or in Subject attendance,
 *   * a subject teacher was offered subjects that are not theirs, and a
 *     section's teacher was offered "All sections",
 *   * a test set by mistake could not be removed by its teacher,
 *   * the register's letters disagreed with the calendars' (L was Leave in one
 *     and Late in the other),
 *   * Birthdays gave a teacher the whole school's list.
 */
import { afterEach, describe, expect, it, vi } from 'vitest'
import { createElement, type ReactElement } from 'react'
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

const { MyClass } = await import('@/pages/MyClass')
const { AttendancePage } = await import('@/pages/attendance/AttendancePage')
const { TestsPage } = await import('@/pages/assessments/TestsPage')
const { BirthdaysPage } = await import('@/pages/people/BirthdaysPage')
const { ATTENDANCE_STATUSES } = await import('@/lib/constants')
const { todayISO } = await import('@/lib/format')

const ME = '11111111-1111-1111-1111-111111111111'
const SCHOOL = '22222222-2222-2222-2222-222222222222'
const as = (role: Role): Profile => ({ id: ME, full_name: 'Sidra Batool', role, staff_id: 'st-1', school_id: SCHOOL })

function open(node: ReactElement, opts: FakeOptions, profile: Profile = as('class_teacher'), path = '/') {
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

afterEach(() => cleanup())

const T = todayISO()
const SESSION = { id: 'sess', name: '2026-27', is_current: true, starts_on: null, ends_on: null }
const CHECKIN = { linked: true, active: true, full: true, today: T, mode: null, geofence: false, record: null, can_check_out: false, out_opens_at: null }
const CLASS_TEACHER = [
  { class_id: 'c1', class_name: 'Class 1', level_order: 1, section_id: 'c1-a', section_name: 'A', is_class_teacher: true, subject_id: null, subject_name: null },
  { class_id: 'c1', class_name: 'Class 1', level_order: 1, section_id: 'c1-b', section_name: 'B', is_class_teacher: true, subject_id: null, subject_name: null },
]
const MATHS3 = { class_id: 'c3', class_name: 'Class 3', level_order: 3, section_id: null, section_name: null, is_class_teacher: false, subject_id: 's-maths3', subject_name: 'Maths' }
const DAY = {
  today: T, session_id: 'sess', to_mark: 2,
  classes: [
    { class_id: 'c1', class_name: 'Class 1', section_id: 'c1-a', section_name: 'A', is_class_teacher: true, subjects: [], pupils: 28,
      register: { marked: 12, present: 10, late: 1, half_day: 0, absent: 1, leave: 0, locked: false } },
    { class_id: 'c1', class_name: 'Class 1', section_id: 'c1-b', section_name: 'B', is_class_teacher: true, subjects: [], pupils: 26,
      register: { marked: 26, present: 24, late: 0, half_day: 0, absent: 1, leave: 1, locked: false } },
    { class_id: 'c3', class_name: 'Class 3', section_id: null, section_name: null, is_class_teacher: false, subjects: ['Maths'], pupils: 31, register: null },
  ],
  birthdays: [{ full_name: 'Hamna Masood', class_name: 'Class 1', section_name: 'A', turning: 7 }],
  upcoming: [{ id: 'u1', title: 'Tables quiz', date: T, max_marks: 20, class_id: 'c3', class_name: 'Class 3', section_name: null, subject_name: 'Maths' }],
}

describe('the teacher home', () => {
  it('says what today needs: each register, the tests to mark, the birthday', async () => {
    open(createElement(MyClass), { rpc: { fn_my_day: DAY, fn_my_checkin: CHECKIN, fn_my_staff_attendance: [] } })
    expect(await screen.findByText('12 of 28 marked')).toBeTruthy()
    expect(screen.getByText('Register saved')).toBeTruthy()
    expect(screen.getByText('1 register to mark')).toBeTruthy()
    expect(screen.getByText('2 tests to mark')).toBeTruthy()
    expect(screen.getByText(/turns 7/).textContent).toContain('Hamna Masood')
    expect(screen.getByRole('link', { name: /2 tests are waiting for marks/ }).getAttribute('href')).toBe('/assessments')
  })

  it('a subject class opens subject attendance and its tests, not a register it cannot mark', async () => {
    open(createElement(MyClass), { rpc: { fn_my_day: DAY, fn_my_checkin: CHECKIN, fn_my_staff_attendance: [] } })
    const card = (await screen.findByRole('heading', { name: 'Class 3' })).closest('article')!
    expect(within(card).getByRole('link', { name: /Attendance/ }).getAttribute('href')).toBe('/attendance?classId=c3&tab=subject')
    expect(within(card).getByRole('link', { name: /Tests/ }).getAttribute('href')).toBe('/assessments?classId=c3')
    expect(within(card).queryByText(/marked|Register/)).toBeNull()
  })

  it('on a database before bundle 52 it falls back to the class teacher\'s list instead of breaking', async () => {
    open(createElement(MyClass), {
      rpc: { fn_my_checkin: CHECKIN, fn_my_staff_attendance: [],
             fn_my_assignments: [{ class_id: 'c1', class_name: 'Class 1', level_order: 1, section_id: 'c1-a', section_name: 'A' }] },
      rpcErrors: { fn_my_day: 'Could not find the function public.fn_my_day in the schema cache' },
    })
    const link = await screen.findByRole('link', { name: /Mark attendance/ })
    expect(link.getAttribute('href')).toBe('/attendance?classId=c1&sectionId=c1-a')
    expect(screen.queryByText(/schema cache/)).toBeNull()
  })
})

describe('a teacher who only teaches a subject', () => {
  const OPTS: FakeOptions = {
    rows: { academic_sessions: [SESSION], sections: [],
            subjects: [{ id: 's-maths3', name: 'Maths', class_id: 'c3' }, { id: 's-eng3', name: 'English', class_id: 'c3' }] },
    rpc: { fn_my_assignments: [], fn_my_teaching: [MATHS3] },
  }

  it('opens attendance on Subject attendance, with their class and only their subject', async () => {
    open(createElement(AttendancePage), OPTS, as('subject_teacher'), '/attendance')
    await waitFor(() => expect(screen.getByRole('button', { name: 'Subject attendance' }).getAttribute('aria-current')).toBe('page'))
    const [cls, , subject] = screen.getAllByRole('combobox') as HTMLSelectElement[]
    await waitFor(() => expect(cls.value).toBe('c3'))
    await waitFor(() => expect(subject.value).toBe('s-maths3'))
    expect(within(subject).queryByRole('option', { name: 'English' })).toBeNull()
  })

  it('is told in words why the daily register is not theirs', async () => {
    open(createElement(AttendancePage), OPTS, as('subject_teacher'), '/attendance?tab=daily')
    expect(await screen.findByText(/you are not the class\s+teacher of any class/)).toBeTruthy()
    expect(screen.getByRole('button', { name: 'Open subject attendance' })).toBeTruthy()
  })

  it('can pick their class in Tests, and the new test is in their subject', async () => {
    open(createElement(TestsPage), { ...OPTS, rows: { ...OPTS.rows, assessments: [] }, rpc: { ...OPTS.rpc, fn_my_unmarked_tests: [] } },
      as('subject_teacher'), '/assessments')
    expect(await screen.findByRole('button', { name: 'Class 3' })).toBeTruthy()
    const subject = (await screen.findAllByRole('combobox'))[0] as HTMLSelectElement
    await waitFor(() => expect(subject.value).toBe('s-maths3'))
    expect(within(subject).queryByRole('option', { name: 'General' })).toBeNull()
    expect(within(subject).queryByRole('option', { name: 'English' })).toBeNull()
  })
})

describe('the tests screen', () => {
  const TESTS = [
    { id: 't3', title: 'Weekly test 3', assessment_date: '2026-01-10', max_marks: 20, is_locked: false, section_id: 'c1-a', subject_id: null, sections: { name: 'A' }, subjects: null },
    { id: 't9', title: 'Set twice by mistake', assessment_date: '2099-01-01', max_marks: 20, is_locked: false, section_id: 'c1-a', subject_id: null, sections: { name: 'A' }, subjects: null },
  ]
  const OPTS: FakeOptions = {
    rows: { academic_sessions: [SESSION], assessments: TESTS,
            sections: [{ id: 'c1-a', name: 'A', class_id: 'c1' }, { id: 'c1-b', name: 'B', class_id: 'c1' }],
            subjects: [{ id: 's-eng', name: 'English', class_id: 'c1' }] },
    rpc: {
      fn_my_teaching: CLASS_TEACHER,
      fn_my_unmarked_tests: [{ assessment_id: 't3', title: 'Weekly test 3', assessment_date: '2026-01-10', class_id: 'c1', class_name: 'Class 1', section_name: 'A', subject_name: null, pupils: 3, marked: 2, days_late: 3 }],
      fn_assessment_marksheet: [
        { enrollment_id: 'e1', student_id: 's1', full_name: 'Ayesha Aslam', roll_no: '1', section_name: 'A', marks: 15, is_absent: false, is_locked: false, max_marks: 20 },
        { enrollment_id: 'e2', student_id: 's2', full_name: 'Omar Farooq', roll_no: '2', section_name: 'A', marks: 11, is_absent: false, is_locked: false, max_marks: 20 },
        { enrollment_id: 'e3', student_id: 's3', full_name: 'Hira Baig', roll_no: '3', section_name: 'A', marks: null, is_absent: false, is_locked: false, max_marks: 20 },
      ],
    },
  }

  it('a section\'s class teacher is never offered "All sections", and may set a general test', async () => {
    open(createElement(TestsPage), OPTS, as('class_teacher'), '/assessments?classId=c1')
    // The section box appears once the sections have loaded.
    await waitFor(() => expect(screen.getAllByRole('combobox')).toHaveLength(2))
    const [subject, section] = screen.getAllByRole('combobox') as HTMLSelectElement[]
    await waitFor(() => expect(section.value).toBe('c1-a'))
    expect(within(section).queryByRole('option', { name: 'All sections' })).toBeNull()
    expect(within(subject).getByRole('option', { name: 'General' })).toBeTruthy()
  })

  it('a reminder opens its test, and one press marks the blanks absent', async () => {
    open(createElement(TestsPage), OPTS, as('class_teacher'), '/assessments?classId=c1')
    const reminder = await screen.findByText('One test is waiting for marks')
    fireEvent.click(within(reminder.parentElement!).getByRole('button', { name: /Weekly test 3/ }))
    expect(await screen.findByRole('heading', { name: 'Weekly test 3' })).toBeTruthy()
    fireEvent.click(await screen.findByRole('button', { name: 'Mark the 1 blank as absent' }))
    await waitFor(() => {
      const hira = screen.getAllByRole('button', { name: 'Hira Baig: absent' })[0]
      expect(hira.getAttribute('aria-pressed')).toBe('true')
    })
  })

  it('a test set by mistake is removed by its teacher, through the database', async () => {
    const calls: FakeOptions['calls'] = []
    open(createElement(TestsPage), { ...OPTS, calls }, as('class_teacher'), '/assessments?classId=c1')
    const card = (await screen.findByText('Set twice by mistake')).closest('li')!
    fireEvent.click(within(card).getByRole('button', { name: 'Edit' }))
    fireEvent.click(within(card).getByRole('button', { name: 'Remove this test' }))
    const confirm = await screen.findByRole('button', { name: 'Remove it' })
    // The dialog is a form of its own and must not sit inside the edit form:
    // there, confirming the removal submitted the edit form as well.
    expect(document.querySelectorAll('form form')).toHaveLength(0)
    fireEvent.click(confirm)
    await waitFor(() => expect(calls!.find((c) => c.name === 'fn_delete_my_test')?.args).toEqual({ p_assessment_id: 't9' }))
  })
})

describe('one set of letters', () => {
  it('Lt is late and Lv is leave everywhere, so a teacher and a parent read the same letter', () => {
    const short = Object.fromEntries(ATTENDANCE_STATUSES.map((s) => [s.value, s.short]))
    expect(short).toMatchObject({ present: 'P', absent: 'A', late: 'Lt', leave: 'Lv', half_day: '½' })
  })
})

describe('birthdays for a teacher', () => {
  it('open on the teacher\'s own classes, with the whole school one tap away', async () => {
    open(createElement(BirthdaysPage), {
      rpc: {
        fn_my_teaching: CLASS_TEACHER,
        fn_birthdays: [
          { kind: 'student', id: 'b1', full_name: 'Hamna Masood', dob: '2019-01-01', turning: 7, birthday: T, days_away: 0, class_name: 'Class 1', detail: '', phone: null },
          { kind: 'student', id: 'b2', full_name: 'Ali Raza', dob: '2012-01-01', turning: 14, birthday: T, days_away: 0, class_name: 'Class 8', detail: '', phone: null },
        ],
      },
    }, as('class_teacher'), '/birthdays')
    expect(await screen.findByText('Hamna Masood')).toBeTruthy()
    await waitFor(() => expect(screen.queryByText('Ali Raza')).toBeNull())
    fireEvent.click(screen.getByRole('button', { name: 'Whole school' }))
    expect(await screen.findByText('Ali Raza')).toBeTruthy()
  })
})

// @vitest-environment jsdom
/**
 * Exams & Results and the sidebar, rebuilt (0152), pinned so the faults cannot
 * come back:
 *
 *   * a teacher could not reach Exams at all, and a section's teacher was
 *     shown, and could save, the whole class,
 *   * a paper row built before the paper arrived started from the defaults, and
 *     Update wrote them over the real paper,
 *   * an exam term could not be corrected or deleted, and two could share a name,
 *   * the release panel said the pupils not re-released were "hidden" when
 *     their parents were still being shown the earlier card, and release was
 *     offered for cards that no longer matched the marks,
 *   * a released class's remarks could still be edited, and a class teacher was
 *     shown another section's pupils,
 *   * the printed card had no remark, no section and no father's name,
 *   * the sidebar was one flat list, called a teacher's home "Dashboard", and
 *     could not be folded.
 */
import { afterEach, describe, expect, it, vi } from 'vitest'
import { createElement, type ReactElement } from 'react'
import { cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { MemoryRouter, Route, Routes } from 'react-router-dom'
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

const { ExamsPage } = await import('@/pages/exams/ExamsPage')
const { ResultCardPrint } = await import('@/pages/exams/ResultCardPrint')
const { AppShell } = await import('@/components/AppShell')
const { canAccess } = await import('@/navigation')

const ME = '11111111-1111-1111-1111-111111111111'
const SCHOOL = '22222222-2222-2222-2222-222222222222'
const as = (role: Role, name = 'Bilal Ahmed'): Profile => ({ id: ME, full_name: name, role, staff_id: 'st-1', school_id: SCHOOL })

function mount(node: ReactElement, opts: FakeOptions, profile: Profile, path: string) {
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

afterEach(() => { cleanup(); try { window.localStorage.clear() } catch { /* none */ } })

const SESSION = { id: 'sess', name: '2026-2027', is_current: true, starts_on: null, ends_on: null }
const TERM = { id: 't1', name: 'First Term', term_type: 'first', starts_on: null, ends_on: null, result_withheld_for_defaulters: true }
const PHYSICS = {
  id: 'es-phy', subject_id: 's-phy', max_marks: 75, pass_marks: 33, practical_max: 25, exam_date: null, paper_time: null,
  subjects: { name: 'Physics', sort_order: 1, stream: null, is_practical: true },
}
const sheetRow = (i: number, name: string, sec: 'a' | 'b') => ({
  enrollment_id: `en${i}`, student_id: `st${i}`, full_name: name, roll_no: String(i), section_name: sec.toUpperCase(),
  section_id: `c9-${sec}`, marks: null, practical_marks: null, is_absent: false, is_locked: false, max_marks: 75, practical_max: 25,
})
const BASE_ROWS = {
  academic_sessions: [SESSION],
  exam_terms: [TERM],
  classes: [{ id: 'c9', name: 'Class 9', level_order: 90, active: true }, { id: 'c8', name: 'Class 8', level_order: 80, active: true }],
}

describe('a teacher marks the papers they teach, and only their own section', () => {
  it('gets Marks Entry alone, sees 9 A and not 9 B, and saves only 9 A', async () => {
    const calls: FakeOptions['calls'] = []
    mount(createElement(ExamsPage), {
      rows: { ...BASE_ROWS, exam_subjects: [PHYSICS] },
      rpc: {
        fn_my_teaching: [{ class_id: 'c9', class_name: 'Class 9', level_order: 90, section_id: 'c9-a', section_name: 'A', is_class_teacher: false, subject_id: 's-phy', subject_name: 'Physics' }],
        fn_exam_marksheet: [sheetRow(1, 'Ahmed Raza', 'a'), sheetRow(2, 'Fatima Noor', 'a'), sheetRow(3, 'Zainab Iqbal', 'b')],
        fn_exam_paper_progress: [],
        fn_enter_marks: { marked: 1, cleared: 0, skipped: 0, total: 2, written: 1 },
      },
      calls,
    }, as('subject_teacher'), '/exams')

    // The one class and the one paper are chosen for them.
    expect((await screen.findAllByText('Ahmed Raza', {}, { timeout: 3000 })).length).toBeGreaterThan(0)
    expect(screen.queryAllByText('Zainab Iqbal')).toHaveLength(0)
    expect(screen.queryByRole('button', { name: 'Setup' })).toBeNull()
    expect(screen.getAllByText('Your sections only').length).toBeGreaterThan(0)

    const box = screen.getAllByLabelText('Ahmed Raza: theory')[0]
    fireEvent.change(box, { target: { value: '61' } })
    fireEvent.click(screen.getByRole('button', { name: /Save 1 change/ }))
    await waitFor(() => expect(calls!.some((c) => c.name === 'fn_enter_marks')).toBe(true))
    const sent = calls!.find((c) => c.name === 'fn_enter_marks')!.args.p_marks as { enrollment_id: string; marks: number | null }[]
    expect(sent.map((r) => r.enrollment_id).sort()).toEqual(['en1', 'en2'])
    expect(sent.find((r) => r.enrollment_id === 'en1')!.marks).toBe(61)
    // A blank box is sent as a blank, which the database now treats as "not
    // marked" (0152) instead of storing a zero.
    expect(sent.find((r) => r.enrollment_id === 'en2')!.marks).toBeNull()
  })

  it('opens Exams to class and subject teachers in the sidebar', () => {
    expect(canAccess('/exams', 'class_teacher')).toBe(true)
    expect(canAccess('/exams', 'subject_teacher')).toBe(true)
  })
})

describe('Setup', () => {
  it('shows the paper as saved, never the defaults it would have started from', async () => {
    mount(createElement(ExamsPage), {
      rows: { ...BASE_ROWS, exam_subjects: [PHYSICS], subjects: [{ id: 's-phy', name: 'Physics', class_id: 'c9', sort_order: 1, stream: null, is_practical: true }] },
      rpc: { fn_exam_paper_progress: [], fn_exam_term_overview: [] },
    }, as('owner', 'Owner'), '/exams?tab=setup&term=t1&class=c9')
    const theory = await screen.findByLabelText('Physics: theory out of')
    expect((theory as HTMLInputElement).value).toBe('75')
    expect((screen.getByLabelText('Physics: practical out of') as HTMLInputElement).value).toBe('25')
  })

  it('refuses a second term with the same name before anything is sent', async () => {
    mount(createElement(ExamsPage), { rows: BASE_ROWS, rpc: { fn_exam_term_overview: [] } }, as('owner', 'Owner'), '/exams?tab=setup&term=t1')
    fireEvent.click(await screen.findByRole('button', { name: /New term/ }))
    // It opens on the next type this year does not have: Mid Term.
    const name = await screen.findByPlaceholderText('e.g. First Term')
    expect((name as HTMLInputElement).value).toBe('Mid Term')
    fireEvent.change(name, { target: { value: ' first term ' } })
    expect(await screen.findByText(/already has a term called first term/)).toBeTruthy()
    expect((screen.getByRole('button', { name: 'Add term' }) as HTMLButtonElement).disabled).toBe(true)
  })

  it('deletes a term through the database, which refuses one with work in it', async () => {
    const calls: FakeOptions['calls'] = []
    mount(createElement(ExamsPage), { rows: BASE_ROWS, rpc: { fn_exam_term_overview: [], fn_delete_exam_term: null }, calls },
      as('owner', 'Owner'), '/exams?tab=setup&term=t1')
    fireEvent.click(await screen.findByRole('button', { name: 'Delete First Term' }))
    fireEvent.click(await screen.findByRole('button', { name: 'Delete the term' }))
    await waitFor(() => expect(calls!.find((c) => c.name === 'fn_delete_exam_term')?.args).toEqual({ p_id: 't1' }))
  })
})

const card = (i: number, published: string | null) => ({
  id: `rc${i}`, enrollment_id: `en${i}`, student_id: `st${i}`, total_marks: 300, total_max: 400, percentage: 75, grade: 'A',
  position: i, attendance_pct: 90, version: 2, published_at: published,
  frozen: { subjects: [], total_marks: 300, total_max: 400, percentage: 75, grade: 'A', position: i, attendance_pct: 90, result: 'PASS', failed_subjects: 0, pass_percent: 33, provisional: false, unmarked_subjects: 0, withheld: false, generated_at: '2026-09-28T09:00:00Z', version: 2 },
  students: { full_name: `Pupil ${i}`, gr_no: null, father_name: null },
  enrollments: { class_id: 'c8', roll_no: String(i), sections: { name: 'A' } },
})

describe('Result cards', () => {
  it('says parents still see the earlier version, and will not release cards that are out of date', async () => {
    mount(createElement(ExamsPage), {
      rows: { ...BASE_ROWS, result_cards: [card(1, null), card(2, null)] },
      rpc: {
        fn_exam_term_overview: [{ class_id: 'c8', class_name: 'Class 8', level_order: 80, papers: 4, pupils: 2, marks_expected: 8, marks_entered: 8, cards: 2, released: 0, older_released: 2, generated_at: null, out_of_date: 1 }],
        fn_result_readiness: [{ problem: 'cards out of date', detail: 'Marks have changed for 1 pupil since the cards were made.', affected: 1 }],
        fn_exam_remarks: [],
      },
    }, as('owner', 'Owner'), '/exams?tab=results&term=t1&class=c8')
    expect(await screen.findByText(/Parents still see the earlier version of 2 cards/)).toBeTruthy()
    expect(screen.getByText(/The cards are out of date/)).toBeTruthy()
    expect((screen.getByRole('button', { name: 'Release to parents' }) as HTMLButtonElement).disabled).toBe(true)
    // Generating is the cure, so it stays offered.
    expect(screen.getByRole('button', { name: 'Make the cards again' })).toBeTruthy()
  })

  it('prints the class teacher\'s remark, the section and the father\'s name on the card', () => {
    const c = { ...card(1, null), full_name: 'Ahmed Raza', gr_no: 'GR 1', roll_no: '1', father_name: 'Raza Ahmed', section_name: 'A' }
    mount(createElement(ResultCardPrint, {
      card: c as never, termName: 'First Term', className: 'Class 8', remark: 'A bright and careful pupil.', onClose: () => {},
    }), {}, as('owner', 'Owner'), '/')
    expect(screen.getByText('A bright and careful pupil.')).toBeTruthy()
    expect(screen.getByText(/Section A/)).toBeTruthy()
    expect(screen.getByText('Raza Ahmed')).toBeTruthy()
  })
})

describe('Remarks', () => {
  it('shows a class teacher their own section, and a released class read-only', async () => {
    const r = (i: number, name: string, sec: string) => ({
      student_id: `st${i}`, student_name: name, gr_no: null, roll_no: String(i), section_name: sec.toUpperCase(),
      section_id: `c8-${sec}`, remark: null, remark_by_name: '-', updated_at: null, percentage: 70, grade: 'A',
      class_position: i, released: true,
    })
    mount(createElement(ExamsPage), {
      rows: BASE_ROWS,
      rpc: {
        fn_my_teaching: [{ class_id: 'c8', class_name: 'Class 8', level_order: 80, section_id: 'c8-a', section_name: 'A', is_class_teacher: true, subject_id: null, subject_name: null }],
        fn_exam_remarks: [r(1, 'Ahmed Raza', 'a'), r(2, 'Zainab Iqbal', 'b')],
      },
    }, as('class_teacher', 'Sidra Batool'), '/exams?tab=remarks&term=t1&class=c8')
    const box = await screen.findByLabelText('Remark for Ahmed Raza')
    expect(screen.queryByLabelText('Remark for Zainab Iqbal')).toBeNull()
    expect((box as HTMLTextAreaElement).disabled).toBe(true)
    expect(screen.getByText(/results have been released, so its remarks/)).toBeTruthy()
  })
})

/* ---------------------------------------------------------------- sidebar --- */

function desktop(yes: boolean) {
  Object.defineProperty(window, 'matchMedia', {
    configurable: true, writable: true,
    value: (q: string) => ({
      media: q, matches: yes, onchange: null,
      addEventListener: () => {}, removeEventListener: () => {}, addListener: () => {}, removeListener: () => {},
      dispatchEvent: () => false,
    }),
  })
}

function shell(profile: Profile) {
  return mount(
    createElement(Routes, null,
      createElement(Route, { path: '/', element: createElement(AppShell) },
        createElement(Route, { index: true, element: createElement('div', null, 'HOME') }))),
    { rows: { academic_sessions: [SESSION] } }, profile, '/')
}

describe('the sidebar', () => {
  it('puts the office\'s fourteen modules in named sections', async () => {
    desktop(true)
    const { container } = shell(as('owner', 'Owner'))
    const aside = container.querySelector('#app-sidebar') as HTMLElement
    for (const g of ['Every day', 'Learning', 'Pupils & families', 'Money', 'Running the school']) {
      expect(within(aside).getByRole('group', { name: g })).toBeTruthy()
    }
    expect(within(aside).getByRole('link', { name: /Dashboard/ })).toBeTruthy()
  })

  it('calls a teacher\'s home My day, and gives five rows no section headings', async () => {
    desktop(true)
    const { container } = shell(as('class_teacher', 'Sidra Batool'))
    const aside = container.querySelector('#app-sidebar') as HTMLElement
    expect(within(aside).getByRole('link', { name: /My day/ })).toBeTruthy()
    expect(within(aside).getByRole('link', { name: /Exams & Results/ })).toBeTruthy()
    expect(within(aside).queryByText('Every day')).toBeNull()
    expect(within(aside).queryByLabelText('Search modules')).toBeNull()
  })

  it('folds to a rail on a desktop and remembers it', async () => {
    desktop(true)
    const { container } = shell(as('owner', 'Owner'))
    const aside = () => container.querySelector('#app-sidebar') as HTMLElement
    expect(aside().className).toContain('lg:w-64')
    fireEvent.click(screen.getByRole('button', { name: 'Collapse the sidebar' }))
    await waitFor(() => expect(aside().className).toContain('lg:w-[4.75rem]'))
    expect(window.localStorage.getItem('tsm.sidebar.folded')).toBe('1')
    // Every row keeps its name for a screen reader and a tooltip for the eye.
    expect(within(aside()).getByRole('link', { name: /Fees/ }).getAttribute('title')).toBe('Fees')
    fireEvent.click(screen.getByRole('button', { name: 'Expand the sidebar' }))
    await waitFor(() => expect(aside().className).toContain('lg:w-64'))
  })

  it('has no fold button in the phone drawer, where it would sit in the focus trap', () => {
    desktop(false)
    shell(as('owner', 'Owner'))
    expect(screen.queryByRole('button', { name: 'Collapse the sidebar' })).toBeNull()
  })
})

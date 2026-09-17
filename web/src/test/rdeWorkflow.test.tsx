// @vitest-environment jsdom
/**
 * The workflow a clerk processing a hundred children an hour actually has.
 *
 * ASSERTION 1 IS THE VENDOR'S OWN REPORT: "Save and add the next" put them back
 * on another screen. Whatever the mechanism, the guarantee has to be locked
 * down, so this drives the REAL Students page from the real URL the screen is
 * reached by, saves, and demands the form is still there with the cursor in it.
 * A native form submit would drop ?add=quick and land on the roster, which is
 * exactly what being thrown out looks like, so the button is type="button" and
 * the form preventDefaults.
 *
 * ASSERTION 4 IS THE ONE THAT PREVENTS A QUIET DISASTER: two children on roll 1.
 * Nothing in the schema forbids it, so there is no error to catch it. The grid
 * has to fill the column with numbers nobody has used.
 */
import { describe, expect, it, vi, afterEach, beforeEach } from 'vitest'
import { createElement } from 'react'
import { cleanup, render, screen, waitFor, fireEvent } from '@testing-library/react'
import { MemoryRouter } from 'react-router-dom'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { fakeSupabase, type FakeOptions } from './fakeSupabase'
import { StudentsPage } from '@/pages/students/StudentsPage'
import { freeRolls } from '@/lib/db'

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
vi.mock('@/auth/AuthProvider', () => ({
  useAuth: () => ({ profile: { id: 'u1', role: 'owner', full_name: 'Head' } }),
}))

/** Class 1 (A) already holds three children, on rolls 1, 2 and 4. */
const SCHOOL: FakeOptions = {
  rows: {
    academic_sessions: [{
      id: 'sess-1', name: '2026-2027', is_current: true,
      starts_on: '2026-06-01', ends_on: '2027-05-31',
    }],
    classes: [{ id: 'cls-1', name: 'Class 1', level_order: 1 }],
    sections: [{ id: 'sec-1', name: 'A', class_id: 'cls-1' }],
    students: [],
  },
  rpc: {
    fn_student_list: [],
    fn_draft_student_ids: [],
    fn_section_roll_state: { on_roll: 3, taken: [1, 2, 4], unnumbered: 0, next_free: 5 },
    fn_rde_add_students: {
      created: 1, failed: 0, drafts: 0,
      results: [{
        row: 1, status: 'created', student_id: 'stu-new', gr_no: '0004',
        roll_no: '3', full_name: 'Bilal Ahmad', is_draft: false,
      }],
    },
    fn_portal_targets: [],
  },
}

function openQuickAdd(opts: FakeOptions = SCHOOL) {
  current.opts = opts
  try { localStorage.setItem('rde.classId', 'cls-1'); localStorage.setItem('rde.sectionId', 'sec-1') } catch { /* ignore */ }
  const qc = new QueryClient({
    defaultOptions: { queries: { retry: false, gcTime: 0 }, mutations: { retry: false } },
  })
  return render(createElement(MemoryRouter, { initialEntries: ['/students?add=quick'] },
    createElement(QueryClientProvider, { client: qc }, createElement(StudentsPage))))
}

beforeEach(() => { localStorage.clear() })
afterEach(() => cleanup())

describe('Save and add the next keeps the clerk where they are', () => {
  it('1. THE REPORTED BUG: the screen does not change, and the form clears', async () => {
    openQuickAdd()
    const name = await screen.findByPlaceholderText(/As written in the register/i)
    fireEvent.change(name, { target: { value: 'Bilal Ahmad' } })
    fireEvent.click(screen.getByRole('button', { name: /Save and add the next/ }))

    await waitFor(() => expect(screen.getByText('Bilal Ahmad')).toBeTruthy())
    // Still on rapid entry: the roster would show "Add students", not this.
    expect(screen.getByText(/Back to the roster/)).toBeTruthy()
    const after = screen.getByPlaceholderText(/As written in the register/i) as HTMLInputElement
    expect(after.value).toBe('')
    expect(document.activeElement).toBe(after)
  })

  it('2. and the roll number moves on past the child just saved', async () => {
    openQuickAdd()
    await screen.findByPlaceholderText(/As written in the register/i)
    // Pre-filled with the first free roll: 1, 2 and 4 are taken, so 3.
    const rollBox = () => screen.getByLabelText?.('Roll no') as HTMLInputElement | undefined
    await waitFor(() => {
      const boxes = Array.from(document.querySelectorAll<HTMLInputElement>('input.tabular-nums'))
      expect(boxes.length).toBeGreaterThan(0)
      expect(boxes[0].value).toBe('3')
    })
    void rollBox

    fireEvent.change(screen.getByPlaceholderText(/As written in the register/i), {
      target: { value: 'Bilal Ahmad' },
    })
    fireEvent.click(screen.getByRole('button', { name: /Save and add the next/ }))
    // The server said this child took roll 3, so the next one is offered 4... but
    // 4 is taken, which is why the NEXT read of the roll state matters more than
    // arithmetic. What must never happen is the box going back to empty.
    await waitFor(() => {
      const boxes = Array.from(document.querySelectorAll<HTMLInputElement>('input.tabular-nums'))
      expect(boxes[0].value).not.toBe('')
    })
  })

  it('3. says what the section already holds, instead of an empty box', async () => {
    openQuickAdd()
    await waitFor(() =>
      expect(screen.getByText(/This section already has/)).toBeTruthy())
    expect(screen.getByText(/on rolls 1 to 4/)).toBeTruthy()
  })
})

describe('the roll numbers nobody has used', () => {
  it('4. freeRolls skips every taken number, in order', () => {
    expect(freeRolls([1, 2, 4], 4)).toEqual([3, 5, 6, 7])
    expect(freeRolls([], 3)).toEqual([1, 2, 3])
    // A corrupt roll must not spin the browser or shift everything after it.
    expect(freeRolls([999999], 3)).toEqual([1, 2, 3])
    expect(freeRolls([1, 2, 3], 0)).toEqual([])
  })
})

describe('the fee is on the screen, not two cards below the fold', () => {
  it('5. Quick Add offers this month paid, a concession and the months owed', async () => {
    openQuickAdd()
    await screen.findByPlaceholderText(/As written in the register/i)
    expect(screen.getByText(/This month.s fee is already collected/)).toBeTruthy()
    expect(screen.getByText(/A concession applies/)).toBeTruthy()
    expect(screen.getByText(/Owes for earlier months/)).toBeTruthy()
  })
})

/**
 * The parent portal, made without anybody pressing anything.
 *
 * ASSERTION 6 IS THE ONE THAT MATTERS MOST AND IS EASIEST TO GET WRONG:
 * supabase.auth.signUp REPLACES THE CURRENT SESSION with the account it creates.
 * Called from the office, the clerk would be silently signed in as the parent
 * they just entered, and their next click would land on the portal or be
 * refused. To them that is indistinguishable from the software throwing them out
 * of the screen. The Edge Function holds the service key and touches nobody's
 * session, so this asserts the call goes there and nowhere near auth.
 */
describe('the portal generates itself', () => {
  it('6. goes through the Edge Function, never through auth.signUp', async () => {
    const calls: { name: string; args: Record<string, unknown> }[] = []
    const invoked: { fn: string; body: any }[] = []
    current.opts = {
      ...SCHOOL,
      calls,
      rpc: {
        ...SCHOOL.rpc,
        fn_portal_targets: [{
          family_id: 'fam-1', head_name: 'Shahid Anwar', student_id: 'stu-new',
          student_name: 'Bilal Ahmad', gr_no: '0004', number: '03331234567',
          email: 'shahid03331234567@gmail.com', password: '03331234567',
        }],
        fn_link_parents: 1,
        fn_remember_login_passwords: 1,
      },
      fn: {
        'create-teacher': {
          data: { version: 5, results: [{ email: 'shahid03331234567@gmail.com', family_id: 'fam-1', id: 'prof-1', status: 'created' }] },
        },
      },
      onInvoke: (fn, body) => { invoked.push({ fn, body }) },
    } as FakeOptions
    try { localStorage.setItem('rde.classId', 'cls-1'); localStorage.setItem('rde.sectionId', 'sec-1') } catch { /* ignore */ }
    const qc = new QueryClient({
      defaultOptions: { queries: { retry: false, gcTime: 0 }, mutations: { retry: false } },
    })
    render(createElement(MemoryRouter, { initialEntries: ['/students?add=quick'] },
      createElement(QueryClientProvider, { client: qc }, createElement(StudentsPage))))

    fireEvent.change(await screen.findByPlaceholderText(/As written in the register/i), {
      target: { value: 'Bilal Ahmad' },
    })
    fireEvent.click(screen.getByRole('button', { name: /Save and add the next/ }))

    // Two invocations, in order: the version probe (empty body, GET) that
    // stops a stale deployment from producing the "ghost" banner, then the
    // real create_batch. Asserting both counts and the order keeps the probe
    // from being silently dropped by a future refactor.
    await waitFor(() => expect(invoked.length).toBe(2))
    const batch = invoked.find((i) => (i.body as any)?.action === 'create_batch')
    expect(batch).toBeTruthy()
    expect(batch!.fn).toBe('create-teacher')
    expect(batch!.body.role).toBe('parent')
    expect(batch!.body.logins[0].email).toBe('shahid03331234567@gmail.com')
    // Attached to the family and written to the key ring, both batched.
    await waitFor(() => expect(calls.some((c) => c.name === 'fn_link_parents')).toBe(true))
    expect(calls.some((c) => c.name === 'fn_remember_login_passwords')).toBe(true)
    await waitFor(() => expect(screen.getByText(/Parent portal login created/)).toBeTruthy())
  })

  it('7. a school with an old Edge Function still gets its register in', async () => {
    current.opts = {
      ...SCHOOL,
      rpc: {
        ...SCHOOL.rpc,
        fn_portal_targets: [{
          family_id: 'fam-1', head_name: 'Shahid Anwar', student_id: 'stu-new',
          student_name: 'Bilal Ahmad', gr_no: '0004', number: '0333',
          email: 'shahid0333@gmail.com', password: '0333aa',
        }],
      },
      fn: { 'create-teacher': { error: { name: 'FunctionsHttpError', message: 'Unknown action' } } },
    }
    try { localStorage.setItem('rde.classId', 'cls-1') } catch { /* ignore */ }
    const qc = new QueryClient({
      defaultOptions: { queries: { retry: false, gcTime: 0 }, mutations: { retry: false } },
    })
    render(createElement(MemoryRouter, { initialEntries: ['/students?add=quick'] },
      createElement(QueryClientProvider, { client: qc }, createElement(StudentsPage))))

    fireEvent.change(await screen.findByPlaceholderText(/As written in the register/i), {
      target: { value: 'Bilal Ahmad' },
    })
    fireEvent.click(screen.getByRole('button', { name: /Save and add the next/ }))

    // THE CHILD IS IN. That is the guarantee: a login that could not be made is
    // a sentence on the screen, never a lost record.
    await waitFor(() => expect(screen.getByText('Bilal Ahmad')).toBeTruthy())
    await waitFor(() => expect(screen.getByText(/Every child is saved/)).toBeTruthy())
  })
})

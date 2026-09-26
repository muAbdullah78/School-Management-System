// @vitest-environment jsdom
/**
 * Step 5: every screen on a phone, and buttons that look like buttons.
 *
 * Each case is a fault the step found, pinned so it cannot come back:
 *
 *   * a row of module screens that read as a heading, not as buttons,
 *   * the same row scrolling "Pending 43" off a phone's edge,
 *   * a Reports and Settings rail of plain words,
 *   * soft buttons whose outline vanished, so an action read as a word,
 *   * "GR GR-0012" on every card of a school with a GR prefix,
 *   * chart tables six columns wide on a phone,
 *   * an enquiry list with no way to ring the parent from a phone.
 */
import { afterEach, describe, expect, it, vi } from 'vitest'
import { createElement, type ReactElement } from 'react'
import { cleanup, render, screen, within } from '@testing-library/react'
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

const { TabBar } = await import('@/components/TabBar')
const { SectionLayout } = await import('@/components/SectionLayout')
const { MiniTable, ChartCard } = await import('@/components/viz')
const { buttonClass } = await import('@/components/ui')
const { grLabel } = await import('@/lib/format')
const { EnquiriesPage } = await import('@/pages/admissions/EnquiriesPage')

const OWNER: Profile = {
  id: '11111111-1111-1111-1111-111111111111', full_name: 'Owner', role: 'owner',
  staff_id: null, school_id: '22222222-2222-2222-2222-222222222222',
}

function open(node: ReactElement, opts: FakeOptions = {}, path = '/') {
  current.opts = opts
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false, gcTime: 0 } } })
  const auth = {
    session: { user: { id: OWNER.id, email: 'x@example.test' } } as never,
    profile: OWNER, loading: false,
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

describe('the row of module screens', () => {
  it('each screen is a filled pill, the open one solid, and the row wraps instead of hiding any', () => {
    render(createElement(TabBar, {
      label: 'Fees', value: 'pending', onChange: () => {},
      tabs: [
        { key: 'collect', label: 'Collect' }, { key: 'bulk', label: 'Bulk collect' },
        { key: 'pending', label: 'Pending', count: 43 }, { key: 'deposits', label: 'Deposits' },
      ],
    }))
    const nav = screen.getByRole('navigation', { name: 'Fees' })
    expect(nav.className).toContain('flex-wrap')
    const open = screen.getByRole('button', { name: /Pending/ })
    expect(open.getAttribute('aria-current')).toBe('page')
    expect(open.className).toContain('bg-brand-600')
    const other = screen.getByRole('button', { name: 'Deposits' })
    expect(other.className).toMatch(/rounded-full/)
    expect(other.className).toMatch(/ring-1/)
    expect(other.className).toContain('bg-white')
  })
})

describe('the Reports and Settings rail', () => {
  it('is a menu of full-width button rows in cards, the open one solid', () => {
    open(createElement(SectionLayout, {
      label: 'Report', value: 'b', onChange: () => {},
      groups: [{ title: 'Money in', items: [{ key: 'a', label: 'Fee collection' }, { key: 'b', label: 'Day book' }] }],
      children: createElement('p', null, 'body'),
    } as never))
    const rail = screen.getByRole('navigation', { name: 'Report' })
    const on = within(rail).getByRole('button', { name: /Day book/ })
    expect(on.getAttribute('aria-current')).toBe('page')
    expect(on.className).toContain('bg-brand-600')
    expect(within(rail).getByRole('button', { name: /Fee collection/ }).className).toMatch(/hover:bg-brand-50/)
  })
})

describe('soft buttons', () => {
  it('carry an outline strong enough to read as a button', () => {
    const c = buttonClass({ variant: 'soft', size: 'sm' })
    expect(c).toContain('ring-1')
    expect(c).toContain('ring-brand-200')
    expect(c).toContain('rounded-lg')
  })
})

describe('a GR number', () => {
  it('gets the word GR only when the school has no prefix of its own', () => {
    expect(grLabel('1204')).toBe('GR 1204')
    expect(grLabel('GR-0012')).toBe('GR-0012')
    expect(grLabel('AQ/12')).toBe('AQ/12')
    expect(grLabel(null)).toBe('')
    expect(grLabel('  ')).toBe('')
  })
})

describe('a chart’s table on a phone', () => {
  it('is drawn as one small card per row as well as the table, each value with its column name', () => {
    render(createElement(MiniTable, {
      head: ['Month', 'Billed', 'Paid'], align: ['l', 'r', 'r'],
      rows: [['September', 'Rs 846,000', 'Rs 512,500']],
    }))
    const cards = screen.getAllByRole('list')[0]
    expect(within(cards).getByText('September')).toBeTruthy()
    expect(within(cards).getByText('Billed')).toBeTruthy()
    expect(screen.getByRole('table')).toBeTruthy()
  })

  it('puts the title above the buttons on a phone, so two buttons cannot squeeze it', () => {
    render(createElement(ChartCard, {
      title: 'Where the dues are', action: createElement('a', { href: '#' }, 'See defaulters'),
      table: createElement('p', null, 't'), children: createElement('p', null, 'c'),
    }))
    const title = screen.getByRole('heading', { name: 'Where the dues are' })
    const header = title.parentElement!.parentElement!
    expect(header.className).toContain('flex-col')
    expect(header.className).toContain('sm:flex-row')
  })
})

describe('the enquiry worklist on a phone', () => {
  it('each enquiry card has a Call button that dials the parent', async () => {
    open(createElement(EnquiriesPage), {
      rpc: {
        fn_enquiry_summary: { open: 1, due_today: 0, overdue: 1, open_no_date: 0, this_month: 1, admitted: 0, lost: 0, decided: 0, conversion_rate: null },
        fn_enquiry_list: [{
          id: 'e1', enquiry_no: 101, child_name: 'Zara Imran', father_name: 'Imran Khan', phone: '0321-5551234',
          whatsapp: null, class_name: 'Class 3', class_wanted: null, session_name: null, source: 'walk_in',
          status: 'new', follow_up_on: '2026-09-20', days_overdue: 2, contacts: 0, last_contact_at: null,
          last_outcome: null, lost_reason: null, notes: null, created_at: '2026-09-15T09:00:00Z',
          created_by_name: 'Office', admitted_student_id: null, total_count: 1,
        }],
        fn_enquiry_sources: [],
      },
    }, '/enquiries')
    const call = await screen.findByRole('link', { name: 'Call' })
    expect(call.getAttribute('href')).toBe('tel:0321-5551234')
    expect(screen.getByText(/Showing 1 to 1 of 1/)).toBeTruthy()
  })
})

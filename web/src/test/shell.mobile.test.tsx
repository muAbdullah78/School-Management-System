// @vitest-environment jsdom
/**
 * The shell on a phone.
 *
 * WHY THIS FILE EXISTS. The sidebar shipped as `w-64 shrink-0` with no
 * breakpoint on it, which on a 390px phone left 134px for the register, the
 * cash drawer and every table in the product. Nothing in this repository could
 * have known: no test had ever mounted AppShell, and a layout bug of that size
 * is invisible to a typecheck.
 *
 * WHAT A jsdom TEST CAN AND CANNOT SAY HERE. It cannot say how anything looks:
 * there is no stylesheet and no layout, so `lg:hidden` does nothing and every
 * element reports zero size. What it can say is everything that is NOT the
 * pixels, and that turns out to be most of what makes a drawer either correct
 * or maddening: what it announces itself as, where focus goes and comes back
 * to, which keys close it, and whether it closes when it should. Those are the
 * parts that break silently. The pixels are checked in a browser.
 */
import { describe, expect, it, vi, afterEach, beforeEach } from 'vitest'
import { createElement } from 'react'
import { act, cleanup, fireEvent, render, waitFor, within } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { MemoryRouter, Route, Routes } from 'react-router-dom'
import { fakeSupabase, type FakeOptions } from './fakeSupabase'
import { AuthContext, type Profile } from '@/auth/AuthProvider'
import { DESKTOP_QUERY } from '@/hooks/useIsDesktop'

vi.mock('@/lib/config', async (importOriginal) => ({
  ...(await importOriginal<typeof import('@/lib/config')>()),
  isConfigured: true,
}))
const current: { opts: FakeOptions } = { opts: {} }
vi.mock('@/lib/supabase', () => ({
  get supabase() { return fakeSupabase(current.opts) },
  isConfigured: true,
  requireSupabase: () => fakeSupabase(current.opts),
}))

const OWNER: Profile = {
  id: '11111111-1111-1111-1111-111111111111',
  full_name: 'Test Owner', role: 'owner',
  staff_id: null, school_id: '22222222-2222-2222-2222-222222222222',
}

function authValue(profile: Profile | null) {
  return {
    session: { user: { id: profile?.id ?? 'x', email: 'owner@example.test' } } as never,
    profile, loading: false,
    signIn: async () => ({ error: null }),
    signOut: async () => {},
    sendReset: async () => ({ error: null }),
    setPassword: async () => ({ error: null }),
  }
}

/**
 * A window of a given width, as far as the shell can tell.
 *
 * jsdom does not implement matchMedia at all, which is why useIsDesktop has to
 * cope with its absence. Here it is supplied, because the whole point is to
 * mount the same component on both sides of the breakpoint.
 */
function setWindowWidth(desktop: boolean) {
  const lists = new Set<{ q: string; fns: Set<(e: unknown) => void>; matches: boolean }>()
  Object.defineProperty(window, 'matchMedia', {
    configurable: true,
    writable: true,
    value: (q: string) => {
      const entry = { q, fns: new Set<(e: unknown) => void>(), matches: desktop }
      lists.add(entry)
      return {
        media: q,
        get matches() { return entry.matches },
        addEventListener: (_: string, fn: (e: unknown) => void) => entry.fns.add(fn),
        removeEventListener: (_: string, fn: (e: unknown) => void) => entry.fns.delete(fn),
        addListener: (fn: (e: unknown) => void) => entry.fns.add(fn),
        removeListener: (fn: (e: unknown) => void) => entry.fns.delete(fn),
        onchange: null,
        dispatchEvent: () => false,
      }
    },
  })
  /** Cross the breakpoint the way a rotation or a window drag does. */
  return function resizeTo(nowDesktop: boolean) {
    act(() => {
      lists.forEach((e) => { e.matches = nowDesktop; e.fns.forEach((fn) => fn({ matches: nowDesktop })) })
    })
  }
}

async function mountShell() {
  const { AppShell } = await import('@/components/AppShell')
  const qc = new QueryClient({
    defaultOptions: { queries: { retry: false, gcTime: 0 }, mutations: { retry: false } },
  })
  const utils = render(
    createElement(MemoryRouter, { initialEntries: ['/'] },
      createElement(AuthContext.Provider, { value: authValue(OWNER) },
        createElement(QueryClientProvider, { client: qc },
          createElement(Routes, null,
            createElement(Route, {
              path: '/',
              element: createElement(AppShell),
              children: [
                createElement(Route, { key: 'i', index: true, element: createElement('div', null, 'HOME') }),
              ],
            }),
            createElement(Route, { path: '*', element: createElement(AppShell) }))))),
  )
  await waitFor(() => expect(qc.isFetching()).toBe(0), { timeout: 4000 })
  const drawer = () => utils.container.querySelector('#app-sidebar') as HTMLElement
  return { ...utils, drawer, qc }
}

beforeEach(() => { current.opts = {} })
afterEach(() => { cleanup(); vi.unstubAllGlobals() })

describe('the sidebar on a phone', () => {
  it('starts off canvas, out of the tab order, and announces itself as a dialog', async () => {
    setWindowWidth(false)
    const { drawer, getByLabelText } = await mountShell()
    const aside = drawer()
    expect(aside).toBeTruthy()
    // Off canvas AND invisible. The transform alone would leave every link in
    // it reachable by Tab and readable by a screen reader.
    expect(aside.className).toContain('-translate-x-full')
    expect(aside.className).toContain('invisible')
    expect(aside.className).not.toContain('visible translate-x-0')
    expect(aside.getAttribute('role')).toBe('dialog')
    expect(aside.getAttribute('aria-modal')).toBe('true')
    expect(getByLabelText('Open menu').getAttribute('aria-expanded')).toBe('false')
  })

  it('opens on the hamburger and puts focus on the way out', async () => {
    setWindowWidth(false)
    const { drawer, getByLabelText } = await mountShell()
    const opener = getByLabelText('Open menu')
    expect(opener.getAttribute('aria-controls')).toBe('app-sidebar')
    fireEvent.click(opener)
    await waitFor(() => expect(drawer().className).toContain('translate-x-0'))
    expect(drawer().className).not.toContain('invisible')
    expect(opener.getAttribute('aria-expanded')).toBe('true')
    // Focus lands on Close, not on the first module: the way out is the first
    // thing a thumb or a Tab key finds.
    expect(document.activeElement).toBe(getByLabelText('Close menu'))
  })

  it('closes on Escape and hands focus back to the button that opened it', async () => {
    setWindowWidth(false)
    const { drawer, getByLabelText } = await mountShell()
    const opener = getByLabelText('Open menu')
    fireEvent.click(opener)
    await waitFor(() => expect(document.activeElement).toBe(getByLabelText('Close menu')))
    fireEvent.keyDown(document, { key: 'Escape' })
    await waitFor(() => expect(drawer().className).toContain('invisible'))
    // Focus must not be left on an element that has just been hidden.
    expect(document.activeElement).toBe(opener)
  })

  it('closes on the close button and on the backdrop', async () => {
    setWindowWidth(false)
    const { drawer, getByLabelText, container } = await mountShell()
    fireEvent.click(getByLabelText('Open menu'))
    await waitFor(() => expect(drawer().className).toContain('translate-x-0'))
    fireEvent.click(getByLabelText('Close menu'))
    await waitFor(() => expect(drawer().className).toContain('invisible'))

    fireEvent.click(getByLabelText('Open menu'))
    await waitFor(() => expect(drawer().className).toContain('translate-x-0'))
    const backdrop = container.querySelector('[aria-hidden="true"]') as HTMLElement
    expect(backdrop.className).toContain('opacity-100')
    fireEvent.click(backdrop)
    await waitFor(() => expect(drawer().className).toContain('invisible'))
    // And the shut backdrop can never swallow a tap meant for the page.
    expect(backdrop.className).toContain('pointer-events-none')
  })

  it('closes when a module is tapped, including the one already open', async () => {
    setWindowWidth(false)
    const { drawer, getByLabelText } = await mountShell()
    fireEvent.click(getByLabelText('Open menu'))
    await waitFor(() => expect(drawer().className).toContain('translate-x-0'))
    // Dashboard is the current route, so navigating to it changes nothing and
    // the route effect never fires. Without the explicit close on the link the
    // drawer would sit there over the screen the user just asked for.
    const links = within(drawer()).getAllByRole('link')
    const dashboard = links.find((a) => a.getAttribute('href') === '/')
    expect(dashboard).toBeTruthy()
    fireEvent.click(dashboard!)
    await waitFor(() => expect(drawer().className).toContain('invisible'))
  })

  it('keeps Tab inside the drawer while it is open', async () => {
    setWindowWidth(false)
    const { drawer, getByLabelText } = await mountShell()
    fireEvent.click(getByLabelText('Open menu'))
    await waitFor(() => expect(drawer().className).toContain('translate-x-0'))
    const stops = Array.from(
      drawer().querySelectorAll<HTMLElement>('a[href],button:not([disabled]),input:not([disabled])'),
    )
    expect(stops.length).toBeGreaterThan(3)
    const first = stops[0]
    const last = stops[stops.length - 1]

    last.focus()
    fireEvent.keyDown(document, { key: 'Tab' })
    expect(document.activeElement).toBe(first)

    first.focus()
    fireEvent.keyDown(document, { key: 'Tab', shiftKey: true })
    expect(document.activeElement).toBe(last)
  })

  it('does not stay flagged open when the window grows into the desktop layout', async () => {
    const resizeTo = setWindowWidth(false)
    const { drawer, getByLabelText } = await mountShell()
    fireEvent.click(getByLabelText('Open menu'))
    await waitFor(() => expect(drawer().className).toContain('translate-x-0'))
    resizeTo(true)
    // On a desktop the sidebar is part of the page again, so the flag must be
    // cleared rather than left to ambush the user the next time they make the
    // window narrow.
    await waitFor(() => expect(drawer().getAttribute('role')).toBe(null))
    resizeTo(false)
    await waitFor(() => expect(drawer().className).toContain('invisible'))
  })
})

describe('the sidebar on a desktop', () => {
  it('is a plain landmark: no dialog, no trap, nothing to open', async () => {
    setWindowWidth(true)
    const { drawer, queryByLabelText } = await mountShell()
    const aside = drawer()
    expect(aside.getAttribute('role')).toBe(null)
    expect(aside.getAttribute('aria-modal')).toBe(null)
    expect(aside.className).toContain('lg:static')
    expect(aside.className).toContain('lg:w-64')
    expect(aside.className).toContain('lg:visible')
    expect(aside.className).toContain('lg:translate-x-0')
    // The hamburger and the close button are still in the markup -- they are
    // hidden by CSS, which is what keeps this one element instead of two --
    // but nothing on a desktop should ever need them.
    expect(queryByLabelText('Open menu')?.className).toContain('lg:hidden')
    expect(queryByLabelText('Close menu')?.className).toContain('lg:hidden')
  })

  it('agrees with the Tailwind breakpoint it is paired with', () => {
    // `lg` is 1024px. If one of these moves the other has to move with it, or
    // the sidebar becomes a dialog at a width where it is still part of the
    // page, or stops being one at a width where it is not.
    expect(DESKTOP_QUERY).toBe('(min-width: 1024px)')
  })
})

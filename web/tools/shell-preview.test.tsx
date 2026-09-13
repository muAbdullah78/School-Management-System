// @vitest-environment jsdom
/**
 * The application shell, at the three widths it is actually used at.
 *
 * NOT A UNIT TEST -- a rendering harness, like challan-preview. It asserts
 * nothing and writes files; src/test/shell.mobile.test.tsx is where the
 * behaviour is asserted. This one exists because behaviour is not the thing
 * that was wrong: the sidebar was 256 fixed pixels of a 390px phone, which is a
 * fact about LOOKING at it, and no assertion about markup would ever have said
 * so. The only way to know a layout is right is to look at it.
 *
 * jsdom rather than renderToStaticMarkup, and it is the only harness here that
 * needs it. The drawer's open state is React state, so a server render can only
 * ever produce the shut one -- which is the half that was already fine.
 *
 * Output: ../scratch/shell/{phone,phone-open,desktop}.html, each against the
 * real compiled stylesheet. Open one in a browser at the width in its name.
 *
 * Excluded from `npm test` by vitest's test.include; run with `npm run harness`.
 */
import { it, vi } from 'vitest'
import { createElement } from 'react'
import { render, fireEvent } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { MemoryRouter, Route, Routes } from 'react-router-dom'
import { mkdirSync, writeFileSync } from 'node:fs'
import { AppShell } from '../src/components/AppShell'
import { AuthContext, type Profile } from '../src/auth/AuthProvider'
import { builtCss } from './harness'

/* A name at the long end of what this market really has. The point of the
   picture is the case that used to be cut off, not the case that fitted. */
vi.mock('../src/hooks/useSchoolName', () => ({
  useSchoolName: () => 'Government Girls Higher Secondary School Chaklala',
}))

const OWNER: Profile = {
  id: '11111111-1111-1111-1111-111111111111',
  full_name: 'Nasreen Akhtar', role: 'owner',
  staff_id: null, school_id: '22222222-2222-2222-2222-222222222222',
}

const auth = {
  session: { user: { id: OWNER.id, email: 'owner@example.test' } } as never,
  profile: OWNER, loading: false,
  signIn: async () => ({ error: null }),
  signOut: async () => {},
  sendReset: async () => ({ error: null }),
  setPassword: async () => ({ error: null }),
}

/** What the shell asks the window, answered without a window. */
function pretendWidth(desktop: boolean) {
  Object.defineProperty(window, 'matchMedia', {
    configurable: true, writable: true,
    value: (media: string) => ({
      media, matches: desktop, onchange: null,
      addEventListener: () => {}, removeEventListener: () => {},
      addListener: () => {}, removeListener: () => {},
      dispatchEvent: () => false,
    }),
  })
}

/** A page with something on it, so the content area is not judged empty. */
function Screen() {
  return createElement('div', null,
    createElement('h1', { className: 'text-xl font-semibold text-slate-900' }, 'Fees'),
    createElement('p', { className: 'mt-1 text-sm text-slate-500' },
      'Every charge and every rupee taken, by class and by month.'),
    createElement('div', { className: 'mt-4 grid gap-3 sm:grid-cols-3' },
      ...['Billed this month', 'Collected', 'Outstanding'].map((t, i) =>
        createElement('div', {
          key: t,
          className: 'rounded-xl border border-slate-200 bg-white p-4 shadow-card',
        },
          createElement('p', { className: 'text-xs uppercase tracking-wide text-slate-500' }, t),
          createElement('p', { className: 'mt-1 text-2xl font-semibold tabular-nums text-slate-900' },
            ['Rs 412,500', 'Rs 331,000', 'Rs 81,500'][i]),
        ))),
    createElement('div', { className: 'mt-4 overflow-x-auto rounded-xl border border-slate-200 bg-white' },
      createElement('table', { className: 'w-full text-sm' },
        createElement('tbody', null,
          ...['Ayesha Khan', 'Bilal Ahmed', 'Fatima Noor'].map((n) =>
            createElement('tr', { key: n, className: 'border-b border-slate-100 last:border-0' },
              createElement('td', { className: 'px-3 py-2.5 text-slate-700' }, n),
              createElement('td', { className: 'px-3 py-2.5 text-slate-500' }, 'Class 5 / A'),
              createElement('td', { className: 'px-3 py-2.5 text-right tabular-nums text-slate-900' },
                'Rs 4,500'))))))) 
}

function shell() {
  const qc = new QueryClient({
    defaultOptions: { queries: { retry: false, staleTime: Infinity, gcTime: Infinity } },
  })
  return render(
    createElement(MemoryRouter, { initialEntries: ['/fees'] },
      createElement(AuthContext.Provider, { value: auth },
        createElement(QueryClientProvider, { client: qc },
          createElement(Routes, null,
            createElement(Route, {
              path: '/', element: createElement(AppShell),
              children: [createElement(Route, {
                key: 'f', path: 'fees', element: createElement(Screen),
              })],
            }))))),
  )
}

const OUT = '../scratch/shell'

function write(name: string, html: string, width: number) {
  mkdirSync(OUT, { recursive: true })
  writeFileSync(`${OUT}/${name}.html`,
    `<!doctype html><html><head><meta charset="utf-8">`
    + `<title>Shell at ${width}px</title>`
    + `<link rel="stylesheet" href="${builtCss(`${OUT}/${name}.html`)}">`
    // The app is a full-height flex column rooted at #root, so the harness has
    // to reproduce that or the shell renders with no height at all.
    + `<style>html,body,#root{height:100%;margin:0}`
    + `body{background:#f1f5f9;font-family:system-ui,sans-serif}</style>`
    + `</head><body><div id="root">${html}</div></body></html>`)
}

it('renders the shell on a phone, with the drawer shut', () => {
  pretendWidth(false)
  const { container, unmount } = shell()
  write('phone', container.innerHTML, 390)
  unmount()
})

it('renders the shell on a phone, with the drawer open', () => {
  pretendWidth(false)
  const { container, getByLabelText, unmount } = shell()
  fireEvent.click(getByLabelText('Open menu'))
  write('phone-open', container.innerHTML, 390)
  unmount()
})

it('renders the shell on a desktop, unchanged', () => {
  pretendWidth(true)
  const { container, unmount } = shell()
  write('desktop', container.innerHTML, 1280)
  unmount()
})

/**
 * Rendering any app component to a real HTML file, outside a browser.
 *
 * WHY THIS EXISTS
 *
 * The harnesses in this directory used to call components as plain functions —
 * `ChallanPrint({ ... }) as never` — which works only for a component that uses
 * no hooks. Migration 0057 added a school logo to every print surface, and
 * ChallanPrint began calling useSchoolLogo() → useQuery(). From that moment the
 * challan harness died with:
 *
 *   TypeError: Cannot read properties of null (reading 'useContext')
 *     ❯ useIsRestoring @tanstack/react-query/IsRestoringProvider
 *
 * and nobody found out, because these harnesses are deliberately excluded from
 * `npm test`. The artefact existed and nothing ran it — the same shape as
 * bundles stopping at 0039 and fn_reverse_other_income shipping with no caller.
 * A CI step now runs them after the build, so that cannot recur.
 *
 * Calling a component as a function was never right anyway: it skips the whole
 * React runtime, so context, hooks and error boundaries are all absent and the
 * harness diverges from what a browser actually renders — which defeats the
 * point of looking at it.
 *
 * WHAT IT DOES
 *
 * Renders real JSX through renderToStaticMarkup inside the providers the app
 * supplies at runtime, with the query cache PRE-SEEDED instead of fetched. There
 * is no Supabase client here and there must not be one: a harness that could
 * reach a database would render whatever happened to be in it, and a screenshot
 * of a real school's children is not something to generate by accident.
 */
import { createElement, type ReactElement } from 'react'
import { renderToStaticMarkup } from 'react-dom/server'
import { QueryClient, QueryClientProvider, type QueryKey } from '@tanstack/react-query'
import { MemoryRouter } from 'react-router-dom'
import { mkdirSync, writeFileSync, readdirSync } from 'node:fs'
import { AuthContext, type Profile } from '../src/auth/AuthProvider'

/**
 * A query result to put in the cache before rendering.
 *
 * Seeding rather than mocking the fetcher: useQuery reads a fresh cache entry
 * synchronously, so the first render already has the data and the markup is the
 * loaded state. A mocked fetcher would need a flush and would render the
 * skeleton — and a screenshot of a loading spinner is worth nothing.
 */
export type Seed = [QueryKey, unknown]

export function renderToHtml(node: ReactElement, seeds: Seed[] = []): string {
  const qc = new QueryClient({
    defaultOptions: {
      queries: {
        // No network exists here. Without these, an unseeded query retries three
        // times with backoff before settling, and every harness pays for it.
        retry: false,
        staleTime: Infinity,
        gcTime: Infinity,
      },
    },
  })
  for (const [key, value] of seeds) qc.setQueryData(key, value)

  // An unseeded query returns undefined, which every consumer in this codebase
  // already handles — useSchoolLogo returns null and SchoolMark sets the school
  // name in type instead. So "no seed" renders the honest no-logo letterhead
  // rather than crashing, which is also the commonest real case.
  return renderToStaticMarkup(
    createElement(QueryClientProvider, { client: qc }, node),
  )
}

/**
 * A signed-in session for the harness, with no Supabase client behind it.
 *
 * Every page calls useAuth(), which throws outside a provider — so a page
 * harness needs one. Rendering the real <AuthProvider> does not work: with no
 * client it settles on profile = null and every page renders its signed-out
 * state, which is not the state anybody wants a screenshot of.
 *
 * The four functions are no-ops that resolve. renderToStaticMarkup never fires an
 * event, so they are never called; they exist to satisfy the type rather than to
 * pretend anything works.
 */
function authValue(profile: Profile | null) {
  return {
    session: profile ? ({ user: { id: profile.id, email: 'demo@example.test' } } as never) : null,
    profile,
    loading: false,
    signIn: async () => ({ error: null }),
    signOut: async () => {},
    sendReset: async () => ({ error: null }),
    setPassword: async () => ({ error: null }),
  }
}

/**
 * Render a whole PAGE, not just a printable.
 *
 * Pages need three things the printables did not: a router (every one of them
 * uses Link or NavLink), a signed-in profile, and their queries seeded. All three
 * are here rather than repeated in each harness file.
 *
 * MemoryRouter, not BrowserRouter: there is no document.location worth speaking
 * of in renderToStaticMarkup, and `initialEntries` is how a page that reads the
 * current route renders the tab the screenshot is meant to show.
 */
export function renderPageToHtml(
  node: ReactElement,
  opts: { seeds?: Seed[]; profile?: Profile | null; route?: string } = {},
): string {
  const qc = new QueryClient({
    defaultOptions: { queries: { retry: false, staleTime: Infinity, gcTime: Infinity } },
  })
  for (const [key, value] of opts.seeds ?? []) qc.setQueryData(key, value)

  return renderToStaticMarkup(
    createElement(
      MemoryRouter,
      { initialEntries: [opts.route ?? '/'] },
      createElement(
        AuthContext.Provider,
        { value: authValue(opts.profile ?? null) },
        createElement(QueryClientProvider, { client: qc }, node),
      ),
    ),
  )
}

/** The built stylesheet, so the harness output looks like the real thing. */
export function builtCss(): string {
  const css = readdirSync('dist/assets').find((f) => f.endsWith('.css'))
  if (!css) {
    throw new Error(
      'web/dist/assets holds no .css — run `npm run build` first. The harnesses ' +
      'render against the REAL compiled Tailwind, because a layout checked ' +
      'against different CSS than the app ships is not checked at all.',
    )
  }
  return `../web/dist/assets/${css}`
}

/**
 * Write one HTML page holding several rendered cases, each under a caption.
 *
 * Captions matter: these files are read by a human deciding whether a layout is
 * right, and "the overdrawn school holding advance fees" tells them what they
 * are meant to be judging. An uncaptioned wall of tiles tells them nothing.
 */
export function writePage(
  outPath: string,
  cases: {
    caption?: string
    node: ReactElement
    seeds?: Seed[]
    /** Set to render as a signed-in PAGE: adds a router and an auth context. */
    profile?: Profile | null
    route?: string
  }[],
  opts: { bodyStyle?: string } = {},
): void {
  const body = cases
    .map(({ caption, node, seeds, profile, route }) => {
      const html = profile !== undefined || route !== undefined
        ? renderPageToHtml(node, { seeds, profile, route })
        : renderToHtml(node, seeds ?? [])
      if (!caption) return html
      return `
    <section style="margin:0 0 3rem">
      <p style="font:600 13px/1.5 system-ui;color:#64748b;border-bottom:1px solid #e2e8f0;padding-bottom:.4rem;margin-bottom:1rem">
        ${caption}
      </p>
      ${html}
    </section>`
    })
    .join('')

  mkdirSync(outPath.replace(/\/[^/]+$/, ''), { recursive: true })
  writeFileSync(
    outPath,
    `<!doctype html><html><head><meta charset="utf-8">
     <link rel="stylesheet" href="${builtCss()}">
     </head><body style="${opts.bodyStyle ?? 'background:#fff'}">${body}</body></html>`,
  )
}

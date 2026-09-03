/**
 * Does a cold start keep a signed-in clerk signed in?
 *
 * WHY THIS EXISTS. "The desktop app asks for my password every time I open it"
 * was a race between two effects in AuthProvider, and nothing in this project
 * could catch it: there is no jsdom in web/, and the rendering harness uses
 * renderToStaticMarkup, which fires no effects at all. So the bug shipped, and
 * it cost a school owner a password every single launch.
 *
 * src/auth/authGate.test.ts is the CI-level guard and plays the exact sequence
 * as a state machine. This is the end-to-end proof in a real browser, and it
 * was run against the broken code first: with the old AuthProvider a stored,
 * unexpired session landed on /login, and with the fix it lands in the app.
 *
 * NOT IN CI, on purpose. It needs Playwright and a Chromium download, which
 * web/ deliberately does not carry so that every CI install stays cheap. Run
 * it by hand when touching AuthProvider, ProtectedRoute, RedirectIfSignedIn or
 * the Supabase client options.
 *
 *   npm install --prefix scripts                       # once
 *   npx --prefix scripts playwright install chromium   # once
 *
 *   cd web && VITE_SUPABASE_URL=https://probe.supabase.co \
 *             VITE_SUPABASE_ANON_KEY=probe-anon-key-not-real npm run build
 *   python3 scripts/spa-server.py web/dist 8801 &
 *   node scripts/check-cold-start.mjs
 *
 * The Supabase host is unroutable and every call to it is answered by a route
 * handler, so nothing leaves the machine and no real project is touched. The
 * seeded session is a fake token with a future expiry, which is enough: the
 * client decides whether to restore from `expires_at` before it ever calls the
 * server.
 */
import { createRequire } from 'node:module'
const require = createRequire('/opt/node22/lib/node_modules/')
const { chromium } = require('playwright')

const ORIGIN = 'http://127.0.0.1:8801'
const FUTURE = Math.floor(Date.now() / 1000) + 3600
const SESSION = {
  access_token: 'fake.access.token',
  token_type: 'bearer',
  expires_in: 3600,
  expires_at: FUTURE,
  refresh_token: 'fake-refresh',
  user: {
    id: '11111111-1111-1111-1111-111111111111',
    aud: 'authenticated',
    role: 'authenticated',
    email: 'clerk@school.test',
    app_metadata: {},
    user_metadata: {},
    created_at: '2026-01-01T00:00:00Z',
  },
}
const PROFILE = {
  id: SESSION.user.id,
  full_name: 'Basha-Salamat',
  role: 'owner',
  staff_id: null,
  school_id: '22222222-2222-2222-2222-222222222222',
}

const browser = await chromium.launch()

async function run({ seed }) {
  const ctx = await browser.newContext({ viewport: { width: 1280, height: 900 } })
  // Every Supabase call answered locally, so nothing leaves the machine.
  await ctx.route('**probe.supabase.co/**', (route) => {
    const u = route.request().url()
    if (u.includes('/rest/v1/profiles')) {
      return route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify(PROFILE) })
    }
    if (u.includes('/auth/v1/token')) {
      return route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify(SESSION) })
    }
    if (u.includes('/auth/v1/user')) {
      return route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify(SESSION.user) })
    }
    return route.fulfill({ status: 200, contentType: 'application/json', body: '[]' })
  })

  const readKeys = []
  await ctx.addInitScript(
    ({ seed, session }) => {
      // Record which storage keys the client looks for, so a key-format change
      // in supabase-js shows up as a diagnosis instead of a mystery failure.
      const real = Storage.prototype.getItem
      Storage.prototype.getItem = function (k) {
        ;(window.__keys = window.__keys || []).push(k)
        return real.call(this, k)
      }
      if (seed) localStorage.setItem('sb-probe-auth-token', JSON.stringify(session))
    },
    { seed, session: SESSION },
  )

  const page = await ctx.newPage()
  await page.goto(ORIGIN + '/', { waitUntil: 'networkidle' })
  // Give any redirect time to happen. A redirect is the failure we are hunting,
  // so waiting is the point.
  await page.waitForTimeout(1500)
  const out = await page.evaluate(() => ({
    path: location.pathname,
    heading: (document.querySelector('h1') || {}).textContent || null,
    body: document.body.innerText.slice(0, 90).replace(/\n/g, ' | '),
    keys: (window.__keys || []).filter((k) => String(k).includes('auth-token')),
  }))
  readKeys.push(...out.keys)
  await ctx.close()
  return out
}

const withSession = await run({ seed: true })
const withoutSession = await run({ seed: false })

console.log('stored session present ->', JSON.stringify(withSession))
console.log('no stored session      ->', JSON.stringify(withoutSession))

let fails = 0
const ok = (label, cond, detail = '') => {
  if (!cond) fails++
  console.log(`${cond ? 'PASS' : 'FAIL'}  ${label}${detail ? '  ' + detail : ''}`)
}
ok('the client actually read the seeded key', withSession.keys.length > 0, withSession.keys.join(','))
ok('a stored session does NOT get redirected to /login', withSession.path !== '/login', withSession.path)
ok('a stored session lands in the app', withSession.path === '/', withSession.path)
ok('no stored session DOES reach /login', withoutSession.path === '/login', withoutSession.path)

await browser.close()
console.log(fails === 0 ? '\nCOLD START OK' : `\n${fails} FAILURES`)
process.exit(fails === 0 ? 0 : 1)

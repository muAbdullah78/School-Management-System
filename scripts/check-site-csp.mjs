/**
 * Load every page under the REAL response headers and prove nothing breaks.
 *
 * site/_headers ships a Content-Security-Policy with no 'unsafe-inline' in
 * script-src. That is worth having and it is also the kind of change that
 * breaks a site quietly: a blocked resource leaves no mark on the page, only a
 * line in a console nobody is watching. The specific worry is the JSON-LD in
 * every page's head. It sits in a <script> tag, so people assume script-src
 * applies to it; browsers do not execute application/ld+json and do not check
 * it, but "I believe browsers behave this way" is not a verification. So this
 * loads the pages through scripts/cf-server.py, which applies site/_headers,
 * and listens for securitypolicyviolation directly.
 *
 * It also checks the favicon end to end, which is the thing that was broken:
 * every icon URL is fetched and must answer 200, and the brand mark in the nav
 * must actually have pixels. A <link rel="icon"> pointing at a 404 looks
 * exactly like a working one in the HTML.
 *
 *   python3 scripts/cf-server.py site 8804 &
 *   node scripts/check-site-csp.mjs 8804
 */
import { createRequire } from 'node:module'
const require = createRequire('/opt/node22/lib/node_modules/')
const { chromium } = require('playwright')

const PORT = process.argv[2] || '8804'
const BASE = `http://127.0.0.1:${PORT}`
const PAGES = [
  '/', '/fee-management', '/attendance', '/exams-and-results', '/accounts',
  '/parent-portal', '/pricing', '/faq', '/contact', '/download', '/guides',
  '/guides/fee-challan-pakistan', '/guides/expected-vs-collected',
  '/guides/moving-from-paper-registers', '/reviews', '/404',
]

const fails = []
const fail = (m) => { fails.push(m); console.log(`  FAIL  ${m}`) }

const browser = await chromium.launch()
const ctx = await browser.newContext()

let checkedIcons = 0
let checkedSchema = 0

for (const path of PAGES) {
  const page = await ctx.newPage()
  const violations = []
  const consoleErrors = []

  page.on('console', (m) => {
    if (m.type() === 'error') consoleErrors.push(m.text())
  })
  page.on('pageerror', (e) => consoleErrors.push(`uncaught: ${e.message}`))
  // The authoritative signal. A CSP block fires this whether or not anything
  // reaches the console.
  await page.addInitScript(() => {
    window.__csp = []
    document.addEventListener('securitypolicyviolation', (e) => {
      window.__csp.push(`${e.violatedDirective} blocked ${e.blockedURI || '(inline)'}`)
    })
  })

  const res = await page.goto(BASE + path, { waitUntil: 'networkidle' })
  if (!res) { fail(`${path}: no response`); await page.close(); continue }

  // The header must actually be on the response we just loaded, or everything
  // below is testing a site with no policy at all.
  const csp = res.headers()['content-security-policy']
  if (!csp) fail(`${path}: served with no Content-Security-Policy`)
  else if (csp.includes("script-src 'self' 'unsafe-inline'"))
    fail(`${path}: script-src gives away 'unsafe-inline'`)

  violations.push(...(await page.evaluate(() => window.__csp || [])))
  for (const v of violations) fail(`${path}: CSP violation: ${v}`)
  for (const e of consoleErrors) fail(`${path}: console error: ${e}`)

  // --- the JSON-LD survived the policy and still parses in the DOM ---
  const blocks = await page.$$eval('script[type="application/ld+json"]', (ns) =>
    ns.map((n) => n.textContent)
  )
  if (blocks.length === 0) fail(`${path}: no JSON-LD in the rendered DOM`)
  for (const [i, b] of blocks.entries()) {
    try {
      const doc = JSON.parse(b)
      if (!doc['@context']) fail(`${path}: JSON-LD block ${i + 1} has no @context`)
      checkedSchema++
    } catch (e) {
      fail(`${path}: JSON-LD block ${i + 1} does not parse in the browser: ${e.message}`)
    }
  }

  // --- every icon URL answers 200 ---
  const iconHrefs = await page.$$eval(
    'link[rel~="icon"], link[rel="apple-touch-icon"], link[rel="manifest"]',
    (ns) => ns.map((n) => n.getAttribute('href'))
  )
  if (iconHrefs.length === 0) fail(`${path}: no icon or manifest links`)
  for (const href of iconHrefs) {
    if (href.startsWith('data:')) { fail(`${path}: icon href is a data: URI`); continue }
    const r = await ctx.request.get(BASE + href)
    if (r.status() !== 200) fail(`${path}: ${href} answers ${r.status()}`)
    else if ((await r.body()).length === 0) fail(`${path}: ${href} is empty`)
    else checkedIcons++
  }

  // --- the brand mark actually rendered ---
  const marks = await page.$$eval('.brand img', (ns) =>
    ns.map((n) => ({ src: n.getAttribute('src'), w: n.naturalWidth, h: n.naturalHeight }))
  )
  if (marks.length === 0) fail(`${path}: no brand mark in the nav or footer`)
  for (const m of marks) {
    if (!m.w || !m.h) fail(`${path}: brand mark ${m.src} did not load (${m.w}x${m.h})`)
  }

  await page.close()
}

// --- the handbook, separately ---
//
// guide.html is built by a different script and is the ONLY page that loads
// anything cross-origin: two stylesheets from fonts.googleapis.com and the font
// files behind them from fonts.gstatic.com. It is therefore the page most
// likely to be broken by a new CSP, and it is not in the list above because it
// has no nav, no brand mark and no structured data. Checked for the things it
// does have: no violations, and fonts that actually arrived.
{
  const page = await ctx.newPage()
  const consoleErrors = []
  // A request to Google Fonts can fail for two completely different reasons and
  // they must not be confused. If the CSP blocked it, a securitypolicyviolation
  // fires and Chromium reports the failure as blocked by the client, and that is
  // a real defect in the policy. If the network could not reach the host, no
  // violation fires and the failure is a connection error. This build runs
  // behind an egress proxy that does not allow fonts.googleapis.com, so the
  // second case happens here and must be reported as NOT VERIFIED rather than
  // quietly passed or falsely failed.
  const FONT_HOSTS = /^https:\/\/fonts\.(googleapis|gstatic)\.com\//
  let fontsUnreachable = null
  page.on('requestfailed', (r) => {
    const why = (r.failure() && r.failure().errorText) || ''
    if (FONT_HOSTS.test(r.url())) {
      if (/blocked/i.test(why)) fail(`/guide.html: ${r.url()} was blocked: ${why}`)
      else fontsUnreachable = why
    }
  })
  page.on('console', (m) => { if (m.type() === 'error') consoleErrors.push(m.text()) })
  page.on('pageerror', (e) => consoleErrors.push(`uncaught: ${e.message}`))
  await page.addInitScript(() => {
    window.__csp = []
    document.addEventListener('securitypolicyviolation', (e) => {
      window.__csp.push(`${e.violatedDirective} blocked ${e.blockedURI || '(inline)'}`)
    })
  })
  const res = await page.goto(BASE + '/guide.html', { waitUntil: 'networkidle' })
  if (!res || res.status() !== 200) {
    fail(`/guide.html: answered ${res ? res.status() : 'nothing'}`)
  } else {
    for (const v of await page.evaluate(() => window.__csp || [])) {
      fail(`/guide.html: CSP violation: ${v}`)
    }
    for (const e of consoleErrors) {
      // The console message for an unreachable host carries no URL, so it can
      // only be excused when a request to a font host really did fail at the
      // network layer. Anything else is still a failure.
      if (fontsUnreachable && /Failed to load resource/.test(e)) continue
      fail(`/guide.html: console error: ${e}`)
    }
    // document.fonts only reports a face as loaded if the file was fetched and
    // parsed, so this fails if font-src blocked fonts.gstatic.com.
    const loaded = await page.evaluate(() =>
      [...document.fonts].filter((f) => f.status === 'loaded').map((f) => f.family)
    )
    if (!loaded.some((f) => /Newsreader|Figtree/.test(f))) {
      if (fontsUnreachable) {
        console.log('  guide.html: NOT VERIFIED, fonts.googleapis.com is unreachable ' +
                    `from this machine (${fontsUnreachable}). The CSP did not block ` +
                    'it: no securitypolicyviolation fired. Re-run somewhere with ' +
                    'outbound access to confirm the fonts render.')
      } else {
        fail(`/guide.html: neither webfont loaded (got ${JSON.stringify(loaded)}) ` +
             'and the host was reachable. font-src or style-src is blocking Google Fonts.')
      }
    } else {
      console.log(`  guide.html: webfonts loaded (${[...new Set(loaded)].join(', ')})`)
    }
    // Its screenshots are data: URIs, which img-src has to allow explicitly.
    const broken = await page.$$eval('img', (ns) =>
      ns.filter((n) => !n.naturalWidth).map((n) => (n.getAttribute('src') || '').slice(0, 40))
    )
    for (const b of broken) fail(`/guide.html: image did not load: ${b}...`)
  }
  await page.close()
}

await browser.close()

if (fails.length) {
  console.log(`\n::error::${fails.length} problem(s) under the real response headers`)
  process.exit(1)
}
console.log(
  `${PAGES.length} pages under the real _headers: no CSP violations, no console errors, ` +
  `${checkedSchema} JSON-LD blocks parsed in the browser, ${checkedIcons} icon URLs answered 200, ` +
  `brand mark rendered on every page`
)

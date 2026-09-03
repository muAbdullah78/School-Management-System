/**
 * The live reviews list, and whether a review can attack the reader.
 *
 * WHY THIS TEST EXISTS. A review body is typed by a customer of ours and then
 * rendered in another school owner's browser. That is untrusted input on a
 * public page, and it is the one place on this site where a stored XSS would
 * be possible. wire.js builds nodes and assigns textContent rather than
 * concatenating HTML, and this proves it: the fixture body carries an
 * <img onerror> and a <script>, and both must appear as literal text.
 *
 * It also proves the live read replaces the snapshot baked in at build time,
 * so a school that posted a review yesterday sees it today without anybody
 * rebuilding the site.
 *
 * NOT IN CI: needs Playwright and a browser. Run it after touching wireReviews
 * in site/wire.js or the review markup in scripts/build-site.py.
 *
 *   python3 scripts/build-site.py
 *   python3 scripts/cf-server.py site 8803 &
 *   node scripts/check-reviews-live.mjs
 *
 * Every Supabase call is answered by a route handler, so nothing leaves the
 * machine and no real project is touched.
 */
import { createRequire } from 'node:module'
const require = createRequire('/opt/node22/lib/node_modules/')
const { chromium } = require('playwright')
const ORIGIN = 'http://127.0.0.1:8803'
const b = await chromium.launch()
let fails = 0
const ok = (l, c, d = '') => { if (!c) fails++; console.log(`${c ? 'PASS' : 'FAIL'}  ${l}${d ? '  ' + d : ''}`) }

// A review body carrying markup and a script. This is the case that matters:
// the body is typed by a customer, and a school must not be able to write a
// review that runs code in another school owner's browser.
const NASTY = '<img src=x onerror="window.__pwned=1">Great software <script>window.__pwned=1</script> really.'
const SUMMARY = [{ total: 2, average: '4.50', five: 1, four: 1, three: 0, two: 0, one: 0 }]
const LIST = [
  { id: 'a', rating: 5, title: 'Excellent <b>bold attempt</b>', body: NASTY,
    school_name: 'Al Noor Public School', city: 'Sahiwal', published_on: '2026-09-01' },
  { id: 'b', rating: 4, title: 'Good', body: 'Solid on fees, reports need work.',
    school_name: 'A school', city: 'Multan', published_on: '2026-08-20' },
]

const ctx = await b.newContext({ viewport: { width: 1280, height: 900 } })
// config.js is committed BLANK, and it is loaded before wire.js, so an
// injected window.SITE_CONFIG is clobbered by it. Serve a filled config
// instead, which is also what the real deployment does.
await ctx.route('**/config.js', (route) =>
  route.fulfill({
    status: 200,
    contentType: 'application/javascript',
    body: `window.SITE_CONFIG = {
      APP_URL: 'https://app.example.test',
      SUPABASE_URL: 'https://rev.supabase.co',
      SUPABASE_ANON_KEY: 'anon-not-real',
      CONTACT_PHONE: '+92 300 0000000',
      CONTACT_WHATSAPP: '923000000000',
      CONTACT_EMAIL: 'hello@example.test',
      SIGNUP_OPEN: true,
    }`,
  }))
await ctx.route('**rev.supabase.co/**', (route) => {
  const u = route.request().url()
  const body = u.includes('reviews_summary') ? SUMMARY
    : u.includes('reviews_public') ? LIST
    : []
  route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify(body) })
})
const page = await ctx.newPage()
const errs = []
page.on('pageerror', (e) => errs.push(String(e)))
await page.goto(ORIGIN + '/reviews', { waitUntil: 'networkidle' })
await page.waitForTimeout(600)

const r = await page.evaluate(() => ({
  pwned: !!window.__pwned,
  articles: document.querySelectorAll('#reviews-list .review').length,
  avg: (document.querySelector('.rsum__avg b') || {}).textContent,
  imgs: document.querySelectorAll('#reviews-list img').length,
  scripts: document.querySelectorAll('#reviews-list script').length,
  bolds: document.querySelectorAll('#reviews-list h3 b').length,
  // the nasty body must appear as literal text, tags and all
  bodyText: (document.querySelectorAll('#reviews-list .review p')[1] || {}).textContent || '',
  ratingText: (document.querySelector('#reviews-list .review__rating b') || {}).textContent,
  emptyGone: !document.body.innerText.includes('No reviews yet'),
}))

ok('the live list replaced the baked empty state', r.emptyGone)
ok('both live reviews rendered', r.articles === 2, String(r.articles))
ok('the live average is shown', r.avg === '4.50', String(r.avg))
ok('the rating is printed as text', r.ratingText === '5 out of 5', String(r.ratingText))
ok('NO script executed from a review body', r.pwned === false)
ok('no <img> was created from a review body', r.imgs === 0, String(r.imgs))
ok('no <script> was created from a review body', r.scripts === 0, String(r.scripts))
ok('no markup interpreted in a review title', r.bolds === 0, String(r.bolds))
ok('the body renders as literal text including its tags',
   r.bodyText.includes('<img src=x') && r.bodyText.includes('<script>'), r.bodyText.slice(0, 50))
ok('no page errors', errs.length === 0, errs.join(' | '))

await page.screenshot({ path: process.env.SP + '/reviews-live-1280.png', fullPage: false })
await ctx.close()
await b.close()
console.log(fails === 0 ? '\nLIVE REVIEWS SAFE' : `\n${fails} FAILURES`)
process.exit(fails ? 1 : 0)

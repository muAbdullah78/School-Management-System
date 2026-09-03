/**
 * Render every page of the site and audit it, at seven widths.
 *
 * WHAT IT CHECKS, per page per width: no horizontal page scroll, no text
 * clipped by a container that is not scrollable, no element hanging outside the
 * viewport, no stray text node wider than the screen (which is what a nested
 * HTML comment produces and what querySelectorAll cannot reach), no console
 * error, and every text colour composited against its real painted background
 * against the WCAG threshold for its size and weight.
 *
 * IT ALSO ASSERTS EACH URL IS A DIFFERENT PAGE, and that is not paranoia. The
 * first version of this used the SPA fallback server written for the app, which
 * serves index.html for any unknown path. So every one of the fifteen URLs
 * returned the HOME page, and it reported "ALL 15 PAGES CLEAN" having audited
 * one page fifteen times. scripts/cf-server.py models Cloudflare instead, and
 * the title check here means a fallback like that can never be mistaken for a
 * pass again.
 *
 * NOT IN CI: it needs Playwright and a Chromium download, which this project
 * deliberately keeps out of web/ so every CI install stays cheap. Run it after
 * touching site-src/ or styles.css.
 *
 *   npm install --prefix scripts                       # once
 *   npx --prefix scripts playwright install chromium   # once
 *
 *   python3 scripts/build-site.py
 *   python3 scripts/cf-server.py site 8803 &
 *   node scripts/check-site-render.mjs
 */
import { createRequire } from 'node:module'
const require = createRequire('/opt/node22/lib/node_modules/')
const { chromium } = require('playwright')
import { mkdirSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { dirname, resolve } from 'node:path'
// scratch/ is gitignored. Defaulting to it rather than to process.env.SP,
// which was unset when this ran from the repo root and created a directory
// literally named "undefined" full of screenshots, staged by git add -A.
const OUT = process.env.SP || resolve(dirname(fileURLToPath(import.meta.url)), '../scratch/site-render')
mkdirSync(OUT, { recursive: true })
const ORIGIN = 'http://127.0.0.1:8803'
const PAGES = ["/", "/fee-management", "/attendance", "/exams-and-results", "/accounts", "/parent-portal", "/pricing", "/faq", "/contact", "/download", "/guides", "/guides/fee-challan-pakistan", "/guides/expected-vs-collected", "/guides/moving-from-paper-registers", "/404"]
const browser = await chromium.launch()

const audit = () => {
  const lum = (c) => { const [r,g,b] = c.map((v)=>{v/=255; return v<=0.03928?v/12.92:((v+0.055)/1.055)**2.4}); return .2126*r+.7152*g+.0722*b }
  const parse = (s) => (s.match(/[\d.]+/g) || []).slice(0,3).map(Number)
  // Resolve the painted background: a gradient-only surface has a transparent
  // background-color, so walking past it lands on the page white and every
  // white heading on it reads as a 1:1 failure. Take the first colour out of
  // the gradient instead, which for a dark CTA is its darkest stop.
  const alphaOf = (str) => { const n = (str.match(/[\d.]+/g) || []).map(Number); return n.length > 3 ? n[3] : 1 }
  const composite = (fg, a, bg) => fg.map((v, i) => Math.round(a * v + (1 - a) * bg[i]))
  // Composites every semi-transparent layer, and takes the LIGHTEST stop of a
  // gradient rather than the first: a threshold has to hold at the worst point
  // on the surface, not on average. An 8 percent white fill over indigo read as
  // pure white until this composited, which reported real buttons as 1:1.
  const bgOf = (el) => {
    const layers = []
    let n = el
    while (n) {
      const s = getComputedStyle(n)
      const c = s.backgroundColor
      const a = alphaOf(c)
      if (a > 0) { layers.push({ rgb: parse(c), a }); if (a >= 0.999) break }
      if (s.backgroundImage && s.backgroundImage !== 'none') {
        const stops = s.backgroundImage.match(/rgba?\([^)]+\)/g)
        if (stops) {
          const lightest = stops.map(parse).sort((x, y) => (x[0]+x[1]+x[2]) - (y[0]+y[1]+y[2])).pop()
          layers.push({ rgb: lightest, a: 1 })
          break
        }
      }
      n = n.parentElement
    }
    let base = [255,255,255]
    for (let i = layers.length - 1; i >= 0; i--) base = composite(layers[i].rgb, layers[i].a, base)
    return base
  }
  // Anything inside a closed <details> is laid out by Chromium but hidden by
  // content-visibility, so its boxes are real and its clipping is not.
  const hiddenByDetails = (el) => !!el.closest('details:not([open]) > *:not(summary)')
  const offscreen = (el) => { const b = el.getBoundingClientRect(); return b.right < 0 || b.left > innerWidth + 2000 }
  const srOnly = (el) => !!el.closest('.sr, .sr-only, .skip')

  const low = [], clipped = [], over = []
  for (const el of document.querySelectorAll('*')) {
    if (hiddenByDetails(el) || srOnly(el) || offscreen(el)) continue
    const b = el.getBoundingClientRect()
    if (b.width > 0 && (b.right > innerWidth + 1 || b.left < -1)) {
      over.push(`${el.tagName}.${String(el.className).slice(0,34)} ${Math.round(b.left)}..${Math.round(b.right)}`)
    }
    if (el.children.length) continue
    const t = (el.textContent || '').trim(); if (!t) continue
    const s = getComputedStyle(el)
    if (s.display === 'none' || s.visibility === 'hidden') continue
    if (el.scrollWidth > el.clientWidth + 1 && !/auto|scroll/.test(s.overflowX)) {
      clipped.push(`${el.tagName} "${t.slice(0,22)}" ${el.scrollWidth}>${el.clientWidth}`)
    }
    const bg = bgOf(el)
    const fg = composite(parse(s.color), alphaOf(s.color), bg)
    const L1 = lum(fg), L2 = lum(bg)
    const ratio = (Math.max(L1,L2)+.05)/(Math.min(L1,L2)+.05)
    const px = parseFloat(s.fontSize), bold = parseInt(s.fontWeight,10) >= 700
    const need = px >= 24 || (bold && px >= 18.66) ? 3 : 4.5
    if (ratio < need) low.push(`"${t.slice(0,24)}" ${ratio.toFixed(2)}<${need} ${px}px/${s.fontWeight} ${s.color} on rgb(${bg})`)
  }
  // A stray text node with no element of its own, which is what a nested HTML
  // comment produces and what querySelectorAll cannot reach.
  const strays = []
  const walk = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT)
  for (let n = walk.nextNode(); n; n = walk.nextNode()) {
    if (!n.textContent.trim()) continue
    const p = n.parentElement
    if (!p || p.tagName === 'SCRIPT' || p.tagName === 'STYLE') continue
    if (srOnly(p) || hiddenByDetails(p)) continue
    const r = document.createRange(); r.selectNode(n)
    const b = r.getBoundingClientRect()
    if (b.width > innerWidth + 1) strays.push(`${p.tagName}.${p.className}: "${n.textContent.trim().slice(0,40)}" w=${Math.round(b.width)}`)
  }
  return { scrollW: document.documentElement.scrollWidth, inner: innerWidth, low, clipped, over, strays }
}


let fails = 0
for (const w of [320, 360, 414, 768, 1024, 1280, 1440]) {
  const ctx = await browser.newContext({ viewport: { width: w, height: 900 } })
  const page = await ctx.newPage()
  let bad = 0
  const notes = []
  const titles = new Map()
  for (const path of PAGES) {
    const errs = []
    page.on('pageerror', (e) => errs.push(String(e)))
    const resp = await page.goto(ORIGIN + path, { waitUntil: 'networkidle' })
    if (!resp || resp.status() >= 400) { notes.push(`${path} HTTP ${resp && resp.status()}`); bad++; continue }
    await page.waitForTimeout(120)
    const seen = await page.title()
    if (titles.has(seen) && titles.get(seen) !== path) {
      notes.push(`${path} rendered the SAME page as ${titles.get(seen)} (title "${seen}")`)
      bad++
    }
    titles.set(seen, path)
    const r = await page.evaluate(audit)
    const n = r.low.length + r.clipped.length + r.over.length + r.strays.length + errs.length +
              (r.scrollW > r.inner + 1 ? 1 : 0)
    if (n) {
      bad += n
      notes.push(`${path}: scrollW=${r.scrollW}` +
        r.low.map((x) => `\n      low : ${x}`).join('') +
        r.clipped.map((x) => `\n      clip: ${x}`).join('') +
        r.over.map((x) => `\n      over: ${x}`).join('') +
        r.strays.map((x) => `\n      stray: ${x}`).join('') +
        errs.map((x) => `\n      err : ${x}`).join(''))
    }
    if (w === 1280 && ['/', '/fee-management', '/guides/expected-vs-collected'].includes(path)) {
      await page.screenshot({ path: `${OUT}/pg-${path.replace(/\//g, '_') || 'home'}-1280.png`, fullPage: true })
    }
  }
  fails += bad
  console.log(`${String(w).padStart(4)}px  ${PAGES.length} pages  ${bad === 0 ? 'clean' : 'FINDINGS ' + bad}`)
  notes.forEach((x) => console.log('   ', x))
  await ctx.close()
}
await browser.close()
console.log(fails === 0 ? '\nALL 15 PAGES CLEAN AT EVERY WIDTH' : `\n${fails} findings`)

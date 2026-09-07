/**
 * Render every page of the site and audit it, at seven widths.
 *
 * WHAT IT CHECKS, per page per width: no horizontal page scroll, no text
 * clipped by a container that is not scrollable, no element hanging outside the
 * viewport, no stray text node wider than the screen (which is what a nested
 * HTML comment produces and what querySelectorAll cannot reach), no console
 * error, every text colour composited against its real painted background
 * against the WCAG threshold for its size and weight, and that the header row
 * fits on one line with room to spare.
 *
 * THAT LAST ONE IS HERE BECAUSE EVERYTHING ELSE MISSED IT TWICE. A header that
 * wraps every label onto two lines inside a fixed-height bar clips nothing,
 * leaves nothing outside the viewport and scrolls no page sideways; neither
 * does one that overflows a centred wrap with 390px of blank page either side
 * of it. Both shipped. The assertions and their measurements are at the foot
 * of audit().
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
const PAGES = ["/", "/fee-management", "/attendance", "/exams-and-results", "/accounts", "/parent-portal", "/pricing", "/faq", "/contact", "/download", "/guides", "/guides/fee-challan-pakistan", "/guides/expected-vs-collected", "/guides/moving-from-paper-registers", "/reviews", "/404"]
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
    // aria-hidden text is DECORATION and is held to 1.4.11's 3:1 for a
    // graphical object rather than 1.4.3's 4.5:1 for text. That is the correct
    // reading, and it is not a free pass: something declared decorative still
    // has to be visible, or a five-star row is indistinguishable from a
    // three-star one. The reviews page prints "4 out of 5" in ink beside the
    // glyphs, so the rating itself is text and is measured as text.
    const decorative = !!el.closest('[aria-hidden="true"]')
    const need = decorative ? 3 : (px >= 24 || (bold && px >= 18.66) ? 3 : 4.5)
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
  // ---- THE HEADER ROW, WHICH IS ONE LINE OR IT IS BROKEN -------------------
  // Neither of the two ways this bar has failed was caught by anything above.
  //
  // First it WRAPPED. Adding a fourth and a fifth control put five items on
  // two lines each ("Parent sign / in", "Start free / trial") inside a 66px
  // bar. Nothing was clipped, nothing left the viewport and the page did not
  // scroll sideways, so every check in this file passed a header a school
  // reported as broken on sight.
  //
  // Then white-space:nowrap turned the wrap into an OVERFLOW: 1180px of
  // unbreakable content in 1092px of room, at every width including 1920,
  // because .wrap is capped and the shortfall therefore never closes. Still
  // invisible from outside: at 1920 there is 390px of empty page either side
  // of the wrap for it to spill into.
  //
  // So both are asserted here directly, and the slack floor is what makes the
  // NEXT label somebody adds fail before it ships rather than after.
  const nav = []
  const bar = document.querySelector('.nav__in')
  if (bar) {
    const shown = (el) => !!el && getComputedStyle(el).display !== 'none'
    const bs = getComputedStyle(bar)
    const kids = [...bar.children].filter(shown)
    const box = bar.getBoundingClientRect()
    const left = box.left + parseFloat(bs.paddingLeft)
    const right = box.right - parseFloat(bs.paddingRight)
    const gap = parseFloat(bs.columnGap) || 0
    const room = right - left
    // EXACT, and margin-agnostic: whatever the auto margins resolve to, no
    // child may end up past the inside edge of the bar.
    for (const el of kids) {
      const b = el.getBoundingClientRect()
      if (b.right > right + 1) nav.push(`.${String(el.className).split(' ')[0]} ends ${Math.round(b.right - right)}px past the bar`)
      if (b.left < left - 1) nav.push(`.${String(el.className).split(' ')[0]} starts ${Math.round(left - b.left)}px before the bar`)
    }
    // CONSERVATIVE, and the reason this file is worth editing: how much room
    // is left over. Sum of widths plus the gaps between them, which leaves out
    // the 10px margin that separates the CTA row from the section links, so
    // the floor has to cover it: 20px of true slack plus that margin.
    // 20 and not 0 because every width here is measured in Liberation Sans,
    // which carries Arial's metrics. Segoe UI, SF and Roboto all come out
    // narrower, so a real visitor has more room than this test does, but a
    // Linux desktop missing both Liberation and Arial lands on DejaVu Sans and
    // has 11% less. A row that fits by 2px does not fit.
    const need = kids.reduce((s, e) => s + e.getBoundingClientRect().width, 0) + gap * Math.max(0, kids.length - 1)
    const floor = shown(document.querySelector('.nav__links')) ? 30 : 0
    if (need > room - floor) {
      nav.push(`row needs ${Math.round(need)}px of ${Math.round(room)}px, under the ${floor}px floor`)
    }
    // NOTHING IN THE BAR TAKES TWO LINES. Range rects, one per line box, and
    // only on elements whose contents are a single text node: the Menu button
    // holds an icon beside its label, and two boxes at two different tops
    // would read as two lines.
    const lines = (el) => {
      if (![...el.childNodes].every((n) => n.nodeType === 3)) return 1
      const r = document.createRange()
      r.selectNodeContents(el)
      return new Set([...r.getClientRects()]
        .filter((b) => b.width > 0.5 && b.height > 0.5)
        .map((b) => Math.round(b.top))).size
    }
    const cta = document.querySelector('.nav__cta')
    const oneLine = [...document.querySelectorAll('.nav__links a, .nav__cta a')]
    // The brand name is the ONE label allowed a second line, and only at the
    // widths where it is the last thing left in the row beside the Menu
    // button. .nav__in is min-height so the bar grows to hold it.
    if (shown(document.querySelector('.nav__links')) || shown(cta)) {
      oneLine.push(document.querySelector('.brand span'))
    }
    for (const el of oneLine) {
      if (!shown(el) || hiddenByDetails(el)) continue
      const n = lines(el)
      if (n > 1) nav.push(`"${el.textContent.trim().slice(0, 26)}" is on ${n} lines`)
    }
  }

  return { scrollW: document.documentElement.scrollWidth, inner: innerWidth, low, clipped, over, strays, nav }
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
              r.nav.length + (r.scrollW > r.inner + 1 ? 1 : 0)
    if (n) {
      bad += n
      notes.push(`${path}: scrollW=${r.scrollW}` +
        r.low.map((x) => `\n      low : ${x}`).join('') +
        r.clipped.map((x) => `\n      clip: ${x}`).join('') +
        r.over.map((x) => `\n      over: ${x}`).join('') +
        r.strays.map((x) => `\n      stray: ${x}`).join('') +
        r.nav.map((x) => `\n      nav : ${x}`).join('') +
        errs.map((x) => `\n      err : ${x}`).join(''))
    }
    if (w === 1280 && ['/', '/fee-management', '/guides/expected-vs-collected', '/reviews'].includes(path)) {
      await page.screenshot({ path: `${OUT}/pg-${path.replace(/\//g, '_') || 'home'}-1280.png`, fullPage: true })
    }
  }
  fails += bad
  console.log(`${String(w).padStart(4)}px  ${PAGES.length} pages  ${bad === 0 ? 'clean' : 'FINDINGS ' + bad}`)
  notes.forEach((x) => console.log('   ', x))
  await ctx.close()
}
await browser.close()
console.log(fails === 0 ? `\nALL ${PAGES.length} PAGES CLEAN AT EVERY WIDTH` : `\n${fails} findings`)

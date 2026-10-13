/**
 * Render the Open Graph image, 1200x630, from HTML.
 *
 * WHY THE SITE NEEDS ONE. Every page declares og:image, and a page that
 * declares one is shown as a large card when somebody shares it on WhatsApp,
 * which in Pakistan is how a link actually travels between two school owners.
 * With no image the card is a line of grey text; with one it is the product.
 * The old site set twitter:card to "summary" precisely BECAUSE there was no
 * image, and a small card was the honest choice at the time.
 *
 * WHY IT IS GENERATED RATHER THAN DRAWN. The image carries the wordmark, the
 * palette and the type, so a hand-made PNG is a fourth copy of the brand that
 * drifts the first time any of the three changes. This renders the same tokens
 * the stylesheet uses, so a change to the palette is one edit.
 *
 *   npm install --prefix scripts                       # once
 *   npx --prefix scripts playwright install chromium   # once
 *   node scripts/build-og.mjs                          # writes site/og.png
 *
 * Not in CI: it needs a browser. The committed PNG is what ships, and
 * scripts/check-site-seo.py refuses a build whose og.png is missing.
 */
import { createRequire } from 'node:module'
import { fileURLToPath } from 'node:url'
import { dirname, resolve } from 'node:path'
import { readFileSync, writeFileSync, statSync } from 'node:fs'
import { crc32 } from 'node:zlib'

// The documented install is `npm install --prefix scripts`. A machine with
// Playwright installed globally instead (as the render checks assume) works
// too, rather than failing on the import.
let chromium
try {
  ;({ chromium } = await import('playwright'))
} catch {
  ;({ chromium } = createRequire('/opt/node22/lib/node_modules/')('playwright'))
}

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..')
const OUT = resolve(ROOT, 'site/og.png')

// THE PRICE ON THE CARD. It is the cheapest monthly price in public.plans, and
// supabase/check-site-prices.sh checks it twice: here in the source, and in
// the PNG itself, which carries this sentence in a text chunk (see below).
// The PNG check is the one that matters. The card once read "Rs 950 a month"
// for weeks after this file said Rs 2,000, because the source was edited and
// the image was never regenerated, and a guard reading only the source passed.
const FROM = 'Rs 2,000 a month'
const TRIAL = '14 days, no card'

// 1200x630 is the size Facebook, WhatsApp, LinkedIn and X all crop from, and
// the one Open Graph's own documentation gives. deviceScaleFactor 1: the spec
// wants 1200 actual pixels, and a 2x render is a 2400px file that every
// consumer downsamples anyway.
const HTML = `<!doctype html>
<meta charset="utf-8">
<style>
  * { box-sizing: border-box; margin: 0; }
  body {
    width: 1200px; height: 630px; display: flex; flex-direction: column;
    justify-content: space-between; padding: 68px 76px;
    font-family: "Segoe UI", system-ui, -apple-system, "Liberation Sans", Arial, sans-serif;
    background:
      radial-gradient(760px 420px at 88% -10%, #EEF2FF 0%, transparent 62%),
      radial-gradient(620px 360px at 4% 8%, #ECFEFF 0%, transparent 58%),
      #FFFFFF;
    color: #0F172A;
  }
  .brand { display: flex; align-items: center; gap: 14px; }
  .brand span { font-size: 27px; font-weight: 700; letter-spacing: -0.01em; }
  .eyebrow {
    display: flex; align-items: center; gap: 12px;
    font-size: 17px; font-weight: 700; letter-spacing: 0.1em;
    text-transform: uppercase; color: #0E7490; margin-bottom: 20px;
  }
  .eyebrow i { display: block; width: 30px; height: 3px; border-radius: 2px; background: #06B6D4; }
  h1 { font-size: 74px; line-height: 1.04; letter-spacing: -0.035em; font-weight: 700; max-width: 20ch; }
  h1 em { font-style: normal; color: #4F46E5; }
  .top { display: flex; align-items: center; justify-content: space-between; }
  .facts { display: flex; gap: 56px; align-items: flex-end; }
  /* nowrap: "Rs 2,000 a month" wrapped to two lines at 30px. The domain used
     to sit at the end of this row, and with a wider fallback face (DejaVu Sans,
     which is what a Linux machine without Segoe has) the row ran past the
     1048px content box and the domain was cut off at the right edge. It now
     sits opposite the brand, and the render below refuses any overflow. */
  .fact b { display: block; font-size: 30px; font-weight: 700; letter-spacing: -0.02em; white-space: nowrap; }
  .fact span { display: block; font-size: 15px; font-weight: 700; letter-spacing: 0.08em;
               text-transform: uppercase; color: #64748B; margin-bottom: 6px; }
  .dom { font-size: 21px; font-weight: 600; color: #475569; white-space: nowrap; }
</style>
<div class="top">
<div class="brand">
  <svg width="42" height="42" viewBox="0 0 24 24">
    <rect width="24" height="24" rx="6" fill="#4F46E5"/>
    <g fill="#fff"><circle cx="12" cy="7.5" r="1.4"/><path fill-rule="evenodd" d="M5.5 12.5h13v6h-13zm2.5 1.5h8v1h-8zm0 2h8v1h-8z"/></g>
  </svg>
  <span>The School Manager</span>
</div>
<div class="dom">theschoolmanager.site</div>
</div>
<div>
  <p class="eyebrow"><i></i>Built for Pakistani schools</p>
  <h1>One parent. One payment. <em>One receipt.</em></h1>
</div>
<div class="facts">
  <div class="fact"><span>From</span><b>${FROM}</b></div>
  <div class="fact"><span>Trial</span><b>${TRIAL}</b></div>
  <div class="fact"><span>Modules</span><b>All included</b></div>
</div>
`

const browser = await chromium.launch()
const page = await browser.newPage({
  viewport: { width: 1200, height: 630 },
  deviceScaleFactor: 1,
})
await page.setContent(HTML, { waitUntil: 'load' })
// Nothing may run past the 76px right margin. The share card is cropped by
// nobody, so a clipped domain ships exactly as rendered.
const overflow = await page.evaluate(() => {
  const limit = 1200 - 76 + 1
  return [...document.querySelectorAll('.brand, h1, .fact, .dom')]
    .filter((el) => el.getBoundingClientRect().right > limit)
    .map((el) => el.textContent.trim())
})
if (overflow.length) {
  console.error(`REFUSING: these run past the right margin: ${overflow.join(' | ')}`)
  await browser.close()
  process.exit(1)
}
const png = await page.screenshot({ type: 'png' })
await browser.close()

// A tEXt chunk saying what the picture says, written just before IEND. A
// guard cannot read pixels, but it can read this, and because the same
// constants render the card and fill the chunk, the two cannot disagree. tEXt
// is uncompressed Latin-1, so `grep -a` finds it.
function textChunk(keyword, text) {
  const data = Buffer.from(`${keyword}\0${text}`, 'latin1')
  const type = Buffer.from('tEXt', 'latin1')
  const len = Buffer.alloc(4)
  len.writeUInt32BE(data.length)
  const crc = Buffer.alloc(4)
  crc.writeUInt32BE(crc32(Buffer.concat([type, data])) >>> 0)
  return Buffer.concat([len, type, data, crc])
}
const iend = png.length - 12
if (png.toString('latin1', iend + 4, iend + 8) !== 'IEND') {
  console.error('REFUSING: the screenshot does not end in an IEND chunk')
  process.exit(1)
}
writeFileSync(OUT, Buffer.concat([
  png.subarray(0, iend),
  textChunk('Description', `The School Manager. From ${FROM}. Trial ${TRIAL}. All modules included.`),
  png.subarray(iend),
]))
if (!readFileSync(OUT).includes(`From ${FROM}.`)) {
  console.error('REFUSING: the price sentence did not land in site/og.png')
  process.exit(1)
}

const kb = Math.round(statSync(OUT).size / 1024)
console.log(`wrote site/og.png: 1200x630, ${kb} KB`)
if (kb > 300) {
  console.error(`REFUSING: ${kb} KB is too heavy for a share card. Simplify the design.`)
  process.exit(1)
}

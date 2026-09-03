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
import { chromium } from 'playwright'
import { fileURLToPath } from 'node:url'
import { dirname, resolve } from 'node:path'
import { statSync } from 'node:fs'

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..')
const OUT = resolve(ROOT, 'site/og.png')

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
  .facts { display: flex; gap: 44px; align-items: flex-end; }
  /* nowrap: "Rs 950 a month" wrapped to two lines at 30px and pushed the
     domain out of alignment. The three facts plus the domain measure 958px
     inside a 1048px content box, so they fit on one line each. */
  .fact b { display: block; font-size: 30px; font-weight: 700; letter-spacing: -0.02em; white-space: nowrap; }
  .fact span { display: block; font-size: 15px; font-weight: 700; letter-spacing: 0.08em;
               text-transform: uppercase; color: #64748B; margin-bottom: 6px; }
  .dom { margin-left: auto; font-size: 21px; font-weight: 600; color: #475569; }
</style>
<div class="brand">
  <svg width="42" height="42" viewBox="0 0 24 24">
    <rect width="24" height="24" rx="6" fill="#4F46E5"/>
    <g fill="#fff"><circle cx="12" cy="7.5" r="1.4"/><path fill-rule="evenodd" d="M5.5 12.5h13v6h-13zm2.5 1.5h8v1h-8zm0 2h8v1h-8z"/></g>
  </svg>
  <span>The School Manager</span>
</div>
<div>
  <p class="eyebrow"><i></i>Built for Pakistani schools</p>
  <h1>One parent. One payment. <em>One receipt.</em></h1>
</div>
<div class="facts">
  <div class="fact"><span>From</span><b>Rs 950 a month</b></div>
  <div class="fact"><span>Trial</span><b>14 days, no card</b></div>
  <div class="fact"><span>Modules</span><b>All included</b></div>
  <div class="dom">theschoolmanager.site</div>
</div>
`

const browser = await chromium.launch()
const page = await browser.newPage({
  viewport: { width: 1200, height: 630 },
  deviceScaleFactor: 1,
})
await page.setContent(HTML, { waitUntil: 'load' })
await page.screenshot({ path: OUT, type: 'png' })
await browser.close()

const kb = Math.round(statSync(OUT).size / 1024)
console.log(`wrote site/og.png: 1200x630, ${kb} KB`)
if (kb > 300) {
  console.error(`REFUSING: ${kb} KB is too heavy for a share card. Simplify the design.`)
  process.exit(1)
}

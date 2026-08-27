/**
 * Photograph each screen rendered by web/tools/guide-shots.test.tsx.
 *
 * Needs Playwright, which lives in scripts/ and NOT in web/: it is used only to
 * build the guide, and putting a ~100MB browser download in the app's package
 * would make every CI install pay for it.
 *
 *     npm install --prefix scripts        # once
 *     npx --prefix scripts playwright install chromium   # once
 *     node scripts/shot-guide.mjs
 *
 * Set PLAYWRIGHT_CHROMIUM to an existing Chromium binary to skip that download.
 *
 * deviceScaleFactor 1.5 rather than 2: the guide embeds these as data URIs and
 * has a 16MB ceiling, and at 2x a single portal screen is 300KB before base64
 * inflates it by a third. 1.5 still reads crisply on a phone and in print.
 *
 * Phone width for the screens a parent or teacher uses on a phone; desktop width
 * for the office screens. Getting that the wrong way round would show a school a
 * layout it will never see.
 */
import { chromium } from 'playwright'
import { readdirSync, mkdirSync, statSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { dirname, resolve } from 'node:path'

// Relative to this file, so the script works from any working directory and on
// anybody's machine. Absolute paths are how a build step becomes "works on the
// computer it was written on".
const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..')
const SRC = resolve(ROOT, 'scratch/guide')
const OUT = resolve(ROOT, 'scratch/guide-img')
mkdirSync(OUT, { recursive: true })

// Which width each screen is actually used at.
const PHONE = new Set(['portal-fees', 'portal-attendance', 'portal-results', 'login', 'forgot'])

// Some screens are DIALOGS. Shooting the page gives a mostly-grey image of the
// modal backdrop with the document floating in the middle of it — which is what
// the user sees, but not what belongs in a manual next to a caption about the
// document. These are cropped to the document itself.
const CLIP = { 'receipt-family': '#receipt' }

// PLAYWRIGHT_CHROMIUM if the browser is somewhere unusual; otherwise Playwright's
// own resolution, which is right on a machine where `npx playwright install` ran.
const b = await chromium.launch(
  process.env.PLAYWRIGHT_CHROMIUM ? { executablePath: process.env.PLAYWRIGHT_CHROMIUM } : {},
)
let total = 0
for (const f of readdirSync(SRC).filter((x) => x.endsWith('.html')).sort()) {
  const name = f.replace(/\.html$/, '')
  const width = PHONE.has(name) ? 400 : 900
  const p = await b.newPage({ viewport: { width, height: 900 }, deviceScaleFactor: 1.5 })
  await p.goto(`file://${SRC}/${f}`)
  await p.waitForTimeout(250)
  const out = `${OUT}/${name}.png`
  if (CLIP[name]) {
    await p.locator(CLIP[name]).screenshot({ path: out })
  } else {
    // fullPage, so a tall screen is captured whole rather than cut at 900px — a
    // screenshot that stops mid-table is worse than none in a step-by-step guide.
    await p.screenshot({ path: out, fullPage: true })
  }
  const kb = Math.round(statSync(out).size / 1024)
  total += kb
  console.log(`${name.padEnd(20)} ${String(width).padStart(4)}px  ${String(kb).padStart(4)} KB`)
  await p.close()
}
await b.close()
console.log(`total ${total} KB (base64 adds about a third)`)

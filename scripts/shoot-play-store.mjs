// The Google Play store art: phone screenshots, the 512px icon and the
// 1024x500 feature graphic, all from the app itself and its one mark.
//
//   cd web && npx vite --config vite.live.config.ts     (the live preview)
//   node scripts/shoot-play-store.mjs                    (in another terminal)
//
// Writes mobile/store/. The screenshots are the real screens on the live
// preview's invented school, inside the app's own frame at phone size, and
// rendered AS THE ANDROID APP (window.Capacitor present), so they show what the
// app shows: no prices, no bank details, the in-app subscription wording.
// Google asks for JPEG or PNG without transparency, 9:16 at 1080x1920 here.
import { createRequire } from 'node:module'
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { dirname, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const require = createRequire(import.meta.url)
let chromium
try { ({ chromium } = require('playwright')) } catch {
  ({ chromium } = createRequire('/opt/node22/lib/node_modules/')('playwright'))
}

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..')
const OUT = resolve(ROOT, 'mobile/store')
const BASE = process.env.LIVE_URL ?? 'http://127.0.0.1:5199/'
const svg = readFileSync(resolve(ROOT, 'site-src/icon.svg'), 'utf8')
const PLATE = svg.match(/id="plate"[^>]*fill="(#[0-9A-Fa-f]{6})"/)[1]
mkdirSync(resolve(OUT, 'screenshots'), { recursive: true })

// The order Google shows them in: what a school does every day first. The third
// field draws the app's own frame around the screen; the parent portal has its
// own layout and no staff frame.
const SHOTS = [
  ['teacher-home', '1-a-teachers-day', true],
  ['attendance-mark', '2-the-register', true],
  ['attendance', '3-the-whole-school-today', true],
  ['fees-pending', '4-fees', true],
  ['exams2-marks-grid', '5-marks-and-results', true],
  ['portal', '6-the-parent-portal', false],
]

const browser = await chromium.launch()

for (const [scene, name, shell] of SHOTS) {
  const page = await browser.newPage({ viewport: { width: 360, height: 640 }, deviceScaleFactor: 3 })
  await page.addInitScript(() => { window.Capacitor = { isNativePlatform: () => true } })
  await page.goto(`${BASE}?scene=${scene}${shell ? '&shell=1' : ''}`, { waitUntil: 'networkidle' })
  await page.waitForTimeout(1200)
  const text = await page.evaluate(() => document.body.innerText)
  if (/No scene called/.test(text)) throw new Error(`the live preview has no scene called ${scene}`)
  // A screen the preview has not seeded, or one this role may not see, is not
  // something to show Google.
  if (/is not seeded|Not permitted|No session set/.test(text)) throw new Error(`${scene} is not ready to photograph`)
  // The app must never show a way to pay inside it (Google Play's rules).
  if (/bank details|I have paid|\bRs\.? ?[0-9,]+ (a|per) (month|year)/i.test(text)) {
    throw new Error(`${scene} shows payment details, which the Android app must not`)
  }
  const file = resolve(OUT, 'screenshots', `${name}.jpg`)
  await page.screenshot({ path: file, type: 'jpeg', quality: 90 })
  console.log(`  mobile/store/screenshots/${name}.jpg`)
  await page.close()
}

// The store icon: Google rounds the corners itself, so the plate is square.
{
  const page = await browser.newPage({ viewport: { width: 512, height: 512 } })
  await page.setContent(`<style>html,body{margin:0}svg{display:block;width:512px;height:512px}</style>${svg}`)
  await page.evaluate(() => document.getElementById('plate').setAttribute('rx', '0'))
  writeFileSync(resolve(OUT, 'icon-512.png'), await page.screenshot())
  console.log('  mobile/store/icon-512.png')
  await page.close()
}

// The feature graphic: the mark and the name on the plate's colour. Google may
// crop its edges and lay its own play button over the middle, so the words sit
// left of centre and nothing matters near the border.
{
  const page = await browser.newPage({ viewport: { width: 1024, height: 500 } })
  await page.setContent(`<!doctype html><style>
    html,body{margin:0;width:1024px;height:500px;background:${PLATE};font-family:Inter,'Segoe UI',Roboto,Arial,sans-serif}
    .row{display:flex;align-items:center;gap:36px;height:100%;padding:0 88px;box-sizing:border-box}
    svg{width:150px;height:150px;flex:none}
    h1{margin:0;color:#fff;font-size:58px;font-weight:700;letter-spacing:-0.02em;line-height:1.05}
    p{margin:14px 0 0;color:#E0E7FF;font-size:27px;line-height:1.3;max-width:600px}
  </style><div class="row">${svg}<div><h1>The School Manager</h1>
  <p>Fees, attendance and results for Pakistani schools. Keeps working when the internet does not.</p></div></div>`)
  writeFileSync(resolve(OUT, 'feature-graphic.png'), await page.screenshot())
  console.log('  mobile/store/feature-graphic.png')
  await page.close()
}

await browser.close()

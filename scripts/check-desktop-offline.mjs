#!/usr/bin/env node
// The Windows program's connect screen (desktop/ui/index.html) decides, at every
// launch, whether to open the app. This drives it in Chromium and checks each
// decision. Needs Playwright, so it is run by hand, like check-blank-page.mjs:
//
//   node scripts/check-desktop-offline.mjs
//
// "Offline" is the probe failing: a fetch that never answers, which is what a
// pulled cable and a connection with no internet behind it both look like.
import { createRequire } from 'node:module'
import { resolve, dirname } from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'

const require = createRequire(import.meta.url)
let chromium
try { ({ chromium } = require('playwright')) } catch {
  ({ chromium } = createRequire('/opt/node22/lib/node_modules/')('playwright'))
}

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..')
const SCREEN = pathToFileURL(resolve(ROOT, 'desktop/ui/index.html')).href
const HOSTED = 'https://app.theschoolmanager.site'

async function launch(browser, { saved, answered, online, pressChange = false }) {
  const page = await browser.newPage()
  const opened = []
  await page.route('https://**/*', (route) => {
    const r = route.request()
    if (r.resourceType() === 'document') {
      opened.push(r.url().replace(/\/$/, ''))
      return route.fulfill({ status: 200, contentType: 'text/html', body: '<p>the app</p>' })
    }
    return online ? route.fulfill({ status: 200, body: '' }) : route.abort('internetdisconnected')
  })
  // Seed what an earlier launch would have left, then launch for real.
  await page.goto(SCREEN + '#seed')
  await page.evaluate(({ saved, answered }) => {
    localStorage.clear()
    if (saved) localStorage.setItem('school_manager_app_url', saved)
    if (answered) localStorage.setItem('school_manager_app_ok', answered)
  }, { saved, answered })
  await page.goto('about:blank')
  await page.goto(SCREEN)
  if (pressChange) {
    await page.waitForSelector('#change', { state: 'visible' })
    await page.waitForFunction(() => document.getElementById('splashHead')?.textContent === 'Working offline')
    await page.click('#change')
  }
  await page.waitForTimeout(4000)
  const state = opened.length ? { opened } : await page.evaluate(() => ({
    setup: getComputedStyle(document.getElementById('setup')).display !== 'none',
    error: document.getElementById('err').textContent,
    answered: localStorage.getItem('school_manager_app_ok'),
  }))
  await page.close()
  return state
}

const cases = [
  ['offline, the hosted address: opens the copy on this computer',
    { saved: HOSTED, online: false }, (s) => s.opened?.[0] === HOSTED],
  ['offline, a school address that has answered before: opens it',
    { saved: 'https://sms.myschool.example', answered: 'https://sms.myschool.example', online: false },
    (s) => s.opened?.[0] === 'https://sms.myschool.example'],
  ['a typo that has never answered: back to the connect screen with the reason',
    { saved: 'https://app.theschoolmanger.site', online: false },
    (s) => !s.opened && s.setup && /Nothing answered/.test(s.error)],
  ['offline, Change address pressed while it waits: stays on the connect screen',
    { saved: HOSTED, online: false, pressChange: true }, (s) => !s.opened && s.setup],
  ['online, a new school address: opens it',
    { saved: 'https://sms.myschool.example', online: true },
    (s) => s.opened?.[0] === 'https://sms.myschool.example'],
]

const browser = await chromium.launch()
let failed = 0
for (const [name, setup, ok] of cases) {
  const state = await launch(browser, setup)
  const pass = ok(state)
  if (!pass) failed++
  console.log(`${pass ? 'PASS' : 'FAIL'}  ${name}${pass ? '' : `  ${JSON.stringify(state)}`}`)
}
await browser.close()
if (failed) {
  console.error(`::error::${failed} connect-screen case(s) failed`)
  process.exit(1)
}
console.log(`desktop connect screen: ${cases.length} launch cases behave`)

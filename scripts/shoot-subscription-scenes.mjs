// Screenshots of the subscription scenes in the live preview (tools/live).
// Usage: node scripts/shoot-subscription-scenes.mjs [filter]
import { chromium } from 'playwright'
import { mkdirSync } from 'node:fs'

const OUT = process.env.SHOTS_DIR
  ?? '/tmp/claude-0/-home-user-School-Management-System/d1c8a368-6bf2-51aa-abe5-0ae6802edec6/scratchpad/subshots'
const BASE = 'http://127.0.0.1:5199/'
mkdirSync(OUT, { recursive: true })

// Make fixed overlays part of the page, so a full-page shot holds all of a
// drawer or dialog rather than the first screenful of it.
async function unclip(page) {
  await page.evaluate(() => {
    for (const el of document.querySelectorAll('*')) {
      const cs = getComputedStyle(el)
      if (cs.position === 'fixed') {
        el.style.position = 'absolute'
        el.style.minHeight = '100%'
        el.style.height = 'auto'
        el.style.bottom = 'auto'
      }
      if ((cs.overflowY === 'auto' || cs.overflowY === 'scroll') && el !== document.documentElement && el !== document.body) {
        el.style.overflowY = 'visible'
        el.style.maxHeight = 'none'
      }
      if (cs.height && el.classList.contains('h-full')) el.style.height = 'auto'
    }
  })
}

const settle = (page, ms = 500) => page.waitForTimeout(ms)
const click = async (page, sel) => { await page.locator(sel).first().click(); await settle(page) }
const role = async (page, name, r = 'button') => {
  await page.getByRole(r, { name, exact: true }).first().click(); await settle(page)
}
const openSchool = (name) => async (page) => {
  await page.getByText(name, { exact: true }).first().click(); await settle(page, 800)
}
const billing = async (page) => { await role(page, 'Billing'); await settle(page, 600) }
// Inside the open workspace or dialog only: the list behind it has buttons
// with the same names.
const inDrawer = async (page, name) => {
  await page.locator('aside[role=dialog]').getByRole('button', { name, exact: true }).first().click()
  await settle(page, 600)
}
const tab = async (page, re) => { await page.getByRole('button', { name: re }).first().click(); await settle(page, 600) }

const SHOTS = [
  ...[1, 280, 281, 1500].map((n) => ({
    scene: 'sub-signup', name: `signup-${n}`,
    act: async (page) => { await page.locator('input[type=number]').fill(String(n)); await settle(page) },
  })),
  { scene: 'sub-signup', name: 'signup-281-yearly',
    act: async (page) => {
      await page.locator('input[type=number]').fill('281'); await settle(page)
      await page.getByText('Yearly', { exact: true }).click(); await settle(page)
    } },
  { scene: 'sub-trial', name: 'settings-trial' },
  { scene: 'sub-trial-preview', name: 'settings-trial-code-check',
    act: async (page) => { await page.locator('#discount-code').fill('WINTER10'); await role(page, 'Check') } },
  { scene: 'sub-code', name: 'settings-code' },
  { scene: 'sub-code-replace', name: 'settings-code-check-another',
    act: async (page) => { await page.locator('#discount-code').fill('YEARLY15'); await role(page, 'Check') } },
  { scene: 'sub-grace', name: 'settings-grace' },
  { scene: 'sub-grace', name: 'settings-grace-i-have-paid', act: async (page) => role(page, 'I have paid') },
  { scene: 'sub-near', name: 'settings-near-limit' },
  { scene: 'sub-full', name: 'settings-at-limit' },
  { scene: 'sub-enterprise', name: 'settings-enterprise' },
  { scene: 'sub-asked', name: 'settings-asked-move-up' },
  { scene: 'sub-extra', name: 'settings-extra-room' },
  { scene: 'sub-unpriced-trial', name: 'settings-enterprise-unpriced-trial' },
  { scene: 'sub-over-grace', name: 'settings-over-plan-grace' },
  { scene: 'sub-paid-ahead', name: 'settings-paid-ahead' },
  { scene: 'sub-stopping', name: 'settings-asked-to-stop' },
  { scene: 'sub-code', name: 'settings-cancel-ask',
    act: async (p) => { await role(p, 'Cancel my subscription') } },
  { scene: 'sub-locked-unpaid', name: 'locked-unpaid' },
  { scene: 'sub-locked-price', name: 'locked-no-price' },
  { scene: 'sub-locked-expired', name: 'locked-trial-expired' },
  { scene: 'sub-locked-expired-paid', name: 'locked-paid-expired' },
  { scene: 'sub-locked-ended', name: 'locked-ended-asked-to-stop' },
  { scene: 'sub-banner-grace', name: 'banner-grace', shell: true },
  { scene: 'sub-banner-price', name: 'banner-enterprise-no-price', shell: true },
  { scene: 'sub-roll-near', name: 'roll-notice-near' },
  { scene: 'sub-roll-full', name: 'roll-notice-full' },
  { scene: 'sub-roll-extra', name: 'roll-notice-extra-room' },
  { scene: 'sub-roll-clerk', name: 'roll-notice-clerk' },
  { scene: 'sub-plan-code', name: 'your-plan-code' },
  { scene: 'sub-plan-unpriced', name: 'your-plan-enterprise-unpriced' },
  { scene: 'sub-console', name: 'console-schools' },
  { scene: 'sub-console-s13', name: 'console-ravi-overview', act: openSchool('Ravi Educational Complex'), unclip: true },
  { scene: 'sub-console-s13', name: 'console-ravi-billing', act: async (p) => { await openSchool('Ravi Educational Complex')(p); await billing(p) }, unclip: true },
  { scene: 'sub-console-s13', name: 'console-ravi-set-price',
    act: async (p) => { await openSchool('Ravi Educational Complex')(p); await billing(p); await inDrawer(p, 'Set price') }, unclip: true },
  { scene: 'sub-console-s9', name: 'console-city-grammar-billing', act: async (p) => { await openSchool('City Grammar Campus')(p); await billing(p) }, unclip: true },
  { scene: 'sub-console-s6', name: 'console-margalla-billing', act: async (p) => { await openSchool('Margalla Heights School System')(p); await billing(p) }, unclip: true },
  { scene: 'sub-console-s4', name: 'console-sunrise-overview', act: openSchool('Sunrise School'), unclip: true },
  { scene: 'sub-console-s4', name: 'console-sunrise-change-plan',
    act: async (p) => {
      await openSchool('Sunrise School')(p); await billing(p); await inDrawer(p, 'Change plan')
      await p.locator('label', { hasText: 'Growth' }).last().click(); await settle(p, 900)
    }, unclip: true },
  { scene: 'sub-console-s4-ent', name: 'console-sunrise-change-plan-enterprise',
    act: async (p) => {
      await openSchool('Sunrise School')(p); await billing(p); await inDrawer(p, 'Change plan')
      await p.locator('label', { hasText: 'Enterprise' }).last().click(); await settle(p, 400)
      const box = p.locator('input[inputmode=numeric], input[inputmode=decimal]').first()
      if (await box.count()) { await box.fill('7000'); await settle(p, 900) }
    }, unclip: true },
  { scene: 'sub-console-s11', name: 'console-bright-minds-overview', act: openSchool('Bright Minds School'), unclip: true },
  { scene: 'sub-console-s11', name: 'console-bright-minds-billing', act: async (p) => { await openSchool('Bright Minds School')(p); await billing(p) }, unclip: true },
  { scene: 'sub-console-s3', name: 'console-crescent-billing', act: async (p) => { await openSchool('Crescent Public School')(p); await billing(p) }, unclip: true },
  { scene: 'sub-console-s15', name: 'console-cedar-overview', act: openSchool('Cedar School'), unclip: true },
  { scene: 'sub-console-s2', name: 'console-iqra-billing', act: async (p) => { await openSchool('Iqra Model School')(p); await billing(p) }, unclip: true },
  { scene: 'sub-console-s17', name: 'console-hilltop-change-plan',
    act: async (p) => {
      await openSchool('Hilltop School')(p); await billing(p); await inDrawer(p, 'Change plan')
      await p.locator('label', { hasText: 'Growth' }).last().click(); await settle(p, 900)
    }, unclip: true },
  { scene: 'sub-console', name: 'console-renewals',
    act: async (p) => { await tab(p, /^Renewals/); await role(p, 'Show me who is due'); await settle(p, 800) } },
  { scene: 'sub-console-s7', name: 'console-room-requests', act: async (p) => { await tab(p, /^Requests for more room/) } },
  { scene: 'sub-console', name: 'console-claims', act: async (p) => { await tab(p, /^Payments reported/) } },
  { scene: 'sub-console', name: 'console-discounts', act: async (p) => { await role(p, 'Discounts'); await settle(p, 800) } },
  { scene: 'sub-console', name: 'console-discounts-new',
    act: async (p) => { await role(p, 'Discounts'); await role(p, 'New code'); await settle(p, 800) }, unclip: true },
  { scene: 'sub-console', name: 'console-discounts-give',
    act: async (p) => { await role(p, 'Discounts'); await p.getByRole('button', { name: 'Give to a school' }).first().click(); await settle(p, 800) }, unclip: true },
  { scene: 'sub-console', name: 'console-discounts-code-open',
    act: async (p) => { await role(p, 'Discounts'); await p.getByRole('button', { name: 'Schools and log' }).first().click(); await settle(p, 800) } },
]

const filter = process.argv[2] ? new RegExp(process.argv[2]) : null
const browser = await chromium.launch({ executablePath: '/opt/pw-browsers/chromium' })
const problems = []
for (const s of SHOTS) {
  if (filter && !filter.test(s.name)) continue
  for (const width of [360, 1280]) {
    const height = s.unclip ? (width < 600 ? 3200 : 2000) : 900
    const ctx = await browser.newContext({ viewport: { width, height }, deviceScaleFactor: 1 })
    const page = await ctx.newPage()
    page.setDefaultTimeout(8000)
    const errs = []
    page.on('pageerror', (e) => errs.push(String(e)))
    const url = `${BASE}?scene=${s.scene}${s.shell ? '&shell=1' : ''}`
    await page.goto(url, { waitUntil: 'networkidle' })
    await settle(page, 700)
    try {
      if (s.act) await s.act(page)
    } catch (e) {
      problems.push(`${s.name}@${width}: action failed: ${String(e).split('\n')[0]}`)
    }
    if (s.unclip) await unclip(page)
    await settle(page, 300)
    const wide = await page.evaluate(() => document.documentElement.scrollWidth)
    if (wide > width + 1) problems.push(`${s.name}@${width}: page is ${wide}px wide`)
    for (const e of errs) problems.push(`${s.name}@${width}: ${e}`)
    await page.screenshot({ path: `${OUT}/${s.name}-${width}.png`, fullPage: true })
    await ctx.close()
  }
}
await browser.close()
console.log(problems.length ? problems.join('\n') : 'no problems noted')

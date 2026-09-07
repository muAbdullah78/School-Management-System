/**
 * Can a stale app shell still produce a silent blank page?
 *
 * WHY THIS EXISTS
 *
 * A school reported the sign-in page loading for about a minute and then going
 * completely white. Reproduced here, and every part of the mechanism is a
 * component working as designed:
 *
 *   Vite fingerprints its output, so each build has new asset filenames. A
 *   browser holding an OLD index.html therefore asks for a filename that is no
 *   longer deployed. web/wrangler.jsonc sets not_found_handling to
 *   "single-page-application", which answers a path with no file by returning
 *   index.html, at 200, as text/html. So a request for a script receives a
 *   page, Chrome refuses to execute HTML as a module script, and the result is
 *
 *       #root innerHTML length: 0
 *       BODY TEXT: ""
 *       CONSOLE error: Failed to load module script: Expected a
 *         JavaScript-or-Wasm module script but the server responded with a
 *         MIME type of "text/html".
 *
 *   A blank page, a 200 in the network tab, and one line in a console no
 *   school will ever open.
 *
 * WHY IT IS A BROWSER TEST AND NOT A GREP
 *
 * scripts/check-stale-shell.py covers what text can decide. It deliberately
 * does not claim the two properties below, because an earlier version of it
 * did: it asserted them by grepping for one spelling of the old defect, and
 * reintroducing the same defect in a different spelling was reported as clean.
 * These two are about what a service worker DOES, so they are asked of one.
 *
 *   1. A stale shell puts something readable on screen, exactly once, and
 *      never loops.
 *   2. A browser running the OLD worker with a poisoned cache recovers on its
 *      own after the new worker deploys.
 *
 * NOT IN CI, for the same reason as check-cold-start.mjs: it needs Playwright
 * and a Chromium download, which web/ deliberately does not carry so every CI
 * install stays cheap. Run it by hand when touching index.html's rescue,
 * public/sw.js, public/_headers or wrangler.jsonc.
 *
 *   cd web && VITE_SUPABASE_URL=https://probe.supabase.co \
 *             VITE_SUPABASE_ANON_KEY=probe-anon-key-not-real npm run build
 *   node scripts/check-blank-page.mjs
 *
 * It serves the build itself and needs no network: the Supabase host is
 * unroutable and every call to it is answered by a route handler.
 */
import { createRequire } from 'node:module'
import { spawn } from 'node:child_process'
import { cpSync, mkdtempSync, readFileSync, writeFileSync, rmSync, copyFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'

const require = createRequire('/opt/node22/lib/node_modules/')
const { chromium } = require('playwright')

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..')
const DIST = join(ROOT, 'web', 'dist')
const PORT = 8931
const ORIGIN = `http://127.0.0.1:${PORT}`

let failures = 0
function ok(cond, label) {
  console.log(`${cond ? 'PASS  ' : 'FAIL  '}${label}`)
  if (!cond) failures++
}

/** Serve a directory the way Workers Static Assets does: index.html, at 200,
 *  for any path with no file. That fallback is the whole cause. */
function serve(dir) {
  const p = spawn('python3', [join(ROOT, 'scripts', 'spa-server.py'), dir, String(PORT)],
    { stdio: 'ignore' })
  return p
}

const work = mkdtempSync(join(tmpdir(), 'blankpage-'))
const site = join(work, 'site')
cpSync(DIST, site, { recursive: true })

// The state a stuck school is in: the shell they are holding names a build
// that is no longer deployed.
const shell = readFileSync(join(site, 'index.html'), 'utf8')
const staleShell = shell.replace(/assets\/index-[A-Za-z0-9_-]+\.js/g, 'assets/index-GONE.js')
                        .replace(/assets\/index-[A-Za-z0-9_-]+\.css/g, 'assets/index-GONE.css')
if (staleShell === shell) {
  console.log('FAIL  could not build a stale shell: no fingerprinted asset in index.html')
  process.exit(1)
}

const server = serve(site)
await new Promise((r) => setTimeout(r, 1200))

const browser = await chromium.launch()

// -------------------------------------------------------------------------
// 1. A stale shell must not be a blank page.
// -------------------------------------------------------------------------
writeFileSync(join(site, 'index.html'), staleShell)
{
  const page = await browser.newPage()
  const navs = []
  page.on('framenavigated', (f) => { if (f === page.mainFrame()) navs.push(f.url()) })
  await page.goto(`${ORIGIN}/login`, { waitUntil: 'load' }).catch(() => {})
  await page.waitForTimeout(6000)
  const text = await page.evaluate(() => document.body.innerText)
  ok(text.trim().length > 0,
    'a shell naming a build that is gone says something instead of going blank')
  ok(/did not finish loading/i.test(text),
    '  and what it says names the problem rather than showing a spinner')
  ok(await page.evaluate(() => !!document.querySelector('button')),
    '  and offers a way to try again')
  // Exactly one self-heal: the first load, plus the reload it triggered.
  ok(navs.length === 2,
    `  and heals itself exactly once rather than looping (${navs.length} navigations)`)
  await page.close()
}

// -------------------------------------------------------------------------
// 2. A browser running the OLD worker, with a poisoned cache, must recover
//    once the new worker deploys.
// -------------------------------------------------------------------------
writeFileSync(join(site, 'index.html'), shell)
{
  // Put the previous worker back, as a stuck school still has it installed.
  const oldWorker = process.argv[2]
  if (!oldWorker) {
    console.log('SKIP  worker upgrade: pass a path to the previous sw.js as argv[2]')
    console.log('        git show HEAD~1:web/public/sw.js > /tmp/old-sw.js')
  } else {
    copyFileSync(oldWorker, join(site, 'sw.js'))
    const profile = mkdtempSync(join(tmpdir(), 'blankprofile-'))
    const ctx = await chromium.launchPersistentContext(profile, {})
    const page = await ctx.newPage()
    await page.route('**probe.supabase.co**', (r) =>
      r.fulfill({ status: 200, contentType: 'application/json', body: '{}' }))

    await page.goto(`${ORIGIN}/login`, { waitUntil: 'load' })
    await page.waitForFunction(() => navigator.serviceWorker.controller !== null,
      null, { timeout: 15000 }).catch(() => {})
    const before = await page.evaluate(() => caches.keys())
    ok(before.length > 0, `the old worker is installed and caching (${before.join()})`)

    // Poison it exactly as the old worker would: the SPA fallback's page,
    // stored under a script's URL.
    await page.evaluate(async (name) => {
      const c = await caches.open(name)
      await c.put('/assets/index-GONE.js', new Response('<!doctype html><p>fallback</p>',
        { headers: { 'Content-Type': 'text/html' } }))
    }, before[0])

    // The deploy lands.
    copyFileSync(join(ROOT, 'web', 'public', 'sw.js'), join(site, 'sw.js'))
    const wanted = /const CACHE = '([^']+)'/.exec(
      readFileSync(join(ROOT, 'web', 'public', 'sw.js'), 'utf8'))?.[1]
    ok(!!wanted && wanted !== before[0],
      `  the new worker uses a different cache name (${before[0]} -> ${wanted})`)

    // POLLED FROM NODE, WITH A NAVIGATION EACH TIME, and both halves of that
    // are deliberate.
    //
    // Fixed sleeps came first and reported a failure the same code had passed
    // by hand ten minutes earlier: a browser decides for itself when to check
    // its worker for an update, so a test that guesses how long that takes
    // fails for reasons that have nothing to do with the product.
    //
    // page.waitForFunction with an async predicate came second and failed the
    // same way. The navigation is what prompts the update check, so waiting
    // inside one page load can wait for ever. Asking again, out loud, after
    // each navigation is the thing that actually models a school opening the
    // app twice.
    let recovered = false
    let after = []
    for (let attempt = 0; attempt < 6 && !recovered; attempt++) {
      await page.goto(`${ORIGIN}/login`, { waitUntil: 'load' })
      await page.waitForTimeout(1500)
      after = await page.evaluate(() => caches.keys())
      recovered = after.includes(wanted) && !after.includes(before[0])
    }
    ok(recovered && !after.includes(before[0]),
      `  the poisoned cache is gone after the upgrade (${after.join() || 'none'})`)

    await page.goto(`${ORIGIN}/login`, { waitUntil: 'load' })
    await page.waitForFunction(
      () => document.getElementById('root')?.childElementCount > 0,
      null, { timeout: 15000 }).catch(() => {})
    const text = await page.evaluate(() => document.body.innerText)
    ok(/Sign in/i.test(text), '  and the app boots')
    await ctx.close()
    rmSync(profile, { recursive: true, force: true })
  }
}

await browser.close()
server.kill()
rmSync(work, { recursive: true, force: true })
console.log(failures ? `\n${failures} check(s) failed` : '\nno stale shell can go blank silently')
process.exit(failures ? 1 : 0)

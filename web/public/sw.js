/* School Manager service worker.
 *
 * Strategy:
 *  - Navigations (SPA routes) → network-first, fall back to the cached app
 *    shell, so the app opens offline and the client-side router takes over.
 *  - Same-origin static assets (Vite's hashed JS/CSS/images) → cache-first with
 *    a background refresh, so they load instantly.
 *  - Cross-origin requests (the school's Supabase API) are never touched, so
 *    auth and Row Level Security are unaffected and no user data is ever
 *    cached on the device.
 *
 * WHY THIS FILE WAS REWRITTEN
 *
 * A school reported the sign-in page loading for a minute and then going
 * completely white. Reproduced: a browser holding an OLD index.html asks for
 * an asset name that no longer exists, wrangler.jsonc answers a missing path
 * with index.html at 200 as text/html, and Chrome refuses to execute HTML as a
 * module script. Blank page, 200 in the network tab, one console line nobody
 * opens. See the long comment in web/index.html for the full trace.
 *
 * THIS FILE WAS ONE OF THE THREE WAYS TO BE HANDED THAT OLD index.html, and it
 * was the only one that could hold on to it indefinitely. Three defects:
 *
 *   1. THE CACHE NAME WAS A CONSTANT, so `activate` only ever ran when this
 *      file itself changed, which it had not since August. Every deploy in
 *      between left whatever was in `sm-shell-v1` exactly where it was.
 *   2. IT WOULD SERVE AND CACHE AN HTML RESPONSE FOR A SCRIPT REQUEST. The
 *      SPA fallback answers a missing asset with a page, at 200, and this
 *      treated that as a successful fetch and stored it. So one bad moment
 *      poisoned the cache with a page under a script's name, and every
 *      subsequent load served it from disk, instantly, for ever.
 *   3. respondWith COULD BE HANDED undefined. `return cached || network`,
 *      where network's own catch resolves to `cached`: for an asset that was
 *      not cached and whose fetch failed, that is respondWith(undefined),
 *      which is a TypeError and turns a recoverable hiccup into a hard failure.
 *
 * The version below is bumped as part of this fix, which is what unsticks
 * anybody already holding a poisoned cache: this file has changed, so `install`
 * runs, `activate` deletes every cache that is not the current one, and the
 * next navigation is clean. RAISE IT whenever this file's caching behaviour
 * changes.
 */
const CACHE = 'sm-shell-v2'
const SHELL = '/index.html'

/* A response that is HTML when HTML was not asked for is the SPA fallback
 * standing in for a file that is not there. Believing it is what poisoned the
 * cache, so it is named once and checked in both directions. */
function isHtml(res) {
  const type = res && res.headers && res.headers.get('content-type')
  return !!type && type.indexOf('text/html') !== -1
}

/* respondWith REQUIRES a Response. Returning undefined from any branch below
 * fails the request outright, so every path ends at one of these. */
function offline() {
  return new Response('', {
    status: 503,
    statusText: 'Offline',
    headers: { 'Content-Type': 'text/plain' },
  })
}

self.addEventListener('install', (event) => {
  event.waitUntil(
    caches.open(CACHE)
      .then((c) => c.add(SHELL))
      .catch(() => {})
      .then(() => self.skipWaiting()),
  )
})

self.addEventListener('activate', (event) => {
  event.waitUntil(
    caches.keys()
      .then((keys) => Promise.all(
        keys.filter((k) => k !== CACHE).map((k) => caches.delete(k)),
      ))
      .then(() => self.clients.claim()),
  )
})

/* The page can ask to be let out. index.html's rescue path clears the caches
 * and unregisters directly; this is the gentler route for the app itself. */
self.addEventListener('message', (event) => {
  if (event.data === 'sm-drop-caches') {
    caches.keys()
      .then((keys) => Promise.all(keys.map((k) => caches.delete(k))))
      .catch(() => {})
  }
})

self.addEventListener('fetch', (event) => {
  const req = event.request
  if (req.method !== 'GET') return
  let url
  try { url = new URL(req.url) } catch (e) { return }
  if (url.origin !== self.location.origin) return // never cache the Supabase API

  if (req.mode === 'navigate') {
    event.respondWith(
      fetch(req)
        .then((res) => {
          // Only a real page is worth keeping as the shell.
          if (res && res.status === 200 && isHtml(res)) {
            const copy = res.clone()
            caches.open(CACHE).then((c) => c.put(SHELL, copy)).catch(() => {})
          }
          return res
        })
        .catch(() => caches.match(SHELL).then((c) => c || offline())),
    )
    return
  }

  event.respondWith(
    caches.match(req)
      .then((cached) => {
        // A cached HTML response under a non-navigation URL is the poisoned
        // entry described at the top of this file. Never serve it, and take it
        // out of the cache on the way past.
        if (cached && isHtml(cached)) {
          caches.open(CACHE).then((c) => c.delete(req)).catch(() => {})
          cached = undefined
        }
        if (cached) {
          // Refresh in the background. Failures are ignored: the caller
          // already has a good answer.
          fetch(req)
            .then((res) => {
              if (res && res.status === 200 && !isHtml(res)) {
                const copy = res.clone()
                caches.open(CACHE).then((c) => c.put(req, copy)).catch(() => {})
              }
            })
            .catch(() => {})
          return cached
        }
        return fetch(req)
          .then((res) => {
            // THE LINE THAT STOPS THE BLANK PAGE BECOMING PERMANENT. A script
            // or stylesheet request answered with a page is a missing file, so
            // it is passed straight through to the browser (whose MIME check
            // fires the error event index.html is listening for) and NOT
            // written to the cache.
            if (res && res.status === 200 && !isHtml(res)) {
              const copy = res.clone()
              caches.open(CACHE).then((c) => c.put(req, copy)).catch(() => {})
            }
            return res
          })
          .catch(() => offline())
      })
      .catch(() => fetch(req).catch(() => offline())),
  )
})

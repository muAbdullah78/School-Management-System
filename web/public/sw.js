/* School Manager service worker — minimal, dependency-free offline support.
 *
 * Strategy:
 *  - Navigations (SPA routes) → network-first, fall back to the cached app shell,
 *    so the app opens offline and the client-side router takes over.
 *  - Same-origin static assets (Vite's hashed JS/CSS/images) → stale-while-
 *    revalidate, so they load instantly and update in the background.
 *  - Cross-origin requests (the school's Supabase API) are never touched — they
 *    always go to the network, so auth and Row Level Security are unaffected and
 *    no user data is ever cached on the device.
 */
const CACHE = 'sm-shell-v1'
const SHELL = '/index.html'

self.addEventListener('install', (event) => {
  event.waitUntil(
    caches.open(CACHE).then((c) => c.add(SHELL)).then(() => self.skipWaiting()),
  )
})

self.addEventListener('activate', (event) => {
  event.waitUntil(
    caches.keys()
      .then((keys) => Promise.all(keys.filter((k) => k !== CACHE).map((k) => caches.delete(k))))
      .then(() => self.clients.claim()),
  )
})

self.addEventListener('fetch', (event) => {
  const req = event.request
  if (req.method !== 'GET') return
  const url = new URL(req.url)
  if (url.origin !== self.location.origin) return // never cache the Supabase API

  if (req.mode === 'navigate') {
    event.respondWith(
      fetch(req)
        .then((res) => {
          const copy = res.clone()
          caches.open(CACHE).then((c) => c.put(SHELL, copy)).catch(() => {})
          return res
        })
        .catch(() => caches.match(SHELL)),
    )
    return
  }

  event.respondWith(
    caches.match(req).then((cached) => {
      const network = fetch(req)
        .then((res) => {
          if (res && res.status === 200) {
            const copy = res.clone()
            caches.open(CACHE).then((c) => c.put(req, copy)).catch(() => {})
          }
          return res
        })
        .catch(() => cached)
      return cached || network
    }),
  )
})

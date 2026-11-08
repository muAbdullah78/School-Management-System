// Offline copies of what the screens read, kept at the fetch boundary.
//
// supabase-js lets the app hand it the fetch it uses. This one keeps a copy of
// every READ the app makes (a table select, or an RPC the database itself
// guarantees cannot write) and answers from that copy when the network cannot:
//
//   * the request fails (no connection, the server is down): the copy;
//   * the request is slow (a weak signal) and a copy exists: the copy after a
//     few seconds, while the request carries on and refreshes the copy for
//     next time, so a bad connection is not a frozen screen;
//   * no copy: the request, however long it takes, or its error.
//
// Nothing that writes is ever answered from a copy: a POST to a table, a PATCH,
// a DELETE or an RPC that is not on READ_RPCS goes straight to the network, as
// before. READ_RPCS holds only functions Postgres declares STABLE or IMMUTABLE,
// which it refuses to let modify anything (checked against the database by
// supabase/check-read-rpcs.sh).
//
// Copies are kept per login (the user id inside the access token), so one
// person never sees another's copy on a shared computer, and are deleted when
// that person signs out.
import { openDB, type DBSchema, type IDBPDatabase } from 'idb'
import { READ_RPCS } from './readRpcs'

export interface ReadCopy {
  key: string
  user_id: string
  status: number
  headers: [string, string][]
  body: string
  saved_wall: number
}

interface Schema extends DBSchema {
  reads: { key: string; value: ReadCopy; indexes: { by_user: string; by_saved: number } }
}

/** How long a read may take, when a copy exists, before the copy is shown instead. */
export const SLOW_MS = 4000
/** Copies older than this are thrown away. */
export const KEEP_MS = 30 * 86_400_000
/** Headers worth keeping with a copy: the count PostgREST sends for a page, and the type. */
const KEEP_HEADERS = ['content-type', 'content-range', 'preference-applied']

export class ReadStore {
  private db: Promise<IDBPDatabase<Schema>>
  constructor(name = 'sm-reads') {
    this.db = openDB<Schema>(name, 1, {
      upgrade(db) {
        const s = db.createObjectStore('reads', { keyPath: 'key' })
        s.createIndex('by_user', 'user_id')
        s.createIndex('by_saved', 'saved_wall')
      },
    })
  }
  async get(key: string): Promise<ReadCopy | undefined> { return (await this.db).get('reads', key) }
  async put(copy: ReadCopy): Promise<void> { await (await this.db).put('reads', copy) }
  /** Everything kept for one login, on sign-out. */
  async forget(userId: string): Promise<void> {
    const db = await this.db
    const tx = db.transaction('reads', 'readwrite')
    for (const k of await tx.store.index('by_user').getAllKeys(userId)) await tx.store.delete(k)
    await tx.done
  }
  /** Copies older than KEEP_MS. */
  async prune(nowWall: number): Promise<void> {
    const db = await this.db
    const tx = db.transaction('reads', 'readwrite')
    for (const k of await tx.store.index('by_saved').getAllKeys(IDBKeyRange.upperBound(nowWall - KEEP_MS))) {
      await tx.store.delete(k)
    }
    await tx.done
  }
  async close(): Promise<void> { (await this.db).close() }
}

/** The login a request is made as: the `sub` inside its bearer token, or null for none. */
export function userOf(headers: Headers): string | null {
  const auth = headers.get('authorization') ?? ''
  const m = /^Bearer\s+[^.]+\.([^.]+)\./i.exec(auth)
  if (!m) return null
  try {
    const json = atob(m[1].replace(/-/g, '+').replace(/_/g, '/').padEnd(Math.ceil(m[1].length / 4) * 4, '='))
    const sub = (JSON.parse(json) as { sub?: unknown; role?: unknown }).sub
    return typeof sub === 'string' && sub ? sub : null
  } catch {
    return null
  }
}

/** Is this request a read that may be answered from a copy? */
export function isRead(url: URL, method: string, restBase: string): boolean {
  if (!url.href.startsWith(restBase)) return false
  const path = url.pathname.slice(new URL(restBase).pathname.length)
  const m = method.toUpperCase()
  if (path.startsWith('rpc/')) {
    const fn = path.slice(4).split('/')[0]
    return (m === 'POST' || m === 'GET') && READ_RPCS.has(fn)
  }
  return m === 'GET'
}

/** The copy's key: who asked, and exactly what they asked for. */
export function keyFor(user: string, method: string, url: URL, headers: Headers, body: string): string {
  const shape = ['accept', 'range', 'range-unit', 'prefer', 'accept-profile']
    .map((h) => `${h}=${headers.get(h) ?? ''}`).join('&')
  return `${user}|${method.toUpperCase()} ${url.pathname}${url.search}|${shape}|${body}`
}

type Served = { saved_wall: number; key: string }
const servedListeners = new Set<(s: Served) => void>()
/** Called whenever a screen is shown a copy instead of a fresh answer. */
export function onServedFromCopy(l: (s: Served) => void): () => void {
  servedListeners.add(l)
  return () => { servedListeners.delete(l) }
}

function fromCopy(copy: ReadCopy): Response {
  const headers = new Headers(copy.headers)
  headers.set('x-sm-copy-saved-at', new Date(copy.saved_wall).toISOString())
  servedListeners.forEach((l) => l({ saved_wall: copy.saved_wall, key: copy.key }))
  return new Response(copy.body, { status: copy.status, headers })
}

async function keep(store: ReadStore, key: string, user: string, res: Response, nowWall: number): Promise<void> {
  try {
    const body = await res.clone().text()
    const headers: [string, string][] = []
    for (const h of KEEP_HEADERS) {
      const v = res.headers.get(h)
      if (v != null) headers.push([h, v])
    }
    await store.put({ key, user_id: user, status: res.status, headers, body, saved_wall: nowWall })
  } catch { /* storage full or closed: the answer still goes to the screen */ }
}

export interface CachingOptions {
  store: ReadStore
  restBase: string
  slowMs?: number
  wall?: () => number
}

/** A fetch for supabase-js that keeps and serves offline copies of reads. */
/**
 * A read that must never be answered from a copy. Sent by the few reads whose
 * answer is PRINTED as fact: the balance on a fee receipt, read straight after
 * the payment, which a copy kept before it would show as still owed. Removed
 * before the request leaves the device, so the server never sees it.
 */
export const FRESH_HEADER = 'x-sm-fresh'

export function cachingFetch(base: typeof fetch, opts: CachingOptions): typeof fetch {
  const slowMs = opts.slowMs ?? SLOW_MS
  const wall = opts.wall ?? (() => Date.now())
  return async (input: RequestInfo | URL, init?: RequestInit): Promise<Response> => {
    const asked = new Headers(init?.headers ?? (input instanceof Request ? input.headers : undefined))
    if (asked.has(FRESH_HEADER)) {
      asked.delete(FRESH_HEADER)
      return base(input, { ...init, headers: asked })
    }
    const req = new Request(input, init)
    let url: URL
    try { url = new URL(req.url) } catch { return base(input, init) }
    if (!isRead(url, req.method, opts.restBase)) return base(input, init)
    const user = userOf(req.headers)
    if (!user) return base(input, init)

    const body = req.method.toUpperCase() === 'GET' ? '' : await req.clone().text()
    const key = keyFor(user, req.method, url, req.headers, body)
    let copy: ReadCopy | undefined
    try { copy = await opts.store.get(key) } catch { copy = undefined }

    const network = base(input, init).then(async (res) => {
      if (res.ok) await keep(opts.store, key, user, res, wall())
      return res
    })

    if (!copy) return network

    // A copy exists: the network has slowMs to answer, and a failure or a
    // server error falls back to the copy. A 4xx is the server saying no
    // (a lapsed sign-in, a permission) and is passed on, never papered over.
    const timer = new Promise<'slow'>((resolve) => setTimeout(() => resolve('slow'), slowMs))
    try {
      const first = await Promise.race([network, timer])
      if (first === 'slow') {
        network.catch(() => undefined) // let it finish and refresh the copy
        return fromCopy(copy)
      }
      if (first.status >= 500) return fromCopy(copy)
      return first
    } catch {
      return fromCopy(copy)
    }
  }
}

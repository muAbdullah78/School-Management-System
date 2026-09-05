/**
 * A stand-in Supabase client for mounting real screens in a test.
 *
 * WHY
 *
 * Not one page in this application was ever rendered by an automated check.
 * All 160 unit tests exercise lib/ in isolation, and the only components any
 * harness rendered were the portal, the dashboard and two auth screens. So a
 * page could throw on mount and nothing would know until a school clicked it
 * and got a blank white screen, which is exactly what happened with Accounts.
 *
 * WHAT IT IS
 *
 * Every method on the query builder returns the builder, and the builder is
 * thenable, so any chain in lib/db.ts resolves. That means the real db.ts
 * functions run: their unwrapping, their mapping and their error handling are
 * all exercised rather than mocked away. Only the network is fake.
 *
 * The DEFAULT is deliberately the emptiest legal answer: [] from a table,
 * null from an RPC, null from single(). That is the state of a school on its
 * first morning, which is both the commonest state a new customer is in and
 * the one nobody tests. Pass `rows` / `rpc` to describe a populated school.
 */
export interface FakeOptions {
  /** Rows per table name. Anything not listed comes back empty. */
  rows?: Record<string, unknown[]>
  /** Return value per RPC name. Anything not listed comes back null. */
  rpc?: Record<string, unknown>
  /** Make every table read fail, to exercise the error paths. */
  failEverything?: string
  /** Records every table and RPC a screen touched, for coverage reporting. */
  seen?: { tables: Set<string>; rpcs: Set<string> }
}

function builder(table: string, opts: FakeOptions): any {
  const fail = opts.failEverything
  const rows = opts.rows?.[table] ?? []
  // `single()` and `maybeSingle()` return an object, not a list. Getting this
  // wrong would hand callers an array where they expect a row, and produce
  // crashes the real client never would.
  let shape: 'many' | 'one' = 'many'

  const result = () =>
    fail
      ? { data: null, error: { message: fail, code: 'PGRST000', details: '', hint: '' }, count: null, status: 400 }
      : {
          data: shape === 'one' ? (rows[0] ?? null) : rows,
          error: null,
          count: rows.length,
          status: 200,
        }

  const target: any = {
    then: (ok: (v: unknown) => unknown, err?: (e: unknown) => unknown) =>
      Promise.resolve(result()).then(ok, err),
    catch: (err: (e: unknown) => unknown) => Promise.resolve(result()).catch(err),
    finally: (f: () => void) => Promise.resolve(result()).finally(f),
  }

  // Self-referential, declared before the Proxy so the handler can close over
  // it. It was a module-level variable at first, which meant two builders alive
  // at the same time shared one chain and a nested query returned the other
  // table's rows.
  const chain: any = new Proxy(target, {
    get(t, prop) {
      if (prop in t) return t[prop as keyof typeof t]
      if (prop === 'single' || prop === 'maybeSingle') {
        return () => { shape = 'one'; return chain }
      }
      // Every other builder method (select, eq, order, limit, insert, update,
      // delete, in, is, or, gte...) keeps the chain going.
      return () => chain
    },
  })
  return chain
}

export function fakeSupabase(opts: FakeOptions = {}) {
  return {
    from(table: string) {
      opts.seen?.tables.add(table)
      return builder(table, opts)
    },
    rpc(name: string, _args?: unknown) {
      opts.seen?.rpcs.add(name)
      const has = opts.rpc && name in opts.rpc
      const value = has ? opts.rpc![name] : null
      const r = opts.failEverything
        ? { data: null, error: { message: opts.failEverything, code: 'PGRST000' } }
        : { data: value, error: null }
      // An RPC result is also chainable in places (.select(), .single()), so it
      // gets the same treatment rather than a bare promise.
      const t: any = {
        then: (ok: (v: unknown) => unknown, e?: (x: unknown) => unknown) =>
          Promise.resolve(r).then(ok, e),
        catch: (e: (x: unknown) => unknown) => Promise.resolve(r).catch(e),
        finally: (f: () => void) => Promise.resolve(r).finally(f),
      }
      return new Proxy(t, {
        get(tt, prop) {
          if (prop in tt) return tt[prop as keyof typeof tt]
          return () => new Proxy(t, { get: (a, b) => (b in a ? a[b as keyof typeof a] : () => a) })
        },
      })
    },
    storage: {
      from() {
        return {
          createSignedUrl: async () => ({ data: null, error: { message: 'no storage in tests' } }),
          createSignedUrls: async () => ({ data: [], error: null }),
          upload: async () => ({ data: null, error: { message: 'no storage in tests' } }),
          remove: async () => ({ data: null, error: null }),
        }
      },
    },
    auth: {
      getSession: async () => ({ data: { session: null }, error: null }),
      getUser: async () => ({ data: { user: null }, error: null }),
      onAuthStateChange: () => ({ data: { subscription: { unsubscribe() {} } } }),
      signOut: async () => ({ error: null }),
    },
    functions: {
      invoke: async () => ({ data: null, error: { name: 'FunctionsFetchError', message: 'not deployed in tests' } }),
    },
    channel: () => ({ on: () => ({ subscribe: () => ({}) }), subscribe: () => ({}) }),
    removeChannel: () => {},
  }
}

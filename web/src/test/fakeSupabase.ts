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
  /**
   * Make ONE rpc fail with this message, the way PostgREST would. A screen
   * that treats "this function is not installed yet" differently from "this
   * read failed" can only be tested by failing one call and not the rest.
   */
  rpcErrors?: Record<string, string>
  /** Records every table and RPC a screen touched, for coverage reporting. */
  seen?: { tables: Set<string>; rpcs: Set<string> }
  /**
   * Every RPC call in order, WITH ITS ARGUMENTS.
   *
   * `seen` records that a function was called; this records what it was called
   * with, and the difference is a shipped defect. The student profile handed
   * fn_add_discount an ENROLMENT id where the function has taken a CHILD since
   * 0138, so every press of "Propose discount" came back "students not found in
   * this school". Both ids are strings, so the types were happy and `seen` was
   * happy: the only thing that could have caught it is the value.
   */
  calls?: { name: string; args: Record<string, unknown> }[]
  /** What functions.invoke should do, per function name. */
  fn?: Record<string, { data?: unknown; error?: { name: string; message: string; body?: unknown } }>
  /**
   * Every Edge Function call, WITH ITS BODY.
   *
   * The parent portal is created through create-teacher precisely so that
   * supabase.auth.signUp is never called: signUp replaces the current session,
   * which would silently sign the clerk in as the parent they just entered. Only
   * the body proves which path was taken, so a test has to be able to read it.
   */
  onInvoke?: (name: string, body: unknown) => void
  /**
   * A signed-in session for the auth block, plus a handle on the auth-change
   * listener so a test can play a TOKEN REFRESH.
   *
   * That event is not a curiosity: supabase-js fires it on a timer and again
   * when a hidden tab becomes visible, and it used to unmount the whole route
   * tree and empty every open form. A test cannot reproduce that without being
   * able to fire it, so the fake exposes it.
   */
  auth?: FakeAuth
}

export interface FakeAuth {
  /** The session getSession() answers with. Null means signed out. */
  session?: unknown
  /**
   * Filled in by the fake with the callback AuthProvider registered, so a test
   * can call `auth.emit('TOKEN_REFRESHED', newSession)`.
   */
  emit?: (event: string, session: unknown) => void
  /** Every signOut() call, with the options it was given. */
  signOuts?: unknown[]
}

function builder(table: string, opts: FakeOptions): any {
  const fail = opts.failEverything
  const rows = opts.rows?.[table] ?? []
  // `single()` and `maybeSingle()` return an object, not a list. Getting this
  // wrong would hand callers an array where they expect a row, and produce
  // crashes the real client never would.
  let shape: 'many' | 'one' = 'many'
  // range(from, to) is honoured, as PostgREST honours it. db.ts pages every
  // report until an empty page comes back, and a fake that answered every
  // page with the same rows would never send the empty one.
  let span: [number, number] | null = null

  const result = () =>
    fail
      ? { data: null, error: { message: fail, code: 'PGRST000', details: '', hint: '' }, count: null, status: 400 }
      : {
          data: shape === 'one' ? (rows[0] ?? null) : span ? rows.slice(span[0], span[1] + 1) : rows,
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
      if (prop === 'range') {
        return (a: number, b: number) => { span = [a, b]; return chain }
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
    rpc(name: string, args?: unknown) {
      opts.seen?.rpcs.add(name)
      opts.calls?.push({ name, args: (args ?? {}) as Record<string, unknown> })
      const has = opts.rpc && name in opts.rpc
      const value = has ? opts.rpc![name] : null
      const r = opts.failEverything
        ? { data: null, error: { message: opts.failEverything, code: 'PGRST000' } }
        : opts.rpcErrors && name in opts.rpcErrors
          ? { data: null, error: { message: opts.rpcErrors[name], code: 'PGRST202' } }
          : { data: value, error: null }
      // An RPC result is also chainable in places (.select(), .single()), so it
      // gets the same treatment rather than a bare promise. range() slices a
      // set-returning answer, as PostgREST does.
      const thenable = (res: unknown): any => ({
        then: (ok: (v: unknown) => unknown, e?: (x: unknown) => unknown) =>
          Promise.resolve(res).then(ok, e),
        catch: (e: (x: unknown) => unknown) => Promise.resolve(res).catch(e),
        finally: (f: () => void) => Promise.resolve(res).finally(f),
      })
      const t: any = thenable(r)
      return new Proxy(t, {
        get(tt, prop) {
          if (prop in tt) return tt[prop as keyof typeof tt]
          if (prop === 'range') {
            return (a: number, b: number) => thenable(
              Array.isArray(r.data) ? { ...r, data: (r.data as unknown[]).slice(a, b + 1) } : r)
          }
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
      getSession: async () => ({ data: { session: opts.auth?.session ?? null }, error: null }),
      getUser: async () => ({ data: { user: (opts.auth?.session as any)?.user ?? null }, error: null }),
      onAuthStateChange: (cb: (event: string, session: unknown) => void) => {
        if (opts.auth) opts.auth.emit = cb
        return { data: { subscription: { unsubscribe() {} } } }
      },
      signOut: async (options?: unknown) => {
        opts.auth?.signOuts?.push(options)
        return { error: null }
      },
    },
    functions: {
      invoke: async (name: string, init?: { body?: unknown }) => {
        opts.onInvoke?.(name, init?.body)
        const spec = opts.fn?.[name]
        if (!spec) {
          return { data: null, error: { name: 'FunctionsFetchError', message: 'not deployed in tests' } }
        }
        if (spec.error) {
          // The real client exposes the response body through context.json(),
          // which is where the function's own error text and version live.
          return {
            data: null,
            error: Object.assign(new Error(spec.error.message), {
              name: spec.error.name,
              context: { json: async () => spec.error!.body ?? { error: spec.error!.message } },
            }),
          }
        }
        return { data: spec.data ?? null, error: null }
      },
    },
    channel: () => ({ on: () => ({ subscribe: () => ({}) }), subscribe: () => ({}) }),
    removeChannel: () => {},
  }
}

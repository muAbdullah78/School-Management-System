/**
 * Stands in for `@/lib/supabase` in the LIVE preview (vite.live.config.ts).
 *
 * The static harnesses alias the module to tools/supabase-stub.ts, which throws
 * on any use, because renderToStaticMarkup runs no queries at all. A live page
 * does run them, for anything not seeded, and a screen that throws from inside
 * a query function never shows its real failure state. This answers every
 * call the way PostgREST answers a failure, so the page draws exactly what a
 * school would see: an RPC named in window.__liveErrors fails with that
 * message, and anything else fails with a message saying it was not seeded.
 *
 * Nothing here can reach a network. There is no client to reach one with.
 */
import type { SupabaseClient } from '@supabase/supabase-js'

declare global {
  interface Window { __liveErrors?: Record<string, string> }
}

function failure(message: string) {
  return { data: null, error: { message, code: 'PGRST000', details: null, hint: null } }
}

function chain(message: string): unknown {
  const done = Promise.resolve(failure(message))
  const self: unknown = new Proxy(function () {}, {
    get(_t, prop) {
      if (prop === 'then') return done.then.bind(done)
      if (prop === 'catch') return done.catch.bind(done)
      if (prop === 'finally') return done.finally.bind(done)
      return () => self
    },
    apply() { return self },
  })
  return self
}

const client = {
  rpc(name: string) {
    const msg = window.__liveErrors?.[name] ?? `live preview: ${name} is not seeded`
    return chain(msg)
  },
  from(table: string) {
    return chain(window.__liveErrors?.[table] ?? `live preview: table ${table} is not seeded`)
  },
  storage: {
    from() {
      return {
        createSignedUrl: async () => failure('no storage in the preview'),
        createSignedUrls: async () => ({ data: [], error: null }),
      }
    },
  },
  functions: { invoke: async () => failure('no functions in the preview') },
  auth: {
    getSession: async () => ({ data: { session: null }, error: null }),
    onAuthStateChange: () => ({ data: { subscription: { unsubscribe() {} } } }),
  },
}

export const supabase = client as unknown as SupabaseClient

export function requireSupabase(): SupabaseClient {
  return client as unknown as SupabaseClient
}

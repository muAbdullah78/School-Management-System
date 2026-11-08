import { createClient, type SupabaseClient } from '@supabase/supabase-js'
import { config, isConfigured } from './config'
import { cachingFetch, ReadStore } from '@/offline/readCache'

/**
 * The offline copies (web/src/offline/readCache.ts) sit in front of every
 * request: a read is kept and, when the network fails or crawls, answered from
 * what was kept. Writes pass straight through. Only where IndexedDB exists,
 * which is every browser and WebView the app runs in, and not the test runner.
 */
export const readStore: ReadStore | null =
  isConfigured && typeof indexedDB !== 'undefined' ? new ReadStore() : null

/**
 * A single Supabase client for the app. When the app has not yet been pointed
 * at a Supabase project (missing env vars), this is `null` and the UI shows a
 * "Not configured" screen instead of crashing.
 */
export const supabase: SupabaseClient | null = isConfigured
  ? createClient(config.supabaseUrl!, config.supabaseAnonKey!, {
      ...(readStore ? {
        global: {
          fetch: cachingFetch((...a: Parameters<typeof fetch>) => fetch(...a), {
            store: readStore, restBase: `${config.supabaseUrl!.replace(/\/+$/, '')}/rest/v1/`,
          }),
        },
      } : {}),
      auth: {
        persistSession: true,
        autoRefreshToken: true,
        detectSessionInUrl: true,
      },
    })
  : null

/** Narrowing helper so call sites get a non-null client or a clear error. */
export function requireSupabase(): SupabaseClient {
  if (!supabase) {
    throw new Error('Supabase is not configured. Set VITE_SUPABASE_URL and VITE_SUPABASE_ANON_KEY.')
  }
  return supabase
}

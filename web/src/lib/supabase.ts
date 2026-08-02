import { createClient, type SupabaseClient } from '@supabase/supabase-js'
import { config, isConfigured } from './config'

/**
 * A single Supabase client for the app. When the app has not yet been pointed
 * at a Supabase project (missing env vars), this is `null` and the UI shows a
 * "Not configured" screen instead of crashing.
 */
export const supabase: SupabaseClient | null = isConfigured
  ? createClient(config.supabaseUrl!, config.supabaseAnonKey!, {
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

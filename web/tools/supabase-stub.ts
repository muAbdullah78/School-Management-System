/**
 * Stands in for `@/lib/supabase` when the rendering harnesses run.
 *
 * WHY IT EXISTS, AND THE BUG THAT PROVED IT NECESSARY
 *
 * The harness config supplies a placeholder VITE_SUPABASE_URL so that
 * `isConfigured` is true and Dashboard renders the real screen instead of its
 * "Not connected yet" state. But that also made `lib/supabase.ts` call
 * `createClient()` at import time — and supabase-js constructs a RealtimeClient
 * inside it, which looks for a native `WebSocket` and THROWS when there is none.
 *
 * Node 22 has one. Node 20 does not. So the harness passed on my machine and
 * failed every one of its files on the CI runner:
 *
 *     Error: Node.js detected but native WebSocket not found.
 *       ❯ new RealtimeClient
 *       ❯ Module.createClient
 *       ❯ src/lib/supabase.ts:10:5
 *
 * Aliasing the module away is the targeted fix. The alternatives were worse:
 * bumping the runner's Node would hide the same fragility behind a version
 * number, and adding a WebSocket shim to the APP would make production carry
 * weight for a docs build.
 *
 * `supabase` is null and `requireSupabase()` throws, deliberately. Every query
 * the harnesses render is SEEDED into the query cache, so no fetcher ever runs —
 * and if one did, a loud throw naming this file is a far better outcome than a
 * silent request to a placeholder host.
 */
import type { SupabaseClient } from '@supabase/supabase-js'

export const supabase: SupabaseClient | null = null

export function requireSupabase(): SupabaseClient {
  throw new Error(
    'web/tools/supabase-stub.ts: a harness tried to reach the database. The '
    + 'harnesses have no client on purpose — seed the query it needs instead. '
    + 'A harness that could read a real database would render whatever happened '
    + 'to be in it.',
  )
}

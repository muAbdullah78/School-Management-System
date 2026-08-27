/**
 * Config for the RENDERING HARNESSES in web/tools/, which are not tests.
 *
 * They render a printable — a challan, a balance sheet — to an HTML file so the
 * layout can be looked at in a browser. They assert nothing, they write files,
 * and they need `npm run build` to have run first for the stylesheet, so they
 * must never run in CI.
 *
 * WHY A SECOND CONFIG RATHER THAN A FLAG
 *
 * vite.config.ts pins `test.include` to `src/**`, and a CLI file argument
 * FILTERS that list rather than adding to it — so the command previously
 * documented in vite.config.ts ("npx vitest run --dir tools
 * tools/challan-preview.test.tsx") matched nothing and exited 1. It had never
 * worked. This config makes the harnesses genuinely runnable:
 *
 *   npm run harness                       # render every harness
 *   npm run harness -- balance-sheet      # just one
 */
import { defineConfig, mergeConfig } from 'vitest/config'
import { fileURLToPath } from 'node:url'
import base from './vite.config'

const merged = mergeConfig(base, defineConfig({}))

// Assigned AFTER the merge, not inside it: mergeConfig CONCATENATES arrays, so
// merging an include would append to src/** rather than replace it and the
// whole unit suite would run again on every render.
merged.test = {
  ...merged.test,
  include: ['tools/**/*.test.{ts,tsx}'],
  /**
   * A PLACEHOLDER Supabase URL and key, so the app believes it is configured.
   *
   * Without these, `isConfigured` is false and Dashboard renders "Not connected
   * yet — Supabase isn't configured" instead of the screen. Every seeded figure
   * is ignored and the screenshot shows the setup warning, which is not the state
   * anybody wants in a user guide.
   *
   * Nothing is ever fetched from this host: renderToStaticMarkup fires no
   * effects, and every query the harness renders is seeded, so no queryFn runs.
   * The value is deliberately unroutable rather than plausible — a real-looking
   * project URL in a config file is how one ends up committed.
   */
  env: {
    VITE_SUPABASE_URL: 'https://harness.invalid',
    VITE_SUPABASE_ANON_KEY: 'harness-placeholder-not-a-real-key',
  },
}

/**
 * And with `isConfigured` true, `lib/supabase.ts` calls createClient() at import
 * time — which builds a RealtimeClient, which looks for a native WebSocket and
 * THROWS when there is none. Node 22 has one; Node 20 does not. So the two
 * changes together passed locally and failed every harness file on the CI runner.
 *
 * The module is aliased away rather than shimmed. See tools/supabase-stub.ts for
 * why that is the right layer to fix it at.
 *
 * Assigned after the merge for the same reason as `test` above: mergeConfig
 * concatenates, and an alias appended to vite.config's list would not take
 * precedence over the `@` path alias it has to override.
 */
merged.resolve = {
  ...merged.resolve,
  alias: [
    // BOTH specifier forms, because a Vite alias matches the SPECIFIER and not
    // the resolved file. The first version aliased only '@/lib/supabase' and did
    // nothing at all: src/lib/db.ts, platform.ts, licence.ts and photos.ts all
    // import './supabase', so the real module still loaded and the WebSocket
    // throw came back. Proved by deleting globalThis.WebSocket to reproduce
    // Node 20 — see the npm script `harness:node20`.
    {
      find: /^(@\/lib|\.)\/supabase$/,
      replacement: fileURLToPath(new URL('./tools/supabase-stub.ts', import.meta.url)),
    },
    ...(Array.isArray(merged.resolve?.alias) ? merged.resolve.alias : []),
    ...(merged.resolve?.alias && !Array.isArray(merged.resolve.alias)
      ? Object.entries(merged.resolve.alias).map(([find, replacement]) => ({
          find, replacement: replacement as string,
        }))
      : []),
  ],
}

export default merged

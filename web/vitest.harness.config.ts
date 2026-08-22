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
import base from './vite.config'

const merged = mergeConfig(base, defineConfig({}))

// Assigned AFTER the merge, not inside it: mergeConfig CONCATENATES arrays, so
// merging an include would append to src/** rather than replace it and the
// whole unit suite would run again on every render.
merged.test = { ...merged.test, include: ['tools/**/*.test.{ts,tsx}'] }

export default merged

import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'
import { fileURLToPath, URL } from 'node:url'

// https://vitejs.dev/config/
export default defineConfig({
  plugins: [react()],
  resolve: {
    alias: {
      '@': fileURLToPath(new URL('./src', import.meta.url)),
    },
  },
  server: {
    host: true, // expose on the LAN so teacher phones can reach the dev server
    port: 5173,
  },
  test: {
    // `npm test` runs the unit tests under src/ only.
    //
    // web/tools/ holds RENDERING HARNESSES, not tests: they render a printable
    // to an HTML file so it can be looked at in a browser. They assert nothing,
    // they write files, and they need `npm run build` to have run first for the
    // stylesheet — so they must never run in CI. Run one deliberately with:
    //
    //   npm run harness                    (all of them)
    //   npm run harness -- balance-sheet   (just one)
    //
    // A bare `vitest run tools/...` does NOT work: a CLI file argument filters
    // `include` rather than adding to it, so it matches nothing. That is what
    // vitest.harness.config.ts exists for.
    //
    // The challan harness earned its keep immediately: it showed a fully paid
    // slip printing "PAST DUE — PAY IMMEDIATELY", which no assertion about
    // markup would have caught.
    include: ['src/**/*.{test,spec}.{ts,tsx}'],
  },
})

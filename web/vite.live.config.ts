/**
 * THE LIVE PREVIEW: real pages, in a real browser, on invented data.
 *
 *   npx vite --config vite.live.config.ts          then open
 *   http://localhost:5199/?scene=dashboard         (scenes: tools/live/scenes.tsx)
 *
 * The static harnesses (vitest.harness.config.ts) render through
 * renderToStaticMarkup, which runs no effects. That is fine for a printable
 * and wrong for a chart: the charts measure their own width to keep their
 * text at 11px on a phone, and a static render only ever draws the fallback
 * width. This serves the same components with effects running, the query
 * cache seeded from tools/demo-data.ts, and no database client at all.
 *
 * Not built, not deployed, not part of `npm test`. It exists to be looked at.
 */
import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'
import { fileURLToPath, URL } from 'node:url'

export default defineConfig({
  root: fileURLToPath(new URL('./tools/live', import.meta.url)),
  plugins: [react()],
  resolve: {
    alias: [
      // Both specifier forms, for the reason given in vitest.harness.config.ts.
      {
        find: /^(@\/lib|\.)\/supabase$/,
        replacement: fileURLToPath(new URL('./tools/live/fake-client.ts', import.meta.url)),
      },
      { find: '@', replacement: fileURLToPath(new URL('./src', import.meta.url)) },
    ],
  },
  define: {
    // A placeholder, so the app believes it is configured. Nothing is ever
    // fetched from it: the client above is not a client.
    'import.meta.env.VITE_SUPABASE_URL': JSON.stringify('https://harness.invalid'),
    'import.meta.env.VITE_SUPABASE_ANON_KEY': JSON.stringify('harness-placeholder-not-a-real-key'),
  },
  server: { port: 5199, strictPort: true, host: '127.0.0.1' },
})

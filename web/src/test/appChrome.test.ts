/**
 * The three colours a phone paints OUTSIDE the page, and the one rule that
 * keeps them from disagreeing.
 *
 * A school reported dark blue bleeding in at every edge of the app on a phone,
 * at the top, the bottom and the sides, whenever a scroll was dragged past its
 * end. The colour was #4338ca: brand-700, the sidebar's indigo, set as the
 * document's theme-color so the browser would tint its own chrome to match the
 * sidebar. On a desktop that reads well. On a phone the sidebar is off canvas
 * and the browser was tinting the gap with the colour of something that is not
 * on screen.
 *
 * The fix is not a colour, it is an invariant: the browser's chrome and the
 * ground the app sits on are the same value, so there is no seam to see. That
 * invariant lives in two files that cannot import from each other -- a meta tag
 * in index.html and a custom property in index.css -- which is exactly the
 * shape of a rule that gets half-changed a year from now. So it is asserted
 * here instead of trusted to a comment.
 */
import { describe, expect, it } from 'vitest'
import { readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'

const read = (rel: string) => readFileSync(fileURLToPath(new URL(rel, import.meta.url)), 'utf8')
const html = read('../../index.html')
const css = read('../index.css')
const manifest = JSON.parse(read('../../public/manifest.webmanifest')) as Record<string, string>

function hex(s: string | undefined): string {
  expect(s, 'colour not found').toBeTruthy()
  return (s as string).trim().toLowerCase()
}

describe('the colour outside the page', () => {
  const canvas = hex(css.match(/--app-canvas:\s*(#[0-9a-fA-F]{3,8})/)?.[1])
  const theme = hex(html.match(/<meta\s+name="theme-color"\s+content="(#[0-9a-fA-F]{3,8})"/)?.[1])

  it('is one value, spelled the same in the stylesheet and in the document', () => {
    expect(theme).toBe(canvas)
  })

  it('is light, so nothing dark can appear at an edge', () => {
    // Cheap luminance. The test is not trying to judge the shade; it is trying
    // to catch somebody putting the sidebar's indigo back.
    const n = parseInt(canvas.slice(1, 7), 16)
    const [r, g, b] = [(n >> 16) & 255, (n >> 8) & 255, n & 255]
    const lum = (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255
    expect(lum).toBeGreaterThan(0.85)
  })

  it('is painted on the root element as well as the body', () => {
    // The canvas takes the root element's background and only falls back to the
    // body's. Setting one and not the other leaves the decision to the browser.
    expect(css).toMatch(/html\s*\{[^}]*background-color:\s*var\(--app-canvas\)/)
    expect(css).toMatch(/body\s*\{[^}]*background-color:\s*var\(--app-canvas\)/)
  })
})

describe('mobile scroll physics', () => {
  it('does not let a vertical bounce chain out to the document', () => {
    expect(css).toMatch(/html\s*\{[^}]*overscroll-behavior-y:\s*none/)
    expect(css).toMatch(/body\s*\{[^}]*overscroll-behavior-y:\s*none/)
  })

  it('leaves the horizontal axis alone, so swipe-to-go-back still works', () => {
    // The shorthand would take the browser's own back gesture with it, and
    // there is nothing on the x axis to contain: the document does not scroll
    // sideways at any width.
    expect(css).not.toMatch(/overscroll-behavior:\s*none/)
  })

  it('declares a light colour scheme, so a phone in dark mode cannot invert it', () => {
    expect(css).toMatch(/:root\s*\{[^}]*color-scheme:\s*light/)
  })

  it('pins the text size, so turning a phone sideways does not resize the tables', () => {
    expect(css).toContain('-webkit-text-size-adjust: 100%')
  })
})

describe('the installed app', () => {
  it('keeps the brand on the splash and the task switcher', () => {
    // Deliberately NOT the canvas colour. The manifest's theme_color is the
    // vendor's mark on an installed icon and a splash screen, neither of which
    // is ever adjacent to the scrolling page, so there is nothing to bleed.
    expect(manifest.theme_color.toLowerCase()).toBe('#4338ca')
    expect(manifest.background_color.toLowerCase()).toBe('#ffffff')
  })
})

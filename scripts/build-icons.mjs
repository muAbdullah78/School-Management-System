/**
 * Generate every icon from site-src/icon.svg.
 *
 * WHY THIS EXISTS
 *
 * Google was showing a grey globe next to theschoolmanager.site instead of the
 * logo. The cause was not a missing tag. The tag was there:
 *
 *     <link rel="icon" type="image/svg+xml" href="data:image/svg+xml,...">
 *
 * A data: URI is not a URL. Google's favicon crawler fetches the favicon as a
 * separate request from the page, so it needs an address it can ask for. There
 * was nothing to fetch. Google's other route is /favicon.ico at the root of the
 * domain, and that file did not exist either, so both paths dead-ended and the
 * generic globe is what is left.
 *
 * So the icons have to be real files at stable URLs. Generating them from one
 * source is the only way to be sure the tab, the search result, the Android
 * home screen, the iOS home screen and the app itself are the same mark. They
 * were not: the website drew an indigo book and the app drew a blue cap.
 *
 * WHAT GOOGLE ASKS FOR, and what this produces
 *
 *   - A square image whose side is a multiple of 48 (48, 96, 144, 192...).
 *     Google resizes down from it. Anything smaller than 48 it may skip.
 *   - A stable URL. Do not rename these files. If the URL changes, Google has
 *     to recrawl and rediscover before the old icon stops being shown.
 *   - Crawlable: not blocked by robots.txt. site/robots.txt is Allow: /.
 *   - ICO, PNG, SVG, JPEG, GIF or BMP. We ship SVG for the browser, PNG in
 *     48-multiples for Google, and ICO at /favicon.ico as the root fallback.
 *
 * WHY RENDER EACH SIZE RATHER THAN RESIZE ONE
 *
 * The source is vector. Rendering 48 natively gives crisper edges than
 * rendering 512 and shrinking it, and it costs one more screenshot.
 *
 * WHY THE ICO IS WRITTEN BY HAND
 *
 * Node has no ICO encoder in the standard library and this repo takes no new
 * dependencies for a build step. The container format is a 6 byte header, a 16
 * byte directory entry per image, and then the images. PNG data inside an ICO
 * is legal and read by every browser since Vista.
 *
 *     node scripts/build-icons.mjs             (everything)
 *     node scripts/build-icons.mjs --android   (the Android app only)
 *     python3 scripts/check-site-seo.py     # then verify
 */
import { createRequire } from 'node:module'
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs'
import { resolve, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'

const require = createRequire('/opt/node22/lib/node_modules/')
const { chromium } = require('playwright')

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..')
const SRC = resolve(ROOT, 'site-src/icon.svg')
const svg = readFileSync(SRC, 'utf8')

/** Android crops a maskable icon to a circle 80% of the icon's width. Anything
 *  outside that is liable to be cut off, and the tassel sits at 92% of the
 *  width, so it would lose it. The mark is scaled to sit inside the safe area.
 *  The manifest previously declared the same artwork for "any" and "maskable",
 *  which is what put the tassel in the crop zone. */
const MASKABLE_SCALE = 0.74

const browser = await chromium.launch()

/** The Android launcher's adaptive icon is a 108dp canvas the launcher masks
 *  to its own shape, and only a circle 66dp across is sure to survive every
 *  mask. The mark reaches 0.44 of the canvas from its centre (the tassel), so
 *  at 0.56 it sits about 0.25 out: inside 0.31 with room to spare. */
const ADAPTIVE_SCALE = 0.56

const ONLY_ANDROID = process.argv.includes('--android')

async function render(size, { squareOff = false, scale = 1, circle = false, plate = true } = {}) {
  const page = await browser.newPage({
    viewport: { width: size, height: size },
    deviceScaleFactor: 1,
  })
  await page.setContent(
    `<style>html,body{margin:0;padding:0;background:transparent}` +
    `svg{display:block;width:${size}px;height:${size}px}</style>${svg}`
  )
  await page.evaluate(({ squareOff, scale, circle, plate }) => {
    if (squareOff) document.getElementById('plate').setAttribute('rx', '0')
    if (circle) document.getElementById('plate').setAttribute('rx', '256')
    if (!plate) document.getElementById('plate').setAttribute('fill', 'none')
    if (scale !== 1) {
      const mark = document.getElementById('mark')
      const b = mark.getBBox()
      // Scale about the artwork's own centre, then re-centre it in the tile,
      // so the result is centred on the mark rather than on the viewBox.
      const cx = b.x + b.width / 2
      const cy = b.y + b.height / 2
      const dx = 256 - cx
      const dy = 256 - cy
      mark.setAttribute(
        'transform',
        `translate(${256 + dx * scale} ${256 + dy * scale}) scale(${scale}) translate(${-256} ${-256})`
      )
    }
  }, { squareOff, scale, circle, plate })
  const buf = await page.screenshot({ omitBackground: true })
  await page.close()
  return buf
}

/** ICO container. Directory entries must be written in the same order as the
 *  image data that follows them, and each entry's offset is absolute from the
 *  start of the file. A side of 256 is stored as 0; we never emit one. */
function ico(images) {
  const header = Buffer.alloc(6)
  header.writeUInt16LE(0, 0)               // reserved
  header.writeUInt16LE(1, 2)               // 1 = icon
  header.writeUInt16LE(images.length, 4)
  let offset = 6 + images.length * 16
  const entries = []
  for (const { size, data } of images) {
    const e = Buffer.alloc(16)
    e.writeUInt8(size === 256 ? 0 : size, 0)  // width
    e.writeUInt8(size === 256 ? 0 : size, 1)  // height
    e.writeUInt8(0, 2)                        // palette size, 0 for truecolour
    e.writeUInt8(0, 3)                        // reserved
    e.writeUInt16LE(1, 4)                     // colour planes
    e.writeUInt16LE(32, 6)                    // bits per pixel
    e.writeUInt32LE(data.length, 8)
    e.writeUInt32LE(offset, 12)
    offset += data.length
    entries.push(e)
  }
  return Buffer.concat([header, ...entries, ...images.map((i) => i.data)])
}

function write(rel, buf) {
  const p = resolve(ROOT, rel)
  mkdirSync(dirname(p), { recursive: true })
  writeFileSync(p, buf)
  const kb = (buf.length / 1024).toFixed(1)
  console.log(`  ${rel.padEnd(34)} ${String(buf.length).padStart(7)} B  (${kb} KB)`)
}

/** A launch screen: the plate's colour edge to edge, the mark in the middle.
 *  The plate is drawn too, in the same colour, so it disappears into it. */
async function splash(width, height) {
  const page = await browser.newPage({ viewport: { width, height }, deviceScaleFactor: 1 })
  const side = Math.round(Math.min(width, height) * 0.28)
  await page.setContent(
    `<style>html,body{margin:0;height:100%;background:${PLATE}}` +
    `body{display:flex;align-items:center;justify-content:center}` +
    `svg{display:block;width:${side}px;height:${side}px}</style>${svg}`
  )
  const buf = await page.screenshot()
  await page.close()
  return buf
}

const PLATE = (svg.match(/id="plate"[^>]*fill="(#[0-9A-Fa-f]{6})"/) ?? [])[1]
if (!PLATE) throw new Error('site-src/icon.svg: the plate has no #rrggbb fill to colour the Android icon with')

/**
 * THE ANDROID APP (mobile/android). The launcher icon at every density, the
 * round icon older launchers ask for, the adaptive icon's two layers (the mark
 * on a transparent canvas, over the plate's colour), and the launch screen the
 * phone shows while the app starts. Capacitor's template ships its own logo in
 * every one of these slots, so nothing of ours appeared until this ran.
 */
async function android() {
  const RES = 'mobile/android/app/src/main/res'
  const DENSITIES = [['mdpi', 1], ['hdpi', 1.5], ['xhdpi', 2], ['xxhdpi', 3], ['xxxhdpi', 4]]
  for (const [d, k] of DENSITIES) {
    write(`${RES}/mipmap-${d}/ic_launcher.png`, await render(48 * k))
    write(`${RES}/mipmap-${d}/ic_launcher_round.png`, await render(48 * k, { circle: true, scale: MASKABLE_SCALE }))
    write(`${RES}/mipmap-${d}/ic_launcher_foreground.png`, await render(108 * k, { plate: false, scale: ADAPTIVE_SCALE }))
  }
  write(`${RES}/values/ic_launcher_background.xml`, Buffer.from(
    `<?xml version="1.0" encoding="utf-8"?>\n<resources>\n    <color name="ic_launcher_background">${PLATE}</color>\n</resources>\n`))
  const SPLASH = [
    ['drawable', 480, 320],
    ['drawable-land-mdpi', 480, 320], ['drawable-land-hdpi', 800, 480], ['drawable-land-xhdpi', 1280, 720],
    ['drawable-land-xxhdpi', 1600, 960], ['drawable-land-xxxhdpi', 1920, 1280],
    ['drawable-port-mdpi', 320, 480], ['drawable-port-hdpi', 480, 800], ['drawable-port-xhdpi', 720, 1280],
    ['drawable-port-xxhdpi', 960, 1600], ['drawable-port-xxxhdpi', 1280, 1920],
  ]
  for (const [dir, w, h] of SPLASH) write(`${RES}/${dir}/splash.png`, await splash(w, h))
}

if (ONLY_ANDROID) {
  console.log('from site-src/icon.svg, the Android app only:')
  await android()
  await browser.close()
  process.exit(0)
}

console.log('from site-src/icon.svg:')

// The website. Multiples of 48 because that is what Google asks for.
const png48 = await render(48)
const png96 = await render(96)
const png192 = await render(192)
const png512 = await render(512)
// iOS applies its own rounding and composites on black, so a transparent
// corner shows up as a black corner. Square plate, no transparency.
const apple = await render(180, { squareOff: true })
const maskable = await render(512, { squareOff: true, scale: MASKABLE_SCALE })

const icoBuf = ico([
  { size: 16, data: await render(16) },
  { size: 32, data: await render(32) },
  { size: 48, data: png48 },
])

const svgBuf = Buffer.from(svg, 'utf8')

for (const dir of ['site', 'web/public']) {
  write(`${dir}/icon.svg`, svgBuf)
  write(`${dir}/favicon.ico`, icoBuf)
  write(`${dir}/icon-192.png`, png192)
  write(`${dir}/icon-512.png`, png512)
  write(`${dir}/icon-maskable-512.png`, maskable)
  write(`${dir}/apple-touch-icon.png`, apple)
}
// Only the website needs these two: Google reads the page's link tags, and the
// app is not indexed at all.
write('site/icon-48.png', png48)
write('site/icon-96.png', png96)
await android()

await browser.close()
console.log('\nDone. site/favicon.ico carries 16, 32 and 48.')

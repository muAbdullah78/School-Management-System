/**
 * THE ICON SHEET, and the reason it exists is that an icon is the one thing in
 * this codebase that cannot be checked by reading it.
 *
 * A path like `M5 21v-6a2 2 0 0 1 2-2h10a2 2 0 0 1 2 2v6` is either a cake or
 * a filing cabinet and the source does not say which. Two of the sidebar's
 * rows shipped with NO icon at all and two more shipped with the SAME icon,
 * and both got through because nobody looked at the set together. This renders
 * every glyph twice: once at 96px, where the drawing can be judged, and once
 * at the size and on the colour it is actually drawn at in the sidebar, where
 * legibility can be judged. Those are different questions and a sheet that
 * answers only the first is the reason the drawer looked fine as a wallet.
 *
 * Excluded from `npm test`; run with `npm run harness`.
 */
import { it } from 'vitest'
import * as icons from '../src/components/icons'
import { NAV } from '../src/navigation'
import { writePage } from './harness'

const GLYPHS = Object.entries(icons).filter(
  ([name, v]) => name.startsWith('Icon') && typeof v === 'function',
) as [string, (p: { className?: string }) => JSX.Element][]

/** path -> label, so the sheet says which sidebar row each glyph serves. */
const LABEL: Record<string, string> = Object.fromEntries(
  NAV.map((n) => [n.path, n.label]),
)

function usedBy(name: string): string {
  const paths = Object.entries(icons.NAV_ICONS)
    .filter(([, fn]) => (fn as unknown) === (icons as Record<string, unknown>)[name])
    .map(([p]) => LABEL[p] ?? p)
  return paths.length ? paths.join(' + ') : 'not in the sidebar'
}

it('writes the icon sheet', () => {
  writePage('../scratch/icons.html', [
    {
      caption:
        'Large, for judging the drawing. Each glyph is captioned with the '
        + 'sidebar row it serves, so a duplicate reads as a duplicate.',
      node: (
        <div style={{ display: 'flex', flexWrap: 'wrap', gap: '1.5rem' }}>
          {GLYPHS.map(([name, Icon]) => (
            <div key={name} style={{ width: '150px', textAlign: 'center' }}>
              <div style={{ color: '#0f172a', fontSize: '96px', lineHeight: 1 }}>
                <Icon className="h-[1em] w-[1em]" />
              </div>
              <div style={{ font: '600 12px/1.4 system-ui', marginTop: '.5rem' }}>
                {name.replace('Icon', '')}
              </div>
              <div style={{ font: '11px/1.4 system-ui', color: '#64748b' }}>
                {usedBy(name)}
              </div>
            </div>
          ))}
        </div>
      ),
    },
    {
      caption:
        'The sidebar itself, at the real size and on the real colour: every '
        + 'row of NAV in order, as an owner sees it.',
      node: (
        <div style={{ background: '#1e3a5f', padding: '.5rem', width: '260px', borderRadius: '.5rem' }}>
          {NAV.map((item) => {
            const Icon = icons.NAV_ICONS[item.path]
            return (
              <div
                key={item.path}
                className="group flex items-center gap-3 rounded-lg px-3 py-2 text-sm text-brand-100/75"
              >
                <span className="flex h-7 w-7 shrink-0 items-center justify-center rounded-lg bg-white/5 text-brand-200/80">
                  {Icon ? <Icon /> : null}
                </span>
                <span className="truncate">{item.label}</span>
              </div>
            )
          })}
        </div>
      ),
    },
  ], { bodyStyle: 'background:#f8fafc;padding:2rem' })
})

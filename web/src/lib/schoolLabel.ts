/**
 * Fitting a real school's own name into a small label, safely.
 *
 * The signup form echoes what the owner types into the product mockup beside
 * it, so the first thing they see is their own school inside the software. That
 * is worth doing and it is easy to get wrong in three ways, all of which show
 * up on real names rather than on test data.
 *
 * 1. TRUNCATION BY GRAPHEME CLUSTER, never by string index. `name.slice(0, 28)`
 *    cuts an Urdu name or an emoji through the middle of a surrogate pair and
 *    renders the replacement glyph on the buyer's own school name. Intl.Segmenter
 *    where the engine has it, code points where it does not, string indices
 *    never.
 *
 * 2. ARABIC SCRIPT NEEDS A DIFFERENT FONT AND NO TRACKING. Letter-spacing
 *    applied to a connected script pulls the joins apart and destroys the
 *    letterforms. An owner typing in Urdu is the normal case here, not an edge
 *    case, so the caller is told which script it got and sets lang and dir to
 *    match, letting the browser shape it and pick the base direction.
 *
 * 3. SIZE STEPS DOWN, it does not shrink to fit. A size recomputed on every
 *    keystroke reads as a glitch rather than as a response.
 *
 * This is a plain module rather than a component so it can be reasoned about
 * and reused without rendering anything.
 */

/* Intl.Segmenter is not in the ES2021 lib this project compiles against, and
   the tsconfig is not ours to change, so it is reached through a narrow local
   type rather than a cast to any. */
type SegmenterCtor = new (
  locales?: string | string[],
  options?: { granularity?: 'grapheme' | 'word' | 'sentence' },
) => { segment(input: string): Iterable<{ segment: string }> }

const Segmenter = (Intl as unknown as { Segmenter?: SegmenterCtor }).Segmenter

/** Grapheme clusters where the engine can, code points where it cannot. */
export function clusters(input: string): string[] {
  if (Segmenter) {
    try {
      const seg = new Segmenter(undefined, { granularity: 'grapheme' })
      return Array.from(seg.segment(input), (part) => part.segment)
    } catch {
      // Fall through to code points rather than to string indices.
    }
  }
  return Array.from(input)
}

/* Arabic, Persian and Urdu script, including the presentation-form blocks that
   older Windows keyboards and pasted text still produce. */
const ARABIC_SCRIPT = /[\u0600-\u06FF\u0750-\u077F\u08A0-\u08FF\uFB50-\uFDFF\uFE70-\uFEFF]/

const NASTALIQ =
  "'Noto Nastaliq Urdu', 'Jameel Noori Nastaleeq', 'Urdu Typesetting', 'Noto Naskh Arabic', 'Segoe UI', Tahoma, sans-serif"

export type SchoolLabel = {
  /** What to render. Never longer than `max` clusters, plus an ellipsis. */
  text: string
  /** True when the text is Arabic script, so the caller sets dir and lang. */
  rtl: boolean
  /** Font size in px, stepped by length rather than fitted. */
  size: number
  /** Inline style: the right family, and no tracking on a connected script. */
  style: { fontFamily?: string; letterSpacing: string }
}

/**
 * @param name  raw field value, untrimmed
 * @param fallback  what to show while the field is empty
 * @param max  cluster budget for the space the label has
 */
export function schoolLabel(name: string, fallback: string, max = 28): SchoolLabel {
  const raw = name.trim()
  const source = raw === '' ? fallback : raw
  const parts = clusters(source)
  const text = parts.length > max ? parts.slice(0, max).join('') + '…' : source
  const rtl = ARABIC_SCRIPT.test(text)
  return {
    text,
    rtl,
    size: parts.length < 18 ? 13 : parts.length < 24 ? 12 : 11,
    style: rtl
      ? { fontFamily: NASTALIQ, letterSpacing: 'normal' }
      : { letterSpacing: '-0.01em' },
  }
}

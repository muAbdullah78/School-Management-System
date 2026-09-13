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

/* ------------------------------------------------------- fitting a big box --
   schoolLabel above fits a name into a SMALL, ONE LINE label on the signup
   mockup, and it does it by cutting the name at a cluster budget. That is the
   right answer there: the mockup is a picture of the software, and a picture
   may be a sketch.

   The sidebar is not a picture. It is the school's own identity inside the
   software they bought, and a name cut off with an ellipsis there reads as the
   product being broken rather than as the name being long. "Government Girls
   Higher Secondary School Chaklala" is forty nine characters and it is an
   entirely ordinary name in this market.

   So this one never chooses a size and then cuts to fit. It walks a ladder of
   (size, lines) steps and picks the FIRST step the whole name fits into, which
   means a short name keeps the full 14px and only a genuinely long one pays
   for its length. The ellipsis at the bottom of the ladder exists for input
   that is not a school name at all. */

/**
 * Average advance of one character as a fraction of the font size, for
 * system-ui at weight 600, mixed case Latin.
 *
 * This is an estimate and it is deliberately a pessimistic one. The browser
 * does the real measuring; all this has to do is choose a step that will not
 * overflow, and a step that leaves a little room spare is invisible while a
 * step that is one character short is a clipped school name.
 */
const ADVANCE = 0.54

/**
 * Word wrapping never fills a line to its last pixel: the break happens at the
 * last space that fits, so some of every line is empty. Measured across the
 * school names in docs/ this sits around 0.88 for two lines and lower for
 * three, so 0.85 is used throughout.
 */
const WRAP = 0.85

/** How many clusters of `size` px text fit on `lines` lines of a `box` px box. */
export function capacity(box: number, size: number, lines: number): number {
  const perLine = box / (size * ADVANCE)
  // The wrap allowance is subtracted only where there is wrapping. Charging it
  // to the one line case as well was a real error and it showed: "Iqra Model
  // School" is seventeen characters and about 124px wide at 14px, it fits a
  // 142px box with room to spare, and it was being sent to two lines by an
  // allowance for a line break that does not exist.
  return Math.floor(lines === 1 ? perLine : perLine * WRAP * lines)
}

/**
 * The ladder, widest and loudest first. Every step is tried in order and the
 * first one that holds the whole name wins.
 *
 * It stops at 11px and three lines because below that the name stops being
 * legible on a laptop screen, and past three lines the header pushes the
 * modules themselves down the sidebar. At that point clipping with a tooltip
 * is the honest answer and the last step does exactly that.
 */
const LADDER: ReadonlyArray<{ size: number; lines: number }> = [
  { size: 14, lines: 1 },
  { size: 14, lines: 2 },
  { size: 13, lines: 2 },
  { size: 12, lines: 3 },
  { size: 11, lines: 3 },
]

/** The tallest step on the ladder, so a caller's line clamp cannot disagree. */
export const FIT_MAX_LINES = LADDER.reduce((n, s) => Math.max(n, s.lines), 1)

export type FittedName = {
  /** What to render. The whole name unless it did not fit the last step. */
  text: string
  /** True when the name is Arabic script, so the caller sets dir and lang. */
  rtl: boolean
  /** Font size in px. */
  size: number
  /** Lines the chosen step needs. Never more than FIT_MAX_LINES. */
  lines: number
  /** True when `text` was cut, so the caller knows a tooltip is load bearing. */
  clipped: boolean
  /** Inline style: the right family, and no tracking on a connected script. */
  style: { fontFamily?: string; letterSpacing: string }
}

/**
 * Fit a school's own name into a box `box` pixels wide.
 *
 * @param name      the school's name, untrimmed
 * @param fallback  what to show while it is empty
 * @param box       usable text width in px, excluding the logo and the padding
 */
export function fitSchoolName(name: string, fallback: string, box = 172): FittedName {
  const raw = name.trim()
  const source = raw === '' ? fallback : raw
  const parts = clusters(source)
  const step = LADDER.find((s) => parts.length <= capacity(box, s.size, s.lines))
    ?? LADDER[LADDER.length - 1]
  const room = capacity(box, step.size, step.lines)
  const clipped = parts.length > room
  const text = clipped ? parts.slice(0, Math.max(1, room - 1)).join('').trimEnd() + '…' : source
  const rtl = ARABIC_SCRIPT.test(text)
  return {
    text,
    rtl,
    size: step.size,
    lines: step.lines,
    clipped,
    style: rtl
      ? { fontFamily: NASTALIQ, letterSpacing: 'normal' }
      : { letterSpacing: '-0.01em' },
  }
}

/**
 * The gate board: the school's own name, echoed onto a drawn signboard as the
 * owner types it into the first field of the signup form.
 *
 * WHY THIS AND NOTHING ELSE. It is the only conversion mechanic in the whole
 * auth design, and it is honest proof rather than a claim, because the only
 * thing it shows is the buyer's own input. It fires on field one of a six field
 * form, which is where the drop-off is. There is no invented school anywhere on
 * these screens, and deliberately no "EST. 1998" line under the name: that
 * would be a fabricated statement about a real school.
 *
 * FOUR THINGS THAT ARE EASY TO GET WRONG AND ALL BREAK ON A REAL NAME.
 *
 * 1. The echoed name is HTML text positioned over the SVG, not an SVG <text>
 *    node. SVG text does not wrap, so "Government Girls Higher Secondary
 *    School" would run straight off the board.
 *
 * 2. Letter-spacing is dropped and the Latin stack swapped when the input is in
 *    Arabic script. Tracking applied to a connected script pulls the joins
 *    apart and destroys the letterforms, and an owner typing in Urdu is the
 *    normal case here, not an edge case. lang and dir are set to match, so the
 *    browser picks the right shaping and the right base direction.
 *
 * 3. Truncation is by GRAPHEME CLUSTER, via Intl.Segmenter with a code-point
 *    fallback, never by JS string index. `name.slice(0, 34)` cuts an Urdu name
 *    or an emoji through the middle of a surrogate pair and renders the
 *    replacement glyph on the buyer's own school name.
 *
 * 4. The size steps down by length instead of shrinking to fit, so the board
 *    never reflows on every keystroke.
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
function clusters(input: string): string[] {
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

const MAX_CLUSTERS = 34

const NASTALIQ =
  "'Noto Nastaliq Urdu', 'Jameel Noori Nastaleeq', 'Urdu Typesetting', 'Noto Naskh Arabic', 'Segoe UI', Tahoma, sans-serif"

export function GateBoard({ name }: { name: string }) {
  const raw = name.trim()
  const parts = clusters(raw)
  const shown = parts.length > MAX_CLUSTERS ? parts.slice(0, MAX_CLUSTERS).join('') + '…' : raw
  const rtl = ARABIC_SCRIPT.test(shown)

  // Steps, not a fit: a size that changes on every keystroke reads as a glitch.
  const size = parts.length < 16 ? 22 : parts.length < 22 ? 18 : 15

  return (
    // Capped rather than overhanging. The board was drawn to overhang the panel
    // by 160px so it read as continuing past the screen, and rendered at 1280px
    // that made it about 980px wide, at which scale the piers and railings read
    // as architecture and the SIGN, which is the only thing this object exists to
    // say, stopped being the subject. Left aligned rather than centred so it
    // still sits in a scene instead of reading as a logo.
    <div aria-hidden="true" className="w-full max-w-[600px]">
      <div className="relative">
        <svg viewBox="0 0 520 248" className="block h-auto w-full" role="presentation">
          {/* piers */}
          <rect x="8" y="60" width="54" height="180" fill="#FFFFFF" stroke="#8A8271" strokeWidth="1.5" />
          <rect x="458" y="60" width="54" height="180" fill="#FFFFFF" stroke="#8A8271" strokeWidth="1.5" />
          <line x1="8" y1="96" x2="62" y2="96" stroke="#C6BEA9" strokeWidth="1" />
          <line x1="458" y1="96" x2="512" y2="96" stroke="#C6BEA9" strokeWidth="1" />
          <line x1="8" y1="228" x2="62" y2="228" stroke="#C6BEA9" strokeWidth="1" />
          <line x1="458" y1="228" x2="512" y2="228" stroke="#C6BEA9" strokeWidth="1" />

          {/* the signboard the name is printed on */}
          <rect x="24" y="14" width="472" height="92" fill="#FFFFFF" stroke="#8A8271" strokeWidth="1.5" />
          <line x1="36" y1="26" x2="484" y2="26" stroke="#C6BEA9" strokeWidth="1" />
          <line x1="36" y1="94" x2="484" y2="94" stroke="#C6BEA9" strokeWidth="1" />

          {/* the gate itself, drawn open */}
          <g stroke="#8A8271" strokeWidth="1.5" fill="none">
            <line x1="62" y1="130" x2="240" y2="130" />
            <line x1="280" y1="130" x2="458" y2="130" />
            <line x1="62" y1="240" x2="240" y2="240" />
            <line x1="280" y1="240" x2="458" y2="240" />
          </g>
          <g stroke="#C6BEA9" strokeWidth="1">
            {[86, 110, 134, 158, 182, 206, 230].map((x) => (
              <line key={`l${x}`} x1={x} y1="130" x2={x} y2="240" />
            ))}
            {[290, 314, 338, 362, 386, 410, 434].map((x) => (
              <line key={`r${x}`} x1={x} y1="130" x2={x} y2="240" />
            ))}
          </g>
        </svg>

        {/* The name, in HTML so it wraps. Positioned to the signboard rect:
            x 24..496 of 520 is 4.6 percent each side, y 14..106 of 248 is
            5.65 percent down and 37.1 percent tall. */}
        <div
          className="absolute flex items-center justify-center overflow-hidden px-4 text-center"
          style={{ left: '4.6%', right: '4.6%', top: '5.65%', height: '37.1%' }}
        >
          {shown ? (
            <span
              lang={rtl ? 'ur' : 'en'}
              dir={rtl ? 'rtl' : 'ltr'}
              className="font-bold text-[#14171C]"
              style={{
                fontSize: `${size}px`,
                lineHeight: 1.22,
                // Tracking is dropped entirely for connected scripts.
                letterSpacing: rtl ? 'normal' : '0.04em',
                fontFamily: rtl ? NASTALIQ : undefined,
                textTransform: rtl ? 'none' : 'uppercase',
                wordBreak: 'break-word',
              }}
            >
              {shown}
            </span>
          ) : (
            <span // slate-500, not slate-400. This placeholder sits on the white signboard
              // and measured 2.56:1, and it is the first thing anybody sees on the
              // most important page in the product. slate-500 is 4.76:1 and still
              // reads as an empty board rather than a filled one.
              className="text-[15px] font-medium tracking-[0.04em] text-slate-500">
              Your school name here
            </span>
          )}
        </div>
      </div>
    </div>
  )
}

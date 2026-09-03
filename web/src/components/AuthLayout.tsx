import type { ReactNode } from 'react'
import { config } from '@/lib/config'

/**
 * The frame around every screen a visitor sees BEFORE they are signed in:
 * /login, /signup, /forgot and /reset.
 *
 * WHY THIS IS A COMPONENT AND NOT FOUR FIXES. All four pages opened with the
 * identical `flex h-full items-center justify-center bg-slate-100 p-4` wrapped
 * around a `w-full max-w-sm rounded-lg bg-white p-6 shadow`, which is what
 * produced the complaint: an isolated white box on a large empty grey field.
 * Repairing four copies of the same wrapper guarantees they drift apart on the
 * next change, so the wrapper now exists once.
 *
 * THE SITE OWNS THE FRAME, THE APP OWNS THE CONTROLS.
 *
 * The marketing site is warm printed stock. The app interior is Tailwind indigo
 * and is not being restyled. The seam between the two is therefore placed
 * deliberately at the moment of signing in: the left panel speaks in the site's
 * institutional voice, and every interactive element in the form column keeps
 * the app's own classes, its border-slate-300 inputs, its indigo focus ring and
 * its brand-600 primary button. By the time the visitor presses submit their
 * hands have already been in the dashboard's controls, so the dashboard is a
 * continuation rather than a jump.
 *
 * WHY THE GRID IS CAPPED AT 1440px. The app's AppShell sidebar is w-64, which
 * is 256px, about 13 percent of a 1920px screen. An uncapped 1fr panel would be
 * 76 percent of the viewport and the continuity claim would be false in
 * proportion. Capped and centred, the dark panel reads as the same kind of
 * object as the sidebar it hands over to.
 *
 * BELOW 900px the panel is not a column at all. It collapses to a header strip
 * and the form runs down the white beneath it, with no card in either case.
 * Most signups happen on a phone, so the device with the most signups has
 * almost no seam left to get wrong.
 */

/* --------------------------------------------------------------- controls --
   Exported so all four pages share one definition of a field, a label and a
   button. These are the app's verbatim classes with three bugs fixed, all of
   which were bugs independently of how the page looked.

   MIN-HEIGHT 44px. The old fields came out at about 36px, which is a mis-tap
   for an office working with a mouse on one machine and a phone on another.

   text-base UNCONDITIONALLY, never text-sm and never an sm: variant of it.
   Anything that resolves to 14px triggers iOS Safari's automatic zoom on focus,
   so the viewport jerks on every field of the highest-intent page in the
   product. A `sm:text-sm` would reintroduce exactly that on iPadOS Safari in
   both orientations, which is the device a principal hands to a clerk.

   THE BORDER, and a correction. This said border-slate-300 was the floor for
   WCAG 1.4.11, and it is not: #CBD5E1 on white measures 1.48:1 against the 3:1
   the criterion requires for the boundary of a control. With the card gone the
   field sits directly on white, so the border is the only thing that says
   "this is where you type", and a comment asserting compliance is worse than
   no comment because it stops the next person measuring.

   slate-500 #64748B measures 4.76:1 on white and still reads as a quiet field
   rather than a heavy one. */
export const authField =
  'mt-1.5 block min-h-[44px] w-full rounded border border-slate-500 px-3 py-2.5 ' +
  'text-base text-slate-900 placeholder:text-slate-400 ' +
  'focus:border-brand-500 focus:outline-none focus:ring-1 focus:ring-brand-500'

export const authLabel = 'text-sm font-medium text-slate-700'

export const authHint = 'mt-1.5 block text-sm text-slate-500'

/** The app's primary button, verbatim brand-600, at a real tap target. */
export const authButton =
  'flex min-h-[44px] w-full items-center justify-center gap-2 rounded bg-brand-600 ' +
  'px-4 py-2.5 text-base font-medium text-white hover:bg-brand-700 ' +
  'focus:outline-none focus-visible:ring-2 focus-visible:ring-brand-500 focus-visible:ring-offset-2 ' +
  // NOT disabled:opacity-60. Every page swaps the label to live status text
  // while busy ("Signing in", "Creating your school"), and dimming the whole
  // button took that text to 2.79:1 at exactly the moment it matters most.
  // A slightly lighter fill says "working" without hiding the word.
  'disabled:bg-brand-500 disabled:opacity-100 disabled:cursor-progress'

/** Same shape, for the places where the action is a link rather than a submit. */
export const authButtonLink = `${authButton} text-center no-underline`

/**
 * A drawn arc, beside the label rather than instead of it.
 *
 * The busy state used to be a change of button text only, which is invisible to
 * anybody not reading the button and says nothing to a screen reader. The
 * buttons that use this also carry aria-busy.
 */
export function AuthSpinner() {
  return (
    <svg
      aria-hidden="true"
      viewBox="0 0 20 20"
      className="h-[18px] w-[18px] shrink-0 animate-spin motion-reduce:animate-none"
      fill="none"
    >
      <circle cx="10" cy="10" r="8" stroke="currentColor" strokeOpacity="0.35" strokeWidth="2.5" />
      <path
        d="M10 2a8 8 0 0 1 8 8"
        stroke="currentColor"
        strokeWidth="2.5"
        strokeLinecap="round"
      />
    </svg>
  )
}

/**
 * An error as a marginal note, not red text floating under a field.
 *
 * role="alert" because the message usually arrives after a network round trip,
 * by which time focus has left the button and nothing would otherwise announce
 * it. The colour is the product's danger-700, which is the only red in the
 * palette permitted on text.
 */
export function AuthError({ children }: { children: ReactNode }) {
  return (
    <p
      role="alert"
      className="rounded-r border border-l-[3px] border-danger-100 border-l-danger-700 bg-danger-50 py-2.5 pl-3 pr-3 text-sm text-danger-700"
    >
      {children}
    </p>
  )
}

/**
 * A good outcome, in the same shape as AuthError so the two read as one system.
 * Kept in the product's money palette, which already means "this went through"
 * everywhere else in the app.
 */
export function AuthNotice({
  tone = 'money',
  children,
}: {
  tone?: 'money' | 'due'
  children: ReactNode
}) {
  const skin =
    tone === 'money'
      ? 'border-money-100 border-l-money-700 bg-money-50 text-money-800'
      : 'border-due-100 border-l-due-700 bg-due-50 text-due-800'
  return (
    // role="status" so a good outcome is ANNOUNCED. AuthError has carried
    // role="alert" since it was written and this had nothing, so every
    // successful outcome on these four screens was silent to a screen reader:
    // the form simply stopped responding as far as the user could tell.
    // "status" rather than "alert" because it is polite news, not an error.
    <p
      role="status"
      className={`rounded-r border border-l-[3px] py-2.5 pl-3 pr-3 text-sm ${skin}`}
    >
      {children}
    </p>
  )
}

/**
 * The busy announcement, for the moment between pressing submit and anything
 * visible happening.
 *
 * Submitting sets disabled on the button, and a disabled element cannot hold
 * focus, so the browser drops focus to <body>. aria-busy on that same button is
 * then attached to something the user is no longer on, and nothing is spoken at
 * all. Measured in a fixture: activeElement went from BUTTON to BODY the moment
 * disabled flipped. So the status lives outside the button, in its own polite
 * live region that is present before the text arrives.
 */
export function AuthBusy({ label }: { label: string | null }) {
  return (
    <p role="status" aria-live="polite" className="sr-only">
      {label ?? ''}
    </p>
  )
}

/* ------------------------------------------------------------------ panel -- */

/** The site's ledger ruling: hairlines at the pitch of an account book. */
const ledger = {
  backgroundImage:
    'repeating-linear-gradient(to bottom,' +
    ' rgba(255,255,255,0.055) 0, rgba(255,255,255,0.055) 1px,' +
    ' transparent 1px, transparent 30px)',
}

function Seal() {
  return (
    <span
      aria-hidden="true"
      className="flex h-10 w-10 shrink-0 items-center justify-center rounded-xl bg-white/10 text-base font-bold text-white ring-1 ring-brand-400/60"
    >
      S
    </span>
  )
}

function BackToSite() {
  return (
    <a
      href={config.siteUrl}
      className="inline-flex min-h-[24px] items-center gap-1.5 text-[13px] text-brand-200/85 underline-offset-2 hover:text-white hover:underline"
    >
      <svg aria-hidden="true" viewBox="0 0 16 16" className="h-3.5 w-3.5" fill="none">
        <path
          d="M9.5 3.5 5 8l4.5 4.5"
          stroke="currentColor"
          strokeWidth="1.6"
          strokeLinecap="round"
          strokeLinejoin="round"
        />
      </svg>
      Back to the website
    </a>
  )
}

/** Three facts in tabular figures, and nothing else. */
function SpecStrip() {
  const cells: Array<[string, ReactNode]> = [
    ['From', <>Rs 950<small className="ml-1 text-sm font-medium text-brand-200/70">/month</small></>],
    ['Trial', <>14 days</>],
    ['Modules', <>All included</>],
  ]
  return (
    <dl className="mt-10 grid grid-cols-3 border-t border-white/[0.16] pt-5">
      {cells.map(([k, v], i) => (
        <div key={k} className={i === 0 ? 'pr-4' : 'border-l border-white/[0.16] pl-4 pr-4'}>
          <dt className="text-[11px] font-bold uppercase tracking-[0.08em] text-brand-200/70">
            {k}
          </dt>
          <dd className="mt-1 text-[17px] font-bold leading-tight tabular-nums lining-nums text-white">
            {v}
          </dd>
        </div>
      ))}
    </dl>
  )
}

export type AuthLayoutProps = {
  /** One line of institutional copy. One line, not a feature list. */
  line: string
  /**
   * The drawn document for this page, at rest. It is deliberately allowed to
   * overhang the panel so it reads as continuing past the screen.
   */
  artefact?: ReactNode
  /** The form column. No card: there is nothing left to be isolated. */
  children: ReactNode
}

export function AuthLayout({ line, artefact, children }: AuthLayoutProps) {
  return (
    <div
      className={
        // Flex rather than a block with mx-auto, so the capped grid inherits a
        // definite height and the dark panel reaches the bottom of the viewport.
        // A percentage min-height on a child of an auto-height block resolves to
        // nothing, which is how a full-height panel ends up half-height.
        'flex min-h-full justify-center bg-white ' +
        // Beyond the 1440px cap the two grounds have to carry on, or the panel
        // floats as a dark slab on white. The seam sits at the viewport centre,
        // which is always hidden behind the opaque panel.
        'min-[900px]:bg-[linear-gradient(to_right,#1E1B4B_50%,#ffffff_50%)]'
      }
    >
      <div className="w-full max-w-[1440px] min-[900px]:grid min-[900px]:grid-cols-[1fr_460px]">
        {/* ---------------------------------------------------------- panel --
            A column at 900px and above, a header strip below it. Flat
            bg-brand-950, no gradient: the gradient belongs to the sidebar, and
            repeating it here would make the two surfaces compete. */}
        <aside
          style={ledger}
          className="relative flex min-h-[112px] flex-col overflow-hidden bg-brand-950 px-6 py-6 min-[900px]:px-12 min-[900px]:py-11"
        >
          <div className="flex items-center gap-3">
            <Seal />
            <div className="min-w-0">
              <div className="truncate text-[15px] font-semibold leading-tight text-white">
                School Manager
              </div>
              <div className="mt-0.5">
                <BackToSite />
              </div>
            </div>
          </div>

          <p className="mt-5 max-w-[26ch] text-[1.35rem] font-semibold leading-[1.18] tracking-[-0.015em] text-white min-[900px]:mt-9 min-[900px]:text-[1.6rem]">
            {line}
          </p>

          {/* The spec strip's three facts, collapsed to one line, because below
              900px the strip itself is gone and the price is the one fact that
              has to survive the collapse. */}
          <p className="mt-3 text-[12px] tabular-nums lining-nums text-brand-200/75 min-[900px]:hidden">
            From Rs 950 a month. 14 days free. All modules included.
          </p>

          {artefact ? (
            <div className="hidden min-[900px]:mt-11 min-[900px]:block min-[900px]:flex-1">
              {artefact}
            </div>
          ) : null}

          <div className="hidden min-[900px]:block">
            <SpecStrip />
          </div>
        </aside>

        {/* ----------------------------------------------------------- form --
            Plain white, not slate-100, with the form sitting directly on it.
            The card, its border, its radius and its shadow are all deleted, and
            that deletion is the specific thing that stops the page reading as
            an isolated box. */}
        <main className="flex items-center justify-center bg-white px-6 py-12 min-[900px]:px-14">
          <div className="w-full max-w-[380px]">{children}</div>
        </main>
      </div>
    </div>
  )
}

/**
 * The fee receipt, reduced to its header and its total.
 *
 * Ink on white with rules for structure, never a brand fill, exactly as
 * ChallanPrint.tsx and the marketing site's drawn documents do it, so the object
 * photocopies the way the real one does. It overhangs the panel by 160px at every
 * width, so it is always cropped and never sits centred like an illustration.
 *
 * Used on /login, /forgot and /reset. Recovery is a Login that went wrong, and
 * it should feel identical rather than announcing itself as a different place.
 */
export function ReceiptArtefact() {
  return (
    <div aria-hidden="true" className="w-[calc(100%+160px)]">
      <div className="rounded-sm bg-white shadow-[4px_4px_0_0_rgba(0,0,0,0.22)]">
        <svg viewBox="0 0 520 208" className="block h-auto w-full" role="presentation">
          {/* header */}
          <text x="24" y="34" fill="#14171C" fontSize="15" fontWeight="700" letterSpacing="0.02em">
            FEE RECEIPT
          </text>
          <text x="24" y="55" fill="#545965" fontSize="11.5" letterSpacing="0.06em">
            OFFICE COPY
          </text>
          <text
            x="496"
            y="34"
            fill="#14171C"
            fontSize="13"
            fontWeight="700"
            textAnchor="end"
            style={{ fontVariantNumeric: 'tabular-nums lining-nums' }}
          >
            No. 1043
          </text>
          <line x1="24" y1="70" x2="496" y2="70" stroke="#8A8271" strokeWidth="1.5" />

          {/* two ruled body lines, drawn empty: the receipt is at rest */}
          <line x1="24" y1="102" x2="360" y2="102" stroke="#C6BEA9" strokeWidth="1" />
          <line x1="24" y1="130" x2="360" y2="130" stroke="#C6BEA9" strokeWidth="1" />
          <line x1="400" y1="102" x2="496" y2="102" stroke="#C6BEA9" strokeWidth="1" />
          <line x1="400" y1="130" x2="496" y2="130" stroke="#C6BEA9" strokeWidth="1" />

          {/* total */}
          <line x1="24" y1="156" x2="496" y2="156" stroke="#8A8271" strokeWidth="1.5" />
          <text x="24" y="184" fill="#545965" fontSize="11.5" fontWeight="700" letterSpacing="0.08em">
            TOTAL RECEIVED
          </text>
          <text
            x="496"
            y="187"
            fill="#14171C"
            fontSize="22"
            fontWeight="700"
            textAnchor="end"
            style={{ fontVariantNumeric: 'tabular-nums lining-nums' }}
          >
            Rs 5,800
          </text>
        </svg>
      </div>
    </div>
  )
}

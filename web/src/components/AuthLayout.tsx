import type { ReactNode } from 'react'
import { PRODUCT_NAME, config } from '@/lib/config'
import { schoolLabel } from '@/lib/schoolLabel'

/**
 * The frame around every screen a visitor sees BEFORE they are signed in:
 * /login, /signup, /forgot and /reset.
 *
 * WHY THIS IS A COMPONENT AND NOT FOUR FIXES. All four pages once opened with
 * the identical wrapper, which is how four copies of the same layout drift
 * apart on the next change. The wrapper exists once.
 *
 * WHAT THIS REPLACED, AND WHY.
 *
 * The previous version put a dark brand-950 column on the left at 1fr, a drawn
 * fee receipt inside it deliberately overhanging its edge by 160px, and the
 * form in a fixed 460px column on the right. On a 1280px screen that is 820px
 * of dark panel and printed paper against 460px of form, and the object with
 * the most visual weight on the sign-in page was a receipt. That was the right
 * answer to the wrong question: it argued for the product on a screen where the
 * visitor has already decided, and it did it with a picture of the paperwork
 * they are buying software to stop doing.
 *
 * THREE RULES NOW, AND THEY ARE ALL ABOUT WEIGHT.
 *
 * 1. THE FORM IS THE ONLY ELEVATED SURFACE. The page ground is the tint, and
 *    the form sits on the single white card with a border and a real shadow.
 *    Everything in the support column sits flat on the tint. Whatever else is
 *    on screen, the eye lands on the thing you came to do.
 *
 * 2. THE FORM COLUMN COMES FIRST AND IS ALWAYS WIDER. Reading order and grid
 *    order both put it first, and the support column is a fixed 420px against a
 *    1fr form column, so the ratio cannot invert on a wide screen the way a
 *    1fr-plus-fixed-form layout does.
 *
 * 3. NOTHING DRAWN AS PAPER. The one piece of product imagery is an abstract UI
 *    mockup in the same idiom as the marketing site: a card, three stat tiles,
 *    three rows and a status pill. It is under 300px tall and it is flat on the
 *    tint, so it supports the form instead of competing with it.
 *
 * BELOW 1024px the support column is not rendered at all. Most signups happen
 * on a phone, so the device with the most signups gets the header, the form and
 * one line of facts, and nothing else to get wrong.
 *
 * COLOUR. The palette is the app's own indigo with the site's cyan accent, on
 * white and slate-50. Cyan appears only as an accent: the eyebrow rule, the
 * mockup's last chart bar, the tick marks. It is never a control colour, because
 * every interactive element here keeps the app's indigo so the dashboard is a
 * continuation rather than a jump. Green, amber and red are reserved product
 * wide for money in, money due and genuinely wrong, so the frame uses none of
 * them decoratively.
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
   the criterion requires for the boundary of a control. The field sits on
   white, so the border is the only thing that says "this is where you type",
   and a comment asserting compliance is worse than no comment because it stops
   the next person measuring.

   slate-500 #64748B measures 4.76:1 on white and still reads as a quiet field
   rather than a heavy one. */
export const authField =
  'mt-1.5 block min-h-[44px] w-full rounded-lg border border-slate-500 bg-white px-3 py-2.5 ' +
  'text-base text-slate-900 placeholder:text-slate-400 ' +
  'focus:border-brand-600 focus:outline-none focus:ring-2 focus:ring-brand-500/40'

export const authLabel = 'text-sm font-medium text-slate-700'

export const authHint = 'mt-1.5 block text-sm text-slate-500'

/** The app's primary button, verbatim brand-600, at a real tap target. */
export const authButton =
  'flex min-h-[44px] w-full items-center justify-center gap-2 rounded-lg bg-brand-600 ' +
  'px-4 py-2.5 text-base font-semibold text-white shadow-raised hover:bg-brand-700 ' +
  'focus:outline-none focus-visible:ring-2 focus-visible:ring-brand-500 focus-visible:ring-offset-2 ' +
  // THE BUSY BUTTON DOES NOT CHANGE COLOUR, and both of the obvious ways of
  // doing it were measured and rejected.
  //
  // disabled:opacity-60 took the label to 2.79:1, and every page swaps that
  // label to live status text ("Signing in", "Creating your school") at
  // exactly the moment it matters most, so the state was announced by making
  // it unreadable. Replacing it with a lighter fill, disabled:bg-brand-500,
  // measured 4.47:1 against the 4.5:1 that 16px text needs: better, and still
  // wrong, and wrong by an amount nobody would notice by eye.
  //
  // So the fill stays brand-600 at 6.29:1 and the state is carried by the
  // things that can carry it without touching contrast: the spinner, the
  // changed label, aria-busy on the form, the polite live region in AuthBusy,
  // and the cursor. The hover is frozen too, because :hover still applies to a
  // disabled button and a colour change on hover would say "press me".
  'disabled:cursor-progress disabled:hover:bg-brand-600'

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
      className="rounded-r-lg border border-l-[3px] border-danger-100 border-l-danger-700 bg-danger-50 py-2.5 pl-3 pr-3 text-sm text-danger-700"
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
      className={`rounded-r-lg border border-l-[3px] py-2.5 pl-3 pr-3 text-sm ${skin}`}
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

/* ------------------------------------------------------------------ mark -- */

/** The product mark: the site's rounded indigo square, at 36px. */
function Mark() {
  return (
    <span
      aria-hidden="true"
      className="flex h-9 w-9 shrink-0 items-center justify-center rounded-[10px] bg-brand-600 shadow-raised"
    >
      <svg viewBox="0 0 24 24" className="h-[18px] w-[18px]" fill="none">
        <path
          d="M4 6.5h6.4a1.6 1.6 0 0 1 1.6 1.6V19a1.4 1.4 0 0 0-1.4-1.4H4Zm16 0h-6.4A1.6 1.6 0 0 0 12 8.1V19a1.4 1.4 0 0 1 1.4-1.4H20Z"
          stroke="#fff"
          strokeWidth="1.6"
          strokeLinejoin="round"
        />
      </svg>
    </span>
  )
}

/* ----------------------------------------------------------------- panel -- */

/** A tick, for the three lines under the mockup. Cyan, the accent colour. */
function Tick() {
  return (
    <svg aria-hidden="true" viewBox="0 0 16 16" className="mt-[3px] h-4 w-4 shrink-0 text-cyan-700" fill="none">
      <path d="m3 8.4 3 3L13 4.6" stroke="currentColor" strokeWidth="1.9" strokeLinecap="round" strokeLinejoin="round" />
    </svg>
  )
}

/**
 * The abstract product mockup: a dashboard, not a document.
 *
 * Every figure in it is a plausible round number for a 486-pupil school and
 * none of it is a claim about a real one. It carries aria-hidden because it says
 * nothing a screen reader user needs; the three lines beneath it are the text.
 *
 * `name` is what the visitor has typed into School name, so on /signup the
 * mockup's title strip carries their school. That is the only persuasion on
 * these screens and it is the buyer's own input, which is why it can sit beside
 * field one of six.
 */
function AppMockup({ name }: { name?: string }) {
  const label = schoolLabel(name ?? '', 'Your school', 26)
  const bars = [38, 52, 46, 64, 58, 72, 66, 88]

  return (
    <div
      aria-hidden="true"
      className="overflow-hidden rounded-xl border border-slate-200 bg-white shadow-pop"
    >
      {/* title strip: the school's own name, which is the whole point */}
      <div className="flex items-center gap-2.5 border-b border-slate-200 bg-slate-50 px-3.5 py-3">
        <span className="flex h-6 w-6 items-center justify-center rounded-md bg-brand-600 text-[11px] font-bold text-white">
          S
        </span>
        <span
          dir={label.rtl ? 'rtl' : 'ltr'}
          lang={label.rtl ? 'ur' : undefined}
          style={{ fontSize: `${label.size}px`, ...label.style }}
          // NOT flex-1. With dir="rtl" on a flex-1 child, text-align resolves
          // to the right edge of the child, so an Urdu school name sat hard
          // against the far side of the strip with a gap where the mark is.
          // Sized to content and shrinkable instead, it stays beside the mark
          // in both directions and still truncates.
          className="min-w-0 truncate font-semibold text-slate-900"
        >
          {label.text}
        </span>
        <span className="ml-auto hidden text-[11px] text-slate-500 min-[1180px]:inline">
          Session 2026
        </span>
      </div>

      <div className="grid grid-cols-[100px_1fr]">
        {/* nav */}
        <div className="border-r border-slate-200 bg-slate-50 px-2 py-3">
          {['Fees', 'Students', 'Attendance', 'Results'].map((item, i) => (
            <div
              key={item}
              className={
                'truncate rounded-md px-2 py-1.5 text-[11px] ' +
                (i === 0 ? 'bg-white font-semibold text-brand-700 shadow-card' : 'text-slate-500')
              }
            >
              {item}
            </div>
          ))}
        </div>

        {/* body */}
        <div className="p-3">
          <div className="grid grid-cols-3 gap-2">
            {[
              ['Collected', 'Rs 84,500', 'text-money-700'],
              ['Outstanding', 'Rs 312,000', 'text-due-800'],
              ['Students', '486', 'text-slate-900'],
            ].map(([k, v, tone]) => (
              <div key={k} className="rounded-lg border border-slate-200 px-1.5 py-1.5">
                <div className="truncate text-[8.5px] font-bold uppercase tracking-[0.06em] text-slate-500">{k}</div>
                <div className={`mt-0.5 whitespace-nowrap text-[12px] font-bold tabular-nums lining-nums ${tone}`}>
                  {v}
                </div>
              </div>
            ))}
          </div>

          <div className="mt-2.5 overflow-hidden rounded-lg border border-slate-200">
            {[
              ['Class 5 A', 'Paid', true],
              ['Class 5 B', 'Due', false],
              ['Class 6 A', 'Paid', true],
            ].map(([row, state, paid], i) => (
              <div
                key={String(row)}
                className={
                  'flex items-center justify-between px-2.5 py-[7px] text-[11.5px] text-slate-600 ' +
                  (i > 0 ? 'border-t border-slate-100' : '')
                }
              >
                <span>{row}</span>
                <span
                  className={
                    'rounded-full px-2 py-[2px] text-[9.5px] font-bold ' +
                    (paid ? 'bg-money-50 text-money-700' : 'bg-due-50 text-due-800')
                  }
                >
                  {state}
                </span>
              </div>
            ))}
          </div>

          <div className="mt-2.5 flex h-9 items-end gap-1">
            {bars.map((h, i) => (
              <span
                key={i}
                style={{ height: `${h}%` }}
                className={
                  'flex-1 rounded-t-sm ' +
                  (i === bars.length - 1
                    ? 'bg-gradient-to-b from-cyan-300 to-cyan-500'
                    : 'bg-gradient-to-b from-brand-300 to-brand-600')
                }
              />
            ))}
          </div>
        </div>
      </div>
    </div>
  )
}

/** Three facts, flat on the tint. Tabular figures, no card, no dark fill. */
function Facts() {
  const cells: Array<[string, string]> = [
    ['From', 'Rs 950'],
    ['Trial', '14 days'],
    ['Modules', 'All included'],
  ]
  return (
    <dl className="mt-8 grid grid-cols-3 border-t border-slate-200 pt-5">
      {cells.map(([k, v], i) => (
        <div key={k} className={i === 0 ? 'pr-4' : 'border-l border-slate-200 pl-4 pr-4'}>
          <dt className="text-[10.5px] font-bold uppercase tracking-[0.08em] text-slate-500">{k}</dt>
          <dd className="mt-1 whitespace-nowrap text-[15px] font-bold leading-tight tabular-nums lining-nums text-slate-800">
            {v}
            {k === 'From' ? (
              <small className="ml-1 text-[13px] font-medium text-slate-500">a month</small>
            ) : null}
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
   * What the visitor has typed into School name, shown inside the mockup.
   * Only /signup has such a field; the other three pass nothing.
   */
  schoolName?: string
  /** The form column. */
  children: ReactNode
}

export function AuthLayout({ line, schoolName, children }: AuthLayoutProps) {
  /*
   * The vendor's name, not appTitle(useSchoolName()).
   *
   * These four screens run with NO SESSION, and useSchoolName reads
   * school_settings, which RLS closes to an anonymous caller. So it could only
   * ever return the build-time fallback here: a network request that always
   * fails, to render a name that was never the school's. Before a sign-in the
   * honest label is who made the software, which is also what the domain says.
   */
  const wordmark = PRODUCT_NAME

  return (
    <div className="flex min-h-full flex-col bg-white lg:bg-slate-50">
      {/* ------------------------------------------------------------ bar --
          A real app bar rather than a logo floating on a panel: white, one
          hairline, and the way back to the website where a visitor expects to
          find it. Present at every width, so the page has a top edge on a
          phone too. */}
      <header className="border-b border-slate-200 bg-white">
        <div className="mx-auto flex h-16 w-full max-w-[1120px] items-center justify-between gap-3 px-4 sm:gap-4 sm:px-8">
          <span className="flex min-w-0 items-center gap-2.5">
            <Mark />
            <span className="truncate text-[14px] font-semibold tracking-[-0.01em] text-slate-900 sm:text-[15px]">
              {wordmark}
            </span>
          </span>
          {/* Below 640px this is the chevron alone. "The School Manager" is
              four characters longer than the name it replaced, and at 320px the
              bar ran out of room and truncated the brand to "The School Manag".
              The aria-label carries the same words the wide layout shows, so a
              voice-control user says what they see either way, and the target
              stays 36px. Spending the last of a 320px budget on the label of a
              secondary link rather than on the product's own name is the wrong
              way round. */}
          <a
            href={config.siteUrl}
            aria-label="Back to the website"
            className="inline-flex min-h-[36px] shrink-0 items-center gap-1.5 rounded-lg px-2 text-[13px] text-slate-500 hover:text-brand-700 focus:outline-none focus-visible:ring-2 focus-visible:ring-brand-500 sm:text-sm"
          >
            <svg aria-hidden="true" viewBox="0 0 16 16" className="h-3.5 w-3.5" fill="none">
              <path
                d="M9.5 3.5 5 8l4.5 4.5"
                stroke="currentColor"
                strokeWidth="1.7"
                strokeLinecap="round"
                strokeLinejoin="round"
              />
            </svg>
            <span className="hidden sm:inline">Back to the website</span>
          </a>
        </div>
      </header>

      {/* ----------------------------------------------------------- body --
          Form column first in the DOM and first in the grid, at 1fr, with the
          support column fixed at 420px. At 1024px that is 604 against 420; at
          1440 it is 900 against 420. The form column is wider at every width
          the support column exists at, which is the property the old layout
          did not have. */}
      <div className="mx-auto flex w-full max-w-[1120px] flex-1 flex-col px-5 sm:px-8 lg:grid lg:grid-cols-[minmax(0,1fr)_420px] lg:gap-14">
        <main className="flex flex-1 items-center justify-center py-10 sm:py-14">
          {/* The one elevated surface on the page, and only where there is a
              second column for it to outweigh.

              Below 1024px the ground is white, there is nothing beside the
              form, and the form sits directly on the page with no card at all.
              A 440px white card centred on a 360px phone in a field of tint is
              the isolated-box failure that produced the original complaint, and
              it would be a card drawn around the only thing on screen.

              From 1024px the ground turns to tint, the support column appears,
              and the card, its border and its shadow appear with it. */}
          <div className="w-full max-w-[440px] bg-white lg:rounded-2xl lg:border lg:border-slate-200 lg:p-9 lg:shadow-pop">
            {children}
          </div>
        </main>

        {/* display:none below 1024px, which takes it out of layout and out of
            the accessibility tree both, so a 420px mockup cannot make a 360px
            phone scroll sideways and a screen reader never walks through it.
            Nothing in here is required in order to sign in. */}
        <aside className="hidden lg:flex lg:flex-col lg:justify-center lg:py-14">
          <p className="flex items-center gap-2.5 text-[11.5px] font-bold uppercase tracking-[0.09em] text-cyan-700">
            <span aria-hidden="true" className="h-[2px] w-[18px] rounded-sm bg-cyan-500" />
            One place for the office
          </p>
          <p className="mt-4 max-w-[24ch] text-[1.6rem] font-semibold leading-[1.2] tracking-[-0.02em] text-slate-900">
            {line}
          </p>

          <div className="mt-7">
            <AppMockup name={schoolName} />
          </div>

          <ul className="mt-6 space-y-2.5 text-sm text-slate-600">
            <li className="flex gap-2.5">
              <Tick />
              <span>Fees, attendance, results and payroll, all included in one price.</span>
            </li>
            <li className="flex gap-2.5">
              <Tick />
              <span>Works in any browser on the computer the office already has.</span>
            </li>
            <li className="flex gap-2.5">
              <Tick />
              <span>Every receipt and reversal is kept, with the name of whoever entered it.</span>
            </li>
          </ul>

          <Facts />
        </aside>
      </div>

      {/* One line of facts for the widths where the support column is gone.
          The price is the fact that has to survive the collapse, because it is
          the first question every school asks. */}
      <p className="border-t border-slate-200 bg-white px-5 py-4 text-center text-[13px] tabular-nums lining-nums text-slate-500 lg:hidden">
        From Rs 950 a month. 14 days free. All modules included.
      </p>
    </div>
  )
}

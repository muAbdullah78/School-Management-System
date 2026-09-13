# The shell on a phone, and the school's own name

Three defects, reported together, in the shell every staff screen renders
inside. The reasoning for each decision sits beside the code that makes it;
this file records the parts that are spread across five files and the
measurements, which nobody can reconstruct by reading.

Files: `web/src/components/AppShell.tsx`, `web/src/lib/schoolLabel.ts`,
`web/src/hooks/useIsDesktop.ts`, `web/src/index.css`, `web/index.html`.

## 1. The sidebar took two thirds of a phone

`<aside className="flex w-64 shrink-0 ...">` had no breakpoint on it. On a
390px phone that is 256 pixels of sidebar and 134 pixels for the attendance
register, the cash drawer and every table in the product. Every staff screen
inherited it, and no test had ever mounted `AppShell`, so nothing in the
repository could have known.

**One element, not two.** The obvious fix is a second sidebar for small
screens. That means two module search boxes with two filter states, two nav
lists, and a second place for every future change to be forgotten. There is
still exactly one `<aside>`: below `lg` it is `fixed` and slid out of frame by
a transform, at `lg` it is `static` and back in the flex row. The desktop
layout is unchanged.

**Transform, not width.** Animating a width relays out the whole page on every
frame, with every table in the content area reflowing behind the drawer. A
transform is composited.

**Visibility, not just a transform.** An element pushed off screen by a
transform is still in the accessibility tree and still in the tab order, so a
keyboard user would fall into an invisible sidebar and a screen reader would
read the menu twice. The closed drawer is `invisible`. Because `visibility`
interpolates as a step that flips at the end of a transition, it stays visible
for the whole slide out and disappears exactly when it lands, with no timer.

**The layout never depends on JavaScript.** The slide, the width and the
breakpoint are all CSS. What JavaScript decides is what the element *means*:
below `lg` it is a modal dialog that takes focus, traps Tab and closes on
Escape; at `lg` it is a navigation landmark where a focus trap would be a bug.
That is why `useIsDesktop` exists, and why `DESKTOP_QUERY` is 1024px with a
test asserting it still agrees with Tailwind's `lg`.

**Where the button went.** Into the existing top bar rather than a new header.
A second sticky header would cost a phone another 56px of chrome and a second
border, on the screens with the least room. The bar already carries where you
are and is already pinned above the scroller. Beside it sits the school's logo
mark alone, with no text: 32px buys back the brand identity that goes off
canvas with the sidebar, without spending width the screen title needs.

**Measured, at 320, 390, 844 and 1280px.** The page never scrolls sideways at
any of them. `main` is `overflow-hidden`, which both clips content wider than
the viewport and resolves the flex item's `min-width: auto` to zero, so no
table can push the document wide. A table wider than the screen scrolls inside
the content area, and every over-wide table in the product sits in an ancestor
that can scroll it.

## 2. The school's own name was cut off

Two faults, and the truncation was the smaller one.

The sidebar rendered `appTitle(schoolName)`, which is `"{name} Manager"`,
directly above a second line reading THE SCHOOL MANAGER. The word said itself
twice and the first copy was glued to the customer's name, where it read as
part of it: "Government Girls High School Manager". Dropping it is correct on
its own and gives eight characters back.

Then `truncate` on a 172px box cut what was left at about twenty characters.
Fifty character names are ordinary here: "Government Girls Higher Secondary
School Chaklala" is forty nine.

`fitSchoolName` walks a ladder of (size, lines) steps and takes the first that
holds the whole name, so a short name keeps the full 14px and only a long one
pays for its length. Capacity is derived, not guessed: a character advance of
0.54 of the font size, a wrap allowance of 0.85 applied only where there is
wrapping, and a test asserts for every length from 1 to 200 that the chosen
step really fits. The ellipsis at the bottom of the ladder is for input that is
not a school name.

**The box is 142px**, which is the drawer's and not the desktop sidebar's,
because the drawer carries a close button the sidebar does not:

```
drawer at its narrowest   min(288 from w-72, 320 - 48 from max-w)   272
less px-4 on both sides                                       -32   240
less the 40px logo and the 12px gap beside it                 -52   188
less the 40px close button, its 12px gap, its -6px pull       -46   142
```

The desktop sidebar is 172. Sizing for 142 leaves a desktop 30px it does not
spend, which is invisible, and is the only number under which the fit holds at
both widths.

## 3. Dark blue bled in at every edge

A browser paints something in the gap when a scroll is dragged past its end,
and what it paints is the canvas: the root element's background, falling back
to the body's. The theme-color in `index.html` was `#4338ca`, brand-700, chosen
to match the sidebar. On a desktop that reads well. On a phone the browser was
tinting its own chrome, and the band revealed by every bounce, with the colour
of a sidebar that is off canvas and not on screen at all.

Four changes, each correct on its own:

- `--app-canvas` is set on **both** `html` and `body`, so neither is the one
  that decides, and the **same literal** is the theme-color meta tag.
  `web/src/test/appChrome.test.ts` fails if the two ever drift apart. That is
  the invariant: the browser's chrome and the ground the app sits on are one
  colour, so there is no seam to see.
- `color-scheme: light`, so a phone in dark mode cannot invert a design that
  has one theme and is built for paper.
- `overscroll-behavior-y: none`, so a flick at the bottom of a list does not
  drag the whole app down. The y axis only: the shorthand would take the
  browser's own swipe to go back with it, and there is nothing on the x axis
  to contain.
- `-webkit-text-size-adjust: 100%`, so turning a phone sideways does not
  silently inflate the text and break every table by a different amount.

The manifest keeps the brand indigo. Its `theme_color` colours the splash
screen and the task switcher entry, neither of which is ever next to the
scrolling page, so there is nothing there to bleed.

`min-h-screen` became `min-h-full` in the parent portal and the password
screen. `100vh` on a mobile browser is the height the page would have if the
address bar were hidden, so a screen with little on it was a few pixels too
tall for the window and bounced when nothing needed to scroll.

## What is checked, and where

| Check | File |
| --- | --- |
| The drawer's semantics, focus, Escape, close on navigate, Tab trap, breakpoint | `web/src/test/shell.mobile.test.tsx` |
| Theme-color equals the canvas; scroll physics; the manifest keeps the brand | `web/src/test/appChrome.test.ts` |
| The ladder fits every length, at every box width, in both scripts | `web/src/lib/schoolLabel.test.ts` |
| What it all looks like, at 390px shut, 390px open, and 1280px | `web/tools/shell-preview.test.tsx`, run by `npm run harness` |

The first three run in `npm test`. The fourth writes HTML to
`scratch/shell/`: behaviour is not what was wrong here, and the only way to
know a layout is right is to look at it.

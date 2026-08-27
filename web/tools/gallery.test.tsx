/**
 * The page gallery — real screens, real CSS, one invented school.
 *
 * WHAT IT IS FOR. The A-to-Z guide has to show a school what each screen looks
 * like, and there is no honest way to produce those pictures by hand: a drawn
 * mockup drifts from the app the day after it is drawn, and a screenshot of a
 * real school's data is a child's name in a PDF sent to fifty schools.
 *
 * So this renders the ACTUAL page components, through the real compiled Tailwind,
 * with the demo school from demo-data.ts seeded into the query cache. The
 * pictures are therefore true by construction: if a screen changes, the next run
 * shows the change.
 *
 * IT IS ALSO A LAYOUT CHECK, and that is not a side effect. Every page here is
 * rendered at the two widths that matter — a phone and a desktop — by
 * /tmp/pgd/shot-gallery.mjs, which is how the ten clipped dialogs and the
 * squeezed by-plan table were found.
 *
 * WHAT IT CANNOT DO, said plainly: renderToStaticMarkup fires no effects and
 * runs no event handlers, so this is every page's FIRST PAINT with data already
 * present. A screenshot of a dialog that only opens on a click has to be produced
 * by rendering that dialog directly, which is what the receipt and statement
 * harnesses do. Nothing here proves a button works.
 *
 * Excluded from `npm test` by vitest's test.include; run with `npm run harness`.
 */
import { it } from 'vitest'
import { PortalPage } from '../src/pages/portal/PortalPage'
import { Dashboard } from '../src/pages/Dashboard'
import { Login } from '../src/pages/Login'
import { ForgotPassword } from '../src/pages/ForgotPassword'
import { writePage } from './harness'
import {
  DEMO_PORTAL_ME, DEMO_FEES, DEMO_ATTENDANCE, DEMO_RESULT, DEMO_CHILDREN,
  DEMO_DASHBOARD_SUMMARY, DEMO_PROFILE,
} from './demo-data'

/**
 * The parent's own account, as the portal sees it.
 *
 * Seeded with the keys PortalPage actually uses, taken from the file rather than
 * guessed: ['portalMe'], ['portalFees', id], ['portalAtt', id], ['portalResults',
 * id]. A wrong key is not an error — the query simply stays empty and the page
 * renders its loading state, which is the failure mode this comment exists to
 * make obvious when a picture comes out blank.
 */
const child = DEMO_CHILDREN[0].student_id
const portalSeeds = [
  [['portalMe'], DEMO_PORTAL_ME],
  [['portalFees', child], DEMO_FEES],
  [['portalAtt', child], DEMO_ATTENDANCE],
  [['portalResults', child], [DEMO_RESULT]],
] as [readonly unknown[], unknown][]

it('writes the page gallery', () => {
  writePage(
    '../scratch/gallery.html',
    [
      {
        caption: 'THE PARENT PORTAL, fees tab — what a parent sees first. Three '
          + 'children in one family, August unpaid, and the admission charge shown '
          + 'as "Other charges" rather than filed under a month it was never '
          + 'billed for.',
        node: <PortalPage />,
        seeds: portalSeeds,
        profile: null,          // a parent has no staff profile, by design
        route: '/portal',
      },
      {
        caption: 'THE DASHBOARD, as a principal sees it. The two figures worth '
          + 'explaining in the guide are both warnings the demo carries on '
          + 'purpose: 209 of 214 pupils billed this month, and one class with no '
          + 'fee structure — which is the reason for the gap. A teacher signing '
          + 'in sees their own class instead of this screen.',
        node: <Dashboard />,
        seeds: [[['dashboardSummary'], DEMO_DASHBOARD_SUMMARY]],
        profile: DEMO_PROFILE,
        route: '/',
      },
      {
        caption: 'THE PARENT PORTAL, results tab — the verdict, not just the '
          + 'marks. Islamiat is below the pass mark so the card reads FAIL, '
          + 'Physics shows written and practical separately (47/75 + 19/25 = 66 '
          + 'out of 100, which the portal used to render as "47 / 75"), and '
          + 'Computer is unmarked, which is why the card says it is not final.',
        node: <PortalPage />,
        seeds: portalSeeds,
        profile: null,
        // The tab comes from the URL, so a static render can show it. Before
        // that it could not: renderToStaticMarkup fires no click, so this case
        // would have rendered the Fees tab under a caption promising Results —
        // a caption that lies is worse than a missing screenshot.
        route: '/portal?tab=results',
      },
      {
        caption: 'THE PARENT PORTAL, attendance tab. 92%, with an absence and a '
          + 'late mark visible — a demo where nobody is ever absent does not '
          + 'teach a parent what the day-by-day list is for.',
        node: <PortalPage />,
        seeds: portalSeeds,
        profile: null,
        route: '/portal?tab=attendance',
      },
      {
        caption: 'SIGN IN. The "Forgotten your password?" link is the one that did '
          + 'not exist: before it, the only way back into the software for a '
          + 'principal, a clerk or a parent was for the vendor to set a password '
          + 'by hand and send it over WhatsApp.',
        node: <Login />,
        seeds: [],
        profile: null,
        route: '/login',
      },
      {
        caption: 'FORGOTTEN PASSWORD. It shows the same sentence whether or not '
          + 'the address has an account — anything more helpful tells a stranger '
          + 'whether a particular teacher works at a particular school.',
        node: <ForgotPassword />,
        seeds: [],
        profile: null,
        route: '/forgot',
      },
    ],
    { bodyStyle: 'background:#f1f5f9;margin:0' },
  )
})

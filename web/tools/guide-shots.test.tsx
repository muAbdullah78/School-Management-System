/**
 * Clean, uncaptioned renders of each screen — one HTML file each — for the user
 * guide's screenshots.
 *
 * SEPARATE FROM gallery.test.tsx on purpose. The gallery stacks every case on one
 * page under a caption, which is right for a human checking layout and wrong for
 * a picture that has to sit in a document: the caption would be baked into the
 * image, and one tall page makes every crop a guess about pixel offsets.
 *
 * Each case here becomes ../scratch/guide/<name>.html, and
 * /tmp/pgd/shot-guide.mjs turns each into a PNG sized for the page. Same
 * components, same compiled CSS, same demo school as everything else — so a
 * screenshot in the guide cannot drift from the software the way a drawn mockup
 * would.
 *
 * Excluded from `npm test` by vitest's test.include; run with `npm run harness`.
 */
import { it } from 'vitest'
import type { ReactElement } from 'react'
import { PortalPage } from '../src/pages/portal/PortalPage'
import { Dashboard } from '../src/pages/Dashboard'
import { Login } from '../src/pages/Login'
import { ForgotPassword } from '../src/pages/ForgotPassword'
import { PortalStatement } from '../src/components/PortalStatement'
import { Receipt } from '../src/components/Receipt'
import { writePage } from './harness'
import type { Profile } from '../src/auth/AuthProvider'
import {
  DEMO_PORTAL_ME, DEMO_FEES, DEMO_ATTENDANCE, DEMO_RESULT, DEMO_CHILDREN,
  DEMO_DASHBOARD_SUMMARY, DEMO_PROFILE, DEMO_SCHOOL, DEMO_PARENT,
} from './demo-data'

const child = DEMO_CHILDREN[0].student_id
const portalSeeds = [
  [['portalMe'], DEMO_PORTAL_ME],
  [['portalFees', child], DEMO_FEES],
  [['portalAtt', child], DEMO_ATTENDANCE],
  [['portalResults', child], [DEMO_RESULT]],
] as [readonly unknown[], unknown][]

/** A stage that gives `position: fixed` dialogs a containing block, so a modal
 *  can be photographed on its own instead of pinning itself to the viewport. */
function Stage({ children }: { children: ReactElement }) {
  return (
    <div style={{ transform: 'translateZ(0)', position: 'relative', minHeight: '44rem' }}>
      {children}
    </div>
  )
}

const SHOTS: {
  name: string
  node: ReactElement
  seeds?: [readonly unknown[], unknown][]
  profile?: Profile | null
  route?: string
  bg?: string
}[] = [
  { name: 'login', node: <Login />, profile: null, route: '/login' },
  { name: 'forgot', node: <ForgotPassword />, profile: null, route: '/forgot' },
  {
    name: 'dashboard', node: <Dashboard />,
    seeds: [[['dashboardSummary'], DEMO_DASHBOARD_SUMMARY]],
    profile: DEMO_PROFILE, route: '/',
  },
  {
    name: 'portal-fees', node: <PortalPage />,
    seeds: portalSeeds, profile: null, route: '/portal',
  },
  {
    name: 'portal-attendance', node: <PortalPage />,
    seeds: portalSeeds, profile: null, route: '/portal?tab=attendance',
  },
  {
    name: 'portal-results', node: <PortalPage />,
    seeds: portalSeeds, profile: null, route: '/portal?tab=results',
  },
  {
    name: 'portal-statement',
    node: (
      <PortalStatement
        schoolName={DEMO_SCHOOL.name}
        parentName={DEMO_PARENT.full_name}
        child={DEMO_CHILDREN[0]}
        fees={DEMO_FEES}
      />
    ),
    bg: '#fff',
  },
  {
    name: 'receipt-family',
    node: (
      <Stage>
        <Receipt
          data={{
            receiptNo: 3184,
            studentName: DEMO_PARENT.full_name,
            amount: 14100,
            method: 'Cash',
            balanceAfter: 0,
            note: null,
            date: '2026-08-26T09:20:00Z',
            payerLabel: 'Received from',
            balanceLabel: 'Family balance after',
            covers: [
              { label: 'Ayesha Aslam (GR 1204) · Aug 2026', amount: 4500 },
              { label: 'Bilal Aslam (GR 1207) · Aug 2026', amount: 6200 },
              { label: 'Hira Aslam (GR 1301) · Aug 2026', amount: 3400 },
            ],
          }}
          onClose={() => {}}
        />
      </Stage>
    ),
  },
]

it('writes one clean page per guide screenshot', () => {
  for (const s of SHOTS) {
    writePage(
      `../scratch/guide/${s.name}.html`,
      // No caption: writePage returns the bare markup when one is not given, so
      // nothing lands in the image that is not the screen itself.
      [{ node: s.node, seeds: s.seeds, profile: s.profile, route: s.route }],
      { bodyStyle: `background:${s.bg ?? '#f1f5f9'};margin:0` },
    )
  }
})

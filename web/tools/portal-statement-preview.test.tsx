/**
 * Not a unit test — a rendering harness for the parent's fee statement.
 *
 * This one exists because of the specific way its predecessor failed. The portal
 * had a "Print" button that called window.print() on a page carrying no
 * printable id, and index.css hides `body *` for print and reveals only named
 * ids. So the button produced a BLANK SHEET. Nothing threw. No test failed. The
 * print dialog opened, the preview was empty, and the only person who ever found
 * out was a parent who had already paid for the print-out.
 *
 * An assertion about markup could not have caught that, and cannot catch it
 * coming back: the bug lived entirely in the interaction between a component and
 * a stylesheet. So this renders the real component against the real compiled
 * Tailwind, and /tmp/pgd/shot-portal.mjs then loads the page with the print
 * media type emulated and checks that ink lands on the paper.
 *
 * Four cases, each a shape a real family is in:
 *
 *   1. the ordinary case — some months paid, this month not
 *   2. the family with an advance, and a running balance that does NOT equal
 *      the sum of the challans, which is the reconciliation a parent phones
 *      about
 *   3. nothing billed and nothing paid — a child admitted last week, which is
 *      the case that most often renders as a broken empty page
 *   4. three children, so the family total dwarfs the child's own and the
 *      family-wide payment list has to say so
 *
 * Excluded from `npm test` by vitest's test.include; run with `npm run harness`.
 */
import { it } from 'vitest'
import { PortalStatement } from '../src/components/PortalStatement'
import type { PortalChild, PortalFees } from '../src/lib/db'
import { writePage } from './harness'

const CHILD: PortalChild = {
  student_id: 'st1',
  full_name: 'Ayesha Bibi',
  gr_no: '1204',
  class_name: 'Class 5',
  section_name: 'B',
  status: 'active',
}

const ordinary: PortalFees = {
  student_id: 'st1',
  balance: 4500,
  family_outstanding: 4500,
  family_credit: 0,
  invoices: [
    { period_month: '2026-08-01', due_date: '2026-08-10', charge: 4500, paid: 0, outstanding: 4500, status: 'unpaid' },
    { period_month: '2026-07-01', due_date: '2026-07-10', charge: 4500, paid: 4500, outstanding: 0, status: 'paid' },
    { period_month: '2026-06-01', due_date: '2026-06-10', charge: 4500, paid: 4500, outstanding: 0, status: 'paid' },
    { period_month: null, due_date: '2026-04-15', charge: 12000, paid: 12000, outstanding: 0, status: 'paid' },
  ],
  receipts: [
    { receipt_no: 3182, amount: 4500, method: 'cash', paid_on: '2026-07-08T09:20:00Z', received_by: 'Nadia Khan' },
    { receipt_no: 2955, amount: 4500, method: 'bank_transfer', paid_on: '2026-06-09T11:05:00Z', received_by: 'Nadia Khan' },
    { receipt_no: 2410, amount: 12000, method: 'cash', paid_on: '2026-04-12T08:40:00Z', received_by: 'Imran Sheikh' },
  ],
  adjustments: [],
  charges_not_on_a_challan: 0,
}

/**
 * The one with a hand-keyed charge, which is the case the statement was blind
 * to. Rs 4,500 unpaid on the challan plus Rs 800 for the van is Rs 5,300, and
 * before 0098 the page showed the Rs 4,500 and the Rs 5,300 with nothing
 * between them. Worth a preview of its own: if the Other charges block ever
 * stops rendering, the page silently goes back to accusing the school of adding
 * money on quietly.
 */
const withHandKeyedCharges: PortalFees = {
  student_id: 'st1',
  balance: 5300,
  family_outstanding: 5300,
  family_credit: 0,
  invoices: [
    { period_month: '2026-08-01', due_date: '2026-08-10', charge: 4500, paid: 0, outstanding: 4500, status: 'unpaid' },
    { period_month: '2026-07-01', due_date: '2026-07-10', charge: 4500, paid: 4500, outstanding: 0, status: 'paid' },
  ],
  receipts: [
    { receipt_no: 3182, amount: 4500, method: 'cash', paid_on: '2026-07-08T09:20:00Z', received_by: 'Nadia Khan' },
  ],
  adjustments: [
    { on: '2026-08-02', amount: 1200, reason: 'Van fare, August' },
    { on: '2026-08-14', amount: -400, reason: 'Hardship: half the van fare waived' },
  ],
  charges_not_on_a_challan: 800,
}

/**
 * The reconciliation call. The challans total Rs 9,000 unpaid; the running
 * balance is Rs 6,500 because Rs 2,500 is sitting as an advance and the office
 * wrote off Rs 0 — a parent who sees two different numbers and no explanation
 * assumes one of them is a mistake and stops trusting the page.
 */
const withAdvance: PortalFees = {
  student_id: 'st1',
  balance: 6500,
  family_outstanding: 6500,
  family_credit: 2500,
  invoices: [
    { period_month: '2026-08-01', due_date: '2026-08-10', charge: 4500, paid: 0, outstanding: 4500, status: 'unpaid' },
    { period_month: '2026-07-01', due_date: '2026-07-10', charge: 4500, paid: 0, outstanding: 4500, status: 'overdue' },
  ],
  receipts: [
    { receipt_no: 3301, amount: 2500, method: 'easypaisa', paid_on: '2026-08-20T13:00:00Z', received_by: null },
  ],
  adjustments: [],
  charges_not_on_a_challan: 0,
}

/** Admitted last week. Nothing billed, nothing paid — and it must not look broken. */
const brandNew: PortalFees = {
  student_id: 'st1',
  balance: 0,
  family_outstanding: 0,
  family_credit: 0,
  invoices: [],
  receipts: [],
  adjustments: [],
  charges_not_on_a_challan: 0,
}

/** Three children. The family total is the number that frightens people. */
const bigFamily: PortalFees = {
  ...ordinary,
  family_outstanding: 13500,
  receipts: [
    { receipt_no: 3182, amount: 13500, method: 'bank_transfer', paid_on: '2026-07-08T09:20:00Z', received_by: 'Nadia Khan' },
    ...ordinary.receipts.slice(1),
  ],
}

it('writes a parent fee statement preview', () => {
  writePage(
    '../scratch/portal-statement.html',
    [
      {
        caption: 'The ordinary case. August unpaid, June and July settled, and an '
          + 'admission charge with no month — labelled "Other charges" rather than '
          + 'printed against a month it was never billed for.',
        node: <PortalStatement schoolName="Al Qalam Public School" parentName="Muhammad Aslam" child={CHILD} fees={ordinary} />,
      },
      {
        caption: 'The reconciliation call: Rs 9,000 of challans unpaid but a running '
          + 'balance of Rs 6,500, because Rs 2,500 is held in advance. Two different '
          + 'numbers on one page is the thing a parent phones about, so the page '
          + 'explains the difference instead of leaving them to find it.',
        node: <PortalStatement schoolName="Al Qalam Public School" parentName="Muhammad Aslam" child={CHILD} fees={withAdvance} />,
      },
      {
        caption: 'Admitted last week: nothing billed and nothing paid. The commonest '
          + 'state for a new family, and the one an empty-state bug reaches first.',
        node: <PortalStatement schoolName="Al Qalam Public School" parentName="Muhammad Aslam" child={CHILD} fees={brandNew} />,
      },
      {
        caption: 'Three children: the family owes Rs 13,500 while this child owes '
          + 'Rs 4,500, and the payment list is family-wide. Without the label, a '
          + 'parent reads one child’s statement and concludes this child is clear.',
        node: <PortalStatement schoolName="Al Qalam Public School" parentName="Muhammad Aslam" child={CHILD} fees={bigFamily} />,
      },
      {
        caption: 'A van fare keyed by hand and half of it later waived. Rs 4,500 '
          + 'unpaid on the challan plus Rs 800 of other charges is the Rs 5,300 '
          + 'balance, and the page says so. Before 0098 these existed only inside '
          + 'the balance, so the statement showed Rs 4,500 of challans above '
          + 'Rs 5,300 owed with nothing between them.',
        node: <PortalStatement schoolName="Al Qalam Public School" parentName="Muhammad Aslam" child={CHILD} fees={withHandKeyedCharges} />,
      },
      {
        caption: 'The school name has not come back from fn_portal_me and the child '
          + 'is not enrolled. It prints a truthful "School" and "Not enrolled" '
          + 'rather than an empty letterhead.',
        node: <PortalStatement schoolName={null} parentName={null} child={{ ...CHILD, gr_no: null, class_name: null, section_name: null }} fees={ordinary} />,
      },
    ],
    { bodyStyle: 'background:#f1f5f9' },
  )
})

/**
 * A second page whose only job is to be PRINTED.
 *
 * It reproduces the portal's real DOM around the statement — a page header, a
 * card, the dialog, and the dialog's own buttons — because the blank-page bug
 * was not in any of those pieces. It was in `body * { visibility: hidden }`
 * meeting a component with no id in the allow-list. Only a browser applying the
 * print media type can tell you which way that went.
 *
 * /tmp/pgd/shot-portal.mjs loads this with media=print and checks three things:
 * the statement is visible, the surrounding page is not, and neither is the
 * Print button — a Print button that prints itself onto the paper is the second
 * most common version of this bug.
 */
it('writes a print-media check page', () => {
  writePage(
    '../scratch/portal-print.html',
    [
      {
        node: (
          <div className="min-h-screen bg-slate-50">
            <header
              id="decoy-header"
              className="bg-brand-800 px-4 pb-16 pt-5 text-white"
            >
              <p className="text-xs uppercase tracking-wide">Al Qalam Public School</p>
              <h1 className="text-lg font-semibold">Muhammad Aslam</h1>
            </header>
            <main className="mx-auto -mt-12 max-w-3xl px-4 pb-12">
              <div id="decoy-card" className="rounded-xl bg-white p-4 shadow">
                Monthly challans, receipts, tabs — none of this belongs on the paper.
              </div>
            </main>
            <div className="fixed inset-0 z-50 flex items-start justify-center overflow-y-auto bg-black/40 p-3 sm:items-center print:static print:overflow-visible print:bg-white print:p-0">
              <div className="w-full max-w-2xl rounded-lg bg-white shadow-lg print:max-w-none print:rounded-none print:shadow-none">
                <PortalStatement
                  schoolName="Al Qalam Public School"
                  parentName="Muhammad Aslam"
                  child={CHILD}
                  fees={ordinary}
                />
                <div className="flex gap-2 border-t border-slate-200 p-4 print:hidden">
                  <button id="decoy-print" className="flex-1 rounded-lg bg-brand-600 px-3 py-2.5 text-sm text-white">
                    Print
                  </button>
                  <button id="decoy-close" className="flex-1 rounded-lg border border-slate-300 px-3 py-2.5 text-sm">
                    Close
                  </button>
                </div>
              </div>
            </div>
          </div>
        ),
      },
    ],
    { bodyStyle: 'background:#fff;margin:0' },
  )
})

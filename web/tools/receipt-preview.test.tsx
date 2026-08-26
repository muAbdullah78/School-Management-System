/**
 * Not a unit test — a rendering harness for the fee receipt.
 *
 * The receipt gained four optional fields in 0084 so that ONE component can
 * serve both counters. Two components would eventually disagree about a total,
 * and the receipt is the piece of paper the parent keeps and brings back when
 * they disagree with the office — so it is the last document that may drift.
 *
 * The family case is the one that needs eyes. A father paying Rs 9,000 for three
 * children gets one receipt, and it has to say which child and which month each
 * rupee went to, in the order the clerk can explain it. Whether that list reads
 * sensibly on a receipt-width page is not something an assertion can answer.
 *
 * No school name and no logo here: the harness has no Supabase client by design,
 * so useSchoolName falls back to the build-time default. That is also what a
 * fresh install prints before Settings is filled in, which makes it the honest
 * case to look at.
 *
 * Excluded from `npm test` by vitest's test.include; run with `npm run harness`.
 */
import { it } from 'vitest'
import type { ReactNode } from 'react'
import { Receipt } from '../src/components/Receipt'
import { writePage } from './harness'

const noop = () => {}

/**
 * Receipt is a `position: fixed` dialog, so three of them on one page would all
 * pin themselves to the viewport and stack on top of one another.
 *
 * A TRANSFORMED ANCESTOR becomes the containing block for fixed descendants —
 * that is what `transform: translateZ(0)` is doing here. It is the whole reason
 * the cases below can sit side by side without the component being restructured
 * for the harness's benefit, which would be the tail wagging the dog.
 */
function Stage({ children }: { children: ReactNode }) {
  return (
    <div style={{ transform: 'translateZ(0)', position: 'relative', minHeight: '46rem' }}>
      {children}
    </div>
  )
}

it('writes a fee receipt preview', () => {
  writePage(
    '../scratch/receipt.html',
    [
      {
        caption: 'One student, one month. The original shape, unchanged — every '
          + 'new field is optional, so this must look exactly as it always did.',
        node: (
          <Stage><Receipt
            data={{
              receiptNo: 3184,
              studentName: 'Ayesha Bibi',
              grNo: '1204',
              amount: 4500,
              method: 'Cash',
              balanceAfter: 0,
              note: null,
              date: '2026-08-26T09:14:00Z',
            }}
            onClose={noop}
          /></Stage>
        ),
      },
      {
        caption: 'The family counter: Rs 9,000 from the father, allocated '
          + 'oldest-month-first across three children. Without the "Applied for" '
          + 'list this receipt says only "Rs 9,000" and the family cannot tell '
          + 'whose dues moved — which is the argument at the counter it exists '
          + 'to prevent.',
        node: (
          <Stage><Receipt
            data={{
              receiptNo: 3185,
              studentName: 'Muhammad Aslam',
              amount: 9000,
              method: 'Cash',
              balanceAfter: 4500,
              note: null,
              date: '2026-08-26T09:20:00Z',
              payerLabel: 'Received from',
              balanceLabel: 'Family balance after',
              covers: [
                { label: 'Ayesha Bibi (GR 1204) · Aug 2026', amount: 3000 },
                { label: 'Bilal Aslam (GR 1207) · Aug 2026', amount: 3000 },
                { label: 'Hira Aslam (GR 1301) · Aug 2026', amount: 3000 },
              ],
            }}
            onClose={noop}
          /></Stage>
        ),
      },
      {
        caption: 'The same family paying ahead: Rs 12,000 against Rs 9,000 owed. '
          + 'The Rs 3,000 surplus is shown as held in advance rather than folded '
          + 'into the amount — a parent who reads "Rs 12,000 paid, balance zero" '
          + 'and is then billed next month has been misled.',
        node: (
          <Stage><Receipt
            data={{
              receiptNo: 3186,
              studentName: 'Muhammad Aslam',
              amount: 12000,
              method: 'Bank transfer',
              balanceAfter: 0,
              note: 'paying to December',
              date: '2026-08-26T09:26:00Z',
              payerLabel: 'Received from',
              balanceLabel: 'Family balance after',
              advance: 3000,
              covers: [
                { label: 'Ayesha Bibi (GR 1204) · Aug 2026', amount: 3000 },
                { label: 'Bilal Aslam (GR 1207) · Aug 2026', amount: 3000 },
                { label: 'Hira Aslam (GR 1301) · Aug 2026', amount: 3000 },
              ],
            }}
            onClose={noop}
          /></Stage>
        ),
      },
    ],
    { bodyStyle: 'background:#f1f5f9' },
  )
})

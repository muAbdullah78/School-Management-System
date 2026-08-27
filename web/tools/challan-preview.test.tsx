/**
 * Not a unit test — a rendering harness.
 *
 * It renders the challan to a real HTML file so the printed layout can be
 * LOOKED AT. A challan is the one thing in this product a parent physically
 * holds and argues with, and no assertion about markup tells you whether three
 * copies actually fit across a page.
 *
 * Excluded from `npm test` by vitest's test.include; run with `npm run harness`.
 * A CI step runs it after the build, because the previous arrangement — nothing
 * ran it at all — let it sit broken: 0057 added a logo to every print surface,
 * ChallanPrint started calling useSchoolLogo(), and calling the component as a
 * plain function died on React context with nobody watching.
 */
import { it } from 'vitest'
import { ChallanPrint } from '../src/pages/fees/ChallanPrint'
import type { Challan } from '../src/lib/db'
import { writePage } from './harness'

const base: Challan = {
  invoice_id: 'i1', voucher_code: 'MB26KRZP', status: 'issued',
  period_month: '2026-08-01', period_label: 'August 2026', due_date: '2026-08-10',
  student_id: 's1', student_name: 'Ayesha Bibi', gr_no: 'GR-0042', roll_no: '3',
  father_name: 'Muhammad Aslam', family_head: 'Muhammad Aslam',
  family_cnic: '35201-1234567-1', phone: '0300-1234567',
  class_name: 'Class 5', section_name: 'A',
  lines: [
    { description: 'Tuition Fee', amount: 3500, is_discount: false },
    { description: 'Computer Lab', amount: 400, is_discount: false },
    { description: 'Sibling discount', amount: 350, is_discount: true },
  ],
  fine: 100, this_month: 3650, already_paid: 0, this_month_due: 3650,
  previous_dues: 1200, total_payable: 4850, arrears_snapshot_at_generation: 1200,
}

const SCHOOL = {
  name: 'Al Qalam Public School',
  address: 'Ghauri Town Phase 5B, Islamabad',
  phone: '0332-9157079',
}

/** Fully paid: this_month_due and total_payable both zero. The case the harness
 *  earned its keep on — a paid slip must not read as a demand. */
const paid: Challan = {
  ...base, invoice_id: 'i2', student_name: 'Bilal Aslam', roll_no: '7',
  previous_dues: 0, already_paid: 3650, this_month_due: 0, total_payable: 0,
  voucher_code: 'MB26QQ7T',
}

it('writes a challan preview', () => {
  // Rendered as real JSX inside the app's providers, not by calling the
  // component as a function. ChallanPrint calls useSchoolLogo() → useQuery(),
  // and a bare function call has no React context at all.
  //
  // The logo query is left UNSEEDED deliberately: useSchoolLogo returns null and
  // SchoolMark sets the school's name in type instead, which is both the
  // fallback worth looking at and what most schools will actually print.
  writePage('../scratch/challan.html', [
    {
      caption: 'Two children in one family — one owing arrears, one fully paid. '
        + 'No logo uploaded, so the letterhead is the name set in type.',
      node: <ChallanPrint challans={[base, paid]} school={SCHOOL} onClose={() => {}} />,
    },
  ])
})

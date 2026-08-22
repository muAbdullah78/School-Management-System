/**
 * Not a unit test — a rendering harness.
 *
 * It renders the challan to a real HTML file so the printed layout can be
 * LOOKED AT. A challan is the one thing in this product a parent physically
 * holds and argues with, and no assertion about markup tells you whether three
 * copies actually fit across a page.
 *
 * Named with a leading underscore and excluded from CI; run on demand.
 */
import { it } from 'vitest'
import { renderToStaticMarkup } from 'react-dom/server'
import { writeFileSync, readdirSync } from 'node:fs'
import { ChallanPrint } from '../src/pages/fees/ChallanPrint'
import type { Challan } from '../src/lib/db'

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

it('writes a challan preview', () => {
  const css = readdirSync('dist/assets').find((f) => f.endsWith('.css'))
  const html = renderToStaticMarkup(
    ChallanPrint({
      challans: [base, { ...base, invoice_id: 'i2', student_name: 'Bilal Aslam', roll_no: '7',
        previous_dues: 0, already_paid: 3650, this_month_due: 0, total_payable: 0,
        voucher_code: 'MB26QQ7T' }],
      school: { name: 'Al Qalam Public School', address: 'Ghauri Town Phase 5B, Islamabad', phone: '0332-9157079' },
      onClose: () => {},
    }) as never,
  )
  writeFileSync('../scratch/challan.html',
    `<!doctype html><html><head><meta charset="utf-8">
     <link rel="stylesheet" href="../web/dist/assets/${css}">
     </head><body style="background:#fff">${html}</body></html>`)
})

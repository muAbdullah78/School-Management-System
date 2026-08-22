/**
 * Not a unit test — a rendering harness, like challan-preview.
 *
 * The balance sheet is the one screen here where a principal reads four numbers
 * and forms a judgement about their school. If a tile is the wrong colour, or a
 * negative reads as a positive, or the workings do not visibly add up to the
 * total above them, the report is worse than useless — it is confidently wrong.
 * No assertion about markup tells you that. Looking does.
 *
 * The figures below are NOT invented. They are the payload
 * fn_report_balance_sheet actually returned for the fixture in
 * supabase/tests/balance_sheet.sql, so the layout is exercised against
 * arithmetic that is known to reconcile.
 *
 * Excluded from `npm test` by vitest's test.include; run on demand.
 */
import { it } from 'vitest'
import { renderToStaticMarkup } from 'react-dom/server'
import { writeFileSync, readdirSync, mkdirSync } from 'node:fs'
import { BalanceSheetView } from '../src/pages/reports/FinanceReports'
import type { BalanceSheet } from '../src/lib/db'

const BASIS =
  'Cumulative from the first record up to the as-at date. Receivable counts ' +
  'charges on invoices ISSUED by that date, less payments taken by that date ' +
  'against those invoices, for every student the school has ever had. Money ' +
  'paid early for a later month is shown as advance held, not as income. Roll ' +
  "counts use the student's CURRENT status, which is not kept historically, so " +
  'a child who has since left is counted off-roll even for a date when they ' +
  'were present; their arrears still appear in receivable. Not double-entry: ' +
  'no chart of accounts, no bank reconciliation, no fixed assets.'

/** Straight from the test fixture: 4 children, one withdrawn, advance fees held. */
const real: BalanceSheet = {
  as_at: '2026-08-22',
  receivable: 8150,
  receivable_off_roll: 3000,
  cash_in: 7500,
  cash_out: 250,
  cash_position: 7250,
  advance_held: 3000,
  fee_receipts: 7000,
  other_income: 500,
  charges_raised: 12150,
  allocated: 4000,
  students_on_roll: 3,
  students_owing: 2,
  basis: BASIS,
}

/** A school that is square: nothing owed, no advance, no leavers. */
const settled: BalanceSheet = {
  ...real,
  receivable: 0, receivable_off_roll: 0, advance_held: 0,
  charges_raised: 12150, allocated: 12150,
  fee_receipts: 12150, cash_in: 12650, cash_position: 12400,
  students_owing: 0,
  basis: BASIS,
}

/**
 * The case worth looking at hardest: the school has spent more than it has
 * taken, and is holding advance fees it may have to return. A cash position
 * smaller than the advance held is a school in trouble, and the layout must
 * not make that look calm.
 */
const overdrawn: BalanceSheet = {
  ...real,
  receivable: 184300, receivable_off_roll: 42500,
  fee_receipts: 61000, other_income: 2000, cash_in: 63000,
  cash_out: 96500, cash_position: -33500,
  advance_held: 18000,
  charges_raised: 245300, allocated: 61000,
  students_on_roll: 214, students_owing: 96,
  basis: BASIS,
}

/** A brand-new school: every figure zero. Must not look broken. */
const empty: BalanceSheet = {
  as_at: '2026-08-22',
  receivable: 0, receivable_off_roll: 0, cash_in: 0, cash_out: 0,
  cash_position: 0, advance_held: 0, fee_receipts: 0, other_income: 0,
  charges_raised: 0, allocated: 0, students_on_roll: 0, students_owing: 0,
  basis: BASIS,
}

it('writes a balance sheet preview', () => {
  const css = readdirSync('dist/assets').find((f) => f.endsWith('.css'))
  const cases: [string, BalanceSheet][] = [
    ['As the test fixture actually returns it — advance fees held, one leaver owing',
      real],
    ['A school that is square — nothing owed, nothing held', settled],
    ['Overdrawn, and holding advance fees it may have to give back', overdrawn],
    ['A brand-new school, before anything has happened', empty],
  ]
  const body = cases.map(([label, b]) => `
    <section style="margin:0 0 3rem">
      <p style="font:600 13px/1.5 system-ui;color:#64748b;border-bottom:1px solid #e2e8f0;padding-bottom:.4rem;margin-bottom:1rem">
        ${label}
      </p>
      ${renderToStaticMarkup(BalanceSheetView({ b }) as never)}
    </section>`).join('')

  mkdirSync('../scratch', { recursive: true })
  writeFileSync('../scratch/balance-sheet.html',
    `<!doctype html><html><head><meta charset="utf-8">
     <link rel="stylesheet" href="../web/dist/assets/${css}">
     </head><body style="background:#fff;padding:2rem;max-width:1100px;margin:auto">${body}</body></html>`)
})

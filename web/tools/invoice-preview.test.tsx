/**
 * Not a unit test — a rendering harness for the subscription invoice.
 *
 * A challan is the paper a parent argues with; this is the paper a school's
 * ACCOUNTANT argues with, and it is the only document this business sends its
 * own customers. Whether the NTN, the amount in words and the withholding note
 * actually fit and read sensibly is not something an assertion about markup can
 * answer.
 *
 * Four cases, because each has been wrong at some point in a real invoicing
 * system and none of them is visible from the happy path:
 *
 *   1. the ordinary invoice, tax and withholding note included
 *   2. the SAME invoice with the seller not configured — the case that ships by
 *      accident, prints without an NTN, and the school never mentions it
 *   3. a discounted invoice, half paid, with the withheld tax on the receipt
 *   4. a credit note, and a voided invoice — neither may come off the printer
 *      looking like a demand for money
 *
 * Excluded from `npm test` by vitest's test.include; run with `npm run harness`.
 */
import { it } from 'vitest'
import { InvoiceDoc } from '../src/components/InvoiceDoc'
import type { InvoiceDocument } from '../src/lib/platform'
import { writePage } from './harness'

const SELLER = {
  name: 'Brndsh Technologies',
  ntn: '1234567-8',
  strn: '3277876543210',
  address: 'Office 4, 2nd Floor, Gulberg III, Lahore',
  city: 'Lahore',
  phone: '0300-9998887',
  email: 'billing@example.test',
  website: null,
}

const BUYER = {
  school_id: 's1',
  name: 'Al Qalam Public School, Ghauri Town',
  address: 'Ghauri Town Phase 5B, Islamabad',
  city: 'Islamabad',
  phone: '051-4931200',
  email: 'office@alqalam.test',
  attention: 'Rashid Ahmed (Principal)',
}

const base: InvoiceDocument = {
  id: 'i1', kind: 'invoice', doc_no: 'BSH-0014', title: 'INVOICE',
  issued_on: '2026-08-26', due_on: '2026-09-05',
  voided: false, voided_at: null, void_reason: null, credits_doc_no: null,
  seller: SELLER, seller_missing: [], buyer: BUYER,
  lines: [{
    description: 'Growth plan — school management software licence',
    period_start: '2026-09-01', period_end: '2027-08-31', months: 12, cycle: 'yearly',
    amount: 20000, list_amount: null,
  }],
  tax: { pct: 16, amount: 3200, label: 'Sales tax on services @ 16%' },
  totals: { subtotal: 20000, tax: 3200, total: 23200, credited: 0, paid: 0, balance: 23200 },
  amount_in_words: 'Rupees Twenty Three Thousand Two Hundred Only',
  bank: {
    bank_name: 'Meezan Bank', title: 'Brndsh Technologies',
    account: '01234567890123', iban: 'PK36MEZA0000001234567890',
  },
  withholding_note:
    'If you are required to deduct income tax at source under section 153(1)(b), '
    + 'please deduct 8% (Rs 1,856.00) and remit the balance of Rs 21,344.00. Kindly '
    + 'send us the CPR / tax deduction certificate so the deduction can be credited '
    + 'to this invoice.',
  note: null, footer: 'Thank you for your business.',
  payments: [], credit_notes: [],
}

/**
 * The one that ships by accident. Nothing here was ever filled in, so the
 * document prints with placeholders where the seller should be — and a school
 * receiving it will not phone about it, it will simply fail to pay.
 */
const unconfigured: InvoiceDocument = {
  ...base, id: 'i2', doc_no: 'INV-0001',
  seller: { ...SELLER, name: null, ntn: null, strn: null, address: null },
  seller_missing: ['business_name', 'ntn', 'address', 'bank_account'],
  tax: { pct: 0, amount: 0, label: null },
  totals: { subtotal: 20000, tax: 0, total: 20000, credited: 0, paid: 0, balance: 20000 },
  amount_in_words: 'Rupees Twenty Thousand Only',
  bank: { bank_name: null, title: null, account: null, iban: null },
  withholding_note: null,
}

/** Discounted, part-settled, and the withheld tax on the receipt line. */
const discounted: InvoiceDocument = {
  ...base, id: 'i3', doc_no: 'BSH-0015',
  lines: [{
    description: 'Institution plan — school management software licence',
    period_start: '2026-09-01', period_end: '2027-08-31', months: 12, cycle: 'yearly',
    amount: 30000, list_amount: 35000,
  }],
  tax: { pct: 0, amount: 0, label: null },
  // paid is sum(settled) = cash + withheld, so this invoice is CLEAR. The first
  // version of this fixture said 27,600 and left a 2,400 balance — which is
  // exactly defect 4 from 0077's header, written back into the harness by hand.
  // The rendered page is what caught it.
  totals: { subtotal: 30000, tax: 0, total: 30000, credited: 0, paid: 30000, balance: 0 },
  amount_in_words: 'Rupees Thirty Thousand Only',
  note: 'two-year commitment, agreed with the principal in July',
  withholding_note: null,
  payments: [{
    paid_on: '2026-09-02', amount: 27600, method: 'bank', reference: 'HBL-77123',
    tax_withheld: 2400, tax_certificate: null, settled: 30000,
  }],
}

/** A credit note. No bank block, no withholding note: nobody pays this. */
const credit: InvoiceDocument = {
  ...base, id: 'i4', kind: 'credit_note', doc_no: 'CN-0003', title: 'CREDIT NOTE',
  credits_doc_no: 'BSH-0014',
  lines: [{
    description: 'Growth plan — school management software licence',
    period_start: '2026-09-01', period_end: '2027-08-31', months: 12, cycle: 'yearly',
    amount: 6666.67, list_amount: null,
  }],
  tax: { pct: 16, amount: 1066.67, label: 'Sales tax on services @ 16%' },
  totals: {
    subtotal: 6666.67, tax: 1066.67, total: 7733.34,
    credited: 0, paid: 0, balance: 7733.34,
  },
  amount_in_words: 'Rupees Seven Thousand Seven Hundred Thirty Three and Thirty Four Paisa Only',
  bank: null, withholding_note: null,
  note: 'Credit against BSH-0014 — closed in March, four months unused',
  payments: [], credit_notes: [],
}

/** Voided. It must never come off the printer looking valid. */
const voided: InvoiceDocument = {
  ...base, id: 'i5', doc_no: 'BSH-0016',
  voided: true, voided_at: '2026-08-27T09:14:00Z',
  void_reason: 'raised twice — the operator double-clicked Renew',
}

it('writes a subscription invoice preview', () => {
  writePage('../scratch/invoice.html', [
    {
      caption: 'The ordinary case: NTN, sales tax, amount in words, bank details, '
        + 'and the section 153(1)(b) note that tells the school what to withhold '
        + 'and asks for the CPR.',
      node: <InvoiceDoc d={base} />,
    },
    {
      caption: 'The one that ships by accident — nothing configured. The amber '
        + 'warning is screen-only; what would actually PRINT is the placeholders '
        + 'in the letterhead, which is why the warning has to be this loud.',
      node: <InvoiceDoc d={unconfigured} />,
    },
    {
      caption: 'Rs 5,000 off list with the reason on the document, and settled IN '
        + 'FULL by Rs 27,600 of cash plus Rs 2,400 the school paid to the FBR in our '
        + 'name. The balance is zero: the withheld tax was paid, and the CPR line '
        + 'says the certificate has not reached us yet, which is a claim we cannot '
        + 'file — not money the school still owes.',
      node: <InvoiceDoc d={discounted} />,
    },
    {
      caption: 'A credit note: its own series, points at the invoice it credits, '
        + 'no bank block and no withholding note — nobody pays this one.',
      node: <InvoiceDoc d={credit} />,
    },
    {
      caption: 'Voided. Still on the books because deleting history is how a '
        + 'business loses an audit, and stamped so it can never be mistaken for a '
        + 'demand.',
      node: <InvoiceDoc d={voided} />,
    },
  ])
})

import { fmtPKR, fmtAmount, fmtDate, fmtDateTime } from '@/lib/format'
import type { PortalChild, PortalFees } from '@/lib/db'

/**
 * The parent's printable fee statement.
 *
 * WHY THIS FILE EXISTS
 *
 * The portal's Fees tab had a "Print" button that called window.print() on a
 * page with no printable id. The global print rule in index.css hides `body *`
 * and reveals only named ids, so the button produced a BLANK SHEET of paper:
 * every time, on every browser. Nothing threw, nothing logged, the dialog opened
 * normally and the preview was empty. A parent standing at a shop counter paying
 * for a print-out got a blank page and no explanation.
 *
 * WHAT IT DELIBERATELY IS NOT
 *
 * It is not a challan and it is not a receipt, and it says so on its face. A
 * printed page with a school's name, an amount and a due date is exactly what a
 * bank cashier accepts, and this one carries no bank account, no voucher
 * number, no barcode and no school signature, so a parent who took it to a
 * counter would be turned away after queuing. Worse, a parent who paid against
 * it in cash at the school would have no numbered document to hold. So the
 * heading says STATEMENT, and a line under the totals says plainly that the bank
 * will not take it and where to get the thing that the bank will take.
 *
 * TWO LABELS THAT HAVE TO BE EXACT
 *
 *   * fn_portal_child_fees returns invoices for THIS CHILD and receipts for the
 *     WHOLE FAMILY (`p.family_id = v_fam`). On screen the heading "Your
 *     receipts" is harmless. On a page headed with one child's name it is not: a
 *     parent of three would read one child's statement, see payments made for
 *     the other two, and conclude that this child's dues had been settled. Every
 *     payment row is therefore labelled as family-wide, with the family total
 *     printed beside the child's own balance.
 *
 *   * The timestamp is on the page, not just the date. A balance moves the
 *     moment the office banks a cheque, and a statement printed this morning is
 *     evidence of this morning. Undated print-outs are how a fee dispute becomes
 *     unresolvable.
 *
 * The school name comes in as a prop, from fn_portal_me. It does NOT use
 * useSchoolName(): a parent account has no direct read on school_settings by
 * design, so that hook would silently fall back to the build-time name and print
 * the wrong school on the page.
 *
 * This is the DOCUMENT only, the way InvoiceDoc is. The dialog around it. The
 * backdrop, the Print button, the Close button: belongs to the page, so the
 * rendering harness can put five of these on one sheet without five fixed
 * overlays stacking on top of one another.
 */
export function PortalStatement({
  schoolName,
  parentName,
  child,
  fees,
}: {
  schoolName: string | null
  parentName: string | null
  child: PortalChild | undefined
  fees: PortalFees
}) {
  const printedAt = new Date().toISOString()
  const billed = fees.invoices.reduce((s, i) => s + Number(i.charge || 0), 0)
  const paid = fees.invoices.reduce((s, i) => s + Number(i.paid || 0), 0)
  const unpaidCount = fees.invoices.filter((i) => Number(i.outstanding) > 0).length
  /* Family-wide, like the list it totals. It will usually NOT equal the Paid
     column above, and that is the point of the label: this is every rupee the
     family has handed over, across all its children. */
  const received = fees.receipts.reduce((s, r) => s + Number(r.amount || 0), 0)

  return (
    <div id="portal-statement" className="bg-white p-5 text-slate-900 sm:p-7">
      {/* --- heading ------------------------------------------------------ */}
      <div className="border-b-2 border-slate-800 pb-3 text-center">
        <div className="text-lg font-bold uppercase tracking-wide">{schoolName ?? 'School'}</div>
        <div className="mt-0.5 text-xs font-semibold uppercase tracking-widest text-slate-600">
          Fee Statement
        </div>
        <div className="mt-1 text-[11px] text-slate-500">
          Printed {fmtDateTime(printedAt)} from the parent portal
        </div>
      </div>

      {/* --- who --------------------------------------------------------- */}
      <div className="mt-4 grid gap-x-6 gap-y-1 text-sm sm:grid-cols-2">
        <Field label="Student" value={child?.full_name ?? '-'} />
        <Field label="GR No" value={child?.gr_no ?? '-'} />
        <Field
          label="Class"
          value={
            [child?.class_name, child?.section_name].filter(Boolean).join(' · ') || 'Not enrolled'
          }
        />
        <Field label="Parent / guardian" value={parentName ?? '-'} />
      </div>

      {/* --- the numbers ------------------------------------------------- */}
      <div className="mt-4 grid gap-2 sm:grid-cols-3">
        <Box label="This student owes" value={fmtPKR(fees.balance)} strong={fees.balance > 0} />
        <Box label="Whole family owes" value={fmtPKR(fees.family_outstanding)} />
        <Box label="Paid in advance" value={fmtPKR(fees.family_credit)} />
      </div>
      {fees.family_credit > 0 && (
        <p className="mt-2 text-[11px] text-slate-600">
          The {fmtPKR(fees.family_credit)} held in advance is applied automatically to the next
          challan, so the amount asked for next month will be lower by that much.
        </p>
      )}

      {/* --- challans ---------------------------------------------------- */}
      <h3 className="mt-5 border-b border-slate-300 pb-1 text-xs font-semibold uppercase tracking-wide text-slate-700">
        Challans raised for this student
      </h3>
      {fees.invoices.length === 0 ? (
        <p className="mt-2 text-sm text-slate-500">Nothing has been billed yet.</p>
      ) : (
        /* Four columns, not five, and the due date sits UNDER the month rather
           than in a column of its own. On a 360px phone, which is most of the
           parents. Five columns pushed Outstanding off the right edge into a
           sideways scroll the parent had no reason to know was there. The one
           number they opened the page for was the one they could not see. */
        <table className="mt-2 w-full text-sm">
          <thead>
            <tr className="text-left text-[11px] uppercase tracking-wide text-slate-500">
              <th className="py-1 pr-2 font-medium">Challan</th>
              <th className="py-1 pr-2 text-right font-medium">Billed (Rs)</th>
              <th className="py-1 pr-2 text-right font-medium">Paid (Rs)</th>
              <th className="py-1 text-right font-medium">Unpaid (Rs)</th>
            </tr>
          </thead>
          <tbody className="divide-y divide-slate-100">
            {fees.invoices.map((inv, i) => (
              <tr key={i}>
                <td className="py-1.5 pr-2 align-top">
                  {monthName(inv.period_month)}
                  {inv.due_date && (
                    <span className="block text-[11px] text-slate-500">
                      due {fmtDate(inv.due_date)}
                    </span>
                  )}
                </td>
                <td className="whitespace-nowrap py-1.5 pr-2 text-right align-top tabular-nums">
                  {fmtAmount(inv.charge)}
                </td>
                <td className="whitespace-nowrap py-1.5 pr-2 text-right align-top tabular-nums">
                  {fmtAmount(inv.paid)}
                </td>
                <td
                  className={`whitespace-nowrap py-1.5 text-right align-top tabular-nums ${
                    Number(inv.outstanding) > 0 ? 'font-semibold' : 'text-slate-500'
                  }`}
                >
                  {fmtAmount(inv.outstanding)}
                </td>
              </tr>
            ))}
          </tbody>
          <tfoot>
            <tr className="border-t-2 border-slate-800 font-semibold">
              <td className="py-1.5 pr-2">Total</td>
              <td className="whitespace-nowrap py-1.5 pr-2 text-right tabular-nums">
                {fmtAmount(billed)}
              </td>
              <td className="whitespace-nowrap py-1.5 pr-2 text-right tabular-nums">
                {fmtAmount(paid)}
              </td>
              <td className="whitespace-nowrap py-1.5 text-right tabular-nums">
                {fmtAmount(billed - paid)}
              </td>
            </tr>
          </tfoot>
        </table>
      )}
      {/* The two totals answer different questions, and a parent comparing them
          will assume one of them is wrong. Said out loud instead. */}
      {billed - paid !== Number(fees.balance) && (
        <p className="mt-2 text-[11px] text-slate-600">
          The table totals the challans listed above: {fmtPKR(billed - paid)} unpaid across{' '}
          {unpaidCount} challan{unpaidCount === 1 ? '' : 's'}. "This student owes"{' '}
          ({fmtPKR(fees.balance)}) is the school's running balance for the student, which also
          counts any advance held and any adjustment made in the office.
        </p>
      )}

      {/* --- payments ---------------------------------------------------- */}
      <h3 className="mt-5 border-b border-slate-300 pb-1 text-xs font-semibold uppercase tracking-wide text-slate-700">
        Payments received from this family
      </h3>
      {fees.receipts.length === 0 ? (
        <p className="mt-2 text-sm text-slate-500">No payments recorded yet.</p>
      ) : (
        <>
          <p className="mt-1 text-[11px] text-slate-600">
            These are payments for the WHOLE family, not for {firstName(child?.full_name)} alone. A
            payment listed here may have been made against another child's challan.
          </p>
          {/* Three columns for the same reason as above: the amount must never be
              the thing that scrolls off. How it was paid goes under the receipt
              number, where it reads as part of the receipt rather than as a
              column competing for width. */}
          <table className="mt-2 w-full text-sm">
            <thead>
              <tr className="text-left text-[11px] uppercase tracking-wide text-slate-500">
                <th className="py-1 pr-2 font-medium">Receipt</th>
                <th className="py-1 pr-2 font-medium">Date</th>
                <th className="py-1 text-right font-medium">Amount (Rs)</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-slate-100">
              {fees.receipts.map((r) => (
                <tr key={r.receipt_no}>
                  <td className="py-1.5 pr-2 align-top">
                    #{r.receipt_no}
                    {r.method && (
                      <span className="block text-[11px] capitalize text-slate-500">
                        {r.method.replace(/_/g, ' ')}
                      </span>
                    )}
                  </td>
                  <td className="py-1.5 pr-2 align-top text-slate-600">{fmtDate(r.paid_on)}</td>
                  <td className="whitespace-nowrap py-1.5 text-right align-top tabular-nums">
                    {fmtAmount(r.amount)}
                  </td>
                </tr>
              ))}
            </tbody>
            <tfoot>
              <tr className="border-t-2 border-slate-800 font-semibold">
                <td className="py-1.5 pr-2" colSpan={2}>
                  Total received
                </td>
                <td className="whitespace-nowrap py-1.5 text-right tabular-nums">
                  {fmtAmount(received)}
                </td>
              </tr>
            </tfoot>
          </table>
        </>
      )}

      {/* --- what this page is not --------------------------------------- */}
      <div className="mt-6 border border-slate-400 px-3 py-2 text-[11px] leading-relaxed text-slate-700">
        <span className="font-semibold">This is a statement, not a payment voucher.</span> A bank
        will not accept it and it is not a receipt for money paid. To pay at a bank, ask the school
        office for a fee challan. If you have already paid and a challan above still shows as
        unpaid, take the receipt number to the office.
      </div>
      <div className="mt-2 text-center text-[10px] text-slate-400">
        Printed by the parent from the online portal. Balances shown are as at the time printed.
      </div>
    </div>
  )
}

function Field({ label, value }: { label: string; value: string }) {
  return (
    <div className="flex gap-2">
      <span className="w-32 shrink-0 text-slate-500">{label}</span>
      <span className="font-medium">{value}</span>
    </div>
  )
}

function Box({ label, value, strong }: { label: string; value: string; strong?: boolean }) {
  return (
    <div className="rounded border border-slate-300 px-3 py-2">
      <div className="text-[10px] uppercase tracking-wide text-slate-500">{label}</div>
      <div className={`tabular-nums ${strong ? 'text-base font-bold' : 'text-sm font-semibold'}`}>
        {value}
      </div>
    </div>
  )
}

/** "Other charges" is the honest label for an invoice with no month. An
 *  admission fee or a one-off, which is not a monthly challan at all. */
function monthName(m: string | null): string {
  if (!m) return 'Other charges'
  const d = new Date(m.length === 10 ? `${m}T00:00:00` : m)
  return isNaN(d.getTime())
    ? '-'
    : d.toLocaleDateString('en-PK', { month: 'long', year: 'numeric' })
}

function firstName(n: string | null | undefined): string {
  return (n ?? 'this student').split(' ')[0]
}

import { useMemo } from 'react'
import type { LedgerEntry } from '@/lib/db'
import { fmtPKR, fmtDate, fmtDateTime } from '@/lib/format'

/**
 * The fee statement: every entry that moved a child's balance, in the order
 * they happened, with a running total.
 *
 * WHY THIS EXISTS
 *
 * Before it, "what does this family owe" was a single number with no workings.
 * The Fees tab listed challans and a balance, and when the two disagreed there
 * was nothing on the page to say why. They disagreed whenever a fine, a
 * discount or a hand-keyed adjustment was involved, which is most families by
 * the second term.
 *
 * The hand-keyed adjustment was the worst of it. `fn_add_adjustment` could add a
 * van fare or waive a whole balance, and NOTHING in the product displayed it
 * afterwards. A parent saw Rs 2,350 owed above Rs 2,100 of challans; an owner
 * looking for who had waived what had no screen to look at.
 *
 * ONE COMPONENT, TWO AUDIENCES
 *
 * The office and the parent read the same rows, out of the same database
 * function, rendered by this file. That is deliberate and it is the point: a
 * fee argument at the counter is settled by both sides looking at one document.
 * The parent's copy leaves out `recorded_by`, because which member of staff
 * keyed an entry is the school's business.
 *
 * IT CHECKS ITSELF ON SCREEN
 *
 * `closesOn` is the last row's running total. `balance` is what
 * `student_balance()` says independently. They are the same arithmetic and must
 * agree; if they ever do not, the component says so in place of quietly
 * printing whichever it was handed. A statement that silently disagrees with
 * the balance beside it is worse than no statement, because somebody will act
 * on it.
 */

const KIND_LABEL: Record<LedgerEntry['kind'], string> = {
  charge: 'Charge',
  discount: 'Discount',
  fine: 'Late fee',
  adjustment: 'Adjustment',
  payment: 'Payment',
}

const KIND_TONE: Record<LedgerEntry['kind'], string> = {
  charge: 'bg-slate-100 text-slate-600',
  discount: 'bg-info-50 text-info-700',
  fine: 'bg-amber-50 text-amber-700',
  adjustment: 'bg-brand-50 text-brand-700',
  payment: 'bg-money-50 text-money-700',
}

export function FeeStatement({
  entries, balance, showRecordedBy = false, emptyNote,
}: {
  entries: LedgerEntry[]
  /** What student_balance() says, read separately. Used to prove the statement. */
  balance: number
  showRecordedBy?: boolean
  emptyNote?: string
}) {
  const closesOn = entries.length ? entries[entries.length - 1].balance_after : 0
  // Rounded before comparing: both sides come back as numeric strings from
  // Postgres and go through Number(), and a paisa of float drift would put a
  // scary warning on a statement that is in fact correct.
  const agrees = Math.round(closesOn * 100) === Math.round(balance * 100)

  if (!entries.length) {
    return (
      <p className="rounded-lg border border-slate-200 bg-slate-50 px-3 py-4 text-sm text-slate-500">
        {emptyNote ?? 'Nothing has been charged or paid yet, so there is no statement to show.'}
      </p>
    )
  }

  return (
    <div className="space-y-2">
      <div className="overflow-x-auto rounded-lg border border-slate-200">
        <table className="w-full min-w-[36rem] text-sm">
          <thead className="bg-slate-50 text-left text-xs uppercase tracking-wide text-slate-500">
            <tr>
              <th className="px-3 py-2 font-medium">Date</th>
              <th className="px-3 py-2 font-medium">Details</th>
              <th className="px-3 py-2 text-right font-medium">Charged</th>
              <th className="px-3 py-2 text-right font-medium">Paid / off</th>
              <th className="px-3 py-2 text-right font-medium">Balance</th>
              {showRecordedBy && <th className="px-3 py-2 font-medium">By</th>}
            </tr>
          </thead>
          <tbody className="divide-y divide-slate-100">
            {entries.map((e) => (
              <tr key={e.seq} className="align-top">
                <td className="whitespace-nowrap px-3 py-2 text-slate-500">{fmtDate(e.entry_on)}</td>
                <td className="px-3 py-2">
                  <span className={`mr-2 rounded px-1.5 py-0.5 text-[11px] font-medium ${KIND_TONE[e.kind] ?? 'bg-slate-100 text-slate-600'}`}>
                    {KIND_LABEL[e.kind] ?? e.kind}
                  </span>
                  <span className="text-slate-800">{e.particulars}</span>
                  {e.reference && <span className="ml-1 text-xs text-slate-400">{e.reference}</span>}
                </td>
                <td className="whitespace-nowrap px-3 py-2 text-right tabular-nums text-slate-700">
                  {e.debit > 0 ? fmtPKR(e.debit) : ''}
                </td>
                <td className="whitespace-nowrap px-3 py-2 text-right tabular-nums text-money-700">
                  {e.credit > 0 ? fmtPKR(e.credit) : ''}
                </td>
                <td className="whitespace-nowrap px-3 py-2 text-right font-medium tabular-nums text-slate-800">
                  {fmtPKR(e.balance_after)}
                </td>
                {showRecordedBy && (
                  <td className="whitespace-nowrap px-3 py-2 text-xs text-slate-400">{e.recorded_by || '-'}</td>
                )}
              </tr>
            ))}
          </tbody>
        </table>
      </div>

      {agrees ? (
        <p className="text-xs text-slate-500">
          {entries.length} entr{entries.length === 1 ? 'y' : 'ies'}, closing at{' '}
          <span className="font-medium text-slate-700">{fmtPKR(closesOn)}</span>, which is the balance shown above.
        </p>
      ) : (
        <p className="rounded-lg border border-danger-200 bg-danger-50 px-3 py-2 text-xs text-danger-800">
          This statement closes at {fmtPKR(closesOn)} but the balance is {fmtPKR(balance)}. The two are
          the same arithmetic, so a difference means this school&rsquo;s database is part-way through an
          update. Apply the latest file from supabase/bundles and reload before acting on either figure.
        </p>
      )}
    </div>
  )
}

/**
 * The printable version, headed like a document rather than a screen.
 *
 * It is a STATEMENT and says so on its face. A printed page carrying a school
 * name, an amount and a date is exactly what a parent will try to pay against at
 * a bank counter, and this one has no bank account, no voucher number and no
 * barcode, so they would queue and be turned away. PortalStatement learned that
 * the hard way; the same sentence is here for the same reason.
 */
export function FeeStatementDoc({
  id, schoolName, studentName, grNo, className, entries, balance, showRecordedBy = false,
}: {
  id: string
  schoolName: string | null
  studentName: string
  grNo?: string | null
  className?: string | null
  entries: LedgerEntry[]
  balance: number
  showRecordedBy?: boolean
}) {
  const printedAt = useMemo(() => new Date().toISOString(), [])
  const charged = entries.reduce((a, e) => a + e.debit, 0)
  const credited = entries.reduce((a, e) => a + e.credit, 0)

  return (
    <div id={id} className="bg-white p-6 text-[13px] text-slate-900">
      <div className="border-b-2 border-slate-800 pb-2">
        <div className="text-lg font-bold">{schoolName || 'School'}</div>
        <div className="text-xs uppercase tracking-widest text-slate-500">Fee statement</div>
      </div>

      <div className="mt-3 flex flex-wrap justify-between gap-2 text-xs">
        <div>
          <div><span className="text-slate-500">Student:</span> <span className="font-medium">{studentName}</span></div>
          {grNo && <div><span className="text-slate-500">GR No:</span> {grNo}</div>}
          {className && <div><span className="text-slate-500">Class:</span> {className}</div>}
        </div>
        <div className="text-right">
          {/* The TIME, not just the date. A balance moves the moment the office
              banks a cheque, and an undated print-out is how a fee dispute
              becomes unresolvable. */}
          <div><span className="text-slate-500">Printed:</span> {fmtDateTime(printedAt)}</div>
          <div><span className="text-slate-500">Balance now:</span> <span className="font-semibold">{fmtPKR(balance)}</span></div>
        </div>
      </div>

      <table className="mt-4 w-full border-collapse text-[12px]">
        <thead>
          <tr className="border-y border-slate-300 text-left">
            <th className="py-1.5 pr-2 font-semibold">Date</th>
            <th className="py-1.5 pr-2 font-semibold">Details</th>
            <th className="py-1.5 pr-2 text-right font-semibold">Charged</th>
            <th className="py-1.5 pr-2 text-right font-semibold">Paid / off</th>
            <th className="py-1.5 text-right font-semibold">Balance</th>
            {showRecordedBy && <th className="py-1.5 pl-2 font-semibold">By</th>}
          </tr>
        </thead>
        <tbody>
          {entries.map((e) => (
            <tr key={e.seq} className="border-b border-slate-100">
              <td className="whitespace-nowrap py-1 pr-2">{fmtDate(e.entry_on)}</td>
              <td className="py-1 pr-2">
                {e.particulars}
                {e.reference && <span className="text-slate-500"> ({e.reference})</span>}
              </td>
              <td className="whitespace-nowrap py-1 pr-2 text-right tabular-nums">{e.debit > 0 ? fmtPKR(e.debit) : ''}</td>
              <td className="whitespace-nowrap py-1 pr-2 text-right tabular-nums">{e.credit > 0 ? fmtPKR(e.credit) : ''}</td>
              <td className="whitespace-nowrap py-1 text-right font-medium tabular-nums">{fmtPKR(e.balance_after)}</td>
              {showRecordedBy && <td className="whitespace-nowrap py-1 pl-2 text-slate-500">{e.recorded_by || ''}</td>}
            </tr>
          ))}
        </tbody>
        <tfoot>
          <tr className="border-t-2 border-slate-800 font-semibold">
            <td className="py-1.5" colSpan={2}>Total</td>
            <td className="py-1.5 pr-2 text-right tabular-nums">{fmtPKR(charged)}</td>
            <td className="py-1.5 pr-2 text-right tabular-nums">{fmtPKR(credited)}</td>
            <td className="py-1.5 text-right tabular-nums">{fmtPKR(balance)}</td>
            {showRecordedBy && <td />}
          </tr>
        </tfoot>
      </table>

      <p className="mt-4 border-t border-dashed border-slate-300 pt-2 text-[11px] leading-relaxed text-slate-600">
        This is a statement of account, not a fee challan and not a receipt. A bank will not accept
        it: it carries no account number, no voucher code and no school signature. Ask the school
        office for a challan if you need to pay at a bank, or for a receipt for money already paid.
      </p>
    </div>
  )
}

import { fmtPKR, fmtDate } from '@/lib/format'
import { useSchoolName } from '@/hooks/useSchoolName'
import { useSchoolLogo } from '@/hooks/useSchoolLogo'

export interface ReceiptData {
  receiptNo: number
  /** The student, or — for a family payment — whoever handed the money over. */
  studentName: string
  grNo?: string | null
  amount: number
  method: string
  balanceAfter: number
  note?: string | null
  date?: string
  /**
   * A FAMILY payment: one amount, one receipt, several children.
   *
   * These four fields exist so there is still only ONE receipt component. Two
   * would eventually disagree about a total, and the receipt is the piece of
   * paper the parent keeps and brings back when they disagree with the office.
   *
   * `covers` matters most. Family allocation is oldest-month-first across
   * siblings, so a father paying Rs 9,000 for three children cannot tell from
   * the amount alone which child's dues moved. A receipt that does not name them
   * is exactly the silent allocation that causes arguments at the counter.
   */
  payerLabel?: string
  balanceLabel?: string
  covers?: { label: string; amount: number }[]
  advance?: number
}

/** A printable fee receipt. Print with the browser (Ctrl+P); print CSS hides everything else. */
export function Receipt({ data, onClose }: { data: ReceiptData; onClose: () => void }) {
  const schoolName = useSchoolName()
  const logo = useSchoolLogo()
  return (
    <div className="fixed inset-0 z-50 flex items-start justify-center overflow-y-auto bg-black/40 p-4 sm:items-center print:static print:bg-white print:p-0">
      <div className="w-full max-w-sm rounded-lg bg-white p-6 shadow-lg print:max-w-none print:shadow-none" id="receipt">
        <div className="text-center">
          {logo && (
            <img src={logo} alt="" className="mx-auto mb-1 max-h-12 max-w-[8rem] object-contain" />
          )}
          <div className="text-lg font-semibold text-slate-800">{schoolName}</div>
          <div className="text-xs uppercase tracking-wide text-slate-500">Fee Receipt</div>
        </div>
        <div className="mt-4 space-y-1.5 text-sm">
          <Row label="Receipt No" value={`#${data.receiptNo}`} />
          <Row label="Date" value={fmtDate(data.date ?? new Date().toISOString())} />
          <Row label={data.payerLabel ?? 'Student'} value={data.studentName} />
          {data.grNo && <Row label="GR No" value={data.grNo} />}
          <Row label="Method" value={data.method} />
          {data.note && <Row label="Note" value={data.note} />}
          <div className="my-2 border-t border-dashed border-slate-300" />
          <Row label="Amount Paid" value={fmtPKR(data.amount)} strong />
          {data.advance != null && data.advance > 0 && (
            <Row label="Held as advance" value={fmtPKR(data.advance)} />
          )}
          <Row label={data.balanceLabel ?? 'Balance After'} value={fmtPKR(data.balanceAfter)} />
          {data.covers && data.covers.length > 0 && (
            <>
              <div className="my-2 border-t border-dashed border-slate-300" />
              <div className="text-slate-500">Applied for</div>
              {/* A row per invoice, amount right-aligned in the same column as
                  every other figure on the receipt. Built from fields rather
                  than from one pre-formatted string, because a string wraps
                  mid-amount on a receipt-width page — "Rs" on one line and
                  "3,000" on the next is how a figure gets misread. */}
              <ul className="space-y-0.5 text-slate-700">
                {data.covers.map((c, i) => (
                  <li key={i} className="flex justify-between gap-3">
                    <span className="min-w-0">{c.label}</span>
                    <span className="shrink-0 whitespace-nowrap tabular-nums">
                      {fmtPKR(c.amount)}
                    </span>
                  </li>
                ))}
              </ul>
            </>
          )}
        </div>
        <div className="mt-6 text-center text-[10px] text-slate-400">
          Computer-generated receipt. Keep for your records.
        </div>
        <div className="mt-5 flex gap-2 print:hidden">
          <button onClick={() => window.print()} className="flex-1 rounded bg-brand-600 px-3 py-2 text-sm font-medium text-white hover:bg-brand-700">
            Print
          </button>
          <button onClick={onClose} className="flex-1 rounded border border-slate-300 px-3 py-2 text-sm hover:bg-slate-50">
            Close
          </button>
        </div>
      </div>
    </div>
  )
}

function Row({ label, value, strong }: { label: string; value: string; strong?: boolean }) {
  return (
    <div className="flex justify-between">
      <span className="text-slate-500">{label}</span>
      <span className={strong ? 'font-semibold text-slate-800' : 'text-slate-700'}>{value}</span>
    </div>
  )
}

import { fmtPKR, fmtDate } from '@/lib/format'
import { useSchoolName } from '@/hooks/useSchoolName'

export interface ReceiptData {
  receiptNo: number
  studentName: string
  grNo?: string | null
  amount: number
  method: string
  balanceAfter: number
  note?: string | null
  date?: string
}

/** A printable fee receipt. Print with the browser (Ctrl+P); print CSS hides everything else. */
export function Receipt({ data, onClose }: { data: ReceiptData; onClose: () => void }) {
  const schoolName = useSchoolName()
  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/40 p-4 print:static print:bg-white print:p-0">
      <div className="w-full max-w-sm rounded-lg bg-white p-6 shadow-lg print:max-w-none print:shadow-none" id="receipt">
        <div className="text-center">
          <div className="text-lg font-semibold text-slate-800">{schoolName}</div>
          <div className="text-xs uppercase tracking-wide text-slate-500">Fee Receipt</div>
        </div>
        <div className="mt-4 space-y-1.5 text-sm">
          <Row label="Receipt No" value={`#${data.receiptNo}`} />
          <Row label="Date" value={fmtDate(data.date ?? new Date().toISOString())} />
          <Row label="Student" value={data.studentName} />
          {data.grNo && <Row label="GR No" value={data.grNo} />}
          <Row label="Method" value={data.method} />
          {data.note && <Row label="Note" value={data.note} />}
          <div className="my-2 border-t border-dashed border-slate-300" />
          <Row label="Amount Paid" value={fmtPKR(data.amount)} strong />
          <Row label="Balance After" value={fmtPKR(data.balanceAfter)} />
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

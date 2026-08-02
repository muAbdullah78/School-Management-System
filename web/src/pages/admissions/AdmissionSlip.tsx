import { useSchoolName } from '@/hooks/useSchoolName'
import { fmtDate } from '@/lib/format'

export interface AdmissionSlipData {
  grNo: string
  rollNo: string | null
  fullName: string
  fatherName: string | null
  className: string
  sectionName: string | null
  admissionDate: string
}

/** A printable admission slip. Print with the browser (Ctrl+P); the print CSS
 *  in index.css hides everything except the #admit-slip element. */
export function AdmissionSlip({ data, onClose }: { data: AdmissionSlipData; onClose: () => void }) {
  const schoolName = useSchoolName()
  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/40 p-4 print:static print:bg-white print:p-0">
      <div className="w-full max-w-sm rounded-lg bg-white p-6 shadow-lg print:max-w-none print:shadow-none" id="admit-slip">
        <div className="text-center">
          <div className="text-lg font-semibold text-slate-800">{schoolName}</div>
          <div className="text-xs uppercase tracking-wide text-slate-500">Admission Slip</div>
        </div>
        <div className="mt-4 space-y-1.5 text-sm">
          <Row label="GR No" value={data.grNo} strong />
          <Row label="Date" value={fmtDate(data.admissionDate)} />
          <Row label="Student" value={data.fullName} />
          {data.fatherName && <Row label="Father" value={data.fatherName} />}
          <Row label="Class" value={data.sectionName ? `${data.className} · ${data.sectionName}` : data.className} />
          {data.rollNo && <Row label="Roll No" value={data.rollNo} />}
        </div>
        <div className="mt-6 text-center text-[10px] text-slate-400">
          Please keep this slip. The GR number is the student's lifelong reference.
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

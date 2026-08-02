import { useSchoolName } from '@/hooks/useSchoolName'
import { fmtDate } from '@/lib/format'
import { ATTENDANCE_STATUSES, ATTENDANCE_SHORT } from '@/lib/constants'
import type { AttendanceStatus } from '@/lib/db'

export interface AttendanceSheetRow {
  roll_no: string | null
  full_name: string
  status: AttendanceStatus
}
export interface AttendanceSheetData {
  className: string
  sectionName: string | null
  date: string
  rows: AttendanceSheetRow[]
}

/** A printable daily attendance sheet. Print with the browser (Ctrl+P); the
 *  print CSS in index.css hides everything except the #att-sheet element. */
export function AttendanceSheet({ data, onClose }: { data: AttendanceSheetData; onClose: () => void }) {
  const schoolName = useSchoolName()
  const counts = ATTENDANCE_STATUSES.map((s) => ({
    ...s,
    n: data.rows.filter((r) => r.status === s.value).length,
  }))

  return (
    <div className="fixed inset-0 z-50 flex items-start justify-center overflow-y-auto bg-black/40 p-4 print:static print:block print:bg-white print:p-0">
      <div className="w-full max-w-3xl rounded-lg bg-white p-6 shadow-lg print:max-w-none print:shadow-none" id="att-sheet">
        <div className="text-center">
          <div className="text-lg font-semibold text-slate-800">{schoolName}</div>
          <div className="text-xs uppercase tracking-wide text-slate-500">Daily Attendance Sheet</div>
        </div>
        <div className="mt-3 flex flex-wrap justify-between gap-2 text-sm text-slate-700">
          <span><span className="text-slate-500">Class:</span> {data.className}
            {data.sectionName ? ` · Section ${data.sectionName}` : ''}</span>
          <span><span className="text-slate-500">Date:</span> {fmtDate(data.date)}</span>
          <span><span className="text-slate-500">Students:</span> {data.rows.length}</span>
        </div>

        <table className="mt-4 w-full border-collapse text-sm">
          <thead>
            <tr className="border-y border-slate-300 text-left text-xs uppercase tracking-wide text-slate-500">
              <th className="py-1.5 pr-2 w-16">Roll</th>
              <th className="py-1.5 pr-2">Student</th>
              <th className="py-1.5 pr-2 w-24">Status</th>
              <th className="py-1.5 w-40">Remarks</th>
            </tr>
          </thead>
          <tbody>
            {data.rows.map((r, i) => (
              <tr key={i} className="border-b border-slate-100">
                <td className="py-1.5 pr-2 text-slate-600">{r.roll_no ?? '—'}</td>
                <td className="py-1.5 pr-2 text-slate-800">{r.full_name}</td>
                <td className="py-1.5 pr-2 font-medium">{ATTENDANCE_SHORT[r.status] ?? r.status}</td>
                <td className="py-1.5 text-slate-400">&nbsp;</td>
              </tr>
            ))}
            {data.rows.length === 0 && (
              <tr><td colSpan={4} className="py-3 text-slate-400">No students in this section.</td></tr>
            )}
          </tbody>
        </table>

        <div className="mt-4 flex flex-wrap gap-x-4 gap-y-1 text-xs text-slate-600">
          {counts.map((c) => (
            <span key={c.value}><span className="font-semibold">{c.short}</span> {c.label}: {c.n}</span>
          ))}
        </div>

        <div className="mt-8 flex justify-between text-xs text-slate-500">
          <span>Class Teacher: ______________________</span>
          <span>Principal: ______________________</span>
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

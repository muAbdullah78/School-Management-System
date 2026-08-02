import { useSchoolName } from '@/hooks/useSchoolName'
import { fmtDate } from '@/lib/format'
import type { ResultCardRow } from '@/lib/db'

/** A printable result card, rendered from the card's frozen snapshot so a
 *  reprint is byte-identical. Print with the browser (Ctrl+P); the print CSS
 *  in index.css hides everything except #result-card. */
export function ResultCardPrint({
  card, termName, className, sectionName, onClose,
}: {
  card: ResultCardRow
  termName: string
  className: string
  sectionName: string | null
  onClose: () => void
}) {
  const schoolName = useSchoolName()
  const f = card.frozen

  return (
    <div className="fixed inset-0 z-50 flex items-start justify-center overflow-y-auto bg-black/40 p-4 print:static print:block print:bg-white print:p-0">
      <div className="w-full max-w-2xl rounded-lg bg-white p-6 shadow-lg print:max-w-none print:shadow-none" id="result-card">
        <div className="text-center">
          <div className="text-xl font-semibold text-slate-800">{schoolName}</div>
          <div className="text-xs uppercase tracking-wide text-slate-500">Result Card — {termName}</div>
        </div>

        <div className="mt-4 grid grid-cols-2 gap-y-1 text-sm text-slate-700">
          <span><span className="text-slate-500">Student:</span> {card.full_name}</span>
          <span className="text-right"><span className="text-slate-500">GR No:</span> {card.gr_no ?? '—'}</span>
          <span><span className="text-slate-500">Class:</span> {className}{sectionName ? ` · ${sectionName}` : ''}</span>
          <span className="text-right"><span className="text-slate-500">Roll No:</span> {card.roll_no ?? '—'}</span>
        </div>

        {f.withheld && (
          <div className="mt-4 rounded border border-red-300 bg-red-50 px-3 py-2 text-center text-sm font-semibold text-red-700">
            RESULT WITHHELD — outstanding dues must be cleared.
          </div>
        )}

        <table className="mt-4 w-full border-collapse text-sm">
          <thead>
            <tr className="border-y border-slate-300 text-left text-xs uppercase tracking-wide text-slate-500">
              <th className="py-1.5 pr-2">Subject</th>
              <th className="py-1.5 pr-2 w-20 text-right">Max</th>
              <th className="py-1.5 pr-2 w-20 text-right">Obtained</th>
              <th className="py-1.5 w-20 text-right">Grade</th>
            </tr>
          </thead>
          <tbody>
            {f.subjects.map((s, i) => (
              <tr key={i} className="border-b border-slate-100">
                <td className="py-1.5 pr-2 text-slate-800">{s.subject}</td>
                <td className="py-1.5 pr-2 text-right text-slate-600">{s.max}</td>
                <td className="py-1.5 pr-2 text-right text-slate-800">{s.is_absent ? 'ABS' : (s.marks ?? '—')}</td>
                <td className="py-1.5 text-right font-medium">{s.grade ?? '—'}</td>
              </tr>
            ))}
          </tbody>
          <tfoot>
            <tr className="border-t border-slate-300 font-semibold text-slate-800">
              <td className="py-1.5 pr-2">Total</td>
              <td className="py-1.5 pr-2 text-right">{f.total_max}</td>
              <td className="py-1.5 pr-2 text-right">{f.total_marks}</td>
              <td className="py-1.5 text-right">{f.grade ?? '—'}</td>
            </tr>
          </tfoot>
        </table>

        <div className="mt-4 flex flex-wrap justify-between gap-2 text-sm text-slate-700">
          <span><span className="text-slate-500">Percentage:</span> {f.percentage == null ? '—' : `${f.percentage}%`}</span>
          <span><span className="text-slate-500">Grade:</span> {f.grade ?? '—'}</span>
          <span><span className="text-slate-500">Position:</span> {f.position ?? '—'}</span>
          <span><span className="text-slate-500">Attendance:</span> {f.attendance_pct == null ? '—' : `${f.attendance_pct}%`}</span>
        </div>

        <div className="mt-8 flex justify-between text-xs text-slate-500">
          <span>Class Teacher: ______________</span>
          <span>Principal: ______________</span>
          <span>Date: {fmtDate(new Date().toISOString())}</span>
        </div>

        <div className="mt-5 flex gap-2 print:hidden">
          <button onClick={() => window.print()} className="flex-1 rounded bg-brand-600 px-3 py-2 text-sm font-medium text-white hover:bg-brand-700">Print</button>
          <button onClick={onClose} className="flex-1 rounded border border-slate-300 px-3 py-2 text-sm hover:bg-slate-50">Close</button>
        </div>
      </div>
    </div>
  )
}

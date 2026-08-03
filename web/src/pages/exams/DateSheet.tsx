import { useSchoolName } from '@/hooks/useSchoolName'
import { fmtDate } from '@/lib/format'
import type { ExamSubjectRow } from '@/lib/db'

/** A printable date sheet: the papers for a class in a term, ordered by date. */
export function DateSheet({
  papers, termName, className, onClose,
}: {
  papers: ExamSubjectRow[]
  termName: string
  className: string
  onClose: () => void
}) {
  const schoolName = useSchoolName()
  const ordered = [...papers].sort((a, b) => {
    if (a.exam_date && b.exam_date) return a.exam_date.localeCompare(b.exam_date)
    if (a.exam_date) return -1
    if (b.exam_date) return 1
    return a.subject_name.localeCompare(b.subject_name)
  })

  return (
    <div className="fixed inset-0 z-50 flex items-start justify-center overflow-auto bg-black/40 p-4 print:static print:block print:bg-white print:p-0">
      <div className="w-full max-w-xl rounded-lg bg-white p-6 shadow-lg print:max-w-none print:shadow-none" id="date-sheet">
        <div className="text-center">
          <div className="text-xl font-semibold text-slate-800">{schoolName}</div>
          <div className="text-xs uppercase tracking-wide text-slate-500">Date Sheet — {termName} · {className}</div>
        </div>

        <table className="mt-5 w-full border-collapse text-sm">
          <thead>
            <tr className="border-y border-slate-300 text-left text-xs uppercase tracking-wide text-slate-500">
              <th className="py-1.5 pr-2">Subject</th>
              <th className="py-1.5 pr-2 w-40">Date</th>
              <th className="py-1.5 pr-2 w-28">Time</th>
              <th className="py-1.5 w-20 text-right">Max</th>
            </tr>
          </thead>
          <tbody>
            {ordered.map((p) => (
              <tr key={p.id} className="border-b border-slate-100">
                <td className="py-1.5 pr-2 text-slate-800">{p.subject_name}</td>
                <td className="py-1.5 pr-2 text-slate-700">{p.exam_date ? fmtDate(p.exam_date) : '—'}</td>
                <td className="py-1.5 pr-2 text-slate-700">{p.paper_time || '—'}</td>
                <td className="py-1.5 text-right text-slate-600">{p.max_marks}</td>
              </tr>
            ))}
          </tbody>
        </table>

        <div className="mt-8 flex justify-between text-xs text-slate-500">
          <span>Controller of Examinations: ______________</span>
          <span>Principal: ______________</span>
        </div>

        <div className="mt-5 flex gap-2 print:hidden">
          <button onClick={() => window.print()} className="flex-1 rounded bg-brand-600 px-3 py-2 text-sm font-medium text-white hover:bg-brand-700">Print</button>
          <button onClick={onClose} className="flex-1 rounded border border-slate-300 px-3 py-2 text-sm hover:bg-slate-50">Close</button>
        </div>
      </div>
    </div>
  )
}

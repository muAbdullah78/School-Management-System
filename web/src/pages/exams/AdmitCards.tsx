import { useSchoolName } from '@/hooks/useSchoolName'
import { fmtDate } from '@/lib/format'
import type { ClassRosterRow, ExamSubjectRow } from '@/lib/db'

/** Printable admit cards / roll-number slips. One per student, each listing the
 *  papers (with date + time) they'll sit. Cards page-break so each prints on its
 *  own slip. */
export function AdmitCards({
  roster, papers, termName, className, onClose,
}: {
  roster: ClassRosterRow[]
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
      <div className="w-full max-w-2xl rounded-lg bg-white p-6 shadow-lg print:max-w-none print:shadow-none" id="admit-cards">
        <div className="print:hidden mb-3 flex items-center justify-between">
          <div className="text-sm text-slate-600">{roster.length} admit card{roster.length === 1 ? '' : 's'}: {termName} · {className}</div>
          <div className="flex gap-2">
            <button onClick={() => window.print()} className="rounded bg-brand-600 px-3 py-2 text-sm font-medium text-white hover:bg-brand-700">Print all</button>
            <button onClick={onClose} className="rounded border border-slate-300 px-3 py-2 text-sm hover:bg-slate-50">Close</button>
          </div>
        </div>

        {roster.map((s) => (
          <div key={s.enrollment_id} className="mb-4 break-inside-avoid rounded-lg border border-slate-300 p-4 print:mb-0 print:break-after-page print:border-slate-400">
            <div className="text-center">
              <div className="text-lg font-semibold text-slate-800">{schoolName}</div>
              <div className="text-xs uppercase tracking-wide text-slate-500">Admit Card: {termName}</div>
            </div>
            <div className="mt-3 grid grid-cols-2 gap-y-1 text-sm text-slate-700">
              <span><span className="text-slate-500">Name:</span> {s.full_name}</span>
              <span className="text-right"><span className="text-slate-500">Roll No:</span> {s.roll_no ?? '-'}</span>
              <span><span className="text-slate-500">Father:</span> {s.father_name ?? '-'}</span>
              <span className="text-right"><span className="text-slate-500">GR No:</span> {s.gr_no ?? '-'}</span>
              <span><span className="text-slate-500">Class:</span> {className}{s.section_name ? ` · ${s.section_name}` : ''}</span>
              <span className="text-right"><span className="text-slate-500">Date:</span> {fmtDate(new Date().toISOString())}</span>
            </div>

            <table className="mt-3 w-full border-collapse text-xs">
              <thead>
                <tr className="border-y border-slate-300 text-left uppercase tracking-wide text-slate-500">
                  <th className="py-1 pr-2">Subject</th>
                  <th className="py-1 pr-2 w-32">Date</th>
                  <th className="py-1 w-24">Time</th>
                </tr>
              </thead>
              <tbody>
                {ordered.map((p) => (
                  <tr key={p.id} className="border-b border-slate-100">
                    <td className="py-1 pr-2 text-slate-800">{p.subject_name}</td>
                    <td className="py-1 pr-2 text-slate-700">{p.exam_date ? fmtDate(p.exam_date) : '-'}</td>
                    <td className="py-1 text-slate-700">{p.paper_time || '-'}</td>
                  </tr>
                ))}
              </tbody>
            </table>

            <div className="mt-4 flex justify-between text-xs text-slate-500">
              <span>Student sign: __________</span>
              <span>Principal: __________</span>
            </div>
          </div>
        ))}
        {roster.length === 0 && <div className="p-3 text-center text-sm text-slate-500">No active students in this class.</div>}
      </div>
    </div>
  )
}

import { useSchoolName } from '@/hooks/useSchoolName'
import { useSchoolLogo } from '@/hooks/useSchoolLogo'
import { fmtDate } from '@/lib/format'
import { gradeLabel, type ResultCardRow } from '@/lib/db'

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
  // Not part of the frozen snapshot on purpose: the snapshot exists so MARKS
  // never drift on a reprint. A school that adopts a logo in March should have
  // it on a reprint of February's card, and a school that changes its logo
  // should not have two different letterheads in circulation.
  const logo = useSchoolLogo()
  const f = card.frozen
  // Whether ANY subject on this card carries a practical. Cards from before 0058
  // have no practical_max at all, so the columns simply do not appear. A
  // reprint of last term's card must not gain empty columns.
  const anyPractical = (f.subjects ?? []).some((s) => (s.practical_max ?? 0) > 0)

  return (
    <div className="fixed inset-0 z-50 flex items-start justify-center overflow-y-auto bg-black/40 p-4 print:static print:block print:bg-white print:p-0">
      <div className="w-full max-w-2xl rounded-lg bg-white p-6 shadow-lg print:max-w-none print:shadow-none" id="result-card">
        <div className="text-center">
          {logo && (
            <img src={logo} alt="" className="mx-auto mb-1 max-h-16 max-w-[10rem] object-contain" />
          )}
          <div className="text-xl font-semibold text-slate-800">{schoolName}</div>
          <div className="text-xs uppercase tracking-wide text-slate-500">Result Card: {termName}</div>
        </div>

        {/* A provisional card SAYS so, in the place nobody can miss. The whole
            point of the provisional state is that a parent is never handed a
            partial result that looks final. */}
        {f.provisional && (
          <div className="mt-3 rounded border-2 border-amber-500 bg-amber-50 px-3 py-2 text-center">
            <div className="text-sm font-bold uppercase tracking-wide text-amber-800">Provisional result</div>
            <div className="text-xs text-amber-800">
              {f.unmarked_subjects === 1
                ? 'One subject has not been marked yet and is not counted below.'
                : `${f.unmarked_subjects} subjects have not been marked yet and are not counted below.`}
            </div>
          </div>
        )}

        <div className="mt-4 grid grid-cols-2 gap-y-1 text-sm text-slate-700">
          <span><span className="text-slate-500">Student:</span> {card.full_name}</span>
          <span className="text-right"><span className="text-slate-500">GR No:</span> {card.gr_no ?? '-'}</span>
          <span><span className="text-slate-500">Class:</span> {className}{sectionName ? ` · ${sectionName}` : ''}{f.stream ? ` · ${f.stream}` : ''}</span>
          <span className="text-right"><span className="text-slate-500">Roll No:</span> {card.roll_no ?? '-'}</span>
          {/* Only when there is one. A primary class has no board number and a
              blank labelled field on a printed card looks like a mistake. */}
          {f.bise_reg_no && (
            <span className="col-span-2"><span className="text-slate-500">Board Reg. No:</span> {f.bise_reg_no}</span>
          )}
        </div>

        {f.withheld && (
          <div className="mt-4 rounded border border-red-300 bg-red-50 px-3 py-2 text-center text-sm font-semibold text-red-700">
            RESULT WITHHELD: outstanding dues must be cleared.
          </div>
        )}

        <table className="mt-4 w-full border-collapse text-sm">
          <thead>
            <tr className="border-y border-slate-300 text-left text-xs uppercase tracking-wide text-slate-500">
              <th className="py-1.5 pr-2">Subject</th>
              <th className="py-1.5 pr-2 w-20 text-right">Max</th>
              <th className="py-1.5 pr-2 w-20 text-right">Obtained</th>
              {anyPractical && <th className="py-1.5 pr-2 w-20 text-right">Practical</th>}
              {anyPractical && <th className="py-1.5 pr-2 w-20 text-right">Total</th>}
              {/* "Grade" or "GPA", from the scale FROZEN onto this card (0089)
                  rather than from the school's current setting. A card issued
                  under letters must still say Grade after the school switches. */}
              <th className="py-1.5 pr-2 w-20 text-right">{gradeLabel(f)}</th>
              <th className="py-1.5 w-16 text-right">Result</th>
            </tr>
          </thead>
          <tbody>
            {f.subjects.map((s, i) => (
              <tr key={i} className="border-b border-slate-100">
                <td className="py-1.5 pr-2 text-slate-800">{s.subject}</td>
                <td className="py-1.5 pr-2 text-right text-slate-600">{s.max}</td>
                {/* Three states, not two. "ABS" for a pupil who did not sit it,
                    a dash for a paper NOT MARKED YET, and a number otherwise:
                    the distinction the old card could not make, which is why an
                    unmarked pupil printed as having scored zero. */}
                <td className="py-1.5 pr-2 text-right text-slate-800">
                  {s.marked === false ? '-' : (s.is_absent ? 'ABS' : (s.marks ?? '-'))}
                </td>
                {anyPractical && (
                  <td className="py-1.5 pr-2 text-right text-slate-800">
                    {(s.practical_max ?? 0) === 0
                      ? <span className="text-slate-300">-</span>
                      : (s.marked === false ? '-' : (s.is_absent ? 'ABS' : (s.practical ?? '-')))}
                  </td>
                )}
                {anyPractical && (
                  <td className="py-1.5 pr-2 text-right font-medium text-slate-800">
                    {s.marked === false ? '-' : (s.obtained ?? '-')}
                    <span className="text-slate-400">/{s.out_of ?? s.max}</span>
                  </td>
                )}
                <td className="py-1.5 pr-2 text-right font-medium">{s.grade ?? '-'}</td>
                <td className="py-1.5 text-right text-xs font-semibold">
                  {s.passed === true && <span className="text-money-700">Pass</span>}
                  {s.passed === false && <span className="text-danger-600">Fail</span>}
                  {s.passed == null && <span className="text-slate-400">-</span>}
                </td>
              </tr>
            ))}
          </tbody>
          <tfoot>
            <tr className="border-t border-slate-300 font-semibold text-slate-800">
              <td className="py-1.5 pr-2">Total</td>
              <td className="py-1.5 pr-2 text-right">{anyPractical ? '' : f.total_max}</td>
              <td className="py-1.5 pr-2 text-right">{anyPractical ? '' : f.total_marks}</td>
              {anyPractical && <td className="py-1.5 pr-2" />}
              {anyPractical && (
                <td className="py-1.5 pr-2 text-right">
                  {f.total_marks}<span className="text-slate-400">/{f.total_max}</span>
                </td>
              )}
              <td className="py-1.5 pr-2 text-right">{f.grade ?? '-'}</td>
              <td className="py-1.5 text-right text-xs">
                {f.result === 'PASS' && <span className="text-money-700">PASS</span>}
                {f.result === 'FAIL' && <span className="text-danger-600">FAIL</span>}
              </td>
            </tr>
          </tfoot>
        </table>

        {/* When the term counts class assessments, both components are printed.
            A single blended percentage nobody can reproduce by hand is a
            percentage a parent will dispute and the school cannot defend. */}
        {(f.assessment_weight_pct ?? 0) > 0 && (
          <div className="mt-3 rounded border border-slate-200 bg-slate-50 px-3 py-2 text-xs text-slate-600">
            <span className="font-medium text-slate-700">How this percentage is made up: </span>
            exam {f.exam_percentage}% &times; {100 - (f.assessment_weight_pct ?? 0)}%
            {' '}+ class assessments {f.assessment_percentage}% &times; {f.assessment_weight_pct}%
            {' '}= <strong>{f.percentage}%</strong>
          </div>
        )}

        <div className="mt-4 flex flex-wrap justify-between gap-2 text-sm text-slate-700">
          <span><span className="text-slate-500">Percentage:</span> {f.percentage == null ? '-' : `${f.percentage}%`}</span>
          <span><span className="text-slate-500">{gradeLabel(f)}:</span> {f.grade ?? '-'}</span>
          <span><span className="text-slate-500">Position:</span> {f.position ?? '-'}</span>
          <span><span className="text-slate-500">Attendance:</span> {f.attendance_pct == null ? '-' : `${f.attendance_pct}%`}</span>
        </div>

        {/* 0105. The register behind that percentage, printed only when there is
            leave to account for. The school approved those days and the card
            used to read as though the child had simply not turned up, which is
            an argument at the counter that nothing printed could settle. The
            percentage is unchanged: it counts every day the school was open,
            because that is the figure the 75% board-exam rule needs. */}
        {(f.attendance?.leave ?? 0) > 0 && (
          <div className="mt-2 text-xs text-slate-600">
            <span className="font-medium text-slate-700">Attendance: </span>
            {f.attendance!.present} present of {f.attendance!.marked_days} days marked, of which
            {' '}{f.attendance!.leave} {f.attendance!.leave === 1 ? 'day was' : 'days were'} leave
            {' '}approved by the school. The percentage counts every day the school was open.
          </div>
        )}

        {/* The verdict, and the fact behind it. Both, so a school that promotes
            on aggregate alone can still apply its own rule from what is printed. */}
        <div className="mt-3 flex flex-wrap items-baseline justify-between gap-2 border-t border-slate-200 pt-3">
          <div className="text-base font-bold">
            <span className="text-sm font-normal text-slate-500">Result: </span>
            {f.result === 'PASS' && <span className="text-money-700">PASS</span>}
            {f.result === 'FAIL' && <span className="text-danger-600">FAIL</span>}
            {(f.result === 'PENDING' || !f.result) && <span className="text-slate-400">Pending</span>}
          </div>
          <div className="text-xs text-slate-600">
            {(f.failed_subjects ?? 0) > 0
              ? `Failed in ${f.failed_subjects} subject${f.failed_subjects === 1 ? '' : 's'}`
              : 'Passed in every subject'}
            {f.pass_percent != null && ` · pass mark ${f.pass_percent}% overall`}
          </div>
        </div>

        <div className="mt-8 flex justify-between text-xs text-slate-500">
          <span>Class Teacher: ______________</span>
          <span>Principal: ______________</span>
          {/* The card's OWN date and version, not today's. Two cards in
              circulation after a correction are otherwise indistinguishable, and
              the parent's copy is always the one that gets argued with. */}
          <span>
            {f.generated_at ? fmtDate(f.generated_at) : fmtDate(new Date().toISOString())}
            {(f.version ?? card.version) > 1 && ` · v${f.version ?? card.version}`}
          </span>
        </div>

        <div className="mt-5 flex gap-2 print:hidden">
          <button onClick={() => window.print()} className="flex-1 rounded bg-brand-600 px-3 py-2 text-sm font-medium text-white hover:bg-brand-700">Print</button>
          <button onClick={onClose} className="flex-1 rounded border border-slate-300 px-3 py-2 text-sm hover:bg-slate-50">Close</button>
        </div>
      </div>
    </div>
  )
}

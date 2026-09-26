import { useSchoolName } from '@/hooks/useSchoolName'
import { useSchoolLogo } from '@/hooks/useSchoolLogo'
import { fmtDate } from '@/lib/format'
import { gradeLabel, type ResultCardRow } from '@/lib/db'

/**
 * A printable result card, rendered from the card's frozen snapshot so a
 * reprint of the marks is identical. Print with the browser (Ctrl+P); the print
 * CSS in index.css hides everything except #result-card.
 *
 * WHAT THE CARD WAS MISSING, AND WHERE EACH NOW COMES FROM:
 *   * the class teacher's REMARK, which a teacher wrote on the Remarks screen
 *     and which printed nowhere. Read live: it cannot change once the result is
 *     released (0152), so the printed and the portal copy agree;
 *   * the SECTION, which was passed as null from the one screen that opens it;
 *   * the FATHER'S NAME, which every Pakistani result card carries.
 * The section and the father's name are facts about the pupil, not about the
 * marks the snapshot froze, so they are read from the pupil's record.
 */
export function ResultCardPrint({
  card, termName, className, sectionName, remark, onClose,
}: {
  card: ResultCardRow
  termName: string
  className: string
  sectionName?: string | null
  remark?: string | null
  onClose: () => void
}) {
  return (
    <Overlay onClose={onClose} label={`${card.full_name}'s result card`}>
      <ResultCardSheet card={card} termName={termName} className={className}
        sectionName={card.section_name ?? sectionName ?? null} remark={remark ?? null} />
    </Overlay>
  )
}

/** Every card of the class, one to a page: the office printed forty cards by
 *  opening forty of them. */
export function ResultCardsPrintAll({ cards, remarks, termName, className, onClose }: {
  cards: ResultCardRow[]
  remarks: Map<string, string>
  termName: string
  className: string
  onClose: () => void
}) {
  const ordered = [...cards].sort((a, b) =>
    (a.section_name ?? '').localeCompare(b.section_name ?? '')
    || rollNum(a.roll_no) - rollNum(b.roll_no) || a.full_name.localeCompare(b.full_name))
  return (
    <Overlay onClose={onClose} label={`${cards.length} result cards`} count={cards.length}>
      {ordered.map((c, i) => (
        <div key={c.id} className={i < ordered.length - 1 ? 'mb-8 border-b border-dashed border-slate-300 pb-8 print:mb-0 print:border-0 print:pb-0 print:[break-after:page]' : ''}>
          <ResultCardSheet card={c} termName={termName} className={className}
            sectionName={c.section_name ?? null} remark={remarks.get(c.student_id) ?? null} />
        </div>
      ))}
    </Overlay>
  )
}

function rollNum(roll: string | null): number {
  const n = parseInt((roll ?? '').replace(/[^0-9]/g, ''), 10)
  return Number.isNaN(n) ? Number.MAX_SAFE_INTEGER : n
}

function Overlay({ children, onClose, label, count }: {
  children: React.ReactNode; onClose: () => void; label: string; count?: number
}) {
  return (
    <div className="fixed inset-0 z-50 flex items-start justify-center overflow-y-auto bg-slate-900/50 p-3 sm:p-6 print:static print:block print:bg-white print:p-0"
      role="dialog" aria-modal="true" aria-label={label}>
      <div className="w-full max-w-2xl rounded-3xl bg-white shadow-2xl print:max-w-none print:rounded-none print:shadow-none">
        <div className="sticky top-0 z-10 flex items-center justify-between gap-2 rounded-t-3xl border-b border-slate-200 bg-white/95 px-4 py-3 backdrop-blur print:hidden">
          <span className="truncate text-sm font-semibold text-slate-700">
            {count != null ? `${count} result card${count === 1 ? '' : 's'}, one to a page` : 'Result card'}
          </span>
          <div className="flex shrink-0 gap-2">
            <button onClick={() => window.print()} className="rounded-xl bg-brand-600 px-4 py-2 text-sm font-semibold text-white shadow-sm hover:bg-brand-700">
              {count != null ? 'Print all' : 'Print'}
            </button>
            <button onClick={onClose} className="rounded-xl bg-white px-4 py-2 text-sm font-medium text-slate-700 ring-1 ring-slate-300 hover:bg-slate-50">Close</button>
          </div>
        </div>
        <div id="result-card" className="p-5 sm:p-7 print:p-0">{children}</div>
      </div>
    </div>
  )
}

export function ResultCardSheet({ card, termName, className, sectionName, remark }: {
  card: ResultCardRow
  termName: string
  className: string
  sectionName: string | null
  remark: string | null
}) {
  const schoolName = useSchoolName()
  // Not part of the frozen snapshot on purpose: the snapshot exists so MARKS
  // never drift on a reprint, and a school that adopts a logo in March should
  // have it on a reprint of February's card.
  const logo = useSchoolLogo()
  const f = card.frozen
  // Cards from before 0058 have no practical_max at all, so the columns simply
  // do not appear. A reprint of last term's card must not gain empty columns.
  const anyPractical = (f.subjects ?? []).some((s) => (s.practical_max ?? 0) > 0)

  return (
    <article className="text-slate-800">
      <div className="text-center">
        {logo && <img src={logo} alt="" className="mx-auto mb-1 max-h-16 max-w-[10rem] object-contain" />}
        <div className="text-xl font-bold text-slate-900">{schoolName}</div>
        <div className="mt-0.5 text-xs font-semibold uppercase tracking-[0.2em] text-brand-700">Result Card · {termName}</div>
      </div>

      {/* A provisional card SAYS so, where nobody can miss it. */}
      {f.provisional && (
        <div className="mt-3 rounded-lg border-2 border-due-500 bg-due-50 px-3 py-2 text-center">
          <div className="text-sm font-bold uppercase tracking-wide text-due-800">Provisional result</div>
          <div className="text-xs text-due-800">
            {f.unmarked_subjects === 1
              ? 'One subject has not been marked yet and is not counted below.'
              : `${f.unmarked_subjects} subjects have not been marked yet and are not counted below.`}
          </div>
        </div>
      )}

      <div className="mt-4 grid grid-cols-2 gap-x-4 gap-y-1 rounded-xl bg-slate-50 px-3 py-2.5 text-sm print:bg-transparent print:px-0">
        <span><span className="text-slate-500">Student:</span> <b className="font-semibold">{card.full_name}</b></span>
        <span className="text-right"><span className="text-slate-500">GR No:</span> {card.gr_no ?? '-'}</span>
        <span><span className="text-slate-500">Father:</span> {card.father_name ?? '-'}</span>
        <span className="text-right"><span className="text-slate-500">Roll No:</span> {card.roll_no ?? '-'}</span>
        <span className="col-span-2">
          <span className="text-slate-500">Class:</span> {className}{sectionName ? ` · Section ${sectionName}` : ''}{f.stream ? ` · ${f.stream}` : ''}
        </span>
        {/* Only when there is one: a blank labelled field looks like a mistake. */}
        {f.bise_reg_no && (
          <span className="col-span-2"><span className="text-slate-500">Board Reg. No:</span> {f.bise_reg_no}</span>
        )}
      </div>

      {f.withheld && (
        <div className="mt-4 rounded-lg border border-danger-300 bg-danger-50 px-3 py-2 text-center text-sm font-semibold text-danger-700">
          RESULT WITHHELD: outstanding dues must be cleared.
        </div>
      )}

      {/* Sideways on a phone rather than cut off: seven columns do not fit
          360px, and the printed page is wide enough for all of them. */}
      <div className="mt-4 overflow-x-auto print:overflow-visible">
      <table className="w-full min-w-[30rem] border-collapse text-sm print:min-w-0">
        <thead>
          <tr className="border-y-2 border-slate-300 text-left text-[11px] uppercase tracking-wide text-slate-500">
            <th className="py-1.5 pr-2">Subject</th>
            <th className="w-16 py-1.5 pr-2 text-right">Max</th>
            <th className="w-20 py-1.5 pr-2 text-right">{anyPractical ? 'Theory' : 'Obtained'}</th>
            {anyPractical && <th className="w-20 py-1.5 pr-2 text-right">Practical</th>}
            {anyPractical && <th className="w-20 py-1.5 pr-2 text-right">Total</th>}
            {/* "Grade" or "GPA", from the scale FROZEN onto this card (0089). */}
            <th className="w-16 py-1.5 pr-2 text-right">{gradeLabel(f)}</th>
            <th className="w-16 py-1.5 text-right">Result</th>
          </tr>
        </thead>
        <tbody>
          {f.subjects.map((s, i) => (
            <tr key={i} className="border-b border-slate-100">
              <td className="py-1.5 pr-2 font-medium">{s.subject}</td>
              <td className="py-1.5 pr-2 text-right text-slate-600">{s.max}</td>
              {/* Three states: ABS for a pupil who did not sit it, a dash for a
                  paper NOT MARKED YET, and a number otherwise. */}
              <td className="py-1.5 pr-2 text-right tabular-nums">
                {s.marked === false ? '-' : (s.is_absent ? 'ABS' : (s.marks ?? '-'))}
              </td>
              {anyPractical && (
                <td className="py-1.5 pr-2 text-right tabular-nums">
                  {(s.practical_max ?? 0) === 0
                    ? <span className="text-slate-300">-</span>
                    : (s.marked === false ? '-' : (s.is_absent ? 'ABS' : (s.practical ?? '-')))}
                </td>
              )}
              {anyPractical && (
                <td className="py-1.5 pr-2 text-right font-semibold tabular-nums">
                  {s.marked === false ? '-' : (s.obtained ?? '-')}
                  <span className="font-normal text-slate-400">/{s.out_of ?? s.max}</span>
                </td>
              )}
              <td className="py-1.5 pr-2 text-right font-semibold">{s.grade ?? '-'}</td>
              <td className="py-1.5 text-right text-xs font-bold">
                {s.passed === true && <span className="text-brand-700">Pass</span>}
                {s.passed === false && <span className="text-danger-600">Fail</span>}
                {s.passed == null && <span className="text-slate-400">-</span>}
              </td>
            </tr>
          ))}
        </tbody>
        <tfoot>
          <tr className="border-t-2 border-slate-300 font-bold">
            <td className="py-1.5 pr-2">Total</td>
            <td className="py-1.5 pr-2 text-right">{anyPractical ? '' : f.total_max}</td>
            <td className="py-1.5 pr-2 text-right tabular-nums">{anyPractical ? '' : f.total_marks}</td>
            {anyPractical && <td className="py-1.5 pr-2" />}
            {anyPractical && (
              <td className="py-1.5 pr-2 text-right tabular-nums">
                {f.total_marks}<span className="font-normal text-slate-400">/{f.total_max}</span>
              </td>
            )}
            <td className="py-1.5 pr-2 text-right">{f.grade ?? '-'}</td>
            <td className="py-1.5 text-right text-xs">
              {f.result === 'PASS' && <span className="text-brand-700">PASS</span>}
              {f.result === 'FAIL' && <span className="text-danger-600">FAIL</span>}
            </td>
          </tr>
        </tfoot>
      </table>
      </div>

      {/* When the term counts class assessments, both components are printed. */}
      {(f.assessment_weight_pct ?? 0) > 0 && (
        <div className="mt-3 rounded-lg border border-slate-200 bg-slate-50 px-3 py-2 text-xs text-slate-600">
          <span className="font-medium text-slate-700">How this percentage is made up: </span>
          exam {f.exam_percentage}% &times; {100 - (f.assessment_weight_pct ?? 0)}%
          {' '}+ class assessments {f.assessment_percentage}% &times; {f.assessment_weight_pct}%
          {' '}= <strong>{f.percentage}%</strong>
        </div>
      )}

      <div className="mt-4 grid grid-cols-2 gap-2 text-center sm:grid-cols-4">
        <Figure label="Percentage" value={f.percentage == null ? '-' : `${f.percentage}%`} strong />
        <Figure label={gradeLabel(f)} value={f.grade ?? '-'} />
        <Figure label="Position" value={f.position ?? '-'} />
        <Figure label="Attendance" value={f.attendance_pct == null ? '-' : `${f.attendance_pct}%`} />
      </div>

      {/* 0105. The register behind that percentage, printed only when there is
          leave to account for. */}
      {(f.attendance?.leave ?? 0) > 0 && (
        <div className="mt-2 text-xs text-slate-600">
          <span className="font-medium text-slate-700">Attendance: </span>
          {f.attendance!.present} present of {f.attendance!.marked_days} days marked, of which
          {' '}{f.attendance!.leave} {f.attendance!.leave === 1 ? 'day was' : 'days were'} leave
          {' '}approved by the school. The percentage counts every day the school was open.
        </div>
      )}

      <div className="mt-3 flex flex-wrap items-baseline justify-between gap-2 border-t border-slate-200 pt-3">
        <div className="text-base font-bold">
          <span className="text-sm font-normal text-slate-500">Result: </span>
          {f.result === 'PASS' && <span className="text-brand-700">PASS</span>}
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

      {remark && (
        <div className="mt-3 rounded-lg border border-slate-200 px-3 py-2">
          <div className="text-[11px] font-semibold uppercase tracking-wide text-slate-500">Class teacher&rsquo;s remark</div>
          <p className="mt-0.5 text-sm italic text-slate-800">{remark}</p>
        </div>
      )}

      <div className="mt-10 flex justify-between gap-4 text-xs text-slate-500">
        <span className="border-t border-slate-400 pt-1">Class Teacher</span>
        <span className="border-t border-slate-400 pt-1">Principal</span>
        <span className="border-t border-slate-400 pt-1">Parent</span>
        {/* The card's OWN date and version, not today's. */}
        <span className="pt-1">
          {f.generated_at ? fmtDate(f.generated_at) : fmtDate(new Date().toISOString())}
          {(f.version ?? card.version) > 1 && ` · v${f.version ?? card.version}`}
        </span>
      </div>
    </article>
  )
}

function Figure({ label, value, strong = false }: { label: string; value: React.ReactNode; strong?: boolean }) {
  return (
    <div className={`rounded-lg px-2 py-1.5 ring-1 ${strong ? 'bg-brand-50 ring-brand-200' : 'bg-white ring-slate-200'}`}>
      <div className="text-[10px] font-semibold uppercase tracking-wide text-slate-500">{label}</div>
      <div className="text-base font-bold tabular-nums text-slate-900">{value}</div>
    </div>
  )
}

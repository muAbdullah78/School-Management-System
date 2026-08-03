import { useSchoolName } from '@/hooks/useSchoolName'
import { fmtDate } from '@/lib/format'
import type { ResultCardRow } from '@/lib/db'

/** A printable tabulation / consolidation sheet: every student in a class for a
 *  term on one grid — subjects across, students down, with totals, %, grade,
 *  position and pass/fail. Built from the same frozen snapshots the result cards
 *  print from, so it always agrees with them. Prints best in landscape. */
export function TabulationSheet({
  cards, termName, className, onClose,
}: {
  cards: ResultCardRow[]
  termName: string
  className: string
  onClose: () => void
}) {
  const schoolName = useSchoolName()

  // Column subjects, in first-seen order across all cards (handles a card that
  // happens to miss a subject).
  const subjects: { name: string; max: number }[] = []
  const seen = new Set<string>()
  for (const c of cards) {
    for (const s of c.frozen?.subjects ?? []) {
      if (!seen.has(s.subject)) { seen.add(s.subject); subjects.push({ name: s.subject, max: s.max }) }
    }
  }

  function cell(card: ResultCardRow, subject: string): string {
    const s = card.frozen?.subjects.find((x) => x.subject === subject)
    if (!s) return '—'
    return s.is_absent ? 'ABS' : (s.marks == null ? '—' : String(s.marks))
  }
  function result(card: ResultCardRow): { label: string; fail: boolean } {
    if (card.frozen?.withheld) return { label: 'Withheld', fail: true }
    const fail = (card.frozen?.subjects ?? []).some((s) => s.is_absent || (s.marks != null && s.marks < s.pass))
    return { label: fail ? 'Fail' : 'Pass', fail }
  }

  return (
    <div className="fixed inset-0 z-50 flex items-start justify-center overflow-auto bg-black/40 p-4 print:static print:block print:bg-white print:p-0">
      <div className="w-full max-w-6xl rounded-lg bg-white p-6 shadow-lg print:max-w-none print:shadow-none" id="tabulation">
        <div className="text-center">
          <div className="text-xl font-semibold text-slate-800">{schoolName}</div>
          <div className="text-xs uppercase tracking-wide text-slate-500">Tabulation Sheet — {termName} · {className}</div>
        </div>

        <div className="mt-4 overflow-x-auto">
          <table className="w-full border-collapse text-xs">
            <thead>
              <tr className="border-y border-slate-300 text-left uppercase tracking-wide text-slate-500">
                <th className="px-1.5 py-1 text-right">Roll</th>
                <th className="px-1.5 py-1">Student</th>
                {subjects.map((s) => (
                  <th key={s.name} className="px-1.5 py-1 text-right" title={s.name}>
                    {s.name}<span className="block font-normal text-[10px] text-slate-400">/{s.max}</span>
                  </th>
                ))}
                <th className="px-1.5 py-1 text-right">Total</th>
                <th className="px-1.5 py-1 text-right">%</th>
                <th className="px-1.5 py-1">Grade</th>
                <th className="px-1.5 py-1 text-right">Pos</th>
                <th className="px-1.5 py-1">Result</th>
              </tr>
            </thead>
            <tbody>
              {cards.map((c) => {
                const r = result(c)
                return (
                  <tr key={c.id} className="border-b border-slate-100">
                    <td className="px-1.5 py-1 text-right text-slate-500">{c.roll_no ?? '—'}</td>
                    <td className="px-1.5 py-1 text-slate-800">{c.full_name}</td>
                    {subjects.map((s) => (
                      <td key={s.name} className="px-1.5 py-1 text-right text-slate-700">{cell(c, s.name)}</td>
                    ))}
                    <td className="px-1.5 py-1 text-right text-slate-800">{c.total_marks ?? '—'}/{c.total_max ?? '—'}</td>
                    <td className="px-1.5 py-1 text-right text-slate-700">{c.percentage == null ? '—' : c.percentage}</td>
                    <td className="px-1.5 py-1 font-medium text-slate-800">{c.grade ?? '—'}</td>
                    <td className="px-1.5 py-1 text-right text-slate-700">{c.position ?? '—'}</td>
                    <td className={`px-1.5 py-1 font-medium ${r.fail ? 'text-red-600' : 'text-emerald-700'}`}>{r.label}</td>
                  </tr>
                )
              })}
              {cards.length === 0 && (
                <tr><td colSpan={subjects.length + 6} className="px-2 py-3 text-center text-slate-500">No result cards to tabulate.</td></tr>
              )}
            </tbody>
          </table>
        </div>

        <div className="mt-4 flex items-center justify-between text-xs text-slate-500">
          <span>{cards.length} student{cards.length === 1 ? '' : 's'}</span>
          <span>Prepared: {fmtDate(new Date().toISOString())}</span>
          <span>Checked by: ______________</span>
        </div>

        <div className="mt-5 flex gap-2 print:hidden">
          <button onClick={() => window.print()} className="flex-1 rounded bg-brand-600 px-3 py-2 text-sm font-medium text-white hover:bg-brand-700">Print (choose landscape)</button>
          <button onClick={onClose} className="flex-1 rounded border border-slate-300 px-3 py-2 text-sm hover:bg-slate-50">Close</button>
        </div>
      </div>
    </div>
  )
}

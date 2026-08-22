import { useState } from 'react'
import { ExamSetup } from './ExamSetup'
import { MarksEntry } from './MarksEntry'
import { ResultsTab } from './ResultsTab'
import { RemarksTab } from './RemarksTab'

const TABS = [
  { key: 'setup', label: 'Setup' },
  { key: 'marks', label: 'Marks Entry' },
  { key: 'results', label: 'Result Cards' },
  // Remarks had nowhere in the schema to live at all; position was computed and
  // printed but had no school-wide view. Both are item 7 of docs/PARITY.md.
  { key: 'remarks', label: 'Remarks & Positions' },
] as const
type TabKey = (typeof TABS)[number]['key']

export function ExamsPage() {
  const [tab, setTab] = useState<TabKey>('setup')
  return (
    <div>
      <h1 className="text-xl font-semibold text-slate-800">Exams &amp; Results</h1>
      <div className="mt-4 flex gap-1 border-b border-slate-200">
        {TABS.map((t) => (
          <button key={t.key} onClick={() => setTab(t.key)}
            className={`-mb-px border-b-2 px-4 py-2 text-sm ${tab === t.key ? 'border-brand-600 font-medium text-brand-700' : 'border-transparent text-slate-500 hover:text-slate-700'}`}>
            {t.label}
          </button>
        ))}
      </div>
      <div className="mt-5">
        {tab === 'setup' && <ExamSetup />}
        {tab === 'marks' && <MarksEntry />}
        {tab === 'results' && <ResultsTab />}
        {tab === 'remarks' && <RemarksTab />}
      </div>
    </div>
  )
}

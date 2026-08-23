import { useState } from 'react'
import { useAuth } from '@/auth/AuthProvider'
import { canWrite } from '@/auth/roles'
import { ObserverNotice } from '@/components/ObserverNotice'
import { ExamSetup } from './ExamSetup'
import { MarksEntry } from './MarksEntry'
import { ResultsTab } from './ResultsTab'
import { RemarksTab } from './RemarksTab'
import { StreamsTab } from './StreamsTab'

// `writes` marks a tab whose purpose is to change something. An observer is
// shown Result Cards and nothing else here: a marks grid it cannot save is not
// a view of anything, and its Save button used to report success while changing
// nothing.
const TABS = [
  { key: 'setup', label: 'Setup', writes: true },
  // Where a school sets who is Science and who is Arts. Not a corner of each
  // pupil's profile: setting a stream forty profiles at a time is why the column
  // stayed empty, and an empty stream in a streamed class means no result card.
  { key: 'streams', label: 'Streams & Board Nos', writes: true },
  { key: 'marks', label: 'Marks Entry', writes: true },
  { key: 'results', label: 'Result Cards', writes: false },
  // Remarks had nowhere in the schema to live at all; position was computed and
  // printed but had no school-wide view. Both are item 7 of docs/PARITY.md.
  { key: 'remarks', label: 'Remarks & Positions', writes: true },
] as const
type TabKey = (typeof TABS)[number]['key']

export function ExamsPage() {
  const { profile } = useAuth()
  const mayWrite = canWrite(profile?.role)
  const tabs = TABS.filter((t) => mayWrite || !t.writes)
  const [tab, setTab] = useState<TabKey>(mayWrite ? 'setup' : 'results')
  return (
    <div>
      <h1 className="text-xl font-semibold text-slate-800">Exams &amp; Results</h1>
      {!mayWrite && <ObserverNotice what="exam results" />}
      <div className="mt-4 flex gap-1 border-b border-slate-200">
        {tabs.map((t) => (
          <button key={t.key} onClick={() => setTab(t.key)}
            className={`-mb-px border-b-2 px-4 py-2 text-sm ${tab === t.key ? 'border-brand-600 font-medium text-brand-700' : 'border-transparent text-slate-500 hover:text-slate-700'}`}>
            {t.label}
          </button>
        ))}
      </div>
      <div className="mt-5">
        {tab === 'setup' && <ExamSetup />}
        {tab === 'streams' && <StreamsTab />}
        {tab === 'marks' && <MarksEntry />}
        {tab === 'results' && <ResultsTab />}
        {tab === 'remarks' && <RemarksTab />}
      </div>
    </div>
  )
}

import { useAuth } from '@/auth/AuthProvider'
import { TabBar } from '@/components/TabBar'
import { useUrlTab } from '@/lib/useUrlTab'
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
  // In the address bar, so /exams?tab=results opens Result Cards and a reload
  // stays where it was. An observer's first (and only) tab is Result Cards.
  const [tab, setTab] = useUrlTab<TabKey>(tabs.map((t) => t.key), tabs[0].key)
  return (
    <div>
      <h1 className="text-xl font-semibold text-slate-800">Exams &amp; Results</h1>
      {!mayWrite && <ObserverNotice what="exam results" />}
      <TabBar label="Exams and results" className="mt-4" value={tab} onChange={setTab}
        tabs={tabs.map((t) => ({ key: t.key, label: t.label }))} />
      <div>
        {tab === 'setup' && <ExamSetup />}
        {tab === 'streams' && <StreamsTab />}
        {tab === 'marks' && <MarksEntry />}
        {tab === 'results' && <ResultsTab />}
        {tab === 'remarks' && <RemarksTab />}
      </div>
    </div>
  )
}

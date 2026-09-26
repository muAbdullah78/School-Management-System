import { useUrlTab } from '@/lib/useUrlTab'
import { SectionLayout, type SectionGroup } from '@/components/SectionLayout'
import { SchoolProfile } from './settings/SchoolProfile'
import { Sessions } from './settings/Sessions'
import { ClassesSections } from './settings/ClassesSections'
import { FeeStructure } from './settings/FeeStructure'
import { FeeHeads } from './settings/FeeHeads'
import { FeeIncrement } from './settings/FeeIncrement'
import { Users } from './settings/Users'
import { Backup } from './settings/Backup'
import { ImportData } from './settings/ImportData'
import { Rollover } from './settings/Rollover'
import { AuditLog } from './settings/AuditLog'
import { StaffCheckin } from './settings/StaffCheckin'
import { SupportVisits } from './settings/SupportVisits'
import { Subscription } from './settings/Subscription'

type SectionKey =
  | 'school' | 'sessions' | 'classes' | 'feeheads' | 'fees' | 'increase' | 'users' | 'checkin'
  | 'import' | 'rollover' | 'subscription' | 'audit' | 'support' | 'backup'

/**
 * FOURTEEN SCREENS, IN THE ORDER A SCHOOL SETS ITSELF UP.
 *
 * The school, then its years and classes, then what it charges (fee heads come
 * BEFORE the structure, because you cannot put an amount against a charge that
 * does not exist yet), then who can sign in, then the once-a-year jobs, then
 * the account with us, then the records that keep everybody honest.
 */
const GROUPS: readonly SectionGroup<SectionKey>[] = [
  {
    title: 'The school',
    items: [
      { key: 'school', label: 'School profile', ask: 'The name, logo and details printed on every challan, receipt and result card.' },
      { key: 'sessions', label: 'Sessions', ask: 'The school years, their first and last days, and which one is current.' },
      { key: 'classes', label: 'Classes and sections', ask: 'The class ladder, the sections in each class, and the subjects each class is taught.' },
    ],
  },
  {
    title: 'Fees',
    items: [
      { key: 'feeheads', label: 'Fee heads', ask: 'The things the school charges for: tuition, admission, exam fee, transport.' },
      { key: 'fees', label: 'Fee structure', ask: 'What each class pays for each fee head, all classes on one sheet.' },
      // Right after the grid it operates on: "everything up 10% from April"
      // in one pass instead of sixty hand edits.
      { key: 'increase', label: 'Fee increase', ask: 'Raise fees across the school in one pass, previewed before anything changes.' },
    ],
  },
  {
    title: 'People',
    items: [
      { key: 'users', label: 'Users and roles', ask: 'Who can sign in, what each person can do, and the saved passwords.' },
      { key: 'checkin', label: 'Staff check-in', ask: 'The code teachers scan to mark their own attendance, the school day, and the gate.' },
    ],
  },
  {
    title: 'Once a year',
    items: [
      { key: 'import', label: 'Import', ask: 'Bring children, staff and opening balances in from a spreadsheet.' },
      // The dashboard sends a school with children left out of this session
      // straight here, as /settings?tab=rollover.
      { key: 'rollover', label: 'Year rollover', ask: 'Move every class up into the new session, with arrears carried over.' },
    ],
  },
  {
    title: 'Your account',
    items: [
      // The school's own bill from us: what do we owe, where do we pay, can we
      // have the invoice again, and did you get our transfer.
      { key: 'subscription', label: 'Subscription', ask: 'Your plan, what you owe us, how to pay, and your invoices.' },
    ],
  },
  {
    title: 'Records and safety',
    items: [
      { key: 'audit', label: 'Audit log', ask: 'Who changed what, and when: money, marks, attendance, discounts and access.' },
      // Next to the audit log on purpose: one is who at the school changed
      // what, the other is when the software company looked.
      { key: 'support', label: 'Support visits', ask: 'Every time our support team opened your account, and why.' },
      { key: 'backup', label: 'Backup', ask: 'Download a complete copy of the school’s records to keep yourself.' },
    ],
  },
]

const KEYS = GROUPS.flatMap((g) => g.items.map((i) => i.key))

export function SettingsPage() {
  // In the URL, so a warning elsewhere can link straight to the screen that
  // fixes it rather than telling the school which tab to go and find.
  const [section, setSection, nav] = useUrlTab<SectionKey>(KEYS, 'school')
  return (
    <div>
      {/* On a phone inside one screen, "‹ All settings" and the screen's own
          heading already say where you are, so this line would only push the
          first field further down. */}
      <div className={nav.picked ? 'hidden lg:block' : ''}>
        <h1 className="text-xl font-semibold text-slate-800">Settings</h1>
        <p className="mt-0.5 text-sm text-slate-500">How the school is set up. Most of it is done once and left alone.</p>
      </div>
      <SectionLayout groups={GROUPS} value={section} onChange={setSection} label="Setting"
        picked={nav.picked} onPick={(k) => setSection(k, { explicit: true, push: true })}
        onIndex={nav.clear} indexLabel="All settings">
        {section === 'school' && <SchoolProfile />}
        {section === 'sessions' && <Sessions />}
        {section === 'classes' && <ClassesSections />}
        {section === 'feeheads' && <FeeHeads />}
        {section === 'fees' && <FeeStructure onSetUpHeads={() => setSection('feeheads')} />}
        {section === 'increase' && <FeeIncrement />}
        {section === 'users' && <Users />}
        {section === 'checkin' && <StaffCheckin />}
        {section === 'import' && <ImportData />}
        {section === 'rollover' && <Rollover />}
        {section === 'subscription' && <Subscription />}
        {section === 'audit' && <AuditLog />}
        {section === 'support' && <SupportVisits />}
        {section === 'backup' && <Backup />}
      </SectionLayout>
    </div>
  )
}

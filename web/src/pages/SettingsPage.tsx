import { useState } from 'react'
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
import { MessageSettings } from './settings/MessageSettings'
import { SupportVisits } from './settings/SupportVisits'
import { Subscription } from './settings/Subscription'

const SECTIONS = [
  { key: 'school', label: 'School Profile' },
  { key: 'sessions', label: 'Sessions' },
  { key: 'classes', label: 'Classes & Sections' },
  // Fee heads come BEFORE the structure, because that is the order a school
  // has to do them in: you cannot put an amount against a charge that does not
  // exist yet. There was no fee-heads screen at all, which is why a new school
  // found the Fee Structure grid empty with no way forward.
  { key: 'feeheads', label: 'Fee Heads' },
  { key: 'fees', label: 'Fee Structure' },
  // Right after the grid it operates on. fn_fee_increment shipped with a wrapper
  // in db.ts and no caller, so the one bulk fee operation every school performs
  // — "everything up 10% from April" — meant sixty hand edits in that grid.
  { key: 'increase', label: 'Fee Increase' },
  { key: 'checkin', label: 'Staff Check-in' },
  { key: 'import', label: 'Import' },
  { key: 'rollover', label: 'Year Rollover' },
  { key: 'messages', label: 'Messages' },
  { key: 'users', label: 'Users & Roles' },
  // The school's own bill from us. Its own tab rather than a line on School
  // Profile, because it is the answer to four questions a school currently has
  // to phone about: what do we owe, where do we pay, can we have the invoice
  // again, and did you get our transfer. Owner and principal only, refused at
  // the database for everybody else.
  { key: 'subscription', label: 'Subscription' },
  { key: 'audit', label: 'Audit Log' },
  // Next to the audit log on purpose: one is who at the school changed what,
  // the other is when the software company looked. Same question, two sources.
  { key: 'support', label: 'Support Visits' },
  { key: 'backup', label: 'Backup' },
] as const

type SectionKey = (typeof SECTIONS)[number]['key']

export function SettingsPage() {
  const [section, setSection] = useState<SectionKey>('school')
  return (
    <div>
      <h1 className="text-xl font-semibold text-slate-800">Settings</h1>
      <div className="mt-4 flex flex-wrap gap-1 border-b border-slate-200">
        {SECTIONS.map((s) => (
          <button key={s.key} onClick={() => setSection(s.key)}
            className={`-mb-px border-b-2 px-4 py-2 text-sm ${
              section === s.key ? 'border-brand-600 font-medium text-brand-700' : 'border-transparent text-slate-500 hover:text-slate-700'
            }`}>
            {s.label}
          </button>
        ))}
      </div>
      <div className="mt-5">
        {section === 'school' && <SchoolProfile />}
        {section === 'sessions' && <Sessions />}
        {section === 'classes' && <ClassesSections />}
        {section === 'feeheads' && <FeeHeads />}
        {section === 'fees' && <FeeStructure onSetUpHeads={() => setSection('feeheads')} />}
        {section === 'increase' && <FeeIncrement />}
        {section === 'checkin' && <StaffCheckin />}
        {section === 'import' && <ImportData />}
        {section === 'rollover' && <Rollover />}
        {section === 'audit' && <AuditLog />}
        {section === 'support' && <SupportVisits />}
        {section === 'messages' && <MessageSettings />}
        {section === 'users' && <Users />}
        {section === 'subscription' && <Subscription />}
        {section === 'backup' && <Backup />}
      </div>
    </div>
  )
}

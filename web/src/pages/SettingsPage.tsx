import { useState } from 'react'
import { SchoolProfile } from './settings/SchoolProfile'
import { Sessions } from './settings/Sessions'
import { ClassesSections } from './settings/ClassesSections'
import { FeeStructure } from './settings/FeeStructure'
import { Users } from './settings/Users'
import { Backup } from './settings/Backup'
import { ImportData } from './settings/ImportData'
import { Rollover } from './settings/Rollover'
import { AuditLog } from './settings/AuditLog'

const SECTIONS = [
  { key: 'school', label: 'School Profile' },
  { key: 'sessions', label: 'Sessions' },
  { key: 'classes', label: 'Classes & Sections' },
  { key: 'fees', label: 'Fee Structure' },
  { key: 'import', label: 'Import' },
  { key: 'rollover', label: 'Year Rollover' },
  { key: 'users', label: 'Users & Roles' },
  { key: 'audit', label: 'Audit Log' },
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
        {section === 'fees' && <FeeStructure />}
        {section === 'import' && <ImportData />}
        {section === 'rollover' && <Rollover />}
        {section === 'audit' && <AuditLog />}
        {section === 'users' && <Users />}
        {section === 'backup' && <Backup />}
      </div>
    </div>
  )
}

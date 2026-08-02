import { useState } from 'react'
import { FeeStructure } from './settings/FeeStructure'

const SECTIONS = [
  { key: 'fees', label: 'Fee Structure' },
  { key: 'school', label: 'School Profile' },
  { key: 'users', label: 'Users & Roles' },
] as const

type SectionKey = (typeof SECTIONS)[number]['key']

export function SettingsPage() {
  const [section, setSection] = useState<SectionKey>('fees')
  return (
    <div>
      <h1 className="text-xl font-semibold text-slate-800">Settings</h1>
      <div className="mt-4 flex gap-1 border-b border-slate-200">
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
        {section === 'fees' && <FeeStructure />}
        {section === 'school' && <Placeholder name="School profile & branding" />}
        {section === 'users' && <Placeholder name="Users & roles" />}
      </div>
    </div>
  )
}

function Placeholder({ name }: { name: string }) {
  return (
    <div className="rounded-lg border border-dashed border-slate-300 bg-white/50 p-5 text-sm text-slate-500">
      {name} — being built in a later step.
    </div>
  )
}

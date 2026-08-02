import { useState } from 'react'
import { ImportStudents } from './ImportStudents'
import { ImportBalances } from './ImportBalances'
import { ImportStaff } from './ImportStaff'

const TABS = [
  { key: 'students', label: 'Students' },
  { key: 'balances', label: 'Opening fee balances' },
  { key: 'staff', label: 'Staff' },
] as const

type TabKey = (typeof TABS)[number]['key']

/** Onboarding imports, in the order you run them: the student roster, each
 *  student's opening arrears, and the staff list. */
export function ImportData() {
  const [tab, setTab] = useState<TabKey>('students')
  return (
    <div>
      <div className="mb-5 inline-flex rounded-lg border border-slate-200 bg-slate-50 p-0.5">
        {TABS.map((t) => (
          <button key={t.key} onClick={() => setTab(t.key)}
            className={`rounded-md px-4 py-1.5 text-sm font-medium transition ${
              tab === t.key ? 'bg-white text-brand-700 shadow-sm' : 'text-slate-500 hover:text-slate-700'
            }`}>
            {t.label}
          </button>
        ))}
      </div>
      {tab === 'students' && <ImportStudents />}
      {tab === 'balances' && <ImportBalances />}
      {tab === 'staff' && <ImportStaff />}
    </div>
  )
}

import { useState } from 'react'
import { CollectPayment } from './CollectPayment'
import { GenerateChallans } from './GenerateChallans'
import { Defaulters } from './Defaulters'

const TABS = [
  { key: 'collect', label: 'Collect Payment' },
  { key: 'generate', label: 'Generate Challans' },
  { key: 'defaulters', label: 'Defaulters' },
] as const

type TabKey = (typeof TABS)[number]['key']

export function FeesPage() {
  const [tab, setTab] = useState<TabKey>('collect')
  return (
    <div>
      <h1 className="text-xl font-semibold text-slate-800">Fees</h1>
      <div className="mt-4 flex gap-1 border-b border-slate-200">
        {TABS.map((t) => (
          <button
            key={t.key}
            onClick={() => setTab(t.key)}
            className={`-mb-px border-b-2 px-4 py-2 text-sm ${
              tab === t.key ? 'border-brand-600 font-medium text-brand-700' : 'border-transparent text-slate-500 hover:text-slate-700'
            }`}
          >
            {t.label}
          </button>
        ))}
      </div>
      <div className="mt-5">
        {tab === 'collect' && <CollectPayment />}
        {tab === 'generate' && <GenerateChallans />}
        {tab === 'defaulters' && <Defaulters />}
      </div>
    </div>
  )
}

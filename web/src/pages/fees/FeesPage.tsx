import { useState } from 'react'
import { FamilyCollect } from './FamilyCollect'
import { CollectPayment } from './CollectPayment'
import { BulkCollect } from './BulkCollect'
import { GenerateChallans } from './GenerateChallans'
import { Defaulters } from './Defaulters'
import { Discounts } from './Discounts'
import { PendingClearances } from './PendingClearances'

// "Collect" is the family counter and is the default, because it is the screen
// that runs two hundred times a day. The per-student screen stays as "Single
// student" for the cases that genuinely are one child — a one-off charge, a
// correction — but it is no longer the way a fee is normally taken.
const TABS = [
  { key: 'collect', label: 'Collect' },
  // The first ten days of a month are a class-at-a-time job, not a
  // family-at-a-time one: 400 collections used to mean 400 searches.
  { key: 'bulk', label: 'Bulk collect' },
  { key: 'single', label: 'Single student' },
  { key: 'generate', label: 'Generate Challans' },
  { key: 'discounts', label: 'Discounts' },
  { key: 'pending', label: 'Pending' },
  { key: 'defaulters', label: 'Defaulters' },
] as const

type TabKey = (typeof TABS)[number]['key']

export function FeesPage() {
  const [tab, setTab] = useState<TabKey>('collect')
  return (
    <div>
      <div className="mb-5 flex gap-1 overflow-x-auto border-b border-slate-200">
        {TABS.map((t) => (
          <button
            key={t.key}
            onClick={() => setTab(t.key)}
            className={`-mb-px whitespace-nowrap border-b-2 px-4 py-2.5 text-sm transition ${
              tab === t.key
                ? 'border-brand-600 font-semibold text-brand-700'
                : 'border-transparent text-slate-500 hover:border-slate-300 hover:text-slate-700'
            }`}
          >
            {t.label}
          </button>
        ))}
      </div>
      <div>
        {tab === 'collect' && <FamilyCollect />}
        {tab === 'bulk' && <BulkCollect />}
        {tab === 'single' && <CollectPayment />}
        {tab === 'generate' && <GenerateChallans />}
        {tab === 'discounts' && <Discounts />}
        {tab === 'pending' && <PendingClearances />}
        {tab === 'defaulters' && <Defaulters />}
      </div>
    </div>
  )
}

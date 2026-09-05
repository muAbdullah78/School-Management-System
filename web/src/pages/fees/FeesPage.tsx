import { useState } from 'react'
import { useAuth } from '@/auth/AuthProvider'
import { canWrite } from '@/auth/roles'
import { ObserverNotice } from '@/components/ObserverNotice'
import { FamilyCollect } from './FamilyCollect'
import { CollectPayment } from './CollectPayment'
import { BulkCollect } from './BulkCollect'
import { GenerateChallans } from './GenerateChallans'
import { Defaulters } from './Defaulters'
import { Discounts } from './Discounts'
import { PendingClearances } from './PendingClearances'
import { Deposits } from './Deposits'

// "Collect" is the family counter and is the default, because it is the screen
// that runs two hundred times a day. The per-student screen stays as "Single
// student" for the cases that genuinely are one child. A one-off charge, a
// correction, but it is no longer the way a fee is normally taken.
// `writes` marks a tab whose whole purpose is to change something. An observer
// is shown the other tabs and not these, rather than being shown a counter with
// a dead Take Payment button. A form that cannot submit reads as a fault in the
// software, and its Save button used to report success while doing nothing.
const TABS = [
  { key: 'collect', label: 'Collect', writes: true },
  // The first ten days of a month are a class-at-a-time job, not a
  // family-at-a-time one: 400 collections used to mean 400 searches.
  { key: 'bulk', label: 'Bulk collect', writes: true },
  { key: 'single', label: 'Single student', writes: true },
  { key: 'generate', label: 'Generate Challans', writes: true },
  { key: 'discounts', label: 'Discounts', writes: true },
  { key: 'pending', label: 'Pending', writes: false },
  { key: 'defaulters', label: 'Defaulters', writes: false },
  // Reading what is held is not a write, so an observer keeps this tab; the
  // Refund and Charge buttons inside it are gated separately, and refunding
  // needs owner or principal rather than merely write access.
  { key: 'deposits', label: 'Deposits', writes: false },
] as const

type TabKey = (typeof TABS)[number]['key']

export function FeesPage() {
  const { profile } = useAuth()
  const mayWrite = canWrite(profile?.role)
  const tabs = TABS.filter((t) => mayWrite || !t.writes)
  const [tab, setTab] = useState<TabKey>(mayWrite ? 'collect' : 'defaulters')
  return (
    <div>
      {!mayWrite && <ObserverNotice what="fee records" />}
      <div className="mb-5 flex gap-1 overflow-x-auto border-b border-slate-200">
        {tabs.map((t) => (
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
        {tab === 'deposits' && <Deposits />}
        {tab === 'defaulters' && <Defaulters />}
      </div>
    </div>
  )
}

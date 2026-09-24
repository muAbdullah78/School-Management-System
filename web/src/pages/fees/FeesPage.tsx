import { useQuery } from '@tanstack/react-query'
import { useAuth } from '@/auth/AuthProvider'
import { TabBar } from '@/components/TabBar'
import { useUrlTab } from '@/lib/useUrlTab'
import { listPendingPayments } from '@/lib/db'
import { canWrite } from '@/auth/roles'
import { ObserverNotice } from '@/components/ObserverNotice'
import { FamilyCollect } from './FamilyCollect'
import { BulkCollect } from './BulkCollect'
import { GenerateChallans } from './GenerateChallans'
import { BillingCalendar } from './BillingCalendar'
import { Arrears } from './Arrears'
import { Discounts } from './Discounts'
import { PendingClearances } from './PendingClearances'
import { Deposits } from './Deposits'

// "Collect" is the family counter and is the default, because it is the screen
// that runs two hundred times a day.
//
// "SINGLE STUDENT" IS GONE. It was Collect with a narrower search: the same
// action, the same function underneath, reached through a different door. A
// counter that handles one child or four without being told which is simpler
// than two counters, and one fewer screen is one fewer place for the two to
// disagree.
// `writes` marks a tab whose whole purpose is to change something. An observer
// is shown the other tabs and not these, rather than being shown a counter with
// a dead Take Payment button. A form that cannot submit reads as a fault in the
// software, and its Save button used to report success while doing nothing.
const TABS = [
  { key: 'collect', label: 'Collect', writes: true },
  // The first ten days of a month are a class-at-a-time job, not a
  // family-at-a-time one: 400 collections used to mean 400 searches.
  { key: 'bulk', label: 'Bulk collect', writes: true },
  // Was "Generate Challans", and the verb was the problem: pressing it was what
  // decided whether a child owed money. 0139 made the month bill itself, so this
  // screen is now where you check the year and print the paper, which is the
  // half that was always valuable.
  { key: 'challans', label: 'Challans', writes: true },
  { key: 'discounts', label: 'Discounts', writes: true },
  { key: 'pending', label: 'Pending', writes: false },
  // "Defaulters" meant "owes anything", so it fired on the second of the
  // month and listed the whole school. Arrears means owing for a month that
  // has already finished, which is the question the office is actually working
  // from, and it drops the accusing word for a family who is simply not in yet.
  { key: 'arrears', label: 'Arrears', writes: false },
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
  // In the address bar (/fees?tab=pending), so a link opens the right tab and
  // a reload stays on it. An observer opens on Arrears, as before: it is the
  // list they are there to read.
  const [tab, setTab] = useUrlTab<TabKey>(tabs.map((t) => t.key), mayWrite ? 'collect' : 'arrears')
  // The count on the Pending tab: money accepted and not yet cleared is the
  // one list here that goes stale if nobody opens it.
  const pending = useQuery({ queryKey: ['pendingPayments'], queryFn: listPendingPayments, staleTime: 60_000 })
  return (
    <div>
      {!mayWrite && <ObserverNotice what="fee records" />}
      <TabBar
        label="Fees"
        value={tab}
        onChange={setTab}
        tabs={tabs.map((t) => ({
          key: t.key, label: t.label,
          count: t.key === 'pending' ? pending.data?.length ?? null : null,
        }))}
      />
      <div>
        {tab === 'collect' && <FamilyCollect onOpenPending={() => setTab('pending')} />}
        {tab === 'bulk' && <BulkCollect />}
        {tab === 'challans' && (
          <div className="space-y-5">
            <BillingCalendar />
            <GenerateChallans />
          </div>
        )}
        {tab === 'discounts' && <Discounts />}
        {tab === 'pending' && <PendingClearances />}
        {tab === 'deposits' && <Deposits />}
        {tab === 'arrears' && <Arrears />}
      </div>
    </div>
  )
}

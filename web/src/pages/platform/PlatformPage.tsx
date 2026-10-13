import { useMemo, useState } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useAuth } from '@/auth/AuthProvider'
import {
  actionNeeded, amPlatformAdmin,
  listPlatformSchools, operatorEnter, platformRevenue,
  platformSchemaState, raisePlatformInvoice, recordPlatformPayment, refreshAllCounts,
  schoolDetail,
  type ActivationResult, type PaymentSettled, type PlatformSchool, type SchemaState,
} from '@/lib/platform'
import type { Term } from '@/lib/subscription'
import { TERM_LABEL } from '@/lib/plans'
import { formatPkr } from '@/lib/licence'
import { fmtDate } from '@/lib/format'
import { monthStart, today } from '@/lib/dates'
import { money, PaymentOutcome, statusWords, wholeRupees } from './status'
import { SchoolsTable, type QuickKind } from './SchoolsTable'
import { SchoolDrawer, type DrawerTab } from './SchoolDrawer'
import { Renewals } from './Renewals'
import { Claims } from './Claims'
import { BillingSettings } from './BillingSettings'
import { LifecycleDialog } from './Lifecycle'
import { OffboardDialog } from './Offboard'
import { NewSchoolDialog } from './NewSchool'
import { Discounts } from './Discounts'
import { Business } from './Business'
import { Publishing } from './Publishing'
import { LeftBehind } from './LeftBehind'
import { RoomRequests } from './RoomRequests'
import { UnattachedLogins } from './UnattachedLogins'
import { Reviews } from './Reviews'
import { paymentClaims, dueSoon, platformSettings, orphanReport, unattachedLogins, limitRequests } from '@/lib/platform'

const FIELD = 'rounded border border-slate-300 px-2 py-1.5 text-sm'

type Tab = 'schools' | 'renewals' | 'claims' | 'business' | 'publishing' | 'billing'
  | 'leftbehind' | 'reviews' | 'strandedlogins' | 'roomrequests' | 'discounts'

// What each screen is FOR, in one line, because the heading alone does not say.
// "Renewals" and "Payments reported" are both about money arriving and a person
// opening the console cold cannot tell which is which.
const TAB_SUBTITLE: Record<Tab, string> = {
  schools: '',
  renewals: 'Licences ending soon, worst first. This is the call list.',
  claims: 'Schools that say they have paid, waiting to be matched to the bank.',
  roomrequests: 'Schools that have filled their plan and cannot admit the next child.',
  discounts: 'What we are offering off the price list, and which schools are on it.',
  business: 'What the company is worth: revenue, churn and the plan mix.',
  publishing: 'The desktop installer, and notices every school sees.',
  billing: 'Our own NTN and bank details, printed on every invoice we raise.',
  leftbehind: 'Records whose school no longer exists. Normally none.',
  reviews: 'What schools have said publicly, and anything reported as abuse.',
  strandedlogins: 'People who can sign in and have no school. Should be none, ever.',
}

const TAB_TITLE: Record<Tab, string> = {
  schools: 'Schools',
  renewals: 'Renewals',
  claims: 'Payments reported',
  roomrequests: 'Requests for more room',
  discounts: 'Discounts',
  business: 'The business',
  publishing: 'Downloads and notices',
  billing: 'Our billing details',
  leftbehind: 'Records with no school',
  reviews: 'What schools say',
  strandedlogins: 'Logins with no school',
}

// today() USED TO BE `new Date().toISOString().slice(0, 10)`, which is today in
// UTC. Pakistan is UTC+5, so from midnight to 5am in Karachi it named
// YESTERDAY - and this file uses it twice for the Record payment dialog: once
// to pre-fill the date received, and once as the date picker's `max`. So an
// operator reconciling the bank at half past midnight got yesterday's date
// filled in AND was refused when they tried to correct it to today. Back-office
// work happens at night; that is when this fired. See web/src/lib/dates.ts.

/**
 * The product owner's console: every school, what they owe, and what needs
 * doing today.
 *
 * Ordered by what needs action rather than alphabetically. The whole point is
 * to answer "who do I call this morning?" without reading the list.
 */
export function PlatformPage() {
  const { signOut, session } = useAuth()
  const qc = useQueryClient()
  const [msg, setMsg] = useState<string | null>(null)
  const [err, setErr] = useState<string | null>(null)
  const [from, setFrom] = useState(monthStart())
  const [to, setTo] = useState(today())
  const [paying, setPaying] = useState<PlatformSchool | null>(null)
  const [visiting, setVisiting] = useState<PlatformSchool | null>(null)
  const [tab, setTab] = useState<Tab>('schools')
  const [creating, setCreating] = useState(false)
  const [lifecycleFor, setLifecycleFor] = useState<PlatformSchool | null>(null)
  const [offboarding, setOffboarding] = useState<PlatformSchool | null>(null)
  const [invoicing, setInvoicing] = useState<PlatformSchool | null>(null)
  // ONE WORKSPACE INSTEAD OF SIX DIALOG FLAGS. The console used to carry a piece
  // of state per popup - ledgerFor, historyFor, openSchool - and the school
  // being worked on could be in three of them at once, each holding a snapshot
  // taken at a different moment. There is now one selected school and one tab.
  const [openId, setOpenId] = useState<string | null>(null)
  const [drawerTab, setDrawerTab] = useState<DrawerTab>('overview')

  const isAdmin = useQuery({ queryKey: ['amPlatformAdmin', session?.user?.id], queryFn: amPlatformAdmin })
  // Counts for the tab badges. Loaded whatever tab is showing, because the whole
  // point of a badge is to be seen from the tab you are already on. A queue you
  // have to open in order to discover is a queue nobody works.
  const claimCount = useQuery({
    queryKey: ['paymentClaims', 'pending'], queryFn: () => paymentClaims('pending'),
    enabled: isAdmin.data === true,
  })
  const renewalCount = useQuery({
    queryKey: ['dueSoon', 45], queryFn: () => dueSoon(45),
    enabled: isAdmin.data === true,
  })
  // Schools asking for room for more pupils than their plan covers. Badged and
  // warned, because unlike every other queue in this console the school at the
  // other end of one of these is REFUSING ADMISSIONS while it waits: migration
  // 0128 blocks the admission and tells them to ask us. A day in this queue is a
  // day of families being turned away, so it outranks the renewals call list.
  const roomCount = useQuery({
    queryKey: ['limitRequests', 'pending'], queryFn: () => limitRequests('pending'),
    enabled: isAdmin.data === true,
    retry: false,
  })
  // A warning dot on the tab rather than a banner on every screen. An invoice
  // printed without an NTN is useless to the school receiving it and they will
  // not tell us, so the console has to keep asking until it is filled in.
  const settings = useQuery({
    queryKey: ['platformSettings'], queryFn: platformSettings,
    enabled: isAdmin.data === true,
  })
  const settingsIncomplete = (settings.data?.missing.length ?? 0) > 0
  // Distinct school ids with records but no school row. Normally zero, and then
  // the tab is not rendered at all, but when it is not zero, nothing else in
  // this console would ever show it: those ids are absent from the school list
  // by definition.
  const orphanCount = useQuery({
    queryKey: ['orphanReport', 'count'],
    queryFn: async () => new Set((await orphanReport()).map((r) => r.school_id)).size,
    enabled: isAdmin.data === true,
    retry: false,
  })
  // Logins that can sign in and belong to no school. Same reasoning as the
  // count above and a worse failure: those people are CUSTOMERS who have paid
  // us nothing yet, are being shown a wall, and are indistinguishable in the
  // school list from a school that simply has not opened the app.
  const strandedCount = useQuery({
    queryKey: ['unattachedLogins', 'count'],
    queryFn: async () => (await unattachedLogins()).length,
    enabled: isAdmin.data === true,
    retry: false,
  })
  // FETCHED ONCE, WITH ARCHIVED INCLUDED, and filtered in the table.
  //
  // This used to be keyed on a "Show archived" checkbox in the page header,
  // with a comment warning that an archived school left in the cache is how a
  // departed customer turns up in this month's totals. That warning was right
  // and the checkbox was the wrong answer to it: a control in the header that
  // silently changes what a list contains is a control people forget is on.
  // Archived is a filter on the table now, where a person looks for it, and the
  // header counts below exclude archived explicitly rather than relying on a
  // flag being off.
  const schools = useQuery({
    queryKey: ['platformSchools', 'all'],
    queryFn: () => listPlatformSchools(true),
    enabled: isAdmin.data === true,
  })
  const revenue = useQuery({
    queryKey: ['platformRevenue', from, to],
    queryFn: () => platformRevenue(from, to),
    enabled: isAdmin.data === true,
  })
  const schema = useQuery({
    queryKey: ['platformSchemaState'], queryFn: platformSchemaState, enabled: isAdmin.data === true,
  })

  const rows = useMemo(() => schools.data ?? [], [schools.data])
  // The school the drawer is showing, read from the LIVE list rather than held
  // in state. Holding the object meant the drawer kept rendering the balance and
  // the status as they were when the row was clicked, so recording a payment
  // left the header claiming they still owed it.
  const openSchool = useMemo(
    () => rows.find((r) => r.school_id === openId) ?? null, [rows, openId])

  const act = useMutation({
    mutationFn: async (fn: () => Promise<unknown>) => fn(),
    onSuccess: () => {
      void qc.invalidateQueries({ queryKey: ['platformSchools'] })
      void qc.invalidateQueries({ queryKey: ['platformRevenue'] })
      void qc.invalidateQueries({ queryKey: ['platformLedger'] })
    },
    onError: (e) => setErr((e as Error).message),
  })

  function run(label: string, fn: () => Promise<unknown>) {
    setErr(null); setMsg(null)
    act.mutate(fn, { onSuccess: () => setMsg(label) })
  }

  if (isAdmin.isLoading) return <div className="p-8 text-slate-500">Loading…</div>

  if (isAdmin.data !== true) {
    return (
      <div className="flex min-h-full items-center justify-center bg-slate-100 p-4">
        <div className="w-full max-w-sm rounded-lg bg-white p-6 text-center shadow">
          <h1 className="text-lg font-semibold text-slate-800">Not available</h1>
          <p className="mt-2 text-sm text-slate-600">This area is for the system operator.</p>
          <button onClick={() => void signOut()} className="mt-4 text-sm text-brand-700 hover:underline">
            Sign out
          </button>
        </div>
      </div>
    )
  }

  // Live schools only. An archived customer counted in "3 paying" is how last
  // year's revenue ends up in this year's summary.
  const live = rows.filter((s) => !s.archived)
  const counts = {
    total: live.length,
    paying: live.filter((s) => s.status === 'active').length,
    trial: live.filter((s) => s.status === 'trialing').length,
    attention: live.filter((s) => actionNeeded(s) !== null).length,
  }
  const rev = revenue.data

  return (
    <div className="min-h-full bg-slate-100 p-4">
      <div className="mx-auto max-w-6xl space-y-4">
        <header className="flex flex-wrap items-center justify-between gap-3">
          {/* THE SUBTITLE USED TO DESCRIBE SCHOOLS ON EVERY TAB. On Renewals it
              read "1 total · 0 paying · 1 on trial · 0 need attention", which is
              the school list's summary rendered under a heading about licences,
              and on "Our billing details" it was pure noise. A number under a
              heading is read as being about that heading. */}
          <div>
            <h1 className="text-lg font-semibold text-slate-800">{TAB_TITLE[tab]}</h1>
            {tab === 'schools' ? (
              <p className="text-sm text-slate-500">
                {counts.total} total · {counts.paying} paying · {counts.trial} on trial ·{' '}
                <span className={counts.attention ? 'font-medium text-due-700' : ''}>
                  {counts.attention} need attention
                </span>
              </p>
            ) : (
              <p className="text-sm text-slate-500">{TAB_SUBTITLE[tab]}</p>
            )}
          </div>
          <div className="flex flex-wrap items-center gap-2">
            {tab === 'schools' && (
              <>
                <button onClick={() => setCreating(true)}
                  className="rounded bg-brand-600 px-3 py-1.5 text-sm font-medium text-white hover:bg-brand-700">
                  Add a school
                </button>
              </>
            )}
            <button
              onClick={() => run('Student counts refreshed.', refreshAllCounts)}
              disabled={act.isPending}
              className="rounded border border-slate-300 bg-white px-3 py-1.5 text-sm text-slate-700 hover:bg-slate-50 disabled:opacity-60"
            >
              Refresh counts
            </button>
            <button onClick={() => void signOut()} className="rounded px-3 py-1.5 text-sm text-slate-600 hover:bg-slate-200">
              Sign out
            </button>
          </div>
        </header>

        {/* Tabs rather than routes: the console is one page behind one gate, and
            a router here would mean four more ProtectedRoute wrappers guarding the
            same thing. The badges are the reason the nav exists at all. A queue
            you have to open in order to discover is a queue nobody works. */}
        <nav className="flex flex-wrap gap-1 rounded-lg border border-slate-200 bg-white p-1">
          <TabButton now={tab} me="schools" set={setTab} label="Schools" />
          <TabButton now={tab} me="renewals" set={setTab} label="Renewals"
            badge={renewalCount.data?.length} />
          <TabButton now={tab} me="claims" set={setTab} label="Payments reported"
            badge={claimCount.data?.length} />
          {/* Only when there IS something, the same rule the two panels below
              follow: a permanently empty tab teaches people to stop reading the
              nav. Warned as well as badged, which the payment queue is not,
              because a payment report waiting a day costs us nothing and a room
              request waiting a day is a school turning a family away. */}
          {(roomCount.data?.length ?? 0) > 0 && (
            <TabButton now={tab} me="roomrequests" set={setTab} label="Requests for more room"
              badge={roomCount.data?.length} warn />
          )}
          {/* Beside "The business" rather than under Schools, because a code is
              a commercial instrument and not a property of any one school. Not
              badged with a count: a number here would mean "action needed", and
              a live discount needs no action. */}
          <TabButton now={tab} me="discounts" set={setTab} label="Discounts" />
          <TabButton now={tab} me="business" set={setTab} label="The business" />
          <TabButton now={tab} me="publishing" set={setTab} label="Downloads & notices" />
          {/* Deliberately NOT badged with a count. A badge means "there is
              something here for you to action", and the only thing an operator
              can do to a review is take one down for abuse. A number nagging
              from the nav would invite exactly the habit this design is built
              to prevent. */}
          <TabButton now={tab} me="reviews" set={setTab} label="What schools say" />
          <TabButton now={tab} me="billing" set={setTab} label="Our billing details"
            warn={settingsIncomplete} />
          {/* Only appears when there IS something, because a permanently empty
              tab teaches people to stop reading the nav. What it describes is
              invisible everywhere else in this console: a school with no
              `schools` row is not in the school list, so its leftover records
              have no other screen. */}
          {(orphanCount.data ?? 0) > 0 && (
            <TabButton now={tab} me="leftbehind" set={setTab} label="Records with no school"
              badge={orphanCount.data} warn />
          )}
          {/* Same rule: only when there IS something. This one is the more
              urgent of the two, because what it lists is a person sitting in
              front of a screen that will not let them in. */}
          {(strandedCount.data ?? 0) > 0 && (
            <TabButton now={tab} me="strandedlogins" set={setTab} label="Logins with no school"
              badge={strandedCount.data} warn />
          )}
        </nav>

        {tab === 'renewals' && (
          <Renewals
            onOpenSchool={(id) => {
              // Straight into the school's Billing tab, because that is the
              // question the renewals list was asking.
              setTab('schools'); setDrawerTab('billing'); setOpenId(id)
            }}
            // Straight into the payment dialog, on the renewals screen, without
            // changing tab. The operator is on the phone: the school has just
            // said they have transferred it, and the reference is being read out
            // now, not after two clicks of navigation.
            onTakePayment={(id) => {
              const s = rows.find((r) => r.school_id === id)
              if (s) { setErr(null); setMsg(null); setPaying(s) }
            }}
          />
        )}
        {tab === 'claims' && <Claims />}
        {tab === 'roomrequests' && (
          <RoomRequests
            onOpenSchool={(id) => {
              // Into their Billing tab, because the question behind every one of
              // these requests is which plan they are on and what they pay.
              setTab('schools'); setDrawerTab('billing'); setOpenId(id)
            }}
          />
        )}
        {tab === 'discounts' && <Discounts />}
        {tab === 'business' && <Business />}
        {tab === 'publishing' && <Publishing />}
        {tab === 'billing' && <BillingSettings />}
        {tab === 'leftbehind' && <LeftBehind />}
        {tab === 'strandedlogins' && <UnattachedLogins />}
        {tab === 'reviews' && <Reviews />}

        {tab === 'schools' && <>

        {/* The books. `Outstanding` is deliberately NOT period-scoped. A
            receivable does not belong to the month it was raised in, and the
            label says so, because a figure next to two dates reads as being
            about those dates. */}
        <div className="rounded-lg border border-slate-200 bg-white p-3">
          <div className="flex flex-wrap items-center justify-between gap-2">
            <div className="text-xs font-semibold uppercase tracking-wide text-slate-500">The books</div>
            <div className="flex items-center gap-2 text-sm">
              <input type="date" value={from} max={to} onChange={(e) => setFrom(e.target.value)} className={FIELD} />
              <span className="text-slate-400">to</span>
              <input type="date" value={to} min={from} onChange={(e) => setTo(e.target.value)} className={FIELD} />
            </div>
          </div>
          {revenue.error && <p className="mt-2 text-sm text-danger-600">{(revenue.error as Error).message}</p>}
          <div className="mt-3 grid gap-3 sm:grid-cols-4">
            <Tile label="Invoiced" value={rev ? formatPkr(rev.net_invoiced) : '-'}
              hint={rev && rev.credited > 0
                ? `after ${formatPkr(rev.credited)} credited back`
                : 'in the dates above'} />
            {/* Two different questions, and 0077 stopped them sharing an answer.
                "Settled" includes the income tax a school withheld and paid to
                the FBR in our name: that money IS paid, and counting it as
                outstanding is how a paid school shows as owing. "In the bank" is
                the cash-flow figure, and it is smaller. */}
            <Tile label="Settled" value={rev ? formatPkr(rev.collected) : '-'}
              hint={rev && rev.tax_withheld > 0
                ? `${formatPkr(rev.cash_received)} in the bank + ${formatPkr(rev.tax_withheld)} tax withheld`
                : 'money that actually arrived'} />
            <Tile label="Given away" value={rev ? formatPkr(rev.discounted) : '-'}
              hint="list price minus what we charged"
              tone={rev && rev.discounted > 0 ? 'warn' : undefined} />
            <Tile label="Owed to us" value={rev ? formatPkr(rev.outstanding_total) : '-'}
              hint="all time, not just these dates"
              tone={rev && rev.outstanding_total > 0 ? 'warn' : undefined} />
          </div>
          {/* Both of these are money, and neither had anywhere to be seen before.
              A month with three voided invoices is a month somebody should look
              at; withheld tax with no CPR is a deduction we cannot claim. */}
          {rev && (rev.voided > 0 || rev.tax_certificates_awaited > 0) && (
            <div className="mt-2 flex flex-wrap gap-3 text-xs">
              {rev.voided > 0 && (
                <span className="rounded bg-slate-100 px-2 py-0.5 text-slate-600">
                  {formatPkr(rev.voided)} of invoices voided in this period
                </span>
              )}
              {rev.tax_certificates_awaited > 0 && (
                <span className="rounded bg-due-50 px-2 py-0.5 text-due-900">
                  {formatPkr(rev.tax_certificates_awaited)} of withheld tax with no CPR on
                  record. We cannot claim it until the certificate arrives
                </span>
              )}
            </div>
          )}
          {rev && rev.schools_owing.length > 0 && (
            <div className="mt-3 border-t border-slate-100 pt-2">
              <div className="text-xs text-slate-500">Who to chase</div>
              <div className="mt-1 flex flex-wrap gap-2">
                {rev.schools_owing.map((s) => (
                  <span key={s.school_id} className="rounded bg-due-50 px-2 py-0.5 text-xs text-due-900">
                    {s.school_name} · {formatPkr(s.outstanding)}
                  </span>
                ))}
              </div>
            </div>
          )}
        </div>

        <SchemaStrip state={schema.data} error={schema.error as Error | null} />

        {msg && <div className="rounded border border-money-200 bg-money-50 p-2 text-sm text-money-800">{msg}</div>}
        {err && <div className="rounded border border-danger-200 bg-danger-50 p-2 text-sm text-danger-700">{err}</div>}

        <SchoolsTable
          schools={rows}
          loading={schools.isLoading}
          error={schools.error as Error | null}
          busy={act.isPending}
          onOpen={(s) => { setDrawerTab('overview'); setOpenId(s.school_id) }}
          onQuickAction={(s, kind: QuickKind) => {
            setErr(null); setMsg(null)
            if (kind === 'pay') setPaying(s)
            else if (kind === 'invoice') setInvoicing(s)
            // An Enterprise school with no price: the price is set on its page,
            // beside the plan, so the quick action opens it there.
            else { setDrawerTab('billing'); setOpenId(s.school_id) }
          }}
        />

        </>}
      </div>

      {/* ONE WORKSPACE. Six dialogs used to be mounted here, each opened from
          its own link on every row. The drawer is the only thing a row opens
          now, and the dialogs below are what the drawer opens in turn: they hold
          logic that took several passes to get right and none of it changed. */}
      {openSchool && (
        <SchoolDrawer
          school={openSchool}
          tab={drawerTab}
          onTab={setDrawerTab}
          onClose={() => setOpenId(null)}
          onPay={() => { setErr(null); setMsg(null); setPaying(openSchool) }}
          onRaiseInvoice={() => { setErr(null); setMsg(null); setInvoicing(openSchool) }}
          onManage={() => { setErr(null); setMsg(null); setLifecycleFor(openSchool) }}
          onVisit={() => { setErr(null); setMsg(null); setVisiting(openSchool) }}
          onOffboard={() => { setErr(null); setMsg(null); setOffboarding(openSchool) }}
        />
      )}

      {paying && (
        <PaymentDialog school={paying} onClose={() => setPaying(null)} />
      )}

      {invoicing && (
        <RaiseInvoiceDialog school={invoicing} onClose={() => setInvoicing(null)} />
      )}

      {creating && (
        <NewSchoolDialog
          onClose={() => setCreating(false)}
          onCreated={(id) => {
            setCreating(false)
            setDrawerTab('overview')
            setOpenId(id)
          }}
        />
      )}

      {lifecycleFor && (
        <LifecycleDialog
          school={lifecycleFor}
          onClose={() => setLifecycleFor(null)}
          onDone={(m) => { setErr(null); setMsg(m); setLifecycleFor(null) }}
        />
      )}

      {offboarding && (
        <OffboardDialog school={offboarding} onClose={() => setOffboarding(null)} />
      )}

      {visiting && (
        <VisitDialog
          school={visiting}
          onClose={() => setVisiting(null)}
          onError={(m) => { setVisiting(null); setErr(m) }}
        />
      )}
    </div>
  )
}

/**
 * What schema this database is actually running.
 *
 * One line, because on a healthy day it is one fact and should not take up
 * space. It goes loud in exactly two cases, and both of them are the reason the
 * ledger was added:
 *
 *  - A GAP. A bundle applies as ONE transaction, so a bundle that dies halfway
 *    rolls back entirely and its migrations never arrive. That has already
 *    happened to a live school: fifteen migrations went missing and nobody
 *    learned until screens started failing at runtime.
 *
 *  - AN EMPTY LEDGER on a database that has the table. 0069 refuses to seed
 *    unless it can prove all six shipped bundles are present, so empty means
 *    "this database is incomplete and I would be lying if I gave you a number".
 */
function SchemaStrip({ state, error }: { state?: SchemaState; error: Error | null }) {
  // Before bundle 7 is pasted, fn_platform_schema_state does not exist and this
  // errors. Saying so plainly beats a blank space, because the fix is one paste.
  if (error) {
    return (
      <div className="rounded border border-due-300 bg-due-50 px-3 py-2 text-sm text-due-900">
        <span className="font-medium">This database has no migration ledger.</span>{' '}
        Paste <code className="rounded bg-due-100 px-1">supabase/bundles/7_ledger_and_limits.sql</code>{' '}
        into the Supabase SQL editor. Until then nothing records which migrations production has.
      </div>
    )
  }
  if (!state) return null

  if (state.applied_count === 0) {
    return (
      <div className="rounded border border-danger-300 bg-danger-50 px-3 py-2 text-sm text-danger-900">
        <span className="font-medium">The migration ledger is empty.</span>{' '}
        0069 refused to record this database because it could not prove every shipped bundle is
        present. Run <code className="rounded bg-danger-100 px-1">supabase/repair/detect.sql</code> and
        apply what it names.
      </div>
    )
  }

  const gaps = state.gaps_total > 0
  // QUIET WHEN IT IS FINE. On a healthy day this said "Schema 38 migrations
  // applied · latest 0105_the_leave_the_school_approved" in a box above the
  // customer list, every day, forever. That is build output, and a business
  // console that opens with a migration filename teaches its owner to skim the
  // top of the page, which is where the money is. It still goes loud, in red and
  // at full size, the moment there is a gap: that is the case it was written
  // for, and the case where a school is silently missing fifteen migrations.
  if (!gaps) {
    return (
      <details className="text-xs text-slate-400">
        <summary className="cursor-pointer select-none hover:text-slate-600">
          Database up to date · {state.applied_count} migration{state.applied_count === 1 ? '' : 's'}
        </summary>
        <div className="mt-1 pl-4">
          Latest {state.latest?.replace(/\.sql$/, '') ?? 'unknown'}. No gaps.
        </div>
      </details>
    )
  }
  return (
    <div className="rounded border border-danger-300 bg-danger-50 px-3 py-2 text-sm text-danger-900">
      <span className="font-medium">Schema</span>{' '}
      {state.applied_count} migration{state.applied_count === 1 ? '' : 's'} applied
      {state.latest && <span className="text-danger-700"> · latest {state.latest.replace(/\.sql$/, '')}</span>}
      <div className="mt-1 font-medium">
        {state.gaps_total} missing in the middle: {state.gaps.join(', ')}
        {state.gaps_total > state.gaps.length && ` … and ${state.gaps_total - state.gaps.length} more`}.
        {' '}A bundle rolled back halfway: apply those migrations before anything else.
      </div>
    </div>
  )
}

function Tile({ label, value, hint, tone }: {
  label: string; value: string; hint?: string; tone?: 'warn'
}) {
  return (
    <div className={`rounded border p-2 ${tone === 'warn' ? 'border-due-200 bg-due-50' : 'border-slate-200'}`}>
      <div className="text-xs text-slate-500">{label}</div>
      <div className={`text-lg font-semibold ${tone === 'warn' ? 'text-due-900' : 'text-slate-800'}`}>{value}</div>
      {hint && <div className="text-[11px] text-slate-400">{hint}</div>}
    </div>
  )
}

/**
 * Raise the next term invoice, and say plainly what that does and does not do.
 *
 * WHAT THIS REPLACED. The Activate dialog picked a plan, a length and a price,
 * and pressing it raised the invoice AND started the paid period. Since 0155
 * access runs on what is PAID: an invoice opens nothing, paying it does. So
 * this dialog raises an invoice and says so, in a box nobody can miss, because
 * "I invoiced them, why are they still locked?" is the question it exists to
 * prevent.
 *
 * NO PLAN PICKER. An invoice is raised on the plan the school is on. Moving a
 * school between plans is Change plan, on its page, which prices the rest of
 * the paid period; doing both from one box is how the old dialog quietly moved
 * schools while invoicing them.
 *
 * THE PRICE IS THE DATABASE'S. Each term is offered at what the next invoice
 * would say for it, the school's live code already taken off. The amount box
 * starts empty, which means exactly that figure. Typing anything else needs a
 * reason, printed on the invoice, and uses a live code up on this invoice: the
 * screen says so before the press, not after.
 *
 * REFUSALS ARE SENTENCES. An invoice already open, no price agreed, a school
 * suspended or cancelled: each is said in plain words before anything is
 * pressed, and anything the database refuses anyway is shown as it says it.
 *
 * OVER THE LIMIT (SB004). A school whose roll is bigger than the limit that
 * will apply in the period being invoiced is a decision for us: move it with
 * Change plan, or invoice it on its plan on purpose, with a reason. Extra room
 * ends with the period it was given in, so it only counts here if it reaches
 * into the new period.
 */
export function RaiseInvoiceDialog({ school, onClose }: {
  school: PlatformSchool
  onClose: () => void
}) {
  const qc = useQueryClient()
  const detail = useQuery({
    queryKey: ['schoolDetail', school.school_id],
    queryFn: () => schoolDetail(school.school_id),
  })
  const v = detail.data?.subscription ?? null
  const [months, setMonths] = useState<Term | null>(null)
  const [amount, setAmount] = useState('')
  const [reason, setReason] = useState('')
  const [err, setErr] = useState<string | null>(null)
  const [done, setDone] = useState<ActivationResult | null>(null)

  const chosen: Term | null = months ?? v?.term_months ?? null
  const term = v?.terms.find((t) => t.months === chosen) ?? null
  const typed = amount.trim() === '' ? null : money(amount)
  const differs = typed !== null && term !== null && typed !== term.amount
  const usesUpCode = differs && (term?.discount_amount ?? 0) > 0
  const codeName = v?.next?.quote.discount?.code ?? null

  // The limit that will apply in the period being invoiced: extra room only if
  // it reaches into it, otherwise the plan's own. The same rule the database
  // applies, read here so the decision is offered before the press.
  const start = v?.next?.period_start ?? null
  const cap = !v ? null
    : v.students.extra != null && v.students.extra_until && start && v.students.extra_until >= start
      ? v.students.extra
      : v.students.plan_limit
  const over = v !== null && cap !== null && v.students.count > cap
  const needsReason = differs || over

  const refusal = !v ? null
    : school.archived ? `${school.school_name} is archived. Bring it back before invoicing it.`
    : v.suspended ? `${school.school_name} is suspended. Lift the suspension before invoicing it.`
    : v.status === 'cancelled' ? `${school.school_name} has cancelled. Reinstate it before invoicing it.`
    : v.cancel_at_period_end ? `${school.school_name} asked to stop at the end of its period, so nothing more is invoiced.`
    : v.open_invoice
      ? `${school.school_name} already has ${v.open_invoice.doc_no ?? 'an invoice'} open for `
        + `${fmtDate(v.open_invoice.period_start)} to ${fmtDate(v.open_invoice.period_end)}, with `
        + `${formatPkr(v.open_invoice.owed)} still owed. That one is paid first.`
    : !v.price.priced
      ? `${school.school_name} is on ${v.plan.name}, and no price has been agreed with it yet. `
        + 'Set its price first, from Billing, Plan and price.'
    : null

  const problem = refusal ? null
    : !term ? 'Choose how many months this invoice is for.'
    : typed !== null && !wholeRupees(typed) ? 'An invoice is a whole number of rupees, nothing below zero.'
    : needsReason && reason.trim().length < 8
      ? over && !differs
        ? 'Their roll is over the limit for this period. Give a reason to invoice them on their plan anyway, or move them with Change plan.'
        : `Charging ${typed !== null && Number.isFinite(typed) ? formatPkr(typed) : 'that'} where the price is ${formatPkr(term.amount)} needs a reason: it is printed on the invoice.`
    : null

  const raise = useMutation({
    mutationFn: () => raisePlatformInvoice(school.school_id, {
      months: chosen, amount: typed, reason: reason.trim() || null,
    }),
    onSuccess: (r) => {
      setErr(null); setDone(r)
      for (const key of ['platformSchools', 'platformLedger', 'schoolDetail', 'platformRevenue', 'dueSoon']) {
        void qc.invalidateQueries({ queryKey: [key] })
      }
    },
    onError: (e) => setErr((e as Error).message),
  })

  const shell = (title: string, body: React.ReactNode) => (
    <div className="fixed inset-0 z-50 flex items-start justify-center overflow-y-auto bg-black/40 p-4 sm:items-center">
      <div role="dialog" aria-modal="true" aria-label={title}
        className="w-full max-w-lg rounded-lg bg-white p-5 text-left shadow-lg">
        <h2 className="text-base font-semibold text-slate-800">{title}</h2>
        {body}
      </div>
    </div>
  )

  if (done) {
    return shell(`${done.doc_no ?? 'Invoice'} raised for ${school.school_name}`, (
      <>
        <dl className="mt-3 grid grid-cols-[auto,1fr] gap-x-4 gap-y-1 rounded border border-slate-200 bg-slate-50 p-3 text-sm">
          <dt className="text-slate-500">Amount</dt>
          <dd className="font-medium text-slate-800">{formatPkr(done.amount)}</dd>
          <dt className="text-slate-500">Covers</dt>
          <dd className="text-slate-800">
            {done.months} month(s), {fmtDate(done.period_start)} to {fmtDate(done.period_end)}
          </dd>
          <dt className="text-slate-500">Due</dt>
          <dd className="text-slate-800">{fmtDate(done.due_on)}</dd>
          <dt className="text-slate-500">Owed on it</dt>
          <dd className="text-slate-800">
            {formatPkr(done.owed)}
            {done.owed < done.amount && (
              <span className="text-money-700"> · {formatPkr(done.amount - done.owed)} of their credit went on it</span>
            )}
          </dd>
        </dl>
        {done.discount_code && !done.overridden && done.discount_amount > 0 && (
          <p className="mt-2 text-sm text-money-700">
            {formatPkr(done.discount_amount)} off with their code {done.discount_code}.
          </p>
        )}
        {done.overridden && (
          <p className="mt-2 text-sm text-due-800">
            Price set by hand: their code {done.discount_code} is used up on this invoice.
          </p>
        )}
        <p className="mt-3 rounded border border-info-200 bg-info-50 px-3 py-2 text-sm text-info-900">
          Nothing changes for {school.school_name} until it is paid. They are{' '}
          {statusWords(done.status).toLowerCase()}, and their paid-through date moves when
          the money is recorded.
        </p>
        <button onClick={onClose}
          className="mt-4 w-full rounded bg-brand-600 px-3 py-2 text-sm font-medium text-white hover:bg-brand-700">
          Done
        </button>
      </>
    ))
  }

  return shell(`Raise an invoice for ${school.school_name}`, (
    <>
      {detail.isLoading && <p className="mt-2 text-sm text-slate-500">Loading…</p>}
      {detail.error && <p className="mt-2 text-sm text-danger-700">{(detail.error as Error).message}</p>}
      {detail.data && !v && (
        <p className="mt-2 text-sm text-danger-700">
          This database does not describe the subscription yet, so there is nothing to price
          an invoice from.
        </p>
      )}

      {v && (
        <>
          <p className="mt-1 text-sm text-slate-600">
            On <span className="font-medium">{v.plan.name}</span>
            {' · '}{v.students.count.toLocaleString()} pupils
            {v.owed > 0 && <> · owes {formatPkr(v.owed)}</>}
            {v.credit > 0 && <> · {formatPkr(v.credit)} in credit</>}
          </p>
          <p className="mt-0.5 text-xs text-slate-500">
            An invoice is raised on the plan they are on. To move them, use Change plan on
            their page first.
          </p>

          {/* THE ONE SENTENCE THIS DIALOG EXISTS TO SAY. */}
          <p className="mt-3 rounded border border-info-200 bg-info-50 px-3 py-2 text-sm text-info-900">
            Raising an invoice does not give {school.school_name} any time. Paying it does:
            their paid-through date moves only when the money is recorded against it.
          </p>

          {refusal ? (
            <p className="mt-3 text-sm text-slate-800">{refusal}</p>
          ) : (
            <>
              <fieldset className="mt-3">
                <legend className="text-sm text-slate-600">How many months</legend>
                <div className="mt-1 space-y-1.5">
                  {v.terms.map((t) => (
                    <label key={t.months}
                      className={`flex cursor-pointer items-start gap-2 rounded border px-3 py-2 text-sm focus-within:ring-2 focus-within:ring-brand-500 ${
                        t.months === chosen ? 'border-brand-500 bg-brand-50' : 'border-slate-200 hover:bg-slate-50'}`}>
                      <input type="radio" name="term" className="mt-0.5" checked={t.months === chosen}
                        onChange={() => setMonths(t.months)} />
                      <span className="flex-1">
                        <span className="flex flex-wrap items-baseline justify-between gap-2">
                          <span className="font-medium text-slate-800">
                            {TERM_LABEL[t.months] ?? `${t.months} months`}
                            {t.chosen && <span className="ml-1 font-normal text-slate-400">their term now</span>}
                          </span>
                          <span className="font-semibold tabular-nums text-slate-800">{formatPkr(t.amount)}</span>
                        </span>
                        <span className="block text-xs text-slate-500">
                          {formatPkr(t.per_month)} a month
                          {t.saving > 0 && <> · saves {formatPkr(t.saving)} against paying monthly</>}
                          {t.discount_amount > 0 && (
                            <span className="text-money-700"> · {formatPkr(t.discount_amount)} off with their code</span>
                          )}
                        </span>
                        {t.discount_note && <span className="block text-xs text-due-800">{t.discount_note}</span>}
                      </span>
                    </label>
                  ))}
                </div>
                {chosen !== null && chosen !== v.term_months && (
                  <p className="mt-1 text-xs text-slate-500">
                    A different term also changes how often they pay from now on.
                  </p>
                )}
              </fieldset>

              {start && (
                <p className="mt-2 text-xs text-slate-500">
                  Covers from {fmtDate(start)}, and it is due that day
                  {start < today() && <> (today, as their paid time has already run out)</>}.
                </p>
              )}

              {over && (
                <p className="mt-3 rounded border border-due-300 bg-due-50 px-3 py-2 text-sm text-due-900">
                  {school.school_name} has {v.students.count.toLocaleString()} pupils and{' '}
                  {v.plan.name} covers {cap?.toLocaleString()} in the period being invoiced. Move
                  them with Change plan on their page, or give a reason below to invoice them on{' '}
                  {v.plan.name} anyway.
                </p>
              )}

              <div className="mt-3 grid gap-3 sm:grid-cols-2">
                <label className="block">
                  <span className="text-sm text-slate-600">
                    Amount <span className="text-slate-400">(empty = {term ? formatPkr(term.amount) : 'the price'})</span>
                  </span>
                  <input value={amount} onChange={(e) => setAmount(e.target.value)} inputMode="numeric"
                    placeholder={term ? String(term.amount) : ''} className={`${FIELD} mt-1 w-full`} />
                </label>
                <label className="block">
                  <span className="text-sm text-slate-600">
                    Reason{needsReason && <span className="text-danger-600"> *</span>}
                  </span>
                  <input value={reason} onChange={(e) => setReason(e.target.value)}
                    placeholder="printed on the invoice" className={`${FIELD} mt-1 w-full`} />
                </label>
              </div>

              {usesUpCode && (
                <p className="mt-2 rounded border border-due-200 bg-due-50 px-3 py-2 text-xs text-due-900">
                  A typed amount replaces the price with their code taken off, and their code
                  {codeName ? ` ${codeName}` : ''} is used up on this invoice: it will not come
                  off again for these months.
                </p>
              )}
            </>
          )}
        </>
      )}

      {err && <p className="mt-3 text-sm text-danger-700">{err}</p>}
      {problem && (
        <p className="mt-3 rounded border border-due-200 bg-due-50 px-3 py-2 text-xs text-due-900">
          {problem}
        </p>
      )}

      <div className="mt-4 flex gap-2">
        {v && !refusal && (
          <button onClick={() => { setErr(null); raise.mutate() }}
            disabled={raise.isPending || problem !== null}
            className="flex-1 rounded bg-brand-600 px-3 py-2 text-sm font-medium text-white hover:bg-brand-700 disabled:opacity-60">
            {raise.isPending ? 'Raising…'
              : `Raise the invoice${term ? ` for ${formatPkr(typed !== null && Number.isFinite(typed) ? typed : term.amount)}` : ''}`}
          </button>
        )}
        <button onClick={onClose}
          className="flex-1 rounded border border-slate-300 px-3 py-2 text-sm hover:bg-slate-50">
          {v && !refusal ? 'Cancel' : 'Close'}
        </button>
      </div>
    </>
  ))
}

// The parser lives in status.tsx so the dialogs on the school's page share it;
// re-exported because payment.test.ts holds it to its promises from here.
export { money }

/** Why Record is disabled, in a sentence, or null when it is not. */
export function whyNot(rawAmount: string, n: number, rawTax: string, t: number, paidOn: string): string | null {
  if (rawAmount.trim() === '') return 'Enter the amount received.'
  if (!Number.isFinite(n)) return `"${rawAmount.trim()}" is not an amount. Digits only, and a decimal point if you need one.`
  if (n <= 0) return 'A payment has to be more than zero. To reverse a charge, credit or void the invoice on the statement.'
  if (rawTax.trim() !== '' && !Number.isFinite(t)) return `"${rawTax.trim()}" is not an amount.`
  if (t < 0) return 'Withheld tax cannot be negative.'
  // The date picker carries a `max`, but a max on an <input type="date"> is only
  // enforced by native form validation and there is no form here, so a date
  // typed straight into the field went through. The database has no future
  // check either: a payment dated next March would have landed in the books and
  // shown up in the wrong month's revenue.
  if (paidOn > today()) return 'That date is in the future. Record a payment on the day it actually arrived.'
  if (paidOn < '2000-01-01') return 'That date looks wrong.'
  return null
}

/**
 * Record money a school sent us, then say what it did.
 *
 * WHY THE DIALOG STAYS OPEN AFTER SAVING. Since 0155 a payment goes against
 * what is owed, oldest first; money left over raises the next term invoice and
 * pays it; anything still left is credit; and the school's paid-through date
 * moves only as far as invoices are paid in full. The database answers with all
 * of that, and the operator is usually on the phone with the school asking
 * "so are we open, and until when?". A green "recorded" line answered none of it.
 */
export function PaymentDialog({ school, onClose }: {
  school: PlatformSchool
  onClose: () => void
}) {
  const qc = useQueryClient()
  // Pre-filled with what they owe, which is the amount in almost every case.
  const [amount, setAmount] = useState(school.outstanding > 0 ? String(school.outstanding) : '')
  const [paidOn, setPaidOn] = useState(today())
  const [method, setMethod] = useState('bank')
  const [reference, setReference] = useState('')
  const [note, setNote] = useState('')
  const [wht, setWht] = useState('')
  const [cert, setCert] = useState('')
  const [err, setErr] = useState<string | null>(null)
  const [done, setDone] = useState<PaymentSettled | null>(null)
  const n = money(amount)
  const t = wht.trim() === '' ? 0 : money(wht)
  // THE CERTIFICATE FIELD IS CLEARED, NOT JUST GREYED OUT.
  // It used to be disabled when the withheld amount went back to zero while
  // still holding whatever had been typed, and still being sent. The database
  // refuses that outright - "A tax certificate was given but no withheld
  // amount" - so the operator got a hard error naming a field they could see
  // was empty and could not edit. Deriving what is sent from the tax figure
  // means the two can never disagree.
  const sendCert = t > 0 ? cert.trim() || null : null
  const problem = whyNot(amount, n, wht, t, paidOn)
  // What the invoice is actually settled by. The gap between this and the
  // outstanding figure is what the operator is deciding about.
  const settles = n + t

  const save = useMutation({
    mutationFn: () => recordPlatformPayment({
      schoolId: school.school_id, amount: n, paidOn, method,
      reference: reference.trim() || null, note: note.trim() || null,
      taxWithheld: t, taxCertificate: sendCert,
    }),
    onSuccess: (r) => {
      setErr(null); setDone(r)
      for (const key of ['platformSchools', 'platformRevenue', 'platformLedger', 'schoolDetail', 'dueSoon']) {
        void qc.invalidateQueries({ queryKey: [key] })
      }
    },
    onError: (e) => setErr((e as Error).message),
  })

  if (done) {
    return (
      <div className="fixed inset-0 z-50 flex items-start justify-center overflow-y-auto bg-black/40 p-4 sm:items-center">
        <div role="dialog" aria-modal="true" aria-label="Payment recorded"
          className="w-full max-w-md rounded-lg bg-white p-5 shadow-lg">
          <h2 className="text-base font-semibold text-slate-800">
            {formatPkr(done.settled)} recorded for {school.school_name}
          </h2>
          {done.awaiting_certificate && (
            <p className="mt-1 text-xs text-slate-500">
              {formatPkr(done.tax_withheld)} of it is tax they withheld. Attach the CPR from the
              statement when it arrives.
            </p>
          )}
          <div className="mt-3">
            <PaymentOutcome r={done} />
          </div>
          <button onClick={onClose}
            className="mt-4 w-full rounded bg-brand-600 px-3 py-2 text-sm font-medium text-white hover:bg-brand-700">
            Done
          </button>
        </div>
      </div>
    )
  }

  return (
    <div className="fixed inset-0 z-50 flex items-start justify-center overflow-y-auto bg-black/40 p-4 sm:items-center">
      <div role="dialog" aria-modal="true" aria-label="Record a payment"
        className="w-full max-w-md rounded-lg bg-white p-5 shadow-lg">
        <h2 className="text-base font-semibold text-slate-800">Record a payment</h2>
        <p className="mt-1 text-sm text-slate-600">
          {school.school_name}
          {school.outstanding > 0
            ? <> · owes {formatPkr(school.outstanding)}</>
            : <> · nothing outstanding. What is not needed for their next invoice stays as credit</>}
        </p>
        <div className="mt-3 grid gap-3 sm:grid-cols-2">
          <label className="block">
            <span className="text-sm text-slate-600">Amount</span>
            <input autoFocus value={amount} onChange={(e) => setAmount(e.target.value)} inputMode="decimal"
              className={`${FIELD} mt-1 w-full`} />
          </label>
          <label className="block">
            <span className="text-sm text-slate-600">Received on</span>
            <input type="date" value={paidOn} max={today()} onChange={(e) => setPaidOn(e.target.value)}
              className={`${FIELD} mt-1 w-full`} />
          </label>
          <label className="block">
            <span className="text-sm text-slate-600">How</span>
            <select value={method} onChange={(e) => setMethod(e.target.value)} className={`${FIELD} mt-1 w-full`}>
              <option value="bank">Bank transfer</option>
              <option value="cash">Cash</option>
              <option value="cheque">Cheque</option>
              <option value="online">Online</option>
              <option value="other">Other</option>
            </select>
          </label>
          <label className="block">
            <span className="text-sm text-slate-600">Reference</span>
            {/* The only way to tie a row to a bank statement when a school says
                it paid and we cannot find it. */}
            <input value={reference} onChange={(e) => setReference(e.target.value)}
              placeholder="e.g. HBL-77123" className={`${FIELD} mt-1 w-full`} />
          </label>
          {/* THE FIELD THAT KEEPS THE RECEIVABLE HONEST.
              Under section 153(1)(b) a school buying services must deduct income
              tax at source and pay it to the FBR on our behalf. So a school
              invoiced Rs 38,000 transfers Rs 34,960 and sends a CPR for the
              Rs 3,040 it deducted. Record only the transfer and Rs 3,040 sits as
              outstanding forever, and we chase a school for money it has already
              paid: in our name. */}
          <label className="block">
            <span className="text-sm text-slate-600">Tax they withheld</span>
            <input value={wht} onChange={(e) => setWht(e.target.value)} inputMode="decimal"
              placeholder="0" className={`${FIELD} mt-1 w-full`} />
          </label>
          <label className="block">
            <span className="text-sm text-slate-600">CPR / certificate no.</span>
            <input value={t > 0 ? cert : ''} onChange={(e) => setCert(e.target.value)}
              disabled={t <= 0}
              placeholder={t > 0 ? 'blank if not received yet' : '-'}
              className={`${FIELD} mt-1 w-full disabled:bg-slate-50`} />
          </label>
          <label className="block sm:col-span-2">
            <span className="text-sm text-slate-600">Note (optional)</span>
            <input value={note} onChange={(e) => setNote(e.target.value)} className={`${FIELD} mt-1 w-full`} />
          </label>
        </div>
        {t > 0 && (
          <p className="mt-2 rounded bg-slate-50 px-3 py-2 text-xs text-slate-600">
            {formatPkr(n)} received plus {formatPkr(t)} paid to the FBR on our behalf:
            this settles <span className="font-medium">{formatPkr(settles)}</span>.
            {cert.trim() === '' && ' The CPR can be attached from the statement when it arrives.'}
          </p>
        )}
        <p className="mt-2 text-xs text-slate-500">
          It goes against what they owe, oldest first. If money is left and nothing is open,
          their next invoice is raised and paid from it; anything still left is credit.
        </p>
        {/* A DISABLED BUTTON THAT DOES NOT SAY WHY IS A BROKEN SCREEN.
            `Number('38,000')` is NaN, and Pakistani figures are written with
            those commas, so typing the amount the way it appears on the bank
            statement used to grey out Record with no message at all. The amount
            is now parsed properly AND the reason is printed. */}
        {problem && (
          <p className="mt-3 rounded border border-due-200 bg-due-50 px-3 py-2 text-xs text-due-900">
            {problem}
          </p>
        )}
        {err && <p className="mt-3 text-sm text-danger-700">{err}</p>}
        <div className="mt-4 flex gap-2">
          <button
            onClick={() => { setErr(null); save.mutate() }}
            disabled={save.isPending || problem !== null}
            className="flex-1 rounded bg-brand-600 px-3 py-2 text-sm font-medium text-white hover:bg-brand-700 disabled:opacity-60">
            {save.isPending ? 'Recording…' : 'Record'}
          </button>
          <button onClick={onClose} className="flex-1 rounded border border-slate-300 px-3 py-2 text-sm hover:bg-slate-50">
            Cancel
          </button>
        </div>
      </div>
    </div>
  )
}

/**
 * Entering a school, with the reason the database insists on.
 *
 * Deliberately a dialog with a required field rather than a one-click button. The
 * reason is not paperwork: it is what the SCHOOL reads in its own settings, and
 * "no reason given" appearing there would undo the whole point of showing them.
 *
 * The warnings are stated plainly because both are true and neither is obvious:
 * nothing can be changed from inside, and the school will see this.
 */
function VisitDialog({ school, onClose, onError }: {
  school: PlatformSchool
  onClose: () => void
  onError: (message: string) => void
}) {
  const [reason, setReason] = useState('')
  const [minutes, setMinutes] = useState(60)
  const qc = useQueryClient()

  const enter = useMutation({
    mutationFn: () => operatorEnter(school.school_id, reason.trim(), minutes),
    onSuccess: () => {
      // Nothing cached was read as this school, so nothing cached is right any
      // more. Clear, then land on the school's own dashboard.
      qc.clear()
      window.location.assign('/')
    },
    onError: (e) => onError((e as Error).message),
  })

  return (
    <div className="fixed inset-0 z-50 flex items-start justify-center overflow-y-auto bg-black/40 p-4 sm:items-center">
      <div className="w-full max-w-md rounded-lg bg-white p-5 shadow-lg">
        <h2 className="text-base font-semibold text-slate-800">
          Open {school.school_name}
        </h2>

        <div className="mt-3 rounded border border-danger-200 bg-danger-50 p-3 text-sm text-danger-900">
          <div className="font-medium">Read only, and they will see it.</div>
          <ul className="mt-1 list-disc space-y-0.5 pl-4 text-danger-800">
            <li>You cannot change anything. The database refuses every write.</li>
            <li>
              This visit and your reason appear in the school&rsquo;s own Settings →
              Support Visits.
            </li>
          </ul>
        </div>

        <label className="mt-3 block">
          <span className="text-sm text-slate-600">Why are you opening it?</span>
          <input
            autoFocus value={reason} onChange={(e) => setReason(e.target.value)}
            placeholder="e.g. principal called: the fee will not save"
            className={`${FIELD} mt-1 w-full`}
          />
          <span className="mt-1 block text-xs text-slate-500">
            The school reads this. Write it for them, not for you.
          </span>
        </label>

        <label className="mt-3 block max-w-[10rem]">
          <span className="text-sm text-slate-600">Ends after</span>
          <select value={minutes} onChange={(e) => setMinutes(Number(e.target.value))}
            className={`${FIELD} mt-1 w-full`}>
            <option value={15}>15 minutes</option>
            <option value={60}>1 hour</option>
            <option value={240}>4 hours</option>
          </select>
        </label>

        <div className="mt-4 flex gap-2">
          <button
            onClick={() => enter.mutate()}
            disabled={enter.isPending || reason.trim().length < 4}
            className="flex-1 rounded bg-danger-600 px-3 py-2 text-sm font-medium text-white hover:bg-danger-700 disabled:opacity-60"
          >
            {enter.isPending ? 'Opening…' : 'Open, read only'}
          </button>
          <button onClick={onClose}
            className="flex-1 rounded border border-slate-300 px-3 py-2 text-sm hover:bg-slate-50">
            Cancel
          </button>
        </div>
      </div>
    </div>
  )
}

function TabButton({ now, me, set, label, badge, warn }: {
  now: Tab; me: Tab; set: (t: Tab) => void; label: string
  badge?: number; warn?: boolean
}) {
  const on = now === me
  return (
    <button onClick={() => set(me)}
      className={`flex items-center gap-1.5 rounded px-3 py-1.5 text-sm ${
        on ? 'bg-brand-600 font-medium text-white' : 'text-slate-600 hover:bg-slate-100'}`}>
      {label}
      {badge !== undefined && badge > 0 && (
        <span className={`rounded-full px-1.5 text-xs ${
          on ? 'bg-white/25' : 'bg-due-100 text-due-900'}`}>{badge}</span>
      )}
      {warn && (
        <span title="Something required is missing"
          className={`h-1.5 w-1.5 rounded-full ${on ? 'bg-white' : 'bg-due-500'}`} />
      )}
    </button>
  )
}

import { useMemo, useState } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useAuth } from '@/auth/AuthProvider'
import {
  activateSubscription, actionNeeded, amPlatformAdmin, describeAction,
  listPlans, listPlatformSchools, operatorEnter, platformRevenue,
  platformSchemaState, recordPlatformPayment, refreshAllCounts, schoolActions,
  sortByAction,
  type PlatformSchool, type SchemaState,
} from '@/lib/platform'
import { formatPkr } from '@/lib/licence'
import { fmtDateTime } from '@/lib/format'
import { SchoolDetailPanel } from './SchoolDetail'
import { LedgerDialog } from './SchoolLedger'
import { Renewals } from './Renewals'
import { Claims } from './Claims'
import { BillingSettings } from './BillingSettings'
import { LifecycleDialog } from './Lifecycle'
import { OffboardDialog } from './Offboard'
import { NewSchoolDialog } from './NewSchool'
import { Business } from './Business'
import { Publishing } from './Publishing'
import { LeftBehind } from './LeftBehind'
import { Reviews } from './Reviews'
import { paymentClaims, dueSoon, platformSettings, orphanReport } from '@/lib/platform'

const STATUS_STYLE: Record<PlatformSchool['status'], string> = {
  trialing: 'bg-sky-100 text-sky-800',
  active: 'bg-emerald-100 text-emerald-800',
  grace: 'bg-amber-100 text-amber-800',
  locked: 'bg-red-100 text-red-800',
  cancelled: 'bg-slate-200 text-slate-700',
}

const FIELD = 'rounded border border-slate-300 px-2 py-1.5 text-sm'

type Tab = 'schools' | 'renewals' | 'claims' | 'business' | 'publishing' | 'billing'
  | 'leftbehind' | 'reviews'

// What each screen is FOR, in one line, because the heading alone does not say.
// "Renewals" and "Payments reported" are both about money arriving and a person
// opening the console cold cannot tell which is which.
const TAB_SUBTITLE: Record<Tab, string> = {
  schools: '',
  renewals: 'Licences ending soon, worst first. This is the call list.',
  claims: 'Schools that say they have paid, waiting to be matched to the bank.',
  business: 'What the company is worth: revenue, churn and the plan mix.',
  publishing: 'The desktop installer, and notices every school sees.',
  billing: 'Our own NTN and bank details, printed on every invoice we raise.',
  leftbehind: 'Records whose school no longer exists. Normally none.',
  reviews: 'What schools have said publicly, and anything reported as abuse.',
}

const TAB_TITLE: Record<Tab, string> = {
  schools: 'Schools',
  renewals: 'Renewals',
  claims: 'Payments reported',
  business: 'The business',
  publishing: 'Downloads and notices',
  billing: 'Our billing details',
  leftbehind: 'Records with no school',
  reviews: 'What schools say',
}

function monthStart(): string {
  const d = new Date()
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-01`
}
function today(): string {
  return new Date().toISOString().slice(0, 10)
}

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
  const [ledgerFor, setLedgerFor] = useState<PlatformSchool | null>(null)
  const [historyFor, setHistoryFor] = useState<PlatformSchool | null>(null)
  const [visiting, setVisiting] = useState<PlatformSchool | null>(null)
  const [openSchool, setOpenSchool] = useState<PlatformSchool | null>(null)
  const [tab, setTab] = useState<Tab>('schools')
  const [showArchived, setShowArchived] = useState(false)
  const [creating, setCreating] = useState(false)
  const [lifecycleFor, setLifecycleFor] = useState<PlatformSchool | null>(null)
  const [offboarding, setOffboarding] = useState<PlatformSchool | null>(null)

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
  const schools = useQuery({
    // Keyed on the flag: an archived school appearing in a cache the console
    // filled while the toggle was off is how a departed customer shows up in
    // this month's totals.
    queryKey: ['platformSchools', showArchived],
    queryFn: () => listPlatformSchools(showArchived),
    enabled: isAdmin.data === true,
  })
  const plans = useQuery({ queryKey: ['plans'], queryFn: listPlans, enabled: isAdmin.data === true })
  const revenue = useQuery({
    queryKey: ['platformRevenue', from, to],
    queryFn: () => platformRevenue(from, to),
    enabled: isAdmin.data === true,
  })
  const schema = useQuery({
    queryKey: ['platformSchemaState'], queryFn: platformSchemaState, enabled: isAdmin.data === true,
  })

  const rows = useMemo(() => sortByAction(schools.data ?? []), [schools.data])

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

  const counts = {
    total: rows.length,
    paying: rows.filter((s) => s.status === 'active').length,
    trial: rows.filter((s) => s.status === 'trialing').length,
    attention: rows.filter((s) => actionNeeded(s) !== null).length,
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
                <span className={counts.attention ? 'font-medium text-amber-700' : ''}>
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
                {/* Archived schools are off by default. A console that shows last
                    year's departed customers next to this year's is a console
                    whose totals nobody trusts. */}
                <label className="flex items-center gap-1.5 rounded border border-slate-300 bg-white px-2 py-1.5 text-sm text-slate-600">
                  <input type="checkbox" checked={showArchived}
                    onChange={(e) => setShowArchived(e.target.checked)} />
                  Show archived
                </label>
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
        </nav>

        {tab === 'renewals' && (
          <Renewals
            onOpenSchool={(id) => {
              const s = rows.find((r) => r.school_id === id)
              if (s) { setTab('schools'); setOpenSchool(s) }
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
        {tab === 'business' && <Business />}
        {tab === 'publishing' && <Publishing />}
        {tab === 'billing' && <BillingSettings />}
        {tab === 'leftbehind' && <LeftBehind />}
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
          {revenue.error && <p className="mt-2 text-sm text-red-600">{(revenue.error as Error).message}</p>}
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
                <span className="rounded bg-amber-50 px-2 py-0.5 text-amber-900">
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
                  <span key={s.school_id} className="rounded bg-amber-50 px-2 py-0.5 text-xs text-amber-900">
                    {s.school_name} · {formatPkr(s.outstanding)}
                  </span>
                ))}
              </div>
            </div>
          )}
        </div>

        <SchemaStrip state={schema.data} error={schema.error as Error | null} />

        {msg && <div className="rounded border border-emerald-200 bg-emerald-50 p-2 text-sm text-emerald-800">{msg}</div>}
        {err && <div className="rounded border border-red-200 bg-red-50 p-2 text-sm text-red-700">{err}</div>}

        {schools.isLoading && <div className="text-sm text-slate-500">Loading schools…</div>}
        {schools.error && <div className="text-sm text-red-600">{(schools.error as Error).message}</div>}

        {rows.length === 0 && !schools.isLoading && (
          <div className="rounded-lg border border-slate-200 bg-white p-6 text-center text-sm text-slate-500">
            No schools yet. They appear here as soon as someone signs up.
          </div>
        )}

        <div className="space-y-2">
          {rows.map((s) => {
            const todo = actionNeeded(s)
            return (
              <div key={s.school_id} className="rounded-lg border border-slate-200 bg-white p-3">
                <div className="flex flex-wrap items-start justify-between gap-3">
                  <div className="min-w-0">
                    <div className="flex items-center gap-2">
                      <button onClick={() => setOpenSchool(s)}
                        className="font-medium text-slate-800 hover:text-brand-700 hover:underline">
                        {s.school_name}
                      </button>
                      <span className={`rounded px-1.5 py-0.5 text-xs font-medium ${STATUS_STYLE[s.status]}`}>
                        {s.status}
                      </span>
                      {s.outstanding > 0 && (
                        <span className="rounded bg-amber-100 px-1.5 py-0.5 text-xs font-medium text-amber-800">
                          owes {formatPkr(s.outstanding)}
                        </span>
                      )}
                      {/* `status` reads 'locked' for a school we suspended AND
                          for one whose licence simply ran out. Without this badge
                          the two are indistinguishable, and the operator cannot
                          tell "they did not pay" from "we switched them off". */}
                      {s.suspended && (
                        <span className="rounded bg-red-100 px-1.5 py-0.5 text-xs font-medium text-red-800"
                          title={s.suspend_reason ?? undefined}>
                          we suspended them
                        </span>
                      )}
                      {s.archived && (
                        <span className="rounded bg-slate-200 px-1.5 py-0.5 text-xs text-slate-600">
                          archived
                        </span>
                      )}
                    </div>
                    <div className="mt-0.5 text-xs text-slate-500">
                      {[s.city, s.contact_name, s.contact_phone].filter(Boolean).join(' · ') || 'No contact details'}
                    </div>
                    <div className="mt-1 text-sm text-slate-600">
                      {s.student_count.toLocaleString()} students
                      {s.student_limit !== null && <span className="text-slate-400"> / {s.student_limit.toLocaleString()}</span>}
                      {s.limit_state === 'over' && (
                        <span className="ml-2 rounded bg-amber-100 px-1.5 py-0.5 text-xs font-medium text-amber-800">
                          over limit
                        </span>
                      )}
                      {s.limit_state === 'within_margin' && (
                        <span className="ml-2 rounded bg-slate-100 px-1.5 py-0.5 text-xs text-slate-600">
                          in margin
                        </span>
                      )}
                      <span className="ml-2 text-slate-400">
                        {s.plan_code}
                        {s.expires_on && ` · ${s.days_left !== null && s.days_left >= 0
                          ? `${s.days_left}d left`
                          : `expired ${Math.abs(s.days_left ?? 0)}d ago`}`}
                      </span>
                      {s.last_paid_on && <span className="ml-2 text-slate-400">last paid {s.last_paid_on}</span>}
                    </div>
                    {todo && <div className="mt-1 text-sm font-medium text-amber-700">{todo}</div>}
                    {/* GROUPED BY WHAT THEY COST YOU IF YOU PRESS THEM BY
                        MISTAKE, because they used to be five identical blue
                        links in a row: Statement, which opens a read-only panel,
                        sat beside View as school, which enters a customer's live
                        records and writes a line into their own audit trail that
                        they can read. Nothing said one was heavier than the
                        other. Now: reading on the left, money in the middle, the
                        two that change or expose something set apart on the
                        right and coloured for it. */}
                    <div className="mt-2 flex flex-wrap items-center gap-x-2 gap-y-1 text-xs">
                      <button onClick={() => setLedgerFor(s)}
                        className="rounded border border-slate-200 bg-white px-2 py-1 text-slate-700 hover:bg-slate-50">
                        Statement
                      </button>
                      <button onClick={() => setHistoryFor(s)}
                        className="rounded border border-slate-200 bg-white px-2 py-1 text-slate-700 hover:bg-slate-50">
                        History
                      </button>
                      <button onClick={() => { setErr(null); setMsg(null); setPaying(s) }}
                        className="rounded border border-brand-200 bg-brand-50 px-2 py-1 font-medium text-brand-800 hover:bg-brand-100">
                        Record payment
                      </button>

                      <span aria-hidden className="mx-1 h-4 w-px bg-slate-200" />

                      <button onClick={() => { setErr(null); setMsg(null); setLifecycleFor(s) }}
                        className="rounded border border-slate-200 bg-white px-2 py-1 text-slate-600 hover:bg-slate-50">
                        Manage
                      </button>
                      {/* The support tool. Read-only, refused at the database,
                          logged, and shown to the school in its own settings, so
                          this is not a back door: it is the front one with a bell
                          on it. Coloured as the heaviest thing on the row because
                          it is the only one the customer finds out about. */}
                      <button onClick={() => { setErr(null); setMsg(null); setVisiting(s) }}
                        className="rounded border border-red-200 bg-red-50 px-2 py-1 font-medium text-red-800 hover:bg-red-100">
                        View as school
                      </button>
                      {/* Only offered on an archived school, because that is the
                          only school the database will export or delete, and a
                          button that always refuses teaches people to ignore
                          buttons. */}
                      {s.archived && (
                        <button onClick={() => { setErr(null); setMsg(null); setOffboarding(s) }}
                          className="rounded border border-slate-200 bg-white px-2 py-1 text-slate-600 hover:bg-slate-50">
                          Offboard
                        </button>
                      )}
                    </div>
                  </div>

                  <SchoolActions
                    school={s}
                    plans={plans.data ?? []}
                    busy={act.isPending}
                    onActivate={(plan, months, amount, note, allowOverLimit) =>
                      run(
                        `${s.school_name} activated on ${plan} for ${months} month(s).`,
                        () => activateSubscription(s.school_id, plan, months,
                          { amount, note, allowOverLimit }),
                      )}
                  />
                </div>
              </div>
            )
          })}
        </div>

        </>}
      </div>

      {paying && (
        <PaymentDialog
          school={paying}
          busy={act.isPending}
          onClose={() => setPaying(null)}
          onSave={(v) => {
            run(`${formatPkr(v.amount)} recorded for ${paying.school_name}.`,
              () => recordPlatformPayment({ schoolId: paying.school_id, ...v }))
            setPaying(null)
          }}
        />
      )}

      {ledgerFor && <LedgerDialog school={ledgerFor} onClose={() => setLedgerFor(null)} />}

      {creating && (
        <NewSchoolDialog
          onClose={() => setCreating(false)}
          onCreated={(id) => {
            setCreating(false)
            const s = rows.find((r) => r.school_id === id)
            if (s) setOpenSchool(s)
            else setMsg('School added. It will appear in the list on the next refresh.')
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

      {historyFor && <HistoryDialog school={historyFor} onClose={() => setHistoryFor(null)} />}

      {openSchool && (
        <SchoolDetailPanel
          schoolId={openSchool.school_id}
          onClose={() => setOpenSchool(null)}
          onVisit={() => { const s = openSchool; setOpenSchool(null); setErr(null); setMsg(null); setVisiting(s) }}
        />
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
      <div className="rounded border border-amber-300 bg-amber-50 px-3 py-2 text-sm text-amber-900">
        <span className="font-medium">This database has no migration ledger.</span>{' '}
        Paste <code className="rounded bg-amber-100 px-1">supabase/bundles/7_ledger_and_limits.sql</code>{' '}
        into the Supabase SQL editor. Until then nothing records which migrations production has.
      </div>
    )
  }
  if (!state) return null

  if (state.applied_count === 0) {
    return (
      <div className="rounded border border-red-300 bg-red-50 px-3 py-2 text-sm text-red-900">
        <span className="font-medium">The migration ledger is empty.</span>{' '}
        0069 refused to record this database because it could not prove every shipped bundle is
        present. Run <code className="rounded bg-red-100 px-1">supabase/repair/detect.sql</code> and
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
    <div className="rounded border border-red-300 bg-red-50 px-3 py-2 text-sm text-red-900">
      <span className="font-medium">Schema</span>{' '}
      {state.applied_count} migration{state.applied_count === 1 ? '' : 's'} applied
      {state.latest && <span className="text-red-700"> · latest {state.latest.replace(/\.sql$/, '')}</span>}
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
    <div className={`rounded border p-2 ${tone === 'warn' ? 'border-amber-200 bg-amber-50' : 'border-slate-200'}`}>
      <div className="text-xs text-slate-500">{label}</div>
      <div className={`text-lg font-semibold ${tone === 'warn' ? 'text-amber-900' : 'text-slate-800'}`}>{value}</div>
      {hint && <div className="text-[11px] text-slate-400">{hint}</div>}
    </div>
  )
}

/**
 * The one commercial control on a school's row.
 *
 * IT USED TO BE SEVEN. A plan dropdown, a months dropdown, a price, an Activate
 * button, a +14d trial button, a change-price toggle and, behind that, two more
 * inputs. Alongside five text links and up to six badges, that put ELEVEN
 * interactive controls on every row. At fifty schools it is 550 controls on one
 * page, and the operator's own description of it was "I get lost all the time".
 *
 * The problem was not density, it was that nothing had a rank. Activate raises
 * an invoice and cannot be undone; Statement opens a read-only panel. They were
 * the same size, one click apart, side by side.
 *
 * So the row now carries ONE button, and every choice it needs -- plan, length,
 * price, reason -- is made in the dialog it opens, where there is room to show
 * what is about to happen and the numbers can be read before they are agreed
 * rather than after.
 */
function SchoolActions({
  school, plans, busy, onActivate,
}: {
  school: PlatformSchool
  plans: { code: string; name: string; price_yearly: number; price_monthly: number; student_limit: number | null }[]
  busy: boolean
  onActivate: (plan: string, months: number, amount: number | null, note: string | null, allowOverLimit: boolean) => void
}) {
  const [confirming, setConfirming] = useState(false)
  const renewing = school.status === 'active'

  return (
    <div className="flex w-full shrink-0 flex-col items-start gap-2 sm:w-auto sm:items-end">
      <button
        onClick={() => setConfirming(true)}
        disabled={busy}
        className="rounded bg-brand-600 px-3 py-1.5 text-sm font-medium text-white hover:bg-brand-700 disabled:opacity-60"
      >
        {renewing ? 'Renew' : 'Activate'}
      </button>

      {/* THERE IS NO +14d BUTTON ANY MORE. fn_extend_trial capped ONE call at 30
          days and capped nothing else, so a fortnight was one click and a
          hundred and forty days was ten, with no confirmation and no reason
          recorded. 0027's own comment above that function warns that an
          unbounded extend button becomes a free tier by accident, and the cap it
          describes is per press. A school that needs longer is put on a plan,
          which is an invoice and a conversation. 0106 makes the database refuse
          the call outright. */}

      {confirming && (
        <ActivationDialog
          school={school} plans={plans}
          onCancel={() => setConfirming(false)}
          onGo={(plan, months, amount, note, over) => {
            setConfirming(false)
            onActivate(plan, months, amount, note, over)
          }}
        />
      )}
    </div>
  )
}

/**
 * Where a licence is actually sold, and the last thing between a mis-click and
 * an invoice.
 *
 * WHY THE CHOICES MOVED HERE. Plan, length and price used to be three controls
 * on the school's row, competing with five text links and up to six badges.
 * Choosing was done in a strip narrower than a phone, and pressing Activate
 * committed immediately: an invoice raised against a real customer, no undo, one
 * click, next to a link that opens a read-only statement.
 *
 * WHAT IT SHOWS IS THE POINT. Not "are you sure", which nobody reads, but the
 * four facts being decided, in the words the invoice will use: who, what plan,
 * what period, and how much. The discount and the over-limit breach are called
 * out because those are the two that get argued about a month later.
 */
function ActivationDialog({ school, plans, onCancel, onGo }: {
  school: PlatformSchool
  plans: { code: string; name: string; price_yearly: number; price_monthly: number; student_limit: number | null }[]
  onCancel: () => void
  onGo: (plan: string, months: number, amount: number | null, note: string | null, over: boolean) => void
}) {
  // Default to the plan their real headcount says they should be on, so the
  // common case is one press and the size question is already answered.
  const [plan, setPlan] = useState(school.suggested_plan || school.plan_code)
  const [months, setMonths] = useState(12)
  const [amount, setAmount] = useState('')
  const [note, setNote] = useState('')

  const chosen = plans.find((p) => p.code === plan)
  const list = chosen ? (months >= 12 ? chosen.price_yearly * (months / 12) : chosen.price_monthly * months) : null
  const typed = amount.trim() === '' ? null : Number(amount)
  const charge = typed ?? list
  const discount = list !== null && typed !== null ? list - typed : 0
  // The database refuses a non-list amount with no reason. Refusing here too
  // means the operator is told before pressing, not after.
  const needsNote = typed !== null && list !== null && typed !== list && !note.trim()
  // The database also refuses a plan the school has outgrown. Showing it up
  // front turns a red error into a decision.
  const overLimit = chosen?.student_limit != null
    && school.student_count > Math.ceil(chosen.student_limit * 1.1)
  const renewing = school.status === 'active'
  // Renewing early extends from the existing end date rather than today, which
  // is fn_activate_subscription's own rule. Saying so stops the operator
  // wondering whether a school paying a week early loses that week.
  const from = renewing && school.expires_on && school.expires_on >= today()
    ? school.expires_on : null

  return (
    <div className="fixed inset-0 z-50 flex items-start justify-center overflow-y-auto bg-black/40 p-4 sm:items-center">
      <div className="w-full max-w-md rounded-lg bg-white p-5 text-left shadow-lg">
        <h2 className="text-base font-semibold text-slate-800">
          {renewing ? 'Renew' : 'Activate'} {school.school_name}
        </h2>
        <p className="mt-1 text-sm text-slate-600">
          {school.student_count.toLocaleString()} students
          {school.outstanding > 0 && <> · owes {formatPkr(school.outstanding)}</>}
        </p>

        <div className="mt-3 grid gap-3 sm:grid-cols-2">
          <label className="block">
            <span className="text-sm text-slate-600">Plan</span>
            <select value={plan} onChange={(e) => setPlan(e.target.value)}
              className={`${FIELD} mt-1 w-full`}>
              {plans.map((p) => <option key={p.code} value={p.code}>{p.code}</option>)}
            </select>
          </label>
          <label className="block">
            <span className="text-sm text-slate-600">For how long</span>
            <select value={months} onChange={(e) => setMonths(Number(e.target.value))}
              className={`${FIELD} mt-1 w-full`}>
              <option value={1}>1 month</option>
              <option value={3}>3 months</option>
              <option value={6}>6 months</option>
              <option value={12}>1 year</option>
            </select>
          </label>
          <label className="block">
            <span className="text-sm text-slate-600">
              They pay <span className="text-slate-400">(blank = list price)</span>
            </span>
            <input value={amount} onChange={(e) => setAmount(e.target.value)} inputMode="decimal"
              placeholder={list !== null ? String(list) : 'amount'}
              className={`${FIELD} mt-1 w-full`} />
          </label>
          <label className="block">
            <span className="text-sm text-slate-600">Reason for the price</span>
            <input value={note} onChange={(e) => setNote(e.target.value)}
              placeholder="goes on the invoice" className={`${FIELD} mt-1 w-full`} />
          </label>
        </div>

        <dl className="mt-3 grid grid-cols-[auto,1fr] gap-x-4 gap-y-1 rounded border border-slate-200 bg-slate-50 p-3 text-sm">
          <dt className="text-slate-500">Period</dt>
          <dd className="text-slate-800">
            {months === 12 ? '1 year' : `${months} month${months === 1 ? '' : 's'}`}
            {from && <span className="text-slate-500"> · starts {from}, after the current one</span>}
          </dd>
          <dt className="text-slate-500">Invoice</dt>
          <dd className="font-medium text-slate-800">
            {charge === null ? 'list price' : formatPkr(charge)}
            {discount > 0 && (
              <span className="ml-1 text-amber-700">
                ({formatPkr(discount)} off {formatPkr(list ?? 0)})
              </span>
            )}
          </dd>
        </dl>

        {needsNote && (
          <p className="mt-2 text-sm text-amber-700">
            A price that is not the list price needs a reason, including zero.
          </p>
        )}

        {overLimit && (
          <p className="mt-3 rounded border border-amber-300 bg-amber-50 px-3 py-2 text-sm text-amber-900">
            {school.student_count.toLocaleString()} students against {plan}&rsquo;s limit
            of {chosen?.student_limit?.toLocaleString()}.
            {school.suggested_plan !== plan
              ? <> Pick <span className="font-semibold">{school.suggested_plan}</span>, or go ahead on {plan}: the breach is recorded on the invoice.</>
              : <> Going ahead records the breach on the invoice.</>}
          </p>
        )}

        <p className="mt-3 text-xs text-slate-500">
          This raises an invoice and starts the paid period. It cannot be undone
          from here.
        </p>

        <div className="mt-3 flex gap-2">
          <button
            onClick={() => onGo(plan, months, typed, note.trim() || null, overLimit)}
            disabled={needsNote}
            className="flex-1 rounded bg-brand-600 px-3 py-2 text-sm font-medium text-white hover:bg-brand-700 disabled:opacity-60">
            {renewing ? 'Renew and invoice' : 'Activate and invoice'}
          </button>
          <button onClick={onCancel}
            className="flex-1 rounded border border-slate-300 px-3 py-2 text-sm hover:bg-slate-50">
            Cancel
          </button>
        </div>
      </div>
    </div>
  )
}

function PaymentDialog({ school, busy, onClose, onSave }: {
  school: PlatformSchool
  busy: boolean
  onClose: () => void
  onSave: (v: {
    amount: number; paidOn: string; method: string
    reference: string | null; note: string | null
    taxWithheld: number; taxCertificate: string | null
  }) => void
}) {
  // Pre-filled with what they owe, which is the amount in almost every case.
  const [amount, setAmount] = useState(school.outstanding > 0 ? String(school.outstanding) : '')
  const [paidOn, setPaidOn] = useState(today())
  const [method, setMethod] = useState('bank')
  const [reference, setReference] = useState('')
  const [note, setNote] = useState('')
  const [wht, setWht] = useState('')
  const [cert, setCert] = useState('')
  const n = Number(amount)
  const t = Number(wht || 0)
  const valid = amount.trim() !== '' && Number.isFinite(n) && n > 0
    && Number.isFinite(t) && t >= 0
  // What the invoice is actually settled by. The gap between this and the
  // outstanding figure is what the operator is deciding about.
  const settles = n + t

  return (
    <div className="fixed inset-0 z-50 flex items-start justify-center overflow-y-auto bg-black/40 p-4 sm:items-center">
      <div className="w-full max-w-md rounded-lg bg-white p-5 shadow-lg">
        <h2 className="text-base font-semibold text-slate-800">Record a payment</h2>
        <p className="mt-1 text-sm text-slate-600">
          {school.school_name}
          {school.outstanding > 0
            ? <> · owes {formatPkr(school.outstanding)}</>
            : <> · nothing outstanding. This will show as credit</>}
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
            <input value={cert} onChange={(e) => setCert(e.target.value)}
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
        <div className="mt-4 flex gap-2">
          <button
            onClick={() => onSave({
              amount: n, paidOn, method,
              reference: reference.trim() || null, note: note.trim() || null,
              taxWithheld: t, taxCertificate: cert.trim() || null,
            })}
            disabled={busy || !valid}
            className="flex-1 rounded bg-brand-600 px-3 py-2 text-sm font-medium text-white hover:bg-brand-700 disabled:opacity-60">
            Record
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
 * Everything we have ever done to this school.
 *
 * The billing rows say what was charged. This says who chose it, that a trial was
 * extended three times, that a year was given away for a reason somebody typed at
 * the time, and every support visit. Before 0073 none of it was recorded, which
 * with one customer is recoverable from memory and with fifty is not.
 */
function HistoryDialog({ school, onClose }: { school: PlatformSchool; onClose: () => void }) {
  const q = useQuery({
    queryKey: ['schoolActions', school.school_id],
    queryFn: () => schoolActions(school.school_id),
  })

  const TONE: Record<string, string> = {
    school_entered: 'bg-red-50 text-red-800',
    school_left: 'bg-slate-100 text-slate-600',
    payment_recorded: 'bg-emerald-50 text-emerald-800',
    invoice_raised: 'bg-sky-50 text-sky-800',
    licence_changed: 'bg-amber-50 text-amber-900',
    school_created: 'bg-slate-100 text-slate-700',
  }

  return (
    <div className="fixed inset-0 z-50 flex items-start justify-center overflow-y-auto bg-black/40 p-4">
      <div className="w-full max-w-2xl rounded-lg bg-white p-5 shadow-lg">
        <div className="flex items-start justify-between gap-3">
          <div>
            <h2 className="text-base font-semibold text-slate-800">{school.school_name}</h2>
            <p className="text-sm text-slate-600">What we have done to this school</p>
          </div>
          <button onClick={onClose} className="text-sm text-slate-500 hover:underline">Close</button>
        </div>

        {q.isLoading && <p className="mt-3 text-sm text-slate-500">Loading…</p>}
        {q.error && <p className="mt-3 text-sm text-red-600">{(q.error as Error).message}</p>}
        {q.data && q.data.length === 0 && (
          <p className="mt-3 text-sm text-slate-500">
            Nothing recorded yet. Activating them, taking a payment or opening their
            account all appear here.
          </p>
        )}

        {q.data && q.data.length > 0 && (
          <ul className="mt-3 divide-y divide-slate-100">
            {q.data.map((a, i) => (
              <li key={i} className="flex items-start gap-3 py-2">
                <span className={`mt-0.5 shrink-0 rounded px-1.5 py-0.5 text-[11px] font-medium ${
                  TONE[a.action] ?? 'bg-slate-100 text-slate-600'}`}>
                  {a.action.replace(/_/g, ' ')}
                </span>
                <div className="min-w-0 flex-1">
                  <div className="text-sm text-slate-800">{describeAction(a)}</div>
                  <div className="text-xs text-slate-400">
                    {fmtDateTime(a.at)}
                    {a.actor_email && <> · {a.actor_email}</>}
                    {a.detail?.backfilled === true && <> · reconstructed from the billing rows</>}
                  </div>
                </div>
              </li>
            ))}
          </ul>
        )}
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

        <div className="mt-3 rounded border border-red-200 bg-red-50 p-3 text-sm text-red-900">
          <div className="font-medium">Read only, and they will see it.</div>
          <ul className="mt-1 list-disc space-y-0.5 pl-4 text-red-800">
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
            className="flex-1 rounded bg-red-600 px-3 py-2 text-sm font-medium text-white hover:bg-red-700 disabled:opacity-60"
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
          on ? 'bg-white/25' : 'bg-amber-100 text-amber-900'}`}>{badge}</span>
      )}
      {warn && (
        <span title="Something required is missing"
          className={`h-1.5 w-1.5 rounded-full ${on ? 'bg-white' : 'bg-amber-500'}`} />
      )}
    </button>
  )
}

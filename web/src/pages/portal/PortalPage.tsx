/**
 * The parent portal.
 *
 * Built phone-first on purpose. Almost every parent will open this on a
 * mid-range Android over a patchy connection, standing somewhere: not at a
 * desk. So: one column, large tap targets, nothing that scrolls sideways, and
 * the three things a parent opens it for (what do I owe, was my child in
 * school, how did the test go) on the first screen, before any tab is pressed.
 * On a laptop the child and the tabs move into a sidebar and the tab fills the
 * rest, instead of a phone-width column in the middle of a white screen.
 *
 * Every read goes through fn_portal_* which resolves the caller's own family
 * server-side. The child switcher below is a convenience, not a permission:
 * passing another family's id gets refused by the database, not by this file.
 *
 * FRESHNESS. The app's queries do not refetch when a window regains focus, which
 * suits an office screen and not this one: a parent keeps the portal open on
 * their phone for days, and a test locked this afternoon has to be there when
 * they look again. So the portal's reads refetch on focus, and a Refresh button
 * is on the page, because a portal saved to the home screen has no browser pull
 * to refresh.
 */
import { useState, type ReactNode } from 'react'
import { Link, useSearchParams } from 'react-router-dom'
import { useQuery, useQueryClient } from '@tanstack/react-query'
import { AnnouncementBanner } from '@/components/AnnouncementBanner'
import { PortalStatement } from '@/components/PortalStatement'
import { useAuth } from '@/auth/AuthProvider'
import {
  getPortalMe, getPortalChildFees, getPortalChildLedger, getPortalChildAttendance,
  getPortalChildResults, getPortalChildTests, type PortalChild, type PortalFees as Fees,
  type PortalTests, type PortalAttendance as Att,
} from '@/lib/db'
import { Button, EmptyState, money } from '@/components/ui'
import { Avatar } from '@/components/Avatar'
import {
  IconStudents, IconWallet, IconAttendance, IconExams, IconAlert, IconLogout, IconBirthday,
  IconChevron, IconBook,
} from '@/components/icons'
import { guideUrl } from '@/lib/config'
import { today as pkToday } from '@/lib/dates'
import { grLabel } from '@/lib/format'
import { PortalFees } from './PortalFees'
import { PortalAttendance, attendanceKey, monthRange } from './PortalAttendance'
import { PortalResults } from './PortalResults'
import { PCard, Problem, Skeleton, firstName, isBirthday, markText, pct, shortDate } from './portalKit'

type Tab = 'fees' | 'attendance' | 'results'

const TABS: { key: Tab; label: string; icon: ReactNode }[] = [
  { key: 'fees', label: 'Fees', icon: <IconWallet /> },
  { key: 'attendance', label: 'Attendance', icon: <IconAttendance /> },
  { key: 'results', label: 'Results', icon: <IconExams /> },
]

const FRESH = { refetchOnWindowFocus: true } as const

export function PortalPage() {
  const { signOut } = useAuth()
  const qc = useQueryClient()
  const [childId, setChildId] = useState<string | null>(null)
  /* The tab lives in the URL. A parent who reloads on a patchy connection was
   * thrown back to Fees, and a school can send "open this link to see the
   * result" pointing at /portal?tab=results. Validated against the three known
   * values rather than cast, so ?tab=anything cannot render an empty page. */
  const [params, setParams] = useSearchParams()
  const urlTab = params.get('tab')
  const tab: Tab = urlTab === 'attendance' || urlTab === 'results' ? urlTab : 'fees'
  const setTab = (t: Tab) => {
    const next = new URLSearchParams(params)
    if (t === 'fees') next.delete('tab')
    else next.set('tab', t)
    setParams(next, { replace: true })
  }
  /* The statement opens a real printable document. window.print() straight
     from this page printed a blank sheet: the print rule reveals only named
     ids, and the page had none. */
  const [statement, setStatement] = useState(false)

  const today = pkToday()
  const thisMonth = today.slice(0, 7)
  const me = useQuery({ queryKey: ['portalMe'], queryFn: getPortalMe, ...FRESH })

  const children = me.data?.children ?? []
  const active = childId ?? children[0]?.student_id ?? null
  const activeChild = children.find((c) => c.student_id === active)

  // The three reads the first screen summarises are fetched whatever the tab,
  // so the parent sees the answer before pressing anything.
  const fees = useQuery({
    queryKey: ['portalFees', active], queryFn: () => getPortalChildFees(active as string),
    enabled: !!active, ...FRESH,
  })
  const range = monthRange(thisMonth, today)
  const month = useQuery({
    queryKey: attendanceKey(active, thisMonth),
    queryFn: () => getPortalChildAttendance(active as string, range.from, range.to),
    enabled: !!active, ...FRESH,
  })
  const tests = useQuery({
    queryKey: ['portalTests', active], queryFn: () => getPortalChildTests(active as string),
    enabled: !!active, ...FRESH,
  })
  // The long reads only when their tab is open.
  const ledger = useQuery({
    queryKey: ['portalLedger', active], queryFn: () => getPortalChildLedger(active as string),
    enabled: !!active && tab === 'fees', ...FRESH,
  })
  const results = useQuery({
    queryKey: ['portalResults', active], queryFn: () => getPortalChildResults(active as string),
    enabled: !!active && tab === 'results', ...FRESH,
  })

  const refreshing = me.isFetching || fees.isFetching || month.isFetching || tests.isFetching
    || ledger.isFetching || results.isFetching
  const refresh = () => {
    for (const k of ['portalMe', 'portalFees', 'portalAttMonth', 'portalTests', 'portalLedger', 'portalResults']) {
      void qc.invalidateQueries({ queryKey: [k] })
    }
  }

  if (me.isLoading) {
    return (
      <div className="flex min-h-full items-center justify-center bg-slate-50">
        <div className="flex flex-col items-center gap-3 text-sm text-slate-500">
          <span className="h-10 w-10 animate-spin rounded-full border-4 border-brand-100 border-t-brand-600" aria-hidden="true" />
          Loading your portal…
        </div>
      </div>
    )
  }

  if (me.isError) {
    return (
      <div className="flex min-h-full items-center justify-center bg-slate-50 p-6">
        <EmptyState
          icon={<IconAlert />}
          title="Could not load your account"
          message={(me.error as Error).message}
          action={
            <div className="flex gap-2">
              <Button variant="soft" onClick={() => void me.refetch()}>Try again</Button>
              <Button variant="soft" tone="neutral" onClick={() => void signOut()}>Sign out</Button>
            </div>
          }
        />
      </div>
    )
  }

  const first = firstName(activeChild?.full_name)

  return (
    /* min-h-full rather than min-h-screen: 100vh on a phone is the height with
       the address bar hidden, so a short page bounced with nothing to scroll. */
    <div className="min-h-full bg-slate-50">
      {/* ---------------------------------------------------------- header -- */}
      <header className="relative overflow-hidden bg-gradient-to-br from-brand-700 via-brand-600 to-violet-600 pb-20 pt-5 text-white lg:pb-24">
        <span aria-hidden="true" className="pointer-events-none absolute -right-16 -top-20 h-56 w-56 rounded-full bg-white/10" />
        <span aria-hidden="true" className="pointer-events-none absolute -left-10 bottom-0 h-32 w-32 rounded-full bg-violet-300/20" />
        <span aria-hidden="true" className="pointer-events-none absolute right-12 bottom-10 h-2 w-2 rounded-full bg-sky-200/80" />
        {/* The same box as <main> below, so the name lines up with the cards. */}
        <div className="relative mx-auto max-w-6xl px-4">
          {/* The school and Sign out share the top line; the greeting and the
              parent's name get the whole width under it. Side by side, a 360px
              phone cut "Muhammad Aslam" to "Muhammad A...". Sign out ONLY up
              here: the password link lives at the foot of the page. */}
          <div className="flex items-center justify-between gap-3">
            <p className="min-w-0 truncate text-[11px] font-semibold uppercase tracking-wider text-white/75">
              {me.data?.school_name ?? 'School'}
            </p>
            <button
              onClick={() => void signOut()}
              className="flex shrink-0 items-center gap-1.5 rounded-full bg-white/15 px-3.5 py-2 text-xs font-semibold ring-1 ring-white/25 transition hover:bg-white/25"
            >
              <IconLogout />
              Sign out
            </button>
          </div>
          <p className="mt-2 text-sm text-white/80">Assalam-o-Alaikum,</p>
          <h1 className="break-words text-xl font-bold leading-tight sm:text-2xl">{me.data?.full_name}</h1>

          {/* One chip per child, only when there is more than one. Wraps rather
              than scrolls, so no child is ever hidden off the edge. */}
          {children.length > 1 && (
            <div className="mt-4 flex flex-wrap gap-2" role="group" aria-label="Your children">
              {children.map((c) => {
                const on = c.student_id === active
                return (
                  <button key={c.student_id} type="button" aria-pressed={on}
                    onClick={() => setChildId(c.student_id)}
                    className={`flex items-center gap-2 rounded-full py-1 pl-1 pr-3.5 text-sm font-semibold transition ${
                      on ? 'bg-white text-brand-700 shadow-md' : 'bg-white/15 text-white ring-1 ring-white/25 hover:bg-white/25'}`}>
                    <Avatar name={c.full_name} size="sm" />
                    {firstName(c.full_name)}
                  </button>
                )
              })}
            </div>
          )}
        </div>
      </header>

      <main className="relative mx-auto -mt-14 max-w-6xl px-4 pb-10 lg:-mt-16">
        {/* Vendor notices reach parents too, when one is aimed at them. */}
        <AnnouncementBanner />
        {children.length === 0 ? (
          <PCard>
            <EmptyState
              icon={<IconStudents />}
              title="No children linked yet"
              message="Your account is not linked to a student. Please ask the school office to connect it."
            />
          </PCard>
        ) : (
          <div className="lg:grid lg:grid-cols-[20rem_minmax(0,1fr)] lg:items-start lg:gap-6">
            {/* ------------------------------------------------- the child -- */}
            <aside className="space-y-4 lg:sticky lg:top-4">
              {activeChild && (
                <ChildCard child={activeChild} today={today}
                  fees={fees.data} feesLoading={fees.isLoading}
                  month={month.data} monthLoading={month.isLoading}
                  tests={tests.data} testsLoading={tests.isLoading}
                  onOpen={setTab} />
              )}

              <nav aria-label="Portal sections"
                className="grid grid-cols-3 gap-2 lg:grid-cols-1 lg:rounded-3xl lg:bg-white lg:p-2 lg:shadow-card lg:ring-1 lg:ring-slate-200/70">
                {TABS.map((t) => {
                  const on = tab === t.key
                  return (
                    <button key={t.key} type="button" onClick={() => setTab(t.key)} aria-current={on ? 'page' : undefined}
                      style={{ touchAction: 'manipulation' }}
                      className={`flex flex-col items-center gap-1 rounded-2xl px-2 py-3 text-xs font-semibold transition active:scale-[0.98] lg:flex-row lg:gap-3 lg:px-3 lg:py-2.5 lg:text-sm ${
                        on ? 'bg-gradient-to-br from-brand-600 to-violet-600 text-white shadow-md'
                          : 'bg-white text-slate-700 shadow-card ring-1 ring-slate-200/70 hover:bg-brand-50 hover:text-brand-800 lg:shadow-none lg:ring-0'}`}>
                      <span className={`flex h-8 w-8 items-center justify-center rounded-xl text-base ${on ? 'bg-white/20' : 'bg-brand-50 text-brand-600'}`}>
                        {t.icon}
                      </span>
                      <span className="lg:flex-1 lg:text-left">{t.label}</span>
                      <span className={`hidden lg:inline ${on ? 'text-white' : 'text-slate-300'}`}><IconChevron /></span>
                    </button>
                  )
                })}
              </nav>

              <p className="flex items-center justify-center gap-2 text-xs text-slate-500 lg:justify-start lg:px-2">
                <span>{refreshing ? 'Updating…' : `Updated ${new Date(Math.max(me.dataUpdatedAt, fees.dataUpdatedAt, tests.dataUpdatedAt)).toLocaleTimeString('en-PK', { hour: 'numeric', minute: '2-digit' })}`}</span>
                <button type="button" onClick={refresh} disabled={refreshing}
                  className="rounded-full bg-white px-3 py-1 font-semibold text-brand-700 ring-1 ring-brand-200 hover:bg-brand-50 disabled:opacity-60">
                  Refresh
                </button>
              </p>
            </aside>

            {/* --------------------------------------------------- the tab -- */}
            <div className="mt-4 min-w-0 lg:mt-0">
              {tab === 'fees' && (
                fees.isLoading ? <Skeleton lines={4} />
                  : fees.isError ? <Problem error={fees.error} onRetry={() => void fees.refetch()} />
                    : fees.data ? (
                      <PortalFees fees={fees.data} ledger={ledger.data} today={today} childFirst={first}
                        onPrint={() => setStatement(true)} />
                    ) : null
              )}

              {tab === 'attendance' && active && (
                <PortalAttendance key={active} childId={active} today={today} />
              )}

              {tab === 'results' && (
                tests.isLoading || results.isLoading ? <Skeleton lines={4} />
                  : tests.isError ? <Problem error={tests.error} onRetry={() => void tests.refetch()} />
                    : results.isError ? <Problem error={results.error} onRetry={() => void results.refetch()} />
                      : <PortalResults tests={tests.data} results={results.data} today={today} childFirst={first} />
              )}
            </div>
          </div>
        )}
      </main>

      {/* In words rather than behind an icon: the audience for this page
          includes parents who read slowly, and a key symbol tells them nothing. */}
      <div className="mx-auto flex max-w-6xl flex-wrap items-center justify-center gap-2 px-4 pb-10">
        <Link to="/password"
          className="rounded-full bg-white px-4 py-2 text-xs font-semibold text-brand-700 shadow-sm ring-1 ring-brand-200 hover:bg-brand-50">
          Change your password
        </Link>
        {/* New tab, so a parent reading it does not lose what they had open. */}
        <a href={guideUrl} target="_blank" rel="noopener"
          className="inline-flex items-center gap-1.5 rounded-full bg-white px-4 py-2 text-xs font-semibold text-brand-700 shadow-sm ring-1 ring-brand-200 hover:bg-brand-50">
          <IconBook /> How to use the parent portal
        </a>
      </div>

      {/* Outside <main> so the print rule's positioning starts at the top of the
          sheet. items-start with overflow-y-auto, not items-center: a centred
          dialog taller than a 360x640 phone puts its own buttons off both edges
          with nothing to scroll, and a statement is long by nature. */}
      {statement && fees.data && (
        <div
          className="fixed inset-0 z-50 flex items-start justify-center overflow-y-auto bg-black/40 p-3 sm:items-center print:static print:overflow-visible print:bg-white print:p-0"
          role="dialog" aria-modal="true" aria-label="Fee statement"
        >
          <div className="w-full max-w-2xl rounded-2xl bg-white shadow-lg print:max-w-none print:rounded-none print:shadow-none">
            <PortalStatement
              schoolName={me.data?.school_name ?? null}
              parentName={me.data?.full_name ?? null}
              child={activeChild}
              fees={fees.data}
            />
            <div className="flex gap-2 border-t border-slate-200 p-4 print:hidden">
              <button onClick={() => window.print()}
                className="flex-1 rounded-xl bg-brand-600 px-3 py-2.5 text-sm font-semibold text-white hover:bg-brand-700">
                Print
              </button>
              <button onClick={() => setStatement(false)}
                className="flex-1 rounded-xl border border-slate-300 px-3 py-2.5 text-sm font-medium hover:bg-slate-50">
                Close
              </button>
            </div>
          </div>
        </div>
      )}
    </div>
  )
}

/* ------------------------------------------------------------ child card --- */

function ChildCard({ child, today, fees, feesLoading, month, monthLoading, tests, testsLoading, onOpen }: {
  child: PortalChild
  today: string
  fees: Fees | undefined; feesLoading: boolean
  month: Att | undefined; monthLoading: boolean
  tests: PortalTests | undefined; testsLoading: boolean
  onOpen: (t: Tab) => void
}) {
  const first = firstName(child.full_name)
  const birthday = isBirthday(child.dob, today)
  const facts = [
    child.class_name ?? 'Not enrolled',
    child.section_name ? `Section ${child.section_name}` : null,
    child.roll_no ? `Roll ${child.roll_no}` : null,
    child.gr_no ? grLabel(child.gr_no) : null,
  ].filter(Boolean).join(' · ')

  // The three answers, one tile each. Each opens the tab it summarises.
  const oldestDue = fees?.invoices.filter((i) => i.outstanding > 0 && i.due_date)
    .map((i) => i.due_date as string).sort()[0]
  const feeTile: TileProps = feesLoading || !fees
    ? { tone: 'slate', label: 'Fees', value: '…' }
    : fees.balance > 0
      ? { tone: oldestDue && oldestDue < today ? 'danger' : 'due', label: 'Fees due', value: money(fees.balance),
          sub: oldestDue ? (oldestDue < today ? 'Overdue' : `By ${shortDate(oldestDue)}`) : undefined }
      : { tone: 'money', label: 'Fees', value: 'All paid' }

  const p = month?.percent ?? null
  const attTile: TileProps = monthLoading || !month
    ? { tone: 'slate', label: 'This month', value: '…' }
    : month.marked === 0
      ? { tone: 'slate', label: 'This month', value: '-', sub: 'No register yet' }
      : { tone: p != null && p >= 90 ? 'money' : p != null && p >= 75 ? 'due' : 'danger',
          label: 'This month', value: `${p ?? '-'}%`, sub: `${month.marked} days marked` }

  const last = tests?.tests[0]
  const testTile: TileProps = testsLoading || !tests
    ? { tone: 'slate', label: 'Last test', value: '…' }
    : !last
      ? { tone: 'slate', label: 'Last test', value: '-', sub: tests.upcoming.length ? `${tests.upcoming.length} coming up` : 'None yet' }
      : last.is_absent
        ? { tone: 'slate', label: 'Last test', value: 'Absent', sub: last.subject }
        : { tone: 'brand', label: 'Last test', value: `${markText(last.marks)}/${markText(last.max_marks)}`,
            sub: `${last.subject} · ${pct(last.marks, last.max_marks) ?? '-'}%` }

  return (
    <PCard className="relative overflow-hidden">
      {/* On the child's birthday, the portal says so. It costs one line and it
          is the one thing on this page that is only good news. */}
      {birthday && (
        <div className="relative -mx-4 -mt-4 mb-4 overflow-hidden bg-gradient-to-r from-fuchsia-500 via-violet-500 to-brand-600 px-4 py-3 text-white sm:-mx-5 sm:-mt-5 sm:px-5">
          <span aria-hidden="true" className="absolute left-6 top-1 h-1.5 w-1.5 rounded-full bg-due-300" />
          <span aria-hidden="true" className="absolute right-10 top-2 h-2 w-2 rounded-full bg-sky-200" />
          <span aria-hidden="true" className="absolute bottom-1 right-24 h-1.5 w-1.5 rounded-full bg-white" />
          <p className="relative flex items-center gap-2 text-sm font-bold">
            <span className="flex h-8 w-8 items-center justify-center rounded-full bg-white/20"><IconBirthday /></span>
            Happy birthday, {first}!
          </p>
        </div>
      )}

      <div className="flex items-center gap-3">
        <Avatar name={child.full_name} size="lg" className="ring-4 ring-brand-50" />
        <div className="min-w-0">
          <h2 className="truncate text-lg font-bold text-slate-900">{child.full_name}</h2>
          <p className="mt-0.5 text-xs font-medium text-slate-500">{facts}</p>
          {child.class_teacher && (
            <p className="mt-1 text-xs text-slate-600">
              Class teacher: <b className="font-semibold text-slate-800">{child.class_teacher}</b>
            </p>
          )}
        </div>
      </div>

      {/* A row each, not three squeezed columns: side by side on a 360px phone
          they read "Rs 4,..." and "THIS MO...". */}
      <div className="mt-4 grid grid-cols-1 gap-2">
        <Tile {...feeTile} onClick={() => onOpen('fees')} />
        <Tile {...attTile} onClick={() => onOpen('attendance')} />
        <Tile {...testTile} onClick={() => onOpen('results')} />
      </div>
    </PCard>
  )
}

interface TileProps {
  tone: 'money' | 'due' | 'danger' | 'brand' | 'slate'
  label: string
  value: string
  sub?: string
}

function Tile({ tone, label, value, sub, onClick }: TileProps & { onClick: () => void }) {
  const skin = {
    money: 'bg-money-50 text-money-800 ring-money-200',
    due: 'bg-due-50 text-due-800 ring-due-200',
    danger: 'bg-danger-50 text-danger-700 ring-danger-200',
    brand: 'bg-brand-50 text-brand-800 ring-brand-200',
    slate: 'bg-slate-50 text-slate-700 ring-slate-200',
  }[tone]
  return (
    <button type="button" onClick={onClick}
      className={`flex min-w-0 items-center justify-between gap-3 rounded-2xl px-3.5 py-2 text-left ring-1 transition hover:brightness-[0.97] active:scale-[0.99] ${skin}`}>
      <span className="shrink-0 text-[11px] font-semibold uppercase tracking-wide opacity-80">{label}</span>
      <span className="min-w-0 text-right">
        <span className="block truncate text-base font-bold tabular-nums leading-tight">{value}</span>
        {sub && <span className="block truncate text-[11px] font-medium opacity-80">{sub}</span>}
      </span>
    </button>
  )
}

import { isMissingFunction } from '@/lib/notInstalled'
import { useState, type ReactNode } from 'react'
import { Link } from 'react-router-dom'
import { useQuery } from '@tanstack/react-query'
import { useAuth } from '@/auth/AuthProvider'
import { ROLE_LABELS, canWrite, isTeacher } from '@/auth/roles'
import { canAccess } from '@/navigation'
import { MyClass } from './MyClass'
import {
  getCurrentSession, getDashboardSummary, getDashboardTrends, getDraftStudents,
  listStudentsWithoutAClass,
  type AttendanceDay, type BillingMonth, type ClassDues, type DashboardTrends,
  type SectionToday, type StaffToday,
} from '@/lib/db'
import { diagnoseNoClass } from '@/lib/noClass'
import { requireSupabase } from '@/lib/supabase'
import { isConfigured } from '@/lib/config'
import { fmtPKR } from '@/lib/format'
import { Card, StatTile, PageHeader, EmptyState } from '@/components/ui'
import {
  C, ChartCard, Donut, HBars, Legend, MiniTable, StackBar, StackedColumns, TrendLine,
  attendanceParts, pctOf, type BarRow, type ColumnDatum, type Segment,
} from '@/components/viz'
import {
  IconAttendance,
  IconStudents,
  IconWallet,
  IconAlert,
  IconFees,
  IconAdmissions,
  IconChevron,
  IconClock,
  IconDashboard,
  IconReports,
  IconStaff,
} from '@/components/icons'

/*
 * THE DASHBOARD, REDRAWN.
 *
 * A school shown the software said the logic was right and the screens were
 * "just numbers". They were: four tiles, a list of links, and a card called At a
 * glance that repeated the tiles in smaller type. A principal reading
 * "Attendance today 82%" could not see which classes were missing from it, and
 * nobody could see whether June's fees ever came in without opening a report.
 *
 * What changed, and what deliberately did not:
 *
 *   * The tiles stay. They are the right answer to "how are we doing today",
 *     and they were already the one loud thing on the page.
 *   * Every chart is drawn from fn_dashboard_trends (0146), which is built so
 *     its figures agree with the tiles: the class rows sum to Active students
 *     and the dues bars sum to Outstanding.
 *   * NOTHING IS MOCKED. A chart with no data says so in words. A dashboard
 *     that fills its gaps with sample figures is one somebody will eventually
 *     make a decision from, and a failed read must never look like a quiet day.
 *   * No charting library. See components/viz.tsx for why.
 *
 * The warnings that used to be four full-width paragraphs above the tiles are
 * now one "Needs attention" list, each row with a button to the screen that
 * fixes it, so they no longer push every figure below the fold.
 */

/* THE one attendance rule: present + late + half of a half day, over marked
 * days. It is fn__attendance_pct in the database (0097) and it is written out
 * here only because this tile is handed counts rather than a percentage.
 *
 * This line used to read (present + half_day) / marked, which was wrong twice:
 * it counted a half day as a whole one, and it did not count `late` AT ALL, so
 * a class that all arrived late showed as nobody having come in. The result
 * card in the child's hand, the student profile and the teacher's own screen
 * all used the correct rule, so the owner's dashboard was the odd one out and
 * always the pessimistic one. */
export function attendancePct(a: { present: number; late: number; half_day: number; marked: number }): number | null {
  if (!a.marked) return null
  return Math.round(((a.present + a.late + 0.5 * a.half_day) / a.marked) * 100)
}

// A register marked at 09:40 should reach a principal who opened the page at
// 09:30 without them knowing to reload. Both reads share the interval so the
// tiles and the charts always describe the same moment.
const REFRESH = 5 * 60 * 1000


/** "24 Sep", "Thu 24 Sep", from a plain date, without the browser's timezone
 *  moving it a day. */
function dayLabel(iso: string, long = false): string {
  const [y, m, d] = iso.split('-').map(Number)
  if (!y || !m || !d) return iso
  return new Date(Date.UTC(y, m - 1, d)).toLocaleDateString('en-GB', {
    ...(long ? { weekday: 'short' as const } : {}), day: 'numeric', month: 'short', timeZone: 'UTC',
  })
}

function sectionName(s: { class_name: string; section_name: string | null }) {
  return s.section_name ? `${s.class_name} ${s.section_name}` : s.class_name
}

function plural(n: number, one: string, many = `${one}s`) {
  return `${n.toLocaleString('en-PK')} ${n === 1 ? one : many}`
}

/* ------------------------------------------------------------ the page --- */

export function Dashboard() {
  const { profile } = useAuth()
  const role = profile?.role
  const configured = isConfigured
  const isTeach = isTeacher(role)
  const on = configured && !isTeach
  const summary = useQuery({
    queryKey: ['dashboardSummary'],
    queryFn: getDashboardSummary,
    enabled: on,
    refetchInterval: REFRESH,
  })
  const trends = useQuery({
    queryKey: ['dashboardTrends'],
    queryFn: getDashboardTrends,
    enabled: on,
    refetchInterval: REFRESH,
    // Asking again cannot create a function that was never installed.
    retry: (n, e) => n < 1 && !isMissingFunction(e),
  })
  /* Its own read rather than a field on fn_dashboard_summary. That function is
     140 lines and is reproduced whole by anything that touches it, which is how
     a careful fix gets silently reverted; 0140's own header records that
     happening once already. This is one index scan on a partial index. */
  const drafts = useQuery({
    queryKey: ['draftStudentsSummary'],
    queryFn: () => getDraftStudents(0),
    enabled: on,
  })
  // Only asked when there is somebody to explain, and silent if it fails: the
  // count above already says the important part.
  const noClassCount = summary.data?.students_without_a_class ?? 0
  const noClass = useQuery({
    queryKey: ['studentsWithoutAClass'],
    queryFn: listStudentsWithoutAClass,
    enabled: on && noClassCount > 0,
  })
  const session = useQuery({
    queryKey: ['currentSession'],
    queryFn: getCurrentSession,
    enabled: on && noClassCount > 0,
  })

  // Teachers get a class-focused home instead of the admin dashboard.
  if (isTeach) return <MyClass />

  const d = summary.data
  const t = trends.data
  const loading = summary.isLoading
  const finance = !!d?.finance_visible
  const canSettings = canAccess('/settings', role)

  /* Today's register, from the class rows when they are here and from the
     summary until then. The class rows count exactly the children on the
     Active students tile, so the tile, the ring and the rows cannot disagree;
     the summary is the fallback for a database without 0146. */
  const roll = t ? sumSections(t.sections) : null
  const att = roll ?? d?.attendance ?? null
  const pct = att ? attendancePct(att) : null
  const classesTotal = t?.sections.length ?? 0

  return (
    <div>
      <PageHeader
        icon={<IconDashboard />}
        title={`Good day, ${(profile?.full_name ?? 'there').split(' ')[0]}`}
        subtitle={
          profile
            ? `Signed in as ${ROLE_LABELS[profile.role]} · ${new Date().toLocaleDateString('en-PK', {
                weekday: 'long',
                day: 'numeric',
                month: 'long',
              })}`
            : undefined
        }
      />

      {!configured && (
        <EmptyState
          icon={<IconAlert />}
          title="Not connected yet"
          message="Supabase isn’t configured, so live figures are unavailable. Set the connection details to see today’s numbers."
        />
      )}

      {configured && (
        <>
          {summary.isError && (
            <div className="mb-5 flex items-start gap-3 rounded-xl border border-danger-100 bg-danger-50 p-4 text-sm text-danger-700">
              <span className="mt-0.5 text-danger-500">
                <IconAlert />
              </span>
              <div>
                <p className="font-medium">Couldn’t load today’s figures</p>
                <p className="mt-0.5 text-danger-600">{(summary.error as Error).message}</p>
              </div>
            </div>
          )}

          <NeedsAttention
            items={attentionItems({
              d, drafts: drafts.data ?? null, canSettings,
              noClassRows: noClass.data ?? null,
              currentSession: session.data?.name ?? null,
            })}
          />

          <div className="grid grid-cols-2 gap-3 sm:gap-4 lg:grid-cols-4">
            <LinkTile to="/attendance" enabled={canAccess('/attendance', role)}>
              <StatTile
                tone={pct !== null && pct < 75 ? 'due' : 'info'}
                icon={<IconAttendance />}
                label="Attendance today"
                value={loading ? '…' : att && att.marked > 0 ? `${pct}%` : '-'}
                /* The counts, not a weighted total. "18 present of 20" was
                   computed with the same wrong arithmetic as the percentage,
                   so the sentence under the tile disagreed with the register a
                   teacher had just filled in. */
                sub={
                  att && att.marked > 0
                    ? [
                        roll ? `${roll.marked} of ${roll.on_roll} marked` : `${att.marked} marked`,
                        att.absent ? `${att.absent} absent` : null,
                      ].filter(Boolean).join(' · ')
                    : classesTotal > 0
                      ? `Not marked yet · 0 of ${plural(classesTotal, 'class', 'classes')} done`
                      : 'Not marked yet today'
                }
              />
            </LinkTile>

            <LinkTile to="/students" enabled={canAccess('/students', role)}>
              <StatTile
                tone="brand"
                icon={<IconStudents />}
                label="Active students"
                value={loading ? '…' : d ? d.active_students.toLocaleString('en-PK') : '-'}
                /* This is the same function the plan limit uses. It used to be a
                   second copy of the rule that counted a removed child and
                   missed one with no class, so the tile, the Students screen and
                   the licence gave three answers. */
                sub={
                  d
                    ? [`${d.new_admissions_month} admitted this month`,
                       d.students_without_a_class
                         ? `${d.students_without_a_class} not in a class`
                         : null,
                      ].filter(Boolean).join(' · ')
                    : undefined
                }
              />
            </LinkTile>

            {finance && d && (
              <>
                <LinkTile to="/fees" enabled={canAccess('/fees', role)}>
                  <StatTile
                    tone="money"
                    icon={<IconWallet />}
                    label="Collected today"
                    value={fmtPKR(d.collected_today)}
                    sub={`${fmtPKR(d.collected_month)} this month`}
                  />
                </LinkTile>

                <LinkTile to="/fees" enabled={canAccess('/fees', role)}>
                  {/* "Nothing owed" and "nothing billed" are different facts.
                      This tile used to render the second as the first: Rs 0 in
                      green, so a school that had never generated a challan was
                      told it was fully paid up. */}
                  {(d.billed_students_month ?? 0) === 0 ? (
                    <StatTile
                      tone="due"
                      icon={<IconAlert />}
                      label="Outstanding"
                      value="Not billed"
                      sub="No challans issued this month"
                    />
                  ) : (
                    <StatTile
                      tone={(d.outstanding ?? 0) > 0 ? 'due' : 'money'}
                      icon={<IconAlert />}
                      label="Outstanding"
                      value={fmtPKR(d.outstanding)}
                      sub={`${plural(d.defaulters ?? 0, 'student')} with dues`}
                    />
                  )}
                </LinkTile>
              </>
            )}
          </div>

          <Shortcuts role={role} />

          <Charts
            trends={trends}
            summaryFailed={summary.isError}
            finance={finance}
            outstanding={d?.outstanding ?? null}
            canSettings={canSettings}
            canAdd={canAccess('/students', role) && canWrite(role)}
            roleCanFees={canAccess('/fees', role)}
            roleCanReports={canAccess('/reports', role)}
          />

          {d && !finance && (
            <p className="mt-4 text-xs text-slate-400">
              Fee figures are visible to admin and accounts staff.
            </p>
          )}

          <ReviewPrompt />
        </>
      )}
    </div>
  )
}

function sumSections(rows: SectionToday[]) {
  const z = { on_roll: 0, marked: 0, present: 0, late: 0, half_day: 0, leave: 0, absent: 0 }
  for (const r of rows) {
    z.on_roll += r.on_roll; z.marked += r.marked; z.present += r.present; z.late += r.late
    z.half_day += r.half_day; z.leave += r.leave; z.absent += r.absent
  }
  return z
}

/** A stat tile that navigates, when the reader may open where it points. A
 *  tile that links to a screen the role is refused is a dead end with a hover
 *  effect, so for them it is just a tile. */
function LinkTile({ to, enabled, children }: { to: string; enabled: boolean; children: ReactNode }) {
  if (!enabled) return <div className="h-full">{children}</div>
  return (
    <Link to={to} className="block h-full rounded-2xl transition hover:-translate-y-0.5 hover:shadow-pop focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-brand-400">
      {children}
    </Link>
  )
}

/* ------------------------------------------------------- needs attention --- */

interface AttentionItem { key: string; title: ReactNode; body: ReactNode; action?: ReactNode }

function ActionLink({ to, children }: { to: string; children: ReactNode }) {
  return (
    <Link
      to={to}
      className="inline-flex shrink-0 items-center gap-1 whitespace-nowrap rounded-lg bg-white px-3 py-1.5 text-sm font-medium text-due-800 ring-1 ring-due-200 transition hover:bg-due-100"
    >
      {children}
      <IconChevron className="h-4 w-4" />
    </Link>
  )
}

function attentionItems({
  d, drafts, canSettings, noClassRows, currentSession,
}: {
  d: Awaited<ReturnType<typeof getDashboardSummary>> | undefined
  drafts: Awaited<ReturnType<typeof getDraftStudents>> | null
  canSettings: boolean
  noClassRows: Awaited<ReturnType<typeof listStudentsWithoutAClass>> | null
  currentSession: string | null
}): AttentionItem[] {
  const items: AttentionItem[] = []
  const askOwner = 'Ask the owner or principal: it is under Settings.'

  if (d && !d.session_set) {
    items.push({
      key: 'session',
      title: 'No academic session is set',
      body: <>Until one is, every figure on this page reads zero whether or not anything has happened. {!canSettings && askOwner}</>,
      action: canSettings ? <ActionLink to="/settings?tab=sessions">Set the session</ActionLink> : undefined,
    })
  }

  if (d && d.finance_visible && (d.classes_without_fee ?? 0) > 0) {
    const n = d.classes_without_fee ?? 0
    items.push({
      key: 'fees',
      title: `${plural(n, 'class', 'classes')} ${n === 1 ? 'has' : 'have'} students but no fee set`,
      body: <>Their challans come out at Rs 0 and report success, so the school looks billed when it is not. {!canSettings && askOwner}</>,
      action: canSettings ? <ActionLink to="/settings?tab=fees">Set the fees</ActionLink> : undefined,
    })
  }

  /* THE CHILDREN NO OTHER SCREEN CAN SEE. An active student with no active
     enrolment in the current session gets no challan, no register and no
     result card, and they are counted by nothing else on this page.
     The advice used to be "admit or enrol each one", which is right for a
     child admitted and never placed and wrong for two hundred children last
     seen in last year's session: those need Year Rollover, which moves the
     roster across in one step, with a preview, and keeps the promotions. */
  if (d && d.students_without_a_class > 0) {
    const n = d.students_without_a_class
    const dx = noClassRows ? diagnoseNoClass(noClassRows, currentSession) : null
    const rollover = !!dx && dx.leftBehind > 0 && dx.leftBehind >= dx.total / 2
    let body: ReactNode
    if (rollover && dx) {
      body = (
        <>
          {dx.leftBehind === dx.total ? 'All of them were' : `${dx.leftBehind.toLocaleString('en-PK')} of them were`} last
          in a class in {dx.fromSession ?? 'an earlier session'} and were never carried
          into {currentSession ?? 'this session'}. Year Rollover does that for the whole school in
          one step, and shows you a preview before it changes anything.
          {dx.neverEnrolled > 0 && ` ${plural(dx.neverEnrolled, 'other was', 'others were')} admitted and never put in a class.`}
          {!canSettings && ` ${askOwner}`}
        </>
      )
    } else {
      body = (
        <>
          They get no challan, no attendance register and no result card until they are in a class.
          Open the list, then open each child and put them in their class.
        </>
      )
    }
    items.push({
      key: 'noclass',
      title: `${plural(n, 'student is', 'students are')} not on any class list`,
      body,
      action: (
        <div className="flex flex-wrap gap-2">
          {rollover && canSettings && <ActionLink to="/settings?tab=rollover">Open Year Rollover</ActionLink>}
          <ActionLink to="/students?no_class=1">See who</ActionLink>
        </div>
      ),
    })
  }

  /* THE RECORDS SOMEBODY STILL OWES. Rapid entry lets a school get four
     hundred children in during one afternoon by typing names and roll numbers,
     which is the right trade: a register half entered beats a register not
     entered. This is the other half of that trade. It names what is missing
     rather than counting "incomplete records", because "48 with no date of
     birth" is a task somebody finishes in one sitting and a bare count is a nag.
     NOTHING IS GATED ON IT. These children are billed, marked present and
     examined exactly like the rest. */
  if (drafts && drafts.count > 0) {
    const missing = [
      drafts.missing_father ? `${drafts.missing_father} with no father's name` : null,
      drafts.missing_dob ? `${drafts.missing_dob} with no date of birth` : null,
      drafts.missing_gender ? `${drafts.missing_gender} with no gender` : null,
      drafts.missing_contact ? `${drafts.missing_contact} with no phone number` : null,
    ].filter(Boolean).join(', ')
    items.push({
      key: 'drafts',
      title: `${plural(drafts.count, 'student record')} still ${drafts.count === 1 ? 'needs' : 'need'} finishing`,
      body: (
        <>
          {missing}{missing ? '. ' : ''}They are billed, marked and examined like everybody else: the
          detail is only missing from certificates, board forms and the messages you send home.
        </>
      ),
      action: <ActionLink to="/students?drafts=1">Show them</ActionLink>,
    })
  }

  return items
}

function NeedsAttention({ items }: { items: AttentionItem[] }) {
  if (!items.length) return null
  return (
    <section aria-label="Needs attention" className="mb-5 overflow-hidden rounded-2xl border border-due-200 bg-due-50/70">
      <h2 className="flex items-center gap-2 border-b border-due-200/70 px-4 py-2.5 text-sm font-semibold text-due-900">
        <IconAlert className="h-4 w-4 text-due-600" />
        Needs attention
        <span className="rounded-full bg-due-600 px-1.5 text-xs font-semibold text-white">{items.length}</span>
      </h2>
      <ul className="divide-y divide-due-200/70">
        {items.map((it) => (
          <li key={it.key} className="flex flex-col gap-3 px-4 py-3 sm:flex-row sm:items-center sm:justify-between">
            <div className="min-w-0 text-sm">
              <p className="font-medium text-due-900">{it.title}</p>
              <p className="mt-0.5 max-w-[80ch] text-due-800">{it.body}</p>
            </div>
            {it.action}
          </li>
        ))}
      </ul>
    </section>
  )
}

/* ------------------------------------------------------------ shortcuts --- */

/** The four things a school office does most, filtered to what this role may
 *  actually do. The old list offered a read-only trustee "Collect a fee" and a
 *  clerk the Day Book they are refused, both of which end on an error. */
function Shortcuts({ role }: { role: Parameters<typeof canAccess>[1] }) {
  const writer = canWrite(role)
  const all = [
    { to: '/fees', path: '/fees', write: true, icon: <IconFees />, label: 'Collect a fee', hint: 'Search by CNIC or name' },
    { to: '/attendance', path: '/attendance', write: false, icon: <IconAttendance />, label: 'Attendance', hint: 'Today’s registers' },
    { to: '/admissions', path: '/admissions', write: true, icon: <IconAdmissions />, label: 'Admit a student', hint: 'New admission, GR number' },
    { to: '/reports?tab=daybook', path: '/reports', write: false, icon: <IconReports />, label: 'Day book', hint: 'Collected today, and by whom' },
  ].filter((a) => canAccess(a.path, role) && (!a.write || writer))
  if (!all.length) return null
  return (
    <nav aria-label="Shortcuts" className="mt-4 grid grid-cols-2 gap-2 lg:grid-cols-4">
      {all.map((a) => (
        <Link
          key={a.to}
          to={a.to}
          className="group flex items-center gap-3 rounded-xl bg-white p-3 shadow-card ring-1 ring-slate-200/80 transition hover:-translate-y-0.5 hover:shadow-raised hover:ring-brand-300 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-brand-400"
        >
          <span className="flex h-9 w-9 shrink-0 items-center justify-center rounded-lg bg-brand-50 text-brand-600 ring-1 ring-brand-100 transition group-hover:bg-brand-600 group-hover:text-white">
            {a.icon}
          </span>
          <span className="min-w-0 flex-1">
            <span className="block text-sm font-medium leading-tight text-slate-800">{a.label}</span>
            <span className="hidden truncate text-xs text-slate-500 sm:block">{a.hint}</span>
          </span>
        </Link>
      ))}
    </nav>
  )
}

/* --------------------------------------------------------------- charts --- */

function Charts({
  trends, summaryFailed, finance, outstanding, canSettings, canAdd, roleCanFees, roleCanReports,
}: {
  trends: { data?: DashboardTrends; isLoading: boolean; isFetching: boolean; isError: boolean; error: unknown }
  summaryFailed: boolean
  finance: boolean
  outstanding: number | null
  canSettings: boolean
  canAdd: boolean
  roleCanFees: boolean
  roleCanReports: boolean
}) {
  if (trends.isLoading) {
    return (
      <div className="mt-6 grid grid-cols-1 gap-4 lg:grid-cols-3" aria-busy="true" aria-label="Loading the charts">
        <div className="h-72 animate-pulse rounded-2xl bg-white ring-1 ring-slate-200/70 lg:col-span-2" />
        <div className="h-72 animate-pulse rounded-2xl bg-white ring-1 ring-slate-200/70" />
      </div>
    )
  }

  if (trends.isError) {
    // The same failure as the tiles is already on screen once. Twice is noise.
    if (summaryFailed && !isMissingFunction(trends.error)) return null
    const missing = isMissingFunction(trends.error)
    return (
      <div className={`mt-6 rounded-2xl border p-4 text-sm ${missing ? 'border-slate-200 bg-white text-slate-600' : 'border-danger-200 bg-danger-50 text-danger-800'}`}>
        <p className={`font-medium ${missing ? 'text-slate-900' : 'text-danger-900'}`}>
          {missing ? 'The charts are not switched on yet' : 'The charts could not be loaded'}
        </p>
        <p className="mt-1">
          {missing
            ? 'They need a database update that has not been applied yet. Everything else on this page is live.'
            : `${(trends.error as Error)?.message ?? 'Unknown error'}. The figures above are not affected.`}
        </p>
        {missing && canSettings && (
          <p className="mt-1 text-xs text-slate-400">For whoever looks after the database: bundle 47.</p>
        )}
      </div>
    )
  }

  const t = trends.data
  if (!t) return null
  const refreshing = trends.isFetching

  return (
    <div className="mt-6 grid grid-cols-1 gap-4 lg:grid-cols-3">
      <RegisterToday sections={t.sections} fetching={refreshing} className="lg:col-span-2" canAdd={canAdd} />
      <div className="flex min-w-0 flex-col gap-4">
        <AttendanceTrend trend={t.trend} fetching={refreshing} />
        {t.staff.on_books > 0 && <StaffCard staff={t.staff} fetching={refreshing} />}
      </div>
      {finance && (
        <>
          <FeeMonths months={t.months} today={t.today} fetching={refreshing} className="lg:col-span-2" roleCanFees={roleCanFees} />
          <DuesByClass rows={t.dues_by_class} outstanding={outstanding} fetching={refreshing} roleCanReports={roleCanReports} />
        </>
      )}
    </div>
  )
}

/* --------------------------------------------------- today's register --- */

const CLASS_ROWS = 8

function RegisterToday({
  sections, fetching, className, canAdd,
}: { sections: SectionToday[]; fetching: boolean; className?: string; canAdd: boolean }) {
  const [all, setAll] = useState(false)
  const z = sumSections(sections)
  const pct = attendancePct(z)
  const parts = attendanceParts(z, z.on_roll)
  const marked = sections.filter((s) => s.marked > 0).length
  const waiting = sections.length - marked
  const shown = all ? sections : sections.slice(0, CLASS_ROWS)

  if (!sections.length) {
    return (
      <ChartCard title="Today’s register" className={className}>
        <p className="text-sm text-slate-500">
          No class has students in it yet. Once children are admitted into a class, each class’s register
          shows here as it is marked.
        </p>
        {canAdd && (
          <Link
            to="/students?add=bulk"
            className="mt-3 inline-flex items-center gap-1 text-sm font-medium text-brand-700 hover:underline"
          >
            Add a whole class at once <IconChevron className="h-4 w-4" />
          </Link>
        )}
      </ChartCard>
    )
  }

  return (
    <ChartCard
      className={className}
      fetching={fetching}
      title="Today’s register"
      subtitle={
        waiting === 0
          ? `Every class has marked · ${z.marked.toLocaleString('en-PK')} students`
          : `${marked} of ${plural(sections.length, 'class', 'classes')} marked · ${plural(waiting, 'class', 'classes')} still to do`
      }
      table={
        <MiniTable
          head={['Class', 'On roll', 'Marked', 'Present', 'Late / half', 'Absent', 'Leave', '%']}
          align={['l', 'r', 'r', 'r', 'r', 'r', 'r', 'r']}
          rows={sections.map((s) => {
            const p = attendancePct(s)
            return [sectionName(s), s.on_roll, s.marked, s.present, s.late + s.half_day, s.absent, s.leave, p == null ? '-' : `${p}%`]
          })}
        />
      }
    >
      <div className="grid grid-cols-1 gap-6 md:grid-cols-[auto_minmax(0,1fr)]">
        <div className="flex flex-col items-center gap-4 sm:flex-row md:flex-col md:items-stretch">
          <Donut
            segments={parts}
            size={152}
            label={`Today’s register: ${parts.map((p) => `${p.label} ${p.value}`).join(', ')}`}
            center={
              z.marked > 0 ? (
                <>
                  <span className="text-3xl font-semibold text-slate-900">{pct}%</span>
                  <span className="text-xs text-slate-500">attendance</span>
                </>
              ) : (
                <>
                  <IconClock className="h-5 w-5 text-slate-400" />
                  <span className="mt-1 text-xs font-medium text-slate-600">Not marked yet</span>
                  <span className="text-[11px] text-slate-400">{z.on_roll} on roll</span>
                </>
              )
            }
          />
          <div className="w-full min-w-[12rem] sm:max-w-[16rem] md:max-w-none">
            {/* Once anything is marked, every status shows even at zero, because
                "Absent 0" is news. Before that, four rows of zeros are not. */}
            <Legend
              items={parts.filter((p) => p.value > 0 || (z.marked > 0 && p.key !== 'unmarked'))}
              total={z.on_roll}
            />
          </div>
        </div>

        <div className="min-w-0">
          <ul className="space-y-2.5" aria-label="Each class today">
            {shown.map((s) => {
              const p = attendancePct(s)
              const partial = s.marked > 0 && s.marked < s.on_roll
              return (
                <li key={`${s.class_id}:${s.section_id ?? ''}`} className="text-sm">
                  <div className="mb-1 flex items-baseline justify-between gap-3">
                    <span className="min-w-0 truncate text-slate-700">
                      {sectionName(s)}
                      <span className="ml-1.5 text-xs text-slate-400">{s.on_roll}</span>
                    </span>
                    {s.marked === 0 ? (
                      <span className="inline-flex shrink-0 items-center gap-1 rounded-full bg-slate-100 px-2 py-0.5 text-xs font-medium text-slate-600">
                        <IconClock className="h-3.5 w-3.5" /> Not marked
                      </span>
                    ) : (
                      <span className="shrink-0 text-xs text-slate-500">
                        {partial && <span className="mr-1.5">{s.marked}/{s.on_roll} marked</span>}
                        {s.absent > 0 && <span className="mr-1.5">{s.absent} absent</span>}
                        <span className="text-sm font-semibold text-slate-900">{p}%</span>
                      </span>
                    )}
                  </div>
                  <StackBar
                    parts={attendanceParts(s, s.on_roll)}
                    height={8}
                    label={`${sectionName(s)}: ${attendanceParts(s, s.on_roll).map((x) => `${x.label} ${x.value}`).join(', ')}`}
                  />
                </li>
              )
            })}
          </ul>
          {sections.length > CLASS_ROWS && (
            <button
              type="button"
              onClick={() => setAll((v) => !v)}
              className="mt-3 text-xs font-medium text-brand-700 hover:underline"
            >
              {all ? 'Show fewer' : `Show all ${sections.length} classes`}
            </button>
          )}
        </div>
      </div>
    </ChartCard>
  )
}

/* ------------------------------------------------------ fourteen days --- */

function AttendanceTrend({ trend, fetching }: { trend: AttendanceDay[]; fetching: boolean }) {
  if (!trend.length) {
    return (
      <ChartCard title="Attendance, school day by school day">
        <p className="text-sm text-slate-500">
          The line starts on the first day a register is marked. Days with no register, like Sundays and
          holidays, are left out rather than drawn as zero.
        </p>
      </ChartCard>
    )
  }
  const tot = trend.reduce(
    (a, r) => ({ present: a.present + r.present, late: a.late + r.late, half_day: a.half_day + r.half_day, marked: a.marked + r.marked }),
    { present: 0, late: 0, half_day: 0, marked: 0 },
  )
  const avg = attendancePct(tot)
  const withPct = trend.filter((r) => r.pct != null)
  const low = withPct.reduce<AttendanceDay | null>((m, r) => (m == null || (r.pct as number) < (m.pct as number) ? r : m), null)
  const floor = withPct.every((r) => (r.pct as number) >= 55) ? 50 : 0

  return (
    <ChartCard
      fetching={fetching}
      title={`Attendance, last ${plural(trend.length, 'school day')}`}
      subtitle={
        avg == null ? undefined
          : `${avg}% across the period${low && trend.length > 1 ? ` · lowest ${Math.round(low.pct as number)}% on ${dayLabel(low.date, true)}` : ''}`
      }
      table={
        <MiniTable
          head={['Day', 'Marked', 'Absent', '%']}
          align={['l', 'r', 'r', 'r']}
          rows={[...trend].reverse().map((r) => [dayLabel(r.date, true), r.marked, r.absent, r.pct == null ? '-' : `${Math.round(r.pct)}%`])}
        />
      }
    >
      <TrendLine
        label={`Attendance by school day, ${trend.length} days`}
        yMin={floor}
        yTicks={floor ? [50, 75, 100] : [0, 25, 50, 75, 100]}
        points={trend.map((r) => ({
          key: r.date,
          label: dayLabel(r.date),
          value: r.pct,
          tipTitle: dayLabel(r.date, true),
          tipRows: [
            { label: 'attendance', value: r.pct == null ? '-' : `${Math.round(r.pct)}%`, color: C.series },
            { label: 'absent', value: String(r.absent) },
            { label: 'marked', value: String(r.marked) },
          ],
        }))}
      />
    </ChartCard>
  )
}

/* ----------------------------------------------------------- staff room --- */

function StaffCard({ staff, fetching }: { staff: StaffToday; fetching: boolean }) {
  const inToday = staff.present + staff.late + staff.half_day
  const parts = attendanceParts(staff, staff.on_books)
  return (
    <ChartCard
      fetching={fetching}
      title="Staff today"
      action={
        <Link to="/staff" className="text-xs font-medium text-brand-700 hover:underline">
          Staff
        </Link>
      }
    >
      <div className="mb-2 flex items-baseline gap-2">
        <IconStaff className="h-4 w-4 self-center text-slate-400" />
        <span className="text-2xl font-semibold text-slate-900">{inToday}</span>
        <span className="text-sm text-slate-500">of {staff.on_books} in</span>
      </div>
      <StackBar parts={parts} height={8} label={`Staff today: ${parts.map((p) => `${p.label} ${p.value}`).join(', ')}`} />
      <p className="mt-2 flex flex-wrap gap-x-3 gap-y-1 text-xs text-slate-500">
        {parts.filter((p) => p.value > 0).map((p) => (
          <span key={p.key} className="inline-flex items-center gap-1">
            <span className="h-2 w-2 rounded-sm" style={{ background: p.color }} aria-hidden />
            {p.value} {p.label.toLowerCase()}
          </span>
        ))}
      </p>
    </ChartCard>
  )
}

/* ------------------------------------------------------ billing months --- */

function monthKeys(today: string): string[] {
  const [y, m] = today.split('-').map(Number)
  const out: string[] = []
  for (let k = 5; k >= 0; k--) {
    const dt = new Date(Date.UTC(y, m - 1 - k, 1))
    out.push(`${dt.getUTCFullYear()}-${String(dt.getUTCMonth() + 1).padStart(2, '0')}`)
  }
  return out
}

function monthName(ym: string, long = false) {
  const [y, m] = ym.split('-').map(Number)
  return new Date(Date.UTC(y, m - 1, 1)).toLocaleDateString('en-GB', {
    month: long ? 'long' : 'short', ...(long ? { year: 'numeric' as const } : {}), timeZone: 'UTC',
  })
}

function feeParts(m: BillingMonth | undefined): Segment[] {
  return [
    { key: 'paid', label: 'Paid', value: m?.paid ?? 0, color: C.good },
    { key: 'not_due', label: 'Not due yet', value: m?.not_due ?? 0, color: C.warn },
    { key: 'overdue', label: 'Overdue', value: m?.overdue ?? 0, color: C.bad },
  ]
}

function FeeMonths({
  months, today, fetching, className, roleCanFees,
}: { months: BillingMonth[]; today: string; fetching: boolean; className?: string; roleCanFees: boolean }) {
  const byKey = new Map(months.map((m) => [m.month.slice(0, 7), m]))
  // A fixed six-month axis, so a month nobody billed is a visible gap with a
  // word under it instead of silently closing up, which is how a school fails
  // to notice that July was never generated.
  const keys = today ? monthKeys(today) : [...byKey.keys()]
  const data: ColumnDatum[] = keys.map((k) => {
    const m = byKey.get(k)
    return {
      key: k,
      label: monthName(k),
      tipTitle: monthName(k, true),
      parts: feeParts(m),
      empty: !m || m.billed <= 0,
      emptyLabel: 'Not billed',
    }
  })
  const totals = feeParts({
    month: '', challans: 0,
    billed: months.reduce((s, m) => s + m.billed, 0),
    paid: months.reduce((s, m) => s + m.paid, 0),
    not_due: months.reduce((s, m) => s + m.not_due, 0),
    overdue: months.reduce((s, m) => s + m.overdue, 0),
  })
  const cur = byKey.get(keys[keys.length - 1])
  const curName = monthName(keys[keys.length - 1] ?? today.slice(0, 7), true).split(' ')[0]

  return (
    <ChartCard
      className={className}
      fetching={fetching}
      title="Fees by billing month"
      subtitle={
        cur && cur.billed > 0
          ? `${pctOf(cur.paid, cur.billed)}% of ${curName}’s challans paid so far · ${fmtPKR(cur.billed - cur.paid)} still to come in`
          : `Nothing billed for ${curName} yet`
      }
      action={
        roleCanFees ? (
          <Link to="/fees" className="text-xs font-medium text-brand-700 hover:underline">Fees</Link>
        ) : undefined
      }
      table={
        <MiniTable
          head={['Month', 'Challans', 'Billed', 'Paid', 'Not due yet', 'Overdue']}
          align={['l', 'r', 'r', 'r', 'r', 'r']}
          rows={keys.map((k) => {
            const m = byKey.get(k)
            return m
              ? [monthName(k, true), m.challans, fmtPKR(m.billed), fmtPKR(m.paid), fmtPKR(m.not_due), fmtPKR(m.overdue)]
              : [monthName(k, true), 0, 'Not billed', '-', '-', '-']
          })}
        />
      }
      footer={
        months.length > 0 && (
          <>
            Each challan counts in the month it bills, whenever it was paid. The Outstanding tile also carries
            balances brought in from before the software and any adjustments, so the two are not meant to match.
          </>
        )
      }
    >
      {months.length === 0 ? (
        <p className="text-sm text-slate-500">
          No challans in the last six months. Once a month is generated under Fees, it shows here as a column:
          what it billed, and how much of that has come in.
        </p>
      ) : (
        <div className="grid grid-cols-1 gap-5 md:grid-cols-[minmax(0,1fr)_13rem]">
          <StackedColumns
            data={data}
            formatFull={fmtPKR}
            label={`Fees by billing month: ${data.map((c) => `${c.tipTitle} ${c.empty ? 'not billed' : c.parts.map((p) => `${p.label} ${fmtPKR(p.value)}`).join(', ')}`).join('; ')}`}
          />
          <div className="self-center">
            <p className="mb-2 text-xs font-medium uppercase tracking-wide text-slate-400">Six months</p>
            <Legend items={totals} format={(n) => fmtPKR(n)} />
          </div>
        </div>
      )}
    </ChartCard>
  )
}

/* ------------------------------------------------------ where the dues are --- */

const DUES_ROWS = 7

function DuesByClass({
  rows, outstanding, fetching, roleCanReports,
}: { rows: ClassDues[]; outstanding: number | null; fetching: boolean; roleCanReports: boolean }) {
  const total = rows.reduce((s, r) => s + r.amount, 0)
  const students = rows.reduce((s, r) => s + r.students, 0)
  // Folded rather than cut: "Other classes" keeps the bars summing to the tile.
  const top = rows.length > DUES_ROWS + 1 ? rows.slice(0, DUES_ROWS) : rows
  const rest = rows.length > DUES_ROWS + 1 ? rows.slice(DUES_ROWS) : []
  const bars: BarRow[] = [
    ...top.map((r) => ({ key: r.class_id, label: r.class_name, value: r.amount, sub: plural(r.students, 'student') })),
    ...(rest.length
      ? [{
          key: 'other',
          label: `${rest.length} other classes`,
          value: rest.reduce((s, r) => s + r.amount, 0),
          sub: plural(rest.reduce((s, r) => s + r.students, 0), 'student'),
        }]
      : []),
  ]

  return (
    <ChartCard
      fetching={fetching}
      title="Where the dues are"
      subtitle={rows.length ? `${fmtPKR(total)} owed by ${plural(students, 'student')}` : undefined}
      action={
        roleCanReports ? (
          <Link to="/reports?tab=defaulters" className="text-xs font-medium text-brand-700 hover:underline">
            Defaulters
          </Link>
        ) : undefined
      }
      table={
        <MiniTable
          head={['Class', 'Students', 'Owed']}
          align={['l', 'r', 'r']}
          rows={rows.map((r) => [r.class_name, r.students, fmtPKR(r.amount)])}
        />
      }
    >
      {rows.length === 0 ? (
        <p className="text-sm text-slate-500">
          {outstanding != null && outstanding > 0
            ? 'The dues could not be split by class.'
            : 'Nobody on a class list owes anything today.'}
        </p>
      ) : (
        <HBars rows={bars} format={fmtPKR} label="Money owed, by class" />
      )}
    </ChartCard>
  )
}

/**
 * The only place the software ever asks for a review, and it asks once.
 *
 * It renders NOTHING unless the database says this school is eligible and has
 * not written one: an owner three days in, a clerk, or a school that already
 * reviewed us all see an ordinary dashboard. That is the difference between
 * asking and nagging, and it is decided by fn_review_eligibility() rather than
 * by a rule in this file, so the answer here and the answer on /feedback
 * cannot disagree.
 *
 * A school that dismisses it gets it back on the next visit, which is a
 * deliberate limit: remembering the dismissal would need a per-user setting,
 * and a card that appears only for a school that has genuinely used the
 * software for a term and taken twenty fees is not the kind of thing that
 * needs suppressing for ever. If that turns out to be wrong, the honest fix is
 * a stored preference, not a longer nag.
 */
function ReviewPrompt() {
  const [dismissed, setDismissed] = useState(false)
  const elig = useQuery({
    queryKey: ['review-eligibility-card'],
    queryFn: async () => {
      const sb = requireSupabase()
      const { data, error } = await sb.rpc('fn_review_eligibility')
      if (error) throw new Error(error.message)
      return data as { may_review: boolean; existing_review: string | null }
    },
    enabled: isConfigured,
    // Once a term is the natural cadence of the answer, so this does not need
    // to be asked again on every dashboard render.
    staleTime: 60 * 60 * 1000,
  })

  if (dismissed) return null
  if (!elig.data?.may_review) return null
  if (elig.data.existing_review) return null

  return (
    <Card className="mt-6 border-brand-200 bg-brand-50/60">
      <div className="flex flex-wrap items-start justify-between gap-4">
        <div className="max-w-[64ch]">
          <h2 className="text-base font-semibold text-slate-900">
            Would you tell another school what this is like?
          </h2>
          <p className="mt-1.5 text-sm text-slate-600">
            You have been running a real month on this. A school owner deciding whether to
            ring us would rather read your two sentences than anything we write about
            ourselves. It goes on the website under your school's name, or just your city if
            you would rather, and you can take it down whenever you like.
          </p>
        </div>
        <div className="flex shrink-0 items-center gap-2">
          <Link
            to="/feedback"
            className="inline-flex items-center justify-center gap-1.5 rounded-lg bg-brand-600 px-3.5 py-2 text-sm font-medium text-white shadow-card transition hover:bg-brand-700"
          >
            Write a review
          </Link>
          <button
            onClick={() => setDismissed(true)}
            className="rounded-lg px-3 py-2 text-sm text-slate-600 transition hover:bg-white"
          >
            Not now
          </button>
        </div>
      </div>
    </Card>
  )
}

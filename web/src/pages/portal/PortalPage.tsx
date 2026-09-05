/**
 * The parent portal.
 *
 * Built phone-first on purpose. Almost every parent will open this on a
 * mid-range Android over a patchy connection, standing somewhere: not at a
 * desk. So: one column, large tap targets, no tables that need horizontal
 * scrolling, and the two things a parent actually opens it for (what do I owe,
 * was my child in school) above the fold.
 *
 * Every read goes through fn_portal_* which resolves the caller's own family
 * server-side. The child switcher below is a convenience, not a permission:
 * passing another family's id gets refused by the database, not by this file.
 */
import { useState } from 'react'
import { Link, useSearchParams } from 'react-router-dom'
import { useQuery } from '@tanstack/react-query'
import { AnnouncementBanner } from '@/components/AnnouncementBanner'
import { PortalStatement } from '@/components/PortalStatement'
import { useAuth } from '@/auth/AuthProvider'
import {
  getPortalMe,
  getPortalChildFees,
  getPortalChildAttendance,
  getPortalChildResults,
} from '@/lib/db'
import { Card, CardTitle, Badge, EmptyState, Button, money, MiniStat } from '@/components/ui'
import {
  IconStudents,
  IconWallet,
  IconAttendance,
  IconExams,
  IconAlert,
  IconLogout,
  IconCheck,
  IconPrint,
} from '@/components/icons'
import { guideUrl } from '@/lib/config'

function monthLabel(m: string | null): string {
  if (!m) return 'Other charges'
  const d = new Date(m.length === 10 ? `${m}T00:00:00` : m)
  return isNaN(d.getTime())
    ? m
    : d.toLocaleDateString('en-PK', { month: 'long', year: 'numeric' })
}

function dayLabel(d: string): string {
  const dt = new Date(`${d}T00:00:00`)
  return isNaN(dt.getTime())
    ? d
    : dt.toLocaleDateString('en-PK', { weekday: 'short', day: 'numeric', month: 'short' })
}

const ATT_TONE: Record<string, { tone: 'money' | 'danger' | 'due' | 'info'; label: string }> = {
  present: { tone: 'money', label: 'Present' },
  absent: { tone: 'danger', label: 'Absent' },
  late: { tone: 'due', label: 'Late' },
  half_day: { tone: 'due', label: 'Half day' },
  leave: { tone: 'info', label: 'Leave' },
}

type Tab = 'fees' | 'attendance' | 'results'

export function PortalPage() {
  const { signOut } = useAuth()
  const [childId, setChildId] = useState<string | null>(null)
  /* The tab lives in the URL.
   *
   * Two reasons, neither of them about testing. A parent who reloads the page,
   * which happens constantly on a patchy connection, was thrown back to Fees
   * from wherever they were. And a school can now send "open this link to see
   * the result" pointing at /portal?tab=results, which is the difference between
   * a parent finding the marks and phoning the office to ask where they are.
   *
   * Validated against the three known values rather than cast: ?tab=anything
   * would otherwise render no tab content at all and look like a broken page. */
  const [params, setParams] = useSearchParams()
  const urlTab = params.get('tab')
  const tab: Tab = urlTab === 'attendance' || urlTab === 'results' ? urlTab : 'fees'
  const setTab = (t: Tab) => {
    const next = new URLSearchParams(params)
    if (t === 'fees') next.delete('tab')
    else next.set('tab', t)
    setParams(next, { replace: true })
  }
  /* The old Print button called window.print() straight from this page. The
     global print rule hides `body *` and reveals only named ids, and the portal
     had none, so it printed a blank sheet, silently, every time. It now opens a
     real statement that carries an id the print rule knows. */
  const [statement, setStatement] = useState(false)

  const me = useQuery({ queryKey: ['portalMe'], queryFn: getPortalMe })

  const children = me.data?.children ?? []
  const active = childId ?? children[0]?.student_id ?? null
  const activeChild = children.find((c) => c.student_id === active)

  const today = new Date()
  const from = new Date(today.getFullYear(), today.getMonth() - 2, 1)
  const fmt = (d: Date) => d.toISOString().slice(0, 10)

  const fees = useQuery({
    queryKey: ['portalFees', active],
    queryFn: () => getPortalChildFees(active as string),
    enabled: !!active && tab === 'fees',
  })
  const attendance = useQuery({
    queryKey: ['portalAtt', active],
    queryFn: () => getPortalChildAttendance(active as string, fmt(from), fmt(today)),
    enabled: !!active && tab === 'attendance',
  })
  const results = useQuery({
    queryKey: ['portalResults', active],
    queryFn: () => getPortalChildResults(active as string),
    enabled: !!active && tab === 'results',
  })

  if (me.isLoading) {
    return (
      <div className="flex min-h-screen items-center justify-center bg-slate-50 text-sm text-slate-500">
        Loading…
      </div>
    )
  }

  if (me.isError) {
    return (
      <div className="flex min-h-screen items-center justify-center bg-slate-50 p-6">
        <EmptyState
          icon={<IconAlert />}
          title="Could not load your account"
          message={(me.error as Error).message}
          action={
            <Button variant="soft" tone="neutral" onClick={() => void signOut()}>
              Sign out
            </Button>
          }
        />
      </div>
    )
  }

  return (
    <div className="min-h-screen bg-slate-50">
      {/* Header */}
      <header className="bg-gradient-to-br from-brand-700 to-brand-900 px-4 pb-16 pt-5 text-white">
        <div className="mx-auto flex max-w-3xl items-center justify-between gap-3">
          <div className="min-w-0">
            <p className="truncate text-xs uppercase tracking-wide text-brand-200/80">
              {me.data?.school_name ?? 'School'}
            </p>
            <h1 className="mt-0.5 truncate text-lg font-semibold">{me.data?.full_name}</h1>
          </div>
          {/* Sign out ONLY. The password link lives at the foot of the page
              instead: putting both here squeezed the school name to
              "AL QALAM PUBLIC SCH…" and the parent's own name to
              "Muhammad A…" on a 390px phone, which is the width most parents
              have. Identity is what the header is for, and changing a password
              is a once-a-year action. Found by screenshotting the real page at
              phone width, not by reading this file. */}
          <button
            onClick={() => void signOut()}
            className="flex shrink-0 items-center gap-1.5 rounded-lg bg-white/10 px-3 py-1.5 text-xs font-medium transition hover:bg-white/20"
          >
            <IconLogout />
            Sign out
          </button>
        </div>
      </header>

      <main className="mx-auto -mt-12 max-w-3xl px-4 pb-12">
        {/* Vendor notices reach parents too, when one is aimed at them. A
            maintenance window that stops a parent checking a fee is something
            they should be able to read in the portal rather than discover. */}
        <AnnouncementBanner />
        {children.length === 0 ? (
          <Card>
            <EmptyState
              icon={<IconStudents />}
              title="No children linked yet"
              message="Your account is not linked to a student. Please ask the school office to connect it."
            />
          </Card>
        ) : (
          <>
            {/* Child switcher: only when there is more than one */}
            {children.length > 1 && (
              <div className="mb-4 flex gap-2 overflow-x-auto pb-1">
                {children.map((c) => (
                  <button
                    key={c.student_id}
                    onClick={() => setChildId(c.student_id)}
                    className={`shrink-0 rounded-xl px-4 py-2.5 text-sm font-medium shadow-card transition ${
                      c.student_id === active
                        ? 'bg-white text-brand-700 ring-2 ring-brand-500'
                        : 'bg-white/90 text-slate-600 hover:bg-white'
                    }`}
                  >
                    {c.full_name.split(' ')[0]}
                  </button>
                ))}
              </div>
            )}

            {/* Child card */}
            <Card className="mb-4">
              <div className="flex items-center gap-3">
                <span className="flex h-12 w-12 shrink-0 items-center justify-center rounded-2xl bg-brand-50 text-brand-600 ring-1 ring-brand-100">
                  <IconStudents />
                </span>
                <div className="min-w-0">
                  <h2 className="truncate text-base font-semibold text-slate-900">
                    {activeChild?.full_name}
                  </h2>
                  <p className="mt-0.5 truncate text-xs text-slate-500">
                    {activeChild?.class_name ?? 'Not enrolled'}
                    {activeChild?.section_name ? ` · ${activeChild.section_name}` : ''}
                    {activeChild?.gr_no ? ` · GR ${activeChild.gr_no}` : ''}
                  </p>
                </div>
              </div>
            </Card>

            {/* Tabs */}
            <div className="mb-4 grid grid-cols-3 gap-2">
              {(
                [
                  ['fees', 'Fees', <IconWallet key="w" />],
                  ['attendance', 'Attendance', <IconAttendance key="a" />],
                  ['results', 'Results', <IconExams key="e" />],
                ] as const
              ).map(([key, label, icon]) => (
                <button
                  key={key}
                  onClick={() => setTab(key as Tab)}
                  className={`flex flex-col items-center gap-1 rounded-xl px-2 py-3 text-xs font-medium shadow-card transition ${
                    tab === key
                      ? 'bg-brand-600 text-white'
                      : 'bg-white text-slate-600 hover:bg-slate-50'
                  }`}
                >
                  <span className="text-lg">{icon}</span>
                  {label}
                </button>
              ))}
            </div>

            {/* ------------------------------------------------------ fees -- */}
            {tab === 'fees' && (
              <div className="space-y-4">
                {fees.isLoading && <Card><p className="text-sm text-slate-400">Loading…</p></Card>}
                {fees.isError && (
                  <Card><p className="text-sm text-danger-600">{(fees.error as Error).message}</p></Card>
                )}
                {fees.data && (
                  <>
                    <Card>
                      <div className="grid grid-cols-2 gap-3">
                        <MiniStat
                          label="This child owes"
                          value={money(fees.data.balance)}
                          tone={fees.data.balance > 0 ? 'due' : 'money'}
                        />
                        <MiniStat
                          label="Family total"
                          value={money(fees.data.family_outstanding)}
                          tone={fees.data.family_outstanding > 0 ? 'due' : 'money'}
                        />
                      </div>
                      {fees.data.family_credit > 0 && (
                        <p className="mt-3 rounded-lg bg-info-50 px-3 py-2 text-xs text-info-700 ring-1 ring-info-100">
                          You have {money(fees.data.family_credit)} paid in advance. It is applied
                          automatically to the next challan.
                        </p>
                      )}
                      {/* The line that closes the page's own arithmetic.
                          Without it a parent charged for the van read a balance
                          of Rs 2,350 above two challans totalling Rs 2,100 and
                          had nothing on the page to ask about. */}
                      {fees.data.charges_not_on_a_challan !== 0 && (
                        <p className="mt-3 text-xs text-slate-500">
                          Of this, {money(Math.abs(fees.data.charges_not_on_a_challan))}{' '}
                          {fees.data.charges_not_on_a_challan > 0 ? 'is charged' : 'has been taken off'}{' '}
                          separately from the monthly challans. It is listed under Other charges below.
                        </p>
                      )}
                    </Card>

                    <Card>
                      <CardTitle icon={<IconWallet />}>Monthly challans</CardTitle>
                      {fees.data.invoices.length === 0 ? (
                        <p className="text-sm text-slate-400">Nothing billed yet.</p>
                      ) : (
                        <ul className="divide-y divide-slate-100">
                          {fees.data.invoices.map((inv, i) => (
                            <li key={i} className="flex items-center justify-between gap-3 py-2.5">
                              <div className="min-w-0">
                                <p className="text-sm font-medium text-slate-800">
                                  {monthLabel(inv.period_month)}
                                </p>
                                <p className="text-xs text-slate-500">
                                  Billed {money(inv.charge)} · paid {money(inv.paid)}
                                </p>
                              </div>
                              {inv.outstanding > 0 ? (
                                <Badge tone="due">{money(inv.outstanding)} due</Badge>
                              ) : (
                                <Badge tone="money">
                                  <IconCheck /> Paid
                                </Badge>
                              )}
                            </li>
                          ))}
                        </ul>
                      )}
                    </Card>

                    {fees.data.adjustments.length > 0 && (
                      <Card>
                        <CardTitle icon={<IconAlert />}>Other charges and credits</CardTitle>
                        <p className="text-xs text-slate-500">
                          Amounts the school added or took off outside the monthly challan, with the
                          reason they recorded.
                        </p>
                        <ul className="mt-2 divide-y divide-slate-100">
                          {fees.data.adjustments.map((a, i) => (
                            <li key={i} className="flex items-center justify-between gap-3 py-2.5">
                              <div className="min-w-0">
                                <p className="text-sm font-medium text-slate-800">{a.reason}</p>
                                <p className="text-xs text-slate-500">
                                  {new Date(`${a.on}T00:00:00`).toLocaleDateString('en-PK', {
                                    day: 'numeric', month: 'short', year: 'numeric',
                                  })}
                                </p>
                              </div>
                              <span className={`shrink-0 text-sm font-semibold tabular-nums ${a.amount < 0 ? 'text-money-700' : 'text-slate-800'}`}>
                                {a.amount < 0 ? `- ${money(-a.amount)}` : money(a.amount)}
                              </span>
                            </li>
                          ))}
                        </ul>
                      </Card>
                    )}

                    <Card>
                      <CardTitle
                        icon={<IconPrint />}
                        right={
                          <button
                            onClick={() => setStatement(true)}
                            className="text-xs font-medium text-brand-600 hover:underline"
                          >
                            Print statement
                          </button>
                        }
                      >
                        {/* "Your receipts" was wrong and the printed version
                            already knew it: fn_portal_child_fees returns
                            invoices for THIS CHILD and receipts for the WHOLE
                            FAMILY. Under a heading carrying one child's name, a
                            parent of three saw Rs 5,000 of payments above a
                            child who had paid nothing, and reasonably read it as
                            that child being settled. PortalStatement.tsx carried
                            a paragraph about labelling this exactly, and the
                            label was fixed only on the page nobody prints. */}
                        Payments from your family
                      </CardTitle>
                      {fees.data.receipts.length === 0 ? (
                        <p className="text-sm text-slate-400">No payments recorded yet.</p>
                      ) : (
                        <ul className="divide-y divide-slate-100">
                          {fees.data.receipts.map((r) => (
                            <li key={r.receipt_no} className="flex items-center justify-between gap-3 py-2.5">
                              <div className="min-w-0">
                                <p className="text-sm font-medium text-slate-800">
                                  Receipt #{r.receipt_no}
                                </p>
                                <p className="text-xs text-slate-500">
                                  {new Date(r.paid_on).toLocaleDateString('en-PK', {
                                    day: 'numeric',
                                    month: 'short',
                                    year: 'numeric',
                                  })}
                                  {r.received_by ? ` · received by ${r.received_by}` : ''}
                                </p>
                              </div>
                              <span className="shrink-0 text-sm font-semibold tabular-nums text-money-700">
                                {money(r.amount)}
                              </span>
                            </li>
                          ))}
                        </ul>
                      )}
                    </Card>
                  </>
                )}
              </div>
            )}

            {/* ------------------------------------------------ attendance -- */}
            {tab === 'attendance' && (
              <div className="space-y-4">
                {attendance.isLoading && <Card><p className="text-sm text-slate-400">Loading…</p></Card>}
                {attendance.isError && (
                  <Card><p className="text-sm text-danger-600">{(attendance.error as Error).message}</p></Card>
                )}
                {attendance.data && (
                  <>
                    <Card>
                      <div className="flex items-center justify-between">
                        <div>
                          <p className="text-xs uppercase tracking-wide text-slate-500">
                            Last 3 months
                          </p>
                          <p className="mt-1 text-3xl font-semibold tabular-nums text-slate-900">
                            {attendance.data.percent === null ? '-' : `${attendance.data.percent}%`}
                          </p>
                          <p className="mt-1 text-xs text-slate-500">
                            {attendance.data.present} present of {attendance.data.marked} days marked
                          </p>
                        </div>
                        <span
                          className={`flex h-14 w-14 items-center justify-center rounded-2xl text-2xl ${
                            (attendance.data.percent ?? 100) >= 85
                              ? 'bg-money-50 text-money-600'
                              : 'bg-due-50 text-due-600'
                          }`}
                        >
                          <IconAttendance />
                        </span>
                      </div>
                    </Card>

                    <Card>
                      <CardTitle>Day by day</CardTitle>
                      {attendance.data.days.length === 0 ? (
                        <p className="text-sm text-slate-400">No attendance marked in this period.</p>
                      ) : (
                        <ul className="divide-y divide-slate-100">
                          {attendance.data.days.map((d) => {
                            const t = ATT_TONE[d.status] ?? { tone: 'info' as const, label: d.status }
                            return (
                              <li key={d.date} className="flex items-center justify-between py-2.5">
                                <span className="text-sm text-slate-700">{dayLabel(d.date)}</span>
                                <Badge tone={t.tone}>{t.label}</Badge>
                              </li>
                            )
                          })}
                        </ul>
                      )}
                    </Card>
                  </>
                )}
              </div>
            )}

            {/* --------------------------------------------------- results -- */}
            {tab === 'results' && (
              <div className="space-y-4">
                {results.isLoading && <Card><p className="text-sm text-slate-400">Loading…</p></Card>}
                {results.isError && (
                  <Card><p className="text-sm text-danger-600">{(results.error as Error).message}</p></Card>
                )}
                {results.data && results.data.length === 0 && (
                  <Card>
                    <EmptyState
                      icon={<IconExams />}
                      title="No results published yet"
                      message="Results appear here once the school releases them."
                    />
                  </Card>
                )}
                {results.data?.map((r) => (
                  <Card key={r.result_card_id}>
                    <div className="flex flex-wrap items-start justify-between gap-2">
                      <h3 className="text-base font-semibold text-slate-900">{r.term}</h3>
                      <div className="flex items-center gap-2">
                        {r.withheld ? (
                          <Badge tone="due">Withheld</Badge>
                        ) : (
                          <>
                            {/* THE THING A PARENT OPENS THIS FOR, and it was not
                                here. The card has said PASS or FAIL since 0058;
                                the portal showed a percentage and a grade and
                                left the parent to work out whether 41% passes at
                                a school whose threshold is 40 or 50. */}
                            {r.result === 'PASS' && <Badge tone="money">Passed</Badge>}
                            {r.result === 'FAIL' && <Badge tone="due">Not passed</Badge>}
                            {r.result === 'PENDING' && <Badge tone="info">Not marked yet</Badge>}
                            {/* Labelled, because "8.5" on its own means nothing
                                to a parent. Under letters the label is dropped:
                                "A+" needs no explaining and "Grade A+" on a
                                phone badge is two words of noise. */}
                            <Badge tone="money">
                              {r.grade_scale === 'gpa10' ? `GPA ${r.grade ?? '-'}` : (r.grade ?? '-')}
                            </Badge>
                          </>
                        )}
                      </div>
                    </div>

                    {r.withheld ? (
                      <p className="mt-3 rounded-lg bg-due-50 px-3 py-2 text-sm text-due-800 ring-1 ring-due-100">
                        {r.message}
                      </p>
                    ) : (
                      <>
                        {/* A provisional card SAYS it is provisional. Its
                            percentage is computed over the marked papers only, so
                            a parent shown 78% with no warning has been told
                            something that is not the final figure, and the card
                            the school prints carries this line already. */}
                        {r.provisional && (
                          <p className="mt-3 rounded-lg bg-due-50 px-3 py-2 text-xs text-due-800 ring-1 ring-due-100">
                            Not final: {r.unmarked_subjects ?? 0} paper(s) are still
                            being marked. The marks below are out of what has been
                            marked so far.
                          </p>
                        )}

                        <div className="mt-3 grid grid-cols-3 gap-2">
                          <MiniStat
                            label="Marks"
                            value={`${r.obtained_marks ?? '-'}/${r.total_marks ?? '-'}`}
                          />
                          <MiniStat label="Percent" value={`${r.percentage ?? '-'}%`} tone="brand" />
                          <MiniStat label="Position" value={r.position ?? '-'} tone="info" />
                        </div>

                        {(r.pass_percent !== undefined || (r.failed_subjects ?? 0) > 0) && (
                          <p className="mt-2 text-xs text-slate-500">
                            {r.pass_percent !== undefined
                              && `Pass mark at this school is ${r.pass_percent}%.`}
                            {(r.failed_subjects ?? 0) > 0
                              && ` ${r.failed_subjects} subject(s) below the pass mark.`}
                            {r.bise_reg_no && ` Board registration ${r.bise_reg_no}.`}
                          </p>
                        )}

                        {r.subjects && r.subjects.length > 0 && (
                          <ul className="mt-4 divide-y divide-slate-100">
                            {r.subjects.map((s, i) => (
                              <li key={i} className="flex items-start justify-between gap-2 py-2 text-sm">
                                <span className="min-w-0">
                                  <span className="text-slate-700">{s.subject}</span>
                                  {/* Broken out when the paper has one. This was
                                      the real defect: the row showed `marks / max`
                                     : THEORY against the THEORY maximum, so a
                                      pupil with 40/75 theory and 20/25 practical
                                      was shown "40 / 75" when they had scored
                                      60 out of 100. Understated, not merely
                                      incomplete. */}
                                  {s.practical_max > 0 && !s.is_absent && (
                                    <span className="block text-xs text-slate-400">
                                      Written {s.marks ?? '-'}/{s.max} · Practical{' '}
                                      {s.practical ?? '-'}/{s.practical_max}
                                    </span>
                                  )}
                                </span>
                                <span className="shrink-0 text-right tabular-nums">
                                  {s.is_absent ? (
                                    <span className="text-danger-600">Absent</span>
                                  ) : !s.marked ? (
                                    <span className="text-slate-400">not marked</span>
                                  ) : (
                                    <>
                                      <span className="text-slate-700">
                                        {s.obtained ?? '-'} / {s.out_of}
                                      </span>
                                      {s.passed === false && (
                                        <span className="block text-xs text-danger-600">
                                          below {s.pass}
                                        </span>
                                      )}
                                    </>
                                  )}
                                </span>
                              </li>
                            ))}
                          </ul>
                        )}
                      </>
                    )}
                  </Card>
                ))}
              </div>
            )}
          </>
        )}
      </main>

      {/* At the foot, in words rather than behind an icon: the audience for this
          page includes parents who read slowly, and an unlabelled key symbol
          tells them nothing. */}
      <div className="mx-auto flex max-w-3xl flex-wrap items-center justify-center gap-x-4 gap-y-2 px-4 pb-10 text-center">
        <Link to="/password" className="text-xs font-medium text-brand-700 hover:underline">
          Change your password
        </Link>
        {/* Three chapters of the handbook are about this page, and a parent had
            no route to any of them. New tab, so a parent reading it does not
            lose the fee statement they had open. */}
        <a
          href={guideUrl}
          target="_blank"
          rel="noopener"
          className="text-xs font-medium text-brand-700 hover:underline"
        >
          How to use the parent portal
        </a>
      </div>

      {/* Rendered outside <main> so the print rule's absolute positioning starts
          at the top of the sheet rather than inside the page's layout.

          items-start with overflow-y-auto, not items-center: on a 360×640 phone
         , which is most of the parents. A centred dialog taller than the
          viewport puts its own buttons off both edges of the screen with nothing
          to scroll. The statement is long by nature, so this one would always
          have been in that state. */}
      {statement && fees.data && (
        <div
          className="fixed inset-0 z-50 flex items-start justify-center overflow-y-auto bg-black/40 p-3 sm:items-center print:static print:overflow-visible print:bg-white print:p-0"
          role="dialog"
          aria-modal="true"
          aria-label="Fee statement"
        >
          <div className="w-full max-w-2xl rounded-lg bg-white shadow-lg print:max-w-none print:rounded-none print:shadow-none">
            <PortalStatement
              schoolName={me.data?.school_name ?? null}
              parentName={me.data?.full_name ?? null}
              child={activeChild}
              fees={fees.data}
            />
            <div className="flex gap-2 border-t border-slate-200 p-4 print:hidden">
              <button
                onClick={() => window.print()}
                className="flex-1 rounded-lg bg-brand-600 px-3 py-2.5 text-sm font-medium text-white hover:bg-brand-700"
              >
                Print
              </button>
              <button
                onClick={() => setStatement(false)}
                className="flex-1 rounded-lg border border-slate-300 px-3 py-2.5 text-sm hover:bg-slate-50"
              >
                Close
              </button>
            </div>
          </div>
        </div>
      )}
    </div>
  )
}

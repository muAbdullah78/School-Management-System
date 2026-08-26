/**
 * The parent portal.
 *
 * Built phone-first on purpose. Almost every parent will open this on a
 * mid-range Android over a patchy connection, standing somewhere — not at a
 * desk. So: one column, large tap targets, no tables that need horizontal
 * scrolling, and the two things a parent actually opens it for (what do I owe,
 * was my child in school) above the fold.
 *
 * Every read goes through fn_portal_* which resolves the caller's own family
 * server-side. The child switcher below is a convenience, not a permission —
 * passing another family's id gets refused by the database, not by this file.
 */
import { useState } from 'react'
import { useQuery } from '@tanstack/react-query'
import { AnnouncementBanner } from '@/components/AnnouncementBanner'
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

function monthLabel(m: string | null): string {
  if (!m) return 'Other charges'
  const d = new Date(m.length === 10 ? `${m}T00:00:00` : m)
  return isNaN(d.getTime())
    ? '—'
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
  const [tab, setTab] = useState<Tab>('fees')

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
            {/* Child switcher — only when there is more than one */}
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

                    <Card>
                      <CardTitle
                        icon={<IconPrint />}
                        right={
                          <button
                            onClick={() => window.print()}
                            className="text-xs font-medium text-brand-600 hover:underline"
                          >
                            Print
                          </button>
                        }
                      >
                        Your receipts
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
                            {attendance.data.percent === null ? '—' : `${attendance.data.percent}%`}
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
                    <div className="flex items-start justify-between gap-3">
                      <h3 className="text-base font-semibold text-slate-900">{r.term}</h3>
                      {r.withheld ? (
                        <Badge tone="due">Withheld</Badge>
                      ) : (
                        <Badge tone="money">{r.grade ?? '—'}</Badge>
                      )}
                    </div>

                    {r.withheld ? (
                      <p className="mt-3 rounded-lg bg-due-50 px-3 py-2 text-sm text-due-800 ring-1 ring-due-100">
                        {r.message}
                      </p>
                    ) : (
                      <>
                        <div className="mt-3 grid grid-cols-3 gap-2">
                          <MiniStat
                            label="Marks"
                            value={`${r.obtained_marks ?? '—'}/${r.total_marks ?? '—'}`}
                          />
                          <MiniStat label="Percent" value={`${r.percentage ?? '—'}%`} tone="brand" />
                          <MiniStat label="Position" value={r.position ?? '—'} tone="info" />
                        </div>

                        {r.subjects && r.subjects.length > 0 && (
                          <ul className="mt-4 divide-y divide-slate-100">
                            {r.subjects.map((s, i) => (
                              <li key={i} className="flex items-center justify-between py-2 text-sm">
                                <span className="text-slate-700">{s.subject}</span>
                                <span className="tabular-nums text-slate-600">
                                  {s.is_absent ? (
                                    <span className="text-danger-600">Absent</span>
                                  ) : (
                                    `${s.marks ?? '—'} / ${s.max}`
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
    </div>
  )
}

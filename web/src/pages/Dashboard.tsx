import { Link } from 'react-router-dom'
import { useQuery } from '@tanstack/react-query'
import { useAuth } from '@/auth/AuthProvider'
import { ROLE_LABELS, isTeacher } from '@/auth/roles'
import { MyClass } from './MyClass'
import { getDashboardSummary } from '@/lib/db'
import { isConfigured } from '@/lib/config'
import { fmtPKR } from '@/lib/format'
import { Card, CardTitle, StatTile, PageHeader, EmptyState, Badge } from '@/components/ui'
import {
  IconAttendance,
  IconStudents,
  IconWallet,
  IconAlert,
  IconFees,
  IconAdmissions,
  IconChevron,
  IconDashboard,
} from '@/components/icons'

/** A stat tile that navigates. Wrapping keeps the hover affordance in one place. */
function LinkTile({ to, children }: { to: string; children: React.ReactNode }) {
  return (
    <Link to={to} className="block transition hover:-translate-y-0.5 hover:shadow-pop">
      {children}
    </Link>
  )
}

function QuickAction({
  to,
  label,
  hint,
  icon,
}: {
  to: string
  label: string
  hint: string
  icon: React.ReactNode
}) {
  return (
    <Link
      to={to}
      className="group flex items-center gap-3 rounded-xl border border-slate-200 bg-white p-3 transition hover:border-brand-300 hover:bg-brand-50/40"
    >
      <span className="flex h-9 w-9 shrink-0 items-center justify-center rounded-lg bg-brand-50 text-brand-600 ring-1 ring-brand-100">
        {icon}
      </span>
      <span className="min-w-0 flex-1">
        <span className="block text-sm font-medium text-slate-800">{label}</span>
        <span className="block truncate text-xs text-slate-500">{hint}</span>
      </span>
      <span className="text-slate-300 transition group-hover:translate-x-0.5 group-hover:text-brand-500">
        <IconChevron />
      </span>
    </Link>
  )
}

export function Dashboard() {
  const { profile } = useAuth()
  const configured = isConfigured
  const isTeach = isTeacher(profile?.role)
  const summary = useQuery({
    queryKey: ['dashboardSummary'],
    queryFn: getDashboardSummary,
    enabled: configured && !isTeach,
  })

  // Teachers get a class-focused home instead of the admin dashboard.
  if (isTeach) return <MyClass />

  const d = summary.data
  const att = d?.attendance
  const pct = att && att.marked > 0 ? Math.round(((att.present + att.half_day) / att.marked) * 100) : null
  const loading = summary.isLoading

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

          {/* Two setup problems that otherwise show up only as numbers that look
              fine. Both are actionable, so both name the screen to go to. */}
          {d && !d.session_set && (
            <div className="mb-5 flex items-start gap-3 rounded-xl border border-due-200 bg-due-50 p-4 text-sm text-due-800">
              <span className="mt-0.5 text-due-600"><IconAlert /></span>
              <div>
                <p className="font-medium">No academic session is set</p>
                <p className="mt-0.5 text-due-700">
                  Until one is, every figure below reads zero whether or not anything has happened.
                  Set it under <strong>Settings → Sessions</strong>.
                </p>
              </div>
            </div>
          )}

          {d && d.finance_visible && (d.classes_without_fee ?? 0) > 0 && (
            <div className="mb-5 flex items-start gap-3 rounded-xl border border-due-200 bg-due-50 p-4 text-sm text-due-800">
              <span className="mt-0.5 text-due-600"><IconAlert /></span>
              <div>
                <p className="font-medium">
                  {d.classes_without_fee} class{d.classes_without_fee === 1 ? ' has' : 'es have'} students but no fee set
                </p>
                <p className="mt-0.5 text-due-700">
                  Generating challans for them produces Rs 0 slips and reports success, so the school
                  looks billed when it is not. Set the amounts under{' '}
                  <strong>Settings → Fee Structure</strong>.
                </p>
              </div>
            </div>
          )}

          <div className="grid grid-cols-1 gap-4 sm:grid-cols-2 lg:grid-cols-4">
            <LinkTile to="/attendance">
              <StatTile
                tone={pct !== null && pct < 75 ? 'due' : 'info'}
                icon={<IconAttendance />}
                label="Attendance today"
                value={loading ? '…' : att && att.marked > 0 ? `${pct}%` : '—'}
                sub={
                  att && att.marked > 0
                    ? `${att.present + att.half_day} present of ${att.marked} · ${att.absent} absent`
                    : 'Not marked yet today'
                }
              />
            </LinkTile>

            <LinkTile to="/students">
              <StatTile
                tone="brand"
                icon={<IconStudents />}
                label="Active students"
                value={loading ? '…' : String(d?.active_students ?? '—')}
                sub={d ? `${d.new_admissions_month} admitted this month` : undefined}
              />
            </LinkTile>

            {d?.finance_visible && (
              <>
                <LinkTile to="/fees">
                  <StatTile
                    tone="money"
                    icon={<IconWallet />}
                    label="Collected today"
                    value={loading ? '…' : fmtPKR(d?.collected_today)}
                    sub={d ? `${fmtPKR(d.collected_month)} this month` : undefined}
                  />
                </LinkTile>

                <LinkTile to="/fees">
                  {/* "Nothing owed" and "nothing billed" are different facts.
                      This tile used to render the second as the first — Rs 0 in
                      green — so a school that had never generated a challan was
                      told it was fully paid up. */}
                  {d && d.finance_visible && (d.billed_students_month ?? 0) === 0 ? (
                    <StatTile
                      tone="due"
                      icon={<IconAlert />}
                      label="Outstanding"
                      value="Not billed"
                      sub="No challans issued this month"
                    />
                  ) : (
                    <StatTile
                      tone={(d?.outstanding ?? 0) > 0 ? 'due' : 'money'}
                      icon={<IconAlert />}
                      label="Outstanding"
                      value={loading ? '…' : fmtPKR(d?.outstanding)}
                      sub={
                        d
                          ? `${d.defaulters ?? 0} student${d.defaulters === 1 ? '' : 's'} with dues`
                          : undefined
                      }
                    />
                  )}
                </LinkTile>
              </>
            )}
          </div>

          <div className="mt-6 grid grid-cols-1 gap-4 lg:grid-cols-3">
            <Card className="lg:col-span-2">
              <CardTitle icon={<IconChevron />}>Jump straight in</CardTitle>
              <div className="grid grid-cols-1 gap-2 sm:grid-cols-2">
                <QuickAction
                  to="/fees"
                  icon={<IconFees />}
                  label="Collect a fee"
                  hint="Search by father’s CNIC or student name"
                />
                <QuickAction
                  to="/attendance"
                  icon={<IconAttendance />}
                  label="Mark attendance"
                  hint="Today’s register, class by class"
                />
                <QuickAction
                  to="/admissions"
                  icon={<IconAdmissions />}
                  label="Admit a student"
                  hint="New admission with GR number"
                />
                <QuickAction
                  to="/reports"
                  icon={<IconWallet />}
                  label="Day book"
                  hint="What was collected, and by whom"
                />
              </div>
            </Card>

            <Card>
              <CardTitle>At a glance</CardTitle>
              {d ? (
                <dl className="space-y-3 text-sm">
                  <div className="flex items-center justify-between">
                    <dt className="text-slate-500">Marked today</dt>
                    <dd className="font-medium tabular-nums text-slate-800">{att?.marked ?? 0}</dd>
                  </div>
                  <div className="flex items-center justify-between">
                    <dt className="text-slate-500">Absent today</dt>
                    <dd className="font-medium tabular-nums text-slate-800">{att?.absent ?? 0}</dd>
                  </div>
                  <div className="flex items-center justify-between">
                    <dt className="text-slate-500">New this month</dt>
                    <dd className="font-medium tabular-nums text-slate-800">
                      {d.new_admissions_month}
                    </dd>
                  </div>
                  {d.finance_visible ? (
                    <div className="flex items-center justify-between border-t border-slate-100 pt-3">
                      <dt className="text-slate-500">Defaulters</dt>
                      <dd>
                        <Badge tone={(d.defaulters ?? 0) > 0 ? 'due' : 'money'}>
                          {d.defaulters ?? 0}
                        </Badge>
                      </dd>
                    </div>
                  ) : null}
                </dl>
              ) : (
                <p className="text-sm text-slate-400">{loading ? 'Loading…' : 'No figures yet.'}</p>
              )}
            </Card>
          </div>

          {d && !d.finance_visible && (
            <p className="mt-4 text-xs text-slate-400">
              Fee figures are visible to admin and accounts staff.
            </p>
          )}
        </>
      )}
    </div>
  )
}

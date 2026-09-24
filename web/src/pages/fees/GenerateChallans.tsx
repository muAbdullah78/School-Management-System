/**
 * Generate a month's challans, and: new: actually print them.
 *
 * The previous version ended at a count: "40 challans generated", with nothing
 * to hand anybody. That is the whole point of the screen for a Pakistani
 * school; the paper is what the parent takes to the bank. Generating without
 * printing is half a feature, and the half that produces nothing.
 *
 * A month that has already been billed is now printable without re-generating.
 * A clerk reprints constantly. A slip is lost, a parent wants a duplicate, the
 * class teacher never handed them out, and forcing a re-generate to reprint is
 * how duplicate challans get created.
 */
import { useState } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import {
  generateClassInvoices, getCurrentSession, listClasses, listSections,
  listChallanMonths, getClassChallans, getSchoolSettings,
  type Challan,
} from '@/lib/db'
import { monthToDate, fmtPKR } from '@/lib/format'
import { Button, inputClass } from '@/components/ui'
import { ChallanPrint } from './ChallanPrint'

function monthLabel(iso: string): string {
  // UTC, where a plain date has no clock. new Date('2026-09-01') read in a
  // browser west of Greenwich is the evening of 31 August.
  const [y, m] = iso.split('-').map(Number)
  return new Date(Date.UTC(y, m - 1, 1)).toLocaleDateString('en-GB', { month: 'long', year: 'numeric', timeZone: 'UTC' })
}

function karachiMonth(): string {
  const k = new Date(Date.now() + 5 * 60 * 60 * 1000)
  return `${k.getUTCFullYear()}-${String(k.getUTCMonth() + 1).padStart(2, '0')}`
}

/** The school's due day in a given month, the same rule the database uses:
 *  a day past the month's end is its last day. */
function dueDateFor(ym: string, dueDay: number): string {
  const [y, m] = ym.split('-').map(Number)
  const last = new Date(Date.UTC(y, m, 0)).getUTCDate()
  return `${ym}-${String(Math.min(Math.max(dueDay, 1), last)).padStart(2, '0')}`
}

export function GenerateChallans() {
  const qc = useQueryClient()
  const session = useQuery({ queryKey: ['currentSession'], queryFn: getCurrentSession })
  const classes = useQuery({ queryKey: ['classes'], queryFn: listClasses })
  const settings = useQuery({ queryKey: ['schoolSettings'], queryFn: getSchoolSettings })

  const [classId, setClassId] = useState('')
  const [sectionId, setSectionId] = useState('')
  const [month, setMonth] = useState(karachiMonth())
  const [dueDate, setDueDate] = useState('')
  const [sheet, setSheet] = useState<Challan[] | null>(null)
  const [loadingMonth, setLoadingMonth] = useState<string | null>(null)

  const dueDay = Number((settings.data as any)?.due_day ?? 10) || 10
  const due = dueDate || (/^\d{4}-\d{2}$/.test(month) ? dueDateFor(month, dueDay) : '')

  const sections = useQuery({
    queryKey: ['sections', classId],
    queryFn: () => listSections(classId),
    enabled: !!classId,
  })

  // Which months this class has actually been billed for. Offering these
  // instead of a bare month input means the clerk can reprint without guessing,
  // and can see at a glance which month still has money outstanding.
  const months = useQuery({
    queryKey: ['challanMonths', session.data?.id, classId],
    queryFn: () => listChallanMonths(session.data!.id, classId),
    enabled: !!session.data?.id && !!classId,
  })

  const gen = useMutation({
    mutationFn: () => generateClassInvoices(session.data!.id, classId, monthToDate(month), due),
    onSuccess: () => {
      void qc.invalidateQueries({ queryKey: ['challanMonths'] })
      void qc.invalidateQueries({ queryKey: ['billingCalendar'] })
      void qc.invalidateQueries({ queryKey: ['feesMonth'] })
      void qc.invalidateQueries({ queryKey: ['feesMonthPupils'] })
      void qc.invalidateQueries({ queryKey: ['counterSummary'] })
      void qc.invalidateQueries({ queryKey: ['dashboardSummary'] })
    },
  })

  const load = useMutation({
    mutationFn: (periodMonth: string) => {
      setLoadingMonth(periodMonth)
      return getClassChallans(session.data!.id, classId, sectionId || null, periodMonth)
    },
    onSuccess: (rows) => setSheet(rows),
    onSettled: () => setLoadingMonth(null),
  })

  const ready = !!session.data && !!classId && /^\d{4}-\d{2}$/.test(month) && !!due
  const school = {
    name: settings.data?.name ?? 'School',
    address: settings.data?.address ?? null,
    phone: settings.data?.phone ?? null,
  }

  return (
    <div className="rounded-2xl border border-slate-200 bg-white p-4 shadow-card">
      <h2 className="text-sm font-semibold text-slate-900">Print challans</h2>
      <p className="mt-0.5 text-sm text-slate-500">
        Three copies per sheet (bank, school and parent) with the challan code on each, so any copy
        can be scanned at the counter. Reprinting never creates a new challan.
      </p>

      {!session.data && !session.isLoading && (
        <p className="mt-3 rounded-xl border border-due-200 bg-due-50 p-3 text-sm text-due-800">
          No current academic session is set. Create one in Settings first.
        </p>
      )}

      <div className="mt-3 grid gap-3 sm:grid-cols-2">
        <label className="block">
          <span className="text-sm text-slate-600">Class</span>
          <select value={classId} onChange={(e) => { setClassId(e.target.value); setSectionId('') }} className={`${inputClass} mt-1`}>
            <option value="">Select class…</option>
            {classes.data?.map((c) => <option key={c.id} value={c.id}>{c.name}</option>)}
          </select>
        </label>
        {(sections.data?.length ?? 0) > 0 && (
          <label className="block">
            <span className="text-sm text-slate-600">Section</span>
            <select value={sectionId} onChange={(e) => setSectionId(e.target.value)} className={`${inputClass} mt-1`}>
              <option value="">Whole class</option>
              {sections.data?.map((s) => <option key={s.id} value={s.id}>{s.name}</option>)}
            </select>
          </label>
        )}
      </div>

      {classId && (
        <div className="mt-4">
          {months.isLoading && <p className="text-sm text-slate-400">Checking…</p>}
          {months.isError && <p className="text-sm text-danger-600">{(months.error as Error).message}</p>}
          {months.data?.length === 0 && (
            <p className="text-sm text-slate-500">
              Nothing billed for this class yet. Months are raised by themselves on the billing day, or by
              hand below.
            </p>
          )}
          {(months.data?.length ?? 0) > 0 && (
            <ul className="grid gap-2 sm:grid-cols-2 lg:grid-cols-3">
              {months.data?.map((m) => {
                const paid = Math.max(m.challans - m.unpaid, 0)
                return (
                  <li key={m.period_month} className="rounded-xl border border-slate-200 p-3">
                    <div className="flex items-center justify-between gap-2">
                      <div className="min-w-0">
                        <div className="text-sm font-medium text-slate-800">{monthLabel(m.period_month)}</div>
                        <div className="text-xs text-slate-500">
                          {m.challans} challan{m.challans === 1 ? '' : 's'} · {m.unpaid > 0 ? `${m.unpaid} unpaid` : 'all paid'}
                        </div>
                      </div>
                      <Button size="sm" variant="soft" tone="neutral"
                        onClick={() => load.mutate(m.period_month)} disabled={load.isPending}>
                        {loadingMonth === m.period_month ? 'Loading…' : 'Print'}
                      </Button>
                    </div>
                    <div className="mt-2 flex h-1.5 overflow-hidden rounded-full bg-slate-100" style={{ gap: 2 }} aria-hidden>
                      {paid > 0 && <div className="h-full bg-money-500" style={{ flexGrow: paid, flexBasis: 0 }} />}
                      {m.unpaid > 0 && <div className="h-full bg-due-500" style={{ flexGrow: m.unpaid, flexBasis: 0 }} />}
                    </div>
                  </li>
                )
              })}
            </ul>
          )}
          {load.isError && <p className="mt-2 text-sm text-danger-600">{(load.error as Error).message}</p>}
        </div>
      )}

      <p className="mt-4 text-xs text-slate-500">
        Each challan is the class&rsquo;s fee minus the child&rsquo;s approved discounts. Previous dues are worked
        out fresh at print time rather than from the figure stored when the challan was made, so a parent who has
        paid since is not asked twice.
      </p>

      {/* ------------------------------------------------- by hand, rarely -- */}
      {/* A SECOND WAY TO BILL, AND IT IS KEPT OUT OF THE WAY ON PURPOSE. Since
          0139 every month raises itself on the billing day for the whole roll.
          This form used to sit open beside the print list with a blank due
          date, so a clerk could raise one class with a due date nobody else's
          challan had. It now opens on request and starts from the school's
          own due day. */}
      <details className="mt-4 rounded-xl border border-slate-200 bg-slate-50 p-3">
        <summary className="cursor-pointer text-sm font-medium text-slate-700">
          Charge one class for a month by hand
        </summary>
        <p className="mt-2 text-xs text-slate-500">
          Rarely needed: the whole school is charged on the billing day by itself. Use this for one class that
          was missed, for example a class whose fee was set after the month was raised. Children already
          charged for that month are skipped, so running it twice is safe.
        </p>
        <form
          className="mt-3 grid gap-3 sm:grid-cols-3"
          onSubmit={(e) => { e.preventDefault(); if (ready) gen.mutate() }}
        >
          <label className="block">
            <span className="text-sm text-slate-600">Month</span>
            <input type="month" value={month} onChange={(e) => { setMonth(e.target.value); setDueDate('') }} className={`${inputClass} mt-1`} />
          </label>
          <label className="block">
            <span className="text-sm text-slate-600">Due date</span>
            <input type="date" value={due} min={/^\d{4}-\d{2}$/.test(month) ? `${month}-01` : undefined}
              onChange={(e) => setDueDate(e.target.value)} className={`${inputClass} mt-1`} />
            {!dueDate && <span className="mt-1 block text-xs text-slate-400">The school&rsquo;s due day, the {dueDay}.</span>}
          </label>
          <div className="flex items-end">
            <Button type="submit" className="w-full" disabled={!ready || gen.isPending}>
              {gen.isPending ? 'Charging…' : classId ? 'Charge this class' : 'Pick a class above'}
            </Button>
          </div>
        </form>
        {gen.isError && <p className="mt-2 text-sm text-danger-600">{(gen.error as Error).message}</p>}
        {gen.isSuccess && (
          <p className="mt-2 rounded-lg bg-brand-50 p-2.5 text-sm text-brand-800">
            {gen.data} challan{gen.data === 1 ? '' : 's'} raised for {monthLabel(`${month}-01`)}. They are in the
            list above to print.
          </p>
        )}
      </details>

      {sheet && (
        <>
          {sheet.length === 0 ? (
            <div className="fixed inset-0 z-50 flex items-center justify-center bg-slate-900/40 p-4">
              <div className="max-w-sm rounded-lg bg-white p-4 text-sm text-slate-700 shadow">
                No challans to print for that month and section.
                <button
                  onClick={() => setSheet(null)}
                  className="mt-3 block rounded border border-slate-300 px-3 py-1.5 text-xs font-medium text-slate-700 hover:bg-slate-50"
                >
                  Close
                </button>
              </div>
            </div>
          ) : (
            <ChallanPrint challans={sheet} school={school} onClose={() => setSheet(null)} />
          )}
        </>
      )}

      {/* A quiet reconciliation aid: the total the printed stack is asking for. */}
      {sheet && sheet.length > 0 && (
        <p className="mt-2 text-xs text-slate-500 print:hidden">
          This batch asks for {fmtPKR(sheet.reduce((t, c) => t + c.total_payable, 0))} in total.
        </p>
      )}
    </div>
  )
}

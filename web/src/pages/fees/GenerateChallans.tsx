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
import { ChallanPrint } from './ChallanPrint'

const FIELD =
  'mt-1 w-full rounded border border-slate-300 px-3 py-2 text-sm focus:border-brand-500 focus:outline-none'

export function GenerateChallans() {
  const qc = useQueryClient()
  const session = useQuery({ queryKey: ['currentSession'], queryFn: getCurrentSession })
  const classes = useQuery({ queryKey: ['classes'], queryFn: listClasses })
  const settings = useQuery({ queryKey: ['schoolSettings'], queryFn: getSchoolSettings })

  const [classId, setClassId] = useState('')
  const [sectionId, setSectionId] = useState('')
  const [month, setMonth] = useState('')
  const [dueDate, setDueDate] = useState('')
  const [sheet, setSheet] = useState<Challan[] | null>(null)

  const sections = useQuery({
    queryKey: ['sections', classId],
    queryFn: () => listSections(classId),
    enabled: !!classId,
  })

  // Which months this class has actually been billed for. Offering these
  // instead of a bare month input means the clerk can reprint without guessing
  //, and can see at a glance which month still has money outstanding.
  const months = useQuery({
    queryKey: ['challanMonths', session.data?.id, classId],
    queryFn: () => listChallanMonths(session.data!.id, classId),
    enabled: !!session.data?.id && !!classId,
  })

  const gen = useMutation({
    mutationFn: () => generateClassInvoices(session.data!.id, classId, monthToDate(month), dueDate),
    onSuccess: () => {
      void qc.invalidateQueries({ queryKey: ['challanMonths'] })
      void qc.invalidateQueries({ queryKey: ['counterSummary'] })
      void qc.invalidateQueries({ queryKey: ['dashboardSummary'] })
    },
  })

  const load = useMutation({
    mutationFn: (periodMonth: string) =>
      getClassChallans(session.data!.id, classId, sectionId || null, periodMonth),
    onSuccess: (rows) => setSheet(rows),
  })

  const ready = !!session.data && !!classId && /^\d{4}-\d{2}$/.test(month) && !!dueDate
  const school = {
    name: settings.data?.name ?? 'School',
    address: settings.data?.address ?? null,
    phone: settings.data?.phone ?? null,
  }

  return (
    <div className="max-w-3xl">
      {!session.data && !session.isLoading && (
        <p className="mb-3 rounded bg-amber-50 p-3 text-sm text-amber-700">
          No current academic session is set. Create one in Settings first.
        </p>
      )}

      <div className="grid gap-4 sm:grid-cols-2">
        {/* ------------------------------------------------------- generate -- */}
        <form
          className="space-y-3 rounded-lg border border-slate-200 bg-white p-4"
          onSubmit={(e) => {
            e.preventDefault()
            if (ready) gen.mutate()
          }}
        >
          <h3 className="text-sm font-semibold text-slate-800">Generate a month</h3>

          <label className="block">
            <span className="text-sm text-slate-600">Class</span>
            <select value={classId} onChange={(e) => { setClassId(e.target.value); setSectionId('') }} className={FIELD}>
              <option value="">Select class…</option>
              {classes.data?.map((c) => <option key={c.id} value={c.id}>{c.name}</option>)}
            </select>
          </label>

          <label className="block">
            <span className="text-sm text-slate-600">Month</span>
            <input type="month" value={month} onChange={(e) => setMonth(e.target.value)} className={FIELD} />
          </label>

          <label className="block">
            <span className="text-sm text-slate-600">Due date</span>
            <input type="date" value={dueDate} onChange={(e) => setDueDate(e.target.value)} className={FIELD} />
          </label>

          {gen.isError && <p className="text-sm text-red-600">{(gen.error as Error).message}</p>}
          {gen.isSuccess && (
            <p className="rounded bg-emerald-50 p-3 text-sm text-emerald-700">
              {gen.data} challan{gen.data === 1 ? '' : 's'} generated. Print them from the right &rarr;
              <span className="mt-1 block text-xs text-emerald-600">
                Students already billed for this month were skipped, so re-running is safe.
              </span>
            </p>
          )}

          <button
            type="submit"
            disabled={!ready || gen.isPending}
            className="rounded bg-brand-600 px-4 py-2 text-sm font-medium text-white hover:bg-brand-700 disabled:opacity-60"
          >
            {gen.isPending ? 'Generating…' : 'Generate monthly challans'}
          </button>
        </form>

        {/* ---------------------------------------------------------- print -- */}
        <div className="space-y-3 rounded-lg border border-slate-200 bg-white p-4">
          <h3 className="text-sm font-semibold text-slate-800">Print challans</h3>

          {!classId && <p className="text-sm text-slate-400">Pick a class on the left first.</p>}

          {classId && (
            <>
              {(sections.data?.length ?? 0) > 0 && (
                <label className="block">
                  <span className="text-sm text-slate-600">
                    Section <span className="text-slate-400">(all, unless you pick one)</span>
                  </span>
                  <select value={sectionId} onChange={(e) => setSectionId(e.target.value)} className={FIELD}>
                    <option value="">Whole class</option>
                    {sections.data?.map((s) => <option key={s.id} value={s.id}>{s.name}</option>)}
                  </select>
                </label>
              )}

              {months.isLoading && <p className="text-sm text-slate-400">Checking…</p>}
              {months.data?.length === 0 && (
                <p className="text-sm text-slate-400">
                  Nothing billed for this class yet. Generate a month first.
                </p>
              )}

              {(months.data?.length ?? 0) > 0 && (
                <ul className="divide-y divide-slate-100 overflow-hidden rounded border border-slate-200">
                  {months.data?.map((m) => (
                    <li key={m.period_month} className="flex items-center justify-between gap-2 px-3 py-2">
                      <div className="min-w-0">
                        <div className="text-sm text-slate-800">
                          {new Date(m.period_month).toLocaleDateString('en-GB', {
                            month: 'long', year: 'numeric',
                          })}
                        </div>
                        <div className="text-xs text-slate-500">
                          {m.challans} challan{m.challans === 1 ? '' : 's'}
                          {m.unpaid > 0
                            ? ` · ${m.unpaid} still unpaid`
                            : ' · all paid'}
                        </div>
                      </div>
                      <button
                        onClick={() => load.mutate(m.period_month)}
                        disabled={load.isPending}
                        className="shrink-0 rounded border border-slate-300 px-3 py-1.5 text-xs font-medium text-slate-700 hover:bg-slate-50 disabled:opacity-60"
                      >
                        {load.isPending ? 'Loading…' : 'Print'}
                      </button>
                    </li>
                  ))}
                </ul>
              )}

              {load.isError && <p className="text-sm text-red-600">{(load.error as Error).message}</p>}
            </>
          )}

          <p className="text-xs text-slate-500">
            Three copies per sheet (bank, school and parent) with the challan code on each, so any copy
            can be scanned at the counter. Reprinting never creates a new challan.
          </p>
        </div>
      </div>

      <p className="mt-4 text-xs text-slate-500">
        Each challan is the class&rsquo;s recurring fee heads minus approved discounts. Previous dues are
        worked out fresh at print time rather than from the figure stored when the challan was made, so a
        parent who has paid since is not asked twice.
      </p>

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

      {/* A quiet reconciliation aid: the total the printed stack is asking for.
          A clerk who knows the batch is worth Rs 48,000 can sanity-check the
          day's collection against it. */}
      {sheet && sheet.length > 0 && (
        <p className="mt-2 text-xs text-slate-500 print:hidden">
          This batch asks for {fmtPKR(sheet.reduce((t, c) => t + c.total_payable, 0))} in total.
        </p>
      )}
    </div>
  )
}

/**
 * Collecting a class's fees in one pass.
 *
 * A Pakistani school takes 100-400 payments in the first ten days of a month.
 * Before this screen every one of them meant a separate search: type a name,
 * wait, pick the family, enter an amount, submit, start again.
 *
 * DESIGN DECISIONS THAT MATTER HERE
 *
 * The list shows the WHOLE class, including children who have already paid. A
 * clerk working down a register needs to see "Ahmed: paid" to know they have
 * not skipped him; a list that hides the paid students is how a child gets
 * chased for money they handed over yesterday.
 *
 * Amounts are pre-filled only on request and stay editable, because a parent
 * hands over what they have, not what the challan says.
 *
 * Nothing is submitted per row. One button, one transaction: if any row is bad
 * the whole batch is refused and nothing is written. A half-applied batch of
 * forty is unrecoverable, because the clerk cannot tell which twenty went in.
 *
 * WHAT THE MONTH PICKER DOES AND DOES NOT DO, said on the screen because it was
 * not: it chooses which month's challan the "This month" column reads. The
 * money itself goes to the child's OLDEST unpaid month first, whatever month is
 * picked, the same as at the family counter. A clerk who picked September and
 * expected the money to land on September was told nothing when it paid off
 * June instead.
 *
 * Step 2 of the redraw also: the app's own colours (red is overdue only, so
 * "owes something" is amber), a progress bar for the class, phone cards with
 * a box big enough to type in, a total that stays on screen while scrolling,
 * and a warning when an amount would become an advance.
 */
import { useMemo, useState } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import {
  getCurrentSession, listClasses, listSections,
  getClassDues, recordBulkPayments,
  type ClassDue, type BulkPaymentResult,
} from '@/lib/db'
import { fmtPKR, fmtDate, monthToDate } from '@/lib/format'
import { Button, inputClass } from '@/components/ui'
import { C, StackBar, type Segment } from '@/components/viz'

const METHODS = [
  { value: 'cash', label: 'Cash' },
  { value: 'bank_challan', label: 'Bank challan' },
  { value: 'bank_transfer', label: 'Bank transfer' },
  { value: 'jazzcash', label: 'JazzCash' },
  { value: 'easypaisa', label: 'Easypaisa' },
  { value: 'other', label: 'Other' },
]

function thisMonth(): string {
  // Karachi, not the browser clock: a machine set to UTC is still in the old
  // month for five hours after Pakistan has moved on.
  const k = new Date(Date.now() + 5 * 60 * 60 * 1000)
  return `${k.getUTCFullYear()}-${String(k.getUTCMonth() + 1).padStart(2, '0')}`
}

function monthName(ym: string): string {
  const [y, m] = ym.split('-').map(Number)
  if (!y || !m) return ym
  return new Date(Date.UTC(y, m - 1, 1)).toLocaleDateString('en-GB', { month: 'long', year: 'numeric', timeZone: 'UTC' })
}

/** How one typed amount relates to what the child owes. */
function rowWarning(r: ClassDue, typed: number): string | null {
  if (!Number.isFinite(typed) || typed <= 0) return null
  if (r.total_due <= 0) return 'owes nothing: all of it becomes an advance'
  if (typed > r.total_due) return `more than owed: ${fmtPKR(typed - r.total_due)} becomes an advance`
  return null
}

export function BulkCollect() {
  const qc = useQueryClient()
  const session = useQuery({ queryKey: ['currentSession'], queryFn: getCurrentSession })
  const classes = useQuery({ queryKey: ['classes'], queryFn: listClasses })

  const [classId, setClassId] = useState('')
  const [sectionId, setSectionId] = useState('')
  const [month, setMonth] = useState(thisMonth())
  const [method, setMethod] = useState('cash')
  const [amounts, setAmounts] = useState<Record<string, string>>({})
  const [result, setResult] = useState<BulkPaymentResult | null>(null)

  const sections = useQuery({
    queryKey: ['sections', classId],
    queryFn: () => listSections(classId),
    enabled: !!classId,
  })

  const monthISO = /^\d{4}-\d{2}$/.test(month) ? monthToDate(month) : ''
  const ready = !!session.data?.id && !!classId && !!monthISO

  const dues = useQuery({
    queryKey: ['classDues', session.data?.id, classId, sectionId, monthISO],
    queryFn: () => getClassDues(session.data!.id, classId, sectionId || null, monthISO),
    enabled: ready,
  })

  const rows = dues.data ?? []

  // Only rows the clerk has actually typed an amount into are submitted. There
  // is deliberately no "select all and pay everything": that would let one
  // keystroke issue forty receipts for money nobody handed over.
  const batch = useMemo(
    () =>
      rows
        .map((r) => ({ student_id: r.student_id, amount: Number(amounts[r.student_id] ?? '') }))
        .filter((r) => Number.isFinite(r.amount) && r.amount > 0),
    [rows, amounts],
  )
  const batchTotal = batch.reduce((t, r) => t + r.amount, 0)
  const advances = rows.filter((r) => rowWarning(r, Number(amounts[r.student_id] ?? '')) != null).length

  const pay = useMutation({
    mutationFn: () => recordBulkPayments(batch, method, `Bulk · ${month}`),
    onSuccess: (r) => {
      setResult(r)
      setAmounts({})
      void qc.invalidateQueries({ queryKey: ['classDues'] })
      void qc.invalidateQueries({ queryKey: ['counterSummary'] })
      void qc.invalidateQueries({ queryKey: ['recentPayments'] })
      void qc.invalidateQueries({ queryKey: ['dashboardSummary'] })
      // The rest of Fees reads the same money.
      void qc.invalidateQueries({ queryKey: ['feesMonth'] })
      void qc.invalidateQueries({ queryKey: ['feesMonthPupils'] })
      void qc.invalidateQueries({ queryKey: ['feesToday'] })
      void qc.invalidateQueries({ queryKey: ['arrears'] })
      void qc.invalidateQueries({ queryKey: ['familySheet'] })
      void qc.invalidateQueries({ queryKey: ['pendingPayments'] })
    },
  })

  function fillDue() {
    const next: Record<string, string> = {}
    for (const r of rows) if (r.month_due > 0) next[r.student_id] = String(r.month_due)
    setAmounts(next)
    setResult(null)
  }
  function fillTotal() {
    const next: Record<string, string> = {}
    for (const r of rows) if (r.total_due > 0) next[r.student_id] = String(r.total_due)
    setAmounts(next)
    setResult(null)
  }
  const setOne = (id: string, v: string) => {
    setAmounts((p) => ({ ...p, [id]: v.replace(/[^\d.]/g, '') }))
    setResult(null)
  }

  // The class against this month's challan, in children.
  const paidMonth = rows.filter((r) => r.month_charge > 0 && r.month_due <= 0).length
  const partMonth = rows.filter((r) => r.month_charge > 0 && r.month_due > 0 && r.month_paid > 0).length
  const unpaidMonth = rows.filter((r) => r.month_charge > 0 && r.month_due > 0 && r.month_paid <= 0).length
  const noChallan = rows.filter((r) => r.month_charge === 0).length
  const parts: Segment[] = [
    { key: 'paid', label: 'Paid', value: paidMonth, color: C.good },
    { key: 'part', label: 'Part paid', value: partMonth, color: C.warn },
    { key: 'unpaid', label: 'Not paid', value: unpaidMonth, color: C.bad },
    { key: 'none', label: 'No challan', value: noChallan, color: C.none },
  ]
  const owing = rows.filter((r) => r.total_due > 0).length
  const owedTotal = rows.reduce((a, r) => a + Math.max(r.total_due, 0), 0)

  return (
    <div>
      {!session.data && !session.isLoading && (
        <p className="mb-3 rounded-xl border border-due-200 bg-due-50 p-3 text-sm text-due-800">
          No current academic session is set. Create one in Settings first.
        </p>
      )}

      <div className="grid grid-cols-2 gap-3 lg:grid-cols-4">
        <label className="block">
          <span className="text-sm text-slate-600">Class</span>
          <select
            value={classId}
            onChange={(e) => { setClassId(e.target.value); setSectionId(''); setAmounts({}); setResult(null) }}
            className={`${inputClass} mt-1`}
          >
            <option value="">Select class…</option>
            {classes.data?.map((c) => <option key={c.id} value={c.id}>{c.name}</option>)}
          </select>
        </label>
        <label className="block">
          <span className="text-sm text-slate-600">Section</span>
          <select
            value={sectionId}
            onChange={(e) => { setSectionId(e.target.value); setAmounts({}); setResult(null) }}
            className={`${inputClass} mt-1`}
            disabled={!classId}
          >
            <option value="">Whole class</option>
            {sections.data?.map((s) => <option key={s.id} value={s.id}>{s.name}</option>)}
          </select>
        </label>
        <label className="block">
          <span className="text-sm text-slate-600">Month shown</span>
          <input type="month" value={month} onChange={(e) => { setMonth(e.target.value); setAmounts({}); setResult(null) }}
            className={`${inputClass} mt-1`} />
        </label>
        <label className="block">
          <span className="text-sm text-slate-600">Paid by</span>
          <select value={method} onChange={(e) => setMethod(e.target.value)} className={`${inputClass} mt-1`}>
            {METHODS.map((m) => <option key={m.value} value={m.value}>{m.label}</option>)}
          </select>
        </label>
      </div>
      <p className="mt-2 text-xs text-slate-500">
        The month only chooses which challan the &ldquo;This month&rdquo; column shows. Money always goes to the
        child&rsquo;s oldest unpaid month first, as it does at the counter, and anything over what they owe is
        kept as an advance for the family.
      </p>

      {!classId && (
        <p className="mt-5 rounded-xl border border-dashed border-slate-300 bg-white px-4 py-6 text-center text-sm text-slate-500">
          Pick a class to load its register.
        </p>
      )}

      {ready && dues.isLoading && <p className="mt-5 text-sm text-slate-400">Loading the class…</p>}
      {dues.isError && <p className="mt-5 text-sm text-danger-600">{(dues.error as Error).message}</p>}

      {ready && rows.length === 0 && !dues.isLoading && !dues.isError && (
        <p className="mt-5 rounded-xl bg-slate-50 p-3 text-sm text-slate-600">
          No active students in this class for the current session.
        </p>
      )}

      {rows.length > 0 && (
        <>
          {/* ------------------------------------------------- the class -- */}
          <div className="mt-5 rounded-2xl border border-slate-200 bg-white p-4 shadow-card">
            <div className="flex flex-wrap items-baseline justify-between gap-2">
              <h3 className="text-sm font-semibold text-slate-900">{monthName(month)}, this class</h3>
              <p className="text-sm text-slate-600">
                <b className="font-semibold tabular-nums text-due-800">{owing}</b> of {rows.length} still owe something,
                {' '}<b className="font-semibold tabular-nums text-slate-900">{fmtPKR(owedTotal)}</b> between them
              </p>
            </div>
            <div className="mt-3">
              <StackBar parts={parts} total={rows.length} height={10}
                label={`This class for ${monthName(month)}: ${parts.map((p) => `${p.label} ${p.value}`).join(', ')}`} />
            </div>
            <ul className="mt-2 flex flex-wrap gap-x-4 gap-y-1 text-xs text-slate-600">
              {parts.map((p) => (
                <li key={p.key} className="inline-flex items-center gap-1.5">
                  <span className="h-2.5 w-2.5 rounded-sm" style={{ background: p.color }} aria-hidden />
                  {p.label} <b className="font-semibold tabular-nums text-slate-900">{p.value}</b>
                </li>
              ))}
            </ul>
          </div>

          <div className="mt-4 flex flex-wrap items-center gap-2">
            <Button size="sm" variant="soft" tone="neutral" onClick={fillDue}>Fill this month&rsquo;s due</Button>
            <Button size="sm" variant="soft" tone="neutral" onClick={fillTotal}>Fill everything owed</Button>
            <Button size="sm" variant="ghost" onClick={() => setAmounts({})}>Clear</Button>
          </div>

          {/* --------------------------------------------- phone: cards -- */}
          <ul className="mt-3 divide-y divide-slate-100 overflow-hidden rounded-2xl border border-slate-200 bg-white sm:hidden">
            {rows.map((r) => {
              const v = amounts[r.student_id] ?? ''
              const warn = rowWarning(r, Number(v))
              return (
                <li key={r.student_id} className={`px-3 py-2.5 ${r.total_due <= 0 ? 'bg-slate-50/60' : ''}`}>
                  <div className="flex items-start gap-3">
                    <div className="min-w-0 flex-1">
                      <div className="truncate text-sm font-medium text-slate-800">
                        <span className="mr-1.5 text-xs tabular-nums text-slate-400">{r.roll_no ?? '-'}</span>
                        {r.full_name}
                      </div>
                      <div className="mt-0.5 text-xs"><MonthCell r={r} /> <span className="text-slate-300">·</span> <OwedCell r={r} /></div>
                    </div>
                    <input
                      inputMode="decimal" value={v} placeholder="Rs"
                      onChange={(e) => setOne(r.student_id, e.target.value)}
                      aria-label={`Amount from ${r.full_name}`}
                      className={`w-28 shrink-0 rounded-lg border px-2.5 py-2 text-right text-base tabular-nums focus:outline-none ${warn ? 'border-info-300 bg-info-50' : 'border-slate-300 focus:border-brand-500'}`}
                    />
                  </div>
                  {warn && <p className="mt-1 text-right text-[11px] text-info-700">{warn}</p>}
                </li>
              )
            })}
          </ul>

          {/* --------------------------------------------- desktop: table -- */}
          <div className="mt-3 hidden overflow-x-auto rounded-2xl border border-slate-200 bg-white shadow-card sm:block">
            <table className="min-w-full text-sm">
              <thead>
                <tr className="border-b border-slate-200 bg-slate-50 text-left text-xs uppercase tracking-wide text-slate-500">
                  <th scope="col" className="px-3 py-2 font-medium">Roll</th>
                  <th scope="col" className="px-3 py-2 font-medium">Student</th>
                  <th scope="col" className="px-3 py-2 font-medium">Father</th>
                  <th scope="col" className="px-3 py-2 text-right font-medium">This month</th>
                  <th scope="col" className="px-3 py-2 text-right font-medium">Total owed</th>
                  <th scope="col" className="px-3 py-2 font-medium">Last paid</th>
                  <th scope="col" className="px-3 py-2 text-right font-medium">Taking now</th>
                </tr>
              </thead>
              <tbody className="divide-y divide-slate-100">
                {rows.map((r) => {
                  const v = amounts[r.student_id] ?? ''
                  const warn = rowWarning(r, Number(v))
                  return (
                    <tr key={r.student_id} className={r.total_due <= 0 ? 'bg-slate-50/60' : 'hover:bg-slate-50/70'}>
                      <td className="whitespace-nowrap px-3 py-1.5 tabular-nums text-slate-500">{r.roll_no ?? '-'}</td>
                      <td className="px-3 py-1.5">
                        <div className="text-slate-800">{r.full_name}</div>
                        {r.gr_no && <div className="text-xs text-slate-400">{r.gr_no}</div>}
                      </td>
                      <td className="px-3 py-1.5 text-slate-600">{r.father_name ?? r.family_head ?? '-'}</td>
                      <td className="whitespace-nowrap px-3 py-1.5 text-right tabular-nums"><MonthCell r={r} /></td>
                      <td className="whitespace-nowrap px-3 py-1.5 text-right tabular-nums"><OwedCell r={r} /></td>
                      <td className="whitespace-nowrap px-3 py-1.5 text-xs text-slate-500">
                        {r.last_paid_at ? fmtDate(r.last_paid_at) : 'never'}
                      </td>
                      <td className="px-3 py-1.5 text-right">
                        <input
                          inputMode="decimal" value={v} placeholder="-"
                          onChange={(e) => setOne(r.student_id, e.target.value)}
                          aria-label={`Amount from ${r.full_name}`}
                          className={`w-28 rounded border px-2 py-1 text-right text-sm tabular-nums focus:outline-none ${warn ? 'border-info-300 bg-info-50' : 'border-slate-300 focus:border-brand-500'}`}
                        />
                        {warn && <div className="mt-0.5 text-[10px] text-info-700">{warn}</div>}
                      </td>
                    </tr>
                  )
                })}
              </tbody>
            </table>
          </div>

          {/* The total stays on screen while scrolling a class of forty. */}
          <div className="sticky bottom-0 z-10 -mx-4 mt-4 border-t border-slate-200 bg-white/95 px-4 py-3 backdrop-blur sm:mx-0 sm:rounded-2xl sm:border sm:shadow-raised">
            <div className="flex flex-wrap items-center gap-3">
              <Button
                tone="money"
                onClick={() => pay.mutate()}
                disabled={batch.length === 0 || pay.isPending}
              >
                {pay.isPending
                  ? 'Recording…'
                  : batch.length === 0
                    ? 'Enter an amount to collect'
                    : `Take ${fmtPKR(batchTotal)} from ${batch.length} student${batch.length === 1 ? '' : 's'}`}
              </Button>
              <span className="text-xs text-slate-500">
                {METHODS.find((m) => m.value === method)?.label ?? method}
                {advances > 0 && <span className="text-info-700"> · {advances} amount{advances === 1 ? '' : 's'} will be kept as advance</span>}
              </span>
            </div>
            {pay.isError && <p className="mt-2 text-sm text-danger-600">{(pay.error as Error).message}</p>}
          </div>

          {result && (
            <div className="mt-3 rounded-2xl border border-money-200 bg-money-50 p-3 text-sm text-money-800">
              <div className="font-medium">
                {result.count} payment{result.count === 1 ? '' : 's'} recorded ·{' '}
                {fmtPKR(result.total)} into the drawer
              </div>
              <div className="mt-1 text-xs text-money-700">
                Receipts{' '}
                {result.receipts
                  .map((x) => (x.receipt_no == null ? '-' : `#${x.receipt_no}`))
                  .join(', ')}
                . Each one is a normal receipt: reprint any of them from the student&rsquo;s profile.
              </div>
            </div>
          )}
        </>
      )}
    </div>
  )
}

function MonthCell({ r }: { r: ClassDue }) {
  // Not the same as "paid". A class with no fee structure produces zero-value
  // challans, and reporting that as settled is how a school ends up believing
  // it has billed when it has not.
  if (r.month_charge === 0) return <span className="text-slate-500">no challan</span>
  if (r.month_due <= 0) return <span className="font-medium text-money-700">paid</span>
  if (r.month_paid > 0) return <span className="text-due-800">{fmtPKR(r.month_due)} left</span>
  return <span className="text-slate-800">{fmtPKR(r.month_due)} due</span>
}

function OwedCell({ r }: { r: ClassDue }) {
  if (r.total_due < 0) return <span className="text-info-700">{fmtPKR(-r.total_due)} advance</span>
  if (r.total_due === 0) return <span className="text-slate-400">owes nothing</span>
  return <span className="font-semibold text-due-800">{fmtPKR(r.total_due)} owed</span>
}

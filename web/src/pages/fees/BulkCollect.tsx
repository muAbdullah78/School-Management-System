/**
 * Collecting a class's fees in one pass.
 *
 * A Pakistani school takes 100–400 payments in the first ten days of a month.
 * Before this screen every one of them meant a separate search: type a name,
 * wait, pick the family, enter an amount, submit, start again. Four hundred
 * searches.
 *
 * DESIGN DECISIONS THAT MATTER HERE
 *
 * The list shows the WHOLE class, including children who have already paid. A
 * clerk working down a register needs to see "Ahmed — paid" to know they have
 * not skipped him; a list that hides the paid students makes that impossible
 * and is how a child gets chased for money they handed over yesterday.
 *
 * Amounts are pre-filled with what is due but stay editable, because a parent
 * hands over what they have, not what the challan says.
 *
 * Nothing is submitted per row. One button, one transaction: if any row is bad
 * the whole batch is refused and nothing is written. A half-applied batch of
 * forty is unrecoverable — the clerk cannot tell which twenty went through.
 */
import { useMemo, useState } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import {
  getCurrentSession, listClasses, listSections,
  getClassDues, recordBulkPayments, queueClassReminders,
  type ClassDue, type BulkPaymentResult,
} from '@/lib/db'
import { fmtPKR, fmtDate, monthToDate } from '@/lib/format'

const FIELD =
  'mt-1 w-full rounded border border-slate-300 px-3 py-2 text-sm focus:border-brand-500 focus:outline-none'

const METHODS = [
  { value: 'cash', label: 'Cash' },
  { value: 'bank_challan', label: 'Bank challan' },
  { value: 'bank_transfer', label: 'Bank transfer' },
  { value: 'jazzcash', label: 'JazzCash' },
  { value: 'easypaisa', label: 'Easypaisa' },
  { value: 'other', label: 'Other' },
]

function thisMonth(): string {
  const d = new Date()
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}`
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
  // is deliberately no "select all and pay everything" — that would let one
  // keystroke issue forty receipts for money nobody handed over.
  const batch = useMemo(
    () =>
      rows
        .map((r) => ({ student_id: r.student_id, amount: Number(amounts[r.student_id] ?? '') }))
        .filter((r) => Number.isFinite(r.amount) && r.amount > 0),
    [rows, amounts],
  )
  const batchTotal = batch.reduce((t, r) => t + r.amount, 0)

  const pay = useMutation({
    mutationFn: () => recordBulkPayments(batch, method, `Bulk · ${month}`),
    onSuccess: (r) => {
      setResult(r)
      setAmounts({})
      void qc.invalidateQueries({ queryKey: ['classDues'] })
      void qc.invalidateQueries({ queryKey: ['counterSummary'] })
      void qc.invalidateQueries({ queryKey: ['recentPayments'] })
      void qc.invalidateQueries({ queryKey: ['dashboardSummary'] })
    },
  })

  const remind = useMutation({
    mutationFn: () => queueClassReminders(session.data!.id, classId, sectionId || null),
    onSuccess: () => void qc.invalidateQueries({ queryKey: ['outbox'] }),
  })

  function fillDue() {
    const next: Record<string, string> = {}
    for (const r of rows) if (r.month_due > 0) next[r.student_id] = String(r.month_due)
    setAmounts(next)
  }
  function fillTotal() {
    const next: Record<string, string> = {}
    for (const r of rows) if (r.total_due > 0) next[r.student_id] = String(r.total_due)
    setAmounts(next)
  }

  const owing = rows.filter((r) => r.total_due > 0).length

  return (
    <div>
      {!session.data && !session.isLoading && (
        <p className="mb-3 rounded bg-amber-50 p-3 text-sm text-amber-700">
          No current academic session is set. Create one in Settings first.
        </p>
      )}

      <div className="grid gap-3 sm:grid-cols-4">
        <label className="block">
          <span className="text-sm text-slate-600">Class</span>
          <select
            value={classId}
            onChange={(e) => { setClassId(e.target.value); setSectionId(''); setAmounts({}); setResult(null) }}
            className={FIELD}
          >
            <option value="">Select class…</option>
            {classes.data?.map((c) => <option key={c.id} value={c.id}>{c.name}</option>)}
          </select>
        </label>
        <label className="block">
          <span className="text-sm text-slate-600">Section</span>
          <select
            value={sectionId}
            onChange={(e) => { setSectionId(e.target.value); setAmounts({}) }}
            className={FIELD}
            disabled={!classId}
          >
            <option value="">Whole class</option>
            {sections.data?.map((s) => <option key={s.id} value={s.id}>{s.name}</option>)}
          </select>
        </label>
        <label className="block">
          <span className="text-sm text-slate-600">Month</span>
          <input type="month" value={month} onChange={(e) => { setMonth(e.target.value); setAmounts({}) }} className={FIELD} />
        </label>
        <label className="block">
          <span className="text-sm text-slate-600">Method</span>
          <select value={method} onChange={(e) => setMethod(e.target.value)} className={FIELD}>
            {METHODS.map((m) => <option key={m.value} value={m.value}>{m.label}</option>)}
          </select>
        </label>
      </div>

      {!classId && (
        <p className="mt-5 text-sm text-slate-500">Pick a class to load the register.</p>
      )}

      {ready && dues.isLoading && <p className="mt-5 text-sm text-slate-400">Loading the class…</p>}
      {dues.isError && <p className="mt-5 text-sm text-red-600">{(dues.error as Error).message}</p>}

      {ready && rows.length === 0 && !dues.isLoading && (
        <p className="mt-5 rounded bg-slate-50 p-3 text-sm text-slate-600">
          No active students in this class for the current session.
        </p>
      )}

      {rows.length > 0 && (
        <>
          <div className="mt-5 flex flex-wrap items-center gap-2">
            <button onClick={fillDue}
              className="rounded border border-slate-300 bg-white px-3 py-1.5 text-xs font-medium text-slate-700 hover:bg-slate-50">
              Fill this month&rsquo;s due
            </button>
            <button onClick={fillTotal}
              className="rounded border border-slate-300 bg-white px-3 py-1.5 text-xs font-medium text-slate-700 hover:bg-slate-50">
              Fill everything owed
            </button>
            <button onClick={() => setAmounts({})}
              className="rounded border border-slate-300 bg-white px-3 py-1.5 text-xs text-slate-600 hover:bg-slate-50">
              Clear
            </button>
            <span className="ml-auto text-xs text-slate-500">
              {owing} of {rows.length} still owe something
            </span>
          </div>

          <div className="mt-3 overflow-x-auto rounded-lg border border-slate-200 bg-white">
            <table className="min-w-full text-sm">
              <thead>
                <tr className="border-b border-slate-200 text-left text-xs uppercase tracking-wide text-slate-500">
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
                {rows.map((r) => (
                  <Row
                    key={r.student_id}
                    r={r}
                    value={amounts[r.student_id] ?? ''}
                    onChange={(v) => setAmounts((p) => ({ ...p, [r.student_id]: v }))}
                  />
                ))}
              </tbody>
            </table>
          </div>

          <div className="mt-4 flex flex-wrap items-center gap-3">
            <button
              onClick={() => pay.mutate()}
              disabled={batch.length === 0 || pay.isPending}
              className="rounded bg-brand-600 px-4 py-2 text-sm font-medium text-white hover:bg-brand-700 disabled:opacity-60"
            >
              {pay.isPending
                ? 'Recording…'
                : batch.length === 0
                  ? 'Enter an amount to collect'
                  : `Take ${fmtPKR(batchTotal)} from ${batch.length} student${batch.length === 1 ? '' : 's'}`}
            </button>

            <button
              onClick={() => remind.mutate()}
              disabled={remind.isPending || owing === 0}
              className="rounded border border-money-300 bg-money-50 px-4 py-2 text-sm font-medium text-money-800 hover:bg-money-100 disabled:opacity-60"
            >
              {remind.isPending ? 'Queueing…' : 'WhatsApp everyone who owes'}
            </button>
          </div>

          {pay.isError && <p className="mt-2 text-sm text-red-600">{(pay.error as Error).message}</p>}

          {result && (
            <div className="mt-3 rounded-lg border border-money-200 bg-money-50 p-3 text-sm text-money-800">
              <div className="font-medium">
                {result.count} payment{result.count === 1 ? '' : 's'} recorded ·{' '}
                {fmtPKR(result.total)} into the drawer
              </div>
              <div className="mt-1 text-xs text-money-700">
                Receipts{' '}
                {result.receipts
                  .map((x) => (x.receipt_no == null ? '—' : `#${x.receipt_no}`))
                  .join(', ')}
                . Each one is a normal receipt — reprint any of them from the student&rsquo;s profile.
              </div>
            </div>
          )}

          {remind.isSuccess && (
            <p className="mt-2 text-sm text-money-700">
              {remind.data.queued} reminder{remind.data.queued === 1 ? '' : 's'} queued
              {remind.data.skipped > 0 ? ` · ${remind.data.skipped} skipped (no number on file)` : ''}
              . Open them under <strong>WhatsApp</strong> and press Send.
            </p>
          )}
          {remind.isError && (
            <p className="mt-2 text-sm text-red-600">{(remind.error as Error).message}</p>
          )}

          <p className="mt-4 text-xs text-slate-500">
            One reminder per family, not per child — a father with three children owing gets a single
            message. Pressing it again later escalates the wording rather than repeating it.
          </p>
        </>
      )}
    </div>
  )
}

function Row({
  r, value, onChange,
}: {
  r: ClassDue
  value: string
  onChange: (v: string) => void
}) {
  const settled = r.total_due <= 0
  const typed = Number(value)
  // Flag an overpayment as it is typed. It is allowed — it becomes family
  // credit — but a clerk who has mistyped 12000 for 1200 should see it before
  // pressing the button, not afterwards in the day book.
  const over = Number.isFinite(typed) && typed > r.total_due && r.total_due > 0

  return (
    <tr className={settled ? 'bg-slate-50/60' : 'hover:bg-slate-50/70'}>
      <td className="whitespace-nowrap px-3 py-1.5 tabular-nums text-slate-500">{r.roll_no ?? '—'}</td>
      <td className="px-3 py-1.5">
        <div className="text-slate-800">{r.full_name}</div>
        {r.gr_no && <div className="text-xs text-slate-400">{r.gr_no}</div>}
      </td>
      <td className="px-3 py-1.5 text-slate-600">{r.father_name ?? r.family_head ?? '—'}</td>
      <td className="whitespace-nowrap px-3 py-1.5 text-right tabular-nums">
        {r.month_charge === 0 ? (
          // Not the same as "paid". A class with no fee structure produces
          // zero-value challans, and reporting that as settled is how a school
          // ends up believing it has billed when it has not.
          <span className="text-xs text-amber-700">not billed</span>
        ) : r.month_due <= 0 ? (
          <span className="text-money-700">paid</span>
        ) : (
          <span className="text-slate-800">{fmtPKR(r.month_due)}</span>
        )}
      </td>
      <td className="whitespace-nowrap px-3 py-1.5 text-right tabular-nums">
        <span className={settled ? 'text-money-700' : 'font-semibold text-danger-600'}>
          {settled ? '—' : fmtPKR(r.total_due)}
        </span>
      </td>
      <td className="whitespace-nowrap px-3 py-1.5 text-xs text-slate-500">
        {r.last_paid_at ? fmtDate(r.last_paid_at) : 'never'}
      </td>
      <td className="px-3 py-1.5 text-right">
        <input
          type="number"
          min="0"
          step="1"
          value={value}
          onChange={(e) => onChange(e.target.value)}
          placeholder="—"
          className={`w-24 rounded border px-2 py-1 text-right text-sm tabular-nums focus:outline-none ${
            over ? 'border-amber-400 bg-amber-50' : 'border-slate-300 focus:border-brand-500'
          }`}
        />
        {over && <div className="mt-0.5 text-[10px] text-amber-700">more than owed</div>}
      </td>
    </tr>
  )
}

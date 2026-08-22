/**
 * The four reports a head teacher asks for at month end.
 *
 * Their Reporting Area lists thirteen; we had five. These are the four that
 * close the gap on the money side — debit & credit statement (which also serves
 * as the detailed income and detailed expense reports via its filter), unpaid
 * invoices per challan, the discount register with its approver, and admissions
 * by date.
 *
 * All four are built on the shared DataTable, so every one of them sorts,
 * searches, exports to CSV and prints without any of that being written four
 * times. That is the payoff for having built the component.
 *
 * The fifth, added after, is the balance sheet — the only one here that is a
 * position AS AT a day rather than a range, and so the only one that is not a
 * table.
 */
import { useMemo, useState } from 'react'
import { useQuery } from '@tanstack/react-query'
import {
  getLedger, getUnpaidInvoices, getDiscountReport, getAdmissionReport,
  getBalanceSheet, getMarkCorrections, getAttendanceCorrections, getCurrentSession,
  type LedgerRow, type UnpaidInvoiceRow, type DiscountReportRow, type AdmissionReportRow,
  type BalanceSheet, type MarkCorrection, type AttendanceCorrection,
} from '@/lib/db'
import { DataTable, type Column } from '@/components/DataTable'
import { fmtPKR, fmtDate } from '@/lib/format'

const FIELD =
  'rounded border border-slate-300 px-2 py-2 text-sm focus:border-brand-500 focus:outline-none'

function monthStart(): string {
  const d = new Date()
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-01`
}
function today(): string {
  return new Date().toISOString().slice(0, 10)
}

/* ============================================================ debit & credit */

export function LedgerReport() {
  const [from, setFrom] = useState(monthStart())
  const [to, setTo] = useState(today())
  const [kind, setKind] = useState<'all' | 'income' | 'expense'>('all')

  const q = useQuery({
    queryKey: ['ledgerReport', from, to, kind],
    queryFn: () => getLedger(from, to, kind),
    enabled: !!from && !!to && from <= to,
  })

  const rows = q.data ?? []
  const debit = rows.reduce((t, r) => t + r.debit, 0)
  const credit = rows.reduce((t, r) => t + r.credit, 0)

  const columns: Column<LedgerRow>[] = [
    {
      key: 'entry_date', header: 'Date', sortable: true,
      value: (r) => r.entry_date,
      render: (r) => <span className="whitespace-nowrap text-slate-600">{fmtDate(r.entry_date)}</span>,
    },
    {
      key: 'category', header: 'Head', sortable: true, value: (r) => r.category,
      render: (r) => (
        <span className={r.kind === 'income' ? 'text-money-700' : 'text-slate-700'}>
          {r.category}
        </span>
      ),
    },
    {
      key: 'particulars', header: 'Particulars', value: (r) => r.particulars,
      render: (r) => (
        <span className="text-slate-700">
          {r.particulars}
          {r.is_reversal && <span className="ml-1 text-xs text-danger-600">(reversed)</span>}
        </span>
      ),
    },
    { key: 'party', header: 'Party', sortable: true, secondary: true, value: (r) => r.party },
    { key: 'reference', header: 'Ref', secondary: true, value: (r) => r.reference },
    {
      key: 'debit', header: 'In', align: 'right', sortable: true, value: (r) => r.debit,
      render: (r) => (r.debit ? <span className="text-money-700">{fmtPKR(r.debit)}</span> : <span className="text-slate-300">—</span>),
    },
    {
      key: 'credit', header: 'Out', align: 'right', sortable: true, value: (r) => r.credit,
      render: (r) => (r.credit ? <span className="text-danger-600">{fmtPKR(r.credit)}</span> : <span className="text-slate-300">—</span>),
    },
    { key: 'recorded_by', header: 'By', secondary: true, value: (r) => r.recorded_by },
  ]

  return (
    <div>
      <div className="mb-3 flex flex-wrap items-end gap-3">
        <label className="block text-sm">
          <span className="text-slate-600">From</span>
          <input type="date" value={from} onChange={(e) => setFrom(e.target.value)} className={`mt-1 block ${FIELD}`} />
        </label>
        <label className="block text-sm">
          <span className="text-slate-600">To</span>
          <input type="date" value={to} onChange={(e) => setTo(e.target.value)} className={`mt-1 block ${FIELD}`} />
        </label>
        <label className="block text-sm">
          <span className="text-slate-600">Show</span>
          <select value={kind} onChange={(e) => setKind(e.target.value as typeof kind)} className={`mt-1 block ${FIELD}`}>
            <option value="all">Everything</option>
            <option value="income">Income only</option>
            <option value="expense">Expenses only</option>
          </select>
        </label>
      </div>

      {from > to && (
        <p className="mb-3 rounded bg-due-50 px-3 py-2 text-sm text-due-800">
          The end date is before the start date.
        </p>
      )}

      <div className="mb-3 flex flex-wrap gap-3 text-sm">
        <span className="rounded bg-money-50 px-2 py-1 font-medium text-money-800">
          In {fmtPKR(debit)}
        </span>
        <span className="rounded bg-danger-50 px-2 py-1 font-medium text-danger-700">
          Out {fmtPKR(credit)}
        </span>
        <span className="rounded bg-slate-100 px-2 py-1 font-medium text-slate-700">
          Net {fmtPKR(debit - credit)}
        </span>
      </div>

      <DataTable
        rows={rows}
        columns={columns}
        rowKey={(r) => `${r.entry_date}-${r.kind}-${r.reference}-${r.particulars}-${r.debit}-${r.credit}`}
        loading={q.isLoading}
        error={q.isError ? (q.error as Error).message : null}
        emptyTitle="Nothing in this period"
        emptyMessage="No receipts, other income or expenses between those dates."
        exportName="debit-credit-statement"
        printId="report"
      />

      <p className="mt-3 text-xs text-slate-500">
        Fee income is read from receipts and cannot be typed in anywhere, which is what makes this
        statement worth trusting. A reversed receipt appears as its own line on the Out side rather
        than being netted away. This nets to the same figure the Accounts screen shows for the same
        dates.
      </p>
    </div>
  )
}

/* ========================================================== unpaid invoices */

export function UnpaidInvoicesReport() {
  const session = useQuery({ queryKey: ['currentSession'], queryFn: getCurrentSession })
  const q = useQuery({
    queryKey: ['unpaidInvoices', session.data?.id],
    queryFn: () => getUnpaidInvoices(session.data!.id),
    enabled: !!session.data?.id,
  })
  const [term, setTerm] = useState('')

  const rows = useMemo(() => {
    const t = term.trim().toLowerCase()
    return (q.data ?? []).filter(
      (r) =>
        !t ||
        r.student_name.toLowerCase().includes(t) ||
        (r.gr_no ?? '').toLowerCase().includes(t) ||
        (r.voucher_code ?? '').toLowerCase().includes(t),
    )
  }, [q.data, term])

  const total = rows.reduce((t, r) => t + r.due, 0)

  const columns: Column<UnpaidInvoiceRow>[] = [
    { key: 'period_label', header: 'Month', sortable: true, value: (r) => r.due_date ?? r.period_label },
    {
      key: 'student_name', header: 'Student', sortable: true, value: (r) => r.student_name,
      render: (r) => (
        <div>
          <div className="text-slate-800">{r.student_name}</div>
          <div className="text-xs text-slate-400">
            {r.gr_no ?? '—'}
            {r.class_name ? ` · ${r.class_name}${r.section_name ? `-${r.section_name}` : ''}` : ''}
          </div>
        </div>
      ),
    },
    { key: 'father_name', header: 'Father', sortable: true, secondary: true, value: (r) => r.father_name },
    {
      key: 'voucher_code', header: 'Challan', secondary: true, value: (r) => r.voucher_code,
      render: (r) => <span className="font-mono text-xs text-slate-500">{r.voucher_code ?? '—'}</span>,
    },
    {
      key: 'days_overdue', header: 'Overdue', align: 'right', sortable: true,
      value: (r) => r.days_overdue,
      render: (r) =>
        r.days_overdue === 0 ? (
          <span className="text-slate-400">not yet</span>
        ) : (
          <span className={r.days_overdue > 30 ? 'font-semibold text-danger-600' : 'text-due-800'}>
            {r.days_overdue}d
          </span>
        ),
    },
    {
      key: 'due', header: 'Due', align: 'right', sortable: true, value: (r) => r.due,
      render: (r) => <span className="font-semibold text-danger-600">{fmtPKR(r.due)}</span>,
    },
  ]

  return (
    <div>
      <div className="mb-3 flex flex-wrap gap-3 text-sm">
        <span className="rounded bg-slate-100 px-2 py-1 text-slate-700">
          {rows.length} unpaid challan{rows.length === 1 ? '' : 's'}
        </span>
        <span className="rounded bg-danger-50 px-2 py-1 font-medium text-danger-700">
          {fmtPKR(total)} outstanding
        </span>
      </div>

      <DataTable
        rows={rows}
        columns={columns}
        rowKey={(r) => r.invoice_id}
        search={term}
        onSearchChange={setTerm}
        searchPlaceholder="Student, GR number or challan code"
        loading={q.isLoading}
        error={q.isError ? (q.error as Error).message : null}
        emptyTitle="Nothing unpaid"
        emptyMessage="Every challan issued this session has been settled."
        exportName="unpaid-invoices"
        printId="report"
      />

      <p className="mt-3 text-xs text-slate-500">
        One row per challan, not per student — so you can see which months are outstanding and which
        slip to reprint. Sort by Overdue to find the ones that have been sitting longest.
      </p>
    </div>
  )
}

/* ================================================================ discounts */

export function DiscountsReport() {
  const q = useQuery({ queryKey: ['discountReport'], queryFn: () => getDiscountReport(null, null) })
  const rows = q.data ?? []

  const columns: Column<DiscountReportRow>[] = [
    {
      key: 'granted_on', header: 'Granted', sortable: true, value: (r) => r.granted_on,
      render: (r) => <span className="whitespace-nowrap text-slate-600">{fmtDate(r.granted_on)}</span>,
    },
    {
      key: 'student_name', header: 'Student', sortable: true, value: (r) => r.student_name,
      render: (r) => (
        <div>
          <div className="text-slate-800">{r.student_name}</div>
          <div className="text-xs text-slate-400">
            {r.gr_no ?? '—'}{r.class_name ? ` · ${r.class_name}` : ''}
          </div>
        </div>
      ),
    },
    { key: 'reason_type', header: 'Type', sortable: true, value: (r) => r.reason_type,
      render: (r) => <span className="capitalize text-slate-700">{r.reason_type.replace('_', ' ')}</span> },
    {
      key: 'amount', header: 'Amount', align: 'right', sortable: true, value: (r) => r.amount,
      render: (r) => (
        <span className="text-slate-800">
          {r.is_percent ? `${r.amount}%` : fmtPKR(r.amount)}
        </span>
      ),
    },
    { key: 'reason', header: 'Reason', secondary: true, value: (r) => r.reason },
    {
      key: 'status', header: 'Status', sortable: true, value: (r) => r.status,
      render: (r) => (
        <span className={r.status === 'approved' ? 'text-money-700' : 'text-due-800'}>
          {r.status}
        </span>
      ),
    },
    { key: 'proposed_by', header: 'Proposed by', secondary: true, value: (r) => r.proposed_by },
    { key: 'approved_by', header: 'Approved by', sortable: true, value: (r) => r.approved_by },
  ]

  return (
    <div>
      <DataTable
        rows={rows}
        columns={columns}
        rowKey={(r) => `${r.student_id}-${r.granted_on}-${r.reason_type}-${r.amount}`}
        loading={q.isLoading}
        error={q.isError ? (q.error as Error).message : null}
        emptyTitle="No discounts"
        emptyMessage="Nothing has been waived or reduced."
        exportName="fee-discounts"
        printId="report"
      />
      <p className="mt-3 text-xs text-slate-500">
        A discount is money the school chose not to collect, so who proposed it and who approved it
        are the columns that matter. Sort by Approved by to see one person&rsquo;s decisions together.
      </p>
    </div>
  )
}

/* =============================================================== admissions */

export function AdmissionsReport() {
  const [from, setFrom] = useState('')
  const [to, setTo] = useState('')
  const q = useQuery({
    queryKey: ['admissionReport', from, to],
    queryFn: () => getAdmissionReport(from || null, to || null),
  })
  const rows = q.data ?? []
  const stillHere = rows.filter((r) => r.status === 'active').length

  const columns: Column<AdmissionReportRow>[] = [
    {
      key: 'admitted_on', header: 'Admitted', sortable: true, value: (r) => r.admitted_on,
      render: (r) => <span className="whitespace-nowrap text-slate-600">{fmtDate(r.admitted_on)}</span>,
    },
    {
      key: 'student_name', header: 'Student', sortable: true, value: (r) => r.student_name,
      render: (r) => (
        <div>
          <div className="text-slate-800">{r.student_name}</div>
          <div className="text-xs text-slate-400">
            {r.gr_no ?? '—'}{r.admission_no ? ` · ${r.admission_no}` : ''}
          </div>
        </div>
      ),
    },
    { key: 'father_name', header: 'Father', sortable: true, value: (r) => r.father_name },
    {
      key: 'class_name', header: 'Class', sortable: true,
      value: (r) => `${r.class_name ?? ''}${r.section_name ?? ''}`,
      render: (r) => (
        <span className="whitespace-nowrap text-slate-600">
          {r.class_name ?? '—'}{r.section_name ? `-${r.section_name}` : ''}
        </span>
      ),
    },
    { key: 'gender', header: 'Gender', secondary: true, sortable: true, value: (r) => r.gender },
    {
      key: 'status', header: 'Still here?', sortable: true, value: (r) => r.status,
      render: (r) =>
        r.status === 'active' ? (
          <span className="text-money-700">yes</span>
        ) : (
          <span className="text-danger-600">{r.status.replace('_', ' ')}</span>
        ),
    },
  ]

  return (
    <div>
      <div className="mb-3 flex flex-wrap items-end gap-3">
        <label className="block text-sm">
          <span className="text-slate-600">From</span>
          <input type="date" value={from} onChange={(e) => setFrom(e.target.value)} className={`mt-1 block ${FIELD}`} />
        </label>
        <label className="block text-sm">
          <span className="text-slate-600">To</span>
          <input type="date" value={to} onChange={(e) => setTo(e.target.value)} className={`mt-1 block ${FIELD}`} />
        </label>
        <span className="ml-auto rounded bg-slate-100 px-2 py-1 text-sm text-slate-700">
          {rows.length} admitted · {stillHere} still here
        </span>
      </div>

      <DataTable
        rows={rows}
        columns={columns}
        rowKey={(r) => r.student_id}
        loading={q.isLoading}
        error={q.isError ? (q.error as Error).message : null}
        emptyTitle="No admissions in this period"
        emptyMessage="Leave both dates blank to see everyone."
        exportName="admissions"
        printId="report"
      />

      <p className="mt-3 text-xs text-slate-500">
        &ldquo;Still here?&rdquo; is the column that makes this more than a headcount: twelve
        admissions with nine already struck off is a different month from twelve that stayed.
      </p>
    </div>
  )
}

/* ============================================================ balance sheet */

/**
 * The one report here that is not a list.
 *
 * Every other tab answers "what happened between two dates" and so renders as
 * rows. This answers "where did the school stand on this day", which is five
 * figures and the relationships between them — so it is laid out as a statement,
 * with the arithmetic shown rather than asserted. A principal who cannot see
 * how a total was reached does not trust the total.
 */
function Figure({ label, value, note, tone = 'plain', big = false }: {
  label: string
  value: string
  note?: string
  tone?: 'plain' | 'good' | 'bad' | 'hold'
  big?: boolean
}) {
  const ring =
    tone === 'good' ? 'border-money-300 bg-money-50'
    : tone === 'bad' ? 'border-danger-200 bg-danger-50'
    : tone === 'hold' ? 'border-amber-300 bg-amber-50'
    : 'border-slate-200 bg-white'
  const text =
    tone === 'good' ? 'text-money-800'
    : tone === 'bad' ? 'text-danger-700'
    : tone === 'hold' ? 'text-amber-800'
    : 'text-slate-800'
  return (
    <div className={`rounded border p-4 ${ring}`}>
      <div className="text-xs uppercase tracking-wide text-slate-500">{label}</div>
      <div className={`mt-1 font-semibold tabular-nums ${text} ${big ? 'text-2xl' : 'text-xl'}`}>
        {value}
      </div>
      {note && <div className="mt-1 text-xs leading-snug text-slate-500">{note}</div>}
    </div>
  )
}

function WorkingRow({ label, value, sign, muted }: {
  label: string; value: number; sign?: '+' | '−'; muted?: boolean
}) {
  return (
    <tr className={muted ? 'text-slate-500' : 'text-slate-700'}>
      <td className="w-6 py-1 text-right align-top text-slate-400">{sign}</td>
      <td className="py-1 pl-2">{label}</td>
      <td className="py-1 pl-4 text-right tabular-nums">{fmtPKR(value)}</td>
    </tr>
  )
}

export function BalanceSheetReport() {
  const [asAt, setAsAt] = useState(today())

  const q = useQuery({
    queryKey: ['balanceSheet', asAt],
    queryFn: () => getBalanceSheet(asAt || null),
    enabled: !!asAt,
  })
  const b = q.data

  if (q.isError) {
    return (
      <div className="rounded border border-danger-200 bg-danger-50 p-4 text-sm text-danger-700">
        {(q.error as Error).message}
      </div>
    )
  }

  return (
    <div>
      <div className="mb-4 flex flex-wrap items-end gap-3 print:hidden">
        <label className="block text-sm">
          <span className="text-slate-600">As at</span>
          <input type="date" value={asAt} onChange={(e) => setAsAt(e.target.value)}
            className={`mt-1 block ${FIELD}`} />
        </label>
        <div className="flex gap-2">
          <button type="button" onClick={() => setAsAt(today())}
            className="rounded border border-slate-300 px-3 py-2 text-sm text-slate-600 hover:bg-slate-50">
            Today
          </button>
          <button type="button" onClick={() => setAsAt(lastDayOfPrevMonth())}
            className="rounded border border-slate-300 px-3 py-2 text-sm text-slate-600 hover:bg-slate-50">
            End of last month
          </button>
          <button type="button" onClick={() => setAsAt(lastDayOfJune())}
            className="rounded border border-slate-300 px-3 py-2 text-sm text-slate-600 hover:bg-slate-50">
            30 June
          </button>
        </div>
        <button type="button" onClick={() => window.print()}
          className="ml-auto rounded border border-slate-300 px-3 py-2 text-sm text-slate-600 hover:bg-slate-50">
          Print
        </button>
      </div>

      {q.isLoading && <div className="py-10 text-center text-sm text-slate-500">Working it out…</div>}

      {b && <BalanceSheetView b={b} />}
    </div>
  )
}

/**
 * The statement itself, with no data fetching in it.
 *
 * Split out so the layout can be rendered to a file and LOOKED AT — see
 * web/tools/balance-sheet-preview.test.tsx. The challan printed "PAST DUE — PAY
 * IMMEDIATELY" across fully-paid reprints for a while, and no assertion about
 * markup caught it; rendering it and looking did.
 */
export function BalanceSheetView({ b }: { b: BalanceSheet }) {
  return (
        <div id="report">
          <div className="mb-4">
            <h2 className="text-lg font-semibold text-slate-800">Balance Sheet</h2>
            <p className="text-sm text-slate-500">
              Position as at {fmtDate(b.as_at)} · {b.students_on_roll} on the roll ·{' '}
              {b.students_owing} owing
            </p>
          </div>

          {/* The one thing on this page a school could act on wrongly if it
              were left implicit. If the advance fees being held exceed the cash
              actually in hand, that money has already been spent — and it may
              have to be given back. Both figures are in the tiles either way;
              saying nothing about the relationship between them is what makes a
              statement technically true and practically misleading. */}
          {b.advance_held > 0 && b.advance_held > b.cash_position && (
            <div className="mb-4 rounded border border-danger-300 bg-danger-50 p-3 text-sm text-danger-800">
              <strong>Advance fees exceed the cash in hand.</strong>{' '}
              {fmtPKR(b.advance_held)} has been collected for months not yet billed, but the
              cash position is only {fmtPKR(b.cash_position)}. If those parents ask for a
              refund, or their children leave, the money to return is not there.
            </div>
          )}

          <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
            <Figure
              label="Receivable" big
              // Never billed is NOT the same as nothing owed — a green zero on a
              // school that has not issued a single challan reads as "all
              // collected". This is the same trap fn_dashboard_summary fell into.
              tone={b.charges_raised === 0 ? 'plain' : b.receivable > 0 ? 'bad' : 'good'}
              value={fmtPKR(b.receivable)}
              note={b.charges_raised === 0
                ? 'Nothing has been billed yet, so nothing is owed. Not the same as being paid up.'
                : b.receivable > 0
                  ? 'Charged to parents by this date and not yet paid.'
                  : 'Every challan issued by this date is settled.'}
            />
            <Figure
              label="Cash position" big
              // Same rule as the receivable tile: a school where nothing has
              // happened yet is empty, not healthy, so it does not get the
              // green tick.
              tone={b.cash_in === 0 && b.cash_out === 0 ? 'plain'
                    : b.cash_position >= 0 ? 'good' : 'bad'}
              value={fmtPKR(b.cash_position)}
              note={b.cash_in === 0 && b.cash_out === 0
                ? 'No money in or out yet.'
                : 'Everything received less everything spent, from the start.'}
            />
            <Figure
              label="Advance held" big tone={b.advance_held > 0 ? 'hold' : 'plain'}
              value={fmtPKR(b.advance_held)}
              note={b.advance_held > 0
                ? 'Fees taken for a month not yet billed. Owed back if a child leaves.'
                : 'No fees taken for months that have not been billed.'}
            />
            <Figure
              label="Arrears of leavers" big
              tone={b.receivable_off_roll > 0 ? 'hold' : 'plain'}
              value={fmtPKR(b.receivable_off_roll)}
              note="Part of the receivable, owed by children no longer on the roll."
            />
          </div>

          {/* The workings. Not decoration — this is what makes the four tiles
              above checkable rather than something the software just asserts. */}
          <div className="mt-6 grid gap-6 lg:grid-cols-2">
            <div className="rounded border border-slate-200 p-4">
              <h3 className="mb-2 text-sm font-semibold text-slate-700">
                How the receivable is reached
              </h3>
              <table className="w-full text-sm">
                <tbody>
                  <WorkingRow label="Charged by this date (fees, fines, adjustments)"
                    value={b.charges_raised} sign="+" />
                  <WorkingRow label="Paid against those challans" value={b.allocated} sign="−" />
                  <tr className="border-t border-slate-200 font-semibold text-slate-800">
                    <td />
                    <td className="py-2 pl-2">Receivable</td>
                    <td className="py-2 pl-4 text-right tabular-nums">{fmtPKR(b.receivable)}</td>
                  </tr>
                </tbody>
              </table>
            </div>

            <div className="rounded border border-slate-200 p-4">
              <h3 className="mb-2 text-sm font-semibold text-slate-700">
                How the cash position is reached
              </h3>
              <table className="w-full text-sm">
                <tbody>
                  <WorkingRow label="Fee receipts (verified only)" value={b.fee_receipts} sign="+" />
                  <WorkingRow label="Other income" value={b.other_income} sign="+" />
                  <WorkingRow label="Expenses" value={b.cash_out} sign="−" />
                  <tr className="border-t border-slate-200 font-semibold text-slate-800">
                    <td />
                    <td className="py-2 pl-2">Cash position</td>
                    <td className="py-2 pl-4 text-right tabular-nums">{fmtPKR(b.cash_position)}</td>
                  </tr>
                  <WorkingRow label="of which held as advance fees"
                    value={b.advance_held} muted />
                </tbody>
              </table>
            </div>
          </div>

          <p className="mt-4 text-xs leading-relaxed text-slate-500">{b.basis}</p>
    </div>
  )
}

/** Last day of the previous month — the date a monthly close is dated. */
function lastDayOfPrevMonth(): string {
  const d = new Date()
  // Day 0 of this month is the last day of the previous one.
  const last = new Date(d.getFullYear(), d.getMonth(), 0)
  return `${last.getFullYear()}-${String(last.getMonth() + 1).padStart(2, '0')}-${String(last.getDate()).padStart(2, '0')}`
}

/**
 * 30 June — the Pakistani financial year end, and the date a school's accounts
 * are actually closed on. If we are already past it this year it means this
 * year's; before it, last year's, because that is the close you would still be
 * working on.
 */
function lastDayOfJune(): string {
  const d = new Date()
  const year = d.getMonth() >= 6 ? d.getFullYear() : d.getFullYear() - 1
  return `${year}-06-30`
}

/* ==================================================== mark corrections */

/**
 * Every mark somebody changed after entering it.
 *
 * mark_entries has recorded the previous mark all along and nothing ever read
 * it, so the school held the answer to "my son got 45, you have written 40" and
 * could not get at it. This is that answer, and it is also the report a head
 * teacher wants the week before results go out.
 */
export function MarkCorrectionsReport() {
  const [from, setFrom] = useState('')
  const [to, setTo] = useState('')

  const q = useQuery({
    queryKey: ['markCorrections', from, to],
    queryFn: () => getMarkCorrections(from || null, to || null),
  })
  const rows = q.data ?? []
  const noReason = rows.filter((r) => !r.reason?.trim()).length

  const columns: Column<MarkCorrection>[] = [
    {
      key: 'changed_at', header: 'Changed', sortable: true, value: (r) => r.changed_at,
      render: (r) => (
        <span className="whitespace-nowrap text-slate-600">{fmtDate(r.changed_at)}</span>
      ),
    },
    {
      key: 'student_name', header: 'Student', sortable: true, value: (r) => r.student_name,
      render: (r) => (
        <div>
          <div className="text-slate-800">{r.student_name}</div>
          <div className="text-xs text-slate-400">
            {r.gr_no ?? '—'}
            {r.class_name ? ` · ${r.class_name}` : ''}{r.section_name ? `-${r.section_name}` : ''}
          </div>
        </div>
      ),
    },
    {
      key: 'paper', header: 'Paper', sortable: true,
      value: (r) => `${r.subject_name ?? ''} ${r.paper ?? ''}`,
      render: (r) => (
        <div>
          <div className="text-slate-700">{r.subject_name ?? '—'}</div>
          <div className="text-xs text-slate-400">{r.kind} · {r.paper ?? '—'}</div>
        </div>
      ),
    },
    {
      // The whole point: the two numbers side by side, with the direction of
      // travel visible at a glance.
      key: 'was', header: 'Was → is', align: 'right', sortable: true, value: (r) => r.was,
      render: (r) => (
        <span className="whitespace-nowrap tabular-nums">
          <span className="text-slate-400 line-through">{r.was ?? '—'}</span>
          <span className="mx-1 text-slate-300">→</span>
          <span className={`font-medium ${
            r.was != null && r.now_is != null && r.now_is < r.was
              ? 'text-danger-700' : 'text-money-700'}`}>
            {r.now_is ?? '—'}
          </span>
          {r.max_marks != null && (
            <span className="ml-1 text-xs text-slate-400">/{r.max_marks}</span>
          )}
        </span>
      ),
    },
    {
      key: 'reason', header: 'Reason', value: (r) => r.reason,
      render: (r) =>
        r.reason?.trim()
          ? <span className="text-slate-700">{r.reason}</span>
          : <span className="text-danger-600">none given</span>,
    },
    { key: 'changed_by', header: 'By', sortable: true, value: (r) => r.changed_by },
  ]

  return (
    <div>
      <div className="mb-3 flex flex-wrap items-end gap-3">
        <label className="block text-sm">
          <span className="text-slate-600">From</span>
          <input type="date" value={from} onChange={(e) => setFrom(e.target.value)}
            className={`mt-1 block ${FIELD}`} />
        </label>
        <label className="block text-sm">
          <span className="text-slate-600">To</span>
          <input type="date" value={to} onChange={(e) => setTo(e.target.value)}
            className={`mt-1 block ${FIELD}`} />
        </label>
        <span className="ml-auto rounded bg-slate-100 px-2 py-1 text-sm text-slate-700">
          {rows.length} changed
          {noReason > 0 && (
            <span className="ml-1 text-danger-700">· {noReason} with no reason</span>
          )}
        </span>
      </div>

      <DataTable
        rows={rows}
        columns={columns}
        rowKey={(r) => `${r.changed_at}-${r.student_name}-${r.paper}`}
        loading={q.isLoading}
        error={q.isError ? (q.error as Error).message : null}
        emptyTitle="No mark has been changed"
        emptyMessage="Leave both dates blank to check the whole session."
        exportName="mark-corrections"
        printId="report"
      />

      <p className="mt-3 text-xs leading-relaxed text-slate-500">
        A mark appears here only if it was changed <em>after</em> being entered — a first entry is
        not a correction. The previous mark has always been recorded; until now nothing could show
        it. Rows marked <span className="text-danger-600">none given</span> were changed without a
        reason, which is worth asking about.
      </p>
    </div>
  )
}

/* ============================================== attendance corrections */

export function AttendanceCorrectionsReport() {
  const [from, setFrom] = useState('')
  const [to, setTo] = useState('')

  const q = useQuery({
    queryKey: ['attendanceCorrections', from, to],
    queryFn: () => getAttendanceCorrections(from || null, to || null),
  })
  const rows = q.data ?? []

  const columns: Column<AttendanceCorrection>[] = [
    {
      key: 'attendance_date', header: 'For the day', sortable: true,
      value: (r) => r.attendance_date,
      render: (r) => (
        <span className="whitespace-nowrap text-slate-700">{fmtDate(r.attendance_date)}</span>
      ),
    },
    {
      key: 'changed_at', header: 'Changed on', sortable: true, secondary: true,
      value: (r) => r.changed_at,
      render: (r) => (
        <span className="whitespace-nowrap text-slate-500">{fmtDate(r.changed_at)}</span>
      ),
    },
    {
      key: 'student_name', header: 'Student', sortable: true, value: (r) => r.student_name,
      render: (r) => (
        <div>
          <div className="text-slate-800">{r.student_name}</div>
          <div className="text-xs text-slate-400">
            {r.gr_no ?? '—'}
            {r.class_name ? ` · ${r.class_name}` : ''}{r.section_name ? `-${r.section_name}` : ''}
          </div>
        </div>
      ),
    },
    {
      key: 'was', header: 'Was → is', sortable: true, value: (r) => r.was,
      render: (r) => (
        <span className="whitespace-nowrap capitalize">
          <span className="text-slate-400 line-through">{r.was ?? '—'}</span>
          <span className="mx-1 text-slate-300">→</span>
          <span className="font-medium text-slate-800">{r.now_is ?? '—'}</span>
        </span>
      ),
    },
    {
      key: 'reason', header: 'Reason', value: (r) => r.reason,
      render: (r) =>
        r.reason?.trim()
          ? <span className="text-slate-700">{r.reason}</span>
          : <span className="text-danger-600">none given</span>,
    },
    { key: 'changed_by', header: 'By', sortable: true, value: (r) => r.changed_by },
  ]

  return (
    <div>
      <div className="mb-3 flex flex-wrap items-end gap-3">
        <label className="block text-sm">
          <span className="text-slate-600">From</span>
          <input type="date" value={from} onChange={(e) => setFrom(e.target.value)}
            className={`mt-1 block ${FIELD}`} />
        </label>
        <label className="block text-sm">
          <span className="text-slate-600">To</span>
          <input type="date" value={to} onChange={(e) => setTo(e.target.value)}
            className={`mt-1 block ${FIELD}`} />
        </label>
        <span className="ml-auto rounded bg-slate-100 px-2 py-1 text-sm text-slate-700">
          {rows.length} changed
        </span>
      </div>

      <DataTable
        rows={rows}
        columns={columns}
        rowKey={(r) => `${r.changed_at}-${r.student_name}-${r.attendance_date}`}
        loading={q.isLoading}
        error={q.isError ? (q.error as Error).message : null}
        emptyTitle="No attendance record has been changed"
        emptyMessage="Leave both dates blank to check the whole session."
        exportName="attendance-corrections"
        printId="report"
      />

      <p className="mt-3 text-xs leading-relaxed text-slate-500">
        &ldquo;For the day&rdquo; is the day being marked; &ldquo;changed on&rdquo; is when somebody
        altered it. A gap between the two is the thing worth looking at — an absence rewritten
        weeks later is different from one corrected the same afternoon.
      </p>
    </div>
  )
}

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
 */
import { useMemo, useState } from 'react'
import { useQuery } from '@tanstack/react-query'
import {
  getLedger, getUnpaidInvoices, getDiscountReport, getAdmissionReport,
  getCurrentSession,
  type LedgerRow, type UnpaidInvoiceRow, type DiscountReportRow, type AdmissionReportRow,
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

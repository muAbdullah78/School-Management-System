/**
 * The registers a head teacher asks for at month end: the debit and credit
 * statement, unpaid challans, discounts, admissions, the balance sheet, the two
 * change registers, children who left, and cancelled charges.
 *
 * All but the balance sheet are built on the shared DataTable, so every one of
 * them sorts, searches, exports to CSV and draws itself as cards on a phone
 * without any of that being written nine times. Each now opens on the figures
 * that matter (in tiles, in the app's colours) instead of a grey pill of text.
 */
import { useMemo, useState } from 'react'
import { useQuery } from '@tanstack/react-query'
import {
  getLedger, getUnpaidInvoices, getDiscountReport, getAdmissionReport,
  getBalanceSheet, getMarkCorrections, getAttendanceCorrections, getCurrentSession,
  getStudentsLeft, getVoidedInvoices,
  type LedgerRow, type UnpaidInvoiceRow, type DiscountReportRow, type AdmissionReportRow,
  type BalanceSheet, type MarkCorrection, type AttendanceCorrection,
  type StudentLeftRow, type VoidedInvoice,
} from '@/lib/db'
import { DataTable, type Column } from '@/components/DataTable'
import { fmtPKR, fmtDate } from '@/lib/format'
import { daysAgo, monthStart, today } from '@/lib/dates'
import { inputBase } from '@/components/ui'
import { StackBar, HBars, StackedColumns, ChartCard, MiniTable, C, compactRs, pctOf, type Segment } from '@/components/viz'
import { ATTENDANCE_LABELS } from '@/lib/constants'
import {
  RangePicker, rangeProblem, rangeWords, methodLabel, statusLabel, Tile, Tiles, ReportFrame,
  Loading, Failed, Note, Chip, type Range,
} from './kit'

// Both come from one place: lib/dates, in Karachi. This file once had a
// correct month start and, four lines below it, a today() that went through
// toISOString and so named yesterday for five hours every night.

/** "2026-09" to "Sep 26". en-GB and UTC, so it is never a day out or American. */
function monthShort(ym: string): string {
  return new Date(`${ym}-01T00:00:00Z`).toLocaleDateString('en-GB', { month: 'short', year: '2-digit', timeZone: 'UTC' })
}

function Problem({ text }: { text: string | null }) {
  return text ? <p className="rounded-xl bg-due-50 px-3 py-2 text-sm text-due-800">{text}</p> : null
}

function Who({ name, sub }: { name: string; sub?: string | null }) {
  return (
    <div className="min-w-0">
      <div className="truncate text-slate-900">{name}</div>
      {sub && <div className="truncate text-xs text-slate-400">{sub}</div>}
    </div>
  )
}

const cls = (c: string | null, s: string | null) => (c ? `${c}${s ? `-${s}` : ''}` : null)

/* ============================================================ debit & credit */

export function LedgerReport() {
  const [range, setRange] = useState<Range>({ from: monthStart(), to: today() })
  const [kind, setKind] = useState<'all' | 'income' | 'expense'>('all')
  const problem = rangeProblem(range)

  const q = useQuery({
    queryKey: ['ledgerReport', range.from, range.to, kind],
    queryFn: () => getLedger(range.from, range.to, kind),
    enabled: !problem,
  })

  const rows = q.data ?? []
  const debit = rows.reduce((t, r) => t + r.debit, 0)
  const credit = rows.reduce((t, r) => t + r.credit, 0)
  const byHead = useMemo(() => {
    const m = new Map<string, number>()
    for (const r of rows) if (r.kind === 'expense') m.set(r.category, (m.get(r.category) ?? 0) + r.credit - r.debit)
    return [...m.entries()].map(([k, v]) => ({ key: k, label: k, value: Math.max(0, v) })).sort((a, b) => b.value - a.value)
  }, [rows])

  const columns: Column<LedgerRow>[] = [
    {
      key: 'entry_date', header: 'Date', sortable: true, value: (r) => r.entry_date,
      render: (r) => <span className="whitespace-nowrap text-slate-600">{fmtDate(r.entry_date)}</span>,
    },
    {
      key: 'category', header: 'Head', sortable: true, value: (r) => r.category,
      render: (r) => <span className={r.kind === 'income' ? 'text-money-700' : 'text-slate-700'}>{r.category}</span>,
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
    { key: 'method', header: 'Method', sortable: true, secondary: true, value: (r) => methodLabel(r.method) },
    { key: 'reference', header: 'Ref', secondary: true, value: (r) => r.reference },
    {
      key: 'debit', header: 'In', align: 'right', sortable: true, value: (r) => r.debit,
      render: (r) => (r.debit ? <span className="text-money-700">{fmtPKR(r.debit)}</span> : <span className="text-slate-300">-</span>),
    },
    {
      key: 'credit', header: 'Out', align: 'right', sortable: true, value: (r) => r.credit,
      render: (r) => (r.credit ? <span className="text-slate-800">{fmtPKR(r.credit)}</span> : <span className="text-slate-300">-</span>),
    },
    { key: 'recorded_by', header: 'By', secondary: true, value: (r) => r.recorded_by },
  ]

  return (
    <div className="space-y-4">
      <div className="flex flex-wrap items-end gap-3">
        <RangePicker value={range} onChange={setRange} />
        <div className="flex gap-1.5 print:hidden">
          {([['all', 'Everything'], ['income', 'Money in'], ['expense', 'Money out']] as const).map(([k, l]) => (
            <Chip key={k} on={kind === k} onClick={() => setKind(k)}>{l}</Chip>
          ))}
        </div>
      </div>
      <Problem text={problem} />

      <ReportFrame title="Debit and credit statement" subtitle={rangeWords(range)} bare>
        {q.data && (<Tiles>
          <Tile label="Money in" value={fmtPKR(debit)} tone="money" sub={`${rows.filter((r) => r.debit).length} entries`} />
          <Tile label="Money out" value={fmtPKR(credit)} sub={`${rows.filter((r) => r.credit).length} entries`} />
          <Tile label={debit - credit >= 0 ? 'Surplus' : 'Deficit'} value={fmtPKR(Math.abs(debit - credit))}
            tone={debit - credit >= 0 ? 'brand' : 'danger'} />
          <Tile label="Biggest cost" value={byHead[0]?.label ?? '-'} sub={byHead[0] ? fmtPKR(byHead[0].value) : 'Nothing spent'} />
        </Tiles>)}
        {byHead.length > 1 && kind !== 'income' && (
          <div className="mt-4 print:hidden">
            <ChartCard title="Where the money went" table={<MiniTable head={['Head', 'Spent']} align={['l', 'r']} rows={byHead.map((h) => [h.label, fmtPKR(h.value)])} />}>
              <HBars rows={byHead.slice(0, 8)} format={(n) => compactRs(n)} label="Spending by head" />
            </ChartCard>
          </div>
        )}
        <div className="mt-4">
          <DataTable
            rows={rows}
            columns={columns}
            rowKey={(r) => `${r.entry_date}-${r.kind}-${r.reference}-${r.particulars}-${r.debit}-${r.credit}`}
            loading={q.isLoading}
            error={q.isError ? (q.error as Error).message : null}
            emptyTitle="Nothing in this period"
            emptyMessage="No receipts, other income or expenses between those dates."
            exportName={`debit-credit_${range.from}_to_${range.to}`}
            mobileCard={(r) => (
              <div className="flex items-start justify-between gap-3">
                <Who name={r.particulars} sub={`${fmtDate(r.entry_date)} · ${r.category}${r.party !== '-' ? ` · ${r.party}` : ''}`} />
                <span className={`shrink-0 font-semibold tabular-nums ${r.debit ? 'text-money-700' : 'text-slate-800'}`}>
                  {r.debit ? `+${fmtPKR(r.debit)}` : `-${fmtPKR(r.credit)}`}
                </span>
              </div>
            )}
          />
        </div>
        <Note>
          Fee income is read from receipts and cannot be typed in anywhere, which is what makes this
          statement worth trusting. A reversed receipt appears as its own line on the Out side rather
          than being netted away. Counted by the day in Pakistan, so it agrees with the Accounts screen
          for the same dates.
        </Note>
      </ReportFrame>
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
  const [age, setAge] = useState<'all' | 'notyet' | 'd30' | 'old'>('all')

  const all = q.data ?? []
  const bucket = (r: UnpaidInvoiceRow) => (r.days_overdue === 0 ? 'notyet' : r.days_overdue <= 30 ? 'd30' : 'old')
  const sum = (xs: UnpaidInvoiceRow[]) => xs.reduce((t, r) => t + r.due, 0)
  const notYet = all.filter((r) => bucket(r) === 'notyet')
  const d30 = all.filter((r) => bucket(r) === 'd30')
  const old = all.filter((r) => bucket(r) === 'old')
  const parts: Segment[] = [
    { key: 'notyet', label: 'Not due yet', value: sum(notYet), color: C.none },
    { key: 'd30', label: 'Up to 30 days late', value: sum(d30), color: C.warn },
    { key: 'old', label: 'Over 30 days late', value: sum(old), color: C.bad },
  ]

  const rows = useMemo(() => {
    const t = term.trim().toLowerCase()
    return all.filter((r) =>
      (age === 'all' || bucket(r) === age) &&
      (!t || r.student_name.toLowerCase().includes(t) || (r.gr_no ?? '').toLowerCase().includes(t) ||
        (r.voucher_code ?? '').toLowerCase().includes(t) || (r.father_name ?? '').toLowerCase().includes(t)))
  }, [all, term, age])

  const columns: Column<UnpaidInvoiceRow>[] = [
    { key: 'period_label', header: 'Month', sortable: true, value: (r) => r.due_date ?? r.period_label },
    {
      key: 'student_name', header: 'Student', sortable: true, value: (r) => r.student_name,
      render: (r) => <Who name={r.student_name} sub={[r.gr_no, cls(r.class_name, r.section_name)].filter(Boolean).join(' · ')} />,
    },
    { key: 'father_name', header: 'Father', sortable: true, secondary: true, value: (r) => r.father_name },
    {
      key: 'voucher_code', header: 'Challan', secondary: true, value: (r) => r.voucher_code,
      render: (r) => <span className="font-mono text-xs text-slate-500">{r.voucher_code ?? '-'}</span>,
    },
    {
      key: 'days_overdue', header: 'Late by', align: 'right', sortable: true, value: (r) => r.days_overdue,
      render: (r) => r.days_overdue === 0
        ? <span className="text-slate-400">not due</span>
        : <span className={r.days_overdue > 30 ? 'font-semibold text-danger-700' : 'text-due-800'}>{r.days_overdue} days</span>,
    },
    {
      key: 'due', header: 'Owed', align: 'right', sortable: true, value: (r) => r.due,
      render: (r) => <span className="font-semibold text-due-800">{fmtPKR(r.due)}</span>,
    },
  ]

  return (
    <div className="space-y-4">
      {q.isLoading && <Loading />}
      {q.isError && <Failed error={q.error} />}
      {q.data && (
        <ReportFrame title="Unpaid challans" subtitle={session.data?.name} bare>
          <Tiles>
            <Tile label="Unpaid challans" value={all.length} tone={all.length ? 'due' : 'plain'} />
            <Tile label="Owed on them" value={fmtPKR(sum(all))} tone={all.length ? 'due' : 'plain'} />
            <Tile label="Over 30 days late" value={fmtPKR(sum(old))} tone={old.length ? 'danger' : 'plain'} sub={`${old.length} challans`} />
            <Tile label="Not due yet" value={fmtPKR(sum(notYet))} sub={`${notYet.length} challans`} />
          </Tiles>
          {all.length > 0 && (
            <div className="mt-4 rounded-2xl border border-slate-200 bg-white p-4 shadow-card print:hidden">
              <StackBar parts={parts} height={10} label={parts.map((p) => `${p.label} ${fmtPKR(p.value)}`).join(', ')} />
              <div className="mt-3 flex flex-wrap gap-1.5">
                <Chip on={age === 'all'} onClick={() => setAge('all')}>Every challan</Chip>
                {parts.map((p) => (
                  <Chip key={p.key} on={age === p.key} onClick={() => setAge(p.key as typeof age)}>
                    <span className="mr-1.5 inline-block h-2 w-2 rounded-sm align-middle" style={{ background: p.color }} aria-hidden />
                    {p.label} · {compactRs(p.value)}
                  </Chip>
                ))}
              </div>
            </div>
          )}
          <div className="mt-4">
            <DataTable
              rows={rows}
              columns={columns}
              rowKey={(r) => r.invoice_id}
              search={term}
              onSearchChange={setTerm}
              searchPlaceholder="Child, father, GR number or challan code"
              emptyTitle={all.length ? 'Nothing matches' : 'Nothing unpaid'}
              emptyMessage={all.length ? 'Try another name, or Every challan.' : 'Every challan issued this session has been settled.'}
              exportName="unpaid-challans"
              mobileCard={(r) => (
                <div className="flex items-start justify-between gap-3">
                  <Who name={r.student_name} sub={`${r.period_label}${cls(r.class_name, r.section_name) ? ` · ${cls(r.class_name, r.section_name)}` : ''}`} />
                  <div className="shrink-0 text-right">
                    <div className="font-semibold tabular-nums text-due-800">{fmtPKR(r.due)}</div>
                    <div className={`text-xs ${r.days_overdue > 30 ? 'font-medium text-danger-700' : 'text-slate-500'}`}>
                      {r.days_overdue === 0 ? 'not due yet' : `${r.days_overdue} days late`}
                    </div>
                  </div>
                </div>
              )}
            />
          </div>
          <Note>
            One line per challan, not per child, so you can see which months are outstanding and which
            slip to reprint. Days late are counted from the due date, in Pakistan.
          </Note>
        </ReportFrame>
      )}
    </div>
  )
}

/* ================================================================ discounts */

const DISCOUNT_TYPE: Record<string, string> = {
  sibling: 'Sibling', staff_child: 'Staff child', merit: 'Merit', need: 'Hardship', hardship: 'Hardship',
  scholarship: 'Scholarship', other: 'Other', orphan: 'Orphan', hafiz: 'Hafiz-e-Quran',
}
const discountType = (t: string) => DISCOUNT_TYPE[t] ?? t.replace(/_/g, ' ').replace(/^./, (c) => c.toUpperCase())

export function DiscountsReport() {
  const [range, setRange] = useState<Range>({ from: '', to: '' })
  const problem = range.from || range.to ? rangeProblem({ from: range.from || '1900-01-01', to: range.to || today() }, 100000) : null
  const q = useQuery({
    queryKey: ['discountReport', range.from, range.to],
    queryFn: () => getDiscountReport(range.from || null, range.to || null),
    enabled: !problem,
  })
  const rows = q.data ?? []
  const waiting = rows.filter((r) => r.status === 'pending').length
  const byType = useMemo(() => {
    const m = new Map<string, number>()
    for (const r of rows) m.set(discountType(r.reason_type), (m.get(discountType(r.reason_type)) ?? 0) + 1)
    return [...m.entries()].map(([k, v]) => ({ key: k, label: k, value: v })).sort((a, b) => b.value - a.value)
  }, [rows])
  const approvers = new Set(rows.map((r) => r.approved_by).filter((x) => x && x !== '-')).size

  const columns: Column<DiscountReportRow>[] = [
    {
      key: 'granted_on', header: 'Granted', sortable: true, value: (r) => r.granted_on,
      render: (r) => <span className="whitespace-nowrap text-slate-600">{fmtDate(r.granted_on)}</span>,
    },
    {
      key: 'student_name', header: 'Student', sortable: true, value: (r) => r.student_name,
      render: (r) => <Who name={r.student_name} sub={[r.gr_no, r.class_name].filter(Boolean).join(' · ')} />,
    },
    { key: 'reason_type', header: 'Type', sortable: true, value: (r) => discountType(r.reason_type) },
    {
      key: 'amount', header: 'Discount', align: 'right', sortable: true, value: (r) => r.amount,
      render: (r) => <span className="font-medium text-slate-900">{r.is_percent ? `${r.amount}%` : fmtPKR(r.amount)}</span>,
    },
    { key: 'reason', header: 'Reason', secondary: true, value: (r) => r.reason },
    {
      key: 'status', header: 'Status', sortable: true, value: (r) => statusLabel(r.status),
      render: (r) => (
        <span className={`rounded-full px-2 py-0.5 text-xs font-medium ring-1 ${
          r.status === 'approved' ? 'bg-brand-50 text-brand-700 ring-brand-100'
            : r.status === 'pending' ? 'bg-due-50 text-due-800 ring-due-200' : 'bg-slate-100 text-slate-600 ring-slate-200'}`}>
          {statusLabel(r.status)}
        </span>
      ),
    },
    { key: 'proposed_by', header: 'Proposed by', secondary: true, value: (r) => r.proposed_by },
    { key: 'approved_by', header: 'Approved by', sortable: true, value: (r) => r.approved_by },
  ]

  return (
    <div className="space-y-4">
      <RangePicker value={range} onChange={setRange} blank />
      <Problem text={problem} />
      <ReportFrame title="Discounts" subtitle={rangeWords(range)} bare>
        {q.data && (<Tiles>
          <Tile label="Discounts" value={rows.length} tone="brand" />
          <Tile label="Waiting for approval" value={waiting} tone={waiting ? 'due' : 'plain'} sub={waiting ? 'Not taken off any challan yet' : 'None waiting'} />
          <Tile label="Most given" value={byType[0]?.label ?? '-'} sub={byType[0] ? `${byType[0].value} of them` : undefined} />
          <Tile label="Approved by" value={approvers} sub={approvers === 1 ? 'person' : 'people'} />
        </Tiles>)}
        {byType.length > 1 && (
          <div className="mt-4 print:hidden">
            <ChartCard title="Discounts by type">
              <HBars rows={byType} format={(n) => String(n)} label="Discounts by type" />
            </ChartCard>
          </div>
        )}
        <div className="mt-4">
          <DataTable
            rows={rows}
            columns={columns}
            /* The student, the date, the type and the amount. 0141 pinned the
               class join to the current session, so one discount is one row. */
            rowKey={(r) => `${r.student_id}-${r.granted_on}-${r.reason_type}-${r.amount}`}
            loading={q.isLoading}
            error={q.isError ? (q.error as Error).message : null}
            emptyTitle="No discounts"
            emptyMessage="Nothing has been waived or reduced in these dates."
            exportName="fee-discounts"
            mobileCard={(r) => (
              <div className="flex items-start justify-between gap-3">
                <Who name={r.student_name} sub={`${discountType(r.reason_type)} · ${statusLabel(r.status)}${r.approved_by && r.approved_by !== '-' ? ` · ${r.approved_by}` : ''}`} />
                <span className="shrink-0 font-semibold tabular-nums text-slate-900">{r.is_percent ? `${r.amount}%` : fmtPKR(r.amount)}</span>
              </div>
            )}
          />
        </div>
        <Note>
          A discount is money the school chose not to collect, so who proposed it and who approved it
          are the columns that matter. Sort by Approved by to see one person&rsquo;s decisions together.
        </Note>
      </ReportFrame>
    </div>
  )
}

/* =============================================================== admissions */

export function AdmissionsReport() {
  const [range, setRange] = useState<Range>({ from: '', to: '' })
  const q = useQuery({
    queryKey: ['admissionReport', range.from, range.to],
    queryFn: () => getAdmissionReport(range.from || null, range.to || null),
  })
  const rows = q.data ?? []
  const stillHere = rows.filter((r) => r.status === 'active').length
  const boys = rows.filter((r) => r.gender === 'male').length
  const girls = rows.filter((r) => r.gender === 'female').length
  const byMonth = useMemo(() => {
    const m = new Map<string, number>()
    for (const r of rows) { const k = r.admitted_on.slice(0, 7); m.set(k, (m.get(k) ?? 0) + 1) }
    return [...m.entries()].sort(([a], [b]) => a.localeCompare(b)).slice(-12)
  }, [rows])

  const columns: Column<AdmissionReportRow>[] = [
    {
      key: 'admitted_on', header: 'Admitted', sortable: true, value: (r) => r.admitted_on,
      render: (r) => <span className="whitespace-nowrap text-slate-600">{fmtDate(r.admitted_on)}</span>,
    },
    {
      key: 'student_name', header: 'Student', sortable: true, value: (r) => r.student_name,
      render: (r) => <Who name={r.student_name} sub={[r.gr_no, r.admission_no].filter(Boolean).join(' · ')} />,
    },
    { key: 'father_name', header: 'Father', sortable: true, value: (r) => r.father_name },
    {
      key: 'class_name', header: 'Class', sortable: true, value: (r) => `${r.class_name ?? ''}${r.section_name ?? ''}`,
      render: (r) => <span className="whitespace-nowrap text-slate-600">{cls(r.class_name, r.section_name) ?? '-'}</span>,
    },
    { key: 'gender', header: 'Gender', secondary: true, sortable: true, value: (r) => (r.gender === 'male' ? 'Boy' : r.gender === 'female' ? 'Girl' : '-') },
    {
      key: 'status', header: 'Still here?', sortable: true, value: (r) => r.status,
      render: (r) => r.status === 'active'
        ? <span className="text-brand-700">Yes</span>
        : <span className="text-due-800">{statusLabel(r.status)}</span>,
    },
  ]

  return (
    <div className="space-y-4">
      <RangePicker value={range} onChange={setRange} blank />
      <ReportFrame title="Admissions" subtitle={rangeWords(range)} bare>
        {q.data && (<Tiles>
          <Tile label="Admitted" value={rows.length} tone="brand" />
          <Tile label="Still here" value={stillHere} sub={rows.length ? `${pctOf(stillHere, rows.length)}% stayed` : undefined} />
          <Tile label="Since left" value={rows.length - stillHere} tone={rows.length - stillHere ? 'due' : 'plain'} />
          <Tile label="Boys and girls" value={`${boys} · ${girls}`} />
        </Tiles>)}
        {byMonth.length > 1 && (
          <div className="mt-4 print:hidden">
            <ChartCard title="Admitted each month" subtitle={byMonth.length === 12 ? 'The last twelve months in these dates' : undefined}
              table={<MiniTable head={['Month', 'Admitted']} align={['l', 'r']} rows={byMonth.map(([m, n]) => [monthShort(m), n])} />}>
              <StackedColumns label="Admissions each month" formatTick={(n) => String(n)} formatCap={(n) => String(n)} formatFull={(n) => String(n)}
                data={byMonth.map(([m, n]) => ({ key: m, label: monthShort(m), parts: [{ key: 'n', label: 'Admitted', value: n, color: C.series }] }))} />
            </ChartCard>
          </div>
        )}
        <div className="mt-4">
          <DataTable
            rows={rows}
            columns={columns}
            rowKey={(r) => r.student_id}
            loading={q.isLoading}
            error={q.isError ? (q.error as Error).message : null}
            emptyTitle="No admissions in these dates"
            emptyMessage="Choose Everything to see every child ever admitted."
            exportName="admissions"
            mobileCard={(r) => (
              <div className="flex items-start justify-between gap-3">
                <Who name={r.student_name} sub={`${fmtDate(r.admitted_on)}${cls(r.class_name, r.section_name) ? ` · ${cls(r.class_name, r.section_name)}` : ''}${r.father_name ? ` · ${r.father_name}` : ''}`} />
                <span className={`shrink-0 text-xs font-medium ${r.status === 'active' ? 'text-brand-700' : 'text-due-800'}`}>
                  {r.status === 'active' ? 'Still here' : statusLabel(r.status)}
                </span>
              </div>
            )}
          />
        </div>
        <Note>
          &ldquo;Still here?&rdquo; is the column that makes this more than a headcount: twelve admissions
          with nine already gone is a different month from twelve that stayed.
        </Note>
      </ReportFrame>
    </div>
  )
}

/* ============================================================ balance sheet */

/**
 * The one report here that is not a list. It answers "where did the school
 * stand on this day", which is five figures and the relationships between
 * them, so it is laid out as a statement with the arithmetic shown.
 */
function Figure({ label, value, note, tone = 'plain', big = false }: {
  label: string
  value: string
  note?: string
  tone?: 'plain' | 'good' | 'bad' | 'hold'
  big?: boolean
}) {
  const ring =
    tone === 'good' ? 'border-money-200 bg-money-50'
    : tone === 'bad' ? 'border-danger-200 bg-danger-50'
    : tone === 'hold' ? 'border-due-200 bg-due-50'
    : 'border-slate-200 bg-white'
  const text =
    tone === 'good' ? 'text-money-800'
    : tone === 'bad' ? 'text-danger-700'
    : tone === 'hold' ? 'text-due-800'
    : 'text-slate-900'
  return (
    <div className={`rounded-2xl border p-4 ${ring}`}>
      <div className="text-xs font-medium text-slate-600">{label}</div>
      <div className={`mt-1 font-semibold tabular-nums ${text} ${big ? 'text-2xl' : 'text-xl'}`}>{value}</div>
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

  return (
    <div className="space-y-4">
      <div className="flex flex-wrap items-end gap-2 print:hidden">
        <Chip on={asAt === today()} onClick={() => setAsAt(today())}>Today</Chip>
        <Chip on={asAt === lastDayOfPrevMonth()} onClick={() => setAsAt(lastDayOfPrevMonth())}>End of last month</Chip>
        <Chip on={asAt === lastDayOfJune()} onClick={() => setAsAt(lastDayOfJune())}>30 June</Chip>
        <label className="block">
          <span className="mb-1 block text-xs font-medium text-slate-500">As at</span>
          <input type="date" value={asAt} max={today()} onChange={(e) => e.target.value && setAsAt(e.target.value)} className={`${inputBase} w-auto`} />
        </label>
      </div>
      {q.isLoading && <Loading what="the position" />}
      {q.isError && <Failed error={q.error} />}
      {b && <ReportFrame title="Balance sheet" subtitle={`As at ${fmtDate(b.as_at)}`}><BalanceSheetView b={b} /></ReportFrame>}
    </div>
  )
}

/**
 * The statement itself, with no data fetching in it. Split out so the layout
 * can be rendered to a file and LOOKED AT: see web/tools/balance-sheet-preview.
 */
export function BalanceSheetView({ b }: { b: BalanceSheet }) {
  return (
    <div>
      <p className="mb-4 text-sm text-slate-500">
        {b.students_on_roll} on the roll · {b.students_owing} owing
      </p>

      {/* If the advance fees being held exceed the cash actually in hand, that
          money has already been spent, and it may have to be given back. */}
      {b.advance_held > 0 && b.advance_held > b.cash_position && (
        <div className="mb-4 rounded-2xl border border-danger-200 bg-danger-50 p-3 text-sm text-danger-800">
          <strong>Advance fees exceed the cash in hand.</strong>{' '}
          {fmtPKR(b.advance_held)} has been collected for months not yet billed, but the
          cash position is only {fmtPKR(b.cash_position)}. If those parents ask for a
          refund, or their children leave, the money to return is not there.
        </div>
      )}

      <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
        <Figure
          label="Owed to the school" big
          // Never billed is NOT the same as nothing owed.
          tone={b.charges_raised === 0 ? 'plain' : b.receivable > 0 ? 'hold' : 'plain'}
          value={fmtPKR(b.receivable)}
          note={b.charges_raised === 0
            ? 'Nothing has been billed yet, so nothing is owed. Not the same as being paid up.'
            : b.receivable > 0
              ? 'Charged to parents by this date and not yet paid.'
              : 'Every challan issued by this date is settled.'}
        />
        <Figure
          label="Cash position" big
          tone={b.cash_in === 0 && b.cash_out === 0 ? 'plain' : b.cash_position >= 0 ? 'good' : 'bad'}
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
          label="Owed by children who left" big
          tone={b.receivable_off_roll > 0 ? 'hold' : 'plain'}
          value={fmtPKR(b.receivable_off_roll)}
          note="Part of what is owed, by children no longer on the roll."
        />
      </div>

      {/* The workings. This is what makes the four tiles above checkable. */}
      <div className="mt-6 grid gap-4 lg:grid-cols-2">
        <div className="rounded-2xl border border-slate-200 p-4">
          <h3 className="mb-2 text-sm font-semibold text-slate-800">How what is owed is reached</h3>
          <table className="w-full text-sm">
            <tbody>
              <WorkingRow label="Charged by this date (fees, fines, adjustments)" value={b.charges_raised} sign="+" />
              <WorkingRow label="Paid against those challans" value={b.allocated} sign="−" />
              <tr className="border-t border-slate-200 font-semibold text-slate-900">
                <td />
                <td className="py-2 pl-2">Owed to the school</td>
                <td className="py-2 pl-4 text-right tabular-nums">{fmtPKR(b.receivable)}</td>
              </tr>
            </tbody>
          </table>
        </div>

        <div className="rounded-2xl border border-slate-200 p-4">
          <h3 className="mb-2 text-sm font-semibold text-slate-800">How the cash position is reached</h3>
          <table className="w-full text-sm">
            <tbody>
              <WorkingRow label="Fee receipts (cleared only)" value={b.fee_receipts} sign="+" />
              <WorkingRow label="Other income" value={b.other_income} sign="+" />
              <WorkingRow label="Expenses" value={b.cash_out} sign="−" />
              <tr className="border-t border-slate-200 font-semibold text-slate-900">
                <td />
                <td className="py-2 pl-2">Cash position</td>
                <td className="py-2 pl-4 text-right tabular-nums">{fmtPKR(b.cash_position)}</td>
              </tr>
              <WorkingRow label="of which held as advance fees" value={b.advance_held} muted />
            </tbody>
          </table>
        </div>
      </div>

      <p className="mt-4 text-xs leading-relaxed text-slate-500">{b.basis}</p>
    </div>
  )
}

/** Last day of the previous month, in Pakistan. The date a monthly close is dated. */
function lastDayOfPrevMonth(): string {
  const [y, m] = today().split('-').map(Number)
  const last = new Date(Date.UTC(y, m - 1, 0))
  return last.toISOString().slice(0, 10)
}

/**
 * 30 June. The Pakistani financial year end, and the date a school's accounts
 * are actually closed on. If we are past it this year it means this year's;
 * before it, last year's, because that is the close still being worked on.
 */
function lastDayOfJune(): string {
  const [y, m] = today().split('-').map(Number)
  return `${m >= 7 ? y : y - 1}-06-30`
}

/* ==================================================== mark corrections */

/**
 * Every mark somebody changed after entering it. mark_entries has recorded the
 * previous mark all along, so the school holds the answer to "my son got 45,
 * you have written 40".
 */
export function MarkCorrectionsReport() {
  const [range, setRange] = useState<Range>({ from: '', to: '' })
  const q = useQuery({
    queryKey: ['markCorrections', range.from, range.to],
    queryFn: () => getMarkCorrections(range.from || null, range.to || null),
  })
  const rows = q.data ?? []
  const noReason = rows.filter((r) => !r.reason?.trim()).length
  const down = rows.filter((r) => r.was != null && r.now_is != null && r.now_is < r.was).length
  const byWho = useMemo(() => {
    const m = new Map<string, number>()
    for (const r of rows) m.set(r.changed_by, (m.get(r.changed_by) ?? 0) + 1)
    return [...m.entries()].sort((a, b) => b[1] - a[1])
  }, [rows])

  const columns: Column<MarkCorrection>[] = [
    {
      key: 'changed_at', header: 'Changed', sortable: true, value: (r) => r.changed_at,
      render: (r) => <span className="whitespace-nowrap text-slate-600">{fmtDate(r.changed_at)}</span>,
    },
    {
      key: 'student_name', header: 'Student', sortable: true, value: (r) => r.student_name,
      render: (r) => <Who name={r.student_name} sub={[r.gr_no, cls(r.class_name, r.section_name)].filter(Boolean).join(' · ')} />,
    },
    {
      key: 'paper', header: 'Paper', sortable: true, value: (r) => `${r.subject_name ?? ''} ${r.paper ?? ''}`,
      render: (r) => <Who name={r.subject_name ?? '-'} sub={`${r.kind} · ${r.paper ?? '-'}`} />,
    },
    {
      // The two numbers side by side, with the direction of travel visible.
      key: 'was', header: 'Was, now', align: 'right', sortable: true, value: (r) => r.was,
      render: (r) => <WasIs r={r} />,
    },
    {
      key: 'reason', header: 'Reason', value: (r) => r.reason,
      render: (r) => r.reason?.trim() ? <span className="text-slate-700">{r.reason}</span> : <span className="text-danger-700">none given</span>,
    },
    { key: 'changed_by', header: 'By', sortable: true, value: (r) => r.changed_by },
  ]

  return (
    <div className="space-y-4">
      <RangePicker value={range} onChange={setRange} blank />
      <ReportFrame title="Mark changes" subtitle={rangeWords(range)} bare>
        {q.data && (<Tiles>
          <Tile label="Marks changed" value={rows.length} tone="brand" />
          <Tile label="With no reason given" value={noReason} tone={noReason ? 'danger' : 'plain'} sub={noReason ? 'Worth asking about' : 'Every change explained'} />
          <Tile label="Lowered" value={down} sub={`${rows.length - down} raised or unchanged`} />
          <Tile label="Changed most by" value={byWho[0]?.[0] ?? '-'} sub={byWho[0] ? `${byWho[0][1]} changes` : undefined} />
        </Tiles>)}
        <div className="mt-4">
          <DataTable
            rows={rows}
            columns={columns}
            rowKey={(r) => `${r.changed_at}-${r.student_name}-${r.paper}`}
            loading={q.isLoading}
            error={q.isError ? (q.error as Error).message : null}
            emptyTitle="No mark has been changed"
            emptyMessage="Choose Everything to check the whole record."
            exportName="mark-changes"
            mobileCard={(r) => (
              <div className="flex items-start justify-between gap-3">
                <Who name={r.student_name} sub={`${r.subject_name ?? '-'} · ${fmtDate(r.changed_at)} · ${r.changed_by}${r.reason?.trim() ? '' : ' · no reason'}`} />
                <WasIs r={r} />
              </div>
            )}
          />
        </div>
        <Note>
          A mark appears here only if it was changed <em>after</em> being entered. A first entry is
          not a change. Rows with <span className="text-danger-700">none given</span> were changed
          without a reason.
        </Note>
      </ReportFrame>
    </div>
  )
}

function WasIs({ r }: { r: MarkCorrection }) {
  return (
    <span className="whitespace-nowrap tabular-nums">
      <span className="text-slate-400 line-through">{r.was ?? '-'}</span>
      <span className="mx-1 text-slate-300" aria-hidden>→</span>
      <span className={`font-semibold ${r.was != null && r.now_is != null && r.now_is < r.was ? 'text-danger-700' : 'text-slate-900'}`}>
        {r.now_is ?? (r.is_absent ? 'absent' : '-')}
      </span>
      {r.max_marks != null && <span className="ml-1 text-xs text-slate-400">/{r.max_marks}</span>}
    </span>
  )
}

/* ============================================== attendance corrections */

const att = (s: string | null) => (s ? ATTENDANCE_LABELS[s] ?? s.replace(/_/g, ' ') : '-')

export function AttendanceCorrectionsReport() {
  const [range, setRange] = useState<Range>({ from: '', to: '' })
  const q = useQuery({
    queryKey: ['attendanceCorrections', range.from, range.to],
    queryFn: () => getAttendanceCorrections(range.from || null, range.to || null),
  })
  const rows = q.data ?? []
  const late = rows.filter((r) => daysApart(r.attendance_date, r.changed_at.slice(0, 10)) > 7).length
  const noReason = rows.filter((r) => !r.reason?.trim()).length
  const absentToPresent = rows.filter((r) => r.was === 'absent' && r.now_is === 'present').length

  const columns: Column<AttendanceCorrection>[] = [
    {
      key: 'attendance_date', header: 'For the day', sortable: true, value: (r) => r.attendance_date,
      render: (r) => <span className="whitespace-nowrap text-slate-700">{fmtDate(r.attendance_date)}</span>,
    },
    {
      key: 'changed_at', header: 'Changed on', sortable: true, secondary: true, value: (r) => r.changed_at,
      render: (r) => {
        const gap = daysApart(r.attendance_date, r.changed_at.slice(0, 10))
        return <span className={`whitespace-nowrap ${gap > 7 ? 'font-medium text-due-800' : 'text-slate-500'}`}>{fmtDate(r.changed_at)}{gap > 0 ? ` (${gap}d later)` : ''}</span>
      },
    },
    {
      key: 'student_name', header: 'Student', sortable: true, value: (r) => r.student_name,
      render: (r) => <Who name={r.student_name} sub={[r.gr_no, cls(r.class_name, r.section_name)].filter(Boolean).join(' · ')} />,
    },
    {
      key: 'was', header: 'Was, now', sortable: true, value: (r) => r.was,
      render: (r) => (
        <span className="whitespace-nowrap">
          <span className="text-slate-400 line-through">{att(r.was)}</span>
          <span className="mx-1 text-slate-300" aria-hidden>→</span>
          <span className="font-medium text-slate-900">{att(r.now_is)}</span>
        </span>
      ),
    },
    {
      key: 'reason', header: 'Reason', value: (r) => r.reason,
      render: (r) => r.reason?.trim() ? <span className="text-slate-700">{r.reason}</span> : <span className="text-danger-700">none given</span>,
    },
    { key: 'changed_by', header: 'By', sortable: true, value: (r) => r.changed_by },
  ]

  return (
    <div className="space-y-4">
      <RangePicker value={range} onChange={setRange} blank />
      <ReportFrame title="Attendance changes" subtitle={rangeWords(range)} bare>
        {q.data && (<Tiles>
          <Tile label="Marks changed" value={rows.length} tone="brand" />
          <Tile label="Changed over a week later" value={late} tone={late ? 'due' : 'plain'} sub="The ones worth looking at" />
          <Tile label="Absent made present" value={absentToPresent} />
          <Tile label="With no reason given" value={noReason} tone={noReason ? 'danger' : 'plain'} />
        </Tiles>)}
        <div className="mt-4">
          <DataTable
            rows={rows}
            columns={columns}
            rowKey={(r) => `${r.changed_at}-${r.student_name}-${r.attendance_date}`}
            loading={q.isLoading}
            error={q.isError ? (q.error as Error).message : null}
            emptyTitle="No attendance mark has been changed"
            emptyMessage="Choose Everything to check the whole record."
            exportName="attendance-changes"
            mobileCard={(r) => (
              <div>
                <div className="flex items-start justify-between gap-3">
                  <Who name={r.student_name} sub={`For ${fmtDate(r.attendance_date)} · changed ${fmtDate(r.changed_at)} · ${r.changed_by}`} />
                </div>
                <div className="mt-1 text-sm"><span className="text-slate-400 line-through">{att(r.was)}</span> <span className="text-slate-300">→</span> <b className="font-medium text-slate-900">{att(r.now_is)}</b></div>
              </div>
            )}
          />
        </div>
        <Note>
          &ldquo;For the day&rdquo; is the day being marked; &ldquo;changed on&rdquo; is when somebody
          altered it. An absence rewritten weeks later is different from one corrected the same afternoon.
        </Note>
      </ReportFrame>
    </div>
  )
}

function daysApart(a: string, b: string): number {
  const [ya, ma, da] = a.split('-').map(Number)
  const [yb, mb, db] = b.split('-').map(Number)
  return Math.round((Date.UTC(yb, mb - 1, db) - Date.UTC(ya, ma - 1, da)) / 86_400_000)
}

/* ================================================================ left */

/**
 * Children who have left, with what each left OWING next to the father's
 * phone number: one screen instead of two for the person who has to ring them.
 */
export function StudentsLeftReport() {
  const [range, setRange] = useState<Range>({ from: '', to: '' })
  const q = useQuery({
    queryKey: ['studentsLeft', range.from, range.to],
    queryFn: () => getStudentsLeft(range.from || null, range.to || null),
  })
  const rows = q.data ?? []
  const owing = rows.filter((r) => r.balance > 0)
  const owed = owing.reduce((a, r) => a + r.balance, 0)
  const how = useMemo(() => {
    const m = new Map<string, number>()
    for (const r of rows) m.set(statusLabel(r.status), (m.get(statusLabel(r.status)) ?? 0) + 1)
    return [...m.entries()].map(([k, v]) => ({ key: k, label: k, value: v })).sort((a, b) => b.value - a.value)
  }, [rows])

  const columns: Column<StudentLeftRow>[] = [
    {
      key: 'left_on', header: 'Left', sortable: true, value: (r) => r.left_on,
      render: (r) => <span className="whitespace-nowrap text-slate-600">{fmtDate(r.left_on)}</span>,
    },
    {
      key: 'student_name', header: 'Child', sortable: true, value: (r) => r.student_name,
      render: (r) => <Who name={r.student_name} sub={[r.gr_no, r.father_name].filter(Boolean).join(' · ')} />,
    },
    {
      key: 'class_name', header: 'Class', sortable: true, value: (r) => `${r.class_name ?? ''}${r.section_name ?? ''}`,
      render: (r) => <span className="whitespace-nowrap text-slate-600">{cls(r.class_name, r.section_name) ?? '-'}</span>,
    },
    {
      key: 'status', header: 'How', sortable: true, value: (r) => statusLabel(r.status),
      // Withdrawn and struck off are different facts: one chose to go, the other was removed.
      render: (r) => <span className={`whitespace-nowrap ${r.status === 'struck_off' ? 'text-danger-700' : r.status === 'graduated' ? 'text-brand-700' : 'text-slate-600'}`}>{statusLabel(r.status)}</span>,
    },
    {
      key: 'reason', header: 'Reason', sortable: true, value: (r) => r.reason ?? '',
      render: (r) => r.reason ? <span className="text-slate-600">{r.reason}</span> : <span className="text-xs text-slate-400">none given</span>,
    },
    { key: 'months_here', header: 'Months here', secondary: true, sortable: true, value: (r) => r.months_here ?? -1,
      render: (r) => <span className="tabular-nums text-slate-600">{r.months_here ?? '-'}</span> },
    { key: 'phone', header: 'Phone', secondary: true, sortable: true, value: (r) => r.phone ?? '',
      render: (r) => r.phone ? <a href={`tel:${r.phone}`} className="whitespace-nowrap text-brand-700 hover:underline">{r.phone}</a> : <span className="text-xs text-slate-400">-</span> },
    {
      key: 'balance', header: 'Left owing', align: 'right', sortable: true, value: (r) => r.balance,
      render: (r) => <span className={`tabular-nums ${r.balance > 0 ? 'font-semibold text-due-800' : 'text-slate-400'}`}>{r.balance > 0 ? fmtPKR(r.balance) : '-'}</span>,
    },
  ]

  return (
    <div className="space-y-4">
      <RangePicker value={range} onChange={setRange} blank />
      <ReportFrame title="Children who left" subtitle={rangeWords(range)} bare>
        {q.data && (<Tiles>
          <Tile label="Left" value={rows.length} tone="brand" />
          <Tile label="Left owing money" value={owing.length} tone={owing.length ? 'due' : 'plain'} />
          <Tile label="Still owed by them" value={fmtPKR(owed)} tone={owed ? 'due' : 'plain'} sub={owed ? 'Somebody has to ring these families' : undefined} />
          <Tile label="Most common" value={how[0]?.label ?? '-'} sub={how[0] ? `${how[0].value} of ${rows.length}` : undefined} />
        </Tiles>)}
        {how.length > 1 && (
          <div className="mt-4 print:hidden">
            <ChartCard title="How they left"><HBars rows={how} format={(n) => String(n)} label="How children left" /></ChartCard>
          </div>
        )}
        <div className="mt-4">
          <DataTable
            rows={rows}
            columns={columns}
            rowKey={(r) => r.student_id}
            loading={q.isLoading}
            error={q.isError ? (q.error as Error).message : null}
            emptyTitle="Nobody left in these dates"
            emptyMessage="Choose Everything to see everyone who has left."
            exportName="children-who-left"
            mobileCard={(r) => (
              <div className="flex items-start justify-between gap-3">
                <Who name={r.student_name} sub={`${fmtDate(r.left_on)} · ${statusLabel(r.status)}${r.phone ? ` · ${r.phone}` : ''}`} />
                <span className={`shrink-0 tabular-nums ${r.balance > 0 ? 'font-semibold text-due-800' : 'text-xs text-slate-400'}`}>
                  {r.balance > 0 ? fmtPKR(r.balance) : 'Paid up'}
                </span>
              </div>
            )}
          />
        </div>
        <Note>
          Children who left before leaving dates were recorded have no date and are not listed: the
          upgrade deliberately did not invent one, because a made-up leaving date is worse than a missing one.
        </Note>
      </ReportFrame>
    </div>
  )
}

/* ======================================================== cancelled charges */

/**
 * The register of challans the school withdrew (0087). Nothing here is
 * deleted: the challan keeps its row, its lines and its voucher code, and
 * stops counting towards any figure. Defaults to the last ninety days, because
 * a school looking here is nearly always asking about something recent.
 */
export function VoidedChargesReport() {
  const [range, setRange] = useState<Range>(() => ({ from: daysAgo(89), to: today() }))
  const problem = rangeProblem(range, 100000)
  const q = useQuery({
    queryKey: ['voidedInvoices', range.from, range.to],
    queryFn: () => getVoidedInvoices(range.from, range.to),
    enabled: !problem,
  })
  const rows = q.data ?? []
  const total = rows.reduce((s, r) => s + r.amount, 0)
  const byWho = useMemo(() => {
    const m = new Map<string, number>()
    for (const r of rows) m.set(r.voided_by, (m.get(r.voided_by) ?? 0) + 1)
    return [...m.entries()].sort((a, b) => b[1] - a[1])
  }, [rows])

  const columns: Column<VoidedInvoice>[] = [
    {
      key: 'voided_at', header: 'Cancelled', sortable: true, value: (r) => r.voided_at,
      render: (r) => <span className="whitespace-nowrap text-slate-600">{fmtDate(r.voided_at)}</span>,
    },
    {
      key: 'student_name', header: 'Student', sortable: true, value: (r) => r.student_name,
      render: (r) => <Who name={r.student_name} sub={[r.gr_no, cls(r.class_name, r.section_name)].filter(Boolean).join(' · ')} />,
    },
    { key: 'period_label', header: 'Charge for', sortable: true, value: (r) => r.period_label },
    {
      key: 'amount', header: 'Amount', align: 'right', sortable: true, value: (r) => r.amount,
      render: (r) => <span className="whitespace-nowrap font-medium text-slate-900">{fmtPKR(r.amount)}</span>,
    },
    { key: 'voided_by', header: 'Cancelled by', sortable: true, value: (r) => r.voided_by },
    { key: 'reason', header: 'Reason', value: (r) => r.reason },
    {
      key: 'voucher_code', header: 'Voucher', secondary: true, value: (r) => r.voucher_code ?? '',
      render: (r) => <span className="font-mono text-xs text-slate-400">{r.voucher_code ?? '-'}</span>,
    },
  ]

  return (
    <div className="space-y-4">
      <RangePicker value={range} onChange={setRange} />
      <Problem text={problem} />
      <ReportFrame title="Cancelled charges" subtitle={rangeWords(range)} bare>
        {q.data && (<Tiles>
          <Tile label="Challans cancelled" value={rows.length} tone="brand" />
          <Tile label="Worth" value={fmtPKR(total)} tone={total ? 'due' : 'plain'} sub="Never owed, by the school's decision" />
          <Tile label="Cancelled most by" value={byWho[0]?.[0] ?? '-'} sub={byWho[0] ? `${byWho[0][1]} of ${rows.length}` : undefined} />
          <Tile label="Largest" value={rows.length ? fmtPKR(Math.max(...rows.map((r) => r.amount))) : '-'} />
        </Tiles>)}
        <div className="mt-4">
          <DataTable
            rows={rows}
            columns={columns}
            rowKey={(r) => r.invoice_id}
            loading={q.isLoading}
            error={q.isError ? (q.error as Error).message : null}
            emptyTitle="Nothing cancelled in these dates"
            emptyMessage="A challan raised by mistake can be cancelled from the child's Fees tab, by the owner or principal."
            exportName="cancelled-charges"
            mobileCard={(r) => (
              <div className="flex items-start justify-between gap-3">
                <Who name={r.student_name} sub={`${r.period_label} · ${fmtDate(r.voided_at)} · ${r.voided_by}`} />
                <span className="shrink-0 font-semibold tabular-nums text-slate-900">{fmtPKR(r.amount)}</span>
              </div>
            )}
          />
        </div>
        <Note>
          Cancelling says the family never owed the money, so every entry carries a reason and the name
          of whoever decided. A challan with a payment against it cannot be cancelled at all: the payment
          is reversed first, which leaves its own contra receipt, and only then can the charge be withdrawn.
        </Note>
      </ReportFrame>
    </div>
  )
}

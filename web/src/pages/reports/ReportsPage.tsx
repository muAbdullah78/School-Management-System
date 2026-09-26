import { useMemo, useState } from 'react'
import { useQuery } from '@tanstack/react-query'
import {
  getCurrentSession, getDefaulters, getDefaultersMonth, listBilledMonths,
  getFeeReceipts, getLedger, getClassStrength,
  listClasses, listSections, getAttendanceRegister,
  listStudents, getStudentBalance, getStudentLedger,
  getFeeReconciliation, getHeadWiseDues, type FeeReconciliation,
  type StudentRow, type MonthDefaulter, type FeeReceipt,
} from '@/lib/db'
import { useUrlTab } from '@/lib/useUrlTab'
import { inputClass, inputBase, buttonClass } from '@/components/ui'
import { ATTENDANCE_SHORT } from '@/lib/constants'
import { fmtPKR, fmtDate, todayISO } from '@/lib/format'
import { today, monthStart } from '@/lib/dates'
import { toCSV, downloadCSV } from '@/lib/csv'
import { FeeStatement } from '@/components/FeeStatement'
import {
  StackedColumns, HBars, StackBar, ChartCard, MiniTable, C, compactRs, pctOf, type ColumnDatum, type Segment,
} from '@/components/viz'
import { isMissingFunction } from '@/lib/notInstalled'
import {
  RangePicker, rangeProblem, rangeWords, methodLabel, Tile, Tiles, ReportFrame,
  Loading, Failed, Empty, Note, Chip, type Range,
} from './kit'
import {
  LedgerReport, UnpaidInvoicesReport, DiscountsReport, AdmissionsReport,
  BalanceSheetReport, MarkCorrectionsReport, AttendanceCorrectionsReport,
  StudentsLeftReport, VoidedChargesReport,
} from './FinanceReports'
import { ClassPhotoSheet } from './ClassPhotoSheet'
import { SectionLayout } from '@/components/SectionLayout'

/**
 * NINETEEN REPORTS, IN FIVE GROUPS.
 *
 * They were nineteen tabs in two rows, in the order they happened to be
 * written, so Balance Sheet sat between Children Who Left and Mark Changes and
 * the Day Book was the thirteenth thing to read along. Each report now sits
 * with the others that answer the same kind of question, and each says the
 * question it answers under its name.
 */
const GROUPS = [
  {
    title: 'Money in',
    items: [
      { key: 'collection', label: 'Fee collection', ask: 'Which receipts came in between two days, how, and for whom.' },
      { key: 'daybook', label: 'Day book and cash', ask: 'One day at the counter: what came in, what went out, and what should be in the drawer.' },
      // The money reports a head teacher asks for at month end. "Debit and
      // credit" also serves as the detailed income and detailed expense
      // reports via its own filter.
      { key: 'statement', label: 'Debit and credit', ask: 'Every rupee in and out between two days, as a statement.' },
      // A position as at one day, not a range, which is why it is the only one
      // here that is not a table.
      { key: 'balancesheet', label: 'Balance sheet', ask: 'Where the school stood on one day: owed to it, in hand, and held in advance.' },
      { key: 'reconciliation', label: 'Reconciliation', ask: 'What was billed this session against what was collected, class by class.' },
    ],
  },
  {
    title: 'Money owed',
    items: [
      { key: 'defaulters', label: 'Defaulters', ask: 'Who owes, how much, for the whole session or for one month.' },
      { key: 'unpaid', label: 'Unpaid challans', ask: 'Every challan not yet settled, and how long it has been waiting.' },
      // Which CHARGE is not being paid, as opposed to which family is not paying.
      { key: 'headwise', label: 'Dues by fee head', ask: 'Which charge is not being paid: tuition, transport, exam fee.' },
      { key: 'ledger', label: 'Student ledger', ask: 'One child’s fee account from the first challan, with a running balance.' },
    ],
  },
  {
    title: 'Money given up',
    items: [
      { key: 'discounts', label: 'Discounts', ask: 'Every discount, who proposed it and who approved it.' },
      // 0087. Nothing is deleted: a cancelled challan keeps its row and stops
      // counting, and this is the register that says who withdrew it and why.
      { key: 'voided', label: 'Cancelled charges', ask: 'Challans withdrawn, by whom and why.' },
    ],
  },
  {
    title: 'Pupils',
    items: [
      { key: 'admissions', label: 'Admissions', ask: 'Who joined between two days, and whether they are still here.' },
      { key: 'left', label: 'Children who left', ask: 'Who left, how, why, and what they left owing.' },
      { key: 'strength', label: 'Class strength', ask: 'How many children are in each class and section, boys and girls.' },
      // Not a money report: the sheet a class teacher pins up, and the screen
      // where a whole class actually gets photographed.
      { key: 'photos', label: 'Class photo sheet', ask: 'Every face in a class, and who still needs photographing.' },
    ],
  },
  {
    title: 'Registers and checks',
    items: [
      { key: 'register', label: 'Attendance register', ask: 'A class’s month, day by day, as the paper register is ruled.' },
      { key: 'attfixes', label: 'Attendance changes', ask: 'Every attendance mark somebody changed after it was made.' },
      // mark_entries has recorded the previous mark since the exam module was
      // built and nothing ever read it.
      { key: 'markfixes', label: 'Mark changes', ask: 'Every mark somebody changed after entering it, was and is.' },
    ],
  },
] as const

type Item = (typeof GROUPS)[number]['items'][number]
type TabKey = Item['key']
const ITEMS: Item[] = GROUPS.flatMap((g) => [...g.items] as Item[])
const TAB_KEYS = ITEMS.map((i) => i.key) as TabKey[]

export function ReportsPage() {
  // In the URL, so the dashboard's Day book shortcut opens the Day Book and
  // not Fee Collection, which is where it used to land.
  const [tab, setTab, nav] = useUrlTab<TabKey>(TAB_KEYS, 'collection')
  return (
    <div>
      <div className={`print:hidden ${nav.picked ? 'hidden lg:block' : ''}`}>
        <h1 className="text-xl font-semibold text-slate-800">Reports</h1>
        <p className="mt-0.5 text-sm text-slate-500">Every report prints, saves as PDF, and downloads to Excel as CSV.</p>
      </div>
      <SectionLayout groups={GROUPS} value={tab} onChange={setTab} label="Report"
        picked={nav.picked} onPick={(k) => setTab(k, { explicit: true, push: true })}
        onIndex={nav.clear} indexLabel="All reports">
        {tab === 'collection' && <CollectionReport />}
        {tab === 'daybook' && <DayBookReport />}
        {tab === 'statement' && <LedgerReport />}
        {tab === 'balancesheet' && <BalanceSheetReport />}
        {tab === 'reconciliation' && <ReconciliationReport />}
        {tab === 'defaulters' && <DefaultersReport />}
        {tab === 'unpaid' && <UnpaidInvoicesReport />}
        {tab === 'headwise' && <HeadWiseDuesReport />}
        {tab === 'ledger' && <StudentLedgerReport />}
        {tab === 'discounts' && <DiscountsReport />}
        {tab === 'voided' && <VoidedChargesReport />}
        {tab === 'admissions' && <AdmissionsReport />}
        {tab === 'left' && <StudentsLeftReport />}
        {tab === 'strength' && <StrengthReport />}
        {tab === 'photos' && <ClassPhotoSheet />}
        {tab === 'register' && <AttendanceRegisterReport />}
        {tab === 'attfixes' && <AttendanceCorrectionsReport />}
        {tab === 'markfixes' && <MarkCorrectionsReport />}
      </SectionLayout>
    </div>
  )
}

const TH = 'px-2 py-2 text-left font-medium sm:px-3'
const TD = 'px-2 py-2 sm:px-3'

/** "Aisha, Bilal and Omar", for the few-children case; the count past three. */
function whoFor(r: FeeReceipt): string {
  if (!r.children) return r.payer
  if (r.child_count <= 3) return r.children
  const first = r.children.split(', ').slice(0, 2).join(', ')
  return `${first} and ${r.child_count - 2} more`
}

function needsUpdate(e: unknown) {
  return isMissingFunction(e)
    ? 'This report needs the latest database update (bundle 49). Paste it in the Supabase SQL editor, then reload.'
    : null
}

/* ========================================================= fee collection */

/**
 * WHAT WAS WRONG. It read the payments table straight, and three things
 * followed. The day was the UTC day, so a receipt at 02:00 on the 1st counted
 * in the month before. A family paying for three children together has no
 * student on the payment row, so the Student column printed "-" for exactly the
 * receipts that mattered most (the screenshot the school sent was a column of
 * dashes). And Supabase stops at 1,000 rows without saying so, so a busy
 * quarter was simply short. fn_fee_receipts fixes all three, in Karachi time.
 */
function CollectionReport() {
  const [range, setRange] = useState<Range>({ from: monthStart(), to: today() })
  const problem = rangeProblem(range)
  const q = useQuery({
    queryKey: ['rptReceipts', range.from, range.to],
    queryFn: () => getFeeReceipts(range.from, range.to),
    enabled: !problem,
  })
  const d = q.data
  const days = d?.by_day ?? []
  // A label under every column collides past ten or so, so only every few
  // carry one; the tooltip names each day in full.
  const every = Math.max(1, Math.ceil(days.length / 8))
  const columns: ColumnDatum[] = days.map((x, i) => ({
    key: x.day, label: i % every === 0 || i === days.length - 1 ? String(Number(x.day.slice(8))) : '',
    tipTitle: `${fmtDate(x.day)} · ${x.receipts} receipt${x.receipts === 1 ? '' : 's'}`,
    parts: [{ key: 'in', label: 'Collected', value: Math.max(0, x.amount), color: C.good }],
  }))

  const csv = () => d && downloadCSV(`fee-collection_${range.from}_to_${range.to}.csv`,
    toCSV(['Date', 'Time', 'Receipt', 'Paid by', 'For', 'GR', 'Class', 'Method', 'Amount', 'Recorded by', 'Note'],
      d.rows.map((r) => [fmtDate(r.paid_on), r.time, r.receipt_no ?? '', r.payer, r.children ?? '', r.gr_no ?? '',
        r.class_label ?? '', methodLabel(r.method), r.amount, r.recorded_by, r.note ?? ''])))

  return (
    <div className="space-y-4">
      <RangePicker value={range} onChange={setRange} />
      {problem && <p className="rounded-xl bg-due-50 px-3 py-2 text-sm text-due-800">{problem}</p>}
      {q.isLoading && <Loading />}
      {q.isError && <Failed error={needsUpdate(q.error) ? new Error(needsUpdate(q.error)!) : q.error} />}
      {d && (
        <ReportFrame title="Fee collection" subtitle={rangeWords(range)} onCSV={d.rows.length ? csv : null}>
          <Tiles>
            <Tile label="Collected" value={fmtPKR(d.total)} tone="money"
              sub={`${d.receipts} receipt${d.receipts === 1 ? '' : 's'}`} />
            <Tile label="Average a day" value={days.length ? fmtPKR(Math.round(d.total / days.length)) : '-'}
              sub={`over ${days.length} day${days.length === 1 ? '' : 's'} with receipts`} />
            <Tile label="Reversed" value={d.reversals ? fmtPKR(d.reversed) : 'None'}
              tone={d.reversals ? 'danger' : 'plain'} sub={d.reversals ? `${d.reversals} receipt${d.reversals === 1 ? '' : 's'} taken back` : 'No receipt was reversed'} />
            <Tile label="Waiting to clear" value={d.pending_count ? fmtPKR(d.pending_total) : 'None'}
              tone={d.pending_count ? 'due' : 'plain'}
              sub={d.pending_count ? `${d.pending_count} not counted until cleared` : 'Nothing is waiting'} />
          </Tiles>

          {d.rows.length === 0 ? (
            <div className="mt-4"><Empty title="No receipts in these dates">Try This month or Last 90 days.</Empty></div>
          ) : (
            <>
              <div className="mt-4 grid gap-4 lg:grid-cols-3 print:hidden">
                <ChartCard className="lg:col-span-2" title="Collected each day" subtitle={`${monthLabel(range.from)}${range.from.slice(0, 7) !== range.to.slice(0, 7) ? ` to ${monthLabel(range.to)}` : ''}: cleared receipts, less any reversed that day`}
                  table={<MiniTable head={['Day', 'Receipts', 'Collected']} align={['l', 'r', 'r']}
                    rows={days.map((x) => [fmtDate(x.day), x.receipts, fmtPKR(x.amount)])} />}>
                  <StackedColumns data={columns} label="Fees collected each day" formatFull={(n) => fmtPKR(n)} />
                </ChartCard>
                <ChartCard title="How it was paid"
                  table={<MiniTable head={['Method', 'Receipts', 'Amount']} align={['l', 'r', 'r']}
                    rows={d.by_method.map((m) => [methodLabel(m.method), m.receipts, fmtPKR(m.amount)])} />}>
                  <HBars label="Collected by method" color={C.good} format={(n) => compactRs(n)}
                    rows={d.by_method.map((m) => ({ key: m.method, label: methodLabel(m.method), value: Math.max(0, m.amount),
                      sub: `${m.receipts} · ${pctOf(m.amount, d.total)}%` }))} />
                </ChartCard>
              </div>

              <ReceiptList rows={d.rows} showDate={range.from !== range.to} />
            </>
          )}
          <Note>
            Counted by the day in Pakistan. Only cleared receipts are counted: a bank challan or a transfer
            still waiting to clear is not money in yet, and appears here on the day it was recorded once it
            clears. A reversed receipt is shown in red as its own line and taken off the total.
          </Note>
        </ReportFrame>
      )}
    </div>
  )
}

/** The receipts, as cards on a phone and a table wider. */
function ReceiptList({ rows, showDate }: { rows: FeeReceipt[]; showDate: boolean }) {
  return (
    <div className="mt-4">
      <ul className="divide-y divide-slate-100 rounded-xl border border-slate-200 sm:hidden print:hidden">
        {rows.map((r) => (
          <li key={r.id} className="px-3 py-2.5">
            <div className="flex items-start justify-between gap-3">
              <div className="min-w-0">
                <div className={`truncate font-medium ${r.is_reversal ? 'text-danger-700' : 'text-slate-900'}`}>{whoFor(r)}</div>
                <div className="text-xs text-slate-500">
                  {r.payer !== r.children && r.children ? `Paid by ${r.payer} · ` : ''}
                  {showDate ? `${fmtDate(r.paid_on)} ` : ''}{r.time} · {methodLabel(r.method)}
                  {r.receipt_no != null ? ` · #${r.receipt_no}` : ''}
                </div>
              </div>
              <div className={`shrink-0 text-right font-semibold tabular-nums ${r.is_reversal ? 'text-danger-700' : 'text-money-700'}`}>
                {fmtPKR(r.amount)}
                {r.is_reversal && <div className="text-[11px] font-medium">reversed</div>}
              </div>
            </div>
          </li>
        ))}
      </ul>
      <div className="hidden overflow-x-auto rounded-xl border border-slate-200 sm:block print:block">
        <table className="w-full text-sm">
          <thead className="bg-slate-50 text-xs uppercase tracking-wide text-slate-500">
            <tr>
              <th className={TH}>{showDate ? 'Date' : 'Time'}</th>
              <th className={TH}>Receipt</th>
              <th className={TH}>For</th>
              <th className={TH}>Paid by</th>
              <th className={TH}>Method</th>
              <th className={`${TH} text-right`}>Amount</th>
              <th className={`${TH} hidden xl:table-cell`}>Recorded by</th>
            </tr>
          </thead>
          <tbody className="divide-y divide-slate-100">
            {rows.map((r) => (
              <tr key={r.id} className={r.is_reversal ? 'bg-danger-50/50 text-danger-700' : ''}>
                <td className={`${TD} whitespace-nowrap text-slate-600`}>{showDate ? <>{fmtDate(r.paid_on)} <span className="text-slate-400">{r.time}</span></> : r.time}</td>
                <td className={`${TD} tabular-nums text-slate-600`}>{r.receipt_no != null ? `#${r.receipt_no}` : '-'}</td>
                <td className={TD}>
                  <div className={r.is_reversal ? '' : 'text-slate-900'}>{whoFor(r)}{r.is_reversal && <span className="ml-1 text-xs font-medium">(reversed)</span>}</div>
                  {(r.gr_no || r.class_label) && <div className="text-xs text-slate-400">{[r.gr_no, r.class_label].filter(Boolean).join(' · ')}</div>}
                </td>
                <td className={`${TD} text-slate-600`}>{r.payer !== r.children ? r.payer : <span className="text-slate-400">-</span>}</td>
                <td className={`${TD} whitespace-nowrap text-slate-600`}>{methodLabel(r.method)}</td>
                <td className={`${TD} whitespace-nowrap text-right font-medium tabular-nums ${r.is_reversal ? '' : 'text-money-700'}`}>{fmtPKR(r.amount)}</td>
                <td className={`${TD} hidden whitespace-nowrap text-slate-500 xl:table-cell`}>{r.recorded_by}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </div>
  )
}

/* ============================================================== day book */

/**
 * One day at the counter.
 *
 * WHAT WAS WRONG. The "cash in the drawer" it asked the clerk to count against
 * was the day's cash RECEIPTS, and nothing else. The Rs 3,000 the peon was
 * handed for the generator came out of that same drawer, and the Rs 500 hall
 * rent went into it, so a drawer that was exactly right was reported "Short by
 * Rs 2,500" every day anything was spent. Now the expected cash is fees in cash,
 * plus other income in cash, less expenses paid in cash, with the working shown.
 * Its CSV also had a column called Time that held the date.
 */
function DayBookReport() {
  const [date, setDate] = useState(today())
  const [counted, setCounted] = useState('')
  const fees = useQuery({ queryKey: ['rptReceipts', date, date], queryFn: () => getFeeReceipts(date, date) })
  const other = useQuery({ queryKey: ['ledgerReport', date, date, 'all'], queryFn: () => getLedger(date, date, 'all') })
  const d = fees.data
  const extra = (other.data ?? []).filter((r) => r.category !== 'Fee collection')
  const income = extra.filter((r) => r.kind === 'income')
  const spent = extra.filter((r) => r.kind === 'expense')
  const cash = (m: string | null | undefined) => m === 'cash'
  const feeCash = (d?.by_method ?? []).filter((m) => cash(m.method)).reduce((s, m) => s + m.amount, 0)
  const otherCash = income.filter((r) => cash(r.method)).reduce((s, r) => s + r.debit - r.credit, 0)
  const spentCash = spent.filter((r) => cash(r.method)).reduce((s, r) => s + r.credit - r.debit, 0)
  const expected = feeCash + otherCash - spentCash
  const countedNum = counted.trim() === '' ? null : Number(counted)
  const diff = countedNum == null || Number.isNaN(countedNum) ? null : countedNum - expected

  const csv = () => d && downloadCSV(`day-book_${date}.csv`,
    toCSV(['Time', 'Receipt', 'For', 'Paid by', 'Method', 'Amount'],
      d.rows.map((r) => [r.time, r.receipt_no ?? '', r.children ?? '', r.payer, methodLabel(r.method), r.amount])))

  return (
    <div className="space-y-4">
      <div className="flex flex-wrap items-end gap-2 print:hidden">
        <Chip on={date === today()} onClick={() => setDate(today())}>Today</Chip>
        <label className="block">
          <span className="mb-1 block text-xs font-medium text-slate-500">Day</span>
          <input type="date" value={date} max={today()} onChange={(e) => e.target.value && setDate(e.target.value)} className={`${inputBase} w-auto`} />
        </label>
      </div>
      {(fees.isLoading || other.isLoading) && <Loading what="the day" />}
      {fees.isError && <Failed error={needsUpdate(fees.error) ? new Error(needsUpdate(fees.error)!) : fees.error} />}
      {other.isError && <Failed error={other.error} />}
      {d && other.data && (
        <ReportFrame title="Day book and cash" subtitle={fmtDate(date)} onCSV={d.rows.length ? csv : null}>
          <Tiles>
            <Tile label="Fees taken" value={fmtPKR(d.total)} tone="money" sub={`${d.receipts} receipt${d.receipts === 1 ? '' : 's'}`} />
            <Tile label="Of which in cash" value={fmtPKR(feeCash)} tone="money"
              sub={d.by_method.filter((m) => !cash(m.method)).map((m) => `${methodLabel(m.method)} ${compactRs(m.amount)}`).join(' · ') || 'All of it'} />
            <Tile label="Other income" value={fmtPKR(income.reduce((s, r) => s + r.debit - r.credit, 0))}
              tone={income.length ? 'money' : 'plain'} sub={`${income.length} entr${income.length === 1 ? 'y' : 'ies'}`} />
            <Tile label="Spent" value={fmtPKR(spent.reduce((s, r) => s + r.credit - r.debit, 0))}
              sub={`${spent.length} voucher${spent.length === 1 ? '' : 's'}`} />
          </Tiles>

          {/* -------------------------------------------- the drawer ---- */}
          <div className="mt-4 rounded-2xl border border-slate-200 bg-slate-50 p-4">
            <div className="text-sm font-semibold text-slate-900">Count the cash drawer</div>
            <div className="mt-3 grid gap-4 md:grid-cols-2">
              <table className="w-full text-sm">
                <tbody>
                  <tr><td className="py-0.5 text-slate-600">Fees paid in cash</td><td className="py-0.5 text-right tabular-nums">{fmtPKR(feeCash)}</td></tr>
                  <tr><td className="py-0.5 text-slate-600">plus other income in cash</td><td className="py-0.5 text-right tabular-nums">{fmtPKR(otherCash)}</td></tr>
                  <tr><td className="py-0.5 text-slate-600">less expenses paid in cash</td><td className="py-0.5 text-right tabular-nums">{fmtPKR(spentCash)}</td></tr>
                  <tr className="border-t border-slate-300 font-semibold text-slate-900">
                    <td className="pt-1.5">The drawer should hold</td><td className="pt-1.5 text-right tabular-nums">{fmtPKR(expected)}</td>
                  </tr>
                </tbody>
              </table>
              <div className="print:hidden">
                <label className="block">
                  <span className="mb-1 block text-xs font-medium text-slate-500">Cash you counted, after today&rsquo;s float is put aside</span>
                  <input type="number" inputMode="numeric" min="0" value={counted} onChange={(e) => setCounted(e.target.value)}
                    className={inputClass} placeholder="e.g. 25000" />
                </label>
                {diff != null && (
                  <div className={`mt-2 rounded-xl px-3 py-2 text-sm font-semibold ${diff === 0 ? 'bg-brand-50 text-brand-800 ring-1 ring-brand-100' : 'bg-danger-50 text-danger-800 ring-1 ring-danger-200'}`}>
                    {diff === 0 ? 'It matches exactly.' : `${diff > 0 ? 'Over' : 'Short'} by ${fmtPKR(Math.abs(diff))}.`}
                    {diff !== 0 && <span className="block text-xs font-normal">Check for a receipt or voucher not yet entered, or one entered in the wrong method.</span>}
                  </div>
                )}
              </div>
            </div>
          </div>

          {d.rows.length === 0 ? (
            <div className="mt-4"><Empty title="No fees taken on this day" /></div>
          ) : <ReceiptList rows={d.rows} showDate={false} />}

          {extra.length > 0 && (
            <div className="mt-4 rounded-xl border border-slate-200">
              <div className="border-b border-slate-100 bg-slate-50 px-3 py-2 text-xs font-semibold uppercase tracking-wide text-slate-500">Other money in and out</div>
              <ul className="divide-y divide-slate-100">
                {extra.map((r, i) => (
                  <li key={`${r.reference}-${i}`} className="flex items-start justify-between gap-3 px-3 py-2.5">
                    <div className="min-w-0">
                      <div className="text-sm text-slate-900">{r.particulars}</div>
                      <div className="text-xs text-slate-500">{r.category}{r.party !== '-' ? ` · ${r.party}` : ''} · {methodLabel(r.method)}</div>
                    </div>
                    <div className={`shrink-0 text-sm font-semibold tabular-nums ${r.debit ? 'text-money-700' : 'text-slate-800'}`}>
                      {r.debit ? `+${fmtPKR(r.debit)}` : `-${fmtPKR(r.credit)}`}
                    </div>
                  </li>
                ))}
              </ul>
            </div>
          )}
        </ReportFrame>
      )}
    </div>
  )
}

/* ============================================================ defaulters */

/** "2026-09-01" -> "Sep 2026". en-GB so it never renders American. */
function monthLabel(iso: string): string {
  const d = new Date(`${iso.slice(0, 7)}-01T00:00:00Z`)
  return d.toLocaleDateString('en-GB', { month: 'short', year: 'numeric', timeZone: 'UTC' })
}

function DefaultersReport() {
  const session = useQuery({ queryKey: ['currentSession'], queryFn: getCurrentSession })
  const sessionId = session.data?.id
  // '' = the lifetime running balance (every unpaid challan to date). A month
  // value isolates that ONE billing cycle, for any past month the principal
  // wants: June's list while it is September.
  const [month, setMonth] = useState('')
  const [classFilter, setClassFilter] = useState('')

  const months = useQuery({
    queryKey: ['billedMonths', sessionId],
    queryFn: () => listBilledMonths(sessionId!), enabled: !!sessionId,
  })
  const running = useQuery({
    queryKey: ['rptDefaulters', sessionId],
    queryFn: () => getDefaulters(sessionId!), enabled: !!sessionId && month === '',
  })
  const perMonth = useQuery({
    queryKey: ['rptDefaultersMonth', sessionId, month],
    queryFn: () => getDefaultersMonth(sessionId!, month), enabled: !!sessionId && month !== '',
  })

  const isMonth = month !== ''
  const q = isMonth ? perMonth : running
  const all = useMemo(() => [...(q.data ?? [])].sort((a, b) => b.balance - a.balance), [q.data])
  const byClass = useMemo(() => {
    const m = new Map<string, { n: number; owed: number }>()
    for (const r of all) {
      const x = m.get(r.class_name) ?? { n: 0, owed: 0 }
      m.set(r.class_name, { n: x.n + 1, owed: x.owed + r.balance })
    }
    return [...m.entries()].map(([k, v]) => ({ key: k, label: k, value: v.owed, sub: `${v.n} ${v.n === 1 ? 'child' : 'children'}` }))
      .sort((a, b) => b.value - a.value)
  }, [all])
  const rows = classFilter ? all.filter((r) => r.class_name === classFilter) : all
  const total = rows.reduce((s, r) => s + r.balance, 0)
  const over5k = rows.filter((r) => r.balance >= 5000).length

  const csv = () => downloadCSV(
    isMonth ? `defaulters-${month.slice(0, 7)}.csv` : 'defaulters.csv',
    isMonth
      ? toCSV(['GR', 'Student', 'Class', 'Section', 'Roll', 'Charged', 'Paid', 'Owes'],
          (rows as MonthDefaulter[]).map((r) => [
            r.gr_no ?? '', r.full_name, r.class_name, r.section_name ?? '', r.roll_no ?? '',
            r.charged, r.paid, r.balance]))
      : toCSV(['GR', 'Student', 'Class', 'Section', 'Roll', 'Balance'],
          rows.map((r) => [r.gr_no ?? '', r.full_name, r.class_name, r.section_name ?? '', r.roll_no ?? '', r.balance])))

  return (
    <div className="space-y-4">
      <div className="flex flex-wrap items-end gap-3 print:hidden">
        <label className="block">
          <span className="mb-1 block text-xs font-medium text-slate-500">Billing month</span>
          <select value={month} onChange={(e) => setMonth(e.target.value)} className={`${inputBase} w-auto`}>
            <option value="">Every month this session</option>
            {(months.data ?? []).map((m) => (
              <option key={m.period_month} value={m.period_month}>{monthLabel(m.period_month)}</option>
            ))}
          </select>
        </label>
        {byClass.length > 1 && (
          <label className="block">
            <span className="mb-1 block text-xs font-medium text-slate-500">Class</span>
            <select value={classFilter} onChange={(e) => setClassFilter(e.target.value)} className={`${inputBase} w-auto`}>
              <option value="">Every class</option>
              {byClass.map((c) => <option key={c.key} value={c.key}>{c.label}</option>)}
            </select>
          </label>
        )}
      </div>
      {!sessionId && !session.isLoading && <Failed error={new Error('There is no current session. Set one under Settings, Sessions.')} />}
      {q.isLoading && <Loading />}
      {q.isError && <Failed error={q.error} />}
      {q.data && (
        <ReportFrame title={isMonth ? `Defaulters for ${monthLabel(month)}` : 'Defaulters'}
          subtitle={`${session.data?.name ?? ''}${classFilter ? ` · ${classFilter}` : ''}`} onCSV={rows.length ? csv : null}>
          <Tiles>
            <Tile label={isMonth ? `Owed for ${monthLabel(month)}` : 'Owed in all'} value={fmtPKR(total)} tone={total > 0 ? 'due' : 'plain'} />
            <Tile label="Children owing" value={rows.length} tone={rows.length ? 'due' : 'plain'} />
            <Tile label="Owing Rs 5,000 or more" value={over5k} tone={over5k ? 'danger' : 'plain'} sub="The calls to make first" />
            <Tile label="Biggest single balance" value={rows[0] ? fmtPKR(rows[0].balance) : '-'} sub={rows[0]?.full_name} />
          </Tiles>

          {rows.length === 0 ? (
            <div className="mt-4"><Empty title={isMonth ? 'Nobody owes on that month’s challan' : 'Nobody owes anything'}>
              {isMonth ? 'Every challan for that month has been paid.' : 'Every challan this session has been paid.'}</Empty></div>
          ) : (
            <>
              {!classFilter && byClass.length > 1 && (
                <div className="mt-4 print:hidden">
                  <ChartCard title="Owed by class" subtitle="Tap a class in the list above to see only its children"
                    table={<MiniTable head={['Class', 'Children', 'Owed']} align={['l', 'r', 'r']}
                      rows={byClass.map((c) => [c.label, c.sub, fmtPKR(c.value)])} />}>
                    <HBars rows={byClass} color={C.warn} format={(n) => compactRs(n)} label="Money owed by class" />
                  </ChartCard>
                </div>
              )}
              <ul className="mt-4 divide-y divide-slate-100 rounded-xl border border-slate-200 sm:hidden print:hidden">
                {rows.map((r) => (
                  <li key={r.student_id} className="flex items-start justify-between gap-3 px-3 py-2.5">
                    <div className="min-w-0">
                      <div className="truncate font-medium text-slate-900">{r.full_name}</div>
                      <div className="text-xs text-slate-500">{r.class_name}{r.section_name ? `-${r.section_name}` : ''}{r.gr_no ? ` · ${r.gr_no}` : ''}</div>
                    </div>
                    <div className="shrink-0 font-semibold tabular-nums text-due-800">{fmtPKR(r.balance)}</div>
                  </li>
                ))}
              </ul>
              <div className="mt-4 hidden overflow-x-auto rounded-xl border border-slate-200 sm:block print:block">
                <table className="w-full text-sm">
                  <thead className="bg-slate-50 text-xs uppercase tracking-wide text-slate-500">
                    <tr>
                      <th className={TH}>Student</th><th className={TH}>Class</th><th className={TH}>Roll</th>
                      {isMonth && <th className={`${TH} text-right`}>Charged</th>}
                      {isMonth && <th className={`${TH} text-right`}>Paid</th>}
                      <th className={`${TH} text-right`}>{isMonth ? 'Owes' : 'Balance'}</th>
                    </tr>
                  </thead>
                  <tbody className="divide-y divide-slate-100">
                    {rows.map((r) => (
                      <tr key={r.student_id}>
                        <td className={TD}><div className="text-slate-900">{r.full_name}</div>{r.gr_no && <div className="text-xs text-slate-400">{r.gr_no}</div>}</td>
                        <td className={`${TD} text-slate-600`}>{r.class_name}{r.section_name ? `-${r.section_name}` : ''}</td>
                        <td className={`${TD} text-slate-600`}>{r.roll_no ?? '-'}</td>
                        {isMonth && <td className={`${TD} text-right tabular-nums`}>{fmtPKR((r as MonthDefaulter).charged)}</td>}
                        {isMonth && <td className={`${TD} text-right tabular-nums text-money-700`}>{fmtPKR((r as MonthDefaulter).paid)}</td>}
                        <td className={`${TD} text-right font-semibold tabular-nums text-due-800`}>{fmtPKR(r.balance)}</td>
                      </tr>
                    ))}
                  </tbody>
                  <tfoot className="border-t-2 border-slate-300 font-semibold text-slate-900">
                    <tr><td className={TD} colSpan={isMonth ? 5 : 3}>Total, {rows.length} {rows.length === 1 ? 'child' : 'children'}</td>
                      <td className={`${TD} text-right tabular-nums`}>{fmtPKR(total)}</td></tr>
                  </tfoot>
                </table>
              </div>
            </>
          )}
          <Note>
            {isMonth
              ? 'Who still owes on that one month’s challan. A child who owes for an earlier month but has paid this one is not listed.'
              : 'Everyone who owes anything on this session’s challans, biggest balance first.'}
          </Note>
        </ReportFrame>
      )}
    </div>
  )
}

/* ======================================================== reconciliation */

function ReconciliationReport() {
  const session = useQuery({ queryKey: ['currentSession'], queryFn: getCurrentSession })
  const sessionId = session.data?.id
  const q = useQuery({ queryKey: ['rptRecon', sessionId], queryFn: () => getFeeReconciliation(sessionId!), enabled: !!sessionId })
  const r = q.data

  const csv = () => {
    if (!r) return
    downloadCSV('fee-reconciliation.csv', toCSV(
      ['Class', 'Expected', 'Collected', 'Outstanding', 'Collected %'],
      r.by_class.map((c) => [c.class_name, c.expected, c.collected, c.outstanding, pctOf(c.collected, c.expected)]),
    ))
  }

  return (
    <div className="space-y-4">
      {q.isLoading && <Loading />}
      {q.isError && <Failed error={q.error} />}
      {r && (
        <ReportFrame title="Fee reconciliation: billed against collected" subtitle={session.data?.name} onCSV={r.by_class.length ? csv : null}>
          <Tiles>
            <Tile label="Billed on challans" value={fmtPKR(r.expected)} tone="brand" />
            <Tile label="Collected against them" value={fmtPKR(r.collected)} tone="money" sub={`${pctOf(r.collected, r.expected)}% of what was billed`} />
            <Tile label="Still unpaid" value={fmtPKR(r.outstanding)} tone={r.outstanding > 0 ? 'due' : 'plain'} />
            <Tile label="Never billed" value={r.uninvoiced.length} tone={r.uninvoiced.length ? 'danger' : 'plain'}
              sub={r.uninvoiced.length ? 'Children on the roll with no challan' : 'Every child has a challan'} />
          </Tiles>

          {r.by_class.length > 0 && (
            <div className="mt-4 overflow-x-auto rounded-xl border border-slate-200">
              <table className="w-full text-sm">
                <thead className="bg-slate-50 text-xs uppercase tracking-wide text-slate-500">
                  <tr><th className={TH}>Class</th><th className={`${TH} text-right`}>Billed</th><th className={`${TH} text-right`}>Collected</th>
                    <th className={`${TH} text-right`}>Unpaid</th><th className={`${TH} w-40 hidden sm:table-cell`}>Collected</th></tr>
                </thead>
                <tbody className="divide-y divide-slate-100">
                  {r.by_class.map((c, i) => {
                    const p = pctOf(c.collected, c.expected)
                    return (
                      <tr key={i}>
                        <td className={`${TD} text-slate-900`}>{c.class_name}</td>
                        <td className={`${TD} text-right tabular-nums`}>{fmtPKR(c.expected)}</td>
                        <td className={`${TD} text-right tabular-nums text-money-700`}>{fmtPKR(c.collected)}</td>
                        <td className={`${TD} text-right tabular-nums ${c.outstanding > 0 ? 'font-medium text-due-800' : 'text-slate-400'}`}>{fmtPKR(c.outstanding)}</td>
                        <td className={`${TD} hidden sm:table-cell`}>
                          <div className="flex items-center gap-2">
                            <div className="h-2 flex-1 overflow-hidden rounded-full bg-slate-100" aria-hidden>
                              <div className="h-full rounded-full" style={{ width: `${p}%`, background: C.good }} />
                            </div>
                            <span className="w-9 text-right text-xs tabular-nums text-slate-600">{p}%</span>
                          </div>
                        </td>
                      </tr>
                    )
                  })}
                </tbody>
              </table>
            </div>
          )}
          {r.by_class.length === 0 && <div className="mt-4"><Empty title="No challans yet this session" /></div>}

          <Bridge r={r} />

          <FlagList
            title="Children on the roll never billed this session"
            count={r.uninvoiced.length}
            hint="A billing gap: every child on the roll should have a challan. Look into each name here."
            rows={r.uninvoiced} tone="due"
          />
          <FlagList
            title="Possible ghost pupils"
            count={r.ghost_suspects.length}
            hint="On the roll, never billed, and never marked present. A name that may not be a real, attending child."
            rows={r.ghost_suspects} tone="danger"
          />
        </ReportFrame>
      )}
    </div>
  )
}

/**
 * How this screen's total becomes the dashboard's.
 *
 * The two count different things and both are right. "Billed minus collected"
 * is about CHALLANS, and it is the only figure that can tell a school it billed
 * a class short. The dashboard is about what the children on the roll today owe,
 * which also includes charges keyed by hand and arrears carried in from an
 * earlier session. Every line below is a real query rather than a residual: a
 * row labelled "difference" is how a reconciliation hides the thing it exists
 * to find.
 */
function Bridge({ r }: { r: FeeReconciliation }) {
  const b = r.bridge
  const rows: { label: string; hint: string; value: number }[] = [
    { label: 'Unpaid on this session’s challans', hint: 'For the children on the roll today. The figure above also counts children who have since left.', value: b.on_challans_this_session },
    { label: 'Charges and waivers keyed by hand', hint: 'A van fare, a book, a hardship credit. Real money, never on a challan. See any child’s Statement.', value: b.charges_keyed_by_hand },
    { label: 'Arrears carried in from an earlier session', hint: 'Billed last year, still owed by a child who is here this year.', value: b.arrears_from_earlier_sessions },
  ]
  return (
    <div className="mt-4 rounded-2xl border border-slate-200 bg-slate-50 p-4">
      <div className="text-sm font-semibold text-slate-900">Why the dashboard shows a different number</div>
      <table className="mt-2 w-full text-sm">
        <tbody className="divide-y divide-slate-200">
          {rows.map((x) => (
            <tr key={x.label}>
              <td className="py-2 pr-3"><div className="text-slate-800">{x.label}</div><div className="text-xs text-slate-500">{x.hint}</div></td>
              <td className="whitespace-nowrap py-2 text-right align-top tabular-nums text-slate-800">{fmtPKR(x.value)}</td>
            </tr>
          ))}
          <tr className="border-t-2 border-slate-400 font-semibold">
            <td className="py-2 pr-3 text-slate-900">Total owed by children on the roll
              <div className="text-xs font-normal text-slate-500">This is the Outstanding figure on the dashboard.</div></td>
            <td className="whitespace-nowrap py-2 text-right align-top tabular-nums text-slate-900">{fmtPKR(b.student_outstanding)}</td>
          </tr>
        </tbody>
      </table>
      {b.owed_by_children_no_longer_on_the_roll > 0 && (
        <p className="mt-2 rounded-xl border border-due-200 bg-due-50 px-3 py-2 text-xs text-due-800">
          A further <span className="font-semibold">{fmtPKR(b.owed_by_children_no_longer_on_the_roll)}</span>{' '}
          is owed by children who are no longer on the roll. It is on no tile, because the dashboard counts the
          children who are here, and somebody still has to chase it. Children who left lists them.
        </p>
      )}
    </div>
  )
}

function FlagList({ title, count, hint, rows, tone }: {
  title: string; count: number; hint: string
  rows: { gr_no: string | null; full_name: string; class_name: string }[]; tone: 'due' | 'danger'
}) {
  if (count === 0) {
    return <p className="mt-4 rounded-xl bg-slate-50 px-3 py-2 text-sm text-slate-600">{title}: none found.</p>
  }
  const box = tone === 'danger' ? 'border-danger-200 bg-danger-50' : 'border-due-200 bg-due-50'
  return (
    <div className={`mt-4 rounded-2xl border p-4 ${box}`}>
      <div className="text-sm font-semibold text-slate-900">{title} ({count})</div>
      <div className="text-xs text-slate-600">{hint}</div>
      <div className="mt-2 flex flex-wrap gap-1.5">
        {rows.slice(0, 200).map((s, i) => (
          <span key={i} className="rounded-full bg-white px-2.5 py-0.5 text-xs text-slate-700 ring-1 ring-slate-200">
            {s.full_name}{s.gr_no ? ` · ${s.gr_no}` : ''} <span className="text-slate-400">· {s.class_name}</span>
          </span>
        ))}
        {rows.length > 200 && <span className="text-xs text-slate-500">and {rows.length - 200} more (in the CSV)</span>}
      </div>
    </div>
  )
}

/* ================================================== attendance register */

const CELL: Record<string, string> = {
  present: 'text-money-700', late: 'bg-due-50 text-due-800', half_day: 'bg-due-50 text-due-800',
  absent: 'bg-danger-50 font-semibold text-danger-700', leave: 'bg-info-50 text-info-800',
}

/**
 * The paper register, on screen.
 *
 * WHAT WAS WRONG. It read the marks with one request, and Supabase stops at
 * 1,000 rows. A class of 40 reaches that on the 26th school day, so the last
 * days of every month came back blank, and "All sections" of a class of 80 lost
 * half the month. db.ts now reads every page. It also printed every mark in the
 * same grey, so an absence looked exactly like a presence from arm's length.
 */
function AttendanceRegisterReport() {
  const session = useQuery({ queryKey: ['currentSession'], queryFn: getCurrentSession })
  const sessionId = session.data?.id
  const classes = useQuery({ queryKey: ['classes'], queryFn: listClasses })
  const [classId, setClassId] = useState('')
  const [sectionChoice, setSectionChoice] = useState('')
  const [month, setMonth] = useState(todayISO().slice(0, 7))
  const sections = useQuery({ queryKey: ['sections', classId], queryFn: () => listSections(classId), enabled: !!classId })
  const hasSections = (sections.data?.length ?? 0) > 0
  const sectionId: string | null = hasSections ? (sectionChoice || null) : null

  const ready = !!sessionId && !!classId && !!month
  const q = useQuery({
    queryKey: ['rptRegister', sessionId, classId, sectionId ?? 'all', month],
    queryFn: () => getAttendanceRegister(sessionId!, classId, sectionId, month),
    enabled: ready,
  })
  const reg = q.data
  const dayNums = (reg?.dates ?? []).map((d) => Number(d.slice(-2)))
  const marked = (reg?.dates ?? []).filter((d) => reg!.students.some((s) => s.marks[d]))

  function summary(marks: Record<string, string>) {
    const vals = Object.values(marks)
    const present = vals.filter((v) => v === 'present' || v === 'late' || v === 'half_day').length
    const absent = vals.filter((v) => v === 'absent').length
    const pct = vals.length ? Math.round((present / vals.length) * 100) : null
    return { present, absent, marked: vals.length, pct }
  }
  const sums = (reg?.students ?? []).map((s) => summary(s.marks))
  const classPct = (() => {
    const m = sums.reduce((a, s) => a + s.marked, 0)
    return m ? Math.round((sums.reduce((a, s) => a + s.present, 0) / m) * 100) : null
  })()
  const below75 = sums.filter((s) => s.pct != null && s.pct < 75).length

  const csv = () => {
    if (!reg) return
    const header = ['Roll', 'Student', ...dayNums.map(String), 'Present', 'Absent', '%']
    const rows = reg.students.map((s, i) => [s.roll_no ?? '', s.full_name,
      ...reg.dates.map((d) => ATTENDANCE_SHORT[s.marks[d]] ?? ''), sums[i].present, sums[i].absent, sums[i].pct ?? ''])
    downloadCSV(`attendance-register_${month}.csv`, toCSV(header, rows))
  }

  const clsName = classes.data?.find((c) => c.id === classId)?.name ?? ''
  const secName = sections.data?.find((s) => s.id === sectionId)?.name
  const sunday = (iso: string) => new Date(`${iso}T00:00:00Z`).getUTCDay() === 0

  return (
    <div className="space-y-4">
      <div className="flex flex-wrap items-end gap-2 print:hidden">
        <label className="block"><span className="mb-1 block text-xs font-medium text-slate-500">Class</span>
          <select value={classId} onChange={(e) => { setClassId(e.target.value); setSectionChoice('') }} className={`${inputBase} w-auto`}>
            <option value="">Choose a class…</option>
            {classes.data?.map((c) => <option key={c.id} value={c.id}>{c.name}</option>)}
          </select>
        </label>
        {hasSections && (
          <label className="block"><span className="mb-1 block text-xs font-medium text-slate-500">Section</span>
            <select value={sectionChoice} onChange={(e) => setSectionChoice(e.target.value)} className={`${inputBase} w-auto`}>
              <option value="">Every section</option>
              {sections.data?.map((s) => <option key={s.id} value={s.id}>{s.name}</option>)}
            </select>
          </label>
        )}
        <label className="block"><span className="mb-1 block text-xs font-medium text-slate-500">Month</span>
          <input type="month" value={month} max={todayISO().slice(0, 7)} onChange={(e) => e.target.value && setMonth(e.target.value)} className={`${inputBase} w-auto`} />
        </label>
      </div>
      {!classId && <Empty title="Choose a class">The register for any month of this session, ruled like the paper one.</Empty>}
      {ready && q.isLoading && <Loading what="the register" />}
      {q.isError && <Failed error={q.error} />}
      {reg && (
        <ReportFrame title="Attendance register" subtitle={`${clsName}${secName ? `-${secName}` : ''} · ${monthLabel(`${month}-01`)}`} onCSV={csv}>
          <Tiles>
            <Tile label="Children" value={reg.students.length} tone="brand" />
            <Tile label="Days marked" value={marked.length} sub={`of ${reg.dates.length} in the month`} />
            <Tile label="Present, over the month" value={classPct == null ? '-' : `${classPct}%`}
              tone={classPct == null ? 'plain' : classPct >= 90 ? 'money' : classPct >= 75 ? 'due' : 'danger'} />
            <Tile label="Below 75%" value={below75} tone={below75 ? 'danger' : 'plain'} sub="The board-exam line" />
          </Tiles>
          {reg.students.length === 0 ? (
            <div className="mt-4"><Empty title="Nobody is enrolled here this session" /></div>
          ) : (
            <>
            {/* A PHONE GETS ONE CARD PER CHILD. Thirty-one day columns cannot fit
                a phone, and a grid that scrolls sideways loses the child's name
                off the left the moment it moves. Each card keeps the name, the
                totals, and the month as a strip of small squares. The grid
                itself is still what prints. */}
            <ul className="mt-4 space-y-2 sm:hidden print:hidden">
              {reg.students.map((s, si) => {
                const sm = sums[si]
                return (
                  <li key={s.enrollment_id} className="rounded-xl border border-slate-200 bg-white p-3">
                    <div className="flex items-start justify-between gap-2">
                      <div className="min-w-0 text-sm font-medium text-slate-900">
                        {s.roll_no && <span className="mr-1.5 tabular-nums text-slate-400">{s.roll_no}</span>}{s.full_name}
                      </div>
                      <div className="shrink-0 text-right text-xs tabular-nums text-slate-600">
                        <span className={`text-base font-semibold ${sm.pct == null ? 'text-slate-400' : sm.pct < 75 ? 'text-danger-700' : sm.pct < 90 ? 'text-due-800' : 'text-slate-900'}`}>{sm.pct == null ? '-' : `${sm.pct}%`}</span>
                        <div>{sm.present} P · <span className={sm.absent ? 'text-danger-700' : ''}>{sm.absent} A</span></div>
                      </div>
                    </div>
                    <div className="mt-2 flex flex-wrap gap-0.5" aria-label={`${s.full_name}: ${sm.present} present, ${sm.absent} absent`}>
                      {reg.dates.map((d, di) => {
                        const v = s.marks[d]
                        return (
                          <span key={d} title={`${dayNums[di]}: ${v ?? 'not marked'}`}
                            className={`flex h-5 w-5 items-center justify-center rounded text-[9px] font-semibold ${v ? `${v === 'present' ? 'bg-money-50 ' : ''}${CELL[v] ?? 'bg-slate-100 text-slate-700'}` : sunday(d) ? 'bg-slate-100 text-slate-300' : 'border border-dashed border-slate-200 text-slate-300'}`}>
                            {v ? ATTENDANCE_SHORT[v] ?? '?' : dayNums[di]}
                          </span>
                        )
                      })}
                    </div>
                  </li>
                )
              })}
            </ul>
            <div className="mt-4 hidden overflow-x-auto rounded-xl border border-slate-200 sm:block print:block">
              <table className="w-full border-collapse text-[11px]">
                <thead>
                  <tr className="bg-slate-50 text-slate-500">
                    <th className="sticky left-0 z-10 border-b border-r border-slate-200 bg-slate-50 px-2 py-1.5 text-left">Student</th>
                    {reg.dates.map((d, i) => (
                      <th key={d} className={`w-6 border-b border-slate-200 px-0.5 py-1.5 text-center font-medium ${sunday(d) ? 'bg-slate-100 text-slate-400' : ''}`}>{dayNums[i]}</th>
                    ))}
                    <th className="border-b border-l border-slate-200 px-1.5 py-1.5 text-right">P</th>
                    <th className="border-b border-slate-200 px-1.5 py-1.5 text-right">A</th>
                    <th className="border-b border-slate-200 px-1.5 py-1.5 text-right">%</th>
                  </tr>
                </thead>
                <tbody>
                  {reg.students.map((s, si) => {
                    const sm = sums[si]
                    return (
                      <tr key={s.enrollment_id} className="border-b border-slate-100">
                        <td className="sticky left-0 z-10 whitespace-nowrap border-r border-slate-200 bg-white px-2 py-1 text-slate-800">
                          <span className="mr-1.5 inline-block w-5 text-right tabular-nums text-slate-400">{s.roll_no ?? ''}</span>{s.full_name}
                        </td>
                        {reg.dates.map((d) => {
                          const v = s.marks[d]
                          return <td key={d} className={`px-0.5 py-1 text-center ${v ? CELL[v] ?? 'text-slate-700' : sunday(d) ? 'bg-slate-50 text-slate-300' : 'text-slate-300'}`}>{v ? ATTENDANCE_SHORT[v] ?? '?' : '·'}</td>
                        })}
                        <td className="border-l border-slate-200 px-1.5 py-1 text-right tabular-nums text-slate-700">{sm.present}</td>
                        <td className={`px-1.5 py-1 text-right tabular-nums ${sm.absent ? 'text-danger-700' : 'text-slate-400'}`}>{sm.absent}</td>
                        <td className={`px-1.5 py-1 text-right font-semibold tabular-nums ${sm.pct == null ? 'text-slate-400' : sm.pct < 75 ? 'text-danger-700' : sm.pct < 90 ? 'text-due-800' : 'text-slate-800'}`}>{sm.pct ?? '-'}</td>
                      </tr>
                    )
                  })}
                </tbody>
                <tfoot>
                  <tr className="bg-slate-50 font-medium text-slate-600">
                    <td className="sticky left-0 z-10 border-r border-slate-200 bg-slate-50 px-2 py-1">Present that day</td>
                    {reg.dates.map((d) => {
                      const n = reg.students.filter((s) => ['present', 'late', 'half_day'].includes(s.marks[d])).length
                      const any = reg.students.some((s) => s.marks[d])
                      return <td key={d} className="px-0.5 py-1 text-center tabular-nums">{any ? n : ''}</td>
                    })}
                    <td colSpan={3} className="border-l border-slate-200" />
                  </tr>
                </tfoot>
              </table>
            </div>
            </>
          )}
          <Note>P present · Lt late · ½ half day · L leave · A absent · a dot is a day not marked. Sundays are shaded. Late and half day count as present in the percentage. Prints best in landscape.</Note>
        </ReportFrame>
      )}
    </div>
  )
}

/* ========================================================= student ledger */

/**
 * One student's fee account, from the top. It reads fn_student_ledger, which is
 * the same function behind the Statement on the student profile and behind the
 * parent's copy in the portal: one implementation, three screens, and a running
 * total that closes on student_balance by construction.
 */
function StudentLedgerReport() {
  const [term, setTerm] = useState('')
  const [student, setStudent] = useState<StudentRow | null>(null)
  const results = useQuery({ queryKey: ['ledgerSearch', term], queryFn: () => listStudents(term), enabled: term.trim().length >= 2 && !student })
  const ledger = useQuery({ queryKey: ['ledger', student?.id], queryFn: () => getStudentLedger(student!.id), enabled: !!student })
  const balance = useQuery({ queryKey: ['ledgerBal', student?.id], queryFn: () => getStudentBalance(student!.id), enabled: !!student })
  const charged = (ledger.data ?? []).reduce((s, r) => s + (r.debit || 0), 0)
  const paid = (ledger.data ?? []).reduce((s, r) => s + (r.credit || 0), 0)

  const csv = () => {
    if (!student) return
    downloadCSV(`ledger_${(student.gr_no || student.full_name).replace(/[^a-z0-9]+/gi, '-')}.csv`,
      toCSV(['Date', 'Kind', 'Particulars', 'Reference', 'Charged', 'Paid or off', 'Balance', 'Recorded by'],
        (ledger.data ?? []).map((r) => [
          r.entry_on ? fmtDate(r.entry_on) : '', r.kind, r.particulars, r.reference,
          r.debit || '', r.credit || '', r.balance_after, r.recorded_by,
        ])))
  }

  if (!student) {
    return (
      <div className="max-w-lg space-y-2 print:hidden">
        <label className="block"><span className="mb-1 block text-xs font-medium text-slate-500">Find the child by name or GR number</span>
          <input autoFocus value={term} onChange={(e) => setTerm(e.target.value)} className={inputClass} placeholder="e.g. Ahmed or GR-0001" />
        </label>
        {term.trim().length > 0 && term.trim().length < 2 && <p className="text-xs text-slate-500">Type at least two letters.</p>}
        {results.isError && <Failed error={results.error} />}
        {(results.data?.length ?? 0) > 0 && (
          <ul className="divide-y divide-slate-100 overflow-hidden rounded-xl border border-slate-200 bg-white shadow-card">
            {results.data!.map((s) => (
              <li key={s.id}>
                <button onClick={() => setStudent(s)} className="block w-full px-3 py-2.5 text-left text-sm hover:bg-brand-50">
                  <span className="font-medium text-slate-900">{s.full_name}</span>
                  {s.father_name && <span className="text-slate-500"> · {s.father_name}</span>}
                  {s.gr_no && <span className="text-slate-400"> · {s.gr_no}</span>}
                </button>
              </li>
            ))}
          </ul>
        )}
        {results.data?.length === 0 && term.trim().length >= 2 && <Empty title="No child by that name or number" />}
      </div>
    )
  }

  return (
    <div className="space-y-3">
      <div className="flex flex-wrap items-center justify-between gap-2 print:hidden">
        <div className="text-sm text-slate-700"><span className="font-semibold text-slate-900">{student.full_name}</span>{student.gr_no ? ` · ${student.gr_no}` : ''}</div>
        <button onClick={() => { setStudent(null); setTerm('') }} className={buttonClass({ variant: 'soft', tone: 'neutral', size: 'sm' })}>Another child</button>
      </div>
      {ledger.isLoading && <Loading what="the account" />}
      {ledger.isError && <Failed error={ledger.error} />}
      {ledger.data && (
        <ReportFrame title="Student fee ledger" subtitle={`${student.full_name}${student.gr_no ? ` · ${student.gr_no}` : ''}`} onCSV={csv}>
          <Tiles>
            <Tile label="Charged, all time" value={fmtPKR(charged)} tone="brand" />
            <Tile label="Paid or taken off" value={fmtPKR(paid)} tone="money" />
            <Tile label="Owes now" value={fmtPKR(balance.data ?? 0)} tone={(balance.data ?? 0) > 0 ? 'due' : 'plain'} />
            <Tile label="Entries" value={ledger.data.length} />
          </Tiles>
          <div className="mt-4"><FeeStatement entries={ledger.data} balance={balance.data ?? 0} showRecordedBy /></div>
          <Note>Charged is what was added to the account. Paid or off is a payment, a discount or a waiver. Balance is what was owed after that entry.</Note>
        </ReportFrame>
      )}
    </div>
  )
}

/* ====================================================== dues by fee head */

/**
 * Charged and collected, per fee head: WHICH CHARGE is not being paid. The
 * apportionment is stated on the page: a payment is made against a challan,
 * not against a line of it, so each head's collected figure is its share of
 * the challan times how much of the challan was paid.
 */
function HeadWiseDuesReport() {
  const session = useQuery({ queryKey: ['currentSession'], queryFn: getCurrentSession })
  const sessionId = session.data?.id
  const q = useQuery({ queryKey: ['rptHeadWise', sessionId], queryFn: () => getHeadWiseDues(sessionId!), enabled: !!sessionId })
  const heads = (q.data?.heads ?? []).map((h) => ({ ...h, charged: Number(h.charged), collected: Number(h.collected) }))
    .map((h) => ({ ...h, owed: Math.max(0, h.charged - h.collected) }))
    .sort((a, b) => b.owed - a.owed)
  // The totals come from the CHALLANS, not from summing the rows: splitting a
  // payment across heads is a division, and it does not add back exactly.
  const tot = { charged: q.data?.total_charged ?? 0, collected: q.data?.total_collected ?? 0, outstanding: q.data?.total_outstanding ?? 0 }

  const csv = () => downloadCSV('dues-by-fee-head.csv',
    toCSV(['Fee head', 'Charged', 'Collected', 'Outstanding', 'Collected %'],
      heads.map((h) => [h.fee_head, h.charged, h.collected, h.owed, pctOf(h.collected, h.charged)])))

  return (
    <div className="space-y-4">
      {q.isLoading && <Loading />}
      {q.isError && <Failed error={q.error} />}
      {q.data && (
        <ReportFrame title="Dues by fee head" subtitle={session.data?.name} onCSV={heads.length ? csv : null}>
          <Tiles>
            <Tile label="Charged" value={fmtPKR(tot.charged)} tone="brand" />
            <Tile label="Collected" value={fmtPKR(tot.collected)} tone="money" sub={`${pctOf(tot.collected, tot.charged)}%`} />
            <Tile label="Outstanding" value={fmtPKR(tot.outstanding)} tone={tot.outstanding > 0 ? 'due' : 'plain'} />
            <Tile label="Worst collected" value={heads.filter((h) => h.charged > 0).sort((a, b) => pctOf(a.collected, a.charged) - pctOf(b.collected, b.charged))[0]?.fee_head ?? '-'}
              sub="The charge families pay least of" />
          </Tiles>
          {heads.length === 0 ? (
            <div className="mt-4"><Empty title="Nothing has been billed this session yet" /></div>
          ) : (
            <div className="mt-4 grid gap-4 lg:grid-cols-2">
              <ChartCard title="Still owed, by charge" className="print:hidden">
                <HBars rows={heads.map((h) => ({ key: h.fee_head, label: h.fee_head, value: h.owed, sub: `${pctOf(h.collected, h.charged)}% collected` }))}
                  color={C.warn} format={(n) => compactRs(n)} label="Outstanding by fee head" />
              </ChartCard>
              <div className="overflow-x-auto rounded-xl border border-slate-200">
                <table className="w-full text-sm">
                  <thead className="bg-slate-50 text-xs uppercase tracking-wide text-slate-500">
                    <tr><th className={TH}>Fee head</th><th className={`${TH} text-right`}>Charged</th><th className={`${TH} text-right`}>Collected</th><th className={`${TH} text-right`}>Owed</th></tr>
                  </thead>
                  <tbody className="divide-y divide-slate-100">
                    {heads.map((h) => (
                      <tr key={h.fee_head}>
                        <td className={`${TD} text-slate-900`}>{h.fee_head}<div className="text-xs text-slate-400">{h.charged > 0 ? `${pctOf(h.collected, h.charged)}% collected` : 'Nothing charged'}</div></td>
                        <td className={`${TD} text-right tabular-nums`}>{fmtPKR(h.charged)}</td>
                        <td className={`${TD} text-right tabular-nums text-money-700`}>{fmtPKR(h.collected)}</td>
                        <td className={`${TD} text-right font-medium tabular-nums ${h.owed > 0 ? 'text-due-800' : 'text-slate-400'}`}>{fmtPKR(h.owed)}</td>
                      </tr>
                    ))}
                  </tbody>
                  <tfoot className="border-t-2 border-slate-300 font-semibold text-slate-900">
                    <tr><td className={TD}>Total</td><td className={`${TD} text-right tabular-nums`}>{fmtPKR(tot.charged)}</td>
                      <td className={`${TD} text-right tabular-nums`}>{fmtPKR(tot.collected)}</td><td className={`${TD} text-right tabular-nums`}>{fmtPKR(tot.outstanding)}</td></tr>
                  </tfoot>
                </table>
              </div>
            </div>
          )}
          {q.data.basis && <Note>{q.data.basis}</Note>}
        </ReportFrame>
      )}
    </div>
  )
}

/* ========================================================= class strength */

function StrengthReport() {
  const session = useQuery({ queryKey: ['currentSession'], queryFn: getCurrentSession })
  const sessionId = session.data?.id
  const q = useQuery({ queryKey: ['rptStrength', sessionId], queryFn: () => getClassStrength(sessionId!), enabled: !!sessionId })
  const rows = q.data ?? []
  const tot = rows.reduce((a, r) => ({ boys: a.boys + r.boys, girls: a.girls + r.girls, other: a.other + r.other, total: a.total + r.total }), { boys: 0, girls: 0, other: 0, total: 0 })
  // One column per class, sections added together, so the chart reads the
  // school's shape and the table below keeps the sections.
  const perClass = useMemo(() => {
    const m = new Map<string, { label: string; order: number; boys: number; girls: number; other: number }>()
    for (const r of rows) {
      const x = m.get(r.class_name) ?? { label: r.class_name, order: r.level_order, boys: 0, girls: 0, other: 0 }
      m.set(r.class_name, { ...x, boys: x.boys + r.boys, girls: x.girls + r.girls, other: x.other + r.other })
    }
    return [...m.values()].sort((a, b) => a.order - b.order)
  }, [rows])
  const parts = (x: { boys: number; girls: number; other: number }): Segment[] => [
    { key: 'boys', label: 'Boys', value: x.boys, color: C.series },
    { key: 'girls', label: 'Girls', value: x.girls, color: C.info },
    ...(x.other ? [{ key: 'other', label: 'Not recorded', value: x.other, color: C.none }] : []),
  ]
  const biggest = [...rows].sort((a, b) => b.total - a.total)[0]

  const csv = () => downloadCSV('class-strength.csv',
    toCSV(['Class', 'Section', 'Boys', 'Girls', 'Not recorded', 'Total'],
      rows.map((r) => [r.class_name, r.section_name ?? '', r.boys, r.girls, r.other, r.total])))

  return (
    <div className="space-y-4">
      {q.isLoading && <Loading />}
      {q.isError && <Failed error={q.error} />}
      {q.data && (
        <ReportFrame title="Class strength" subtitle={session.data?.name} onCSV={rows.length ? csv : null}>
          <Tiles>
            <Tile label="On the roll" value={tot.total} tone="brand" sub={`in ${perClass.length} class${perClass.length === 1 ? '' : 'es'}`} />
            <Tile label="Boys" value={tot.boys} sub={`${pctOf(tot.boys, tot.total)}%`} />
            <Tile label="Girls" value={tot.girls} sub={`${pctOf(tot.girls, tot.total)}%`} />
            <Tile label="Biggest section" value={biggest ? biggest.total : '-'} sub={biggest ? `${biggest.class_name}${biggest.section_name ? `-${biggest.section_name}` : ''}` : undefined} />
          </Tiles>
          {rows.length === 0 ? (
            <div className="mt-4"><Empty title="Nobody is enrolled this session yet" /></div>
          ) : (
            <>
              <div className="mt-4 print:hidden">
                <ChartCard title="Children in each class"
                  subtitle={<span className="inline-flex flex-wrap gap-x-3">{parts(tot).map((p) => (
                    <span key={p.key} className="inline-flex items-center gap-1"><span className="h-2 w-2 rounded-sm" style={{ background: p.color }} />{p.label}</span>))}</span>}
                  table={<MiniTable head={['Class', 'Boys', 'Girls', 'Total']} align={['l', 'r', 'r', 'r']}
                    rows={perClass.map((c) => [c.label, c.boys, c.girls, c.boys + c.girls + c.other])} />}>
                  <StackedColumns label="Children in each class, boys and girls"
                    data={perClass.map((c) => ({ key: c.label, label: c.label, parts: parts(c), tipTitle: c.label }))}
                    formatTick={(n) => String(n)} formatCap={(n) => String(n)} formatFull={(n) => String(n)} />
                </ChartCard>
              </div>
              <div className="mt-4 overflow-x-auto rounded-xl border border-slate-200">
                <table className="w-full text-sm">
                  <thead className="bg-slate-50 text-xs uppercase tracking-wide text-slate-500">
                    <tr><th className={TH}>Class</th><th className={`${TH} text-right`}>Boys</th><th className={`${TH} text-right`}>Girls</th>
                      {tot.other > 0 && <th className={`${TH} text-right`}>Not recorded</th>}<th className={`${TH} text-right`}>Total</th>
                      <th className={`${TH} hidden w-32 sm:table-cell`}><span className="sr-only">Split</span></th></tr>
                  </thead>
                  <tbody className="divide-y divide-slate-100">
                    {rows.map((r, i) => (
                      <tr key={i}>
                        <td className={`${TD} text-slate-900`}>{r.class_name}{r.section_name ? <span className="text-slate-500">-{r.section_name}</span> : ''}</td>
                        <td className={`${TD} text-right tabular-nums`}>{r.boys}</td>
                        <td className={`${TD} text-right tabular-nums`}>{r.girls}</td>
                        {tot.other > 0 && <td className={`${TD} text-right tabular-nums text-slate-500`}>{r.other}</td>}
                        <td className={`${TD} text-right font-semibold tabular-nums`}>{r.total}</td>
                        <td className={`${TD} hidden sm:table-cell`}><StackBar parts={parts(r)} height={6} label={`${r.boys} boys, ${r.girls} girls`} /></td>
                      </tr>
                    ))}
                  </tbody>
                  <tfoot className="border-t-2 border-slate-300 font-semibold text-slate-900">
                    <tr><td className={TD}>Total</td><td className={`${TD} text-right tabular-nums`}>{tot.boys}</td><td className={`${TD} text-right tabular-nums`}>{tot.girls}</td>
                      {tot.other > 0 && <td className={`${TD} text-right tabular-nums`}>{tot.other}</td>}<td className={`${TD} text-right tabular-nums`}>{tot.total}</td><td className="hidden sm:table-cell" /></tr>
                  </tfoot>
                </table>
              </div>
              {tot.other > 0 && <Note>{tot.other} {tot.other === 1 ? 'child has' : 'children have'} no gender on their record. It can be filled in on each child&rsquo;s profile.</Note>}
            </>
          )}
        </ReportFrame>
      )}
    </div>
  )
}

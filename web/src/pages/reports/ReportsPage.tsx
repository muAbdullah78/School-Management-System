import { useState, type ReactNode } from 'react'
import { useQuery } from '@tanstack/react-query'
import {
  getCurrentSession, getDefaulters, listCollections, getClassStrength,
  listClasses, listSections, getAttendanceRegister,
  listStudents, getStudentBalance, getStudentLedger,
  getFeeReconciliation, getHeadWiseDues, type FeeReconciliation,
  type StudentRow,
} from '@/lib/db'
import { useSchoolName } from '@/hooks/useSchoolName'
import { ATTENDANCE_SHORT } from '@/lib/constants'
import { fmtPKR, fmtDate, todayISO } from '@/lib/format'
import { toCSV, downloadCSV } from '@/lib/csv'
import { FeeStatement } from '@/components/FeeStatement'

const FIELD = 'rounded border border-slate-300 px-3 py-2 text-sm focus:border-brand-500 focus:outline-none focus:ring-1 focus:ring-brand-500'
const TABS = [
  { key: 'collection', label: 'Fee Collection' },
  // The money reports a head teacher asks for at month end. "Debit & Credit"
  // also serves as the detailed income and detailed expense reports via its
  // own filter, which is why there are four tabs and not six.
  { key: 'statement', label: 'Debit & Credit' },
  { key: 'unpaid', label: 'Unpaid Challans' },
  // Which CHARGE is not being paid, as opposed to which family is not paying.
  // fn_head_wise_dues shipped in the fee-operations work and had a wrapper in
  // db.ts with no caller anywhere, so a school could see that Rs 400,000 was
  // outstanding and never that Rs 380,000 of it was the transport charge nobody
  // agreed to.
  { key: 'headwise', label: 'Dues by Fee Head' },
  { key: 'discounts', label: 'Discounts' },
  // 0087. The competitor calls this "Deleted Fees". Nothing is deleted: a
  // cancelled challan keeps its row and stops counting, and this is the register
  // that says who withdrew it and why. A clerk may read it and may not cancel.
  { key: 'voided', label: 'Cancelled Charges' },
  { key: 'admissions', label: 'Admissions' },
  // The counterpart of Admissions, and impossible before 0054 gave a leaving a
  // date. "How many left this term" is the number a proprietor watches hardest.
  { key: 'left', label: 'Children Who Left' },
  // A position as at one day, not a range, which is why it sits apart from
  // the four above and is the only report here that is not a table.
  { key: 'balancesheet', label: 'Balance Sheet' },
  // Oversight, not money. mark_entries has recorded the previous mark since the
  // exam module was built and nothing ever read it, so a school held the answer
  // to a disputed mark and could not get at it.
  { key: 'markfixes', label: 'Mark Changes' },
  { key: 'attfixes', label: 'Attendance Changes' },
  { key: 'daybook', label: 'Day Book / Cash' },
  { key: 'reconciliation', label: 'Reconciliation' },
  { key: 'defaulters', label: 'Defaulters' },
  { key: 'strength', label: 'Class Strength' },
  { key: 'register', label: 'Attendance Register' },
  // Not a money report: the sheet a class teacher pins up, and the screen where
  // a whole class actually gets photographed.
  { key: 'photos', label: 'Class Photo Sheet' },
  { key: 'ledger', label: 'Student Ledger' },
] as const

import {
  LedgerReport, UnpaidInvoicesReport, DiscountsReport, AdmissionsReport,
  BalanceSheetReport, MarkCorrectionsReport, AttendanceCorrectionsReport,
  StudentsLeftReport, VoidedChargesReport,
} from './FinanceReports'
import { ClassPhotoSheet } from './ClassPhotoSheet'

type TabKey = (typeof TABS)[number]['key']

function monthStart() { return `${todayISO().slice(0, 7)}-01` }
function thisMonth() { return todayISO().slice(0, 7) }

export function ReportsPage() {
  const [tab, setTab] = useState<TabKey>('collection')
  return (
    <div>
      <h1 className="text-xl font-semibold text-slate-800">Reports</h1>
      <div className="mt-4 flex flex-wrap gap-1 border-b border-slate-200 print:hidden">
        {TABS.map((t) => (
          <button key={t.key} onClick={() => setTab(t.key)}
            className={`-mb-px border-b-2 px-4 py-2 text-sm ${tab === t.key ? 'border-brand-600 font-medium text-brand-700' : 'border-transparent text-slate-500 hover:text-slate-700'}`}>
            {t.label}
          </button>
        ))}
      </div>
      <div className="mt-5">
        {tab === 'collection' && <CollectionReport />}
        {tab === 'statement' && <LedgerReport />}
        {tab === 'unpaid' && <UnpaidInvoicesReport />}
        {tab === 'discounts' && <DiscountsReport />}
        {tab === 'voided' && <VoidedChargesReport />}
        {tab === 'admissions' && <AdmissionsReport />}
        {tab === 'left' && <StudentsLeftReport />}
        {tab === 'balancesheet' && <BalanceSheetReport />}
        {tab === 'markfixes' && <MarkCorrectionsReport />}
        {tab === 'attfixes' && <AttendanceCorrectionsReport />}
        {tab === 'daybook' && <DayBookReport />}
        {tab === 'reconciliation' && <ReconciliationReport />}
        {tab === 'defaulters' && <DefaultersReport />}
        {tab === 'photos' && <ClassPhotoSheet />}
        {tab === 'strength' && <StrengthReport />}
        {tab === 'register' && <AttendanceRegisterReport />}
        {tab === 'ledger' && <StudentLedgerReport />}
        {tab === 'headwise' && <HeadWiseDuesReport />}
      </div>
    </div>
  )
}

function ReportShell({ title, subtitle, onCSV, children }: {
  title: string; subtitle?: string; onCSV: () => void; children: ReactNode
}) {
  const schoolName = useSchoolName()
  return (
    <div>
      <div className="mb-3 flex items-center justify-between print:hidden">
        <div className="text-sm text-slate-500">{subtitle}</div>
        <div className="flex gap-2">
          <button onClick={onCSV} className="rounded border border-slate-300 px-3 py-1.5 text-sm font-medium text-slate-700 hover:bg-slate-50">Download CSV</button>
          <button onClick={() => window.print()} className="rounded bg-brand-600 px-3 py-1.5 text-sm font-medium text-white hover:bg-brand-700">Print</button>
        </div>
      </div>
      <div id="report" className="rounded-lg border border-slate-200 bg-white p-4 print:border-0">
        <div className="mb-3 border-b border-slate-200 pb-2">
          <div className="text-lg font-bold text-slate-800">{schoolName}</div>
          <div className="text-sm text-slate-600">{title}{subtitle ? ` · ${subtitle}` : ''}</div>
        </div>
        {children}
      </div>
    </div>
  )
}

const TH = 'px-3 py-2 text-left font-medium'
const TD = 'px-3 py-1.5'

function CollectionReport() {
  const [from, setFrom] = useState(monthStart())
  const [to, setTo] = useState(todayISO())
  const q = useQuery({ queryKey: ['rptCollection', from, to], queryFn: () => listCollections(from, to) })
  const rows = q.data ?? []
  const total = rows.reduce((s, r) => s + r.amount, 0)
  const byMethod = rows.reduce<Record<string, number>>((m, r) => { m[r.method] = (m[r.method] ?? 0) + r.amount; return m }, {})

  const csv = () => downloadCSV(`fee-collection_${from}_to_${to}.csv`,
    toCSV(['Date', 'Receipt', 'Student', 'GR', 'Method', 'Amount', 'Note'],
      rows.map((r) => [fmtDate(r.created_at), r.receipt_no ?? '', r.student_name ?? '', r.gr_no ?? '', r.method, r.amount, r.note ?? ''])))

  return (
    <div>
      <div className="mb-3 flex flex-wrap items-end gap-2 print:hidden">
        <label className="block"><span className="text-sm text-slate-600">From</span><br /><input type="date" value={from} onChange={(e) => setFrom(e.target.value)} className={`mt-1 ${FIELD}`} /></label>
        <label className="block"><span className="text-sm text-slate-600">To</span><br /><input type="date" value={to} onChange={(e) => setTo(e.target.value)} className={`mt-1 ${FIELD}`} /></label>
      </div>
      <ReportShell title="Fee Collection Report" subtitle={`${fmtDate(from)} to ${fmtDate(to)}`} onCSV={csv}>
        {q.isLoading && <p className="text-sm text-slate-500">Loading…</p>}
        {q.isError && <p className="text-sm text-red-600">{(q.error as Error).message}</p>}
        {!q.isLoading && (
          <>
            <div className="mb-3 flex flex-wrap gap-4 text-sm">
              <span className="font-semibold text-slate-800">Total collected: {fmtPKR(total)}</span>
              {Object.entries(byMethod).map(([m, v]) => <span key={m} className="text-slate-600">{m}: {fmtPKR(v)}</span>)}
              <span className="text-slate-500">{rows.length} entries</span>
            </div>
            <div className="overflow-x-auto">
              <table className="w-full text-sm">
                <thead className="bg-slate-50 text-xs uppercase tracking-wide text-slate-500">
                  <tr><th className={TH}>Date</th><th className={TH}>Receipt</th><th className={TH}>Student</th><th className={TH}>Method</th><th className={`${TH} text-right`}>Amount</th></tr>
                </thead>
                <tbody className="divide-y divide-slate-100">
                  {rows.length === 0 && <tr><td colSpan={5} className={`${TD} text-slate-500`}>No payments in this range.</td></tr>}
                  {rows.map((r) => (
                    <tr key={r.id} className={r.is_reversal ? 'text-red-600' : ''}>
                      <td className={TD}>{fmtDate(r.created_at)}</td>
                      <td className={TD}>{r.receipt_no ?? '-'}</td>
                      <td className={TD}>{r.student_name ?? '-'}{r.gr_no ? <span className="text-slate-400"> · {r.gr_no}</span> : ''}{r.is_reversal ? ' (reversal)' : ''}</td>
                      <td className={TD}>{r.method}</td>
                      <td className={`${TD} text-right tabular-nums`}>{fmtPKR(r.amount)}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          </>
        )}
      </ReportShell>
    </div>
  )
}

function DefaultersReport() {
  const session = useQuery({ queryKey: ['currentSession'], queryFn: getCurrentSession })
  const sessionId = session.data?.id
  const q = useQuery({ queryKey: ['rptDefaulters', sessionId], queryFn: () => getDefaulters(sessionId!), enabled: !!sessionId })
  const rows = q.data ?? []
  const total = rows.reduce((s, r) => s + r.balance, 0)

  const csv = () => downloadCSV('defaulters.csv',
    toCSV(['GR', 'Student', 'Class', 'Section', 'Roll', 'Balance'],
      rows.map((r) => [r.gr_no ?? '', r.full_name, r.class_name, r.section_name ?? '', r.roll_no ?? '', r.balance])))

  return (
    <ReportShell title="Fee Defaulters" subtitle={session.data?.name} onCSV={csv}>
      {q.isLoading && <p className="text-sm text-slate-500">Loading…</p>}
      {!q.isLoading && (
        <>
          <div className="mb-3 text-sm"><span className="font-semibold text-slate-800">Total outstanding: {fmtPKR(total)}</span> <span className="text-slate-500">· {rows.length} students</span></div>
          <div className="overflow-x-auto">
            <table className="w-full text-sm">
              <thead className="bg-slate-50 text-xs uppercase tracking-wide text-slate-500">
                <tr><th className={TH}>GR</th><th className={TH}>Student</th><th className={TH}>Class</th><th className={TH}>Roll</th><th className={`${TH} text-right`}>Balance</th></tr>
              </thead>
              <tbody className="divide-y divide-slate-100">
                {rows.length === 0 && <tr><td colSpan={5} className={`${TD} text-slate-500`}>No defaulters. 🎉</td></tr>}
                {rows.map((r) => (
                  <tr key={r.student_id}>
                    <td className={TD}>{r.gr_no ?? '-'}</td>
                    <td className={TD}>{r.full_name}</td>
                    <td className={TD}>{r.class_name}{r.section_name ? ` · ${r.section_name}` : ''}</td>
                    <td className={TD}>{r.roll_no ?? '-'}</td>
                    <td className={`${TD} text-right tabular-nums`}>{fmtPKR(r.balance)}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </>
      )}
    </ReportShell>
  )
}

function DayBookReport() {
  const [date, setDate] = useState(todayISO())
  const [counted, setCounted] = useState('')
  const q = useQuery({ queryKey: ['rptDaybook', date], queryFn: () => listCollections(date, date) })
  const rows = q.data ?? []
  const byMethod = rows.reduce<Record<string, number>>((m, r) => { m[r.method] = (m[r.method] ?? 0) + r.amount; return m }, {})
  const total = rows.reduce((s, r) => s + r.amount, 0)
  const systemCash = byMethod['cash'] ?? 0
  const countedNum = counted === '' ? null : Number(counted)
  const diff = countedNum == null ? null : countedNum - systemCash

  const csv = () => downloadCSV(`day-book_${date}.csv`,
    toCSV(['Receipt', 'Time', 'Student', 'GR', 'Method', 'Amount'],
      rows.map((r) => [r.receipt_no ?? '', fmtDate(r.created_at), r.student_name ?? '', r.gr_no ?? '', r.method, r.amount])))

  return (
    <div>
      <div className="mb-3 flex flex-wrap items-end gap-2 print:hidden">
        <label className="block"><span className="text-sm text-slate-600">Date</span><br />
          <input type="date" value={date} max={todayISO()} onChange={(e) => setDate(e.target.value)} className={`mt-1 ${FIELD}`} /></label>
      </div>
      <ReportShell title="Day Book / Cash Reconciliation" subtitle={fmtDate(date)} onCSV={csv}>
        {q.isLoading && <p className="text-sm text-slate-500">Loading…</p>}
        {!q.isLoading && (
          <>
            <div className="mb-4 grid grid-cols-2 gap-3 sm:grid-cols-4">
              <Stat label="Total collected" value={fmtPKR(total)} tone="slate" />
              <Stat label="Cash (system)" value={fmtPKR(systemCash)} tone="emerald" />
              {Object.entries(byMethod).filter(([m]) => m !== 'cash').map(([m, v]) => (
                <Stat key={m} label={m} value={fmtPKR(v)} tone="slate" />
              ))}
            </div>

            <div className="mb-4 rounded-lg border border-slate-200 bg-slate-50 p-3 print:hidden">
              <div className="text-sm font-medium text-slate-700">Reconcile the cash drawer</div>
              <div className="mt-2 flex flex-wrap items-end gap-3">
                <label className="block"><span className="text-xs text-slate-500">Cash counted in drawer</span><br />
                  <input type="number" min="0" value={counted} onChange={(e) => setCounted(e.target.value)} className={`mt-1 ${FIELD}`} placeholder="e.g. 25000" /></label>
                {diff != null && (
                  <div className={`rounded px-3 py-2 text-sm font-medium ${diff === 0 ? 'bg-emerald-100 text-emerald-800' : 'bg-red-100 text-red-800'}`}>
                    {diff === 0 ? 'Balances exactly ✓' : `${diff > 0 ? 'Over' : 'Short'} by ${fmtPKR(Math.abs(diff))}`}
                  </div>
                )}
              </div>
            </div>

            <div className="overflow-x-auto">
              <table className="w-full text-sm">
                <thead className="bg-slate-50 text-xs uppercase tracking-wide text-slate-500">
                  <tr><th className={TH}>Receipt</th><th className={TH}>Student</th><th className={TH}>Method</th><th className={`${TH} text-right`}>Amount</th></tr>
                </thead>
                <tbody className="divide-y divide-slate-100">
                  {rows.length === 0 && <tr><td colSpan={4} className={`${TD} text-slate-500`}>No payments on this day.</td></tr>}
                  {rows.map((r) => (
                    <tr key={r.id} className={r.is_reversal ? 'text-red-600' : ''}>
                      <td className={TD}>#{r.receipt_no ?? '-'}</td>
                      <td className={TD}>{r.student_name ?? '-'}{r.gr_no ? <span className="text-slate-400"> · {r.gr_no}</span> : ''}{r.is_reversal ? ' (reversal)' : ''}</td>
                      <td className={TD}>{r.method}</td>
                      <td className={`${TD} text-right tabular-nums`}>{fmtPKR(r.amount)}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          </>
        )}
      </ReportShell>
    </div>
  )
}

function ReconciliationReport() {
  const session = useQuery({ queryKey: ['currentSession'], queryFn: getCurrentSession })
  const sessionId = session.data?.id
  const q = useQuery({ queryKey: ['rptRecon', sessionId], queryFn: () => getFeeReconciliation(sessionId!), enabled: !!sessionId })
  const r = q.data

  const csv = () => {
    if (!r) return
    downloadCSV('fee-reconciliation.csv', toCSV(
      ['Class', 'Expected', 'Collected', 'Outstanding'],
      r.by_class.map((c) => [c.class_name, c.expected, c.collected, c.outstanding]),
    ))
  }

  return (
    <ReportShell title="Fee Reconciliation: expected vs collected" subtitle={session.data?.name} onCSV={csv}>
      {q.isLoading && <p className="text-sm text-slate-500">Loading…</p>}
      {q.isError && <p className="text-sm text-red-600">{(q.error as Error).message}</p>}
      {r && (
        <>
          <div className="mb-4 grid grid-cols-3 gap-3">
            <Stat label="Expected (billed)" value={fmtPKR(r.expected)} tone="slate" />
            <Stat label="Collected" value={fmtPKR(r.collected)} tone="emerald" />
            <Stat label="Unpaid on challans" value={fmtPKR(r.outstanding)} tone={r.outstanding > 0 ? 'red' : 'emerald'} />
          </div>

          <Bridge r={r} />

          <div className="overflow-x-auto">
            <table className="w-full text-sm">
              <thead className="bg-slate-50 text-xs uppercase tracking-wide text-slate-500">
                <tr><th className={TH}>Class</th><th className={`${TH} text-right`}>Expected</th><th className={`${TH} text-right`}>Collected</th><th className={`${TH} text-right`}>Outstanding</th></tr>
              </thead>
              <tbody className="divide-y divide-slate-100">
                {r.by_class.length === 0 && <tr><td colSpan={4} className={`${TD} text-slate-500`}>No invoices yet this session.</td></tr>}
                {r.by_class.map((c, i) => (
                  <tr key={i}>
                    <td className={TD}>{c.class_name}</td>
                    <td className={`${TD} text-right tabular-nums`}>{fmtPKR(c.expected)}</td>
                    <td className={`${TD} text-right tabular-nums`}>{fmtPKR(c.collected)}</td>
                    <td className={`${TD} text-right tabular-nums ${c.outstanding > 0 ? 'text-red-600' : ''}`}>{fmtPKR(c.outstanding)}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>

          <FlagList
            title={`Active students never billed this session (${r.uninvoiced.length})`}
            hint="A billing gap: every active student should have a challan. Investigate any names here."
            rows={r.uninvoiced} tone="amber"
          />
          <FlagList
            title={`Possible ghost students (${r.ghost_suspects.length})`}
            hint="Active, never billed, AND never marked present. A name on the roll that may not be a real, attending child."
            rows={r.ghost_suspects} tone="red"
          />
        </>
      )}
    </ReportShell>
  )
}

/**
 * How this screen's total becomes the dashboard's.
 *
 * The two count different things and both are right. "Expected minus collected"
 * is about CHALLANS, and it is the only figure that can tell a school it billed
 * a class short. The dashboard is about what the children on the roll today owe,
 * which also includes charges keyed by hand and arrears carried in from an
 * earlier session.
 *
 * Before this, the difference was simply unexplained. An owner who opened both
 * in one morning saw Rs 8,100 here and Rs 8,350 there, with nothing anywhere to
 * say which was wrong, and the honest conclusion available to them was that
 * neither could be trusted. Every line below is a real query rather than a
 * residual: a row labelled "difference" is how a reconciliation hides the thing
 * it exists to find.
 */
function Bridge({ r }: { r: FeeReconciliation }) {
  const b = r.bridge
  const rows: { label: string; hint: string; value: number }[] = [
    {
      label: 'Unpaid on this session\u2019s challans',
      hint: 'For the children on the roll today. The figure above also counts children who have since left.',
      value: b.on_challans_this_session,
    },
    {
      label: 'Charges and waivers keyed by hand',
      hint: 'A van fare, a book, a hardship credit. Real money, never on a challan. See any child\u2019s Statement.',
      value: b.charges_keyed_by_hand,
    },
    {
      label: 'Arrears carried in from an earlier session',
      hint: 'Billed last year, still owed by a child who is here this year.',
      value: b.arrears_from_earlier_sessions,
    },
  ]

  return (
    <div className="mb-4 rounded-lg border border-slate-200 bg-slate-50 p-3">
      <div className="text-xs font-semibold uppercase tracking-wide text-slate-500">
        Why the dashboard shows a different number
      </div>
      <table className="mt-2 w-full text-sm">
        <tbody className="divide-y divide-slate-200">
          {rows.map((x) => (
            <tr key={x.label}>
              <td className="py-1.5 pr-3">
                <div className="text-slate-700">{x.label}</div>
                <div className="text-xs text-slate-500">{x.hint}</div>
              </td>
              <td className="whitespace-nowrap py-1.5 text-right align-top tabular-nums text-slate-800">
                {fmtPKR(x.value)}
              </td>
            </tr>
          ))}
          <tr className="border-t-2 border-slate-400 font-semibold">
            <td className="py-1.5 pr-3 text-slate-800">
              Total owed by children on the roll
              <div className="text-xs font-normal text-slate-500">
                This is the Outstanding figure on the dashboard.
              </div>
            </td>
            <td className="whitespace-nowrap py-1.5 text-right align-top tabular-nums text-slate-900">
              {fmtPKR(b.student_outstanding)}
            </td>
          </tr>
        </tbody>
      </table>
      {b.owed_by_children_no_longer_on_the_roll > 0 && (
        <p className="mt-2 rounded border border-due-200 bg-due-50 px-3 py-2 text-xs text-due-800">
          A further <span className="font-semibold">{fmtPKR(b.owed_by_children_no_longer_on_the_roll)}</span>{' '}
          is owed by children who are no longer on the roll. It is on no tile, because the dashboard
          counts the children who are here, and somebody still has to chase it. Reports &rarr;
          Students who left lists them.
        </p>
      )}
    </div>
  )
}

function FlagList({ title, hint, rows, tone }: {
  title: string; hint: string; rows: { gr_no: string | null; full_name: string; class_name: string }[]; tone: 'amber' | 'red'
}) {
  if (rows.length === 0) return (
    <p className="mt-4 rounded bg-emerald-50 px-3 py-2 text-sm text-emerald-800">✓ {title.replace(/\(\d+\)/, '')}: none found.</p>
  )
  const c = tone === 'red' ? 'border-red-200 bg-red-50' : 'border-amber-200 bg-amber-50'
  return (
    <div className={`mt-4 rounded-lg border p-3 ${c}`}>
      <div className="text-sm font-medium text-slate-800">{title}</div>
      <div className="text-xs text-slate-500">{hint}</div>
      <div className="mt-2 flex flex-wrap gap-1.5">
        {rows.slice(0, 200).map((s, i) => (
          <span key={i} className="rounded bg-white/70 px-2 py-0.5 text-xs text-slate-700">
            {s.full_name}{s.gr_no ? ` · ${s.gr_no}` : ''} <span className="text-slate-400">· {s.class_name}</span>
          </span>
        ))}
      </div>
    </div>
  )
}

function Stat({ label, value, tone }: { label: string; value: string; tone: 'slate' | 'emerald' | 'red' }) {
  const tones: Record<string, string> = {
    slate: 'border-slate-200 bg-slate-50 text-slate-800',
    emerald: 'border-emerald-200 bg-emerald-50 text-emerald-800',
    red: 'border-red-200 bg-red-50 text-red-800',
  }
  return (
    <div className={`rounded border p-3 ${tones[tone]}`}>
      <div className="text-xl font-semibold tabular-nums">{value}</div>
      <div className="text-xs">{label}</div>
    </div>
  )
}

function AttendanceRegisterReport() {
  const session = useQuery({ queryKey: ['currentSession'], queryFn: getCurrentSession })
  const sessionId = session.data?.id
  const classes = useQuery({ queryKey: ['classes'], queryFn: listClasses })
  const [classId, setClassId] = useState('')
  const [sectionChoice, setSectionChoice] = useState('')
  const [month, setMonth] = useState(thisMonth())
  const sections = useQuery({ queryKey: ['sections', classId], queryFn: () => listSections(classId), enabled: !!classId })
  const hasSections = (sections.data?.length ?? 0) > 0
  const sectionId: string | null = hasSections ? (sectionChoice || null) : null

  const ready = !!sessionId && !!classId && !!month && (!hasSections || !!sectionChoice)
  const q = useQuery({
    queryKey: ['rptRegister', sessionId, classId, sectionId ?? 'all', month],
    queryFn: () => getAttendanceRegister(sessionId!, classId, sectionId, month),
    enabled: ready,
  })
  const reg = q.data
  const dayNums = (reg?.dates ?? []).map((d) => Number(d.slice(-2)))

  function summary(marks: Record<string, string>) {
    const vals = Object.values(marks)
    const present = vals.filter((v) => v === 'present').length
    const absent = vals.filter((v) => v === 'absent').length
    const marked = vals.length
    const pct = marked ? Math.round((present / marked) * 100) : null
    return { present, absent, marked, pct }
  }

  const csv = () => {
    if (!reg) return
    const header = ['Roll', 'Student', ...dayNums.map(String), 'P', 'A', '%']
    const rows = reg.students.map((s) => {
      const sm = summary(s.marks)
      return [s.roll_no ?? '', s.full_name,
        ...reg.dates.map((d) => ATTENDANCE_SHORT[s.marks[d]] ?? ''),
        sm.present, sm.absent, sm.pct == null ? '' : sm.pct]
    })
    downloadCSV(`attendance-register_${month}.csv`, toCSV(header, rows))
  }

  const clsName = classes.data?.find((c) => c.id === classId)?.name ?? ''
  const secName = sections.data?.find((s) => s.id === sectionId)?.name

  return (
    <div>
      <div className="mb-3 flex flex-wrap items-end gap-2 print:hidden">
        <label className="block"><span className="text-sm text-slate-600">Class</span><br />
          <select value={classId} onChange={(e) => { setClassId(e.target.value); setSectionChoice('') }} className={`mt-1 ${FIELD}`}>
            <option value="">Select class…</option>
            {classes.data?.map((c) => <option key={c.id} value={c.id}>{c.name}</option>)}
          </select>
        </label>
        <label className="block"><span className="text-sm text-slate-600">Section</span><br />
          <select value={sectionChoice} onChange={(e) => setSectionChoice(e.target.value)} disabled={!classId || !hasSections} className={`mt-1 ${FIELD}`}>
            {!classId ? <option value="">Pick a class</option> : !hasSections ? <option value="">(no sections)</option>
              : <><option value="">All sections</option>{sections.data?.map((s) => <option key={s.id} value={s.id}>{s.name}</option>)}</>}
          </select>
        </label>
        <label className="block"><span className="text-sm text-slate-600">Month</span><br />
          <input type="month" value={month} max={thisMonth()} onChange={(e) => setMonth(e.target.value)} className={`mt-1 ${FIELD}`} />
        </label>
      </div>
      {!ready && <p className="text-sm text-slate-500">Pick a class{hasSections ? ', section' : ''} and month.</p>}
      {ready && (
        <ReportShell title="Attendance Register" subtitle={`${clsName}${secName ? ` · ${secName}` : ''} · ${month}`} onCSV={csv}>
          {q.isLoading && <p className="text-sm text-slate-500">Loading…</p>}
          {q.isError && <p className="text-sm text-red-600">{(q.error as Error).message}</p>}
          {reg && (
            <div className="overflow-x-auto">
              <table className="w-full border-collapse text-[11px]">
                <thead>
                  <tr className="bg-slate-50 text-slate-500">
                    <th className="border border-slate-200 px-1 py-1 text-right">Roll</th>
                    <th className="border border-slate-200 px-1 py-1 text-left">Student</th>
                    {dayNums.map((d) => <th key={d} className="border border-slate-200 px-1 py-1 w-5 text-center">{d}</th>)}
                    <th className="border border-slate-200 px-1 py-1 text-right">P</th>
                    <th className="border border-slate-200 px-1 py-1 text-right">A</th>
                    <th className="border border-slate-200 px-1 py-1 text-right">%</th>
                  </tr>
                </thead>
                <tbody>
                  {reg.students.length === 0 && <tr><td colSpan={dayNums.length + 5} className="px-2 py-3 text-center text-slate-500">No active students.</td></tr>}
                  {reg.students.map((s) => {
                    const sm = summary(s.marks)
                    return (
                      <tr key={s.enrollment_id}>
                        <td className="border border-slate-200 px-1 py-0.5 text-right text-slate-500">{s.roll_no ?? '-'}</td>
                        <td className="border border-slate-200 px-1 py-0.5 whitespace-nowrap text-slate-800">{s.full_name}</td>
                        {reg.dates.map((d) => {
                          const v = s.marks[d]
                          return <td key={d} className={`border border-slate-200 px-1 py-0.5 text-center ${v === 'absent' ? 'text-red-600' : v ? 'text-slate-700' : 'text-slate-300'}`}>{ATTENDANCE_SHORT[v] ?? '·'}</td>
                        })}
                        <td className="border border-slate-200 px-1 py-0.5 text-right text-slate-700">{sm.present}</td>
                        <td className="border border-slate-200 px-1 py-0.5 text-right text-slate-700">{sm.absent}</td>
                        <td className="border border-slate-200 px-1 py-0.5 text-right font-medium">{sm.pct == null ? '-' : `${sm.pct}`}</td>
                      </tr>
                    )
                  })}
                </tbody>
              </table>
              <p className="mt-2 text-[11px] text-slate-400">P present · A absent · L leave · Lt late · ½ half-day · · not marked. Prints best in landscape.</p>
            </div>
          )}
        </ReportShell>
      )}
    </div>
  )
}

/**
 * One student's fee account, from the top.
 *
 * WHAT THIS REPLACED, AND WHY IT MATTERED
 *
 * A ledger assembled IN THE BROWSER out of two queries: every invoice as a
 * debit, every payment row as a credit, sorted by comparing a period month
 * against a timestamp as strings. It was the fifth implementation of "what does
 * this child owe" in the product and it was wrong in four ways at once.
 *
 *   * It credited PAYMENT rows, and a family payment carries no student_id. A
 *     household paying for three children together therefore saw a ledger of
 *     charges with no payments against them at all.
 *   * It never saw an adjustment, so a hand-keyed van fare or a waiver moved the
 *     closing balance and appeared on no line.
 *   * A pending bank challan was credited as though the money had cleared.
 *     Nothing else in the product counts one.
 *   * Its own footer said "(current)" when its total disagreed with
 *     student_balance, which is an admission printed on the report rather than a
 *     fix.
 *
 * It now reads fn_student_ledger, which is the same function behind the
 * Statement on the student profile and behind the parent's copy in the portal.
 * One implementation, three screens, and a running total that closes on
 * student_balance by construction.
 */
function StudentLedgerReport() {
  const [term, setTerm] = useState('')
  const [student, setStudent] = useState<StudentRow | null>(null)
  const results = useQuery({ queryKey: ['ledgerSearch', term], queryFn: () => listStudents(term), enabled: term.trim().length >= 2 && !student })
  const ledger = useQuery({ queryKey: ['ledger', student?.id], queryFn: () => getStudentLedger(student!.id), enabled: !!student })
  const balance = useQuery({ queryKey: ['ledgerBal', student?.id], queryFn: () => getStudentBalance(student!.id), enabled: !!student })

  const csv = () => {
    if (!student) return
    downloadCSV(`ledger_${(student.gr_no || student.full_name).replace(/[^a-z0-9]+/gi, '-')}.csv`,
      toCSV(['Date', 'Kind', 'Particulars', 'Reference', 'Charged', 'Paid or off', 'Balance', 'Recorded by'],
        (ledger.data ?? []).map((r) => [
          r.entry_on ? fmtDate(r.entry_on) : '', r.kind, r.particulars, r.reference,
          r.debit || '', r.credit || '', r.balance_after, r.recorded_by,
        ])))
  }

  return (
    <div>
      {!student ? (
        <div className="max-w-md print:hidden">
          <label className="block"><span className="text-sm text-slate-600">Search student by name or GR number</span>
            <input autoFocus value={term} onChange={(e) => setTerm(e.target.value)} className={`mt-1 w-full ${FIELD}`} placeholder="e.g. Ahmed or GR-0001" />
          </label>
          <div className="mt-2 divide-y divide-slate-100 rounded border border-slate-200">
            {results.data?.length === 0 && term.trim().length >= 2 && <div className="p-2 text-sm text-slate-500">No students found.</div>}
            {results.data?.map((s) => (
              <button key={s.id} onClick={() => setStudent(s)} className="block w-full px-3 py-2 text-left text-sm hover:bg-slate-50">
                <span className="font-medium text-slate-800">{s.full_name}</span>
                {s.father_name && <span className="text-slate-500"> · {s.father_name}</span>}
                {s.gr_no && <span className="text-slate-400"> · {s.gr_no}</span>}
              </button>
            ))}
          </div>
        </div>
      ) : (
        <div>
          <div className="mb-3 flex items-center justify-between print:hidden">
            <div className="text-sm text-slate-700"><span className="font-medium">{student.full_name}</span>{student.gr_no ? ` · ${student.gr_no}` : ''}</div>
            <button onClick={() => { setStudent(null); setTerm('') }} className="text-sm text-brand-700 hover:underline">Change student</button>
          </div>
          <ReportShell title="Student Fee Ledger" subtitle={`${student.full_name}${student.gr_no ? ` · ${student.gr_no}` : ''}`} onCSV={csv}>
            {ledger.isLoading && <p className="text-sm text-slate-500">Loading…</p>}
            {ledger.isError && <p className="text-sm text-red-600">{(ledger.error as Error).message}</p>}
            {ledger.data && (
              <>
                <FeeStatement entries={ledger.data} balance={balance.data ?? 0} showRecordedBy />
                <p className="mt-2 text-xs text-slate-400">
                  Charged = what was added to the account · Paid or off = a payment, a discount or a
                  waiver · Balance = what was owed after that entry.
                </p>
              </>
            )}
          </ReportShell>
        </div>
      )}
    </div>
  )
}

/**
 * Charged and collected, per fee head.
 *
 * The question this answers is not "who owes us": Defaulters does that, but
 * "WHICH CHARGE is not being paid". A school with Rs 400,000 outstanding needs
 * to know whether it is spread across the tuition of eighty families or is
 * almost entirely the transport fee that thirty parents never agreed to, because
 * those are different problems with different remedies.
 *
 * THE APPORTIONMENT IS STATED ON THE PAGE. A payment is made against an invoice,
 * not against a line of it, so "collected per head" cannot be read off the
 * ledger. It is each head's share of the invoice multiplied by how much of that
 * invoice has been paid. That is a reasonable convention and it is not the only
 * one, so the basis sentence the function returns is printed rather than
 * dropped. A figure whose derivation is invisible is a figure somebody will
 * eventually dispute with an accountant.
 *
 * Discount lines come back NEGATIVE and are already netted into `charged`, which
 * is why a head can show less charged than the fee structure would suggest.
 */
function HeadWiseDuesReport() {
  const session = useQuery({ queryKey: ['currentSession'], queryFn: getCurrentSession })
  const sessionId = session.data?.id
  const q = useQuery({
    queryKey: ['rptHeadWise', sessionId],
    queryFn: () => getHeadWiseDues(sessionId!),
    enabled: !!sessionId,
  })
  const heads = q.data?.heads ?? []
  // The totals come from the CHALLANS, not from summing the rows above.
  // Splitting a payment across heads is a division, and Rs 1,000 divided across
  // three heads does not add back to Rs 1,000 however the rounding is arranged.
  // Summing the rows therefore produced a total that missed the reconciliation
  // screen by a few paisa for no reason a school could ever work out.
  const tot = {
    charged: q.data?.total_charged ?? 0,
    collected: q.data?.total_collected ?? 0,
    outstanding: q.data?.total_outstanding ?? 0,
  }

  const csv = () => downloadCSV('dues-by-fee-head.csv',
    toCSV(['Fee Head', 'Charged', 'Collected', 'Outstanding'],
      heads.map((h) => [h.fee_head, h.charged, h.collected,
                        Number(h.charged) - Number(h.collected)])))

  return (
    <ReportShell title="Dues by Fee Head" subtitle={session.data?.name} onCSV={csv}>
      {q.isLoading && <p className="text-sm text-slate-500">Loading…</p>}
      {q.isError && <p className="text-sm text-red-600">{(q.error as Error).message}</p>}
      {!q.isLoading && !q.isError && (
        <>
          <div className="overflow-x-auto">
            <table className="w-full text-sm">
              <thead className="bg-slate-50 text-xs uppercase tracking-wide text-slate-500">
                <tr>
                  <th className={TH}>Fee Head</th>
                  <th className={`${TH} text-right`}>Charged</th>
                  <th className={`${TH} text-right`}>Collected</th>
                  <th className={`${TH} text-right`}>Outstanding</th>
                  <th className={`${TH} text-right`}>Collected %</th>
                </tr>
              </thead>
              <tbody className="divide-y divide-slate-100">
                {heads.length === 0 && (
                  <tr><td colSpan={5} className={`${TD} text-slate-500`}>
                    Nothing has been billed in this session yet.
                  </td></tr>
                )}
                {heads.map((h, i) => {
                  const charged = Number(h.charged)
                  const collected = Number(h.collected)
                  const pct = charged > 0 ? Math.round((collected / charged) * 100) : null
                  return (
                    <tr key={i}>
                      <td className={TD}>{h.fee_head}</td>
                      <td className={`${TD} text-right tabular-nums`}>{fmtPKR(charged)}</td>
                      <td className={`${TD} text-right tabular-nums`}>{fmtPKR(collected)}</td>
                      <td className={`${TD} text-right font-medium tabular-nums`}>
                        {fmtPKR(charged - collected)}
                      </td>
                      {/* No percentage rather than "0%" when nothing was charged:
                          a head with no billing has not been collected badly. */}
                      <td className={`${TD} text-right tabular-nums ${
                        pct !== null && pct < 60 ? 'text-red-600' : 'text-slate-600'
                      }`}>
                        {pct === null ? '-' : `${pct}%`}
                      </td>
                    </tr>
                  )
                })}
              </tbody>
              {heads.length > 0 && (
                <tfoot className="border-t-2 border-slate-300 font-semibold text-slate-800">
                  <tr>
                    <td className={TD}>Total</td>
                    <td className={`${TD} text-right tabular-nums`}>{fmtPKR(tot.charged)}</td>
                    <td className={`${TD} text-right tabular-nums`}>{fmtPKR(tot.collected)}</td>
                    <td className={`${TD} text-right tabular-nums`}>
                      {fmtPKR(tot.outstanding)}
                    </td>
                    <td className={`${TD} text-right tabular-nums`}>
                      {tot.charged > 0 ? `${Math.round((tot.collected / tot.charged) * 100)}%` : '-'}
                    </td>
                  </tr>
                </tfoot>
              )}
            </table>
          </div>
          {q.data?.basis && (
            <p className="mt-3 text-xs text-slate-500">{q.data.basis}</p>
          )}
        </>
      )}
    </ReportShell>
  )
}

function StrengthReport() {
  const session = useQuery({ queryKey: ['currentSession'], queryFn: getCurrentSession })
  const sessionId = session.data?.id
  const q = useQuery({ queryKey: ['rptStrength', sessionId], queryFn: () => getClassStrength(sessionId!), enabled: !!sessionId })
  const rows = q.data ?? []
  const tot = rows.reduce((a, r) => ({ boys: a.boys + r.boys, girls: a.girls + r.girls, other: a.other + r.other, total: a.total + r.total }), { boys: 0, girls: 0, other: 0, total: 0 })

  const csv = () => downloadCSV('class-strength.csv',
    toCSV(['Class', 'Section', 'Boys', 'Girls', 'Other', 'Total'],
      rows.map((r) => [r.class_name, r.section_name ?? '', r.boys, r.girls, r.other, r.total])))

  return (
    <ReportShell title="Class Strength" subtitle={session.data?.name} onCSV={csv}>
      {q.isLoading && <p className="text-sm text-slate-500">Loading…</p>}
      {!q.isLoading && (
        <div className="overflow-x-auto">
          <table className="w-full text-sm">
            <thead className="bg-slate-50 text-xs uppercase tracking-wide text-slate-500">
              <tr><th className={TH}>Class</th><th className={TH}>Section</th><th className={`${TH} text-right`}>Boys</th><th className={`${TH} text-right`}>Girls</th><th className={`${TH} text-right`}>Total</th></tr>
            </thead>
            <tbody className="divide-y divide-slate-100">
              {rows.length === 0 && <tr><td colSpan={5} className={`${TD} text-slate-500`}>No active enrolments.</td></tr>}
              {rows.map((r, i) => (
                <tr key={i}>
                  <td className={TD}>{r.class_name}</td>
                  <td className={TD}>{r.section_name ?? '-'}</td>
                  <td className={`${TD} text-right tabular-nums`}>{r.boys}</td>
                  <td className={`${TD} text-right tabular-nums`}>{r.girls}</td>
                  <td className={`${TD} text-right font-medium tabular-nums`}>{r.total}</td>
                </tr>
              ))}
            </tbody>
            {rows.length > 0 && (
              <tfoot className="border-t-2 border-slate-300 font-semibold text-slate-800">
                <tr><td className={TD} colSpan={2}>Total</td><td className={`${TD} text-right tabular-nums`}>{tot.boys}</td><td className={`${TD} text-right tabular-nums`}>{tot.girls}</td><td className={`${TD} text-right tabular-nums`}>{tot.total}</td></tr>
              </tfoot>
            )}
          </table>
        </div>
      )}
    </ReportShell>
  )
}

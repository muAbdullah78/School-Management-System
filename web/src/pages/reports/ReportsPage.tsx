import { useState, type ReactNode } from 'react'
import { useQuery } from '@tanstack/react-query'
import {
  getCurrentSession, getDefaulters, listCollections, getClassStrength,
} from '@/lib/db'
import { useSchoolName } from '@/hooks/useSchoolName'
import { fmtPKR, fmtDate, todayISO } from '@/lib/format'
import { toCSV, downloadCSV } from '@/lib/csv'

const FIELD = 'rounded border border-slate-300 px-3 py-2 text-sm focus:border-brand-500 focus:outline-none focus:ring-1 focus:ring-brand-500'
const TABS = [
  { key: 'collection', label: 'Fee Collection' },
  { key: 'defaulters', label: 'Defaulters' },
  { key: 'strength', label: 'Class Strength' },
] as const
type TabKey = (typeof TABS)[number]['key']

function monthStart() { return `${todayISO().slice(0, 7)}-01` }

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
        {tab === 'defaulters' && <DefaultersReport />}
        {tab === 'strength' && <StrengthReport />}
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
      <ReportShell title="Fee Collection Report" subtitle={`${fmtDate(from)} – ${fmtDate(to)}`} onCSV={csv}>
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
                      <td className={TD}>{r.receipt_no ?? '—'}</td>
                      <td className={TD}>{r.student_name ?? '—'}{r.gr_no ? <span className="text-slate-400"> · {r.gr_no}</span> : ''}{r.is_reversal ? ' (reversal)' : ''}</td>
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
                    <td className={TD}>{r.gr_no ?? '—'}</td>
                    <td className={TD}>{r.full_name}</td>
                    <td className={TD}>{r.class_name}{r.section_name ? ` · ${r.section_name}` : ''}</td>
                    <td className={TD}>{r.roll_no ?? '—'}</td>
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
                  <td className={TD}>{r.section_name ?? '—'}</td>
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

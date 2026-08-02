import { useMemo } from 'react'
import type { ImportResult } from '@/lib/db'
import { fmtPKR } from '@/lib/format'

/** Shared results panel for the onboarding importers (students, fee balances).
 *  Shows the created/skipped/error tally and a table of rows needing attention. */
export function ImportResultPanel({
  result, successDry, successReal, footer,
}: {
  result: { dry: boolean; data: ImportResult }
  successDry: string
  successReal: string
  footer?: React.ReactNode
}) {
  const { dry, data } = result
  const problemRows = useMemo(
    () => data.rows.filter((r) => r.status === 'error' || r.status === 'skipped'),
    [data],
  )
  const showAmount = useMemo(() => data.rows.some((r) => r.amount != null), [data])

  return (
    <div className="rounded-lg border border-slate-200 bg-white p-4">
      <div className="flex items-center gap-2">
        <span className={`rounded px-2 py-0.5 text-xs font-medium ${dry ? 'bg-sky-100 text-sky-700' : 'bg-emerald-100 text-emerald-700'}`}>
          {dry ? 'Dry run — nothing was saved' : 'Import complete'}
        </span>
        <span className="text-sm text-slate-600">{data.total} row{data.total === 1 ? '' : 's'} processed</span>
      </div>

      <div className="mt-3 grid grid-cols-3 gap-3">
        <Stat label={dry ? 'Would create' : 'Created'} value={data.created} tone="emerald" />
        <Stat label="Skipped" value={data.skipped} tone="amber" />
        <Stat label="Errors" value={data.errors} tone="red" />
      </div>

      {problemRows.length > 0 ? (
        <div className="mt-4">
          <div className="text-sm font-medium text-slate-700">Rows needing attention</div>
          <div className="mt-2 overflow-x-auto">
            <table className="min-w-full text-sm">
              <thead>
                <tr className="text-left text-xs uppercase tracking-wide text-slate-400">
                  <th className="py-1 pr-3">Row</th>
                  <th className="py-1 pr-3">Name</th>
                  {showAmount && <th className="py-1 pr-3">Amount</th>}
                  <th className="py-1 pr-3">Status</th>
                  <th className="py-1">Reason</th>
                </tr>
              </thead>
              <tbody>
                {problemRows.slice(0, 300).map((r) => (
                  <tr key={r.row} className="border-t border-slate-100">
                    <td className="py-1 pr-3 text-slate-500">{r.row}</td>
                    <td className="py-1 pr-3 text-slate-700">{r.name || <span className="text-slate-400">—</span>}</td>
                    {showAmount && <td className="py-1 pr-3 text-slate-600">{r.amount == null ? '—' : fmtPKR(r.amount)}</td>}
                    <td className="py-1 pr-3">
                      <span className={r.status === 'error' ? 'text-red-600' : 'text-amber-600'}>{r.status}</span>
                    </td>
                    <td className="py-1 text-slate-600">{r.message}</td>
                  </tr>
                ))}
              </tbody>
            </table>
            {problemRows.length > 300 && (
              <p className="mt-2 text-xs text-slate-400">Showing the first 300 of {problemRows.length} rows.</p>
            )}
          </div>
        </div>
      ) : (
        <p className="mt-4 rounded bg-emerald-50 p-3 text-sm text-emerald-800">
          {dry ? successDry : successReal}
        </p>
      )}

      {footer && !dry && data.created > 0 && <div className="mt-3 text-xs text-slate-500">{footer}</div>}
    </div>
  )
}

function Stat({ label, value, tone }: { label: string; value: number; tone: 'emerald' | 'amber' | 'red' }) {
  const tones: Record<string, string> = {
    emerald: 'border-emerald-200 bg-emerald-50 text-emerald-800',
    amber: 'border-amber-200 bg-amber-50 text-amber-800',
    red: 'border-red-200 bg-red-50 text-red-800',
  }
  return (
    <div className={`rounded border p-3 ${tones[tone]}`}>
      <div className="text-2xl font-semibold">{value.toLocaleString()}</div>
      <div className="text-xs">{label}</div>
    </div>
  )
}

import { useState } from 'react'
import { useQuery } from '@tanstack/react-query'
import { exportAllData, getSchoolSettings, EXPORT_TABLES, type ExportResult } from '@/lib/db'
import { downloadJSON } from '@/lib/csv'

export function Backup() {
  const settings = useQuery({ queryKey: ['schoolSettings'], queryFn: getSchoolSettings })
  const [busy, setBusy] = useState(false)
  const [progress, setProgress] = useState<{ table: string; i: number; n: number } | null>(null)
  const [result, setResult] = useState<ExportResult | null>(null)
  const [error, setError] = useState<string | null>(null)

  async function runExport() {
    setBusy(true); setError(null); setResult(null)
    try {
      const stamp = new Date().toISOString()
      const data = await exportAllData(stamp, (table, i, n) => setProgress({ table, i, n }))
      const slug = (settings.data?.name || 'school').toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '')
      downloadJSON(`backup_${slug}_${stamp.slice(0, 10)}.json`, data)
      setResult(data)
    } catch (e) {
      setError((e as Error).message)
    } finally {
      setBusy(false); setProgress(null)
    }
  }

  const totalRows = result ? Object.values(result.counts).reduce((a, b) => a + b, 0) : 0
  const errorCount = result ? Object.keys(result.errors).length : 0

  return (
    <div className="max-w-2xl space-y-4">
      <div className="rounded-lg border border-slate-200 bg-white p-4">
        <div className="text-sm font-medium text-slate-800">Export all data</div>
        <p className="mt-1 text-sm text-slate-600">
          Download a complete copy of your school’s data as a single JSON file — students, fees, attendance,
          marks, certificates and settings. This is <span className="font-medium">your</span> data; keep periodic
          backups somewhere safe (a USB drive or your own cloud storage). It complements Supabase’s own automatic backups.
        </p>
        <button onClick={runExport} disabled={busy}
          className="mt-3 rounded bg-brand-600 px-5 py-2 text-sm font-medium text-white hover:bg-brand-700 disabled:opacity-60">
          {busy ? 'Exporting…' : 'Download full backup (JSON)'}
        </button>

        {busy && progress && (
          <div className="mt-3">
            <div className="text-xs text-slate-500">Reading {progress.table}… ({progress.i + 1} of {progress.n})</div>
            <div className="mt-1 h-1.5 w-full overflow-hidden rounded bg-slate-100">
              <div className="h-full bg-brand-500 transition-all" style={{ width: `${((progress.i + 1) / progress.n) * 100}%` }} />
            </div>
          </div>
        )}

        {error && <p className="mt-3 text-sm text-red-600">{error}</p>}

        {result && (
          <div className="mt-3 rounded border border-emerald-200 bg-emerald-50 p-3 text-sm text-emerald-800">
            Backup downloaded — {totalRows.toLocaleString()} rows across {Object.keys(result.counts).length} tables.
            {errorCount > 0 && (
              <span className="text-amber-700"> {errorCount} table{errorCount === 1 ? '' : 's'} skipped (no permission): {Object.keys(result.errors).join(', ')}.</span>
            )}
          </div>
        )}
      </div>

      <details className="rounded-lg border border-slate-200 bg-white p-4">
        <summary className="cursor-pointer text-sm font-medium text-slate-700">What’s included</summary>
        <div className="mt-2 flex flex-wrap gap-1.5">
          {EXPORT_TABLES.map((t) => (
            <span key={t} className="rounded bg-slate-100 px-2 py-0.5 text-xs text-slate-600">{t}</span>
          ))}
        </div>
        <p className="mt-2 text-xs text-slate-500">
          The file is a JSON object <code>{'{ exported_at, tables, counts, errors }'}</code>. Tables you don’t have
          permission to read are listed under <code>errors</code> and left out.
        </p>
      </details>
    </div>
  )
}

import { useState } from 'react'
import { useMutation, useQueryClient } from '@tanstack/react-query'
import { useAuth } from '@/auth/AuthProvider'
import { resetSchoolData } from '@/lib/db'
import { useLicence } from '@/hooks/useLicence'
import { useQuery } from '@tanstack/react-query'
import { exportAllData, getSchoolSettings, EXPORT_TABLES, type ExportResult } from '@/lib/db'
import { downloadJSON } from '@/lib/csv'
import { LoadError } from '@/components/ui'

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
      <LoadError of={[settings]} what="The school profile" />
      <div className="rounded-lg border border-slate-200 bg-white p-4">
        <div className="text-sm font-medium text-slate-800">Export all data</div>
        <p className="mt-1 text-sm text-slate-600">
          Download a complete copy of your school’s data as a single JSON file: students, fees, attendance,
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
            Backup downloaded: {totalRows.toLocaleString()} rows across {Object.keys(result.counts).length} tables.
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

      <StartAgain />
    </div>
  )
}



/**
 * Clearing the practice data, at the bottom of the page that backs it up.
 *
 * Placed here on purpose. Every school's first week is the same: somebody types
 * in fifteen made-up children to see how it works, and then wants the practice
 * gone before real admissions start. The thing they should do immediately
 * beforehand is take the export that sits directly above this, so the two live
 * together rather than in different corners of Settings.
 *
 * It shows at all only during the trial, because that is the period when the
 * data is known to be practice. A paying school with three years of fee history
 * has no legitimate use for it, and the database refuses regardless: this only
 * decides whether an owner is shown a button that would be refused.
 */
function StartAgain() {
  const qc = useQueryClient()
  const { profile } = useAuth()
  const settings = useQuery({ queryKey: ['schoolSettings'], queryFn: getSchoolSettings })
  // The same hook the licence banner uses, so "on trial" means one thing in
  // this app rather than two.
  const licence = useLicence()
  const [open, setOpen] = useState(false)
  const [typed, setTyped] = useState('')
  const [done, setDone] = useState<string | null>(null)

  const run = useMutation({
    mutationFn: () => resetSchoolData(typed),
    onSuccess: (r) => {
      setDone(`${r.school} has been cleared. ${r.rows_removed.toLocaleString()} record(s) removed.`)
      setOpen(false); setTyped('')
      // Everything on every screen is now stale, so throw the whole cache away
      // rather than trying to name the parts of it that changed.
      qc.clear()
    },
  })

  const isOwner = profile?.role === 'owner'
  const onTrial = licence.data && 'status' in licence.data && licence.data.status === 'trialing'
  const name = settings.data?.name ?? ''
  if (!isOwner || !onTrial) return null

  return (
    <section className="mt-8 rounded-lg border border-danger-200 bg-danger-50 p-4">
      <h3 className="text-sm font-semibold text-danger-900">Start again</h3>
      <p className="mt-1 text-sm text-danger-800">
        Clears everything you have entered so far: children, families, staff records,
        classes, the fee structure, challans, receipts, attendance and marks. Use it
        once, after the practice week, before the real admissions go in.
      </p>
      <p className="mt-2 text-sm text-danger-800">
        <b>Take the export above first.</b> This cannot be undone and we cannot
        recover it for you.
      </p>
      <p className="mt-2 text-sm text-danger-700">
        Your logins are kept, including yours. Remove any you do not need from the
        Staff screen. The school, its settings and its subscription are kept too.
      </p>
      <p className="mt-2 text-xs text-danger-700">
        Only available during the free trial.
      </p>

      {done && (
        <p className="mt-3 rounded-lg border border-money-200 bg-money-50 px-3 py-2 text-sm text-money-800">
          {done}
        </p>
      )}

      {!open ? (
        <button onClick={() => { setOpen(true); setDone(null) }}
          className="mt-3 rounded-lg border border-danger-300 bg-white px-4 py-2 text-sm font-medium text-danger-700 hover:bg-danger-50">
          Clear everything and start again
        </button>
      ) : (
        <div className="mt-3 rounded-lg border border-danger-200 bg-white p-3">
          <p className="text-sm text-slate-700">
            Type <b>{name}</b> to confirm.
          </p>
          <input
            value={typed} onChange={(e) => setTyped(e.target.value)} placeholder={name} autoFocus
            className="mt-2 w-full rounded-lg border border-slate-300 px-3 py-2 text-sm focus:border-brand-500 focus:outline-none"
          />
          {run.isError && (
            <p className="mt-2 text-sm text-danger-700">{(run.error as Error).message}</p>
          )}
          <div className="mt-3 flex gap-2">
            <button
              onClick={() => run.mutate()}
              disabled={run.isPending || typed.trim().toLowerCase() !== name.trim().toLowerCase()}
              className="rounded-lg bg-danger-600 px-4 py-2 text-sm font-medium text-white hover:bg-danger-700 disabled:cursor-not-allowed disabled:opacity-50">
              {run.isPending ? 'Clearing…' : 'Clear everything'}
            </button>
            <button onClick={() => { setOpen(false); setTyped('') }}
              className="rounded-lg border border-slate-300 bg-white px-4 py-2 text-sm font-medium text-slate-700 hover:bg-slate-50">
              Cancel
            </button>
          </div>
        </div>
      )}
    </section>
  )
}

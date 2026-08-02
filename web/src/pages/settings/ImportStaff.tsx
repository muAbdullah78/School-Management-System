import { useState } from 'react'
import { useMutation } from '@tanstack/react-query'
import { importStaff, type ImportResult } from '@/lib/db'
import { parseCSVToObjects, toCSV, downloadCSV } from '@/lib/csv'
import { STAFF_IMPORT_COLUMNS, mapStaffRows, canonicalStaffColumn, missingStaffColumns } from '@/lib/importStaff'
import { ImportResultPanel } from './ImportResultPanel'

interface Loaded {
  fileName: string
  recognised: string[]
  unknown: string[]
  missing: string[]
  rows: Record<string, string>[]
}

export function ImportStaff() {
  const [loaded, setLoaded] = useState<Loaded | null>(null)
  const [parseError, setParseError] = useState<string | null>(null)
  const [result, setResult] = useState<{ dry: boolean; data: ImportResult } | null>(null)

  function downloadTemplate() {
    const headers = [...STAFF_IMPORT_COLUMNS]
    const example: Record<string, string> = {
      full_name: 'Mr. Imran Khan', designation: 'Senior Teacher', employee_no: 'EMP-001',
      mobile: '03001234567', whatsapp: '03001234567', cnic: '', joined_on: '2020-04-01',
    }
    downloadCSV('staff-import-template.csv', toCSV(headers, [headers.map((h) => example[h] ?? '')]))
  }

  async function onFile(file: File) {
    setParseError(null); setResult(null); setLoaded(null)
    try {
      const text = await file.text()
      const { headers, rows: rawRows } = parseCSVToObjects(text)
      if (headers.length === 0) { setParseError('That file looks empty.'); return }
      const recognised: string[] = []
      const unknown: string[] = []
      for (const h of headers) (canonicalStaffColumn(h) ? recognised : unknown).push(h)
      setLoaded({ fileName: file.name, recognised, unknown, missing: missingStaffColumns(headers), rows: mapStaffRows(rawRows) })
    } catch (e) {
      setParseError((e as Error).message)
    }
  }

  const run = useMutation({
    mutationFn: (dryRun: boolean) => importStaff(loaded!.rows, dryRun).then((data) => ({ dry: dryRun, data })),
    onSuccess: (r) => setResult(r),
  })

  const canImport = !!loaded && loaded.rows.length > 0 && loaded.missing.length === 0

  return (
    <div className="max-w-3xl space-y-4">
      <div className="rounded-lg border border-slate-200 bg-white p-4">
        <div className="text-sm font-medium text-slate-800">Import staff from a spreadsheet</div>
        <p className="mt-1 text-sm text-slate-600">
          Load the school's staff list (teaching and non-teaching) in one go. Save as <span className="font-medium">CSV</span> and upload.
          Only <span className="font-medium">Full name</span> is required. You can link each person to a teacher login later, under Staff.
        </p>
        <button onClick={downloadTemplate}
          className="mt-3 rounded border border-slate-300 bg-white px-4 py-2 text-sm font-medium text-slate-700 hover:bg-slate-50">
          Download CSV template
        </button>
      </div>

      <div className="rounded-lg border border-slate-200 bg-white p-4">
        <div className="text-sm font-medium text-slate-800">Choose your CSV file</div>
        <input type="file" accept=".csv,text/csv"
          onChange={(e) => { const f = e.target.files?.[0]; if (f) onFile(f) }}
          className="mt-2 block w-full text-sm text-slate-600 file:mr-3 file:rounded file:border-0 file:bg-brand-600 file:px-4 file:py-2 file:text-sm file:font-medium file:text-white hover:file:bg-brand-700" />
        {parseError && <p className="mt-2 text-sm text-red-600">{parseError}</p>}

        {loaded && (
          <div className="mt-4 space-y-3 text-sm">
            <div className="text-slate-700">
              <span className="font-medium">{loaded.fileName}</span> — {loaded.rows.length.toLocaleString()} row{loaded.rows.length === 1 ? '' : 's'} detected.
            </div>
            <div>
              <span className="text-slate-500">Recognised columns:</span>
              <div className="mt-1 flex flex-wrap gap-1.5">
                {loaded.recognised.map((h) => <span key={h} className="rounded bg-emerald-50 px-2 py-0.5 text-xs text-emerald-700">{h}</span>)}
                {loaded.recognised.length === 0 && <span className="text-xs text-slate-400">none</span>}
              </div>
            </div>
            {loaded.unknown.length > 0 && (
              <div>
                <span className="text-slate-500">Ignored columns:</span>
                <div className="mt-1 flex flex-wrap gap-1.5">
                  {loaded.unknown.map((h) => <span key={h} className="rounded bg-slate-100 px-2 py-0.5 text-xs text-slate-500">{h}</span>)}
                </div>
              </div>
            )}
            {loaded.missing.length > 0 && (
              <p className="rounded bg-red-50 p-2 text-sm text-red-700">Missing required column: <span className="font-medium">{loaded.missing.join(', ')}</span>.</p>
            )}

            <div className="flex flex-wrap gap-2 pt-1">
              <button onClick={() => run.mutate(true)} disabled={!canImport || run.isPending}
                className="rounded border border-brand-300 bg-brand-50 px-4 py-2 text-sm font-medium text-brand-700 hover:bg-brand-100 disabled:opacity-60">
                {run.isPending && run.variables === true ? 'Validating…' : 'Validate (dry run)'}
              </button>
              <button onClick={() => { if (confirm(`Import ${loaded.rows.length} staff record(s)?`)) run.mutate(false) }}
                disabled={!canImport || run.isPending}
                className="rounded bg-brand-600 px-4 py-2 text-sm font-medium text-white hover:bg-brand-700 disabled:opacity-60">
                {run.isPending && run.variables === false ? 'Importing…' : `Import ${loaded.rows.length} staff`}
              </button>
            </div>
            {run.isError && <p className="text-sm text-red-600">{(run.error as Error).message}</p>}
          </div>
        )}
      </div>

      {result && (
        <ImportResultPanel
          result={result}
          successDry="Every row is valid and ready to import."
          successReal="Staff imported. Link teachers to their logins under Staff → assign roles in Settings → Users."
          footer="Tip: rows with an Employee No or CNIC are skipped on a re-run, so importing the same file twice won't duplicate them."
        />
      )}
    </div>
  )
}

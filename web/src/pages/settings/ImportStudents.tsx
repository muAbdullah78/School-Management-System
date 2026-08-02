import { useMemo, useRef, useState } from 'react'
import { useMutation, useQuery } from '@tanstack/react-query'
import { getCurrentSession, importStudents, type ImportResult } from '@/lib/db'
import { parseCSVToObjects } from '@/lib/csv'
import { toCSV, downloadCSV } from '@/lib/csv'
import {
  STUDENT_IMPORT_COLUMNS, mapImportRows, canonicalColumn, missingRequiredColumns,
} from '@/lib/importStudents'

interface Loaded {
  fileName: string
  headers: string[]
  recognised: string[]
  unknown: string[]
  missing: string[]
  rows: Record<string, string>[]
}

export function ImportStudents() {
  const session = useQuery({ queryKey: ['currentSession'], queryFn: getCurrentSession })
  const [loaded, setLoaded] = useState<Loaded | null>(null)
  const [parseError, setParseError] = useState<string | null>(null)
  const [result, setResult] = useState<{ dry: boolean; data: ImportResult } | null>(null)
  const fileInput = useRef<HTMLInputElement>(null)

  function downloadTemplate() {
    const example: Record<string, string> = {
      full_name: 'Ali Raza', father_name: 'Raza Khan', mother_name: '', gender: 'male',
      dob: '2015-04-12', b_form: '', phone: '03001234567', whatsapp: '03001234567', address: 'Model Town',
      class: 'Class 1', section: 'A', roll_no: '', gr_no: '', admission_no: '', admission_date: '2025-04-01',
      guardian_name: 'Raza Khan', guardian_relation: 'Father', guardian_phone: '03001234567', guardian_whatsapp: '',
    }
    const headers = [...STUDENT_IMPORT_COLUMNS]
    const csv = toCSV(headers, [headers.map((h) => example[h] ?? '')])
    downloadCSV('student-import-template.csv', csv)
  }

  async function onFile(file: File) {
    setParseError(null); setResult(null); setLoaded(null)
    try {
      const text = await file.text()
      const { headers, rows: rawRows } = parseCSVToObjects(text)
      if (headers.length === 0) { setParseError('That file looks empty.'); return }
      const recognised: string[] = []
      const unknown: string[] = []
      for (const h of headers) (canonicalColumn(h) ? recognised : unknown).push(h)
      const rows = mapImportRows(rawRows)
      setLoaded({
        fileName: file.name, headers, recognised, unknown,
        missing: missingRequiredColumns(headers), rows,
      })
    } catch (e) {
      setParseError((e as Error).message)
    }
  }

  const run = useMutation({
    mutationFn: (dryRun: boolean) =>
      importStudents(session.data!.id, loaded!.rows, dryRun).then((data) => ({ dry: dryRun, data })),
    onSuccess: (r) => setResult(r),
  })

  const canImport = !!session.data && !!loaded && loaded.rows.length > 0 && loaded.missing.length === 0
  const problemRows = useMemo(
    () => result?.data.rows.filter((r) => r.status === 'error' || r.status === 'skipped') ?? [],
    [result],
  )

  return (
    <div className="max-w-3xl space-y-4">
      <div className="rounded-lg border border-slate-200 bg-white p-4">
        <div className="text-sm font-medium text-slate-800">Import students from a spreadsheet</div>
        <p className="mt-1 text-sm text-slate-600">
          Load an existing student list (a paper register typed into Excel, or an export from another system)
          in one go. Save your spreadsheet as <span className="font-medium">CSV</span> and upload it here.
          Students are admitted into the <span className="font-medium">current session</span>, appear on the
          class roster, and become billable in Fees — exactly as if each were admitted by hand.
        </p>
        <ul className="mt-3 list-disc space-y-1 pl-5 text-sm text-slate-600">
          <li>Only <span className="font-medium">Full name</span> and <span className="font-medium">Class</span> are required. Everything else is optional.</li>
          <li>The <span className="font-medium">Class</span> and <span className="font-medium">Section</span> must already exist (create them under <span className="font-medium">Classes &amp; Sections</span> first). They’re matched by name.</li>
          <li>Leave <span className="font-medium">GR No</span> blank to auto-assign gapless GR numbers; supply your own to keep existing ones.</li>
          <li>Always <span className="font-medium">Validate</span> first — it checks every row and changes nothing.</li>
        </ul>
        <button onClick={downloadTemplate}
          className="mt-3 rounded border border-slate-300 bg-white px-4 py-2 text-sm font-medium text-slate-700 hover:bg-slate-50">
          Download CSV template
        </button>
      </div>

      {!session.data && !session.isLoading && (
        <p className="rounded bg-amber-50 p-3 text-sm text-amber-700">
          No current academic session is set. Create one under <span className="font-medium">Sessions</span> before importing.
        </p>
      )}

      <div className="rounded-lg border border-slate-200 bg-white p-4">
        <div className="text-sm font-medium text-slate-800">Choose your CSV file</div>
        <input
          ref={fileInput}
          type="file"
          accept=".csv,text/csv"
          onChange={(e) => { const f = e.target.files?.[0]; if (f) onFile(f) }}
          className="mt-2 block w-full text-sm text-slate-600 file:mr-3 file:rounded file:border-0 file:bg-brand-600 file:px-4 file:py-2 file:text-sm file:font-medium file:text-white hover:file:bg-brand-700"
        />
        {parseError && <p className="mt-2 text-sm text-red-600">{parseError}</p>}

        {loaded && (
          <div className="mt-4 space-y-3 text-sm">
            <div className="text-slate-700">
              <span className="font-medium">{loaded.fileName}</span> — {loaded.rows.length.toLocaleString()} row{loaded.rows.length === 1 ? '' : 's'} detected.
            </div>
            <div>
              <span className="text-slate-500">Recognised columns:</span>
              <div className="mt-1 flex flex-wrap gap-1.5">
                {loaded.recognised.map((h) => (
                  <span key={h} className="rounded bg-emerald-50 px-2 py-0.5 text-xs text-emerald-700">{h}</span>
                ))}
                {loaded.recognised.length === 0 && <span className="text-xs text-slate-400">none</span>}
              </div>
            </div>
            {loaded.unknown.length > 0 && (
              <div>
                <span className="text-slate-500">Ignored columns (not recognised):</span>
                <div className="mt-1 flex flex-wrap gap-1.5">
                  {loaded.unknown.map((h) => (
                    <span key={h} className="rounded bg-slate-100 px-2 py-0.5 text-xs text-slate-500">{h}</span>
                  ))}
                </div>
              </div>
            )}
            {loaded.missing.length > 0 && (
              <p className="rounded bg-red-50 p-2 text-sm text-red-700">
                Missing required column{loaded.missing.length === 1 ? '' : 's'}: <span className="font-medium">{loaded.missing.join(', ')}</span>.
                Add {loaded.missing.length === 1 ? 'it' : 'them'} and re-upload.
              </p>
            )}

            <div className="flex flex-wrap gap-2 pt-1">
              <button
                onClick={() => run.mutate(true)}
                disabled={!canImport || run.isPending}
                className="rounded border border-brand-300 bg-brand-50 px-4 py-2 text-sm font-medium text-brand-700 hover:bg-brand-100 disabled:opacity-60">
                {run.isPending && run.variables === true ? 'Validating…' : 'Validate (dry run)'}
              </button>
              <button
                onClick={() => { if (confirm(`Import ${loaded.rows.length} student(s) into ${session.data?.name}?`)) run.mutate(false) }}
                disabled={!canImport || run.isPending}
                className="rounded bg-brand-600 px-4 py-2 text-sm font-medium text-white hover:bg-brand-700 disabled:opacity-60">
                {run.isPending && run.variables === false ? 'Importing…' : `Import ${loaded.rows.length} student${loaded.rows.length === 1 ? '' : 's'}`}
              </button>
            </div>
            {run.isError && <p className="text-sm text-red-600">{(run.error as Error).message}</p>}
          </div>
        )}
      </div>

      {result && (
        <div className="rounded-lg border border-slate-200 bg-white p-4">
          <div className="flex items-center gap-2">
            <span className={`rounded px-2 py-0.5 text-xs font-medium ${result.dry ? 'bg-sky-100 text-sky-700' : 'bg-emerald-100 text-emerald-700'}`}>
              {result.dry ? 'Dry run — nothing was saved' : 'Import complete'}
            </span>
            <span className="text-sm text-slate-600">{result.data.total} row{result.data.total === 1 ? '' : 's'} processed</span>
          </div>
          <div className="mt-3 grid grid-cols-3 gap-3">
            <Stat label={result.dry ? 'Would create' : 'Created'} value={result.data.created} tone="emerald" />
            <Stat label="Skipped (duplicate)" value={result.data.skipped} tone="amber" />
            <Stat label="Errors" value={result.data.errors} tone="red" />
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
                      <th className="py-1 pr-3">Status</th>
                      <th className="py-1">Reason</th>
                    </tr>
                  </thead>
                  <tbody>
                    {problemRows.slice(0, 300).map((r) => (
                      <tr key={r.row} className="border-t border-slate-100">
                        <td className="py-1 pr-3 text-slate-500">{r.row}</td>
                        <td className="py-1 pr-3 text-slate-700">{r.name || <span className="text-slate-400">—</span>}</td>
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
              {result.dry
                ? 'Every row is valid and ready to import. Click “Import” to save them.'
                : 'All rows imported cleanly. The students are now on the roster and billable in Fees.'}
            </p>
          )}

          {!result.dry && result.data.created > 0 && (
            <p className="mt-3 text-xs text-slate-500">
              Tip: re-uploading the same file is safe for rows that carry a GR No or Admission No — those are skipped as duplicates.
              Rows without either identifier can’t be de-duplicated, so import a file once.
            </p>
          )}
        </div>
      )}
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

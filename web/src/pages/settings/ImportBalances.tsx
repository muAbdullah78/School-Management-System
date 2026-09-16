import { useState } from 'react'
import { AskDialog } from '@/components/AskDialog'
import { useMutation, useQuery } from '@tanstack/react-query'
import { getCurrentSession, importOpeningBalances, type ImportResult } from '@/lib/db'
import { parseCSVToObjects, toCSV, downloadCSV } from '@/lib/csv'
import {
  BALANCE_IMPORT_COLUMNS, mapBalanceRows, canonicalBalanceColumn, missingBalanceColumns,
} from '@/lib/importBalances'
import { ImportResultPanel } from './ImportResultPanel'

interface Loaded {
  fileName: string
  recognised: string[]
  unknown: string[]
  missing: string[]
  rows: Record<string, string>[]
}

export function ImportBalances() {
  const session = useQuery({ queryKey: ['currentSession'], queryFn: getCurrentSession })
  const [loaded, setLoaded] = useState<Loaded | null>(null)
  const [parseError, setParseError] = useState<string | null>(null)
  const [result, setResult] = useState<{ dry: boolean; data: ImportResult } | null>(null)
  const [asking, setAsking] = useState(false)

  function downloadTemplate() {
    const headers = [...BALANCE_IMPORT_COLUMNS]
    const example: Record<string, string> = {
      gr_no: 'GR0001', admission_no: '', full_name: '', father_name: '', amount: '12000', due_date: '',
    }
    downloadCSV('fee-balance-template.csv', toCSV(headers, [headers.map((h) => example[h] ?? '')]))
  }

  async function onFile(file: File) {
    setParseError(null); setResult(null); setLoaded(null)
    try {
      const text = await file.text()
      const { headers, rows: rawRows } = parseCSVToObjects(text)
      if (headers.length === 0) { setParseError('That file looks empty.'); return }
      const recognised: string[] = []
      const unknown: string[] = []
      for (const h of headers) (canonicalBalanceColumn(h) ? recognised : unknown).push(h)
      setLoaded({
        fileName: file.name, recognised, unknown,
        missing: missingBalanceColumns(headers), rows: mapBalanceRows(rawRows),
      })
    } catch (e) {
      setParseError((e as Error).message)
    }
  }

  const run = useMutation({
    mutationFn: (dryRun: boolean) =>
      importOpeningBalances(session.data!.id, loaded!.rows, dryRun).then((data) => ({ dry: dryRun, data })),
    onSuccess: (r) => setResult(r),
  })

  const canImport = !!session.data && !!loaded && loaded.rows.length > 0 && loaded.missing.length === 0

  return (
    <div className="max-w-3xl space-y-4">
      <div className="rounded-lg border border-slate-200 bg-white p-4">
        <div className="text-sm font-medium text-slate-800">Import opening fee balances</div>
        <p className="mt-1 text-sm text-slate-600">
          Load each student’s <span className="font-medium">arrears (money already owed)</span> from before they
          moved onto the system, so Fees, receipts and the defaulter list start from reality instead of zero.
          Do this <span className="font-medium">once</span>, right after importing students and before the first
          monthly challan run.
        </p>
        <ul className="mt-3 list-disc space-y-1 pl-5 text-sm text-slate-600">
          <li>Each row needs an <span className="font-medium">amount</span> and a way to find the student: <span className="font-medium">GR No</span> is best (Admission No or Name also work).</li>
          <li>Students must already be imported and enrolled in the <span className="font-medium">current session</span>.</li>
          <li>The balance becomes an “opening balance” charge that’s settled first when the parent next pays.</li>
          <li>Amounts like <code>12,000</code> or <code>Rs 12000</code> are fine. Always <span className="font-medium">Validate</span> first.</li>
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
          type="file"
          accept=".csv,text/csv"
          onChange={(e) => { const f = e.target.files?.[0]; if (f) onFile(f) }}
          className="mt-2 block w-full text-sm text-slate-600 file:mr-3 file:rounded file:border-0 file:bg-brand-600 file:px-4 file:py-2 file:text-sm file:font-medium file:text-white hover:file:bg-brand-700"
        />
        {parseError && <p className="mt-2 text-sm text-red-600">{parseError}</p>}

        {loaded && (
          <div className="mt-4 space-y-3 text-sm">
            <div className="text-slate-700">
              <span className="font-medium">{loaded.fileName}</span>: {loaded.rows.length.toLocaleString()} row{loaded.rows.length === 1 ? '' : 's'} detected.
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
                Missing: <span className="font-medium">{loaded.missing.join(', ')}</span>. Add and re-upload.
              </p>
            )}

            <div className="flex flex-wrap gap-2 pt-1">
              <button
                onClick={() => run.mutate(true)}
                disabled={!canImport || run.isPending}
                className="rounded border border-brand-300 bg-brand-50 px-4 py-2 text-sm font-medium text-brand-700 hover:bg-brand-100 disabled:opacity-60">
                {run.isPending && run.variables === true ? 'Validating…' : 'Validate (dry run)'}
              </button>
              {/* NOT confirm(). This writes a hundred rows into a school's
                  books in one press, and a browser that has been told to stop
                  showing dialogs from this page returns false from confirm()
                  for ever, so the button would silently do nothing on the one
                  screen where "did it work?" is hardest to answer. */}
              <button
                onClick={() => setAsking(true)}
                disabled={!canImport || run.isPending}
                className="rounded bg-brand-600 px-4 py-2 text-sm font-medium text-white hover:bg-brand-700 disabled:opacity-60">
                {run.isPending && run.variables === false ? 'Importing…' : `Import ${loaded.rows.length} balance${loaded.rows.length === 1 ? '' : 's'}`}
              </button>
            </div>
            {run.isError && <p className="text-sm text-red-600">{(run.error as Error).message}</p>}
          </div>
        )}
      </div>

      {asking && loaded && (
        <AskDialog
          title={`Import ${loaded.rows.length} opening balance${loaded.rows.length === 1 ? '' : 's'}?`}
          intro={
            <>
              These become what each family owed {session.data?.name ?? 'this session'} on the day
              it started, and every fee figure in the product is built on top of them. If you have
              not run the dry run, do that first: it reports the same errors and writes nothing.
            </>
          }
          confirmLabel="Import them"
          busy={run.isPending}
          error={run.error ? (run.error as Error).message : null}
          onCancel={() => setAsking(false)}
          onSubmit={() => { setAsking(false); run.mutate(false) }}
        />
      )}
      {result && (
        <ImportResultPanel
          result={result}
          successDry="Every row is valid and ready to import. Click “Import” to save them."
          successReal="Opening balances imported. They now show in each student’s fee ledger and on the defaulter list."
          footer="Tip: re-running this file is safe. A student who already has an opening balance for the session is skipped, so balances are never double-counted."
        />
      )}
    </div>
  )
}

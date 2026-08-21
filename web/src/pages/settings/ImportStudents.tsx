import { useRef, useState } from 'react'
import { useMutation, useQuery } from '@tanstack/react-query'
import { getCurrentSession, importStudents, repairFamilies, type ImportResult } from '@/lib/db'
import { parseCSVToObjects, toCSV, downloadCSV } from '@/lib/csv'
import {
  STUDENT_IMPORT_COLUMNS, mapImportRows, canonicalColumn, missingRequiredColumns,
} from '@/lib/importStudents'
import { ImportResultPanel } from './ImportResultPanel'

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
          <li>
            Include a <span className="font-medium">Father CNIC</span> column if your register has one. Children
            sharing a CNIC are put in one family, so the parent gets a single challan instead of one per child.
            A column headed just <span className="font-medium">CNIC</span> is read as the father’s — children are
            identified by B-Form.
          </li>
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
        <ImportResultPanel
          result={result}
          successDry="Every row is valid and ready to import. Click “Import” to save them."
          successReal="All rows imported cleanly. The students are now on the roster and billable in Fees."
          footer="Tip: re-uploading the same file is safe for rows that carry a GR No or Admission No — those are skipped as duplicates. Rows without either identifier can’t be de-duplicated, so import a file once."
        />
      )}

      <JoinSiblings />
    </div>
  )
}

/**
 * After an import, put brothers and sisters back together.
 *
 * A spreadsheet from a paper register has no father-CNIC column, so every
 * imported child arrives in a family of its own and their fees do not pool —
 * the parent gets one challan per child instead of one for the family. This
 * sweeps the school for siblings sitting apart and merges them: explicit
 * sibling links first, then same father's name AND same phone number.
 *
 * Deliberately a button rather than something that runs on import: merging
 * families changes how money is collected, so it is the school's decision and
 * it should be visible when it happens.
 */
function JoinSiblings() {
  const repair = useMutation({ mutationFn: repairFamilies })

  return (
    <div className="rounded-lg border border-slate-200 bg-white p-4">
      <h3 className="text-sm font-semibold text-slate-800">Join brothers and sisters after an import</h3>
      <p className="mt-1 max-w-2xl text-sm text-slate-600">
        Imported students start in a family of their own, so a parent with three children here would get three
        separate challans. This finds children who belong together and merges them, so one payment covers the
        family.
      </p>
      <p className="mt-2 max-w-2xl text-xs text-slate-500">
        Two children are merged when the admission form linked them as siblings, or when they share{' '}
        <strong>both</strong> the father&rsquo;s name and the phone number. A shared name alone is never enough —
        too many fathers in Pakistan are called the same thing. Anything it misses can be fixed on the
        student&rsquo;s own profile, under Siblings&nbsp;/&nbsp;family.
      </p>

      <button type="button" onClick={() => repair.mutate()} disabled={repair.isPending}
        className="mt-3 rounded bg-brand-600 px-4 py-2 text-sm font-medium text-white hover:bg-brand-700 disabled:opacity-60">
        {repair.isPending ? 'Checking…' : 'Find and join siblings'}
      </button>

      {repair.isSuccess && (
        <p className="mt-2 text-sm text-money-700">
          {repair.data === 0
            ? 'Nothing to join — every family is already together.'
            : `Joined ${repair.data} ${repair.data === 1 ? 'family' : 'families'}. Their fees now collect together.`}
        </p>
      )}
      {repair.isError && <p className="mt-2 text-sm text-red-600">{(repair.error as Error).message}</p>}
    </div>
  )
}

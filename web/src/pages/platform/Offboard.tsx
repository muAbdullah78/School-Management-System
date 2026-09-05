import { useState } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import {
  exportManifest, exportTable, purgeSchool, recordExport, type PlatformSchool,
} from '@/lib/platform'
import { downloadJSON } from '@/lib/csv'
import { formatPkr } from '@/lib/licence'
import { fmtDateTime } from '@/lib/format'

const FIELD = 'w-full rounded border border-slate-300 px-2 py-1.5 text-sm'
const PAGE = 1000

/**
 * Ending a school: hand over their data, then destroy it.
 *
 * This is the only screen in the product that deletes something that cannot be
 * got back, so the shape of it is the safety:
 *
 *   Step 1 EXPORT   downloads everything they own as one JSON file. Refused by
 *                   the database unless the school is archived, so this is not a
 *                   route to a live customer's records. Recording it is what
 *                   unlocks step 2, and it is the answer if they ever say we
 *                   deleted their records without warning.
 *
 *   Step 2 DELETE   refused unless the export exists, refused unless the typed
 *                   name matches exactly, and refused if they still owe money
 *                   unless that is overridden on purpose.
 *
 * The counts written into the export record come from the rows ACTUALLY put in
 * the file, not from the manifest. If a page failed halfway the numbers will not
 * match and nobody will be able to claim the export was complete.
 */
export function OffboardDialog({ school, onClose }: {
  school: PlatformSchool; onClose: () => void
}) {
  const qc = useQueryClient()
  const q = useQuery({
    queryKey: ['exportManifest', school.school_id],
    queryFn: () => exportManifest(school.school_id),
    retry: false,
  })
  const [progress, setProgress] = useState<string | null>(null)
  const [exported, setExported] = useState<{ rows: number; at: string } | null>(null)
  const [confirm, setConfirm] = useState('')
  const [force, setForce] = useState(false)
  const [err, setErr] = useState<string | null>(null)
  const [purged, setPurged] = useState<Awaited<ReturnType<typeof purgeSchool>> | null>(null)

  const doExport = useMutation({
    mutationFn: async () => {
      const m = q.data!
      const tables: Record<string, unknown[]> = {}
      const counts: Record<string, number> = {}
      for (const t of m.tables) {
        setProgress(`${t.name} (${t.rows.toLocaleString()} rows)`)
        const rows: unknown[] = []
        // Paged, and the loop trusts the RETURNED count rather than the
        // manifest's: a table that grew between the manifest and the export
        // would otherwise be silently truncated at the old number.
        for (let off = 0; ; off += PAGE) {
          const page = await exportTable(school.school_id, t.name, off, PAGE)
          rows.push(...page.rows)
          if (page.count < PAGE) break
        }
        tables[t.name] = rows
        counts[t.name] = rows.length
      }
      setProgress('writing the file')
      const stamp = new Date().toISOString()
      downloadJSON(
        `export_${slug(school.school_name)}_${stamp.slice(0, 10)}.json`,
        {
          school: { id: school.school_id, name: school.school_name },
          exported_at: stamp,
          tables,
          counts,
          total_rows: Object.values(counts).reduce((a, b) => a + b, 0),
        },
      )
      // Recorded from what was WRITTEN, not from the manifest.
      const r = await recordExport(school.school_id, counts,
        `downloaded as export_${slug(school.school_name)}_${stamp.slice(0, 10)}.json`)
      return r
    },
    onSuccess: (r) => {
      setErr(null); setProgress(null)
      setExported({ rows: r.total_rows, at: r.taken_at })
      void qc.invalidateQueries({ queryKey: ['exportManifest', school.school_id] })
    },
    onError: (e) => { setProgress(null); setErr((e as Error).message) },
  })

  const doPurge = useMutation({
    mutationFn: () => purgeSchool(school.school_id, confirm, force),
    onSuccess: (r) => {
      setErr(null); setPurged(r)
      void qc.invalidateQueries({ queryKey: ['platformSchools'] })
      void qc.invalidateQueries({ queryKey: ['platformRevenue'] })
    },
    onError: (e) => setErr((e as Error).message),
  })

  if (purged) {
    return (
      <Shell title={`${purged.school_name} has been deleted`} onClose={onClose}>
        <p className="text-sm text-slate-700">
          {purged.rows_deleted.toLocaleString()} row(s) removed across{' '}
          {Object.keys(purged.by_table).length} table(s)
          {purged.photos_deleted > 0
            && `, and ${purged.photos_deleted} photograph(s)`}.
        </p>
        <div className="mt-3 rounded border border-slate-200 bg-slate-50 p-3 text-sm">
          <div className="font-medium text-slate-700">What was kept</div>
          <ul className="mt-1 space-y-0.5 text-slate-600">
            <li>{purged.kept.invoices} invoice(s) and {purged.kept.payments} receipt(s), with the school&rsquo;s name on them</li>
            <li>{purged.also_kept}</li>
          </ul>
          <p className="mt-2 text-xs text-slate-500">{purged.kept.why}</p>
        </div>
        <button onClick={onClose}
          className="mt-4 w-full rounded bg-brand-600 px-3 py-2 text-sm font-medium text-white hover:bg-brand-700">
          Close
        </button>
      </Shell>
    )
  }

  // The database refuses the manifest on a school that is not archived, and the
  // message it returns says so: shown as an instruction rather than an error.
  if (q.error) {
    return (
      <Shell title={`Offboard ${school.school_name}`} onClose={onClose}>
        <div className="rounded border border-amber-300 bg-amber-50 px-3 py-2 text-sm text-amber-900">
          {(q.error as Error).message}
        </div>
        <p className="mt-3 text-xs text-slate-500">
          Archiving is on the Manage screen. It hides them, kills the licence, deletes
          nothing, and can be undone in one click, which is why it comes first.
        </p>
      </Shell>
    )
  }

  const m = q.data
  const already = m?.previous_exports ?? []

  return (
    <Shell title={`Offboard ${school.school_name}`} onClose={onClose}>
      {err && <p className="rounded bg-red-50 px-3 py-2 text-sm text-red-700">{err}</p>}

      {/* --- step 1 -------------------------------------------------------- */}
      <section className="rounded border border-slate-200 p-3">
        <div className="text-sm font-semibold text-slate-800">
          1. Hand over their data
        </div>
        <p className="mt-1 text-xs text-slate-500">
          One JSON file with every row they own: pupils, guardians, fees, payments,
          marks, attendance, staff, certificates. Give it to them. It is also the
          answer if they ever say their records were deleted without warning.
        </p>
        {m && (
          <p className="mt-2 text-sm text-slate-700">
            {m.total_rows.toLocaleString()} row(s) across{' '}
            {m.tables.filter((t) => t.rows > 0).length} table(s) with data
            {' '}({m.tables.length} checked).
          </p>
        )}
        {already.length > 0 && (
          <p className="mt-1 text-xs text-slate-500">
            Already exported {fmtDateTime(already[0].taken_at)},{' '}
            {already[0].total_rows.toLocaleString()} rows
            {already[0].by && ` by ${already[0].by}`}.
          </p>
        )}
        {progress && (
          <p className="mt-2 text-sm text-brand-700">Reading {progress}…</p>
        )}
        {exported && (
          <p className="mt-2 rounded bg-emerald-50 px-2 py-1 text-sm text-emerald-800">
            Downloaded and recorded: {exported.rows.toLocaleString()} rows.
          </p>
        )}
        <button onClick={() => doExport.mutate()} disabled={doExport.isPending || !m}
          className="mt-2 rounded bg-brand-600 px-3 py-1.5 text-sm font-medium text-white hover:bg-brand-700 disabled:opacity-60">
          {doExport.isPending ? 'Exporting…'
            : already.length > 0 || exported ? 'Export again' : 'Export everything'}
        </button>
      </section>

      {/* --- step 2 -------------------------------------------------------- */}
      <section className={`mt-3 rounded border p-3 ${
        already.length > 0 || exported
          ? 'border-red-300 bg-red-50/40' : 'border-slate-200 opacity-60'}`}>
        <div className="text-sm font-semibold text-slate-800">
          2. Delete them permanently
        </div>
        {already.length === 0 && !exported ? (
          <p className="mt-1 text-xs text-slate-500">
            Take the export first. The database refuses this until it exists.
          </p>
        ) : (
          <>
            <p className="mt-1 text-xs text-red-800">
              This cannot be undone. Every pupil, guardian, payment, mark and photograph
              is destroyed. Your own invoices and receipts are kept, with the school&rsquo;s
              name on them, because a business keeps its sales ledger.
            </p>
            {school.outstanding > 0 && (
              <label className="mt-2 flex items-start gap-2 text-xs text-amber-900">
                <input type="checkbox" checked={force} className="mt-0.5"
                  onChange={(e) => setForce(e.target.checked)} />
                <span>
                  They still owe {formatPkr(school.outstanding)}. Deleting them does not
                  collect it and does not write it off: raise a credit note if you are
                  forgiving it. Tick to delete anyway.
                </span>
              </label>
            )}
            <label className="mt-2 block">
              <span className="text-xs font-medium text-slate-700">
                Type the school&rsquo;s name exactly: <span className="font-mono">{school.school_name}</span>
              </span>
              <input className={FIELD} value={confirm} autoComplete="off"
                onChange={(e) => setConfirm(e.target.value)} />
            </label>
            <button
              onClick={() => doPurge.mutate()}
              disabled={doPurge.isPending
                || confirm !== school.school_name
                || (school.outstanding > 0 && !force)}
              className="mt-2 rounded bg-red-600 px-3 py-1.5 text-sm font-medium text-white hover:bg-red-700 disabled:opacity-50">
              {doPurge.isPending ? 'Deleting…' : 'Delete this school for ever'}
            </button>
          </>
        )}
      </section>
    </Shell>
  )
}

function Shell({ title, onClose, children }: {
  title: string; onClose: () => void; children: React.ReactNode
}) {
  return (
    <div className="fixed inset-0 z-50 flex items-start justify-center overflow-y-auto bg-black/40 p-4">
      <div className="w-full max-w-lg rounded-lg bg-white p-5 shadow-lg">
        <div className="flex items-start justify-between gap-3">
          <h2 className="text-base font-semibold text-slate-800">{title}</h2>
          <button onClick={onClose} className="text-sm text-slate-500 hover:underline">Close</button>
        </div>
        <div className="mt-3">{children}</div>
      </div>
    </div>
  )
}

function slug(s: string): string {
  return s.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '').slice(0, 40)
}

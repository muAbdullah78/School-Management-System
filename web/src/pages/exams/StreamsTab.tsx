/**
 * Streams and board registration numbers.
 *
 * `enrollments.stream` and `enrollments.bise_reg_no` existed from the first
 * migration and no screen could set either. That is not a cosmetic gap: without
 * a stream, a class-9 result card was computed over every paper in the class,
 * so a Science pupil was marked out of the Arts syllabus too. Two A+ pupils came
 * out as a C and a D and the ranking inverted. See
 * docs/EXAM-COMPUTATION-DESIGN.md.
 *
 * So this screen is the other half of that fix, and it is built as ONE LIST the
 * school works down: not a field buried in each pupil's profile. Setting a
 * stream for forty pupils one profile at a time is why these columns stayed
 * empty, and a half-filled stream column is worse than an empty one: generation
 * refuses on an empty one and cannot detect a wrong one.
 */
import { useEffect, useState } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import {
  getClassStreams, listClasses, listSubjects, setEnrollmentStream,
  type ClassStreamRow,
} from '@/lib/db'
import { useAuth } from '@/auth/AuthProvider'
import { toCSV, downloadCSV } from '@/lib/csv'

const FIELD = 'mt-1 w-full rounded border border-slate-300 px-3 py-2 text-sm focus:border-brand-500 focus:outline-none focus:ring-1 focus:ring-brand-500'

type Edit = { stream: string; bise: string }

export function StreamsTab() {
  const qc = useQueryClient()
  const { profile } = useAuth()
  const canEdit = !!profile && ['owner', 'principal', 'admin_clerk'].includes(profile.role)

  const classes = useQuery({ queryKey: ['classes'], queryFn: listClasses })
  const [classId, setClassId] = useState('')

  const pupils = useQuery({
    queryKey: ['classStreams', classId],
    queryFn: () => getClassStreams(classId),
    enabled: !!classId,
  })
  // The streams this class's subjects actually use. Offered as a datalist so a
  // school picks the spelling it already used rather than inventing a second
  // one: 'Science' and 'Sciences' are two streams as far as any computer is
  // concerned, and the pupils in the second one would quietly lose subjects.
  const subjects = useQuery({
    queryKey: ['subjects', classId], queryFn: () => listSubjects(classId), enabled: !!classId,
  })
  const knownStreams = [...new Set(
    (subjects.data ?? []).map((s) => s.stream).filter((x): x is string => !!x),
  )].sort()

  const [edits, setEdits] = useState<Record<string, Edit>>({})
  const [saved, setSaved] = useState<string | null>(null)

  useEffect(() => {
    const next: Record<string, Edit> = {}
    for (const p of pupils.data ?? []) {
      next[p.enrollment_id] = { stream: p.stream ?? '', bise: p.bise_reg_no ?? '' }
    }
    setEdits(next)
    setSaved(null)
  }, [pupils.data])

  const save = useMutation({
    mutationFn: async () => {
      // Only the rows that actually changed. Writing all forty would fill the
      // updated_at column with noise and make a real change impossible to find.
      const changed = (pupils.data ?? []).filter((p) => {
        const e = edits[p.enrollment_id]
        if (!e) return false
        return (e.stream.trim() || null) !== (p.stream ?? null)
          || (e.bise.trim() || null) !== (p.bise_reg_no ?? null)
      })
      for (const p of changed) {
        const e = edits[p.enrollment_id]
        await setEnrollmentStream(p.enrollment_id, e.stream.trim() || null, e.bise.trim() || null)
      }
      return changed.length
    },
    onSuccess: (n) => {
      setSaved(n === 0 ? 'Nothing had changed.' : `Saved ${n} pupil${n === 1 ? '' : 's'}.`)
    },
    // Saved one pupil at a time, so a failure half way leaves the first half
    // saved. Re-reading on failure as well shows exactly which ones went in,
    // instead of leaving the screen claiming nothing was saved. The result
    // cards for this class depend on these values.
    onSettled: () => {
      qc.invalidateQueries({ queryKey: ['classStreams', classId] })
      qc.invalidateQueries({ queryKey: ['resultReadiness'] })
    },
  })

  const rows = pupils.data ?? []
  const noStream = rows.filter((p) => !(edits[p.enrollment_id]?.stream ?? '').trim()).length
  // A stream no subject in the class carries is allowed (a school may be
  // adding one), but it matches no streamed paper, so that pupil's card would
  // carry only the subjects everybody takes. Worth a question before saving:
  // "science" typed as "sceince" is the usual cause. Compared without case, as
  // the result card compares it.
  const known = new Set(knownStreams.map((x) => x.toLowerCase()))
  const strays = knownStreams.length === 0 ? 0 : rows.filter((p) => {
    const v = (edits[p.enrollment_id]?.stream ?? '').trim().toLowerCase()
    return v !== '' && !known.has(v)
  }).length
  const dirty = rows.some((p) => {
    const e = edits[p.enrollment_id]
    if (!e) return false
    return (e.stream.trim() || null) !== (p.stream ?? null)
      || (e.bise.trim() || null) !== (p.bise_reg_no ?? null)
  })

  // The saved values, not the unsaved edits: a board form filled from what is on
  // screen but not yet in the database is a board form that disagrees with the
  // school's own records.
  const exportCsv = () => {
    downloadCSV(
      `board-list-${(classes.data?.find((c) => c.id === classId)?.name ?? 'class').replace(/\s+/g, '-')}`,
      toCSV(
        ['Roll', 'GR No', 'Name', "Father's name", 'Section', 'Stream', 'Board Reg No'],
        rows.map((p) => [
          p.roll_no ?? '', p.gr_no ?? '', p.full_name, p.father_name ?? '',
          p.section_name ?? '', p.stream ?? '', p.bise_reg_no ?? '',
        ]),
      ),
    )
  }

  const applyToAllBlank = (stream: string) => {
    setEdits((m) => {
      const next = { ...m }
      for (const p of rows) {
        if (!(next[p.enrollment_id]?.stream ?? '').trim()) {
          next[p.enrollment_id] = { ...next[p.enrollment_id], stream }
        }
      }
      return next
    })
    setSaved(null)
  }

  return (
    <div>
      <label className="block max-w-sm">
        <span className="text-sm text-slate-600">Class</span>
        <select value={classId} onChange={(e) => setClassId(e.target.value)} className={FIELD}>
          <option value="">Select class…</option>
          {classes.data?.map((c) => <option key={c.id} value={c.id}>{c.name}</option>)}
        </select>
      </label>

      {!classId && (
        <p className="mt-5 text-sm text-slate-500">
          Choose a class. Streams matter for classes 9 to 12, where pupils take different
          subjects, and a pupil with no stream in a streamed class cannot have a result card
          generated at all, on purpose.
        </p>
      )}

      {classId && knownStreams.length === 0 && (
        <div className="mt-5 rounded-lg border border-slate-200 bg-slate-50 p-3 text-sm text-slate-600">
          None of this class&rsquo;s subjects belongs to a stream, so every pupil takes every
          subject and no stream is needed here. Give a subject a stream under
          <strong> Setup</strong> first if this class splits into Science and Arts.
          Board registration numbers can still be entered below.
        </div>
      )}

      {classId && rows.length > 0 && (
        <>
          <div className="mt-4 flex flex-wrap items-center gap-2">
            {knownStreams.length > 0 && noStream > 0 && canEdit && (
              <>
                <span className="text-xs text-slate-500">
                  {noStream} pupil{noStream === 1 ? '' : 's'} with no stream: set them all to:
                </span>
                {knownStreams.map((st) => (
                  <button key={st} onClick={() => applyToAllBlank(st)}
                    className="rounded border border-slate-300 px-2.5 py-1 text-xs font-medium text-slate-700 hover:bg-slate-50">
                    {st}
                  </button>
                ))}
              </>
            )}
            <button onClick={exportCsv}
              className="ml-auto rounded border border-slate-300 px-3 py-1.5 text-xs font-medium text-slate-700 hover:bg-slate-50">
              Export board list (CSV)
            </button>
          </div>

          {strays > 0 && (
            <p className="mt-3 rounded-xl border border-due-200 bg-due-50 px-3 py-2 text-sm text-due-800">
              {strays} pupil{strays === 1 ? ' has' : 's have'} a stream that none of this class&rsquo;s subjects
              uses ({knownStreams.join(', ')} are). Their result card would carry only the subjects every pupil
              takes. Check the spelling, or give a subject that stream under Setup.
            </p>
          )}
          {/* One list for the whole table. It used to be repeated inside every
              row, which put forty elements with the same id on the page. */}
          <datalist id="known-streams">
            {knownStreams.map((st) => <option key={st} value={st} />)}
          </datalist>
          {/* On a phone each pupil is a stacked card (the table's own rows shown
              as blocks), with the two boxes full width and labelled. */}
          <div className="mt-3 rounded-lg border border-slate-200 bg-white sm:overflow-x-auto">
            <table className="block w-full text-sm sm:table">
              <thead className="hidden bg-slate-50 text-left text-xs uppercase tracking-wide text-slate-500 sm:table-header-group">
                <tr>
                  <th className="px-3 py-2 w-14">Roll</th>
                  <th className="px-3 py-2">Student</th>
                  <th className="px-3 py-2 w-40">Stream</th>
                  <th className="px-3 py-2 w-52">Board registration no</th>
                </tr>
              </thead>
              <tbody className="block divide-y divide-slate-100 sm:table-row-group">
                {rows.map((p) => (
                  <StreamRow
                    key={p.enrollment_id} pupil={p} canEdit={canEdit}
                    known={knownStreams}
                    edit={edits[p.enrollment_id] ?? { stream: '', bise: '' }}
                    onChange={(patch) => {
                      setEdits((m) => ({
                        ...m, [p.enrollment_id]: { ...m[p.enrollment_id], ...patch },
                      }))
                      setSaved(null)
                    }}
                  />
                ))}
              </tbody>
            </table>
          </div>

          {canEdit && (
            <div className="mt-4 flex items-center gap-3">
              <button onClick={() => save.mutate()} disabled={!dirty || save.isPending}
                className="rounded-lg bg-brand-600 px-4 py-2 text-sm font-medium text-white shadow-card hover:bg-brand-700 disabled:opacity-60">
                {save.isPending ? 'Saving…' : 'Save'}
              </button>
              {saved && <span className="text-sm font-medium text-brand-700">{saved}</span>}
              {save.isError && <span className="text-sm text-danger-600">{(save.error as Error).message}</span>}
              {!dirty && !saved && <span className="text-xs text-slate-400">No changes to save.</span>}
            </div>
          )}
          {!canEdit && (
            <p className="mt-3 text-xs text-slate-500">Only the office can change a stream.</p>
          )}
        </>
      )}

      {classId && rows.length === 0 && !pupils.isLoading && (
        <p className="mt-5 text-sm text-slate-500">Nobody is enrolled in this class this session.</p>
      )}
      {pupils.isError && <p className="mt-5 text-sm text-danger-600">{(pupils.error as Error).message}</p>}
    </div>
  )
}

function StreamRow({ pupil, edit, known, canEdit, onChange }: {
  pupil: ClassStreamRow
  edit: Edit
  known: string[]
  canEdit: boolean
  onChange: (patch: Partial<Edit>) => void
}) {
  const missing = known.length > 0 && !edit.stream.trim()
  const stray = known.length > 0 && !!edit.stream.trim()
    && !known.some((k) => k.toLowerCase() === edit.stream.trim().toLowerCase())
  return (
    <tr className={`block p-3 sm:table-row sm:p-0 ${missing || stray ? 'bg-due-50/60' : ''}`}>
      <td className="hidden px-3 py-2 text-slate-500 sm:table-cell">{pupil.roll_no ?? '-'}</td>
      <td className="block font-medium text-slate-800 sm:table-cell sm:px-3 sm:py-2 sm:font-normal">
        <span className="mr-1.5 text-slate-400 sm:hidden">{pupil.roll_no ?? ''}</span>
        {pupil.full_name}
        <span className="text-slate-400">
          {pupil.gr_no ? ` · ${pupil.gr_no}` : ''}
          {pupil.section_name ? ` · ${pupil.section_name}` : ''}
        </span>
      </td>
      <td className="mt-2 block sm:mt-0 sm:table-cell sm:px-3 sm:py-2">
        <span className="mb-0.5 block text-[11px] text-slate-500 sm:hidden">Stream</span>
        {/* A datalist, not a free field with no help and not a closed dropdown:
            the school must be able to name a stream this class has never used,
            while being nudged to reuse the exact spelling its subjects carry. */}
        <input
          list="known-streams"
          value={edit.stream} disabled={!canEdit}
          onChange={(e) => onChange({ stream: e.target.value })}
          placeholder={known.length > 0 ? 'required' : 'none'}
          className={`w-full rounded-lg border px-3 py-2 text-sm disabled:bg-slate-100 sm:w-32 sm:rounded sm:px-2 sm:py-1 ${missing || stray ? 'border-due-400' : 'border-slate-300'}`}
        />
      </td>
      <td className="mt-2 block sm:mt-0 sm:table-cell sm:px-3 sm:py-2">
        <span className="mb-0.5 block text-[11px] text-slate-500 sm:hidden">Board registration no</span>
        <input
          value={edit.bise} disabled={!canEdit}
          onChange={(e) => onChange({ bise: e.target.value })}
          placeholder="e.g. 2026-BISE-01234"
          className="w-full rounded-lg border border-slate-300 px-3 py-2 text-sm disabled:bg-slate-100 sm:w-44 sm:rounded sm:px-2 sm:py-1"
        />
      </td>
    </tr>
  )
}

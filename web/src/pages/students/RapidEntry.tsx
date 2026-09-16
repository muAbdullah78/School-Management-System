/**
 * Getting a school's register into the software.
 *
 * THE BOTTLENECK THIS EXISTS FOR. A school signs up with four hundred children
 * already written down, and the product offered two ways in, both of which lose
 * the trial before the dashboard is ever seen:
 *
 *   the admission form   correct, thorough, minutes per child. Four hundred
 *                        children is a fortnight of evenings.
 *   the CSV importer     asks a head teacher to produce a column-mapped
 *                        spreadsheet and then read validation errors. That is
 *                        not a data-entry problem, it is a software-literacy
 *                        problem, and it is the one this product exists to
 *                        remove.
 *
 * The importer is untouched and still in Settings: it is the right tool for a
 * school that already keeps its roster in Excel, and for the consultant who
 * sets them up. What was missing is the third way, for everybody else: typing
 * straight down a class list the way the register is already read aloud.
 *
 * TWO SHAPES, ONE BACKEND. Quick Add is one child with the money on it, for a
 * walk-in or for finishing a class somebody started. The grid is a hundred
 * children with names and roll numbers, for the first afternoon. Both call
 * fn_rde_add_students, so the family resolution, the GR allotment and the draft
 * rule cannot differ between them.
 */
import { useEffect, useState } from 'react'
import { useQuery } from '@tanstack/react-query'
import { getCurrentSession, listClasses, listSections } from '@/lib/db'
import { PageHeader, Card, EmptyState, LoadError } from '@/components/ui'
import { IconStudents, IconAlert } from '@/components/icons'
import { QuickAdd } from './QuickAdd'
import { BulkClassAdd } from './BulkClassAdd'

const SELECT =
  'rounded border border-slate-300 px-2.5 py-2 text-sm focus:border-brand-500 focus:outline-none'

type Mode = 'quick' | 'bulk'

export function RapidEntry({ mode, onMode, onDone }: {
  mode: Mode; onMode: (m: Mode) => void; onDone: () => void
}) {
  const session = useQuery({ queryKey: ['currentSession'], queryFn: getCurrentSession })
  const classes = useQuery({ queryKey: ['classes'], queryFn: listClasses })

  /* The class and section are REMEMBERED ACROSS VISITS. A clerk doing this over
     two afternoons should not re-pick Class 4 (B) every time they come back,
     and it is the single most-repeated action on the screen. */
  const [classId, setClassId] = useState(() => {
    try { return localStorage.getItem('rde.classId') ?? '' } catch { return '' }
  })
  const [sectionId, setSectionId] = useState(() => {
    try { return localStorage.getItem('rde.sectionId') ?? '' } catch { return '' }
  })
  const sections = useQuery({
    queryKey: ['sections', classId], queryFn: () => listSections(classId), enabled: !!classId,
  })

  useEffect(() => { try { localStorage.setItem('rde.classId', classId) } catch { /* ignore */ } }, [classId])
  useEffect(() => { try { localStorage.setItem('rde.sectionId', sectionId) } catch { /* ignore */ } }, [sectionId])

  // A section belonging to another class is not a valid choice; clear it rather
  // than silently sending it to the server.
  useEffect(() => {
    if (!classId) { setSectionId(''); return }
    if (sections.data && sectionId && !sections.data.some((s) => s.id === sectionId)) setSectionId('')
  }, [classId, sections.data, sectionId])

  const cls = classes.data?.find((c) => c.id === classId)
  const sec = sections.data?.find((s) => s.id === sectionId)

  if (session.isError) return <LoadError of={[session]} what="the school year" />

  return (
    <div>
      <button onClick={onDone} className="text-sm text-brand-700 hover:underline">
        ← Back to the roster
      </button>

      <PageHeader
        icon={<IconStudents />}
        title="Add students"
        subtitle="Type straight off the register. Nothing is required except a name."
      />

      {!session.isLoading && !session.data && (
        <Card className="border-due-200 bg-due-50/60">
          <p className="flex items-start gap-2 text-sm text-due-900">
            <span className="mt-0.5 text-due-600"><IconAlert /></span>
            <span>
              No school year is set as current, so there is nothing to enrol anybody into. Set one
              under Settings → School year first.
            </span>
          </p>
        </Card>
      )}

      {session.data && (
        <>
          {/* ---------------------------------------------- where they go -- */}
          <div className="mb-4 flex flex-wrap items-center gap-2 rounded-xl border border-slate-200 bg-white p-3">
            <span className="text-xs font-medium uppercase tracking-wide text-slate-500">Into</span>
            <select value={classId} onChange={(e) => { setClassId(e.target.value); setSectionId('') }}
              aria-label="Class" className={SELECT}>
              <option value="">Pick a class…</option>
              {classes.data?.map((c) => <option key={c.id} value={c.id}>{c.name}</option>)}
            </select>
            <select value={sectionId} onChange={(e) => setSectionId(e.target.value)}
              aria-label="Section" disabled={!classId || (sections.data?.length ?? 0) === 0}
              className={SELECT}>
              <option value="">
                {(sections.data?.length ?? 0) === 0 ? 'No sections' : 'No section'}
              </option>
              {sections.data?.map((s) => <option key={s.id} value={s.id}>{s.name}</option>)}
            </select>
            <span className="text-xs text-slate-400">{session.data.name}</span>

            <span className="ml-auto flex overflow-hidden rounded-lg border border-slate-200">
              {(['quick', 'bulk'] as Mode[]).map((m) => (
                <button key={m} onClick={() => onMode(m)}
                  className={`px-3 py-1.5 text-sm ${
                    mode === m ? 'bg-brand-600 font-medium text-white' : 'bg-white text-slate-600 hover:bg-slate-50'
                  }`}>
                  {m === 'quick' ? 'One at a time' : 'A whole class'}
                </button>
              ))}
            </span>
          </div>

          {!classId ? (
            <Card>
              <EmptyState
                icon={<IconStudents />}
                title="Pick a class"
                message="Everything below fills that class's list. Sections are optional: a school that does not use them can leave it blank."
              />
            </Card>
          ) : mode === 'quick' ? (
            <QuickAdd
              sessionId={session.data.id}
              sessionStart={session.data.starts_on ?? null}
              classId={classId}
              sectionId={sectionId}
            />
          ) : (
            <BulkClassAdd
              sessionId={session.data.id}
              sessionStart={session.data.starts_on ?? null}
              classId={classId}
              sectionId={sectionId}
              className={cls?.name ?? 'Class'}
              sectionName={sec?.name ?? ''}
            />
          )}
        </>
      )}
    </div>
  )
}

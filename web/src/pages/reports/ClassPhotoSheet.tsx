/**
 * The class photo sheet.
 *
 * Two jobs, and the second is the one that gets the photographs taken at all:
 *
 *  1. A printable grid of faces with roll numbers, which is what an invigilator
 *     carries into an exam hall and what a new class teacher learns names from.
 *  2. The place where a whole class is photographed. Every face here is also the
 *     upload button, so a clerk with a phone works down one screen instead of
 *     opening forty profiles. Without this, "student photographs" is a feature
 *     that exists and never gets used, because nobody photographs 800 children
 *     one navigation at a time.
 *
 * It also answers the question a principal will ask on day two — "how many are
 * still missing?" — with a number and a filter, rather than leaving them to
 * count squares.
 */
import { useMemo, useState } from 'react'
import { useQuery, useQueryClient } from '@tanstack/react-query'
import { getClassPhotoPaths, listClasses, listSections, getSchoolLogoPath } from '@/lib/db'
import { removeStudentPhoto, signPath, signPaths, uploadStudentPhoto } from '@/lib/photos'
import { PhotoUpload } from '@/components/PhotoUpload'
import { SchoolMark } from '@/components/Avatar'
import { useSchoolName } from '@/hooks/useSchoolName'
import { useAuth } from '@/auth/AuthProvider'

const SELECT = 'rounded border border-slate-300 px-2 py-2 text-sm focus:border-brand-500 focus:outline-none'

export function ClassPhotoSheet() {
  const qc = useQueryClient()
  const schoolName = useSchoolName()
  const { profile } = useAuth()
  // The same three roles fn_set_student_photo allows. A teacher gets the sheet
  // to read; only the office changes what is on a record.
  const mayEdit = !!profile && ['owner', 'principal', 'admin_clerk'].includes(profile.role)

  const [classId, setClassId] = useState('')
  const [sectionId, setSectionId] = useState('')
  const [onlyMissing, setOnlyMissing] = useState(false)

  const classes = useQuery({ queryKey: ['classes'], queryFn: listClasses })
  const sections = useQuery({
    queryKey: ['sections', classId], queryFn: () => listSections(classId), enabled: !!classId,
  })

  const pupils = useQuery({
    queryKey: ['classPhotos', classId, sectionId],
    queryFn: () => getClassPhotoPaths(classId, sectionId || null),
    enabled: !!classId,
  })

  // ONE signing request for the whole class. This is the reason
  // fn_class_photo_paths exists rather than forty selects.
  const paths = (pupils.data ?? []).map((p) => p.photo_path).filter(Boolean) as string[]
  const faces = useQuery({
    queryKey: ['classFaces', [...paths].sort().join('|')],
    queryFn: () => signPaths(paths),
    enabled: paths.length > 0,
    staleTime: 20 * 60 * 1000,
  })

  const logoPath = useQuery({ queryKey: ['schoolLogoPath'], queryFn: getSchoolLogoPath })
  const logo = useQuery({
    queryKey: ['schoolLogo', logoPath.data],
    queryFn: () => signPath(logoPath.data ?? null),
    enabled: !!logoPath.data,
  })

  const rows = pupils.data ?? []
  const missing = rows.filter((r) => !r.photo_path).length
  const shown = useMemo(
    () => (onlyMissing ? rows.filter((r) => !r.photo_path) : rows),
    [rows, onlyMissing],
  )

  const className = classes.data?.find((c) => c.id === classId)?.name ?? ''
  const sectionName = sections.data?.find((s) => s.id === sectionId)?.name ?? ''

  // Both this sheet and the pupil's own profile read the same paths.
  const refresh = () => {
    qc.invalidateQueries({ queryKey: ['classPhotos'] })
    qc.invalidateQueries({ queryKey: ['studentFaces'] })
    qc.invalidateQueries({ queryKey: ['student'] })
  }

  return (
    <div>
      <div className="flex flex-wrap items-end gap-2 print:hidden">
        <label className="block">
          <span className="block text-xs text-slate-500">Class</span>
          <select
            value={classId}
            onChange={(e) => { setClassId(e.target.value); setSectionId('') }}
            className={SELECT}
          >
            <option value="">Choose a class…</option>
            {classes.data?.map((c) => <option key={c.id} value={c.id}>{c.name}</option>)}
          </select>
        </label>
        <label className="block">
          <span className="block text-xs text-slate-500">Section</span>
          <select value={sectionId} onChange={(e) => setSectionId(e.target.value)}
            disabled={!classId} className={SELECT}>
            <option value="">All sections</option>
            {sections.data?.map((s) => <option key={s.id} value={s.id}>{s.name}</option>)}
          </select>
        </label>
        {rows.length > 0 && (
          <label className="flex items-center gap-1.5 pb-2 text-xs text-slate-600">
            <input type="checkbox" checked={onlyMissing}
              onChange={(e) => setOnlyMissing(e.target.checked)} className="h-4 w-4" />
            Only those without a photograph
          </label>
        )}
        {rows.length > 0 && (
          <button onClick={() => window.print()}
            className="ml-auto rounded border border-slate-300 px-3 py-2 text-sm font-medium text-slate-700 hover:bg-slate-50">
            Print sheet
          </button>
        )}
      </div>

      {!classId && (
        <p className="mt-6 text-sm text-slate-500">
          Choose a class to see its photo sheet.
          {mayEdit && ' Tap any face to add or change a photograph — this is the quickest way to photograph a whole class.'}
        </p>
      )}

      {pupils.isLoading && <p className="mt-6 text-sm text-slate-500">Loading…</p>}
      {pupils.isError && <p className="mt-6 text-sm text-red-600">{(pupils.error as Error).message}</p>}

      {classId && !pupils.isLoading && rows.length === 0 && (
        <p className="mt-6 text-sm text-slate-500">
          Nobody is enrolled in this class in the current session.
        </p>
      )}

      {rows.length > 0 && (
        <div className="mt-4" id="report">
          {/* The letterhead, so a printed sheet is recognisably the school's. */}
          <div className="mb-3 flex items-center gap-3 border-b border-slate-200 pb-3">
            <SchoolMark name={schoolName} url={logo.data ?? null} />
            <div className="min-w-0">
              <div className="text-sm font-semibold text-slate-800">
                Class photo sheet — {className}{sectionName ? `-${sectionName}` : ''}
              </div>
              <div className="text-xs text-slate-500">
                {rows.length} {rows.length === 1 ? 'pupil' : 'pupils'}
                {missing > 0
                  ? ` · ${missing} without a photograph`
                  : ' · every pupil photographed'}
              </div>
            </div>
          </div>

          {onlyMissing && shown.length === 0 && (
            <p className="text-sm text-money-700">
              Every pupil in this class has a photograph.
            </p>
          )}

          <div className="grid grid-cols-3 gap-4 sm:grid-cols-5 md:grid-cols-6 lg:grid-cols-8">
            {shown.map((p) => (
              <div key={p.student_id} className="text-center">
                <PhotoUpload
                  compact
                  size="lg"
                  square
                  name={p.full_name}
                  path={p.photo_path}
                  url={faces.data?.get(p.photo_path ?? '') ?? null}
                  disabled={!mayEdit}
                  onUpload={(file) => uploadStudentPhoto(p.student_id, file)}
                  onRemove={() => removeStudentPhoto(p.student_id, p.photo_path)}
                  onChanged={refresh}
                />
                <div className="mt-1 truncate text-[11px] font-medium leading-tight text-slate-700"
                  title={p.full_name}>
                  {p.full_name}
                </div>
                <div className="text-[10px] text-slate-400">{p.roll_no ?? '—'}</div>
              </div>
            ))}
          </div>
        </div>
      )}
    </div>
  )
}

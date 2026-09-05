/**
 * The roster.
 *
 * What this replaced: a <ul> of buttons showing name, father's name and GR
 * number, capped at fifty rows with no count and no notice. An 800-student
 * school saw the first fifty names alphabetically and was never told the other
 * 750 existed: silent truncation on the flagship list of the product. No
 * class, no section, no roll number, and no balance, on a product whose entire
 * purpose is students and money.
 *
 * Now: a real table with class, section, roll and balance; filters by class and
 * section; paging that reports the true total; sortable columns; CSV; and an
 * explicit "include struck-off" switch, because a struck-off child still owes
 * money and still has to be findable.
 */
import { useState } from 'react'
import { useSearchParams } from 'react-router-dom'
import { useQuery } from '@tanstack/react-query'
import {
  listStudentPage, listClasses, listSections, getStudentPhotoPaths,
  listStudentsWithoutAClass, type StudentListRow,
} from '@/lib/db'
import { fmtDate } from '@/lib/format'
import { DataTable, type Column } from '@/components/DataTable'
import { fmtPKR } from '@/lib/format'
import { StudentProfile } from './StudentProfile'
import { Avatar } from '@/components/Avatar'
import { signPaths } from '@/lib/photos'

const SELECT =
  'rounded border border-slate-300 px-2 py-2 text-sm focus:border-brand-500 focus:outline-none'

export function StudentsPage() {
  // The dashboard links here with ?no_class=1 when it has counted children who
  // are on no class list. Read from the URL rather than kept in state so the
  // link works from anywhere, including a bookmark or a message to a colleague.
  const [params, setParams] = useSearchParams()
  const [term, setTerm] = useState('')
  const [classId, setClassId] = useState('')
  const [sectionId, setSectionId] = useState('')
  const [includeInactive, setIncludeInactive] = useState(false)
  const [page, setPage] = useState(0)
  const [pageSize, setPageSize] = useState(50)
  const [selectedId, setSelectedId] = useState<string | null>(null)

  const classes = useQuery({ queryKey: ['classes'], queryFn: listClasses })
  const sections = useQuery({
    queryKey: ['sections', classId],
    queryFn: () => listSections(classId),
    enabled: !!classId,
  })

  const q = useQuery({
    queryKey: ['studentPage', term, classId, sectionId, includeInactive, page, pageSize],
    queryFn: () =>
      listStudentPage({
        term,
        classId: classId || null,
        sectionId: sectionId || null,
        includeInactive,
        limit: pageSize,
        offset: page * pageSize,
      }),
  })

  /**
   * Faces for the fifty rows on screen, in two requests regardless of page size.
   *
   * Worth the round trips: four boys called Muhammad Ali in one school is
   * ordinary here, and a face is how a clerk knows they opened the right one.
   * Both steps degrade to nothing rather than failing the page.
   */
  const ids = (q.data?.rows ?? []).map((r) => r.student_id)
  const idKey = ids.join('|')
  const faces = useQuery({
    queryKey: ['studentFaces', idKey],
    queryFn: async () => {
      const paths = await getStudentPhotoPaths(ids)
      const signed = await signPaths([...paths.values()])
      // Re-keyed by student id: the table has a pupil in hand, not a path.
      const byStudent = new Map<string, string>()
      for (const [studentId, path] of paths) {
        const url = signed.get(path)
        if (url) byStudent.set(studentId, url)
      }
      return byStudent
    },
    enabled: ids.length > 0,
    staleTime: 20 * 60 * 1000,
  })

  if (selectedId) {
    return (
      <StudentProfile
        studentId={selectedId}
        onBack={() => setSelectedId(null)}
        onOpen={setSelectedId}
      />
    )
  }

  // Any filter change has to reset to page one, or a search that returns three
  // students while you are on page 7 shows an empty table.
  const reset = <T,>(setter: (v: T) => void) => (v: T) => {
    setter(v)
    setPage(0)
  }

  const columns: Column<StudentListRow>[] = [
    {
      key: 'roll_no',
      header: 'Roll',
      align: 'right',
      sortable: true,
      secondary: true,
      value: (r) => (r.roll_no ? Number(r.roll_no.replace(/\D/g, '')) || null : null),
      render: (r) => <span className="text-slate-500">{r.roll_no ?? '-'}</span>,
    },
    {
      key: 'full_name',
      header: 'Student',
      sortable: true,
      value: (r) => r.full_name,
      render: (r) => (
        <div className="flex items-center gap-2">
          {/* print:hidden: signed URLs do not survive a printed page reliably,
              and a printed roster with forty broken image boxes is worse than a
              printed roster of names. */}
          <Avatar
            name={r.full_name} url={faces.data?.get(r.student_id) ?? null}
            size="sm" className="print:hidden"
          />
          <div className="min-w-0">
            <div className="font-medium text-slate-800">{r.full_name}</div>
            <div className="text-xs text-slate-400">
              {r.gr_no ?? '-'}
              {r.status !== 'active' ? ` · ${r.status.replace('_', ' ')}` : ''}
            </div>
          </div>
        </div>
      ),
    },
    {
      key: 'father_name',
      header: 'Father',
      sortable: true,
      value: (r) => r.father_name,
      render: (r) => <span className="text-slate-600">{r.father_name ?? '-'}</span>,
    },
    {
      key: 'class_name',
      header: 'Class',
      sortable: true,
      value: (r) => `${r.class_name ?? ''}${r.section_name ?? ''}`,
      render: (r) => (
        <span className="whitespace-nowrap text-slate-600">
          {r.class_name ?? '-'}
          {r.section_name ? `-${r.section_name}` : ''}
        </span>
      ),
    },
    {
      key: 'phone',
      header: 'Phone',
      secondary: true,
      value: (r) => r.phone,
      render: (r) => <span className="text-slate-500">{r.phone ?? '-'}</span>,
    },
    {
      key: 'balance',
      header: 'Owes',
      align: 'right',
      sortable: true,
      value: (r) => r.balance,
      render: (r) =>
        r.balance > 0 ? (
          <span className="font-semibold text-danger-600">{fmtPKR(r.balance)}</span>
        ) : r.balance < 0 ? (
          // Negative means the family is in credit, which is not the same as
          // "clear" and must not be shown as a debt.
          <span className="text-money-700">{fmtPKR(-r.balance)} advance</span>
        ) : (
          <span className="text-slate-400">-</span>
        ),
    },
  ]

  return (
    <div>
      <h1 className="text-xl font-semibold text-slate-800">Students</h1>
      <p className="mt-1 text-sm text-slate-500">
        The whole roster. Search by name, GR number, admission number or father&rsquo;s name.
      </p>

      <NotInAClass
        open={params.get('no_class') === '1'}
        onOpenChange={(v) => {
          const next = new URLSearchParams(params)
          if (v) next.set('no_class', '1'); else next.delete('no_class')
          setParams(next, { replace: true })
        }}
        onOpen={setSelectedId}
      />

      <div className="mt-4">
        <DataTable
          rows={q.data?.rows ?? []}
          total={q.data?.total}
          columns={columns}
          rowKey={(r) => r.student_id}
          page={page}
          pageSize={pageSize}
          onPageChange={setPage}
          onPageSizeChange={reset(setPageSize)}
          search={term}
          onSearchChange={reset(setTerm)}
          searchPlaceholder="Name, GR number, admission number or father's name"
          onRowClick={(r) => setSelectedId(r.student_id)}
          loading={q.isLoading}
          error={q.isError ? (q.error as Error).message : null}
          emptyTitle="No students match"
          emptyMessage="Try fewer letters, or clear the class filter."
          exportName="students"
          printId="report"
          toolbarExtra={
            <>
              <select
                value={classId}
                onChange={(e) => {
                  setClassId(e.target.value)
                  setSectionId('')
                  setPage(0)
                }}
                aria-label="Class"
                className={SELECT}
              >
                <option value="">All classes</option>
                {classes.data?.map((c) => (
                  <option key={c.id} value={c.id}>
                    {c.name}
                  </option>
                ))}
              </select>
              <select
                value={sectionId}
                onChange={(e) => reset(setSectionId)(e.target.value)}
                aria-label="Section"
                disabled={!classId}
                className={SELECT}
              >
                <option value="">All sections</option>
                {sections.data?.map((s) => (
                  <option key={s.id} value={s.id}>
                    {s.name}
                  </option>
                ))}
              </select>
              <label className="flex items-center gap-1.5 whitespace-nowrap text-xs text-slate-600">
                <input
                  type="checkbox"
                  checked={includeInactive}
                  onChange={(e) => reset(setIncludeInactive)(e.target.checked)}
                  className="h-4 w-4"
                />
                Include struck off
              </label>
            </>
          }
        />
      </div>
    </div>
  )
}


/**
 * The children who are on no class list.
 *
 * They are active students with no active enrolment in the current session, and
 * that state makes them invisible almost everywhere: no challan, no attendance
 * register, no result card, not in the dashboard count, not in the plan count,
 * and not in the reconciliation screen's list of children who are not being
 * billed, because that list also walks enrolments.
 *
 * On this screen they were visible, but only as a row with an empty Class cell,
 * which reads as a formatting gap rather than as a child about to be forgotten
 * for a term. The usual cause is a rollover that did not carry everybody across.
 *
 * The panel renders nothing at all when there are none, which is the normal
 * case: a standing empty box teaches people to stop reading the top of the page.
 */
function NotInAClass({
  open, onOpenChange, onOpen,
}: {
  open: boolean
  onOpenChange: (v: boolean) => void
  onOpen: (studentId: string) => void
}) {
  const q = useQuery({ queryKey: ['studentsWithoutAClass'], queryFn: listStudentsWithoutAClass })
  const rows = q.data ?? []
  // Silent on failure. A database that predates 0099 has no such function, and
  // an error banner at the top of the roster about a migration would be worse
  // than the omission it is reporting.
  if (q.isError || rows.length === 0) return null

  return (
    <div className="mt-4 rounded-xl border border-due-200 bg-due-50 p-4">
      <button
        onClick={() => onOpenChange(!open)}
        className="flex w-full items-center justify-between gap-3 text-left"
      >
        <span className="text-sm font-medium text-due-900">
          {rows.length} student{rows.length === 1 ? ' is' : 's are'} not on any class list
        </span>
        <span className="shrink-0 text-xs font-medium text-due-700 underline">
          {open ? 'Hide' : 'Show who'}
        </span>
      </button>
      <p className="mt-1 text-xs text-due-800">
        They get no challan, no attendance register and no result card until they are enrolled in a
        class for this session.
      </p>
      {open && (
        <div className="mt-3 overflow-x-auto rounded-lg border border-due-200 bg-white">
          <table className="w-full min-w-[32rem] text-sm">
            <thead className="bg-slate-50 text-left text-xs uppercase tracking-wide text-slate-500">
              <tr>
                <th className="px-3 py-2 font-medium">Student</th>
                <th className="px-3 py-2 font-medium">Father</th>
                <th className="px-3 py-2 font-medium">Admitted</th>
                <th className="px-3 py-2 font-medium">Last seen in</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-slate-100">
              {rows.map((r) => (
                <tr
                  key={r.student_id}
                  onClick={() => onOpen(r.student_id)}
                  className="cursor-pointer hover:bg-slate-50"
                >
                  <td className="px-3 py-2 text-slate-800">
                    {r.full_name}
                    {r.gr_no && <span className="ml-1 text-xs text-slate-400">GR {r.gr_no}</span>}
                  </td>
                  <td className="px-3 py-2 text-slate-600">{r.father_name || '-'}</td>
                  <td className="whitespace-nowrap px-3 py-2 text-slate-500">
                    {r.admission_date ? fmtDate(r.admission_date) : '-'}
                  </td>
                  <td className="px-3 py-2 text-slate-500">
                    {/* Which tells the office what happened: no previous class at
                        all is a new admission that was never enrolled; a class in
                        last year's session is a child the rollover left behind. */}
                    {r.last_class
                      ? `${r.last_class}${r.last_session ? ` · ${r.last_session}` : ''}`
                      : 'Never enrolled'}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </div>
  )
}

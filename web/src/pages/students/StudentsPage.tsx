/**
 * The roster.
 *
 * What this replaced: a <ul> of buttons showing name, father's name and GR
 * number, capped at fifty rows with no count and no notice. An 800-student
 * school saw the first fifty names alphabetically and was never told the other
 * 750 existed — silent truncation on the flagship list of the product. No
 * class, no section, no roll number, and no balance, on a product whose entire
 * purpose is students and money.
 *
 * Now: a real table with class, section, roll and balance; filters by class and
 * section; paging that reports the true total; sortable columns; CSV; and an
 * explicit "include struck-off" switch, because a struck-off child still owes
 * money and still has to be findable.
 */
import { useState } from 'react'
import { useQuery } from '@tanstack/react-query'
import { listStudentPage, listClasses, listSections, type StudentListRow } from '@/lib/db'
import { DataTable, type Column } from '@/components/DataTable'
import { fmtPKR } from '@/lib/format'
import { StudentProfile } from './StudentProfile'

const SELECT =
  'rounded border border-slate-300 px-2 py-2 text-sm focus:border-brand-500 focus:outline-none'

export function StudentsPage() {
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
      render: (r) => <span className="text-slate-500">{r.roll_no ?? '—'}</span>,
    },
    {
      key: 'full_name',
      header: 'Student',
      sortable: true,
      value: (r) => r.full_name,
      render: (r) => (
        <div>
          <div className="font-medium text-slate-800">{r.full_name}</div>
          <div className="text-xs text-slate-400">
            {r.gr_no ?? '—'}
            {r.status !== 'active' ? ` · ${r.status.replace('_', ' ')}` : ''}
          </div>
        </div>
      ),
    },
    {
      key: 'father_name',
      header: 'Father',
      sortable: true,
      value: (r) => r.father_name,
      render: (r) => <span className="text-slate-600">{r.father_name ?? '—'}</span>,
    },
    {
      key: 'class_name',
      header: 'Class',
      sortable: true,
      value: (r) => `${r.class_name ?? ''}${r.section_name ?? ''}`,
      render: (r) => (
        <span className="whitespace-nowrap text-slate-600">
          {r.class_name ?? '—'}
          {r.section_name ? `-${r.section_name}` : ''}
        </span>
      ),
    },
    {
      key: 'phone',
      header: 'Phone',
      secondary: true,
      value: (r) => r.phone,
      render: (r) => <span className="text-slate-500">{r.phone ?? '—'}</span>,
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
          <span className="text-slate-400">—</span>
        ),
    },
  ]

  return (
    <div>
      <h1 className="text-xl font-semibold text-slate-800">Students</h1>
      <p className="mt-1 text-sm text-slate-500">
        The whole roster. Search by name, GR number, admission number or father&rsquo;s name.
      </p>

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

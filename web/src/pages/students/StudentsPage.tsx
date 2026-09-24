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
import { useState, type ReactNode } from 'react'
import { Link, useSearchParams } from 'react-router-dom'
import { useQuery } from '@tanstack/react-query'
import {
  listStudentPage, listClasses, listSections, listDraftStudentIds,
  listStudentsWithoutAClass, getDashboardSummary, getDraftStudents, getCurrentSession,
  type StudentListRow,
} from '@/lib/db'
import { RapidEntry } from './RapidEntry'
import { Badge, Button, PageHeader } from '@/components/ui'
import { IconAdmissions, IconAlert, IconStudents, IconWallet, IconChevron } from '@/components/icons'
import { useAuth } from '@/auth/AuthProvider'
import { canWrite } from '@/auth/roles'
import { canAccess } from '@/navigation'
import { diagnoseNoClass } from '@/lib/noClass'
import { useStudentFaces } from '@/hooks/useStudentFaces'
import { fmtDate } from '@/lib/format'
import { DataTable, type Column } from '@/components/DataTable'
import { fmtPKR } from '@/lib/format'
import { StudentProfile } from './StudentProfile'
import { Avatar } from '@/components/Avatar'

const SELECT =
  'rounded border border-slate-300 px-2 py-2 text-sm focus:border-brand-500 focus:outline-none'

export function StudentsPage() {
  // The dashboard links here with ?no_class=1 when it has counted children who
  // are on no class list. Read from the URL rather than kept in state so the
  // link works from anywhere, including a bookmark or a message to a colleague.
  const [params, setParams] = useSearchParams()
  const { profile } = useAuth()
  const role = profile?.role
  const writer = canWrite(role)
  const [term, setTerm] = useState('')
  const [classId, setClassId] = useState('')
  const [sectionId, setSectionId] = useState('')
  const [includeInactive, setIncludeInactive] = useState(false)
  const [page, setPage] = useState(0)
  const [pageSize, setPageSize] = useState(50)
  /* ?student=<id> OPENS THAT CHILD DIRECTLY, which is what makes the counter and
     this page one feature rather than two.
     A clerk at Fees → Collect now sees the concession on the family sheet, and
     the next thing they want is the statement behind it: the month-by-month
     list, the discount's history, the End it button. All of that lives here.
     Without a deep link the route from one to the other is Students, type the
     name again, hope you pick the same child.
     Read straight out of the URL rather than copied into state, for the reason
     the no_class link above is: it then works from a bookmark, from a message to
     a colleague and from the browser's back button. */
  /* ?add=quick and ?add=bulk open rapid entry. In the URL rather than in state
     for the same reason the selected student is: the dashboard's "finish these
     records" notice and the empty-roster button both link straight into it. */
  const addMode = params.get('add')
  function setAddMode(m: 'quick' | 'bulk' | null) {
    const next = new URLSearchParams(params)
    if (m) next.set('add', m); else next.delete('add')
    next.delete('student')
    setParams(next, { replace: !m })
  }

  const selectedId = params.get('student')
  const setSelectedId = (id: string | null) => {
    const next = new URLSearchParams(params)
    if (id) next.set('student', id)
    else next.delete('student')
    setParams(next, { replace: !id })
  }

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

  // Faces for the fifty rows on screen, in two requests regardless of page size.
  // Lives in a hook now because the cash counter needed the same thing and had
  // no face at all, which is the screen where picking the wrong Muhammad Ali
  // moves money between two families.
  const faces = useStudentFaces((q.data?.rows ?? []).map((r) => r.student_id))
  /* Which rows are short of something. Read as a set of ids rather than as a
     column on fn_student_list, because widening that function's return type
     would stop a frozen bundle from ever being re-applied. */
  const drafts = useQuery({ queryKey: ['draftStudents'], queryFn: listDraftStudentIds })
  /* The strip above the table. The same reads the dashboard makes, under the
     same keys, so the two screens show one set of numbers and a visit to one
     warms the other. Each tile hides itself when its read fails: the table
     below reports a failure loudly, and four more copies would be noise. */
  const summary = useQuery({ queryKey: ['dashboardSummary'], queryFn: getDashboardSummary })
  const noClass = useQuery({ queryKey: ['studentsWithoutAClass'], queryFn: listStudentsWithoutAClass })
  const draftList = useQuery({ queryKey: ['draftStudents', 'list'], queryFn: () => getDraftStudents(50) })
  function togglePanel(key: 'no_class' | 'drafts', v: boolean) {
    const next = new URLSearchParams(params)
    if (v) next.set(key, '1'); else next.delete(key)
    setParams(next, { replace: true })
  }

  if (addMode === 'quick' || addMode === 'bulk') {
    return (
      <RapidEntry
        mode={addMode}
        onMode={setAddMode}
        onDone={() => setAddMode(null)}
      />
    )
  }

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
            <div className="flex flex-wrap items-center gap-1.5">
              <span className="font-medium text-slate-800">{r.full_name}</span>
              {/* A REMINDER, NOT A STATE. This child is on the register, on the
                  challan run and in the exam hall exactly like the others. The
                  chip says the office still owes them a father's name or a date
                  of birth, nothing more. */}
              {drafts.data?.has(r.student_id) && <Badge tone="due">draft</Badge>}
            </div>
            <div className="flex flex-wrap items-center gap-x-1.5 text-xs text-slate-400">
              <span className="whitespace-nowrap">GR {r.gr_no ?? '-'}</span>
              {r.status !== 'active' && <Badge tone="neutral">{r.status.replace('_', ' ')}</Badge>}
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
      render: (r) => <ClassPill row={r} />,
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
      render: (r) => <OwesPill balance={r.balance} />,
    },
  ]

  return (
    <div>
      <PageHeader
        icon={<IconStudents />}
        title="Students"
        subtitle="The whole roster. Search by name, GR number, admission number or father’s name."
        actions={
          writer ? (
            <>
              {canAccess('/admissions', role) && (
                <Link
                  to="/admissions"
                  className="inline-flex items-center gap-1.5 rounded-lg bg-white px-3.5 py-2 text-sm font-medium text-slate-700 shadow-card ring-1 ring-slate-200 transition hover:bg-slate-50"
                >
                  <IconAdmissions /> Admit one
                </Link>
              )}
              {/* THE FIRST THING A NEW SCHOOL NEEDS. The roster of a school that
                  signed up this morning is empty, and the only two ways in were an
                  admission form that takes minutes a child and a CSV importer
                  buried in Settings. */}
              <Button onClick={() => setAddMode('bulk')} icon={<IconStudents />}>
                Add students
              </Button>
            </>
          ) : undefined
        }
      />

      <RosterStrip
        onRoll={summary.data?.active_students ?? null}
        admittedThisMonth={summary.data?.new_admissions_month ?? null}
        owing={summary.data?.finance_visible
          ? { count: summary.data.defaulters ?? 0, amount: summary.data.outstanding ?? 0 }
          : null}
        owingLink={canAccess('/reports', role) ? '/reports?tab=defaulters' : null}
        noClass={noClass.isSuccess ? noClass.data.length : null}
        drafts={draftList.isSuccess ? draftList.data.count : null}
        noClassOpen={params.get('no_class') === '1'}
        draftsOpen={params.get('drafts') === '1'}
        onNoClass={() => togglePanel('no_class', params.get('no_class') !== '1')}
        onDrafts={() => togglePanel('drafts', params.get('drafts') !== '1')}
      />

      <NotInAClass
        open={params.get('no_class') === '1'}
        onOpenChange={(v) => togglePanel('no_class', v)}
        onOpen={setSelectedId}
        canSettings={canAccess('/settings', role)}
      />

      <NeedsFinishing
        open={params.get('drafts') === '1'}
        onOpenChange={(v) => togglePanel('drafts', v)}
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
          mobileCard={(r) => (
            <div className="flex items-center gap-3">
              <Avatar name={r.full_name} url={faces.data?.get(r.student_id) ?? null} size="md" />
              <div className="min-w-0 flex-1">
                <div className="flex items-center gap-1.5">
                  <span className="truncate text-sm font-medium text-slate-800">{r.full_name}</span>
                  {drafts.data?.has(r.student_id) && <Badge tone="due">draft</Badge>}
                </div>
                <div className="truncate text-xs text-slate-500">
                  {r.father_name ?? 'No father’s name'}
                </div>
                <div className="mt-1 flex flex-wrap items-center gap-1.5 text-xs text-slate-400">
                  <ClassPill row={r} />
                  <span className="whitespace-nowrap">GR {r.gr_no ?? '-'}{r.roll_no ? ` · Roll ${r.roll_no}` : ''}</span>
                  {r.status !== 'active' && <Badge tone="neutral">{r.status.replace('_', ' ')}</Badge>}
                </div>
              </div>
              <div className="shrink-0 text-right">
                <OwesPill balance={r.balance} />
              </div>
            </div>
          )}
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
function ClassPill({ row }: { row: StudentListRow }) {
  return row.class_name ? (
    <span className="whitespace-nowrap rounded-md bg-slate-100 px-2 py-0.5 text-xs font-medium text-slate-700">
      {row.class_name}
      {row.section_name ? ` · ${row.section_name}` : ''}
    </span>
  ) : (
    // An empty class is a child on no class list, not a formatting gap.
    <span className="whitespace-nowrap rounded-md bg-due-50 px-2 py-0.5 text-xs font-medium text-due-800 ring-1 ring-due-200">
      No class
    </span>
  )
}

/* Amber, not red. components/ui.tsx keeps red for OVERDUE and amber for owed,
   and this column cannot tell the two apart: a balance on the 3rd of the
   month is mostly fees not yet due. Painting every one of them red is how a
   principal learns to ignore red. */
function OwesPill({ balance }: { balance: number }) {
  if (balance > 0) {
    return (
      <span className="whitespace-nowrap rounded-full bg-due-50 px-2.5 py-0.5 text-xs font-semibold text-due-800 ring-1 ring-due-200">
        {fmtPKR(balance)}
      </span>
    )
  }
  if (balance < 0) {
    // Negative means the family is in credit, which is not the same as "clear"
    // and must not be shown as a debt.
    return (
      <span className="whitespace-nowrap rounded-full bg-info-50 px-2.5 py-0.5 text-xs font-medium text-info-800 ring-1 ring-info-200">
        {fmtPKR(-balance)} advance
      </span>
    )
  }
  return <span className="text-slate-400">-</span>
}

function NotInAClass({
  open, onOpenChange, onOpen, canSettings,
}: {
  open: boolean
  onOpenChange: (v: boolean) => void
  onOpen: (studentId: string) => void
  canSettings: boolean
}) {
  const q = useQuery({ queryKey: ['studentsWithoutAClass'], queryFn: listStudentsWithoutAClass })
  const session = useQuery({ queryKey: ['currentSession'], queryFn: getCurrentSession })
  const rows = q.data ?? []
  // Silent on failure. A database that predates 0099 has no such function, and
  // an error banner at the top of the roster about a migration would be worse
  // than the omission it is reporting.
  if (q.isError || rows.length === 0) return null
  const dx = diagnoseNoClass(rows, session.data?.name ?? null)
  // The same test the dashboard uses: most of them were in a class last session.
  const rollover = dx.leftBehind > 0 && dx.leftBehind >= dx.total / 2
  // The tile above already counts them. The panel stands on its own only when
  // it has something to DO about it (a skipped rollover), or when asked for.
  if (!open && !rollover) return null

  return (
    <div className="mt-4 rounded-2xl border border-due-200 bg-due-50/70 p-4">
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div className="min-w-0">
          <p className="text-sm font-semibold text-due-900">
            {rows.length} student{rows.length === 1 ? ' is' : 's are'} not on any class list
          </p>
          <p className="mt-0.5 max-w-[80ch] text-sm text-due-800">
            {rollover ? (
              <>
                {dx.leftBehind === dx.total ? 'All of them were' : `${dx.leftBehind} of them were`} last in a class
                in {dx.fromSession ?? 'an earlier session'} and were not carried into{' '}
                {session.data?.name ?? 'this session'}. Year Rollover moves them all in one step, promoting each
                class, and shows a preview before it changes anything.
                {!canSettings && ' Ask the owner or principal: it is under Settings.'}
              </>
            ) : (
              <>
                They get no challan, no attendance register and no result card until they are enrolled in a
                class for this session. Open each child to put them in their class.
              </>
            )}
          </p>
        </div>
        <div className="flex shrink-0 flex-wrap gap-2">
          {rollover && canSettings && (
            <Link
              to="/settings?tab=rollover"
              className="inline-flex items-center gap-1 rounded-lg bg-due-600 px-3 py-1.5 text-sm font-medium text-white shadow-card hover:bg-due-700"
            >
              Open Year Rollover <IconChevron className="h-4 w-4" />
            </Link>
          )}
          <button
            onClick={() => onOpenChange(!open)}
            className="rounded-lg bg-white px-3 py-1.5 text-sm font-medium text-due-800 ring-1 ring-due-200 hover:bg-due-100"
          >
            {open ? 'Hide the list' : 'Show who'}
          </button>
        </div>
      </div>
      {open && (
        <div className="mt-3 overflow-x-auto rounded-xl border border-due-200 bg-white">
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

/**
 * The records Rapid Entry left short of something, each with what it lacks.
 *
 * The dashboard counts them; this is where somebody sits down and finishes
 * them. "Zainab Aslam: date of birth, a phone number" is a task, and a list of
 * those is an afternoon's work with the register open. Nothing is gated on it:
 * these children are billed, marked and examined like everybody else.
 */
function NeedsFinishing({
  open, onOpenChange, onOpen,
}: {
  open: boolean
  onOpenChange: (v: boolean) => void
  onOpen: (studentId: string) => void
}) {
  const q = useQuery({ queryKey: ['draftStudents', 'list'], queryFn: () => getDraftStudents(50) })
  // Silent on failure, like the panel above: the draft chip on each row still
  // says which records are short.
  if (q.isError || !q.data || q.data.count === 0 || !open) return null
  const d = q.data
  return (
    <div className="mt-4 rounded-2xl border border-slate-200 bg-white p-4 shadow-card">
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div>
          <p className="text-sm font-semibold text-slate-900">
            {d.count} record{d.count === 1 ? '' : 's'} to finish
          </p>
          <p className="mt-0.5 text-sm text-slate-500">
            Open each one and fill in what it lacks. They are billed and marked like everybody else in the
            meantime.
          </p>
        </div>
        <button
          onClick={() => onOpenChange(false)}
          className="rounded-lg px-3 py-1.5 text-sm font-medium text-slate-600 ring-1 ring-slate-200 hover:bg-slate-50"
        >
          Hide
        </button>
      </div>
      <ul className="mt-3 divide-y divide-slate-100 rounded-xl ring-1 ring-slate-200">
        {d.students.map((r) => (
          <li key={r.student_id}>
            <button
              onClick={() => onOpen(r.student_id)}
              className="flex w-full flex-wrap items-center gap-x-3 gap-y-1 px-3 py-2.5 text-left hover:bg-slate-50"
            >
              <span className="min-w-[10rem] flex-1 text-sm font-medium text-slate-800">
                {r.full_name}
                <span className="ml-2 text-xs font-normal text-slate-400">
                  {[r.class_name, r.section_name].filter(Boolean).join(' · ') || 'No class'}
                </span>
              </span>
              <span className="flex flex-wrap gap-1.5">
                {r.missing.map((m) => (
                  <span key={m} className="rounded-full bg-due-50 px-2 py-0.5 text-xs text-due-800 ring-1 ring-due-200">
                    no {m}
                  </span>
                ))}
              </span>
            </button>
          </li>
        ))}
      </ul>
      {d.count > d.students.length && (
        <p className="mt-2 text-xs text-slate-500">
          Showing the first {d.students.length} of {d.count}, by name. Finished ones drop off the list.
        </p>
      )}
    </div>
  )
}

/**
 * Four numbers above the roster, each one a way into the list behind it. The
 * old page opened on a bare table, so "how many do we have, who owes, who is
 * missing" meant three other screens.
 */
function RosterStrip({
  onRoll, admittedThisMonth, owing, owingLink, noClass, drafts,
  noClassOpen, draftsOpen, onNoClass, onDrafts,
}: {
  onRoll: number | null
  admittedThisMonth: number | null
  owing: { count: number; amount: number } | null
  owingLink: string | null
  noClass: number | null
  drafts: number | null
  noClassOpen: boolean
  draftsOpen: boolean
  onNoClass: () => void
  onDrafts: () => void
}) {
  return (
    <div className="grid grid-cols-2 gap-3 lg:grid-cols-4">
      <StripTile
        icon={<IconStudents />} tone="brand" label="On the roll"
        value={onRoll == null ? '-' : onRoll.toLocaleString('en-PK')}
        sub={admittedThisMonth != null ? `${admittedThisMonth} admitted this month` : undefined}
      />
      {owing && (
        <StripTile
          icon={<IconWallet />} tone={owing.count > 0 ? 'due' : 'money'} label="Owe fees"
          value={owing.count.toLocaleString('en-PK')}
          sub={owing.count > 0 ? `${fmtPKR(owing.amount)} between them` : 'Nobody owes anything'}
          to={owing.count > 0 ? owingLink ?? undefined : undefined}
          cta={owing.count > 0 && owingLink ? 'Defaulters list' : undefined}
        />
      )}
      <StripTile
        icon={<IconAlert />} tone={noClass ? 'due' : 'neutral'} label="Not in a class"
        value={noClass == null ? '-' : String(noClass)}
        sub={noClass ? 'No challan, no register' : 'Everyone is on a list'}
        onClick={noClass ? onNoClass : undefined}
        pressed={noClassOpen}
        cta={noClass ? (noClassOpen ? 'Hide who' : 'Show who') : undefined}
      />
      <StripTile
        icon={<IconAdmissions />} tone={drafts ? 'due' : 'neutral'} label="Records to finish"
        value={drafts == null ? '-' : String(drafts)}
        sub={drafts ? 'Missing a birth date, a phone…' : 'Every record is complete'}
        onClick={drafts ? onDrafts : undefined}
        pressed={draftsOpen}
        cta={drafts ? (draftsOpen ? 'Hide them' : 'Show them') : undefined}
      />
    </div>
  )
}

const STRIP_TONE = {
  brand: 'bg-brand-50 text-brand-600 ring-brand-100',
  due: 'bg-due-50 text-due-600 ring-due-100',
  money: 'bg-money-50 text-money-600 ring-money-100',
  neutral: 'bg-slate-100 text-slate-500 ring-slate-200',
} as const

function StripTile({
  icon, tone, label, value, sub, to, onClick, pressed, cta,
}: {
  icon: ReactNode
  tone: keyof typeof STRIP_TONE
  label: string
  value: string
  sub?: string
  to?: string
  onClick?: () => void
  pressed?: boolean
  cta?: string
}) {
  const body = (
    <>
      <div className="flex items-center gap-2">
        <span className={`flex h-8 w-8 shrink-0 items-center justify-center rounded-lg ring-1 ${STRIP_TONE[tone]}`}>{icon}</span>
        <span className="text-xs font-medium uppercase tracking-wide text-slate-500">{label}</span>
      </div>
      <div className="mt-2 text-2xl font-semibold text-slate-900">{value}</div>
      {sub && <div className="mt-0.5 text-xs leading-snug text-slate-500">{sub}</div>}
      {cta && <div className="mt-1.5 text-xs font-medium text-brand-700">{cta}</div>}
    </>
  )
  const cls = `block h-full rounded-2xl bg-white p-3.5 text-left shadow-card ring-1 transition sm:p-4 ${
    pressed ? 'ring-2 ring-brand-300' : 'ring-slate-200/80'
  }`
  const hover = ' hover:-translate-y-0.5 hover:shadow-raised focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-brand-400'
  if (to) return <Link to={to} className={cls + hover}>{body}</Link>
  if (onClick) {
    return <button type="button" onClick={onClick} aria-pressed={pressed} className={cls + hover}>{body}</button>
  }
  return <div className={cls}>{body}</div>
}

import { useMemo, useState } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import {
  getStaffRoster, createStaff, updateStaff, linkStaffProfile, listProfiles,
  staffLeave, staffRejoin, staffSetLoginActive,
  listClasses, listSectionTeachers, getCurrentSession, listTeacherAssignments, setClassTeacher,
  getSubjectTeachers, setSubjectTeachers, type SubjectTeacherRow,
  getStaffAttendanceSummary, getStaffMonthAttendance, createTeacherLogin,
  type StaffRow, type StaffInput, type StaffRosterRow, type StaffLeaveResult,
} from '@/lib/db'
import { ROLE_LABELS, ROLES, canWrite, type Role } from '@/auth/roles'
import { ObserverNotice } from '@/components/ObserverNotice'
import { ATTENDANCE_SHORT } from '@/lib/constants'
import { fmtDate, todayISO } from '@/lib/format'
import { useAuth } from '@/auth/AuthProvider'
import { useSchoolName } from '@/hooks/useSchoolName'
import { StaffIdCard } from './StaffIdCard'
import { StaffDayRegister } from './StaffDayRegister'
import { PhotoUpload } from '@/components/PhotoUpload'
import { Avatar } from '@/components/Avatar'
import { removeStaffPhoto, signPaths, uploadStaffPhoto } from '@/lib/photos'
import { LoadError } from '@/components/ui'
import { LoginFunctionWarning } from '@/components/LoginFunctionWarning'
import { DeleteRecord } from '@/components/DeleteRecord'
import { staffDeleteBlockers, deleteStaff } from '@/lib/db'
import { listSchoolLogins, loginDeleteBlockers, deleteLogin, type SchoolLogin } from '@/lib/db'

const FIELD = 'mt-1 w-full rounded border border-slate-300 px-3 py-2 text-sm focus:border-brand-500 focus:outline-none focus:ring-1 focus:ring-brand-500'
const TABS = [{ key: 'staff', label: 'Staff' }, { key: 'attendance', label: 'Attendance' },
              { key: 'teachers', label: 'Class Teachers' },
              // 0085. Who teaches WHAT — and it is not paperwork: until this
              // register existed, fn_enter_marks had no class scope at all, so
              // any teacher could rewrite any class's exam marks.
              { key: 'subjects', label: 'Subject Teachers' }] as const

function ymNow(): string { return todayISO().slice(0, 7) }
function monthLabel(y: string): string {
  const [yy, mm] = y.split('-').map(Number)
  return new Date(yy, mm - 1, 1).toLocaleDateString('en-PK', { month: 'long', year: 'numeric' })
}
function lastSixMonths(): string[] {
  const [y, m] = ymNow().split('-').map(Number)
  const out: string[] = []
  let yy = y, mm = m
  for (let i = 0; i < 6; i++) { out.push(`${yy}-${String(mm).padStart(2, '0')}`); mm--; if (mm < 1) { mm = 12; yy-- } }
  return out
}

export function StaffPage() {
  const [tab, setTab] = useState<'staff' | 'attendance' | 'teachers' | 'subjects'>('staff')
  return (
    <div>
      <h1 className="text-xl font-semibold text-slate-800">Staff</h1>
      <div className="mt-4 flex gap-1 border-b border-slate-200">
        {TABS.map((t) => (
          <button key={t.key} onClick={() => setTab(t.key)}
            className={`-mb-px border-b-2 px-4 py-2 text-sm ${tab === t.key ? 'border-brand-600 font-medium text-brand-700' : 'border-transparent text-slate-500 hover:text-slate-700'}`}>
            {t.label}
          </button>
        ))}
      </div>
      <div className="mt-5">
        {tab === 'staff' ? <StaffTab />
          : tab === 'attendance' ? <StaffDayRegister />
          : tab === 'teachers' ? <ClassTeachersTab />
          : <SubjectTeachersTab />}
      </div>
    </div>
  )
}

const BLANK: StaffInput = { full_name: '', designation: '', employee_no: '', mobile: '', whatsapp: '', cnic: '', joined_on: '', dob: '' }

function StaffTab() {
  const qc = useQueryClient()
  const { profile } = useAuth()
  // An observer reads the roster and changes nothing on it. canLink is ANDed
  // with mayWrite so a future edit to that list cannot hand an observer the
  // login dropdown.
  const mayWrite = canWrite(profile?.role)
  const canLink = mayWrite && !!profile && ['owner', 'principal'].includes(profile.role)
  const staff = useQuery({ queryKey: ['staff'], queryFn: getStaffRoster })
  const profiles = useQuery({ queryKey: ['profiles'], queryFn: listProfiles })
  // The same query UnattachedLogins uses, shared by key. It carries the email
  // address, which listProfiles cannot: profiles has no email column, so until
  // 0095 no screen in this app could say which address a login belonged to.
  // Two staff both called Muhammad Ali appeared in the dropdown below as
  // "Muhammad Ali" twice, and picking the wrong one gives the wrong person
  // access to the wrong class.
  const schoolLogins = useQuery({
    queryKey: ['schoolLogins'], queryFn: listSchoolLogins, enabled: canLink, retry: false,
  })
  const emailOf = (id: string | null) =>
    id ? (schoolLogins.data ?? []).find((l) => l.profile_id === id)?.email ?? null : null
  const [editing, setEditing] = useState<string | null>(null) // staff id, or 'new'
  const [form, setForm] = useState<StaffInput>(BLANK)
  const [idCard, setIdCard] = useState<StaffRow | null>(null)
  const [attFor, setAttFor] = useState<StaffRow | null>(null)
  const [adding, setAdding] = useState(false)
  const [leaving, setLeaving] = useState<StaffRosterRow | null>(null)
  const [removing, setRemoving] = useState<StaffRow | null>(null)
  const [flash, setFlash] = useState<string | null>(null)

  const invalidate = () => {
    qc.invalidateQueries({ queryKey: ['staff'] })
    // The Class Teachers tab and every result card read sections.class_teacher_id,
    // which a leaving vacates.
    qc.invalidateQueries({ queryKey: ['sectionTeachers'] })
    qc.invalidateQueries({ queryKey: ['teacherAssignments'] })
  }
  const save = useMutation({
    mutationFn: async () => {
      const payload = { ...form, full_name: form.full_name.trim() }
      if (editing === 'new') await createStaff(payload)
      else await updateStaff(editing!, payload)
    },
    onSuccess: () => { setEditing(null); setForm(BLANK); invalidate() },
  })
  const rejoin = useMutation({
    mutationFn: (v: { id: string; reason: string | null }) => staffRejoin(v.id, v.reason),
    onSuccess: (r) => {
      setFlash(
        `${r.staff_name} is back on the staff list.` +
        (r.login_restored ? ' Their login works again.' : '') +
        ' They are not class teacher of anything — assign that on the Class Teachers tab.',
      )
      invalidate()
    },
  })
  // The access switch on its own: suspension without saying somebody left, and
  // the fix for anyone the OLD Deactivate button left able to log in.
  const login = useMutation({
    mutationFn: (v: { id: string; active: boolean; reason: string | null }) =>
      staffSetLoginActive(v.id, v.active, v.reason),
    onSuccess: (r) => {
      setFlash(r.changed
        ? `${r.staff_name}'s login is now ${r.login_active ? 'open' : 'closed'}.`
        : `${r.staff_name}'s login was already ${r.login_active ? 'open' : 'closed'}.`)
      invalidate()
    },
  })
  const link = useMutation({
    mutationFn: (v: { id: string; profileId: string | null }) => linkStaffProfile(v.id, v.profileId),
    onSuccess: () => { invalidate(); qc.invalidateQueries({ queryKey: ['profiles'] }) },
  })

  /**
   * One signing request for the whole roster.
   *
   * Keyed on the sorted list of paths, so it re-signs when a photograph is added
   * or removed and not on every render. `signPaths` returns an empty map rather
   * than throwing, so a storage outage costs the faces and not the page.
   */
  const photoPaths = (staff.data ?? []).map((s) => s.photo_path).filter(Boolean) as string[]
  const facesQ = useQuery({
    queryKey: ['staffFaces', [...photoPaths].sort().join('|')],
    queryFn: () => signPaths(photoPaths),
    enabled: photoPaths.length > 0,
    staleTime: 20 * 60 * 1000,
  })
  const faces = facesQ.data ?? new Map<string, string>()

  /** The row being edited, for the fields the form does not hold — currently the
   *  photograph path, which is written by an RPC rather than by the form save. */
  const editingRow = editing && editing !== 'new'
    ? staff.data?.find((r) => r.id === editing) ?? null
    : null

  function startEdit(s: StaffRow) {
    setEditing(s.id)
    setForm({ full_name: s.full_name, designation: s.designation ?? '', employee_no: s.employee_no ?? '', mobile: s.mobile ?? '', whatsapp: s.whatsapp ?? '', cnic: s.cnic ?? '', joined_on: s.joined_on ?? '', dob: s.dob ?? '' })
  }

  return (
    <div className="space-y-5">
      <LoadError of={[staff, profiles]} what="The staff list" />

      {!mayWrite && <ObserverNotice what="staff records" />}

      {/* ONE button, where there were two. "+ Add staff" wrote a staff row and
          "+ Add teacher login" wrote a profiles row, and the office was left to
          work out that a teacher needs both and then join them by hand. */}
      {!editing && !adding && mayWrite && (
        <div className="flex flex-wrap gap-2">
          <button onClick={() => setAdding(true)}
            className="rounded bg-brand-600 px-4 py-2 text-sm font-medium text-white hover:bg-brand-700">
            + Add someone
          </button>
        </div>
      )}

      {adding && mayWrite && (
        <AddPerson
          onDone={() => {
            setAdding(false)
            invalidate()
            qc.invalidateQueries({ queryKey: ['profiles'] })
            qc.invalidateQueries({ queryKey: ['schoolLogins'] })
          }}
          onFlash={setFlash}
        />
      )}

      <UnattachedLogins canLink={canLink} staff={staff.data ?? []} />

      {editing && (
        <form className="rounded-lg border border-slate-200 bg-white p-4" onSubmit={(e) => { e.preventDefault(); if (form.full_name.trim()) save.mutate() }}>
          <div className="text-xs font-semibold uppercase tracking-wide text-slate-500">{editing === 'new' ? 'New staff member' : 'Edit staff'}</div>

          {/* Only for a saved record: the photograph is stored under the staff
              id, so there is nowhere to put it until the row exists. Saying so
              beats a control that silently fails. */}
          {editing === 'new'
            ? (
              <p className="mt-2 text-xs text-slate-500">
                Save the staff member first, then reopen Edit to add their photograph.
              </p>
            )
            : (
              <div className="mt-3 border-b border-slate-100 pb-3">
                <PhotoUpload
                  name={form.full_name}
                  path={editingRow?.photo_path ?? null}
                  size="lg"
                  onUpload={(file) => uploadStaffPhoto(editing, file)}
                  onRemove={() => removeStaffPhoto(editing, editingRow?.photo_path ?? null)}
                  onChanged={invalidate}
                />
              </div>
            )}

          <div className="mt-2 grid gap-3 sm:grid-cols-3">
            <label className="block sm:col-span-2"><span className="text-sm text-slate-600">Full name</span>
              <input value={form.full_name} onChange={(e) => setForm((f) => ({ ...f, full_name: e.target.value }))} className={FIELD} /></label>
            <label className="block"><span className="text-sm text-slate-600">Designation</span>
              <input value={form.designation ?? ''} onChange={(e) => setForm((f) => ({ ...f, designation: e.target.value }))} className={FIELD} placeholder="e.g. Senior Teacher" /></label>
            <label className="block"><span className="text-sm text-slate-600">Employee #</span>
              <input value={form.employee_no ?? ''} onChange={(e) => setForm((f) => ({ ...f, employee_no: e.target.value }))} className={FIELD} /></label>
            <label className="block"><span className="text-sm text-slate-600">Mobile</span>
              <input value={form.mobile ?? ''} onChange={(e) => setForm((f) => ({ ...f, mobile: e.target.value }))} className={FIELD} /></label>
            <label className="block"><span className="text-sm text-slate-600">WhatsApp</span>
              <input value={form.whatsapp ?? ''} onChange={(e) => setForm((f) => ({ ...f, whatsapp: e.target.value }))} className={FIELD} /></label>
            <label className="block"><span className="text-sm text-slate-600">CNIC</span>
              <input value={form.cnic ?? ''} onChange={(e) => setForm((f) => ({ ...f, cnic: e.target.value }))} className={FIELD} /></label>
            <label className="block"><span className="text-sm text-slate-600">Joined on</span>
              <input type="date" value={form.joined_on ?? ''} onChange={(e) => setForm((f) => ({ ...f, joined_on: e.target.value }))} className={FIELD} /></label>
            <label className="block"><span className="text-sm text-slate-600">Date of birth</span>
              {/* Feeds the Birthdays screen. Without a field here the column
                  would be read-only and that screen permanently empty of staff. */}
              <input type="date" value={form.dob ?? ''} onChange={(e) => setForm((f) => ({ ...f, dob: e.target.value }))} className={FIELD} /></label>
          </div>
          {save.isError && <p className="mt-2 text-sm text-red-600">{(save.error as Error).message}</p>}
          <div className="mt-3 flex gap-2">
            <button type="submit" disabled={!form.full_name.trim() || save.isPending}
              className="rounded bg-brand-600 px-4 py-2 text-sm font-medium text-white hover:bg-brand-700 disabled:opacity-60">{save.isPending ? 'Saving…' : 'Save'}</button>
            <button type="button" onClick={() => { setEditing(null); setForm(BLANK) }} className="rounded border border-slate-300 px-4 py-2 text-sm hover:bg-slate-50">Cancel</button>
          </div>
        </form>
      )}

      {flash && (
        <div className="flex items-start justify-between gap-3 rounded-lg border border-money-200 bg-money-50 px-4 py-3 text-sm text-money-800">
          <span>{flash}</span>
          <button onClick={() => setFlash(null)} className="shrink-0 text-money-700 hover:underline">Dismiss</button>
        </div>
      )}

      {/* Anyone recorded as having left whose login still works. This is the one
          thing 0053 refuses to fix silently: it cannot tell "resigned in March"
          from "the old Deactivate button was clicked by mistake", and closing
          somebody's access from inside a migration is how a person who is still
          working gets locked out on a Monday morning. So the school is shown the
          list and decides. */}
      {(() => {
        const stranded = (staff.data ?? []).filter((s) => s.status !== 'active' && s.login_active === true)
        if (!stranded.length || !canLink) return null
        return (
          <div className="rounded-lg border border-danger-200 bg-danger-50 p-4 text-sm">
            <p className="font-medium text-danger-800">
              {stranded.length === 1 ? 'One person who has left can still log in' :
                `${stranded.length} people who have left can still log in`}
            </p>
            <p className="mt-1 text-danger-700">
              They can still open the app and read the children&rsquo;s records. Close each
              login unless they are in fact still working here.
            </p>
            <ul className="mt-2 space-y-1">
              {stranded.map((s) => (
                <li key={s.id} className="flex items-center justify-between gap-3">
                  <span className="text-danger-900">
                    {s.full_name}
                    {s.left_on ? <span className="text-danger-600"> · left {fmtDate(s.left_on)}</span> : null}
                  </span>
                  <button
                    onClick={() => login.mutate({ id: s.id, active: false, reason: 'Left the school' })}
                    className="shrink-0 rounded bg-danger-600 px-2 py-1 text-xs font-medium text-white hover:bg-danger-700">
                    Close login
                  </button>
                </li>
              ))}
            </ul>
          </div>
        )
      })()}

      <div className="overflow-x-auto rounded-lg border border-slate-200 bg-white">
        <table className="w-full text-sm">
          <thead className="bg-slate-50 text-left text-xs uppercase tracking-wide text-slate-500">
            <tr><th className="px-3 py-2">Name</th><th className="px-3 py-2">Designation</th><th className="px-3 py-2">Mobile</th><th className="px-3 py-2 w-56">Login</th><th className="px-3 py-2 w-52"></th></tr>
          </thead>
          <tbody className="divide-y divide-slate-100">
            {staff.isLoading && <tr><td colSpan={5} className="px-3 py-3 text-slate-500">Loading…</td></tr>}
            {staff.data?.length === 0 && <tr><td colSpan={5} className="px-3 py-3 text-slate-500">No staff yet.</td></tr>}
            {staff.data?.map((s) => {
              const logins = (profiles.data ?? []).filter((p) => !p.staff_id || p.id === s.profile_id)
              const here = s.status === 'active'
              return (
                <tr key={s.id} className={here ? '' : 'bg-slate-50/60'}>
                  <td className="px-3 py-2 font-medium text-slate-800">
                    <div className="flex items-center gap-2">
                      <Avatar name={s.full_name} url={faces.get(s.photo_path ?? '') ?? null} size="sm" />
                      <div className="min-w-0">
                        <span className={here ? '' : 'text-slate-500'}>{s.full_name}</span>
                        {s.employee_no && <span className="ml-1 text-xs text-slate-400">#{s.employee_no}</span>}
                        {!here && (
                          <span className="ml-2 rounded bg-slate-200 px-1.5 py-0.5 text-[11px] font-medium text-slate-600">
                            left{s.left_on ? ` ${fmtDate(s.left_on)}` : ''}
                          </span>
                        )}
                        {/* Named, not counted: "Class 1-A, Class 2-B" is what the
                            principal needs in order to reassign. */}
                        {here && s.class_teacher_of && (
                          <span className="ml-2 text-xs font-normal text-slate-500">
                            class teacher · {s.class_teacher_of}
                          </span>
                        )}
                      </div>
                    </div>
                  </td>
                  <td className="px-3 py-2 text-slate-600">{s.designation ?? '—'}</td>
                  <td className="px-3 py-2 text-slate-600">{s.mobile ?? '—'}</td>
                  <td className="px-3 py-2">
                    {canLink ? (
                      <select value={s.profile_id ?? ''} onChange={(e) => link.mutate({ id: s.id, profileId: e.target.value || null })}
                        className="w-full rounded border border-slate-300 px-2 py-1 text-sm focus:border-brand-500 focus:outline-none">
                        <option value="">— no login —</option>
                        {logins.map((p) => (
                          <option key={p.id} value={p.id}>
                            {p.full_name || '(unnamed)'}
                            {emailOf(p.id) ? ` · ${emailOf(p.id)}` : ''}
                            {' · '}{ROLE_LABELS[p.role as Role] ?? p.role}
                          </option>
                        ))}
                      </select>
                    ) : (
                      <span className="text-slate-500">{profiles.data?.find((p) => p.id === s.profile_id)?.full_name ?? '—'}</span>
                    )}
                    {/* null and false are different facts and the old screen
                        could see neither: it read the staff table, and this
                        lives in profiles. */}
                    {s.profile_id && emailOf(s.profile_id) && (
                      <div className="mt-0.5 truncate text-xs text-slate-500">
                        {emailOf(s.profile_id)}
                      </div>
                    )}
                    <LoginState row={s} canLink={canLink}
                      onOpen={() => login.mutate({ id: s.id, active: true, reason: null })}
                      onClose={() => login.mutate({ id: s.id, active: false, reason: null })} />
                  </td>
                  <td className="px-3 py-2 text-right">
                    {/* Edit is a write; Attendance and ID card are reads and an
                        observer keeps both. */}
                    {mayWrite && (
                      <button onClick={() => startEdit(s)} className="mr-2 text-sm text-brand-700 hover:underline">Edit</button>
                    )}
                    <button onClick={() => setAttFor(s)} className="mr-2 text-sm text-brand-700 hover:underline">Attendance</button>
                    <button onClick={() => setIdCard(s)} className="mr-2 text-sm text-brand-700 hover:underline">ID card</button>
                    {/* Two different actions people confuse. "Left the school"
                        is for somebody who really left and keeps every register
                        and payslip they touched. "Remove" is for a row typed in
                        by mistake, and it refuses the moment anything is
                        attached. */}
                    {canLink && (
                      <button onClick={() => setRemoving(s)}
                        className="mr-2 rounded border border-slate-300 px-2 py-1 text-xs font-medium text-slate-600 hover:bg-slate-50">
                        Remove
                      </button>
                    )}
                    {canLink && (here ? (
                      <button onClick={() => setLeaving(s)}
                        className="rounded border border-slate-300 px-2 py-1 text-xs font-medium text-slate-600 hover:bg-slate-50">
                        Left the school
                      </button>
                    ) : (
                      <button onClick={() => rejoin.mutate({ id: s.id, reason: null })}
                        disabled={rejoin.isPending}
                        className="rounded border border-slate-300 px-2 py-1 text-xs font-medium text-slate-600 hover:bg-slate-50 disabled:opacity-60">
                        Rejoined
                      </button>
                    ))}
                  </td>
                </tr>
              )
            })}
          </tbody>
        </table>
      </div>
      {link.isError && <p className="text-sm text-red-600">{(link.error as Error).message}</p>}
      {rejoin.isError && <p className="text-sm text-red-600">{(rejoin.error as Error).message}</p>}
      {login.isError && <p className="text-sm text-red-600">{(login.error as Error).message}</p>}
      {leaving && (
        <LeaveDialog
          row={leaving}
          onClose={() => setLeaving(null)}
          onDone={(r) => {
            setLeaving(null)
            setFlash(
              `${r.staff_name} recorded as having left on ${fmtDate(r.left_on)}.` +
              (r.login_revoked ? ' Their login is closed.'
                : r.had_login ? ' Their login was already closed.' : '') +
              (r.sections_count > 0
                ? ` ${r.sections_vacated} ${r.sections_count === 1 ? 'now has' : 'now have'} no class teacher — assign somebody on the Class Teachers tab.`
                : ''),
            )
            invalidate()
          }}
        />
      )}
      {removing && (
        <DeleteRecord
          kind="staff member"
          name={removing.full_name}
          blockers={() => staffDeleteBlockers(removing.id)}
          remove={() => deleteStaff(removing.id)}
          onDeleted={(r) => {
            setRemoving(null)
            setFlash(`${r.name} has been removed from the staff list.`)
            invalidate()
            qc.invalidateQueries({ queryKey: ['profiles'] })
          }}
          onCancel={() => setRemoving(null)}
          archive={{
            label: 'Record them as having left instead',
            explain: 'Their attendance and everything they entered stays exactly as it '
                   + 'is, their login closes, and any class they run is freed for '
                   + 'somebody else.',
            run: () => { const r = removing; setRemoving(null); setLeaving(r as StaffRosterRow) },
          }}
        />
      )}
      {idCard && <StaffIdCard staff={idCard} onClose={() => setIdCard(null)} />}
      {attFor && <StaffAttendanceModal staff={attFor} onClose={() => setAttFor(null)} />}
    </div>
  )
}

/** Whether this person can actually get into the app.
 *
 *  Three states, not two. The old screen showed none of them, which is how a
 *  resigned teacher kept working access: "Deactivate" wrote staff.status and
 *  every access check reads profiles.active. */
function LoginState({ row, canLink, onOpen, onClose }: {
  row: StaffRosterRow; canLink: boolean; onOpen: () => void; onClose: () => void
}) {
  if (row.login_active === null) {
    return <p className="mt-1 text-xs text-slate-400">No account — cannot sign in.</p>
  }
  if (row.login_active) {
    return (
      <p className="mt-1 text-xs text-money-700">
        Can sign in{row.login_role ? ` as ${ROLE_LABELS[row.login_role as Role] ?? row.login_role}` : ''}.
        {canLink && row.status === 'active' && (
          <button onClick={onClose} className="ml-1 text-slate-500 hover:underline">Suspend</button>
        )}
      </p>
    )
  }
  return (
    <p className="mt-1 text-xs text-slate-500">
      Login closed.
      {/* Reopening is offered only for somebody who is still on the staff —
          reopening a departed person's login would leave the two facts
          contradicting each other, and SQL refuses it anyway. */}
      {canLink && row.status === 'active' && (
        <button onClick={onOpen} className="ml-1 text-brand-700 hover:underline">Reopen</button>
      )}
    </p>
  )
}

/** Recording a leaving, with what it is about to do stated before it happens. */
function LeaveDialog({ row, onClose, onDone }: {
  row: StaffRosterRow; onClose: () => void; onDone: (r: StaffLeaveResult) => void
}) {
  const [leftOn, setLeftOn] = useState(todayISO())
  const [reason, setReason] = useState('')
  const go = useMutation({
    mutationFn: () => staffLeave(row.id, leftOn, reason.trim() || null),
    onSuccess: onDone,
  })

  return (
    <div className="fixed inset-0 z-50 flex items-start justify-center overflow-y-auto bg-black/40 p-4">
      <div className="mt-16 w-full max-w-md rounded-lg bg-white p-5 shadow-xl">
        <h2 className="text-base font-semibold text-slate-800">{row.full_name} has left</h2>

        <label className="mt-4 block"><span className="text-sm text-slate-600">Last working day</span>
          {/* Capped at today because the login closes on save, not on the date.
              A future date would put a lie in the record: employed on a day the
              system had already locked them out. */}
          <input type="date" value={leftOn} max={todayISO()} min={row.joined_on ?? undefined}
            onChange={(e) => setLeftOn(e.target.value)} className={FIELD} />
        </label>
        <label className="mt-3 block"><span className="text-sm text-slate-600">Reason (optional)</span>
          <input value={reason} onChange={(e) => setReason(e.target.value)} className={FIELD}
            placeholder="e.g. Resigned — moved to Lahore" />
        </label>

        <div className="mt-4 rounded-lg bg-slate-50 p-3 text-xs text-slate-600">
          <p className="font-medium text-slate-700">Saving this will:</p>
          <ul className="mt-1 space-y-1">
            <li>
              {row.login_active === true
                ? '• close their login straight away — they will not be able to sign in'
                : row.login_active === false
                  ? '• leave their login closed (it already is)'
                  : '• change no login, because they do not have one'}
            </li>
            {row.class_teacher_of
              ? <li>• leave <b>{row.class_teacher_of}</b> with no class teacher, so you will need to appoint somebody</li>
              : <li>• change no class-teacher assignment</li>}
            {row.assignments > 0 && (
              <li>• remove {row.assignments === 1 ? 'their teaching assignment' : `their ${row.assignments} teaching assignments`} for this session</li>
            )}
            <li>• keep every past record: attendance, marks entered, and who taught what in earlier sessions</li>
          </ul>
          <p className="mt-2 text-slate-500">
            It can be undone with &ldquo;Rejoined&rdquo;, which restores the login but not the
            class-teacher assignments.
          </p>
        </div>

        {go.isError && <p className="mt-3 text-sm text-red-600">{(go.error as Error).message}</p>}

        <div className="mt-4 flex justify-end gap-2">
          <button onClick={onClose} className="rounded border border-slate-300 px-4 py-2 text-sm hover:bg-slate-50">Cancel</button>
          <button onClick={() => go.mutate()} disabled={go.isPending || !leftOn}
            className="rounded bg-brand-600 px-4 py-2 text-sm font-medium text-white hover:bg-brand-700 disabled:opacity-60">
            {go.isPending ? 'Saving…' : 'Record leaving'}
          </button>
        </div>
      </div>
    </div>
  )
}

function StaffAttendanceModal({ staff, onClose }: { staff: StaffRow; onClose: () => void }) {
  const schoolName = useSchoolName()
  const months = useMemo(() => lastSixMonths(), [])
  const [month, setMonth] = useState(months[0])
  const first = `${month}-01`
  const [yy, mm] = month.split('-').map(Number)
  const last = `${month}-${String(new Date(yy, mm, 0).getDate()).padStart(2, '0')}`

  const summary = useQuery({ queryKey: ['staffAttSummary', staff.id, month], queryFn: () => getStaffAttendanceSummary(staff.id, first, last) })
  const days = useQuery({ queryKey: ['staffAttDays', staff.id, month], queryFn: () => getStaffMonthAttendance(staff.id, month) })
  const [printing, setPrinting] = useState(false)
  const d = summary.data

  return (
    <div className="fixed inset-0 z-50 flex items-start justify-center overflow-y-auto bg-black/40 p-4 print:static print:block print:bg-white print:p-0">
      <div className="mt-10 w-full max-w-lg rounded-lg bg-white p-6 shadow-lg print:mt-0 print:max-w-none print:shadow-none" id="report">
        <div className="text-center">
          <div className="text-lg font-semibold text-slate-800">{schoolName}</div>
          <div className="text-xs uppercase tracking-wide text-slate-500">Staff Attendance — {monthLabel(month)}</div>
        </div>
        <div className="mt-3 flex flex-wrap items-center justify-between gap-2">
          <div className="text-sm text-slate-700"><span className="text-slate-500">Staff:</span> {staff.full_name}{staff.designation ? ` · ${staff.designation}` : ''}</div>
          <select value={month} onChange={(e) => setMonth(e.target.value)} className="rounded border border-slate-300 px-2 py-1 text-sm print:hidden">
            {months.map((m) => <option key={m} value={m}>{monthLabel(m)}{m === ymNow() ? ' (current)' : ''}</option>)}
          </select>
        </div>

        <div className="mt-3 text-sm text-slate-700">
          {d?.present_pct == null ? '—' : `${d.present_pct}% present`} over {d?.marked_days ?? 0} marked days ·
          {' '}P {d?.present ?? 0} · A {d?.absent ?? 0} · L {d?.leave ?? 0} · Lt {d?.late ?? 0} · ½ {d?.half_day ?? 0}
        </div>

        <div className="mt-3">
          {days.isLoading ? <p className="text-sm text-slate-400">…</p> : (days.data?.length ?? 0) === 0 ? (
            <p className="text-sm text-slate-400">No attendance recorded this month.</p>
          ) : (
            <div className="grid grid-cols-2 gap-x-6 gap-y-0.5 text-sm sm:grid-cols-3">
              {days.data?.map((day) => (
                <div key={day.attendance_date} className="flex justify-between border-b border-slate-100 py-0.5">
                  <span className="text-slate-600">{fmtDate(day.attendance_date)}</span>
                  <span className="font-medium text-slate-800">{ATTENDANCE_SHORT[day.status] ?? day.status}</span>
                </div>
              ))}
            </div>
          )}
        </div>

        <div className="mt-6 flex gap-2 print:hidden">
          <button onClick={() => { setPrinting(true); setTimeout(() => { window.print(); setPrinting(false) }, 50) }}
            className="flex-1 rounded bg-brand-600 px-3 py-2 text-sm font-medium text-white hover:bg-brand-700">Print / Save PDF</button>
          <button onClick={onClose} className="flex-1 rounded border border-slate-300 px-3 py-2 text-sm hover:bg-slate-50">Close</button>
        </div>
        {printing && <span className="hidden">printing</span>}
      </div>
    </div>
  )
}

/**
 * Logins that belong to nobody.
 *
 * THE BUG THIS EXISTS FOR. The roster reads the staff table. A login that was
 * never attached to a staff record therefore appeared on NO screen in the
 * application: it existed, it worked, it could sign in and read every child's
 * record, and nothing showed it. Create a teacher login and the roster still
 * said "No staff yet", which looks exactly like the creation having failed.
 * That is what the first real school saw, and they were right to think
 * something was broken.
 *
 * It renders nothing when there are none, which is the normal state now that
 * adding somebody makes both halves at once. It is here for the ones already
 * created, and for a login made from Settings that nobody has claimed.
 *
 * Every row offers the two things worth doing: attach it to a person who is
 * already on the roster, or remove it. Removing goes through the same rules as
 * everything else, so one that has taken a payment or marked a register is
 * refused with the reason.
 */
function UnattachedLogins({ canLink, staff }: { canLink: boolean; staff: StaffRow[] }) {
  const qc = useQueryClient()
  const [removing, setRemoving] = useState<SchoolLogin | null>(null)
  const logins = useQuery({
    queryKey: ['schoolLogins'],
    queryFn: listSchoolLogins,
    enabled: canLink,
    retry: false,
  })

  const attach = useMutation({
    mutationFn: (v: { staffId: string; profileId: string }) =>
      linkStaffProfile(v.staffId, v.profileId),
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ['schoolLogins'] })
      qc.invalidateQueries({ queryKey: ['staff'] })
      qc.invalidateQueries({ queryKey: ['profiles'] })
    },
  })

  if (!canLink) return null
  const loose = (logins.data ?? []).filter((l) => !l.staff_id)
  if (logins.isError) {
    return (
      <p className="rounded-lg border border-danger-200 bg-danger-50 px-3 py-2 text-sm text-danger-800">
        Could not check for unattached logins: {(logins.error as Error).message}
      </p>
    )
  }
  if (!loose.length) return null

  const free = staff.filter((s) => !s.profile_id && s.status === 'active')

  return (
    <div className="rounded-lg border border-amber-200 bg-amber-50 p-4">
      <p className="text-sm font-medium text-amber-900">
        {loose.length === 1
          ? 'One login is not attached to anybody on the staff list'
          : `${loose.length} logins are not attached to anybody on the staff list`}
      </p>
      <p className="mt-1 text-sm text-amber-800">
        They can sign in and see the school&rsquo;s records, but they have no staff
        record, so they do not appear on the roster below, cannot be given a class,
        and have no attendance or ID card. Attach each one to a person, or remove it.
      </p>
      <ul className="mt-3 space-y-2">
        {loose.map((l) => (
          <li key={l.profile_id}
              className="flex flex-wrap items-center justify-between gap-2 rounded-lg bg-white px-3 py-2">
            <div className="min-w-0">
              <span className="text-sm font-medium text-slate-800">
                {l.full_name || '(no name)'}
              </span>
              {/* The address, which no screen in this app could show before. */}
              <span className="ml-2 text-xs text-slate-500">{l.email}</span>
              <span className="ml-2 rounded bg-slate-100 px-1.5 py-0.5 text-[11px] font-medium text-slate-600">
                {ROLE_LABELS[l.role as Role] ?? l.role}
              </span>
              {!l.active && (
                <span className="ml-2 rounded bg-slate-200 px-1.5 py-0.5 text-[11px] text-slate-600">closed</span>
              )}
            </div>
            <div className="flex items-center gap-2">
              {free.length > 0 ? (
                <select defaultValue=""
                  onChange={(e) => {
                    if (e.target.value) attach.mutate({ staffId: e.target.value, profileId: l.profile_id })
                  }}
                  className="rounded border border-slate-300 px-2 py-1 text-sm focus:border-brand-500 focus:outline-none">
                  <option value="">Attach to…</option>
                  {free.map((s) => <option key={s.id} value={s.id}>{s.full_name}</option>)}
                </select>
              ) : (
                <span className="text-xs text-slate-500">
                  Add them with &ldquo;Add someone&rdquo; first, then attach this login
                </span>
              )}
              <button onClick={() => setRemoving(l)}
                className="rounded border border-slate-300 bg-white px-2 py-1 text-xs font-medium text-slate-600 hover:bg-slate-50">
                Remove
              </button>
            </div>
          </li>
        ))}
      </ul>
      {attach.isError && (
        <p className="mt-2 text-sm text-danger-700">{(attach.error as Error).message}</p>
      )}
      {removing && (
        <DeleteRecord
          kind="login"
          name={removing.full_name || removing.email || 'this login'}
          blockers={() => loginDeleteBlockers(removing.profile_id)}
          remove={() => deleteLogin(removing.profile_id)}
          onDeleted={() => {
            setRemoving(null)
            qc.invalidateQueries({ queryKey: ['schoolLogins'] })
            qc.invalidateQueries({ queryKey: ['profiles'] })
          }}
          onCancel={() => setRemoving(null)}
        />
      )}
    </div>
  )
}

/**
 * Adding somebody to the school. One screen, one form, one decision at a time.
 *
 * WHAT WAS WRONG BEFORE
 *
 * A person and a login were two separate records joined by a manual step, and
 * the screen showed that plumbing to the office. Two forms sat open side by
 * side, each with its own "Full name" field: "New teacher login" wrote a
 * profiles row, "New staff member" wrote a staff row, and neither mentioned the
 * other. To get one working teacher you had to fill in the first, fill in the
 * second, find the new row in the roster, and pick the login out of a dropdown.
 * Nothing said so, and nothing warned you when you stopped after step one.
 *
 * There were also THREE places to create access: this screen, Settings > Users
 * and Roles, and the parent panel on a student. Settings even advised against
 * the button this screen put front and centre.
 *
 * WHAT IT IS NOW
 *
 * The person first, because that is what the office came to do. Then one plain
 * question, "Should they be able to sign in?", which opens the login fields
 * only if the answer is yes. Same form, same screen, and the clerk never sees a
 * field they do not need.
 *
 * WHY THE PERSON IS SAVED FIRST
 *
 * The staff record is cheap, local and always works. The login needs an Edge
 * Function that may be out of date or not deployed. Doing the durable half
 * first means a failure at the second step leaves a correct staff record and a
 * clear message, rather than a login floating with nobody attached to it, which
 * is the exact state that made logins invisible in the first place.
 */
function AddPerson({ onDone, onFlash }: { onDone: () => void; onFlash: (m: string) => void }) {
  const [form, setForm] = useState<StaffInput>(BLANK)
  const [wantsLogin, setWantsLogin] = useState(false)
  const [email, setEmail] = useState('')
  const [password, setPassword] = useState('')
  const [role, setRole] = useState('class_teacher')
  const [partial, setPartial] = useState<string | null>(null)

  const nameOk = form.full_name.trim().length > 0
  const loginOk = !wantsLogin
    || (/^\S+@\S+\.\S+$/.test(email.trim()) && password.length >= 6)
  const valid = nameOk && loginOk
  const roleChoices = ROLES.filter((r) => r !== 'owner')

  const save = useMutation({
    mutationFn: async () => {
      const staffId = await createStaff({ ...form, full_name: form.full_name.trim() })
      if (!wantsLogin) return { name: form.full_name.trim(), login: null as string | null }

      // From here the person exists. If the login fails, say so precisely and
      // leave the person alone: they are a correct record either way, and the
      // login can be added later from the same row.
      try {
        const created = await createTeacherLogin({
          email: email.trim(), password, full_name: form.full_name.trim(), role,
        })
        await linkStaffProfile(staffId, created.id)
        return { name: form.full_name.trim(), login: created.email }
      } catch (e) {
        throw new Error(
          `${form.full_name.trim()} has been added to the staff list, but their login `
          + `could not be created: ${(e as Error).message}`,
        )
      }
    },
    onSuccess: (r) => {
      onFlash(
        r.login
          ? `${r.name} has been added, and can sign in as ${r.login}.`
          : `${r.name} has been added. They cannot sign in yet; use "Give them a login" on their row when they need to.`,
      )
      setForm(BLANK); setEmail(''); setPassword(''); setWantsLogin(false); setPartial(null)
      onDone()
    },
    onError: (e) => setPartial((e as Error).message),
  })

  return (
    <form
      className="rounded-lg border border-slate-200 bg-white p-4"
      onSubmit={(e) => { e.preventDefault(); if (valid) save.mutate() }}
    >
      <div className="text-xs font-semibold uppercase tracking-wide text-slate-500">
        Add someone to the school
      </div>

      <div className="mt-3 grid gap-3 sm:grid-cols-2">
        <label className="block sm:col-span-2">
          <span className="text-sm text-slate-600">Full name</span>
          <input value={form.full_name} autoFocus
            onChange={(e) => setForm({ ...form, full_name: e.target.value })} className={FIELD} />
        </label>
        <label className="block"><span className="text-sm text-slate-600">Designation</span>
          <input value={form.designation ?? ''} placeholder="e.g. Senior Teacher"
            onChange={(e) => setForm({ ...form, designation: e.target.value })} className={FIELD} /></label>
        <label className="block"><span className="text-sm text-slate-600">Mobile</span>
          <input value={form.mobile ?? ''}
            onChange={(e) => setForm({ ...form, mobile: e.target.value })} className={FIELD} /></label>
        <label className="block"><span className="text-sm text-slate-600">Employee #</span>
          <input value={form.employee_no ?? ''}
            onChange={(e) => setForm({ ...form, employee_no: e.target.value })} className={FIELD} /></label>
        <label className="block"><span className="text-sm text-slate-600">CNIC</span>
          <input value={form.cnic ?? ''}
            onChange={(e) => setForm({ ...form, cnic: e.target.value })} className={FIELD} /></label>
        <label className="block"><span className="text-sm text-slate-600">Joined on</span>
          <input type="date" value={form.joined_on ?? ''}
            onChange={(e) => setForm({ ...form, joined_on: e.target.value })} className={FIELD} /></label>
        <label className="block"><span className="text-sm text-slate-600">Date of birth</span>
          <input type="date" value={form.dob ?? ''}
            onChange={(e) => setForm({ ...form, dob: e.target.value })} className={FIELD} /></label>
      </div>

      {/* The one question that used to be a whole second form on a different
          part of the screen. */}
      <div className="mt-4 rounded-lg border border-slate-200 bg-slate-50 p-3">
        <label className="flex cursor-pointer items-start gap-2.5">
          <input type="checkbox" checked={wantsLogin} className="mt-0.5 h-4 w-4"
            onChange={(e) => setWantsLogin(e.target.checked)} />
          <span>
            <span className="text-sm font-medium text-slate-800">
              Should they be able to sign in to the app?
            </span>
            <span className="mt-0.5 block text-xs text-slate-500">
              A teacher needs this to mark attendance and enter marks. An office
              record with no login is perfectly normal for a driver, a guard or an
              ayah. You can add one later.
            </span>
          </span>
        </label>

        {wantsLogin && (
          <div className="mt-3 border-t border-slate-200 pt-3">
            <LoginFunctionWarning />
            <div className="grid gap-3 sm:grid-cols-2">
              <label className="block"><span className="text-sm text-slate-600">Email they sign in with</span>
                <input type="email" value={email} placeholder="teacher@school.pk"
                  onChange={(e) => setEmail(e.target.value)} className={FIELD} /></label>
              <label className="block"><span className="text-sm text-slate-600">What they can do</span>
                <select value={role} onChange={(e) => setRole(e.target.value)} className={FIELD}>
                  {roleChoices.map((r) => <option key={r} value={r}>{ROLE_LABELS[r as Role]}</option>)}
                </select></label>
              <label className="block sm:col-span-2">
                <span className="text-sm text-slate-600">First password (at least 6 characters)</span>
                <input type="text" value={password} placeholder="they can change it after signing in"
                  onChange={(e) => setPassword(e.target.value)} className={FIELD} /></label>
            </div>
            <p className="mt-2 text-xs text-slate-500">
              Give them the address and this password. They can sign in straight away
              and change it from their own account.
            </p>
          </div>
        )}
      </div>

      {/* Deliberately not the generic mutation error: the message above says
          which half succeeded, and that distinction is the whole point of doing
          the durable half first. */}
      {partial && <p className="mt-3 text-sm text-danger-700">{partial}</p>}

      <div className="mt-4 flex gap-2">
        <button type="submit" disabled={!valid || save.isPending}
          className="rounded bg-brand-600 px-4 py-2 text-sm font-medium text-white hover:bg-brand-700 disabled:opacity-60">
          {save.isPending ? 'Saving…' : wantsLogin ? 'Add them and make their login' : 'Add them'}
        </button>
        <button type="button" onClick={onDone}
          className="rounded border border-slate-300 px-4 py-2 text-sm font-medium text-slate-700 hover:bg-slate-50">
          Cancel
        </button>
      </div>
    </form>
  )
}

/**
 * Who teaches which subject.
 *
 * WHY THIS SCREEN IS NOT PAPERWORK. Until 0085, fn_enter_marks — the function
 * that writes the marks printed on the result card, the certificate and the
 * tabulation sheet — had NO class scope at all. Any class_teacher or
 * subject_teacher could enter or overwrite any class's exam marks in any
 * subject. Its sibling fn_enter_assessment_marks, which writes the weekly test
 * marks nobody keeps, had been class-scoped since 0048. The guarded path was the
 * one that did not matter.
 *
 * So what is filled in here decides who can touch a child's result. The panel at
 * the top says that out loud, because a screen that looks like a directory gets
 * treated like one.
 *
 * ONE CLASS AT A TIME, deliberately. A school has twelve classes and five to
 * eight subjects each, and a single grid of sixty-plus rows is a screen nobody
 * finishes. Picking a class turns it into five decisions.
 *
 * SUBJECTS WITH NOBODY ASSIGNED ARE SHOWN AND MARKED. fn_subject_teachers returns
 * them for exactly that reason: the empty rows are the work list, and a screen
 * that listed only the filled ones would hide the thing the office opened it to
 * do — then teachers would hit "you can only enter marks for a class and subject
 * you teach" during exam week with no idea why.
 */
function SubjectTeachersTab() {
  const qc = useQueryClient()
  const session = useQuery({ queryKey: ['currentSession'], queryFn: getCurrentSession })
  const sessionId = session.data?.id
  const staff = useQuery({ queryKey: ['staff'], queryFn: getStaffRoster })
  const [classId, setClassId] = useState('')

  const register = useQuery({
    queryKey: ['subjectTeachers', sessionId],
    queryFn: () => getSubjectTeachers(sessionId!),
    enabled: !!sessionId,
  })

  const save = useMutation({
    mutationFn: (v: { subjectId: string; staffIds: string[] }) =>
      // Section null: a subject is taught to the class here. Per-section split
      // teaching is supported by the database and is not offered on this screen,
      // because it is rare and adding it would double the width of every row.
      setSubjectTeachers(sessionId!, classId, null, v.subjectId, v.staffIds),
    onSuccess: () => qc.invalidateQueries({ queryKey: ['subjectTeachers', sessionId] }),
  })

  const activeStaff = (staff.data ?? []).filter((s) => s.status === 'active')
  const rows: SubjectTeacherRow[] = (register.data ?? []).filter((r) => r.class_id === classId)
  const classes = Array.from(
    new Map((register.data ?? []).map((r) => [r.class_id, { id: r.class_id, name: r.class_name, order: r.level_order }])).values(),
  ).sort((a, b) => a.order - b.order)
  const unassigned = (register.data ?? []).filter((r) => r.teachers.length === 0).length

  function toggle(row: SubjectTeacherRow, staffId: string) {
    const has = row.teachers.some((t) => t.staff_id === staffId)
    const next = has
      ? row.teachers.filter((t) => t.staff_id !== staffId).map((t) => t.staff_id)
      : [...row.teachers.map((t) => t.staff_id), staffId]
    save.mutate({ subjectId: row.subject_id, staffIds: next })
  }

  return (
    <div className="max-w-3xl space-y-4">
      {!sessionId && !session.isLoading && (
        <p className="rounded bg-amber-50 p-3 text-sm text-amber-700">
          No current session set — set one in Settings → Sessions first.
        </p>
      )}

      <div className="rounded-lg border border-slate-200 bg-white p-3 text-sm text-slate-600">
        <span className="font-medium text-slate-800">This decides who can enter marks.</span>{' '}
        A teacher may enter marks for a class they are the class teacher of, or for a
        class and subject listed here. Everyone else is refused — including for the exam
        marks that go on the result card.
        {unassigned > 0 && (
          <span className="mt-1 block text-amber-700">
            {unassigned} subject{unassigned === 1 ? ' has' : 's have'} nobody assigned across
            all classes. Only the office can enter their marks until somebody is.
          </span>
        )}
      </div>

      <label className="block max-w-xs">
        <span className="text-sm text-slate-600">Class</span>
        <select value={classId} onChange={(e) => setClassId(e.target.value)} className={FIELD}>
          <option value="">Select class…</option>
          {classes.map((c) => <option key={c.id} value={c.id}>{c.name}</option>)}
        </select>
      </label>

      {register.isLoading && <p className="text-sm text-slate-400">Loading…</p>}
      {register.isError && (
        <p className="text-sm text-red-600">{(register.error as Error).message}</p>
      )}
      {save.isError && (
        <p className="rounded bg-red-50 p-3 text-sm text-red-700">{(save.error as Error).message}</p>
      )}

      {classId && rows.length === 0 && !register.isLoading && (
        <p className="rounded bg-amber-50 p-3 text-sm text-amber-700">
          That class has no subjects yet. Add them under Exams → Subjects before assigning
          teachers.
        </p>
      )}

      {classId && rows.length > 0 && (
        <div className="overflow-hidden rounded-lg border border-slate-200 bg-white">
          <ul className="divide-y divide-slate-100">
            {rows.map((row) => (
              <li key={row.subject_id} className="px-3 py-2.5">
                <div className="flex flex-wrap items-baseline justify-between gap-2">
                  <span className="text-sm font-medium text-slate-800">{row.subject_name}</span>
                  {row.teachers.length === 0 ? (
                    <span className="text-xs text-amber-700">nobody assigned</span>
                  ) : (
                    <span className="text-xs text-slate-500">
                      {row.teachers.map((t) => t.staff_name).join(', ')}
                    </span>
                  )}
                </div>
                {activeStaff.length === 0 ? (
                  <p className="mt-1 text-xs text-slate-400">
                    No active staff to assign — add them on the Staff tab first.
                  </p>
                ) : (
                  <div className="mt-1.5 flex flex-wrap gap-1.5">
                    {activeStaff.map((st) => {
                      const on = row.teachers.some((t) => t.staff_id === st.id)
                      return (
                        <button
                          key={st.id}
                          onClick={() => toggle(row, st.id)}
                          disabled={save.isPending || !sessionId}
                          className={`rounded-full px-2.5 py-1 text-xs font-medium transition disabled:opacity-50 ${
                            on
                              ? 'bg-brand-600 text-white'
                              : 'bg-slate-100 text-slate-600 hover:bg-slate-200'
                          }`}
                        >
                          {st.full_name}
                        </button>
                      )
                    })}
                  </div>
                )}
              </li>
            ))}
          </ul>
        </div>
      )}
    </div>
  )
}

function ClassTeachersTab() {
  const qc = useQueryClient()
  const session = useQuery({ queryKey: ['currentSession'], queryFn: getCurrentSession })
  const sessionId = session.data?.id
  const classes = useQuery({ queryKey: ['classes'], queryFn: listClasses })
  const staff = useQuery({ queryKey: ['staff'], queryFn: getStaffRoster })
  const [classId, setClassId] = useState('')
  const sections = useQuery({ queryKey: ['sectionTeachers', classId], queryFn: () => listSectionTeachers(classId), enabled: !!classId })
  const assignments = useQuery({ queryKey: ['teacherAssignments', sessionId], queryFn: () => listTeacherAssignments(sessionId!), enabled: !!sessionId })

  // Set the teacher for a (class, section-or-null): update the scoping assignment
  // AND mirror the section's class_teacher_id (used by result cards).
  const setTeacher = useMutation({
    mutationFn: (v: { sectionId: string | null; staffId: string | null }) =>
      setClassTeacher(v.staffId, sessionId!, classId, v.sectionId),
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ['sectionTeachers', classId] })
      qc.invalidateQueries({ queryKey: ['teacherAssignments', sessionId] })
    },
  })
  const activeStaff = (staff.data ?? []).filter((s) => s.status === 'active')

  const teacherFor = (sectionId: string | null): string => {
    const a = (assignments.data ?? []).find((x) => x.class_id === classId && (x.section_id ?? null) === (sectionId ?? null))
    if (a) return a.staff_id
    if (sectionId) return sections.data?.find((s) => s.id === sectionId)?.class_teacher_id ?? ''
    return ''
  }

  /* The options for one row.
   *
   * This existed as `activeStaff` alone, and that was a silent misreport. If the
   * assigned teacher is no longer active, their id matches no <option>, and a
   * <select> whose value matches nothing renders as the FIRST option — here,
   * "— unassigned —". So the screen told the principal the section had no class
   * teacher while sections.class_teacher_id still held one, and result cards
   * still printed that name. Nothing on any screen could reveal it.
   *
   * 0053's fn_staff_leave vacates these slots, so it cannot happen going
   * forward. It can still be TRUE of a school upgrading with rows the old
   * Deactivate button left behind, which is exactly when a screen must not lie.
   */
  const optionsFor = (sectionId: string | null) => {
    const current = teacherFor(sectionId)
    if (!current || activeStaff.some((s) => s.id === current)) return activeStaff
    const held = (staff.data ?? []).find((s) => s.id === current)
    return [
      ...(held
        ? [{ ...held, full_name: `${held.full_name} (has left — please reassign)` }]
        : [{ id: current, full_name: 'A former member of staff — please reassign' } as StaffRosterRow]),
      ...activeStaff,
    ]
  }

  return (
    <div className="max-w-2xl space-y-4">
      {!sessionId && !session.isLoading && (
        <p className="rounded bg-amber-50 p-3 text-sm text-amber-700">No current session set — set one in Settings → Sessions first.</p>
      )}
      <label className="block max-w-xs"><span className="text-sm text-slate-600">Class</span>
        <select value={classId} onChange={(e) => setClassId(e.target.value)} className={FIELD}>
          <option value="">Select class…</option>
          {classes.data?.map((c) => <option key={c.id} value={c.id}>{c.name}</option>)}
        </select>
      </label>

      {classId && (
        <div className="overflow-hidden rounded-lg border border-slate-200 bg-white">
          <ul className="divide-y divide-slate-100">
            {/* Whole-class row — the only option for a class with no sections */}
            <li className="flex items-center justify-between px-3 py-2">
              <span className="text-sm font-medium text-slate-800">
                Whole class <span className="text-xs font-normal text-slate-400">(use when there are no sections)</span>
              </span>
              <select value={teacherFor(null)} onChange={(e) => setTeacher.mutate({ sectionId: null, staffId: e.target.value || null })}
                disabled={!sessionId} className="w-56 rounded border border-slate-300 px-2 py-1 text-sm focus:border-brand-500 focus:outline-none">
                <option value="">— unassigned —</option>
                {optionsFor(null).map((s) => <option key={s.id} value={s.id}>{s.full_name}</option>)}
              </select>
            </li>
            {sections.data?.map((sec) => (
              <li key={sec.id} className="flex items-center justify-between px-3 py-2">
                <span className="text-sm font-medium text-slate-800">Section {sec.name}</span>
                <select value={teacherFor(sec.id)} onChange={(e) => setTeacher.mutate({ sectionId: sec.id, staffId: e.target.value || null })}
                  disabled={!sessionId} className="w-56 rounded border border-slate-300 px-2 py-1 text-sm focus:border-brand-500 focus:outline-none">
                  <option value="">— unassigned —</option>
                  {optionsFor(sec.id).map((s) => <option key={s.id} value={s.id}>{s.full_name}</option>)}
                </select>
              </li>
            ))}
          </ul>
        </div>
      )}
      {setTeacher.isError && <p className="text-sm text-red-600">{(setTeacher.error as Error).message}</p>}
      <p className="text-xs text-slate-500">
        Assigning a teacher here lets them mark that class’s attendance and tests in the teacher portal, and shows them
        as class teacher on result cards. A whole-class assignment covers every section of the class.
      </p>
    </div>
  )
}

import { useMemo, useState } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import {
  listStaff, createStaff, updateStaff, setStaffStatus, linkStaffProfile, listProfiles,
  listClasses, listSectionTeachers, assignClassTeacher,
  getCurrentSession, listTeacherAssignments, assignTeacher, removeTeacherAssignment,
  getStaffAttendanceSummary, getStaffMonthAttendance, createTeacherLogin,
  type StaffRow, type StaffInput,
} from '@/lib/db'
import { ROLE_LABELS, ROLES, type Role } from '@/auth/roles'
import { ATTENDANCE_SHORT } from '@/lib/constants'
import { fmtDate, todayISO } from '@/lib/format'
import { useAuth } from '@/auth/AuthProvider'
import { useSchoolName } from '@/hooks/useSchoolName'
import { StaffIdCard } from './StaffIdCard'

const FIELD = 'mt-1 w-full rounded border border-slate-300 px-3 py-2 text-sm focus:border-brand-500 focus:outline-none focus:ring-1 focus:ring-brand-500'
const TABS = [{ key: 'staff', label: 'Staff' }, { key: 'teachers', label: 'Class Teachers' }] as const

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
  const [tab, setTab] = useState<'staff' | 'teachers'>('staff')
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
      <div className="mt-5">{tab === 'staff' ? <StaffTab /> : <ClassTeachersTab />}</div>
    </div>
  )
}

const BLANK: StaffInput = { full_name: '', designation: '', employee_no: '', mobile: '', whatsapp: '', cnic: '', joined_on: '' }

function StaffTab() {
  const qc = useQueryClient()
  const { profile } = useAuth()
  const canLink = !!profile && ['owner', 'principal'].includes(profile.role)
  const staff = useQuery({ queryKey: ['staff'], queryFn: listStaff })
  const profiles = useQuery({ queryKey: ['profiles'], queryFn: listProfiles })
  const [editing, setEditing] = useState<string | null>(null) // staff id, or 'new'
  const [form, setForm] = useState<StaffInput>(BLANK)
  const [idCard, setIdCard] = useState<StaffRow | null>(null)
  const [attFor, setAttFor] = useState<StaffRow | null>(null)
  const [showLogin, setShowLogin] = useState(false)

  const invalidate = () => qc.invalidateQueries({ queryKey: ['staff'] })
  const save = useMutation({
    mutationFn: async () => {
      const payload = { ...form, full_name: form.full_name.trim() }
      if (editing === 'new') await createStaff(payload)
      else await updateStaff(editing!, payload)
    },
    onSuccess: () => { setEditing(null); setForm(BLANK); invalidate() },
  })
  const status = useMutation({
    mutationFn: (v: { id: string; status: 'active' | 'inactive' }) => setStaffStatus(v.id, v.status),
    onSuccess: invalidate,
  })
  const link = useMutation({
    mutationFn: (v: { id: string; profileId: string | null }) => linkStaffProfile(v.id, v.profileId),
    onSuccess: () => { invalidate(); qc.invalidateQueries({ queryKey: ['profiles'] }) },
  })

  function startEdit(s: StaffRow) {
    setEditing(s.id)
    setForm({ full_name: s.full_name, designation: s.designation ?? '', employee_no: s.employee_no ?? '', mobile: s.mobile ?? '', whatsapp: s.whatsapp ?? '', cnic: s.cnic ?? '', joined_on: s.joined_on ?? '' })
  }

  return (
    <div className="space-y-5">
      {!editing && (
        <div className="flex flex-wrap gap-2">
          <button onClick={() => { setEditing('new'); setForm(BLANK) }}
            className="rounded bg-brand-600 px-4 py-2 text-sm font-medium text-white hover:bg-brand-700">+ Add staff</button>
          {canLink && (
            <button onClick={() => setShowLogin((v) => !v)}
              className="rounded border border-slate-300 px-4 py-2 text-sm font-medium text-slate-700 hover:bg-slate-50">
              {showLogin ? 'Close' : '+ Add teacher login'}
            </button>
          )}
        </div>
      )}

      {showLogin && canLink && (
        <AddLogin onDone={() => { setShowLogin(false); qc.invalidateQueries({ queryKey: ['profiles'] }) }} />
      )}

      {editing && (
        <form className="rounded-lg border border-slate-200 bg-white p-4" onSubmit={(e) => { e.preventDefault(); if (form.full_name.trim()) save.mutate() }}>
          <div className="text-xs font-semibold uppercase tracking-wide text-slate-500">{editing === 'new' ? 'New staff member' : 'Edit staff'}</div>
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
          </div>
          {save.isError && <p className="mt-2 text-sm text-red-600">{(save.error as Error).message}</p>}
          <div className="mt-3 flex gap-2">
            <button type="submit" disabled={!form.full_name.trim() || save.isPending}
              className="rounded bg-brand-600 px-4 py-2 text-sm font-medium text-white hover:bg-brand-700 disabled:opacity-60">{save.isPending ? 'Saving…' : 'Save'}</button>
            <button type="button" onClick={() => { setEditing(null); setForm(BLANK) }} className="rounded border border-slate-300 px-4 py-2 text-sm hover:bg-slate-50">Cancel</button>
          </div>
        </form>
      )}

      <div className="overflow-x-auto rounded-lg border border-slate-200 bg-white">
        <table className="w-full text-sm">
          <thead className="bg-slate-50 text-left text-xs uppercase tracking-wide text-slate-500">
            <tr><th className="px-3 py-2">Name</th><th className="px-3 py-2">Designation</th><th className="px-3 py-2">Mobile</th><th className="px-3 py-2 w-56">Login</th><th className="px-3 py-2 w-40"></th></tr>
          </thead>
          <tbody className="divide-y divide-slate-100">
            {staff.isLoading && <tr><td colSpan={5} className="px-3 py-3 text-slate-500">Loading…</td></tr>}
            {staff.data?.length === 0 && <tr><td colSpan={5} className="px-3 py-3 text-slate-500">No staff yet.</td></tr>}
            {staff.data?.map((s) => {
              const logins = (profiles.data ?? []).filter((p) => !p.staff_id || p.id === s.profile_id)
              return (
                <tr key={s.id} className={s.status === 'active' ? '' : 'opacity-60'}>
                  <td className="px-3 py-2 font-medium text-slate-800">{s.full_name}{s.employee_no && <span className="ml-1 text-xs text-slate-400">#{s.employee_no}</span>}</td>
                  <td className="px-3 py-2 text-slate-600">{s.designation ?? '—'}</td>
                  <td className="px-3 py-2 text-slate-600">{s.mobile ?? '—'}</td>
                  <td className="px-3 py-2">
                    {canLink ? (
                      <select value={s.profile_id ?? ''} onChange={(e) => link.mutate({ id: s.id, profileId: e.target.value || null })}
                        className="w-full rounded border border-slate-300 px-2 py-1 text-sm focus:border-brand-500 focus:outline-none">
                        <option value="">— no login —</option>
                        {logins.map((p) => <option key={p.id} value={p.id}>{p.full_name || '(unnamed)'} · {ROLE_LABELS[p.role as Role] ?? p.role}</option>)}
                      </select>
                    ) : (
                      <span className="text-slate-500">{profiles.data?.find((p) => p.id === s.profile_id)?.full_name ?? '—'}</span>
                    )}
                  </td>
                  <td className="px-3 py-2 text-right">
                    <button onClick={() => startEdit(s)} className="mr-2 text-sm text-brand-700 hover:underline">Edit</button>
                    <button onClick={() => setAttFor(s)} className="mr-2 text-sm text-brand-700 hover:underline">Attendance</button>
                    <button onClick={() => setIdCard(s)} className="mr-2 text-sm text-brand-700 hover:underline">ID card</button>
                    <button onClick={() => status.mutate({ id: s.id, status: s.status === 'active' ? 'inactive' : 'active' })}
                      className="rounded border border-slate-300 px-2 py-1 text-xs font-medium text-slate-600 hover:bg-slate-50">
                      {s.status === 'active' ? 'Deactivate' : 'Activate'}
                    </button>
                  </td>
                </tr>
              )
            })}
          </tbody>
        </table>
      </div>
      {link.isError && <p className="text-sm text-red-600">{(link.error as Error).message}</p>}
      {idCard && <StaffIdCard staff={idCard} onClose={() => setIdCard(null)} />}
      {attFor && <StaffAttendanceModal staff={attFor} onClose={() => setAttFor(null)} />}
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

function AddLogin({ onDone }: { onDone: () => void }) {
  const [fullName, setFullName] = useState('')
  const [email, setEmail] = useState('')
  const [password, setPassword] = useState('')
  const [role, setRole] = useState('class_teacher')
  const [ok, setOk] = useState<string | null>(null)
  const create = useMutation({
    mutationFn: () => createTeacherLogin({ email: email.trim(), password, full_name: fullName.trim(), role }),
    onSuccess: (r) => { setOk(`Login created for ${r.email}. Link it to a staff record below, then assign a class in Class Teachers.`); setFullName(''); setEmail(''); setPassword(''); onDone() },
  })
  const valid = /^\S+@\S+\.\S+$/.test(email.trim()) && password.length >= 6
  const roleChoices = ROLES.filter((r) => r !== 'owner')
  return (
    <form className="rounded-lg border border-slate-200 bg-white p-4" onSubmit={(e) => { e.preventDefault(); if (valid) create.mutate() }}>
      <div className="text-xs font-semibold uppercase tracking-wide text-slate-500">New teacher login</div>
      <div className="mt-2 grid gap-3 sm:grid-cols-2">
        <label className="block"><span className="text-sm text-slate-600">Full name</span>
          <input value={fullName} onChange={(e) => setFullName(e.target.value)} className={FIELD} /></label>
        <label className="block"><span className="text-sm text-slate-600">Role</span>
          <select value={role} onChange={(e) => setRole(e.target.value)} className={FIELD}>
            {roleChoices.map((r) => <option key={r} value={r}>{ROLE_LABELS[r as Role]}</option>)}
          </select></label>
        <label className="block"><span className="text-sm text-slate-600">Email</span>
          <input type="email" value={email} onChange={(e) => setEmail(e.target.value)} className={FIELD} placeholder="teacher@school.pk" /></label>
        <label className="block"><span className="text-sm text-slate-600">Password (min 6)</span>
          <input type="text" value={password} onChange={(e) => setPassword(e.target.value)} className={FIELD} placeholder="temporary password" /></label>
      </div>
      {create.isError && <p className="mt-2 text-sm text-red-600">{(create.error as Error).message}</p>}
      {ok && <p className="mt-2 text-sm text-emerald-600">{ok}</p>}
      <button type="submit" disabled={!valid || create.isPending}
        className="mt-3 rounded bg-brand-600 px-4 py-2 text-sm font-medium text-white hover:bg-brand-700 disabled:opacity-60">
        {create.isPending ? 'Creating…' : 'Create login'}
      </button>
      <p className="mt-2 text-xs text-slate-400">Share the email &amp; password with the teacher; they can sign in and check in immediately.</p>
    </form>
  )
}

function ClassTeachersTab() {
  const qc = useQueryClient()
  const session = useQuery({ queryKey: ['currentSession'], queryFn: getCurrentSession })
  const sessionId = session.data?.id
  const classes = useQuery({ queryKey: ['classes'], queryFn: listClasses })
  const staff = useQuery({ queryKey: ['staff'], queryFn: listStaff })
  const [classId, setClassId] = useState('')
  const sections = useQuery({ queryKey: ['sectionTeachers', classId], queryFn: () => listSectionTeachers(classId), enabled: !!classId })
  const assignments = useQuery({ queryKey: ['teacherAssignments', sessionId], queryFn: () => listTeacherAssignments(sessionId!), enabled: !!sessionId })

  // Set the teacher for a (class, section-or-null): update the scoping assignment
  // AND mirror the section's class_teacher_id (used by result cards).
  const setTeacher = useMutation({
    mutationFn: async (v: { sectionId: string | null; staffId: string | null }) => {
      const existing = (assignments.data ?? []).filter(
        (a) => a.class_id === classId && (a.section_id ?? null) === (v.sectionId ?? null),
      )
      for (const ex of existing) await removeTeacherAssignment(ex.id)
      if (v.sectionId) await assignClassTeacher(v.sectionId, v.staffId)
      if (v.staffId) await assignTeacher(v.staffId, sessionId!, classId, v.sectionId)
    },
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
                {activeStaff.map((s) => <option key={s.id} value={s.id}>{s.full_name}</option>)}
              </select>
            </li>
            {sections.data?.map((sec) => (
              <li key={sec.id} className="flex items-center justify-between px-3 py-2">
                <span className="text-sm font-medium text-slate-800">Section {sec.name}</span>
                <select value={teacherFor(sec.id)} onChange={(e) => setTeacher.mutate({ sectionId: sec.id, staffId: e.target.value || null })}
                  disabled={!sessionId} className="w-56 rounded border border-slate-300 px-2 py-1 text-sm focus:border-brand-500 focus:outline-none">
                  <option value="">— unassigned —</option>
                  {activeStaff.map((s) => <option key={s.id} value={s.id}>{s.full_name}</option>)}
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

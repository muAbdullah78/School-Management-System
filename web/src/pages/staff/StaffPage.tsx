import { useMemo, useState } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import {
  getStaffRoster, createStaff, updateStaff, linkStaffProfile, listProfiles,
  staffLeave, staffRejoin, staffSetLoginActive,
  listClasses, getCurrentSession, listTeacherAssignments, setClassTeacher,
  getSubjectTeachers, setSubjectTeachers, type SubjectTeacherRow, createSubject,
  getStaffAttendanceSummary, getStaffMonthAttendance, createTeacherLogin,
  type StaffRow, type StaffInput, type StaffRosterRow, type StaffLeaveResult,
} from '@/lib/db'
import { ASSIGNABLE_ROLES, ROLE_LABELS, canWrite, type Role } from '@/auth/roles'
import { ObserverNotice } from '@/components/ObserverNotice'
import { ATTENDANCE_SHORT, ATTENDANCE_LABELS } from '@/lib/constants'
import { fmtDate, todayISO } from '@/lib/format'
import { useAuth } from '@/auth/AuthProvider'
import { useSchoolName } from '@/hooks/useSchoolName'
import { StaffIdCard } from './StaffIdCard'
import { StaffDayRegister } from './StaffDayRegister'
import { PhotoUpload } from '@/components/PhotoUpload'
import { Avatar } from '@/components/Avatar'
import { removeStaffPhoto, signPaths, uploadStaffPhoto } from '@/lib/photos'
import { LoadError, Button, inputClass, buttonClass } from '@/components/ui'
import { TabBar } from '@/components/TabBar'
import { useUrlTab } from '@/lib/useUrlTab'
import { AskDialog } from '@/components/AskDialog'
import { StackBar, C, attendanceParts, type Segment } from '@/components/viz'
import { listAllSections } from '@/lib/db'
import { LoginFunctionWarning } from '@/components/LoginFunctionWarning'
import { DeleteRecord } from '@/components/DeleteRecord'
import { staffDeleteBlockers, deleteStaff } from '@/lib/db'
import { listSchoolLogins, loginDeleteBlockers, deleteLogin, type SchoolLogin } from '@/lib/db'
import { useEmailCheck, EmailVerdictLine } from '@/components/EmailAvailability'

const FIELD = 'mt-1 w-full rounded border border-slate-300 px-3 py-2 text-sm focus:border-brand-500 focus:outline-none focus:ring-1 focus:ring-brand-500'
const TABS = [{ key: 'staff', label: 'Staff' }, { key: 'attendance', label: 'Attendance' },
              { key: 'teachers', label: 'Class Teachers' },
              // 0085. Who teaches WHAT, and it is not paperwork: until this
              // register existed, fn_enter_marks had no class scope at all, so
              // any teacher could rewrite any class's exam marks.
              { key: 'subjects', label: 'Subject Teachers' }] as const

/** The roles a STAFF login may have. ASSIGNABLE_ROLES includes Parent, which is
 *  what the parent portal hands out, and offering it here made a teacher's login
 *  a parent's: it signed in to an empty portal. */
const STAFF_ROLES = ASSIGNABLE_ROLES.filter((r) => r !== 'parent')

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
  // In the address bar (/staff?tab=teachers), so a warning elsewhere can link
  // straight to the Class Teachers board and a reload stays where it was.
  const [tab, setTab] = useUrlTab<'staff' | 'attendance' | 'teachers' | 'subjects'>(
    ['staff', 'attendance', 'teachers', 'subjects'], 'staff')
  return (
    <div>
      <h1 className="text-xl font-semibold text-slate-800">Staff</h1>
      <p className="mt-0.5 text-sm text-slate-500">The people who work here, who can sign in, and who teaches what.</p>
      <TabBar label="Staff" className="mt-4" value={tab} onChange={setTab}
        tabs={TABS.map((t) => ({ key: t.key, label: t.label }))} />
      <div>
        {tab === 'staff' ? <StaffTab />
          : tab === 'attendance' ? <StaffDayRegister />
          : tab === 'teachers' ? <ClassTeachersTab />
          : <SubjectTeachersTab />}
      </div>
    </div>
  )
}

const BLANK: StaffInput = { full_name: '', designation: '', employee_no: '', mobile: '', whatsapp: '', cnic: '', joined_on: '', dob: '' }

type RosterFilter = 'everyone' | 'teaching' | 'stuck' | 'nologin' | 'left'

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
  // address, which listProfiles cannot: two staff both called Muhammad Ali
  // appeared in the dropdown as "Muhammad Ali" twice, and picking the wrong one
  // gives the wrong person access to the wrong class.
  const schoolLogins = useQuery({
    queryKey: ['schoolLogins'], queryFn: listSchoolLogins, enabled: canLink, retry: false,
  })
  const emailOf = (id: string | null) =>
    id ? (schoolLogins.data ?? []).find((l) => l.profile_id === id)?.email ?? null : null
  // WHAT EACH PERSON TEACHES, by name. The roster function counts class-teacher
  // rows and nothing else, so the card said "1 teaching assignment" beside
  // "Class teacher · 1-A" (the same fact twice) and said nothing at all about
  // the Physics teacher of Class 9, whose login decides who can enter Class 9's
  // Physics marks. Both registers are read here and named on the card.
  const cur = useQuery({ queryKey: ['currentSession'], queryFn: getCurrentSession })
  const curId = cur.data?.id
  const ctRows = useQuery({ queryKey: ['teacherAssignments', curId], queryFn: () => listTeacherAssignments(curId!), enabled: !!curId })
  const subjRows = useQuery({ queryKey: ['subjectTeachers', curId], queryFn: () => getSubjectTeachers(curId!), enabled: !!curId })
  const classOf = useMemo(() => {
    const m = new Map<string, string[]>()
    for (const a of ctRows.data ?? []) {
      const label = a.section_name ? `${a.class_name}-${a.section_name}` : a.class_name
      m.set(a.staff_id, [...(m.get(a.staff_id) ?? []), label])
    }
    return m
  }, [ctRows.data])
  const subjectsOf = useMemo(() => {
    const m = new Map<string, string[]>()
    for (const r of subjRows.data ?? []) {
      for (const t of r.teachers) m.set(t.staff_id, [...(m.get(t.staff_id) ?? []), `${r.subject_name} (${r.class_name})`])
    }
    return m
  }, [subjRows.data])
  const [editing, setEditing] = useState<string | null>(null) // staff id, or 'new'
  const [form, setForm] = useState<StaffInput>(BLANK)
  const [idCard, setIdCard] = useState<StaffRow | null>(null)
  const [attFor, setAttFor] = useState<StaffRow | null>(null)
  const [adding, setAdding] = useState(false)
  const [leaving, setLeaving] = useState<StaffRosterRow | null>(null)
  const [removing, setRemoving] = useState<StaffRow | null>(null)
  const [giveLoginFor, setGiveLoginFor] = useState<StaffRosterRow | null>(null)
  const [flash, setFlash] = useState<string | null>(null)
  const [q, setQ] = useState('')
  const [filter, setFilter] = useState<RosterFilter>('everyone')
  /* A login change waiting on "are you sure". The dropdown used to attach a
     login the moment it changed, so a slip of the thumb gave one teacher's
     access to another person, with no question and no message. */
  const [relinking, setRelinking] = useState<null | { row: StaffRosterRow; profileId: string | null }>(null)
  // Whose "Change login" list is open. One at a time, and closed by default:
  // a dropdown on every row repeated the login the row already showed.
  const [picking, setPicking] = useState<string | null>(null)

  const invalidate = () => {
    qc.invalidateQueries({ queryKey: ['staff'] })
    // The Class Teachers tab and every result card read sections.class_teacher_id,
    // which a leaving vacates.
    qc.invalidateQueries({ queryKey: ['sectionTeachers'] })
    qc.invalidateQueries({ queryKey: ['allSections'] })
    qc.invalidateQueries({ queryKey: ['teacherAssignments'] })
  }
  const save = useMutation({
    mutationFn: async () => {
      const payload = { ...form, full_name: form.full_name.trim() }
      if (editing === 'new') await createStaff(payload)
      else await updateStaff(editing!, payload)
    },
    onSuccess: () => {
      setFlash(`${form.full_name.trim()} saved.`)
      setEditing(null); setForm(BLANK); invalidate()
    },
  })
  const rejoin = useMutation({
    mutationFn: (v: { id: string; reason: string | null }) => staffRejoin(v.id, v.reason),
    onSuccess: (r) => {
      setFlash(
        `${r.staff_name} is back on the staff list.` +
        (r.login_restored ? ' Their login works again.' : '') +
        ' They are not class teacher of anything: assign that on the Class Teachers tab.',
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
    onSuccess: (_d, v) => {
      setRelinking(null)
      const who = staff.data?.find((x) => x.id === v.id)?.full_name ?? 'They'
      setFlash(v.profileId
        ? `${who} now signs in as ${emailOf(v.profileId) ?? 'that login'}.`
        : `${who} no longer has a login attached. They cannot sign in.`)
      invalidate(); qc.invalidateQueries({ queryKey: ['profiles'] }); qc.invalidateQueries({ queryKey: ['schoolLogins'] })
    },
  })

  /**
   * One signing request for the whole roster, keyed on the sorted list of
   * paths, so it re-signs when a photograph is added or removed and not on
   * every render. A storage outage costs the faces and not the page.
   */
  const photoPaths = (staff.data ?? []).map((s) => s.photo_path).filter(Boolean) as string[]
  const facesQ = useQuery({
    queryKey: ['staffFaces', [...photoPaths].sort().join('|')],
    queryFn: () => signPaths(photoPaths),
    enabled: photoPaths.length > 0,
    staleTime: 20 * 60 * 1000,
  })
  const faces = facesQ.data ?? new Map<string, string>()

  const editingRow = editing && editing !== 'new'
    ? staff.data?.find((r) => r.id === editing) ?? null
    : null

  function startEdit(s: StaffRow) {
    setEditing(s.id)
    setForm({ full_name: s.full_name, designation: s.designation ?? '', employee_no: s.employee_no ?? '', mobile: s.mobile ?? '', whatsapp: s.whatsapp ?? '', cnic: s.cnic ?? '', joined_on: s.joined_on ?? '', dob: s.dob ?? '' })
    // The form opens at the top of the list. On a long roster the row being
    // edited is far below it, and nothing on screen changed where the finger was.
    if (typeof window !== 'undefined') window.scrollTo({ top: 0, behavior: 'smooth' })
  }

  const rows = staff.data ?? []
  const here = rows.filter((r) => r.status === 'active')
  const teaching = (r: StaffRosterRow) =>
    !!r.class_teacher_of || r.assignments > 0 || classOf.has(r.id) || subjectsOf.has(r.id)
  const canSignIn = here.filter((r) => r.login_active === true)
  // A class teacher or subject teacher with no working login cannot mark the
  // register or enter marks, and nothing anywhere said so: the class simply
  // went unmarked.
  const stuck = here.filter((r) => teaching(r) && r.login_active !== true)
  const left = rows.filter((r) => r.status !== 'active')
  const designations = [...new Set(rows.map((r) => (r.designation ?? '').trim()).filter(Boolean))].sort()

  const term = q.trim().toLowerCase()
  const shown = rows.filter((r) => {
    if (filter === 'teaching' && !(r.status === 'active' && teaching(r))) return false
    if (filter === 'stuck' && !(r.status === 'active' && teaching(r) && r.login_active !== true)) return false
    if (filter === 'nologin' && !(r.status === 'active' && r.login_active !== true)) return false
    if (filter === 'left' && r.status === 'active') return false
    if (filter === 'everyone' && r.status !== 'active' && !term) return false
    if (!term) return true
    return [r.full_name, r.designation, r.employee_no, r.mobile, r.cnic, r.class_teacher_of]
      .some((v) => (v ?? '').toLowerCase().includes(term))
  })

  const parts: Segment[] = [
    { key: 'in', label: 'Can sign in', value: canSignIn.length, color: C.series },
    { key: 'closed', label: 'Login closed', value: here.filter((r) => r.login_active === false).length, color: C.warn },
    { key: 'none', label: 'No login', value: here.filter((r) => r.login_active === null).length, color: C.none },
  ]

  return (
    <div className="space-y-5">
      <LoadError of={[staff, profiles]} what="The staff list" />

      {!mayWrite && <ObserverNotice what="staff records" />}

      {/* ---------------------------------------------------- the numbers -- */}
      {staff.data && (
        <div className="grid grid-cols-2 gap-3 lg:grid-cols-4">
          <RosterTile n={here.length} title="On the staff" sub={`${here.filter(teaching).length} of them teach a class or subject`} tone="brand" />
          <RosterTile n={canSignIn.length} title="Can sign in"
            sub={here.length - canSignIn.length > 0 ? `${here.length - canSignIn.length} cannot: show them` : 'Everybody here can'} tone="plain"
            onClick={here.length - canSignIn.length > 0 ? () => setFilter('nologin') : undefined} />
          <RosterTile n={stuck.length} title="Teachers who cannot sign in"
            sub={stuck.length ? 'Nobody can mark their register or enter their marks.' : 'Every teacher can sign in.'}
            tone={stuck.length ? 'due' : 'plain'} onClick={stuck.length ? () => setFilter('stuck') : undefined} />
          <RosterTile n={left.length} title="Have left" sub="Kept, with everything they did" tone="plain"
            onClick={left.length ? () => setFilter('left') : undefined} />
        </div>
      )}
      {here.length > 0 && (
        <div className="rounded-2xl border border-slate-200 bg-white px-4 py-3 shadow-card">
          <StackBar parts={parts} total={here.length} height={8}
            label={`Staff logins: ${parts.map((p) => `${p.label} ${p.value}`).join(', ')}`} />
          <ul className="mt-2 flex flex-wrap gap-x-4 gap-y-1 text-xs text-slate-600">
            {parts.map((p) => (
              <li key={p.key} className="inline-flex items-center gap-1.5">
                <span className="h-2.5 w-2.5 rounded-sm" style={{ background: p.color }} aria-hidden />
                {p.label} <b className="font-semibold tabular-nums text-slate-900">{p.value}</b>
              </li>
            ))}
          </ul>
        </div>
      )}

      {/* ONE button, where there were two. "+ Add staff" wrote a staff row and
          "+ Add teacher login" wrote a profiles row, and the office was left to
          work out that a teacher needs both and then join them by hand. */}
      {!editing && !adding && mayWrite && (
        <div className="flex flex-wrap items-center gap-2">
          <Button onClick={() => setAdding(true)}>+ Add someone</Button>
        </div>
      )}

      {adding && mayWrite && (
        <AddPerson
          designations={designations}
          onDone={() => {
            setAdding(false)
            invalidate()
            qc.invalidateQueries({ queryKey: ['profiles'] })
            qc.invalidateQueries({ queryKey: ['schoolLogins'] })
          }}
          onFlash={setFlash}
        />
      )}

      <UnattachedLogins canLink={canLink} staff={rows} />

      {editing && (
        <form className="rounded-2xl border border-brand-200 bg-white p-4 shadow-raised" onSubmit={(e) => { e.preventDefault(); if (form.full_name.trim()) save.mutate() }}>
          <div className="text-xs font-semibold uppercase tracking-wide text-slate-500">{editing === 'new' ? 'New staff member' : `Edit ${editingRow?.full_name ?? 'staff'}`}</div>

          {/* Only for a saved record: the photograph is stored under the staff
              id, so there is nowhere to put it until the row exists. */}
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

          <StaffFields form={form} setForm={setForm} designations={designations} whatsapp />
          {save.isError && <p className="mt-2 text-sm text-danger-600">{(save.error as Error).message}</p>}
          <div className="mt-3 flex gap-2">
            <Button type="submit" disabled={!form.full_name.trim() || save.isPending}>{save.isPending ? 'Saving…' : 'Save'}</Button>
            <Button type="button" variant="soft" tone="neutral" onClick={() => { setEditing(null); setForm(BLANK) }}>Cancel</Button>
          </div>
        </form>
      )}

      {flash && (
        <div className="flex items-start justify-between gap-3 rounded-xl border border-brand-200 bg-brand-50 px-4 py-3 text-sm text-brand-800">
          <span>{flash}</span>
          <button onClick={() => setFlash(null)} className={buttonClass({ variant: 'soft', tone: 'neutral', size: 'sm', className: 'shrink-0' })}>Dismiss</button>
        </div>
      )}

      {/* Anyone recorded as having left whose login still works. 0053 refuses
          to fix this silently: it cannot tell "resigned in March" from "the old
          Deactivate button was clicked by mistake". So the school decides. */}
      {(() => {
        const stranded = rows.filter((s) => s.status !== 'active' && s.login_active === true)
        if (!stranded.length || !canLink) return null
        return (
          <div className="rounded-xl border border-danger-200 bg-danger-50 p-4 text-sm">
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

      {/* ------------------------------------------------ find and filter -- */}
      <div className="flex flex-wrap items-center gap-2">
        <input value={q} onChange={(e) => setQ(e.target.value)} placeholder="Find by name, number, phone or class"
          className={`${inputClass} min-w-0 flex-1 sm:max-w-sm`} aria-label="Find staff" />
        <div className="flex flex-wrap gap-1">
          {([['everyone', 'Everyone here'], ['teaching', 'Teachers'],
             ...(stuck.length ? [['stuck', 'Teachers without a login']] as const : []),
             ['nologin', 'Cannot sign in'], ['left', 'Have left']] as const).map(([k, l]) => (
            <button key={k} type="button" aria-pressed={filter === k} onClick={() => setFilter(k)}
              className={`rounded-full px-3 py-1 text-sm font-medium ring-1 ${filter === k ? 'bg-brand-600 text-white ring-brand-600' : 'bg-white text-slate-600 ring-slate-300 hover:bg-slate-50'}`}>
              {l}
            </button>
          ))}
        </div>
      </div>

      {staff.isLoading && <p className="text-sm text-slate-500">Loading…</p>}
      {staff.data?.length === 0 && (
        <p className="rounded-xl border border-dashed border-slate-300 bg-white px-4 py-6 text-center text-sm text-slate-500">
          No staff yet. &ldquo;Add someone&rdquo; puts the first person on the list.
        </p>
      )}
      {staff.data && staff.data.length > 0 && shown.length === 0 && (
        <p className="rounded-xl bg-slate-50 px-4 py-4 text-sm text-slate-500">Nobody matches.</p>
      )}

      <ul className="space-y-2">
        {shown.map((s) => {
          const logins = (profiles.data ?? []).filter((p) =>
            // Never a parent's login: 0148 refuses it too. And never one that
            // belongs to somebody else on the list.
            p.role !== 'parent' && (!p.staff_id || p.id === s.profile_id))
          const onRoll = s.status === 'active'
          const email = emailOf(s.profile_id)
          const cannotMark = onRoll && teaching(s) && s.login_active !== true
          return (
            <li key={s.id}
              className={`rounded-2xl border bg-white p-3 shadow-card sm:p-4 ${onRoll ? 'border-slate-200' : 'border-slate-200 bg-slate-50/70'}`}>
              <div className="flex flex-wrap items-start gap-3">
                <Avatar name={s.full_name} url={faces.get(s.photo_path ?? '') ?? null} size="md" />
                <div className="min-w-0 flex-1">
                  <div className="flex flex-wrap items-baseline gap-x-2 gap-y-0.5">
                    <span className={`font-semibold ${onRoll ? 'text-slate-900' : 'text-slate-500'}`}>{s.full_name}</span>
                    {s.employee_no && <span className="text-xs text-slate-400">#{s.employee_no}</span>}
                    {!onRoll && (
                      <span className="rounded bg-slate-200 px-1.5 py-0.5 text-[11px] font-medium text-slate-600">
                        left{s.left_on ? ` ${fmtDate(s.left_on)}` : ''}
                      </span>
                    )}
                  </div>
                  <div className="text-sm text-slate-600">
                    {s.designation || <span className="text-slate-400">No designation</span>}
                    {s.mobile ? <span className="text-slate-400"> · {s.mobile}</span> : null}
                  </div>
                  {/* Named, not counted: "Class 1-A, Class 2-B" is what the
                      principal needs in order to reassign. */}
                  {onRoll && teaching(s) && (() => {
                    const cls = classOf.get(s.id) ?? (s.class_teacher_of ? [s.class_teacher_of] : [])
                    const subs = subjectsOf.get(s.id) ?? []
                    return (
                      <div className="mt-1.5 flex flex-wrap gap-1.5 text-xs">
                        {cls.length > 0 && (
                          <span className="rounded-full bg-brand-50 px-2 py-0.5 font-medium text-brand-700 ring-1 ring-brand-100">
                            Class teacher · {cls.join(', ')}
                          </span>
                        )}
                        {subs.slice(0, 3).map((x) => (
                          <span key={x} className="rounded-full bg-slate-100 px-2 py-0.5 text-slate-700">{x}</span>
                        ))}
                        {subs.length > 3 && (
                          <span className="rounded-full bg-slate-100 px-2 py-0.5 text-slate-500" title={subs.slice(3).join(', ')}>
                            and {subs.length - 3} more
                          </span>
                        )}
                      </div>
                    )
                  })()}
                </div>

                {/* ------------------------------------------- the login -- */}
                <div className="w-full min-w-0 sm:w-72">
                  <LoginBadge row={s} email={email} />
                  {cannotMark && (
                    <p className="mt-1 text-xs font-medium text-due-800">
                      Teaches, but cannot sign in: nobody can mark their class from their phone.
                    </p>
                  )}
                  <LoginState row={s} canLink={canLink}
                    onOpen={() => login.mutate({ id: s.id, active: true, reason: null })}
                    onClose={() => login.mutate({ id: s.id, active: false, reason: null })}
                    onGive={() => setGiveLoginFor(s)}
                    onChange={logins.length > 0 ? () => setPicking(picking === s.id ? null : s.id) : undefined}
                    changing={picking === s.id} />
                  {canLink && picking === s.id && logins.length > 0 && (
                    <label className="mt-1.5 block">
                      <span className="sr-only">Attached login for {s.full_name}</span>
                      <select value={s.profile_id ?? ''}
                        onChange={(e) => { setPicking(null); setRelinking({ row: s, profileId: e.target.value || null }) }}
                        className="w-full rounded-lg border border-slate-300 bg-white px-2 py-1.5 text-xs text-slate-700 focus:border-brand-500 focus:outline-none">
                        <option value="">{s.profile_id ? 'Detach this login' : 'Choose a login…'}</option>
                        {logins.map((p) => (
                          <option key={p.id} value={p.id}>
                            {p.full_name || '(unnamed)'}
                            {emailOf(p.id) ? ` · ${emailOf(p.id)}` : ''}
                            {' · '}{ROLE_LABELS[p.role as Role] ?? p.role}
                          </option>
                        ))}
                      </select>
                    </label>
                  )}
                </div>
              </div>

              {/* ------------------------------------------------ actions -- */}
              <div className="mt-3 flex flex-wrap gap-1.5 border-t border-slate-100 pt-2.5">
                {mayWrite && <Button size="sm" variant="soft" tone="brand" onClick={() => startEdit(s)}>Edit</Button>}
                {/* Attendance and ID card are reads and an observer keeps both. */}
                <Button size="sm" variant="soft" tone="neutral" onClick={() => setAttFor(s)}>Attendance</Button>
                <Button size="sm" variant="soft" tone="neutral" onClick={() => setIdCard(s)}>ID card</Button>
                <span className="ml-auto flex flex-wrap gap-1.5">
                {/* Two different actions people confuse. "Left the school" is
                    for somebody who really left and keeps every register and
                    payslip they touched. "Remove" is for a row typed in by
                    mistake, and it refuses the moment anything is attached. */}
                {canLink && (onRoll ? (
                  <Button size="sm" variant="ghost" onClick={() => setLeaving(s)}>Left the school</Button>
                ) : (
                  <Button size="sm" variant="ghost" onClick={() => rejoin.mutate({ id: s.id, reason: null })}
                    disabled={rejoin.isPending}>Rejoined</Button>
                ))}
                {canLink && (
                  <button onClick={() => setRemoving(s)}
                    className="rounded-lg px-2.5 py-1.5 text-xs font-medium text-danger-700 hover:bg-danger-50">
                    Remove
                  </button>
                )}
                </span>
              </div>
            </li>
          )
        })}
      </ul>
      {filter === 'everyone' && !term && left.length > 0 && (
        <p className="text-xs text-slate-500">
          {left.length} {left.length === 1 ? 'person who has left is' : 'people who have left are'} not shown.{' '}
          <button type="button" onClick={() => setFilter('left')} className={buttonClass({ variant: 'soft', size: 'sm', className: 'ml-1' })}>Show them</button>
        </p>
      )}
      {link.isError && !relinking && <p className="text-sm text-danger-600">{(link.error as Error).message}</p>}
      {rejoin.isError && <p className="text-sm text-danger-600">{(rejoin.error as Error).message}</p>}
      {login.isError && <p className="text-sm text-danger-600">{(login.error as Error).message}</p>}

      {relinking && (
        <AskDialog
          title={relinking.profileId ? `Attach this login to ${relinking.row.full_name}?` : `Detach ${relinking.row.full_name}'s login?`}
          intro={relinking.profileId ? (
            <>They will sign in as <b>{emailOf(relinking.profileId) ?? 'that login'}</b> and get whatever it can do,
              including any class they teach. Only do this if that address is theirs.</>
          ) : (
            <>{relinking.row.full_name} will not be able to sign in until a login is attached again. The login itself is
              kept, and shows under &ldquo;logins not attached&rdquo; so it can be given back.</>
          )}
          confirmLabel={relinking.profileId ? 'Attach it' : 'Detach it'}
          tone={relinking.profileId ? 'brand' : 'danger'}
          busy={link.isPending}
          error={link.error ? (link.error as Error).message : null}
          onCancel={() => { setRelinking(null); link.reset() }}
          onSubmit={() => link.mutate({ id: relinking.row.id, profileId: relinking.profileId })}
        />
      )}
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
                ? ` ${r.sections_vacated} ${r.sections_count === 1 ? 'now has' : 'now have'} no class teacher: assign somebody on the Class Teachers tab.`
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
      {giveLoginFor && (
        <GiveLoginDialog
          staff={giveLoginFor}
          onClose={() => setGiveLoginFor(null)}
          onDone={(msg) => { setGiveLoginFor(null); setFlash(msg); invalidate(); qc.invalidateQueries({ queryKey: ['schoolLogins'] }) }}
        />
      )}
    </div>
  )
}

function RosterTile({ n, title, sub, tone, onClick }: {
  n: number; title: string; sub: string; tone: 'brand' | 'due' | 'plain'; onClick?: () => void
}) {
  const skin = tone === 'brand' ? 'border-brand-200 bg-brand-50 text-brand-900'
    : tone === 'due' ? 'border-due-200 bg-due-50 text-due-900'
    : 'border-slate-200 bg-white text-slate-900'
  const Tag = onClick ? 'button' : 'div'
  return (
    <Tag {...(onClick ? { type: 'button' as const, onClick } : {})}
      className={`rounded-2xl border px-4 py-3 text-left ${skin} ${onClick ? 'transition hover:shadow-raised' : ''}`}>
      <div className="text-2xl font-semibold tabular-nums">{n}</div>
      <div className="text-sm font-medium">{title}</div>
      <div className="mt-0.5 text-xs opacity-75">{sub}</div>
    </Tag>
  )
}

/** The login at a glance: the address, and what it can do. */
function LoginBadge({ row, email }: { row: StaffRosterRow; email: string | null }) {
  if (row.login_active === null) {
    return <div className="text-xs font-medium uppercase tracking-wide text-slate-400">No login</div>
  }
  return (
    <div className="min-w-0">
      <div className={`text-xs font-medium uppercase tracking-wide ${row.login_active ? 'text-brand-700' : 'text-due-800'}`}>
        {row.login_active ? 'Signs in' : 'Login closed'}
        {row.login_role ? ` · ${ROLE_LABELS[row.login_role as Role] ?? row.login_role}` : ''}
      </div>
      {email && <div className="truncate text-sm text-slate-700">{email}</div>}
    </div>
  )
}

/** The person's fields, once, for both Add and Edit. A datalist of the
 *  designations already in use nudges "teacher", "Teacher" and "Class Teacher"
 *  towards one spelling, which the roster filters and ID cards read. */
function StaffFields({ form, setForm, designations, whatsapp }: {
  form: StaffInput; setForm: (f: StaffInput) => void; designations: string[]; whatsapp?: boolean
}) {
  const f = (k: keyof StaffInput) => (e: React.ChangeEvent<HTMLInputElement>) => setForm({ ...form, [k]: e.target.value })
  return (
    <div className="mt-3 grid gap-3 sm:grid-cols-2 lg:grid-cols-3">
      <label className="block sm:col-span-2"><span className="text-sm text-slate-600">Full name</span>
        <input value={form.full_name} onChange={f('full_name')} className={FIELD} autoFocus /></label>
      <label className="block"><span className="text-sm text-slate-600">Designation</span>
        <input value={form.designation ?? ''} onChange={f('designation')} className={FIELD}
          placeholder="e.g. Senior Teacher" list="staff-designations" />
        <datalist id="staff-designations">{designations.map((d) => <option key={d} value={d} />)}</datalist></label>
      <label className="block"><span className="text-sm text-slate-600">Employee #</span>
        <input value={form.employee_no ?? ''} onChange={f('employee_no')} className={FIELD} /></label>
      <label className="block"><span className="text-sm text-slate-600">Mobile</span>
        <input value={form.mobile ?? ''} onChange={f('mobile')} className={FIELD} inputMode="tel" /></label>
      {whatsapp && (
        <label className="block"><span className="text-sm text-slate-600">WhatsApp</span>
          <input value={form.whatsapp ?? ''} onChange={f('whatsapp')} className={FIELD} inputMode="tel" /></label>
      )}
      <label className="block"><span className="text-sm text-slate-600">CNIC</span>
        <input value={form.cnic ?? ''} onChange={f('cnic')} className={FIELD} placeholder="35201-1234567-1" /></label>
      <label className="block"><span className="text-sm text-slate-600">Joined on</span>
        <input type="date" value={form.joined_on ?? ''} max={todayISO()} onChange={f('joined_on')} className={FIELD} /></label>
      <label className="block"><span className="text-sm text-slate-600">Date of birth</span>
        {/* Feeds the Birthdays screen. */}
        <input type="date" value={form.dob ?? ''} max={todayISO()} onChange={f('dob')} className={FIELD} /></label>
    </div>
  )
}

/** What can be done about this person's login, in one line of plain actions.
 *
 *  Three states, not two: no account, account switched off, account working.
 *  The old screen showed none of them, which is how a resigned teacher kept
 *  working access. The badge above says which state; this says what to do. */
function LoginState({ row, canLink, onOpen, onClose, onGive, onChange, changing }: {
  row: StaffRosterRow; canLink: boolean
  onOpen: () => void; onClose: () => void; onGive: () => void
  onChange?: () => void; changing: boolean
}) {
  if (!canLink || row.status !== 'active') return null
  const go = buttonClass({ variant: 'soft', size: 'sm' })
  const quiet = buttonClass({ variant: 'soft', tone: 'neutral', size: 'sm' })
  return (
    <div className="mt-2 flex flex-wrap gap-2 text-xs">
      {row.login_active === null && <button onClick={onGive} className={go}>Give a login</button>}
      {row.login_active === true && <button onClick={onClose} className={quiet}>Suspend</button>}
      {/* Reopening is offered only for somebody who is still on the staff:
          reopening a departed person's login would leave the two facts
          contradicting each other, and SQL refuses it anyway. */}
      {row.login_active === false && <button onClick={onOpen} className={go}>Reopen</button>}
      {onChange && (
        <button onClick={onChange} aria-expanded={changing} className={quiet}>
          {changing ? 'Keep it as it is' : row.profile_id ? 'Change login' : 'Attach an existing login'}
        </button>
      )}
    </div>
  )
}

/**
 * Give a loginless staff member a login, later, from their row.
 *
 * Mirrors the parent-portal generator: a first-name-plus-number address and a
 * number password are SUGGESTED so the office can accept them with one press,
 * and both are editable because a teacher, unlike a parent, often has a real
 * address they would rather use. The credentials go through the same
 * createTeacherLogin -> linkStaffProfile path the New Staff form uses, so there
 * is one implementation of "make a staff login" and it cannot drift.
 */
export function suggestStaffEmail(name: string, number: string | null): string {
  const first = (name.trim().split(/\s+/)[0] ?? '').toLowerCase().replace(/[^a-z0-9]/g, '')
  const num = (number ?? '').replace(/[^0-9]/g, '')
  if (!first || !num) return ''
  return `${first.slice(0, 30)}${num.slice(0, 30)}@gmail.com`
}

function GiveLoginDialog({ staff, onClose, onDone }: {
  staff: StaffRosterRow; onClose: () => void; onDone: (msg: string) => void
}) {
  const number = staff.mobile || staff.whatsapp || null
  const [email, setEmail] = useState(suggestStaffEmail(staff.full_name, number))
  const [password, setPassword] = useState((number ?? '').replace(/[^0-9]/g, ''))
  const [role, setRole] = useState<Role>('class_teacher')
  const [err, setErr] = useState<string | null>(null)

  const go = useMutation({
    mutationFn: async () => {
      const created = await createTeacherLogin({
        email: email.trim(), password, full_name: staff.full_name, role,
      })
      try {
        await linkStaffProfile(staff.id, created.id)
      } catch (e) {
        throw new Error(
          `${staff.full_name} can now sign in as ${created.email}, but joining that `
          + `login to their staff record failed: ${(e as Error).message} Attach it from `
          + `"logins not attached to anybody" above; do not create it again.`)
      }
      return created
    },
    onSuccess: (r) => onDone(
      `${staff.full_name} can now sign in as ${r.email}.`
      + (r.remembered === false
        ? ' Write the password down now: this database has no key ring yet (bundle 22).'
        : ' The password is saved under Settings, Users.')),
    onError: (e) => setErr((e as Error).message),
  })

  const passwordOk = password.length >= 6
  const emailOk = /.+@.+\..+/.test(email.trim())

  return (
    <div className="fixed inset-0 z-50 flex items-start justify-center overflow-y-auto bg-slate-900/40 p-4" role="dialog" aria-modal="true"
      aria-label={`Give ${staff.full_name} a login`}>
      <div className="mt-16 w-full max-w-md rounded-2xl bg-white p-5 shadow-pop">
        <h2 className="text-base font-semibold text-slate-800">Give {staff.full_name} a login</h2>
        <p className="mt-1 text-xs text-slate-500">
          We have suggested an address and password from their phone number. Change either if
          you like. They can sign in the moment you save.
        </p>

        <label className="mt-4 block"><span className="text-sm text-slate-600">Email / username</span>
          <input value={email} onChange={(e) => setEmail(e.target.value.trim())} className={FIELD}
            placeholder="teacher0333xxxxxxx@gmail.com" autoComplete="off" />
        </label>
        <label className="mt-3 block"><span className="text-sm text-slate-600">Password</span>
          <input value={password} onChange={(e) => setPassword(e.target.value)} className={FIELD}
            autoComplete="off" />
          {!passwordOk && <span className="mt-1 block text-xs text-due-800">At least 6 characters.</span>}
        </label>
        <label className="mt-3 block"><span className="text-sm text-slate-600">They sign in as</span>
          <select value={role} onChange={(e) => setRole(e.target.value as Role)} className={FIELD}>
            {STAFF_ROLES.map((r) => <option key={r} value={r}>{ROLE_LABELS[r] ?? r}</option>)}
          </select>
        </label>

        {err && <p className="mt-3 rounded-lg bg-danger-50 px-3 py-2 text-sm text-danger-700">{err}</p>}

        <div className="mt-4 flex gap-2">
          <Button className="flex-1" onClick={() => { setErr(null); go.mutate() }}
            disabled={go.isPending || !emailOk || !passwordOk}>
            {go.isPending ? 'Creating…' : 'Create the login'}
          </Button>
          <Button className="flex-1" variant="soft" tone="neutral" onClick={onClose}>Cancel</Button>
        </div>
      </div>
    </div>
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
    <div className="fixed inset-0 z-50 flex items-start justify-center overflow-y-auto bg-slate-900/40 p-4" role="dialog" aria-modal="true"
      aria-label={`${row.full_name} has left`}>
      <div className="mt-16 w-full max-w-md rounded-2xl bg-white p-5 shadow-pop">
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
            placeholder="e.g. Resigned: moved to Lahore" />
        </label>

        <div className="mt-4 rounded-xl bg-slate-50 p-3 text-xs text-slate-600">
          <p className="font-medium text-slate-700">Saving this will:</p>
          <ul className="mt-1 space-y-1">
            <li>
              {row.login_active === true
                ? '• close their login straight away. They will not be able to sign in'
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

        {go.isError && <p className="mt-3 rounded-lg bg-danger-50 px-3 py-2 text-sm text-danger-700">{(go.error as Error).message}</p>}

        <div className="mt-4 flex justify-end gap-2">
          <Button variant="soft" tone="neutral" onClick={onClose}>Cancel</Button>
          <Button onClick={() => go.mutate()} disabled={go.isPending || !leftOn}>
            {go.isPending ? 'Saving…' : 'Record leaving'}
          </Button>
        </div>
      </div>
    </div>
  )
}

/** The day's colour, from the same palette as every attendance ring in the app. */
const DAY_SKIN: Record<string, string> = {
  present: 'bg-money-50 text-money-800 ring-money-200',
  late: 'bg-due-50 text-due-800 ring-due-200',
  half_day: 'bg-due-50 text-due-800 ring-due-200',
  absent: 'bg-danger-50 text-danger-800 ring-danger-200',
  leave: 'bg-info-50 text-info-800 ring-info-200',
}

/**
 * One person's month, as a calendar.
 *
 * It was a line of initials ("P 18 · A 2 · L 1 · Lt 0 · ½ 0") over a two-column
 * list of dates, which answered "how many" and hid "which days". A principal
 * looking at a teacher's month wants to see that the absences are all Mondays.
 */
function StaffAttendanceModal({ staff, onClose }: { staff: StaffRow; onClose: () => void }) {
  const schoolName = useSchoolName()
  const months = useMemo(() => lastSixMonths(), [])
  const [month, setMonth] = useState(months[0])
  const first = `${month}-01`
  const [yy, mm] = month.split('-').map(Number)
  const daysIn = new Date(yy, mm, 0).getDate()
  const last = `${month}-${String(daysIn).padStart(2, '0')}`

  const summary = useQuery({ queryKey: ['staffAttSummary', staff.id, month], queryFn: () => getStaffAttendanceSummary(staff.id, first, last) })
  const days = useQuery({ queryKey: ['staffAttDays', staff.id, month], queryFn: () => getStaffMonthAttendance(staff.id, month) })
  const d = summary.data
  const byDay = new Map((days.data ?? []).map((x) => [x.attendance_date, x.status]))
  // Monday first, the way a Pakistani school's register is ruled.
  const lead = (new Date(yy, mm - 1, 1).getDay() + 6) % 7
  const today = todayISO()
  const parts = attendanceParts({
    present: d?.present ?? 0, late: d?.late ?? 0, half_day: d?.half_day ?? 0,
    leave: d?.leave ?? 0, absent: d?.absent ?? 0, marked: d?.marked_days ?? 0,
  })

  return (
    <div className="fixed inset-0 z-50 flex items-start justify-center overflow-y-auto bg-slate-900/40 p-4 print:static print:block print:bg-white print:p-0"
      role="dialog" aria-modal="true" aria-label={`${staff.full_name}: attendance`}>
      <div className="mt-10 w-full max-w-lg rounded-2xl bg-white p-5 shadow-pop sm:p-6 print:mt-0 print:max-w-none print:shadow-none" id="report">
        <div className="text-center">
          <div className="text-lg font-semibold text-slate-800">{schoolName}</div>
          <div className="text-xs uppercase tracking-wide text-slate-500">Staff attendance · {monthLabel(month)}</div>
        </div>
        <div className="mt-3 flex flex-wrap items-center justify-between gap-2">
          <div className="min-w-0 text-sm text-slate-700">
            <span className="font-semibold text-slate-900">{staff.full_name}</span>
            {staff.designation ? <span className="text-slate-500"> · {staff.designation}</span> : null}
          </div>
          <select value={month} onChange={(e) => setMonth(e.target.value)} aria-label="Month"
            className="rounded-lg border border-slate-300 px-2 py-1 text-sm print:hidden">
            {months.map((m) => <option key={m} value={m}>{monthLabel(m)}{m === ymNow() ? ' (this month)' : ''}</option>)}
          </select>
        </div>

        {summary.isError && <p className="mt-3 rounded-lg bg-danger-50 px-3 py-2 text-sm text-danger-700">{(summary.error as Error).message}</p>}
        <div className="mt-4 flex items-center gap-4 rounded-xl border border-slate-200 p-3">
          <div className="shrink-0 text-center">
            <div className="text-3xl font-semibold tabular-nums text-slate-900">{d?.present_pct == null ? '-' : `${d.present_pct}%`}</div>
            <div className="text-[11px] uppercase tracking-wide text-slate-500">present</div>
          </div>
          <div className="min-w-0 flex-1">
            <StackBar parts={parts} total={Math.max(d?.marked_days ?? 0, 1)} height={8}
              label={`${parts.map((p) => `${p.label} ${p.value}`).join(', ')}`} />
            <ul className="mt-2 flex flex-wrap gap-x-3 gap-y-1 text-xs text-slate-600">
              {parts.map((p) => (
                <li key={p.key} className="inline-flex items-center gap-1">
                  <span className="h-2 w-2 rounded-sm" style={{ background: p.color }} aria-hidden />
                  {p.label} <b className="tabular-nums text-slate-900">{p.value}</b>
                </li>
              ))}
            </ul>
            <p className="mt-1 text-[11px] text-slate-500">Out of {d?.marked_days ?? 0} marked {(d?.marked_days ?? 0) === 1 ? 'day' : 'days'}.</p>
          </div>
        </div>

        <div className="mt-4">
          {days.isLoading ? <p className="text-sm text-slate-400">Loading the month…</p> : days.isError ? (
            <p className="rounded-lg bg-danger-50 px-3 py-2 text-sm text-danger-700">{(days.error as Error).message}</p>
          ) : (
            <>
              <div className="grid grid-cols-7 gap-1 text-center text-[10px] font-semibold uppercase tracking-wide text-slate-400">
                {['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'].map((w) => <div key={w}>{w}</div>)}
              </div>
              <div className="mt-1 grid grid-cols-7 gap-1">
                {Array.from({ length: lead }).map((_, i) => <div key={`x${i}`} aria-hidden />)}
                {Array.from({ length: daysIn }).map((_, i) => {
                  const iso = `${month}-${String(i + 1).padStart(2, '0')}`
                  const st = byDay.get(iso)
                  const future = iso > today
                  return (
                    <div key={iso} title={`${fmtDate(iso)}: ${st ? (ATTENDANCE_LABELS[st] ?? st) : future ? 'not yet' : 'not marked'}`}
                      className={`flex aspect-square flex-col items-center justify-center rounded-lg text-xs ring-1 ${
                        st ? DAY_SKIN[st] ?? 'bg-slate-50 text-slate-700 ring-slate-200'
                          : future ? 'bg-white text-slate-300 ring-slate-100' : 'bg-slate-50 text-slate-400 ring-slate-100'}`}>
                      <span className="tabular-nums">{i + 1}</span>
                      <span className="text-[10px] font-semibold leading-none">{st ? ATTENDANCE_SHORT[st] ?? '' : ''}</span>
                    </div>
                  )
                })}
              </div>
              {(days.data?.length ?? 0) === 0 && (
                <p className="mt-2 text-center text-xs text-slate-500">Nothing recorded for {staff.full_name} in {monthLabel(month)}.</p>
              )}
            </>
          )}
        </div>

        <div className="mt-6 flex gap-2 print:hidden">
          <Button className="flex-1" onClick={() => window.print()}>Print or save as PDF</Button>
          <Button className="flex-1" variant="soft" tone="neutral" onClick={onClose}>Close</Button>
        </div>
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
  const { session } = useAuth()
  const qc = useQueryClient()
  const [removing, setRemoving] = useState<SchoolLogin | null>(null)
  // Picked, then attached with a button. The select attached on change, so a
  // slip on a phone joined the login to whoever was next in the list.
  const [pick, setPick] = useState<Record<string, string>>({})
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
      setPick({})
      qc.invalidateQueries({ queryKey: ['schoolLogins'] })
      qc.invalidateQueries({ queryKey: ['staff'] })
      qc.invalidateQueries({ queryKey: ['profiles'] })
    },
  })

  if (!canLink) return null
  const all = (logins.data ?? []).filter((l) => !l.staff_id)
  // WHO IS READING THIS SCREEN. The owner's own login is in this list on every
  // school, because signing up creates a login and no staff record, and there
  // is nothing wrong with that: a proprietor is not necessarily on the roster.
  // What was wrong was offering them "Remove" for it. fn_delete_login refuses
  // both ways round -- you cannot delete the login you are signed in with, and
  // you cannot delete the last owner -- so the button could only ever produce
  // an error. A button whose only outcome is a refusal teaches the office to
  // distrust the buttons that do work.
  const myId = session?.user?.id ?? null
  // A PARENT login in this list means one thing only: 0104 includes a parent
  // whose family link was never written, and excludes every parent who has one.
  // They need a family, not a staff record, so they get their own wording and
  // their own actions. Mixing them in with "Attach to a staff member" would
  // offer the office a repair that is wrong for them.
  const parents = all.filter((l) => l.role === 'parent')
  // NOT THE OWNER. Signing up makes the owner a login and no staff record, on
  // every school, and a proprietor need not be on the roster. Listing them made
  // this box appear on every school's staff screen for ever, naming the person
  // reading it, with "Attach to..." beside a login that belongs to nobody else.
  // An owner who also teaches attaches their login from their own row.
  const loose = all.filter((l) => l.role !== 'parent' && l.role !== 'owner')
  if (logins.isError) {
    return (
      <p className="rounded-lg border border-danger-200 bg-danger-50 px-3 py-2 text-sm text-danger-800">
        Could not check for unattached logins: {(logins.error as Error).message}
      </p>
    )
  }
  if (!loose.length && !parents.length) return null

  const free = staff.filter((s) => !s.profile_id && s.status === 'active')

  return (
    <>
    {parents.length > 0 && (
      <div className="rounded-2xl border border-danger-200 bg-danger-50 p-4">
        <p className="text-sm font-semibold text-danger-900">
          {parents.length === 1
            ? 'One parent login belongs to no family'
            : `${parents.length} parent logins belong to no family`}
        </p>
        <p className="mt-1 text-sm text-danger-800">
          They can sign in, and the portal shows them their own name above an empty
          page: no children, no fees, nothing. It happens when a login is created
          but the family link does not get written.
          <br />
          Open the child&rsquo;s profile and press <b>Attach to this family</b> in the
          Parent portal box. Do not try to create the login again: the address is
          already taken and it will be refused. Or remove it here to free the address.
        </p>
        <ul className="mt-3 space-y-2">
          {parents.map((l) => (
            <li key={l.profile_id}
                className="flex flex-wrap items-center justify-between gap-2 rounded-lg bg-white px-3 py-2">
              <div className="min-w-0">
                <span className="text-sm font-medium text-slate-800">{l.full_name || '(no name)'}</span>
                <span className="ml-2 text-xs text-slate-500">{l.email}</span>
                <span className="ml-2 rounded bg-slate-100 px-1.5 py-0.5 text-[11px] font-medium text-slate-600">
                  Parent
                </span>
                {!l.active && (
                  <span className="ml-2 rounded bg-slate-200 px-1.5 py-0.5 text-[11px] text-slate-600">closed</span>
                )}
              </div>
              <button onClick={() => setRemoving(l)}
                className="rounded border border-slate-300 bg-white px-2 py-1 text-xs font-medium text-slate-600 hover:bg-slate-50">
                Remove
              </button>
            </li>
          ))}
        </ul>
      </div>
    )}
    {loose.length > 0 && (
    <div className="rounded-2xl border border-due-200 bg-due-50 p-4">
      <p className="text-sm font-semibold text-due-900">
        {loose.length === 1
          ? 'One login is not attached to anybody on the staff list'
          : `${loose.length} logins are not attached to anybody on the staff list`}
      </p>
      <p className="mt-1 text-sm text-due-800">
        They can sign in, but they have no staff record, so they are not on the list
        below, cannot be given a class, and have no attendance or ID card. Attach each
        one to its person, or remove it.
      </p>
      <ul className="mt-3 space-y-2">
        {loose.map((l) => (
          <li key={l.profile_id}
              className="flex flex-wrap items-center justify-between gap-2 rounded-xl bg-white px-3 py-2.5 shadow-card">
            <div className="min-w-0">
              <div className="flex flex-wrap items-center gap-1.5">
                <span className="text-sm font-medium text-slate-800">{l.full_name || '(no name)'}</span>
                <span className="rounded-full bg-slate-100 px-2 py-0.5 text-[11px] font-medium text-slate-600">
                  {ROLE_LABELS[l.role as Role] ?? l.role}
                </span>
                {!l.active && (
                  <span className="rounded-full bg-slate-200 px-2 py-0.5 text-[11px] text-slate-600">closed</span>
                )}
              </div>
              {/* The address, which no screen in this app could show before. */}
              <div className="truncate text-xs text-slate-500">{l.email}</div>
            </div>
            <div className="flex w-full flex-wrap items-center gap-2 sm:w-auto">
              {free.length > 0 ? (
                <>
                  <select value={pick[l.profile_id] ?? ''} aria-label={`Attach ${l.email ?? 'this login'} to`}
                    onChange={(e) => setPick({ ...pick, [l.profile_id]: e.target.value })}
                    className="min-w-0 flex-1 rounded-lg border border-slate-300 px-2 py-1.5 text-sm focus:border-brand-500 focus:outline-none sm:flex-none">
                    <option value="">Whose login is this?</option>
                    {free.map((s) => <option key={s.id} value={s.id}>{s.full_name}</option>)}
                  </select>
                  <Button size="sm" disabled={!pick[l.profile_id] || attach.isPending}
                    onClick={() => attach.mutate({ staffId: pick[l.profile_id], profileId: l.profile_id })}>
                    Attach
                  </Button>
                </>
              ) : (
                <span className="text-xs text-slate-500">
                  Add them with &ldquo;Add someone&rdquo; first, then attach this login
                </span>
              )}
              {l.profile_id === myId ? (
                <span className="text-xs text-slate-500">This is the login you are signed in with</span>
              ) : (
                <Button size="sm" variant="ghost" onClick={() => setRemoving(l)}>Remove</Button>
              )}
            </div>
          </li>
        ))}
      </ul>
      {attach.isError && (
        <p className="mt-2 text-sm text-danger-700">{(attach.error as Error).message}</p>
      )}
    </div>
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
    </>
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
function AddPerson({ onDone, onFlash, designations }: {
  onDone: () => void; onFlash: (m: string) => void; designations: string[]
}) {
  const [form, setForm] = useState<StaffInput>(BLANK)
  const [wantsLogin, setWantsLogin] = useState(false)
  const [email, setEmail] = useState('')
  const [password, setPassword] = useState('')
  const [role, setRole] = useState('class_teacher')
  const [partial, setPartial] = useState<string | null>(null)
  // Asked when they leave the address field. The office types a name, an
  // address, a password and a role, and before this the answer to "is that
  // address free?" arrived after all four, in the auth service's own words.
  const emailCheck = useEmailCheck()

  const nameOk = form.full_name.trim().length > 0
  const loginOk = !wantsLogin
    || (/^\S+@\S+\.\S+$/.test(email.trim()) && password.length >= 6)
  // A KNOWN NO BLOCKS, an unknown does not. The database enforces uniqueness
  // whatever this screen believes, so a check that failed must not stop a
  // school adding a teacher.
  const addressFree = !wantsLogin
    || (!emailCheck.checking && emailCheck.verdict?.available !== false)
  const valid = nameOk && loginOk && addressFree
  // STAFF_ROLES: ASSIGNABLE_ROLES without Parent. No owner (signup creates the
  // only one) and, since 0133, no Admin / Clerk or Accountant.
  const roleChoices = STAFF_ROLES

  const save = useMutation({
    mutationFn: async () => {
      const staffId = await createStaff({ ...form, full_name: form.full_name.trim() })
      if (!wantsLogin) return { name: form.full_name.trim(), login: null as string | null }

      // From here the person exists. If the login fails, say so precisely and
      // leave the person alone: they are a correct record either way, and the
      // login can be added later from the same row.
      //
      // TWO CATCHES, NOT ONE, AND THE WORDING IS THE POINT. One `try` around
      // both calls could only say "their login could not be created", and it
      // said that even when the login HAD been created and only the link to the
      // staff row was missing. A school reading that retries, and the retry
      // fails with "already registered" because the address is taken by the
      // login they were told did not exist. Twice wrong is worse than silent.
      const name = form.full_name.trim()
      let created: Awaited<ReturnType<typeof createTeacherLogin>>
      try {
        created = await createTeacherLogin({
          email: email.trim(), password, full_name: name, role,
        })
      } catch (e) {
        // Neutral about whether the login exists, because the function itself
        // knows and says so: some of its refusals happen after the account is
        // minted, and this must not contradict them.
        throw new Error(
          `${name} has been added to the staff list. The login step did not `
          + `finish: ${(e as Error).message}`,
        )
      }
      try {
        await linkStaffProfile(staffId, created.id)
      } catch (e) {
        throw new Error(
          `${name} has been added and can sign in as ${created.email}, but the `
          + `login could not be joined to their staff record: `
          + `${(e as Error).message} Attach it under "logins not attached to `
          + `anybody on the staff list" above. Do not create the login again.`,
        )
      }
      return { name, login: created.email, repaired: created.repaired === true,
               remembered: created.remembered !== false }
    },
    onSuccess: (r) => {
      onFlash(
        r.login
          ? `${r.name} has been added, and can sign in as ${r.login}.`
            // SAID EITHER WAY. "Their password is saved" is the sentence that
            // stops the office writing it on a piece of paper; its absence,
            // said out loud, is what stops them assuming it was saved when the
            // school's database has not had bundle 22 yet.
            + (r.remembered === false
              ? ' Their password could NOT be saved under Settings, Users, so'
                + ' write it down now: this school\'s database does not have the'
                + ' key ring yet (apply bundle 22).'
              : ' Their password is saved under Settings, Users, so you can tell'
                + ' them again if they forget it.')
            + (r.repaired
              ? ' Note: the signup trigger on this database did not attach their'
                + ' profile, so the server finished the job. This login is fine,'
                + ' but a school signing up on your website goes through the same'
                + ' trigger with nothing to fall back on. Run supabase/verify.sql.'
              : '')
          : `${r.name} has been added. They cannot sign in yet; use "Give them a login" on their row when they need to.`,
      )
      setForm(BLANK); setEmail(''); setPassword(''); setWantsLogin(false); setPartial(null)
      onDone()
    },
    onError: (e) => setPartial((e as Error).message),
  })

  return (
    <form
      className="rounded-2xl border border-brand-200 bg-white p-4 shadow-raised"
      onSubmit={(e) => { e.preventDefault(); if (valid) save.mutate() }}
    >
      <div className="text-xs font-semibold uppercase tracking-wide text-slate-500">
        Add someone to the school
      </div>

      <StaffFields form={form} setForm={setForm} designations={designations} />

      {/* The one question that used to be a whole second form on a different
          part of the screen. */}
      <div className="mt-4 rounded-xl border border-slate-200 bg-slate-50 p-3">
        <label className="flex cursor-pointer items-start gap-2.5">
          <input type="checkbox" checked={wantsLogin} className="mt-0.5 h-4 w-4 accent-brand-600"
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
                  onChange={(e) => { setEmail(e.target.value); emailCheck.clear() }}
                  onBlur={() => void emailCheck.check(email)} className={FIELD} />
                <EmailVerdictLine verdict={emailCheck.verdict} checking={emailCheck.checking} />
              </label>
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
              and change it from their own account. It is also kept under
              Settings, Users so you can tell them again if they forget it.
            </p>
          </div>
        )}
      </div>

      {/* Deliberately not the generic mutation error: the message above says
          which half succeeded, and that distinction is the whole point of doing
          the durable half first. */}
      {partial && <p className="mt-3 text-sm text-danger-700">{partial}</p>}

      <div className="mt-4 flex flex-wrap gap-2">
        <Button type="submit" disabled={!valid || save.isPending}>
          {save.isPending ? 'Saving…' : wantsLogin ? 'Add them and make their login' : 'Add them'}
        </Button>
        <Button type="button" variant="soft" tone="neutral" onClick={onDone}>Cancel</Button>
      </div>
    </form>
  )
}

/**
 * Who teaches which subject.
 *
 * WHY THIS SCREEN IS NOT PAPERWORK. Until 0085, fn_enter_marks. The function
 * that writes the marks printed on the result card, the certificate and the
 * tabulation sheet: had NO class scope at all. Any class_teacher or
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
 * do: then teachers would hit "you can only enter marks for a class and subject
 * you teach" during exam week with no idea why.
 */
function SubjectTeachersTab() {
  const qc = useQueryClient()
  const { profile } = useAuth()
  const mayWrite = canWrite(profile?.role)
  const session = useQuery({ queryKey: ['currentSession'], queryFn: getCurrentSession })
  const sessionId = session.data?.id
  const staff = useQuery({ queryKey: ['staff'], queryFn: getStaffRoster })
  // The full active class list, so a class with NO subjects can still be picked
  // and given its first one here. The register below only carries classes that
  // already have subjects (fn_subject_teachers inner-joins subjects), which is
  // exactly the class you cannot reach when you have nothing to assign yet.
  const allClasses = useQuery({ queryKey: ['classes'], queryFn: listClasses })
  const cts = useQuery({ queryKey: ['teacherAssignments', sessionId], queryFn: () => listTeacherAssignments(sessionId!), enabled: !!sessionId })
  const [picked, setPicked] = useState('')
  const [newSubject, setNewSubject] = useState('')
  const [subjErr, setSubjErr] = useState<string | null>(null)
  const [busy, setBusy] = useState<string | null>(null)

  const register = useQuery({
    queryKey: ['subjectTeachers', sessionId],
    queryFn: () => getSubjectTeachers(sessionId!),
    enabled: !!sessionId,
  })

  const people = staff.data ?? []
  const byId = new Map(people.map((p) => [p.id, p]))
  const activeStaff = people.filter((p) => p.status === 'active')
  const classes = (allClasses.data ?? []).slice().sort((x, y) => x.level_order - y.level_order)
  const all = register.data ?? []
  // Covered means somebody on the staff teaches it. A subject whose only
  // teacher has left was counted as covered, and read as fine.
  const here = (id: string) => { const p = byId.get(id); return !!p && p.status === 'active' }
  const taught = (r: SubjectTeacherRow) => r.teachers.some((t) => here(t.staff_id))
  const stats = classes.map((c) => {
    const subs = all.filter((r) => r.class_id === c.id)
    return { ...c, subjects: subs.length, covered: subs.filter(taught).length }
  })
  // Open on the first class with a gap, so the screen starts on the work.
  const classId = picked || stats.find((x) => x.subjects > x.covered)?.id || stats[0]?.id || ''
  const rows: SubjectTeacherRow[] = all.filter((r) => r.class_id === classId)
  const cls = classes.find((c) => c.id === classId)
  const unassigned = all.filter((r) => !taught(r)).length
  const classTeachers = [...new Set((cts.data ?? []).filter((x) => x.class_id === classId).map((x) => x.staff_name))]

  const addSubject = useMutation({
    mutationFn: () => createSubject(newSubject.trim(), classId),
    onSuccess: () => {
      setNewSubject(''); setSubjErr(null)
      qc.invalidateQueries({ queryKey: ['subjectTeachers', sessionId] })
      qc.invalidateQueries({ queryKey: ['subjects', classId] })
    },
    onError: (e) => setSubjErr((e as Error).message),
  })

  const save = useMutation({
    mutationFn: (v: { subjectId: string; staffIds: string[] }) =>
      // Section null: a subject is taught to the class here. Per-section split
      // teaching is supported by the database and is not offered on this screen,
      // because it is rare and adding it would double the width of every row.
      setSubjectTeachers(sessionId!, classId, null, v.subjectId, v.staffIds),
    onMutate: (v) => setBusy(v.subjectId),
    onSettled: () => setBusy(null),
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ['subjectTeachers', sessionId] })
      qc.invalidateQueries({ queryKey: ['staff'] })
    },
  })

  const ids = (row: SubjectTeacherRow) => [...new Set(row.teachers.map((t) => t.staff_id))]

  return (
    <div className="space-y-4">
      <LoadError of={[staff, allClasses, register]} what="The subject teacher register" />
      {!sessionId && !session.isLoading && (
        <p className="rounded-xl border border-due-200 bg-due-50 p-3 text-sm text-due-800">
          There is no current session, so no subject can be given a teacher. Set one under Settings, Sessions.
        </p>
      )}
      {!mayWrite && <ObserverNotice what="subject teachers" />}

      <div className="rounded-2xl border border-brand-100 bg-brand-50 p-4 text-sm text-brand-900">
        <p className="font-semibold">This decides who can enter marks.</p>
        <p className="mt-1 text-brand-800">
          A class teacher can enter every subject in their own class. Any other teacher can enter only the subjects
          listed against them here, for tests and for the exam marks on the result card. Everyone else is refused.
        </p>
        {unassigned > 0 && (
          <p className="mt-2 font-medium text-due-800">
            {unassigned} subject{unassigned === 1 ? ' has' : 's have'} no subject teacher. Only the class teacher and
            the office can enter {unassigned === 1 ? 'its' : 'their'} marks.
          </p>
        )}
      </div>

      {/* ------------------------------------------------ every class ---- */}
      {stats.length > 0 && (
        <div className="grid grid-cols-2 gap-2 sm:grid-cols-3 lg:grid-cols-6" role="list" aria-label="Classes">
          {stats.map((c) => {
            const on = c.id === classId
            const gap = c.subjects > c.covered
            return (
              <button key={c.id} type="button" role="listitem" onClick={() => setPicked(c.id)} aria-pressed={on}
                className={`rounded-xl border px-3 py-2 text-left transition ${on ? 'border-brand-500 bg-white shadow-raised ring-1 ring-brand-500' : 'border-slate-200 bg-white hover:shadow-card'}`}>
                <div className="truncate text-sm font-semibold text-slate-900">{c.name}</div>
                <div className={`text-xs ${c.subjects === 0 ? 'text-slate-400' : gap ? 'font-medium text-due-800' : 'text-slate-500'}`}>
                  {c.subjects === 0 ? 'No subjects yet' : `${c.covered} of ${c.subjects} have a teacher`}
                </div>
                <div className="mt-1.5 h-1.5 overflow-hidden rounded-full bg-slate-100" aria-hidden>
                  <div className="h-full rounded-full" style={{ width: `${c.subjects ? Math.round((c.covered / c.subjects) * 100) : 0}%`, background: C.series }} />
                </div>
              </button>
            )
          })}
        </div>
      )}

      {register.isLoading && <p className="text-sm text-slate-500">Loading…</p>}
      {save.isError && (
        <p className="rounded-lg bg-danger-50 px-3 py-2 text-sm text-danger-700">{(save.error as Error).message}</p>
      )}

      {/* ---------------------------------------------- the one class ---- */}
      {cls && (
        <section className="rounded-2xl border border-slate-200 bg-white shadow-card" aria-label={`${cls.name} subjects`}>
          <div className="flex flex-wrap items-baseline justify-between gap-2 border-b border-slate-100 px-4 py-3">
            <h3 className="text-base font-semibold text-slate-900">{cls.name}</h3>
            <span className="text-xs text-slate-500">
              {classTeachers.length
                ? <>Class teacher: <b className="font-medium text-slate-700">{classTeachers.join(', ')}</b>, who can enter every subject</>
                : 'No class teacher yet, so only the teachers below and the office can enter marks'}
            </span>
          </div>

          {rows.length === 0 && !register.isLoading && (
            <p className="px-4 py-4 text-sm text-slate-500">
              {cls.name} has no subjects yet. Add the first one below.
            </p>
          )}

          <ul className="divide-y divide-slate-100">
            {rows.map((row) => {
              const mine = ids(row)
              const free = activeStaff.filter((p) => !mine.includes(p.id))
              return (
                <li key={row.subject_id} className="flex flex-wrap items-center gap-x-3 gap-y-2 px-4 py-3">
                  <div className="w-full min-w-0 sm:w-40">
                    <div className="text-sm font-medium text-slate-900">{row.subject_name}</div>
                    {!taught(row) && <div className="text-xs font-medium text-due-800">No subject teacher</div>}
                  </div>
                  <div className="flex min-w-0 flex-1 flex-wrap items-center gap-1.5">
                    {mine.map((id) => {
                      const p = byId.get(id)
                      const gone = !p || p.status !== 'active'
                      const noLogin = !gone && p!.login_active !== true
                      const name = p?.full_name ?? row.teachers.find((t) => t.staff_id === id)?.staff_name ?? 'Unknown'
                      return (
                        <span key={id}
                          className={`inline-flex items-center gap-1 rounded-full py-0.5 pl-2.5 pr-1 text-xs font-medium ring-1 ${
                            gone ? 'bg-danger-50 text-danger-800 ring-danger-200'
                              : noLogin ? 'bg-due-50 text-due-800 ring-due-200'
                              : 'bg-brand-50 text-brand-800 ring-brand-200'}`}
                          title={gone ? 'Has left the school' : noLogin ? 'Cannot sign in, so cannot enter these marks' : undefined}>
                          {name}{gone ? ' (has left)' : noLogin ? ' (no login)' : ''}
                          {mayWrite && (
                            <button type="button" aria-label={`Take ${name} off ${row.subject_name}`}
                              disabled={busy === row.subject_id || !sessionId}
                              onClick={() => save.mutate({ subjectId: row.subject_id, staffIds: mine.filter((x) => x !== id) })}
                              className="grid h-5 w-5 place-items-center rounded-full hover:bg-black/10 disabled:opacity-40">
                              <span aria-hidden>×</span>
                            </button>
                          )}
                        </span>
                      )
                    })}
                    {mayWrite && free.length > 0 && (
                      <select value="" aria-label={`Add a teacher to ${row.subject_name}`}
                        disabled={busy === row.subject_id || !sessionId}
                        onChange={(e) => { if (e.target.value) save.mutate({ subjectId: row.subject_id, staffIds: [...mine, e.target.value] }) }}
                        className="w-40 rounded-full border border-dashed border-slate-300 bg-white px-2.5 py-1 text-xs text-slate-600 hover:border-brand-400 focus:border-brand-500 focus:outline-none">
                        <option value="">+ Add a teacher</option>
                        {free.map((p) => (
                          <option key={p.id} value={p.id}>{p.full_name}{p.designation ? ` · ${p.designation}` : ''}{p.login_active !== true ? ' (no login)' : ''}</option>
                        ))}
                      </select>
                    )}
                    {activeStaff.length === 0 && <span className="text-xs text-slate-400">Nobody on the staff list to choose from yet.</span>}
                  </div>
                </li>
              )
            })}
          </ul>

          {/* Add a subject right here rather than sending the user to Exams. The
              same per-class subjects table, surfaced where you assign its teachers.
              Also managed in Settings, Classes and sections. */}
          {mayWrite && (
            <form className="flex flex-wrap items-center gap-2 border-t border-slate-100 px-4 py-3"
              onSubmit={(e) => { e.preventDefault(); if (newSubject.trim()) addSubject.mutate() }}>
              <input value={newSubject} onChange={(e) => setNewSubject(e.target.value)}
                placeholder={`Add a subject to ${cls.name} (e.g. Mathematics)`} aria-label={`New subject for ${cls.name}`}
                className={`${inputClass} min-w-0 flex-1 sm:max-w-xs`} />
              <Button type="submit" variant="soft" tone="brand" disabled={!newSubject.trim() || addSubject.isPending}>
                {addSubject.isPending ? 'Adding…' : 'Add subject'}
              </Button>
              {subjErr && <span className="w-full text-sm text-danger-700">{subjErr}</span>}
            </form>
          )}
        </section>
      )}
      {!allClasses.isLoading && classes.length === 0 && (
        <p className="rounded-xl border border-dashed border-slate-300 bg-white px-4 py-6 text-center text-sm text-slate-500">
          No classes yet. Add them under Settings, Classes and sections.
        </p>
      )}
    </div>
  )
}

type SlotState = 'ok' | 'nologin' | 'left' | 'none' | 'covered' | 'half'

interface Slot {
  key: string
  classId: string
  className: string
  sectionId: string | null
  /** "Section A", or "Whole class" */
  label: string
  /** An extra whole-class row on a class that also has sections. */
  wholeExtra: boolean
  teacherId: string | null
  state: SlotState
  /** The whole-class teacher, when this section has none of its own. */
  coveredBy: string | null
}

/**
 * Every register in the school and who marks it, on one screen.
 *
 * WHAT WAS WRONG. It showed one class at a time behind a "Select class…"
 * dropdown, so the one question the principal opens it with (which classes have
 * nobody?) meant opening every class in turn. And it said nothing about the
 * teacher it showed: a class teacher who had left, or who had no working login,
 * looked exactly like one who marks the register every morning. Either way that
 * register is marked by nobody, and nothing on any screen said so.
 *
 * Now every class is a card, every section a line, and every line says whether
 * somebody can actually mark it from their phone.
 */
function ClassTeachersTab() {
  const qc = useQueryClient()
  const { profile } = useAuth()
  const mayWrite = canWrite(profile?.role)
  const session = useQuery({ queryKey: ['currentSession'], queryFn: getCurrentSession })
  const sessionId = session.data?.id
  const classes = useQuery({ queryKey: ['classes'], queryFn: listClasses })
  const sections = useQuery({ queryKey: ['allSections'], queryFn: listAllSections })
  const staff = useQuery({ queryKey: ['staff'], queryFn: getStaffRoster })
  const assignments = useQuery({ queryKey: ['teacherAssignments', sessionId], queryFn: () => listTeacherAssignments(sessionId!), enabled: !!sessionId })
  const [onlyGaps, setOnlyGaps] = useState(false)
  const [busyKey, setBusyKey] = useState<string | null>(null)

  const setTeacher = useMutation({
    mutationFn: (v: { classId: string; sectionId: string | null; staffId: string | null; key: string }) =>
      setClassTeacher(v.staffId, sessionId!, v.classId, v.sectionId),
    onMutate: (v) => setBusyKey(v.key),
    onSettled: () => setBusyKey(null),
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ['allSections'] })
      qc.invalidateQueries({ queryKey: ['sectionTeachers'] })
      qc.invalidateQueries({ queryKey: ['teacherAssignments', sessionId] })
      qc.invalidateQueries({ queryKey: ['staff'] })
    },
  })

  const people = staff.data ?? []
  const byId = new Map(people.map((p) => [p.id, p]))
  const activeStaff = people.filter((p) => p.status === 'active')
  const stateOf = (id: string | null): SlotState => {
    if (!id) return 'none'
    const p = byId.get(id)
    if (!p || p.status !== 'active') return 'left'
    return p.login_active === true ? 'ok' : 'nologin'
  }

  const cards = (classes.data ?? []).map((c) => {
    const secs = (sections.data ?? []).filter((x) => x.class_id === c.id)
      .sort((x, y) => (x.sort_order ?? 0) - (y.sort_order ?? 0) || x.name.localeCompare(y.name))
    const mine = (assignments.data ?? []).filter((x) => x.class_id === c.id)
    const whole = mine.find((x) => x.section_id === null) ?? null
    const slots: Slot[] = []
    if (secs.length === 0) {
      const t = whole?.staff_id ?? null
      slots.push({ key: `${c.id}:`, classId: c.id, className: c.name, sectionId: null, label: 'Whole class',
        wholeExtra: false, teacherId: t, state: stateOf(t), coveredBy: null })
    } else {
      for (const sec of secs) {
        const own = mine.find((x) => x.section_id === sec.id)?.staff_id ?? null
        // On the result card but not in the register table: prints their name,
        // cannot mark. Left by an old version of the screen.
        const printed = !own && sec.class_teacher_id ? sec.class_teacher_id : null
        const t = own ?? printed
        let state = stateOf(t)
        if (printed && state === 'ok') state = 'half'
        if (!t && whole) state = 'covered'
        slots.push({ key: `${c.id}:${sec.id}`, classId: c.id, className: c.name, sectionId: sec.id,
          label: `Section ${sec.name}`, wholeExtra: false, teacherId: t, state,
          coveredBy: !t && whole ? whole.staff_id : null })
      }
      if (whole) {
        slots.push({ key: `${c.id}:`, classId: c.id, className: c.name, sectionId: null, label: 'Whole class',
          wholeExtra: true, teacherId: whole.staff_id, state: stateOf(whole.staff_id), coveredBy: null })
      }
    }
    return { id: c.id, name: c.name, slots }
  })

  const registers = cards.flatMap((c) => c.slots.filter((x) => !x.wholeExtra))
  const count = (st: SlotState[]) => registers.filter((x) => st.includes(x.state)).length
  const parts: Segment[] = [
    { key: 'ok', label: 'Teacher can mark it', value: count(['ok', 'covered']), color: C.series },
    { key: 'nologin', label: 'Teacher cannot sign in', value: count(['nologin', 'half']), color: C.warn },
    { key: 'left', label: 'Teacher has left', value: count(['left']), color: C.bad },
    { key: 'none', label: 'Nobody', value: count(['none']), color: C.none },
  ]
  const gaps = registers.length - parts[0].value
  const needs = (x: Slot) => x.state !== 'ok' && x.state !== 'covered'
  const shownCards = onlyGaps ? cards.filter((c) => c.slots.some(needs)) : cards
  const loading = classes.isLoading || sections.isLoading || staff.isLoading || assignments.isLoading

  const optionsFor = (current: string | null) => {
    const list = [...activeStaff]
    if (current && !activeStaff.some((p) => p.id === current)) {
      const held = byId.get(current)
      list.unshift({ ...(held ?? ({ id: current } as StaffRosterRow)),
        full_name: held ? `${held.full_name} (has left)` : 'A former member of staff' })
    }
    return list
  }

  return (
    <div className="space-y-4">
      <LoadError of={[classes, sections, staff, assignments]} what="The class teacher board" />
      {!sessionId && !session.isLoading && (
        <p className="rounded-xl border border-due-200 bg-due-50 p-3 text-sm text-due-800">
          There is no current session, so nobody can be made a class teacher. Set one under Settings, Sessions.
        </p>
      )}
      {!mayWrite && <ObserverNotice what="class teachers" />}

      {!loading && registers.length > 0 && (
        <div className="rounded-2xl border border-slate-200 bg-white p-4 shadow-card">
          <div className="flex flex-wrap items-baseline justify-between gap-2">
            <div>
              <div className="text-2xl font-semibold tabular-nums text-slate-900">
                {parts[0].value} <span className="text-base font-normal text-slate-500">of {registers.length}</span>
              </div>
              <div className="text-sm text-slate-600">registers have a class teacher who can mark them</div>
            </div>
            {gaps > 0 && (
              <button type="button" aria-pressed={onlyGaps} onClick={() => setOnlyGaps(!onlyGaps)}
                className={`rounded-full px-3 py-1 text-sm font-medium ring-1 ${onlyGaps ? 'bg-brand-600 text-white ring-brand-600' : 'bg-white text-slate-700 ring-slate-300 hover:bg-slate-50'}`}>
                {onlyGaps ? 'Show every class' : `Show only the ${gaps} that need someone`}
              </button>
            )}
          </div>
          <div className="mt-3">
            <StackBar parts={parts} total={registers.length} height={8}
              label={`Registers: ${parts.map((p) => `${p.label} ${p.value}`).join(', ')}`} />
          </div>
          <ul className="mt-2 flex flex-wrap gap-x-4 gap-y-1 text-xs text-slate-600">
            {parts.map((p) => (
              <li key={p.key} className="inline-flex items-center gap-1.5">
                <span className="h-2.5 w-2.5 rounded-sm" style={{ background: p.color }} aria-hidden />
                {p.label} <b className="font-semibold tabular-nums text-slate-900">{p.value}</b>
              </li>
            ))}
          </ul>
        </div>
      )}

      {loading && <p className="text-sm text-slate-500">Loading…</p>}
      {!loading && cards.length === 0 && (
        <p className="rounded-xl border border-dashed border-slate-300 bg-white px-4 py-6 text-center text-sm text-slate-500">
          No classes yet. Add them under Settings, Classes and sections.
        </p>
      )}
      {setTeacher.isError && <p className="rounded-lg bg-danger-50 px-3 py-2 text-sm text-danger-700">{(setTeacher.error as Error).message}</p>}

      <div className="grid items-start gap-3 lg:grid-cols-2">
        {/* Not until every read is in: drawn early, every class read "Nobody"
            for the second the assignments took to arrive. */}
        {!loading && shownCards.map((c) => (
          <section key={c.id} className="rounded-2xl border border-slate-200 bg-white shadow-card" aria-label={c.name}>
            <h3 className="border-b border-slate-100 px-4 py-2.5 text-sm font-semibold text-slate-900">{c.name}</h3>
            <ul className="divide-y divide-slate-100">
              {c.slots.filter((x) => !onlyGaps || needs(x) || x.wholeExtra).map((x) => {
                const t = x.teacherId ? byId.get(x.teacherId) : null
                const also = x.teacherId
                  ? registers.filter((o) => o.teacherId === x.teacherId && o.key !== x.key)
                      .map((o) => `${o.className}${o.sectionId ? ` ${o.label.replace('Section ', '')}` : ''}`)
                  : []
                return (
                  <li key={x.key} className="flex flex-wrap items-center gap-x-3 gap-y-1.5 px-4 py-2.5">
                    <div className="min-w-0 flex-1">
                      <div className="text-sm font-medium text-slate-800">
                        {x.label}
                        {x.wholeExtra && <span className="ml-1 text-xs font-normal text-slate-500">(covers every section)</span>}
                      </div>
                      <SlotLine slot={x} teacher={t ?? null} coveredBy={x.coveredBy ? byId.get(x.coveredBy)?.full_name ?? null : null} also={also} />
                    </div>
                    {x.state === 'half' && mayWrite && sessionId ? (
                      <Button size="sm" variant="soft" tone="brand" disabled={busyKey === x.key}
                        onClick={() => setTeacher.mutate({ classId: x.classId, sectionId: x.sectionId, staffId: x.teacherId, key: x.key })}>
                        Let them mark it
                      </Button>
                    ) : null}
                    <select value={x.teacherId ?? ''} aria-label={`Class teacher of ${c.name} ${x.label}`}
                      disabled={!sessionId || !mayWrite || busyKey === x.key}
                      onChange={(e) => setTeacher.mutate({ classId: x.classId, sectionId: x.sectionId, staffId: e.target.value || null, key: x.key })}
                      className="w-full rounded-lg border border-slate-300 bg-white px-2 py-1.5 text-sm focus:border-brand-500 focus:outline-none disabled:bg-slate-50 sm:w-56">
                      <option value="">{x.teacherId ? 'Nobody (clear)' : 'Choose a teacher…'}</option>
                      {optionsFor(x.teacherId).map((p) => (
                        <option key={p.id} value={p.id}>{p.full_name}{p.status === 'active' && p.login_active !== true ? ' (no login)' : ''}</option>
                      ))}
                    </select>
                  </li>
                )
              })}
            </ul>
          </section>
        ))}
      </div>
      <p className="text-xs text-slate-500">
        The class teacher marks the daily register, enters marks for every subject in the class, writes the report card
        remark, and is printed on the result card. One teacher can run more than one section.
      </p>
    </div>
  )
}

function SlotLine({ slot, teacher, coveredBy, also }: {
  slot: Slot; teacher: StaffRosterRow | null; coveredBy: string | null; also: string[]
}) {
  const alsoText = also.length ? ` · also ${also.join(', ')}` : ''
  switch (slot.state) {
    case 'ok':
      return <div className="text-xs text-slate-500">{teacher?.full_name}{alsoText}</div>
    case 'covered':
      return <div className="text-xs text-slate-500">Marked by {coveredBy ?? 'the whole-class teacher'}. No name on the result card.</div>
    case 'nologin':
      return <div className="text-xs font-medium text-due-800">{teacher?.full_name} cannot sign in, so nobody marks this register. Give them a login on the Staff tab.</div>
    case 'half':
      return <div className="text-xs font-medium text-due-800">{teacher?.full_name} is on the result card but cannot mark the register.</div>
    case 'left':
      return <div className="text-xs font-medium text-danger-700">{teacher?.full_name ?? 'The teacher'} has left. Choose somebody else.</div>
    default:
      return <div className="text-xs font-medium text-due-800">Nobody is set to mark this register.</div>
  }
}
